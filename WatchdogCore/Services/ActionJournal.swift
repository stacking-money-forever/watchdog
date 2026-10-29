import Darwin
import Foundation

/// One Watchdog process-control action, kept as a durable history line.
/// The ledger is "what is stopped now"; this journal is "what we did".
struct ActionJournalEntry: Codable, Equatable, Sendable {
    enum Source: String, Codable, Sendable {
        case app
        case auto
        case cli
    }

    /// Stable `ProcessControlAction` spelling for JSONL (`forceQuit`, not `force-quit`).
    enum ActionKind: String, Codable, Sendable {
        case suspend
        case resume
        case terminate
        case forceQuit
    }

    let id: UUID
    let at: Date
    let source: Source
    let action: ActionKind
    let pid: Int32
    let startTimeMicroseconds: UInt64
    let userID: UInt32
    let executablePath: String
    let displayName: String
    let workingDirectory: String?
    let reason: String?
    var outcome: String
    let undoOf: UUID?

    init(
        id: UUID = UUID(),
        at: Date = Date(),
        source: Source,
        action: ActionKind,
        pid: Int32,
        startTimeMicroseconds: UInt64,
        userID: UInt32,
        executablePath: String,
        displayName: String,
        workingDirectory: String? = nil,
        reason: String? = nil,
        outcome: String,
        undoOf: UUID? = nil
    ) {
        self.id = id
        self.at = at
        self.source = source
        self.action = action
        self.pid = pid
        self.startTimeMicroseconds = startTimeMicroseconds
        self.userID = userID
        self.executablePath = executablePath
        self.displayName = displayName
        self.workingDirectory = workingDirectory
        self.reason = reason
        self.outcome = outcome
        self.undoOf = undoOf
    }

    init(
        id: UUID = UUID(),
        at: Date = Date(),
        source: Source,
        action: ProcessControlAction,
        process: ProcessSnapshot,
        reason: String? = nil,
        outcome: ProcessActionOutcome,
        undoOf: UUID? = nil
    ) {
        self.init(
            id: id,
            at: at,
            source: source,
            action: ActionKind(action),
            pid: process.id,
            startTimeMicroseconds: process.startTimeMicroseconds,
            userID: process.userID,
            executablePath: process.executablePath,
            displayName: process.displayName,
            workingDirectory: process.workingDirectory,
            reason: reason,
            outcome: Self.outcomeString(outcome),
            undoOf: undoOf
        )
    }

    static func outcomeString(_ outcome: ProcessActionOutcome) -> String {
        switch outcome {
        case .signalDelivered: return "signalDelivered"
        case .suspended: return "suspended"
        case .resumed: return "resumed"
        case .awaitingExit: return "awaitingExit"
        case .exited: return "exited"
        case .stillRunning: return "stillRunning"
        case .identityChanged: return "identityChanged"
        case .verificationFailed: return "verificationFailed"
        case let .failed(message): return "failed:\(message)"
        }
    }
}

extension ActionJournalEntry.ActionKind {
    init(_ action: ProcessControlAction) {
        switch action {
        case .suspend: self = .suspend
        case .resume: self = .resume
        case .terminate: self = .terminate
        case .forceQuit: self = .forceQuit
        }
    }
}

extension ActionJournalEntry.Source {
    init(_ source: SuspensionRecord.Source) {
        switch source {
        case .auto: self = .auto
        case .manual: self = .app
        case .cli: self = .cli
        }
    }
}

/// Append-only JSONL history of every signal Watchdog actually sent.
/// Failures to persist must never block or rewrite a control action.
final class ActionJournal: @unchecked Sendable {
    static let compactThreshold = 2_200
    static let compactKeep = 2_000

    private let fileURL: URL?
    private let lock = NSLock()
    private var memory: [ActionJournalEntry] = []

    /// File-backed journal. `nil` keeps records in memory only (tests, previews).
    init(fileURL: URL?) {
        self.fileURL = fileURL
    }

    static func inMemory() -> ActionJournal {
        ActionJournal(fileURL: nil)
    }

