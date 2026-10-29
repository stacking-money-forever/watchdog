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
/// Remembers argv[0] per process between samples. Reading `KERN_PROCARGS2`
/// for every process on every 2 s sample dominated the sampling cost, yet
/// argv[0] only changes on exec. The key includes the kernel's short name, which
/// exec updates; entries also expire so an exec that keeps the same short
/// name is picked up within `maximumAge`.
final class CommandNameCache: @unchecked Sendable {
    private struct Key: Hashable {
        let pid: Int32
        let startMicroseconds: UInt64
        let shortName: String
    }

    private struct Entry {
        let command: LaunchCommand?
        let storedAt: ContinuousClock.Instant
    }

    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]
    private let maximumAge: Duration
    private let now: @Sendable () -> ContinuousClock.Instant

    init(
        maximumAge: Duration = .seconds(30),
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock().now }
    ) {
        self.maximumAge = maximumAge
        self.now = now
    }

    fileprivate func command(
        pid: Int32,
        startMicroseconds: UInt64,
        shortName: String,
        read: () -> LaunchCommand?
    ) -> LaunchCommand? {
        let key = Key(pid: pid, startMicroseconds: startMicroseconds, shortName: shortName)
        let instant = now()
        if let entry = lock.withLock({ entries[key] }),
           entry.storedAt.duration(to: instant) < maximumAge {
            return entry.command
        }
        let command = read()
        lock.withLock { entries[key] = Entry(command: command, storedAt: instant) }
        return command
    }

    /// Drops entries for processes that are no longer listed.
    fileprivate func retain(pids: Set<Int32>) {
        lock.withLock {
            entries = entries.filter { pids.contains($0.key.pid) }
        }
    }

    var count: Int { lock.withLock { entries.count } }
}

enum LibprocProcessLister {
    static func list(now: Date = Date(), cache: CommandNameCache? = nil) throws -> [RawProcessRow] {
        var arguments = ArgumentReader()
        let currentUserID = getuid()
        let processes = try allProcesses()
        let rows = processes.compactMap { info in
            row(from: info, now: now, currentUserID: currentUserID, arguments: &arguments, cache: cache)
        }
        cache?.retain(pids: Set(processes.map(\.kp_proc.p_pid)))
        return rows
    }

