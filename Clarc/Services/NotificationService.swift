import AppKit
import UserNotifications
import os.log

/// Thin wrapper around UNUserNotificationCenter for turn and input banners.
/// Notifications carry the project ID in userInfo so taps can route back to the
/// correct project window.
@MainActor
final class NotificationService: NSObject {
    static let shared = NotificationService()

    private let logger = Logger(subsystem: "com.idealapp.Clarc", category: "Notification")
    private var didRequestAuthorization = false

    /// Invoked on the main actor when the user clicks a notification.
    /// Parameters: projectId, sessionId
    var onNotificationTapped: ((UUID, String) -> Void)?

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func requestAuthorizationIfNeeded() async {
        guard !didRequestAuthorization else { return }
        didRequestAuthorization = true
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
            logger.info("Notification authorization granted=\(granted)")
        } catch {
            logger.error("Notification authorization failed: \(error.localizedDescription)")
        }
    }

    /// Post a "response complete" notification. Silently no-ops if unauthorized.
    func postResponseComplete(title: String, body: String, projectId: UUID, sessionId: String) async {
        await post(
            title: title,
            body: body.isEmpty
                ? NSLocalizedString("Response complete", comment: "Notification body when Claude finishes a response")
                : body,
            projectId: projectId,
            sessionId: sessionId
        )
    }

    func postInputRequired(title: String, projectId: UUID, sessionId: String) async {
        await post(
            title: title,
            body: NSLocalizedString(
                "Input required to continue",
                comment: "Notification body when Claude asks the user a question"
            ),
            projectId: projectId,
            sessionId: sessionId
        )
    }

    private func post(title: String, body: String, projectId: UUID, sessionId: String) async {
        if !NSApp.isActive {
            NSApp.requestUserAttention(.informationalRequest)
        }

        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            break
        default:
            return
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["projectId": projectId.uuidString, "sessionId": sessionId]

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            logger.error("Failed to post notification: \(error.localizedDescription)")
        }
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension NotificationService: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        guard let projectIdString = userInfo["projectId"] as? String,
              let projectId = UUID(uuidString: projectIdString),
              let sessionId = userInfo["sessionId"] as? String else { return }

        await MainActor.run {
            NSApp.activate(ignoringOtherApps: true)
            self.onNotificationTapped?(projectId, sessionId)
        }
    }
}
