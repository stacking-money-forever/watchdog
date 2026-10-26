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

/// Enumerates processes in-process through libproc instead of spawning
/// `/bin/ps`. There is no child process, no output parsing, no helper-slot
/// contention with `git`, and no deadline that can fail under load.
///
/// Field semantics deliberately mirror `ps -axo pid,ppid,pgid,uid,tty,rss,state,etime,comm`
/// so classification behaves identically: `executablePath` is argv[0] (what
/// `ps comm` prints, e.g. `claude` for a versioned native install), falling back
/// to the executable path and then the kernel's short name.
enum LibprocProcessLister {
    static func list(now: Date = Date()) throws -> [RawProcessRow] {
        let pids = try allPIDs()
        var arguments = ArgumentReader()
        var rows: [RawProcessRow] = []
        rows.reserveCapacity(pids.count)

        for pid in pids where pid > 0 {
            guard let row = readRow(pid: pid, now: now, arguments: &arguments) else { continue }
            rows.append(row)
        }
        return rows
    }

    static func readRow(pid: Int32, now: Date = Date()) -> RawProcessRow? {
        var arguments = ArgumentReader()
        return readRow(pid: pid, now: now, arguments: &arguments)
    }

    private static func allPIDs() throws -> [Int32] {
        // The process table can grow between the size probe and the read;
        // retry with headroom until the result fits.
        var capacity = Int(proc_listallpids(nil, 0))
        guard capacity > 0 else {
            throw ProcessListingError.enumerationFailed(code: errno)
        }
        for _ in 0..<4 {
            capacity += 128
            var buffer = [Int32](repeating: 0, count: capacity)
            let count = buffer.withUnsafeMutableBytes {
                proc_listallpids($0.baseAddress, Int32($0.count))
            }
            guard count > 0 else {
                throw ProcessListingError.enumerationFailed(code: errno)
            }
            if Int(count) < capacity {
                return Array(buffer.prefix(Int(count)))
            }
            capacity = Int(count) * 2
        }
        throw ProcessListingError.enumerationFailed(code: ENOMEM)
    }

    private static func readRow(
        pid: Int32,
        now: Date,
        arguments: inout ArgumentReader
    ) -> RawProcessRow? {
        var bsdInfo = proc_bsdinfo()
        let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.stride)
        let bsdResult = withUnsafeMutablePointer(to: &bsdInfo) {
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0, bsdSize)
        }
        guard bsdResult == bsdSize else { return nil }
        // Zombies have already exited; `ps` lists them as `<defunct>` but they
        // cannot be acted on and only add noise.
        guard bsdInfo.pbi_status != UInt32(SZOMB) else { return nil }

        var taskInfo = proc_taskinfo()
        let taskSize = Int32(MemoryLayout<proc_taskinfo>.stride)
        let taskResult = withUnsafeMutablePointer(to: &taskInfo) {
            proc_pidinfo(pid, PROC_PIDTASKINFO, 0, $0, taskSize)
        }
        let hasTaskInfo = taskResult == taskSize

        let startMicroseconds = bsdInfo.pbi_start_tvsec * 1_000_000 + bsdInfo.pbi_start_tvusec
        let snapshot = ProcessSnapshot(
            id: pid,
            parentPID: Int32(bitPattern: bsdInfo.pbi_ppid),
            processGroupID: Int32(bitPattern: bsdInfo.pbi_pgid),
            userID: bsdInfo.pbi_uid,
            tty: ttyName(bsdInfo.e_tdev),
            cpuPercent: 0,
            residentBytes: hasTaskInfo ? taskInfo.pti_resident_size : 0,
            state: stateLetter(bsdInfo.pbi_status),
            elapsed: elapsedText(
                startSeconds: bsdInfo.pbi_start_tvsec,
                now: now
            ),
            executablePath: arguments.commandName(pid: pid)
                ?? executablePath(pid: pid)
                ?? shortName(bsdInfo),
            startTimeMicroseconds: startMicroseconds
        )
        return RawProcessRow(
            snapshot: snapshot,
            totalCPUTimeNanoseconds: hasTaskInfo
                ? taskInfo.pti_total_user + taskInfo.pti_total_system
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

    private static func ttyName(_ device: UInt32) -> String {
        guard device != UInt32.max, device != 0,
              let name = devname(dev_t(bitPattern: device), mode_t(S_IFCHR))
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

    private static func shortName(_ info: proc_bsdinfo) -> String {
        var info = info
        let name = withUnsafeBytes(of: &info.pbi_name) { cString(from: $0) }
        if !name.isEmpty { return name }
        return withUnsafeBytes(of: &info.pbi_comm) { cString(from: $0) }
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
