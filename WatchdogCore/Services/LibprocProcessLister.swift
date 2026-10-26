import Darwin
import Foundation

/// One enumerated process plus the cumulative CPU time needed to derive a
/// per-interval percentage. `totalCPUTimeNanoseconds` is nil when the task
/// info is unreadable (another user's process), matching what `ps` exposes.
struct RawProcessRow: Sendable {
    var snapshot: ProcessSnapshot
    let totalCPUTimeNanoseconds: UInt64?
}

enum ProcessListingError: LocalizedError, Sendable {
    case enumerationFailed(code: Int32)

    var errorDescription: String? {
        switch self {
        case let .enumerationFailed(code):
            return "프로세스 목록을 읽지 못했습니다(\(code))"
        }
    }
}

/// Enumerates processes in-process (sysctl + libproc) instead of spawning
/// `/bin/ps`. There is no child process, no output parsing, no helper-slot
/// contention with `git`, and no deadline that can fail under load.
///
/// Field semantics deliberately mirror `ps -axo pid,ppid,pgid,uid,tty,rss,state,etime,comm`
/// so classification behaves identically: `executablePath` is argv[0] (what
/// `ps comm` prints, e.g. `claude` for a versioned native install), falling back
/// to the executable path and then the kernel's short name, like `ps`.
enum LibprocProcessLister {
    static func list(now: Date = Date()) throws -> [RawProcessRow] {
        var arguments = ArgumentReader()
        let currentUserID = getuid()
        return try allProcesses().compactMap { info in
            row(from: info, now: now, currentUserID: currentUserID, arguments: &arguments)
        }
    }

