import Foundation

struct AuditReport: Equatable, Codable, Sendable {
    struct FieldCounts: Equatable, Codable, Sendable {
        var compared: Int = 0
        var matches: Int = 0
        var mismatches: Int = 0
        var tolerated: Int = 0
    }

    struct Mismatch: Equatable, Codable, Sendable {
        var pid: Int32
        var field: String
        var expected: String
        var actual: String
        var note: String?
        var tolerated: Bool
    }

    var snapshotCount: Int
    var labeledCount: Int
    var kind: FieldCounts
    var agentName: FieldCounts
    var sessionRoot: FieldCounts
    var orphan: FieldCounts
    var orphanReason: FieldCounts
    var kindConfusion: [String: [String: Int]]
    var mismatches: [Mismatch]
    var toleratedMismatchCount: Int
    var untoleratedMismatchCount: Int

    func render() -> String {
        var lines: [String] = []
        lines.append("분류 정확도")
        lines.append("스냅샷 \(snapshotCount)행 · 라벨 \(labeledCount)건")
        lines.append("")
        lines.append(
            pad("필드", 16) + pad("비교", 8) + pad("일치", 8) + pad("불일치", 8) + "허용"
        )
        for (name, counts) in [
            ("kind", kind),
            ("agentName", agentName),
            ("sessionRoot", sessionRoot),
            ("orphan", orphan),
            ("orphanReason", orphanReason),
        ] as [(String, FieldCounts)] {
            lines.append(
                pad(name, 16)
                    + pad(String(counts.compared), 8)
                    + pad(String(counts.matches), 8)
                    + pad(String(counts.mismatches), 8)
                    + String(counts.tolerated)
            )
        }
        lines.append("")
        lines.append(
            "허용되지 않은 불일치 \(untoleratedMismatchCount)건 · 허용 \(toleratedMismatchCount)건"
        )
        lines.append("")
        lines.append("종류 혼동 행렬 (행=라벨, 열=계산)")
        lines.append(contentsOf: renderConfusionMatrix())
        if !mismatches.isEmpty {
            lines.append("")
            lines.append("불일치:")
            for item in mismatches {
                let mark = item.tolerated ? " [허용]" : ""
                let note = item.note.map { "  note=\($0)" } ?? ""
                lines.append(
                    "  pid \(item.pid)  \(item.field)  expected=\(item.expected)  actual=\(item.actual)\(mark)\(note)"
                )
            }
        }
        return lines.joined(separator: "\n")
    }

    private func renderConfusionMatrix() -> [String] {
        let labels = kindConfusion.keys.sorted()
        var predicted = Set<String>()
        for row in kindConfusion.values {
            predicted.formUnion(row.keys)
        }
        let columns = predicted.sorted()
        guard !labels.isEmpty, !columns.isEmpty else { return ["  (비어 있음)"] }

        let rowHeaderWidth = max(8, labels.map(\.count).max() ?? 8) + 1
        let columnWidth = max(8, columns.map(\.count).max() ?? 8) + 1
        var lines: [String] = []
        lines.append("  " + pad("", rowHeaderWidth) + columns.map { pad($0, columnWidth) }.joined())
        for label in labels {
            let row = kindConfusion[label] ?? [:]
            let cells = columns.map { pad(String(row[$0] ?? 0), columnWidth) }.joined()
            lines.append("  " + pad(label, rowHeaderWidth) + cells)
        }
        return lines
    }

    private func pad(_ text: String, _ width: Int) -> String {
        let count = text.count
        if count >= width { return String(text.prefix(width)) }
        return text + String(repeating: " ", count: width - count)
    }
}

struct ClassificationSummary: Equatable, Codable, Sendable {
    struct AgentRow: Equatable, Codable, Sendable {
        var pid: Int32
        var agentName: String
        var workingDirectory: String?
    }

    struct OrphanRow: Equatable, Codable, Sendable {
        var pid: Int32
        var path: String
        var orphanReason: String?
    }

    var snapshotCount: Int
    var kinds: [String: Int]
    var agents: [AgentRow]
    var orphans: [OrphanRow]

    func render() -> String {
        var lines: [String] = []
        lines.append("스냅샷 \(snapshotCount)행")
        let kindText = kinds.keys.sorted().map { key in
            "\(key) \(kinds[key] ?? 0)"
        }.joined(separator: " · ")
        lines.append("종류: \(kindText.isEmpty ? "없음" : kindText)")
        lines.append("에이전트 \(agents.count)개:")
        if agents.isEmpty {
            lines.append("  (없음)")
        } else {
            for agent in agents {
                let directory = agent.workingDirectory ?? "-"
                lines.append("  pid \(agent.pid)  \(agent.agentName)  cwd=\(directory)")
            }
        }
        lines.append("고아 \(orphans.count)개:")
        if orphans.isEmpty {
            lines.append("  (없음)")
        } else {
            for orphan in orphans {
                lines.append(
                    "  pid \(orphan.pid)  \(orphan.path)  \(orphan.orphanReason ?? "-")"
                )
            }
        }
        return lines.joined(separator: "\n")
    }
}

enum ClassifierAudit {
    static func classify(_ fixture: ProcessFixture) -> [ProcessSnapshot] {
        OrphanClassifier.classify(fixture.snapshots())
    }

