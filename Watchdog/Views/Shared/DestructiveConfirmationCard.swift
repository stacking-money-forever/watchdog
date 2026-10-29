import AppKit
import SwiftUI

struct PendingProcessAction: Identifiable {
    enum Kind {
        case terminate
        case forceQuit
    }

    let id = UUID()
    let process: ProcessSnapshot
    let kind: Kind
    let confirmationRequest: DestructiveActionConfirmationRequest

    var title: String {
        switch kind {
        case .terminate: return "프로세스를 종료할까요?"
        case .forceQuit: return "프로세스를 강제 종료할까요?"
        }
    }

    var message: String {
        switch kind {
        case .terminate:
            return "\(process.displayName) · PID \(process.id)\nSIGTERM을 보내 정리 후 종료할 기회를 줍니다."
        case .forceQuit:
            return "\(process.displayName) · PID \(process.id)\nSIGKILL을 보내 즉시 종료합니다. 저장하지 않은 작업은 사라집니다."
        }
    }
}

struct DestructiveConfirmationCard: View {
    enum FocusTarget {
        case cancel
        case confirm
    }

    let action: PendingProcessAction
    let onCancel: () -> Void
    let onConfirm: () -> Void

    @FocusState private var focused: FocusTarget?

    var body: some View {
        ZStack {
            Color.black.opacity(0.28)
                .contentShape(Rectangle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 16) {
                Text(action.title)
                    .font(.headline)

                Text(action.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Spacer()

                    ConfirmationCancelButton(action: onCancel)
                        .focused($focused, equals: .cancel)
                        .keyboardShortcut(.cancelAction)
                        .frame(minWidth: 72, minHeight: 22)

                    Button(action.kind == .terminate ? "종료" : "강제 종료", role: .destructive) {
                        onConfirm()
                    }
                    .accessibilityLabel(action.kind == .terminate ? "종료" : "강제 종료")
                    .focused($focused, equals: .confirm)
                    .accessibilityIdentifier("watchdog.destructive-confirmation.confirm")
                }
            }
            .padding(20)
            .frame(width: 360)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.separator.opacity(0.7))
            }
            .shadow(radius: 18, y: 8)
            .focusSection()
            .defaultFocus($focused, .cancel)
        }
        .task {
            focused = .cancel
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("watchdog.destructive-confirmation")
    }
}

private struct ConfirmationCancelButton: NSViewRepresentable {
    let action: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = FocusableCancelButton(title: "취소", target: context.coordinator, action: #selector(Coordinator.click))
        button.bezelStyle = .rounded
        button.setButtonType(.momentaryPushIn)
        button.keyEquivalent = "\u{1b}"
        button.setAccessibilityLabel("취소")
        button.setAccessibilityIdentifier("watchdog.destructive-confirmation.cancel")
        button.refusesFirstResponder = false
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        context.coordinator.action = action
        nsView.setAccessibilityLabel("취소")
        nsView.setAccessibilityIdentifier("watchdog.destructive-confirmation.cancel")
        DispatchQueue.main.async {
            nsView.window?.makeKeyAndOrderFront(nil)
            nsView.window?.makeFirstResponder(nsView)
            nsView.setAccessibilityFocused(true)
        }
    }

    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) {
            self.action = action
        }

        @objc func click() {
            action()
        }
    }
}

private final class FocusableCancelButton: NSButton {
    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        setAccessibilityFocused(true)
    }
}

struct DismissInvalidDestructiveConfirmationModifier: ViewModifier {
    @Binding var pendingAction: PendingProcessAction?
    @ObservedObject var monitor: ProcessMonitor
    var onInvalid: ((PendingProcessAction, Bool) -> Void)?

    func body(content: Content) -> some View {
        content
            .onReceive(monitor.$processes) { _ in
                dismissIfInvalid()
            }
            .onReceive(monitor.$samplingError) { _ in
                dismissIfInvalid()
            }
            .task(id: pendingAction?.id) {
                guard pendingAction != nil else { return }
                try? await Task.sleep(for: ProcessMonitor.confirmationValidity + .milliseconds(100))
                dismissIfInvalid()
            }
    }

    private func dismissIfInvalid() {
        guard let pending = pendingAction,
              !monitor.isConfirmationValid(pending.confirmationRequest)
        else { return }
        pendingAction = nil
        monitor.cancelDestructiveConfirmation(pending.confirmationRequest)
        let stillListed = monitor.processes.contains { $0.identity == pending.process.identity }
        onInvalid?(pending, stillListed)
    }
}

extension View {
    func dismissInvalidDestructiveConfirmation(
        pendingAction: Binding<PendingProcessAction?>,
        monitor: ProcessMonitor,
        onInvalid: ((PendingProcessAction, Bool) -> Void)? = nil
    ) -> some View {
        modifier(
            DismissInvalidDestructiveConfirmationModifier(
                pendingAction: pendingAction,
                monitor: monitor,
                onInvalid: onInvalid
            )
        )
    }
}
