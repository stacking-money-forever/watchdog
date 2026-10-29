import Combine
import Foundation
import SwiftUI

enum WatchdogFocusTarget: Hashable {
    case session(ProcessIdentity)
    case process(ProcessIdentity)
    case journal(UUID)
    case confirmationCancel
}

@MainActor
final class AccessibilityAnnouncer {
    private var cancellable: AnyCancellable?
    private var lastMessage: String?
    private var lastPostedAt: Date?
    private let announce: (String) -> Void
    private let now: () -> Date
    private let duplicateInterval: TimeInterval = 1

    init(
        monitor: ProcessMonitor,
        now: @escaping () -> Date = Date.init,
        announce: @escaping (String) -> Void = { message in
            AccessibilityNotification.Announcement(message).post()
        }
    ) {
        self.now = now
        self.announce = announce
        cancellable = monitor.$actionFeedback.sink { [weak self] feedback in
            guard let message = feedback?.message, !message.isEmpty else { return }
            self?.postIfNeeded(message)
        }
    }

    private func postIfNeeded(_ message: String) {
        let timestamp = now()
        if let lastMessage, lastMessage == message, let lastPostedAt,
           timestamp.timeIntervalSince(lastPostedAt) < duplicateInterval {
            return
        }
        lastMessage = message
        lastPostedAt = timestamp
        announce(message)
    }
}
