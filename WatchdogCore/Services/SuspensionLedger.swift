import Darwin
import Foundation

/// A process that Watchdog (the app or the CLI) stopped with SIGSTOP.
struct SuspensionRecord: Codable, Hashable, Sendable {
    enum Source: String, CaseIterable, Codable, Sendable {
        case auto
        case manual
        case cli
    }

    let pid: Int32
    let startTimeMicroseconds: UInt64
    let userID: UInt32
    let executablePath: String
    let suspendedAt: Date
    let source: Source
    /// Root identity token (`pid:start:uid`) when this stop is part of a
    /// session-scoped auto-suspend. Absent in older ledger files.
    var groupID: String?

    init(
        identity: ProcessIdentity,
        executablePath: String,
        suspendedAt: Date,
        source: Source,
        groupID: String? = nil
    ) {
        pid = identity.pid
        startTimeMicroseconds = identity.startTimeMicroseconds
        userID = identity.userID
        self.executablePath = executablePath
        self.suspendedAt = suspendedAt
        self.source = source
        self.groupID = groupID
    }

    var identity: ProcessIdentity {
        ProcessIdentity(pid: pid, startTimeMicroseconds: startTimeMicroseconds, userID: userID)
    }

    var displayName: String {
        let name = URL(fileURLWithPath: executablePath).lastPathComponent
        return name.isEmpty ? executablePath : name
    }
}

/// Durable record of every SIGSTOP Watchdog sends, so a stopped process is
/// never forgotten when Watchdog quits, crashes, or the CLI exits. The app and
/// the CLI share one file; every read-modify-write holds an exclusive `flock`
/// and replaces the file atomically.
///
/// Entries are removed when Watchdog resumes or terminates the process, and
/// `reconcile` drops entries whose exact process is gone, replaced, or no
/// longer stopped. A lookup failure keeps the entry (unknown is not gone).
final class SuspensionLedger: @unchecked Sendable {
    static let capacity = 512

    private let fileURL: URL?
    private let lock = NSLock()
    private var memory: [SuspensionRecord] = []

    /// File-backed ledger. `nil` keeps records in memory only (tests, previews).
    init(fileURL: URL?) {
        self.fileURL = fileURL
    }

    static func inMemory() -> SuspensionLedger {
        SuspensionLedger(fileURL: nil)
    }

    /// Overrides the ledger location; used by the CLI end-to-end script so a
    /// verification run never touches the user's real ledger.
    static let pathEnvironmentKey = "WATCHDOG_LEDGER_PATH"

    /// `~/Library/Application Support/Watchdog/suspensions.json`
    static func standard(environment: [String: String] = ProcessInfo.processInfo.environment) -> SuspensionLedger {
        if let override = environment[pathEnvironmentKey], !override.isEmpty {
            return SuspensionLedger(fileURL: URL(fileURLWithPath: override))
        }
        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return inMemory()
        }
        return SuspensionLedger(
            fileURL: support
                .appendingPathComponent("Watchdog", isDirectory: true)
                .appendingPathComponent("suspensions.json")
        )
    }

    var isPersistent: Bool { fileURL != nil }

    func all() -> [SuspensionRecord] {
        (try? mutate { _ in }) ?? []
    }

    func contains(_ identity: ProcessIdentity) -> Bool {
        all().contains { $0.identity == identity }
    }

    @discardableResult
    func record(_ record: SuspensionRecord) throws -> [SuspensionRecord] {
        try mutate { records in
            records.removeAll { $0.identity == record.identity }
            records.append(record)
            if records.count > Self.capacity {
                records.removeFirst(records.count - Self.capacity)
            }
        }
    }

    @discardableResult
    func remove(_ identity: ProcessIdentity) throws -> [SuspensionRecord] {
        try mutate { records in
            records.removeAll { $0.identity == identity }
        }
    }

    func records(inGroup groupID: String) -> [SuspensionRecord] {
        all().filter { $0.groupID == groupID }
    }

    @discardableResult
    func removeGroup(_ groupID: String) throws -> [SuspensionRecord] {
        try mutate { records in
            records.removeAll { $0.groupID == groupID }
        }
    }

    /// Other records sharing this identity's session group, if it is the root.
    func groupCompanions(of identity: ProcessIdentity) -> [SuspensionRecord] {
        guard let record = all().first(where: { $0.identity == identity }),
              let groupID = record.groupID,
              IdentityToken(identity).description == groupID
        else { return [] }
        return records(inGroup: groupID).filter { $0.identity != identity }
    }

    /// Drops entries whose process exited, was replaced (PID reuse), or is no
    /// longer stopped; returns the entries still stopped by Watchdog.
    @discardableResult
    func reconcile(
        lookup: (Int32) -> LiveProcessLookup = ProcessMetricsReader.liveFacts
    ) throws -> [SuspensionRecord] {
        try mutate { records in
            records.removeAll { record in
                switch lookup(record.pid) {
                case .absent:
                    return true
                case let .found(facts):
                    return facts.identity != record.identity || !facts.isSuspended || facts.isZombie
                case .failed:
                    return false
                }
            }
        }
    }

    // MARK: - Storage

    private func mutate(
        _ body: (inout [SuspensionRecord]) throws -> Void
    ) throws -> [SuspensionRecord] {
        try lock.withLock {
            guard let fileURL else {
                try body(&memory)
                return memory
            }
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let lockPath = fileURL.appendingPathExtension("lock").path
            let descriptor = Darwin.open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else {
                throw CocoaError(.fileWriteNoPermission)
            }
            defer { Darwin.close(descriptor) }
            guard flock(descriptor, LOCK_EX) == 0 else {
                throw CocoaError(.fileLocking)
            }
            defer { flock(descriptor, LOCK_UN) }

            var (records, damaged) = Self.decode(fileURL)
            if damaged {
                // Keep the unreadable original for inspection instead of
                // silently overwriting it with whatever could be salvaged.
                let aside = fileURL.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
                try? FileManager.default.copyItem(at: fileURL, to: aside)
            }
            let before = records
            try body(&records)
            if records != before || damaged {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(records).write(to: fileURL, options: .atomic)
            }
            return records
        }
    }

    /// Decodes record by record: one unreadable entry (or a source value
    /// from a newer version) must not wipe every other stopped process.
    /// `damaged` is true when anything had to be dropped.
    private static func decode(_ url: URL) -> (records: [SuspensionRecord], damaged: Bool) {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return ([], false) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let entries = try? decoder.decode([LossyRecord].self, from: data) else {
            return ([], true)
        }
        let records = entries.compactMap(\.record)
        return (records, records.count != entries.count)
    }

    private struct LossyRecord: Decodable {
        let record: SuspensionRecord?

        init(from decoder: Decoder) throws {
            record = try? SuspensionRecord(from: decoder)
        }
    }
}