    /// Overrides the journal location; used so a verification run never
    /// touches the user's real journal.
    static let pathEnvironmentKey = "WATCHDOG_JOURNAL_PATH"

    /// `~/Library/Application Support/Watchdog/journal.jsonl`
    static func standard(environment: [String: String] = ProcessInfo.processInfo.environment) -> ActionJournal {
        if let override = environment[pathEnvironmentKey], !override.isEmpty {
            return ActionJournal(fileURL: URL(fileURLWithPath: override))
        }
        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return inMemory()
        }
        return ActionJournal(
            fileURL: support
                .appendingPathComponent("Watchdog", isDirectory: true)
                .appendingPathComponent("journal.jsonl")
        )
    }

    var isPersistent: Bool { fileURL != nil }

    func all() -> [ActionJournalEntry] {
        (try? locked { entries, _ in entries }) ?? []
    }

    /// Newest first.
    func recent(limit: Int) -> [ActionJournalEntry] {
        guard limit > 0 else { return [] }
        return Array(all().suffix(limit).reversed())
    }

    func append(_ entry: ActionJournalEntry) throws {
        try locked { entries, writer in
            entries.append(entry)
            try writer.append(entry)
            if entries.count > Self.compactThreshold {
                entries = Array(entries.suffix(Self.compactKeep))
                try writer.replace(entries)
            }
        }
    }

    /// Rewrites the matching line in place (full file rewrite under flock).
    func update(id: UUID, outcome: String) throws {
        try locked { entries, writer in
            guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
            entries[index].outcome = outcome
            try writer.replace(entries)
        }
    }

    // MARK: - Storage

    private func locked(
        _ body: (inout [ActionJournalEntry], FileWriter) throws -> Void
    ) throws -> [ActionJournalEntry] {
        try lock.withLock {
            guard let fileURL else {
                try body(&memory, .memory)
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

            var entries = Self.decode(fileURL)
            try body(&entries, .file(fileURL))
            return entries
        }
    }

    /// Skips unreadable lines; never throws.
    private static func decode(_ url: URL) -> [ActionJournalEntry] {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [] }
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        let decoder = decoder()
        var entries: [ActionJournalEntry] = []
        entries.reserveCapacity(256)
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, let lineData = trimmed.data(using: .utf8) else { continue }
            if let entry = try? decoder.decode(ActionJournalEntry.self, from: lineData) {
                entries.append(entry)
            }
        }
        return entries
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func encodeLine(_ entry: ActionJournalEntry) throws -> Data {
        var data = try encoder().encode(entry)
        data.append(0x0A)
        return data
    }

    private static func appendLine(_ entry: ActionJournalEntry, to url: URL) throws {
        let payload = try encodeLine(entry)
        let descriptor = Darwin.open(
            url.path,
            O_CREAT | O_WRONLY | O_APPEND,
            S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH
        )
        guard descriptor >= 0 else {
            throw CocoaError(.fileWriteNoPermission)
        }
        defer { Darwin.close(descriptor) }
        try payload.withUnsafeBytes { buffer in
            var written = 0
            let total = buffer.count
            guard let base = buffer.bindMemory(to: UInt8.self).baseAddress else {
                throw CocoaError(.fileWriteUnknown)
            }
            while written < total {
                let n = Darwin.write(descriptor, base + written, total - written)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw CocoaError(.fileWriteUnknown)
                }
                written += n
            }
        }
    }

    private static func replaceFile(_ url: URL, with entries: [ActionJournalEntry]) throws {
        var data = Data()
        data.reserveCapacity(entries.count * 256)
        for entry in entries {
            data.append(try encodeLine(entry))
        }
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        try data.write(to: temporary, options: .atomic)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
    }

    private enum FileWriter {
        case memory
        case file(URL)

        func append(_ entry: ActionJournalEntry) throws {
            switch self {
            case .memory:
                break
            case let .file(url):
                try ActionJournal.appendLine(entry, to: url)
            }
        }

        func replace(_ entries: [ActionJournalEntry]) throws {
            switch self {
            case .memory:
                break
            case let .file(url):
                try ActionJournal.replaceFile(url, with: entries)
            }
        }
    }
}