    static func readRow(pid: Int32, now: Date = Date()) -> RawProcessRow? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size == MemoryLayout<kinfo_proc>.stride else {
            return nil
        }
        var arguments = ArgumentReader()
        return row(from: info, now: now, currentUserID: getuid(), arguments: &arguments, cache: nil)
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
        arguments: inout ArgumentReader,
        cache: CommandNameCache?
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
        // argv[0] is only readable for this user's processes; skip the
        // syscall for everyone else.
        let command: LaunchCommand?
        if userID == currentUserID {
            if let cache {
                command = cache.command(pid: pid, startMicroseconds: startMicroseconds, shortName: shortName) {
                    arguments.command(pid: pid)
                }
            } else {
                command = arguments.command(pid: pid)
            }
        } else {
            command = nil
        }
        var snapshot = ProcessSnapshot(
            id: pid,
            parentPID: info.kp_eproc.e_ppid,
            processGroupID: info.kp_eproc.e_pgid,
            userID: userID,
            tty: ttyName(info.kp_eproc.e_tdev),
            cpuPercent: 0,
            residentBytes: hasTaskInfo ? taskInfo.pti_resident_size : 0,
            state: stateLetter(
                UInt32(info.kp_proc.p_stat),
                runningThreads: hasTaskInfo ? taskInfo.pti_numrunning : nil
            ),
            elapsed: elapsedText(startSeconds: startSeconds, now: now),
            // Same order as `ps comm`: argv[0] when readable (own processes),
            // otherwise the executable path, otherwise the kernel's short name.
            executablePath: command?.name
                ?? executablePath(pid: pid)
                ?? shortName,
            startTimeMicroseconds: startMicroseconds
        )
        snapshot.launchScript = command?.script
        snapshot.launchSubcommand = command?.subcommand
        return RawProcessRow(
            snapshot: snapshot,
            totalCPUTimeNanoseconds: hasTaskInfo
                ? MachTime.nanoseconds(fromTicks: taskInfo.pti_total_user + taskInfo.pti_total_system)
                : nil
        )
    }

    /// The kernel reports `SRUN` for every live process that is not stopped,
    /// sleeping ones included. Like `ps`, call it sleeping (`S`) when none of
    /// its threads is running; unreadable thread counts keep `R`.
    static func stateLetter(_ status: UInt32, runningThreads: Int32? = nil) -> String {
        switch Int32(status) {
        case SIDL: return "I"
        case SRUN: return runningThreads == 0 ? "S" : "R"
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

    /// `devname(3)` costs ~0.5 ms per call (it searches the device database),
    /// which made tty lookup the dominant sampling cost. A device number's
    /// name does not change, so resolve each one once.
    private static let ttyNames = TTYNameCache()

    private static func ttyName(_ device: dev_t) -> String {
        guard device != -1, device != 0 else { return "??" }
        return ttyNames.name(for: device)
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

private final class TTYNameCache: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [dev_t: String] = [:]

    func name(for device: dev_t) -> String {
        if let cached = lock.withLock({ names[device] }) { return cached }
        let resolved = devname(device, mode_t(S_IFCHR)).map { String(cString: $0) } ?? "??"
        lock.withLock {
            if names.count > 4_096 { names.removeAll(keepingCapacity: true) }
            names[device] = resolved
        }
        return resolved
    }
}

/// What a process was launched as: argv[0], plus the script an interpreter
/// runs (`node …/gemini.js`), which is where npm-installed agents show.
struct LaunchCommand: Sendable, Equatable {
    let name: String
    let script: String?
    let subcommand: String?
}

/// Reads argv through `KERN_PROCARGS2`, reusing one buffer across a whole
/// enumeration. Fails (returns nil) for processes the caller may not inspect.
struct ArgumentReader {
    private var buffer: [UInt8] = []

    /// Interpreter arguments read to find the script; enough for option
    /// prefixes like `node --use-system-ca --max-old-space-size=4096 x.js`.
    private static let maximumScriptSearch = 8

    mutating func command(pid: Int32) -> LaunchCommand? {
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

        return buffer.withUnsafeBytes { raw -> LaunchCommand? in
            Self.parse(UnsafeRawBufferPointer(rebasing: raw[0..<size]))
        }
    }

    /// Layout: argc (Int32), exec path, NUL padding, argv[0], argv[1], …
    static func parse(_ bytes: UnsafeRawBufferPointer) -> LaunchCommand? {
        guard bytes.count > MemoryLayout<Int32>.size else { return nil }
        let argc = Int(bytes.loadUnaligned(as: Int32.self))
        var index = MemoryLayout<Int32>.size
        while index < bytes.count, bytes[index] != 0 { index += 1 }
        while index < bytes.count, bytes[index] == 0 { index += 1 }

        var arguments: [String] = []
        while index < bytes.count, arguments.count < min(argc, maximumScriptSearch + 2) {
            let end = bytes[index...].firstIndex(of: 0) ?? bytes.endIndex
            arguments.append(String(decoding: bytes[index..<end], as: UTF8.self))
            index = end + 1
        }
        guard let name = arguments.first, !name.isEmpty else { return nil }
        let script = AgentCatalog.isInterpreter(name)
            ? AgentCatalog.launchScript(arguments: Array(arguments.dropFirst()))
            : nil
        let subcommand = AgentCatalog.launchSubcommand(arguments: arguments)
        return LaunchCommand(name: name, script: script, subcommand: subcommand)
    }

    /// argv[0]… for a live dump. Classification still uses `command(pid:)`.
    mutating func arguments(pid: Int32, limit: Int = 10) -> [String] {
        if buffer.isEmpty {
            var argumentMax: Int32 = 0
            var size = MemoryLayout<Int32>.size
            var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
            guard sysctl(&mib, 2, &argumentMax, &size, nil, 0) == 0, argumentMax > 0 else {
                return []
            }
            buffer = [UInt8](repeating: 0, count: Int(argumentMax))
        }

        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = buffer.count
        let result = buffer.withUnsafeMutableBytes {
            sysctl(&mib, 3, $0.baseAddress, &size, nil, 0)
        }
        guard result == 0, size > MemoryLayout<Int32>.size else { return [] }

        return buffer.withUnsafeBytes { raw in
            Self.arguments(from: UnsafeRawBufferPointer(rebasing: raw[0..<size]), limit: limit)
        }
    }

    static func arguments(from bytes: UnsafeRawBufferPointer, limit: Int) -> [String] {
        guard bytes.count > MemoryLayout<Int32>.size, limit > 0 else { return [] }
        let argc = Int(bytes.loadUnaligned(as: Int32.self))
        var index = MemoryLayout<Int32>.size
        while index < bytes.count, bytes[index] != 0 { index += 1 }
        while index < bytes.count, bytes[index] == 0 { index += 1 }

        var arguments: [String] = []
        while index < bytes.count, arguments.count < min(argc, limit) {
            let end = bytes[index...].firstIndex(of: 0) ?? bytes.endIndex
            arguments.append(String(decoding: bytes[index..<end], as: UTF8.self))
            index = end + 1
        }
        return arguments
    }
}
