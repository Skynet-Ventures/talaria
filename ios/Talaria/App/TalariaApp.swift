// TalariaApp — the iOS app shell.
//
// Everything of substance lives in the Talaria Swift package (TalariaKit /
// TalariaTheme / TalariaUI, see Packages/Talaria); this target only mounts
// the root view and wires the pieces that need a real UIApplication:
//   - the UNUserNotificationCenter delegate (foreground banners + the
//     APPROVE_ACTION / LATER_ACTION routing live in PushCoordinator),
//   - APNs registration callbacks for the gateway push-relay handshake,
//   - the bot-at-work Live Activity mirror,
//   - talaria:// deep links (island, widgets, notifications, external).

import SwiftUI
import TalariaKit
import TalariaTheme
import TalariaUI
import UIKit

@main
struct TalariaApp: App {

    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// The single observable state tree for the whole app (demo or live).
    @State private var model: AppModel

    init() {
        let model = AppModel()
        _model = State(initialValue: model)

        // Notification-center delegate wiring must precede the end of app
        // launch so a cold-start notification tap still reaches the router.
        // This also registers the TALARIA_APPROVAL actionable category in the
        // current theme's voice (Approve/RELEASE/grant-the-seal).
        PushCoordinator.shared.configure(model: model)

        // Mirror "bot is working" into the lock screen / Dynamic Island.
        LiveActivityController.shared.attach(to: model)

        // Solo's `shortcuts_run` needs a real UIApplication to hand control to
        // the Shortcuts app; with no opener installed the tool reports itself
        // unavailable rather than pretending to have run something. The return
        // half of the round trip is `SoloToolHost.deliver`, routed in
        // DeepLinkRouter.
        SoloToolHost.shared.openURL = { url in
            await UIApplication.shared.open(url)
        }
    }

    var body: some Scene {
        WindowGroup {
            TalariaRootView(model: model)
                .onOpenURL { url in
                    DeepLinkRouter(model: model).open(url)
                }
        }
    }
}

/// Minimal delegate: SwiftUI owns the lifecycle; UIKit callbacks that have no
/// SwiftUI equivalent are forwarded into the package layer.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {

    func applicationDidBecomeActive(_ application: UIApplication) {
        NotificationCenter.default.post(
            name: .talariaApplicationDidBecomeActive, object: application)
    }

    /// APNs registration succeeded — hand the token to PushCoordinator, which
    /// exposes it awaitably for the gateway relay registration RPC.
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        PushCoordinator.shared.didRegisterForRemoteNotifications(deviceToken: deviceToken)
    }

    /// Registration failed (no entitlement / simulator without paired
    /// developer account / network). The app stays fully usable over the
    /// live socket; the relay handshake simply never fires.
    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        PushCoordinator.shared.didFailToRegisterForRemoteNotifications(error: error)
    }
}
