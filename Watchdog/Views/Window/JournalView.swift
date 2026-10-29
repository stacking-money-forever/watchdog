import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct JournalView: View {
    @ObservedObject var monitor: ProcessMonitor
    @State private var reloadTask: Task<Void, Never>?
    @State private var selection: ActionJournalEntry.ID?
    @FocusState private var tableFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if monitor.journalEntries.isEmpty {
                emptyState
            } else {
                table
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("watchdog.window.detail.journal")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button("되돌리기") {
                    undoLatest()
                }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(latestUndoable == nil)
                .help(latestUndoable == nil ? "이미 재개됐거나 종료된 프로세스입니다" : "가장 최근 일시 정지를 되돌립니다")
                .accessibilityLabel("되돌리기")
            }
        }
        .onAppear(perform: startReloading)
        .onDisappear(perform: stopReloading)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("조치 기록")
                    .font(.title2)
                Text("\(monitor.journalEntries.count)건")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("JSON 내보내기", action: exportJSON)
                .accessibilityLabel("JSON 내보내기")
                .accessibilityIdentifier("watchdog.journal.export")
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("아직 기록이 없습니다")
                .font(.headline)
            Text("Watchdog이 프로세스를 멈추거나 종료하면 여기에 남습니다.")
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("watchdog.journal.empty")
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.top, 24)
    }

    private var table: some View {
        Table(monitor.journalEntries, selection: $selection) {
            TableColumn("시각") { entry in
                Text(Self.relativeFormatter.localizedString(for: entry.at, relativeTo: Date()))
                    .help(Self.absoluteFormatter.string(from: entry.at))
                    .accessibilityIdentifier("journal.\(entry.id.uuidString).row")
            }
            .width(min: 72, ideal: 90)
            TableColumn("출처") { entry in
                Text(JournalPresentation.sourceLabel(entry.source))
            }
            .width(min: 44, ideal: 52)
            TableColumn("조치") { entry in
                Text(JournalPresentation.actionLabel(entry.action))
            }
            .width(min: 64, ideal: 76)
            TableColumn("대상") { entry in
                Text(JournalPresentation.targetLabel(entry))
                    .lineLimit(1)
            }
            .width(min: 140, ideal: 200)
            TableColumn("사유") { entry in
                Text(entry.reason?.isEmpty == false ? entry.reason! : "—")
                    .foregroundStyle(entry.reason?.isEmpty == false ? .primary : .secondary)
                    .lineLimit(1)
            }
            .width(min: 120, ideal: 180)
            TableColumn("결과") { entry in
                Text(JournalPresentation.outcomeLabel(entry.outcome))
                    .lineLimit(1)
            }
            .width(min: 80, ideal: 110)
            TableColumn("되돌리기") { entry in
                let canUndo = monitor.undoTarget(for: entry) != nil
                HStack {
                    Button("되돌리기") {
                        selection = entry.id
                        tableFocused = true
                        monitor.undo(entry)
                    }
                    .controlSize(.small)
                    .disabled(!canUndo)
                    .help(canUndo ? "이 일시 정지를 되돌립니다" : "이미 재개됐거나 종료된 프로세스입니다")
                    .accessibilityLabel("되돌리기: \(JournalPresentation.targetLabel(entry))")
                    .accessibilityIdentifier("journal.\(entry.id.uuidString).undo")
                    Spacer(minLength: 0)
                }
            }
            .width(min: 84, ideal: 96)
        }
        .focused($tableFocused)
        .onChange(of: selection) { _, _ in
            tableFocused = true
        }
    }

    private var latestUndoable: ActionJournalEntry? {
        monitor.journalEntries.first { monitor.undoTarget(for: $0) != nil }
    }

    private func undoLatest() {
        guard let entry = latestUndoable else { return }
        selection = entry.id
        tableFocused = true
        monitor.undo(entry)
    }

    private func startReloading() {
        monitor.reloadJournal()
        reloadTask?.cancel()
        reloadTask = Task { @MainActor in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(10))
                } catch {
                    return
                }
                monitor.reloadJournal()
            }
        }
    }

    private func stopReloading() {
        reloadTask?.cancel()
        reloadTask = nil
    }

    private func exportJSON() {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "watchdog-journal.json"
        panel.title = "조치 기록 내보내기"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(monitor.journalEntries)
            try data.write(to: url, options: .atomic)
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "JSON 내보내기에 실패했습니다"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .named
        return formatter
    }()

    private static let absoluteFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()
}

extension ActionJournalEntry: Identifiable {}
