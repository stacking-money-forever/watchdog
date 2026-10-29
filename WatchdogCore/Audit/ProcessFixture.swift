import Darwin
import Foundation

/// A saved process table in the classifier-accuracy schema.
/// Home directories are stored as `~` and compared as that literal string.
struct ProcessFixture: Codable, Equatable, Sendable {
    var capturedAt: String
    var uid: UInt32
    var rows: [Row]

    struct Row: Codable, Equatable, Sendable {
        var pid: Int32
        var ppid: Int32
        var pgid: Int32
        var uid: UInt32
        var tty: String
        var state: String
        var elapsed: String
        var path: String
        var args: [String] = []
        var cwd: String?

        enum CodingKeys: String, CodingKey {
            case pid, ppid, pgid, uid, tty, state, elapsed, path, args, cwd
        }

        init(
            pid: Int32,
            ppid: Int32,
            pgid: Int32,
            uid: UInt32,
            tty: String,
            state: String,
            elapsed: String,
            path: String,
            args: [String] = [],
            cwd: String? = nil
        ) {
            self.pid = pid
            self.ppid = ppid
            self.pgid = pgid
            self.uid = uid
            self.tty = tty
            self.state = state
            self.elapsed = elapsed
            self.path = path
            self.args = args
            self.cwd = cwd
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            pid = try container.decode(Int32.self, forKey: .pid)
            ppid = try container.decode(Int32.self, forKey: .ppid)
            pgid = try container.decode(Int32.self, forKey: .pgid)
            uid = try container.decode(UInt32.self, forKey: .uid)
            tty = try container.decode(String.self, forKey: .tty)
            state = try container.decode(String.self, forKey: .state)
            elapsed = try container.decode(String.self, forKey: .elapsed)
            path = try container.decode(String.self, forKey: .path)
            args = try container.decodeIfPresent([String].self, forKey: .args) ?? []
            cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        }
    }

    func snapshots() -> [ProcessSnapshot] {
        rows.map { row in
            var snapshot = ProcessSnapshot(
                id: row.pid,
                parentPID: row.ppid,
                processGroupID: row.pgid,
                userID: row.uid,
                tty: row.tty,
                cpuPercent: 0,
                residentBytes: 0,
                state: row.state,
                elapsed: row.elapsed,
                executablePath: row.path,
                startTimeMicroseconds: UInt64(UInt32(bitPattern: row.pid)) * 1_000_000,
                workingDirectory: row.cwd
            )
            if let name = row.args.first, AgentCatalog.isInterpreter(name) {
                snapshot.launchScript = AgentCatalog.launchScript(arguments: Array(row.args.dropFirst()))
            }
            return snapshot
        }
    }

    static func collapsingHome(_ path: String, home: String = NSHomeDirectory()) -> String {
        if path == home { return "~" }
        let prefix = home.hasSuffix("/") ? home : home + "/"
        if path.hasPrefix(prefix) {
            return "~/" + path.dropFirst(prefix.count)
        }
        return path
    }

    static func capturedAtNow(_ date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

struct ProcessLabelFile: Codable, Equatable, Sendable {
    var labels: [String: ProcessLabel]
}

struct ProcessLabel: Codable, Equatable, Sendable {
    var kind: String
    var agentName: String?
    var sessionRoot: Int32?
    var orphan: Bool
    var orphanReason: String?
    var project: String?
    var tolerance: String?
    var note: String?
}
