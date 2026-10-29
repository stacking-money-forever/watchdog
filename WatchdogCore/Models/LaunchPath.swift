import Foundation

/// Paths that mean a process was started from a throwaway directory and is
/// likely leftover after the session that created it ended.
enum LaunchPath {
    private static let temporaryPrefixes = [
        "/tmp/",
        "/private/tmp/",
        "/var/folders/",
        "/private/var/folders/",
    ]

    static func isTemporary(_ path: String) -> Bool {
        if path.contains("/AppTranslocation/") { return false }

        if path == "/tmp" || path == "/private/tmp" { return true }
        if temporaryPrefixes.contains(where: { path.hasPrefix($0) }) { return true }

        guard let tmpdir = ProcessInfo.processInfo.environment["TMPDIR"], !tmpdir.isEmpty else {
            return false
        }
        return matchesTMPDIR(path, tmpdir: tmpdir)
    }

    static func isTemporaryLaunch(of snapshot: ProcessSnapshot) -> Bool {
        if isTemporary(snapshot.executablePath) { return true }
        if let script = snapshot.launchScript, isTemporary(script) { return true }
        if let directory = snapshot.workingDirectory, isTemporary(directory) { return true }
        if let subcommand = snapshot.launchSubcommand, subcommand.hasPrefix("/"), isTemporary(subcommand) {
            return true
        }
        return false
    }

    private static func matchesTMPDIR(_ path: String, tmpdir: String) -> Bool {
        let trimmed = tmpdir.hasSuffix("/") ? String(tmpdir.dropLast()) : tmpdir
        var roots = [trimmed]
        if trimmed.hasPrefix("/private") {
            roots.append(String(trimmed.dropFirst("/private".count)))
        } else if trimmed.hasPrefix("/") {
            roots.append("/private" + trimmed)
        }
        return roots.contains { root in
            path == root || path.hasPrefix(root + "/")
        }
    }
}