    static func readRow(pid: Int32, now: Date = Date()) -> RawProcessRow? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size == MemoryLayout<kinfo_proc>.stride else {
            return nil
        }
        var arguments = ArgumentReader()
        return row(from: info, now: now, currentUserID: getuid(), arguments: &arguments)
    }

    /// Every process on the system, including other users' and root's — the
    /// same `KERN_PROC_ALL` table `ps -ax` reads. Per-process `proc_pidinfo`
    /// would silently skip processes this user may not inspect, and orphan
    /// classification needs those ancestors (e.g. a root-owned `login`).
    private static func allProcesses() throws -> [kinfo_proc] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        for _ in 0..<4 {
            var size = 0
            guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else {
                throw ProcessListingError.enumerationFailed(code: errno)
            }
            // The table can grow between the size probe and the read.
            size += 64 * MemoryLayout<kinfo_proc>.stride
            var buffer = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
            let result = buffer.withUnsafeMutableBytes { raw -> Int32 in
                var length = raw.count
                let status = sysctl(&mib, 4, raw.baseAddress, &length, nil, 0)
                size = length
                return status
            }
            if result == 0 {
                return Array(buffer.prefix(size / MemoryLayout<kinfo_proc>.stride))
            }
            guard errno == ENOMEM else {
                throw ProcessListingError.enumerationFailed(code: errno)
            }
        }
        throw ProcessListingError.enumerationFailed(code: ENOMEM)
    }

    private static func row(
        from info: kinfo_proc,
        now: Date,
        currentUserID: UInt32,
        arguments: inout ArgumentReader
    ) -> RawProcessRow? {
        let pid = info.kp_proc.p_pid
        // Zombies have already exited; `ps` lists them as `<defunct>` but they
        // cannot be acted on and only add noise. pid 0 is the kernel.
        guard pid > 0, Int32(info.kp_proc.p_stat) != SZOMB else { return nil }

        let start = info.kp_proc.p_un.__p_starttime
        let startSeconds = UInt64(max(0, start.tv_sec))
        let startMicroseconds = startSeconds * 1_000_000 + UInt64(max(0, start.tv_usec))
        let userID = info.kp_eproc.e_ucred.cr_uid

        // Task info is only readable for this user's processes, as with `ps`.
        var taskInfo = proc_taskinfo()
        var hasTaskInfo = false
        if userID == currentUserID {
            let taskSize = Int32(MemoryLayout<proc_taskinfo>.stride)
            hasTaskInfo = withUnsafeMutablePointer(to: &taskInfo) {
                proc_pidinfo(pid, PROC_PIDTASKINFO, 0, $0, taskSize)
            } == taskSize
        }

        var info = info
        let shortName = withUnsafeBytes(of: &info.kp_proc.p_comm) { cString(from: $0) }
        let snapshot = ProcessSnapshot(
            id: pid,
            parentPID: info.kp_eproc.e_ppid,
            processGroupID: info.kp_eproc.e_pgid,
            userID: userID,
            tty: ttyName(info.kp_eproc.e_tdev),
            cpuPercent: 0,
            residentBytes: hasTaskInfo ? taskInfo.pti_resident_size : 0,
            state: stateLetter(UInt32(info.kp_proc.p_stat)),
            elapsed: elapsedText(startSeconds: startSeconds, now: now),
            // Same order as `ps comm`: argv[0] when readable (own processes),
            // otherwise the executable path, otherwise the kernel's short name.
            executablePath: arguments.commandName(pid: pid)
                ?? executablePath(pid: pid)
                ?? shortName,
            startTimeMicroseconds: startMicroseconds
        )
        return RawProcessRow(
            snapshot: snapshot,
            totalCPUTimeNanoseconds: hasTaskInfo
                ? MachTime.nanoseconds(fromTicks: taskInfo.pti_total_user + taskInfo.pti_total_system)
                : nil
        )
    }

    static func stateLetter(_ status: UInt32) -> String {
        switch Int32(status) {
        case SIDL: return "I"
        case SRUN: return "R"
        case SSLEEP: return "S"
        case SSTOP: return "T"
        case SZOMB: return "Z"
        default: return "?"
        }
    }

    /// `ps etime` format: `[[dd-]hh:]mm:ss`.
    static func elapsedText(startSeconds: UInt64, now: Date) -> String {
        let nowSeconds = UInt64(max(0, now.timeIntervalSince1970))
        let total = nowSeconds > startSeconds ? nowSeconds - startSeconds : 0
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60
        let clock = String(format: "%02llu:%02llu", minutes, seconds)
        if days > 0 {
            return String(format: "%llu-%02llu:", days, hours) + clock
        }
        if hours > 0 {
            return String(format: "%02llu:", hours) + clock
        }
        return clock
    }

    private static func ttyName(_ device: dev_t) -> String {
        guard device != -1, device != 0,
              let name = devname(device, mode_t(S_IFCHR))
        else {
            return "??"
        }
        return String(cString: name)
    }

    private static func executablePath(pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(
            decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
    }

    fileprivate static func cString(from bytes: UnsafeRawBufferPointer) -> String {
        let end = bytes.firstIndex(of: 0) ?? bytes.endIndex
        return String(decoding: bytes[bytes.startIndex..<end], as: UTF8.self)
    }
}

/// Reads argv[0] through `KERN_PROCARGS2`, reusing one buffer across a whole
/// enumeration. Fails (returns nil) for processes the caller may not inspect.
private struct ArgumentReader {
    private var buffer: [UInt8] = []

    mutating func commandName(pid: Int32) -> String? {
        if buffer.isEmpty {
            var argumentMax: Int32 = 0
            var size = MemoryLayout<Int32>.size
            var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
            guard sysctl(&mib, 2, &argumentMax, &size, nil, 0) == 0, argumentMax > 0 else {
                return nil
            }
            buffer = [UInt8](repeating: 0, count: Int(argumentMax))
        }

        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = buffer.count
        let result = buffer.withUnsafeMutableBytes {
            sysctl(&mib, 3, $0.baseAddress, &size, nil, 0)
        }
        guard result == 0, size > MemoryLayout<Int32>.size else { return nil }

        // Layout: argc (Int32), exec path, NUL padding, argv[0], …
        return buffer.withUnsafeBytes { raw -> String? in
            let bytes = UnsafeRawBufferPointer(rebasing: raw[0..<size])
            var index = MemoryLayout<Int32>.size
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            while index < bytes.count, bytes[index] == 0 { index += 1 }
            guard index < bytes.count else { return nil }
            let name = LibprocProcessLister.cString(
                from: UnsafeRawBufferPointer(rebasing: bytes[index..<bytes.count])
            )
            return name.isEmpty ? nil : name
        }
    }
}