    static func summarize(_ snapshots: [ProcessSnapshot]) -> ClassificationSummary {
        var kinds: [String: Int] = [:]
        var agents: [ClassificationSummary.AgentRow] = []
        var orphans: [ClassificationSummary.OrphanRow] = []
        for snapshot in snapshots {
            kinds[snapshot.kind.rawValue, default: 0] += 1
            if snapshot.kind == .agent, let name = snapshot.agentName {
                agents.append(
                    .init(pid: snapshot.id, agentName: name, workingDirectory: snapshot.workingDirectory)
                )
            }
            if snapshot.suspectedOrphan {
                orphans.append(
                    .init(pid: snapshot.id, path: snapshot.executablePath, orphanReason: snapshot.orphanReason?.rawValue)
                )
            }
        }
        agents.sort { $0.pid < $1.pid }
        orphans.sort { $0.pid < $1.pid }
        return ClassificationSummary(
            snapshotCount: snapshots.count,
            kinds: kinds,
            agents: agents,
            orphans: orphans
        )
    }

    static func audit(snapshots: [ProcessSnapshot], labels: [String: ProcessLabel]) -> AuditReport {
        let classified = OrphanClassifier.classify(snapshots)
        let byPID = Dictionary(classified.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var kindCounts = AuditReport.FieldCounts()
        var agentNameCounts = AuditReport.FieldCounts()
        var sessionRootCounts = AuditReport.FieldCounts()
        var orphanCounts = AuditReport.FieldCounts()
        var orphanReasonCounts = AuditReport.FieldCounts()
        var confusion: [String: [String: Int]] = [:]
        var mismatches: [AuditReport.Mismatch] = []

        let orderedLabels = labels.compactMap { key, label -> (Int32, ProcessLabel)? in
            guard let pid = Int32(key) else { return nil }
            return (pid, label)
        }
        .sorted { $0.0 < $1.0 }

        for (pid, label) in orderedLabels {
            let tolerated = label.tolerance == "miss"
            let snapshot = byPID[pid]
            let predictedKind = snapshot?.kind.rawValue ?? "missing"
            confusion[label.kind, default: [:]][predictedKind, default: 0] += 1

            compare(
                pid: pid,
                field: "kind",
                expected: label.kind,
                actual: predictedKind,
                note: label.note,
                tolerated: tolerated,
                counts: &kindCounts,
                mismatches: &mismatches
            )

            if let expectedName = label.agentName {
                compare(
                    pid: pid,
                    field: "agentName",
                    expected: expectedName,
                    actual: snapshot?.agentName ?? "nil",
                    note: label.note,
                    tolerated: tolerated,
                    counts: &agentNameCounts,
                    mismatches: &mismatches
                )
            }

            if let expectedRoot = label.sessionRoot {
                let computed: Int32?
                if let snapshot {
                    computed = snapshot.agentAncestor?.pid
                        ?? ((snapshot.kind == .agent || snapshot.kind == .service) ? snapshot.id : nil)
                } else {
                    computed = nil
                }
                compare(
                    pid: pid,
                    field: "sessionRoot",
                    expected: String(expectedRoot),
                    actual: computed.map(String.init) ?? "nil",
                    note: label.note,
                    tolerated: tolerated,
                    counts: &sessionRootCounts,
                    mismatches: &mismatches
                )
            }

            compare(
                pid: pid,
                field: "orphan",
                expected: String(label.orphan),
                actual: snapshot.map { String($0.suspectedOrphan) } ?? "nil",
                note: label.note,
                tolerated: tolerated,
                counts: &orphanCounts,
                mismatches: &mismatches
            )

            if let expectedReason = label.orphanReason, let actualReason = snapshot?.orphanReason?.rawValue {
                compare(
                    pid: pid,
                    field: "orphanReason",
                    expected: expectedReason,
                    actual: actualReason,
                    note: label.note,
                    tolerated: tolerated,
                    counts: &orphanReasonCounts,
                    mismatches: &mismatches
                )
            }
        }

        let toleratedCount = Set(mismatches.filter(\.tolerated).map(\.pid)).count
        let untoleratedCount = mismatches.filter { !$0.tolerated }.count
        return AuditReport(
            snapshotCount: snapshots.count,
            labeledCount: orderedLabels.count,
            kind: kindCounts,
            agentName: agentNameCounts,
            sessionRoot: sessionRootCounts,
            orphan: orphanCounts,
            orphanReason: orphanReasonCounts,
            kindConfusion: confusion,
            mismatches: mismatches,
            toleratedMismatchCount: toleratedCount,
            untoleratedMismatchCount: untoleratedCount
        )
    }

    static func audit(fixture: ProcessFixture, labels: [String: ProcessLabel]) -> AuditReport {
        audit(snapshots: fixture.snapshots(), labels: labels)
    }

    private static func compare(
        pid: Int32,
        field: String,
        expected: String,
        actual: String,
        note: String?,
        tolerated: Bool,
        counts: inout AuditReport.FieldCounts,
        mismatches: inout [AuditReport.Mismatch]
    ) {
        counts.compared += 1
        if expected == actual {
            counts.matches += 1
            return
        }
        if tolerated {
            counts.tolerated += 1
        } else {
            counts.mismatches += 1
        }
        mismatches.append(
            AuditReport.Mismatch(
                pid: pid,
                field: field,
                expected: expected,
                actual: actual,
                note: note,
                tolerated: tolerated
            )
        )
    }
}
