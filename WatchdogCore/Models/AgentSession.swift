import Foundation

/// An agent or service root plus the non-root descendants attributed to it.
/// Nested agent/service processes are their own sessions; `AgentLineage`
/// already names the nearest root, so this type never double-counts a subtree.
struct AgentSession: Identifiable, Equatable, Sendable {
    let id: ProcessIdentity
    let rootPID: Int32
    let name: String
    let kind: ProcessKind
    let workingDirectory: String?
    let projectName: String?
    /// Descendants of this root, excluding the root itself, ordered by PID.
    let members: [ProcessIdentity]
    let memberCount: Int
    let cpuPercent: Double
    let residentBytes: UInt64
    let isSuspended: Bool
    let elapsed: String
}
