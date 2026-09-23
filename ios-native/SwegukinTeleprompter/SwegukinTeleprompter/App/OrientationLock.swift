import SwiftUI
import UIKit

/// Which way a script is shot. Landscape is the default because the prompter
/// is used sideways, like a game.
enum ScriptOrientation: String, CaseIterable, Identifiable {
    case landscape
    case portrait

    var id: String { rawValue }

    var label: String { self == .landscape ? "Landscape" : "Portrait" }

    var mask: UIInterfaceOrientationMask {
        self == .landscape ? .landscape : .portrait
    }

    static func from(_ raw: String?) -> ScriptOrientation {
        ScriptOrientation(rawValue: raw ?? "") ?? .landscape
    }
}

/// Rotates the app the way iOS games do: the delegate reports the mask we want
/// and the scene is asked to adopt it. Documented API only —
/// `UIWindowScene.requestGeometryUpdate(_:errorHandler:)` and
/// `UIViewController.setNeedsUpdateOfSupportedInterfaceOrientations()`.
@MainActor
final class OrientationLock {
    static let shared = OrientationLock()

    /// What the app delegate reports for supported orientations.
    private(set) var mask: UIInterfaceOrientationMask = .all

    /// Locks the interface to `mask` and rotates immediately if needed.
    func lock(to mask: UIInterfaceOrientationMask) {
        apply(mask)
    }

    /// Back to the normal, freely rotating app.
    func release() {
        apply(.all)
    }

    private func apply(_ next: UIInterfaceOrientationMask) {
        mask = next
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
            ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
        else { return }

        for window in scene.windows {
            window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: next)) { _ in
            // A refused rotation simply leaves the current orientation in place.
        }
    }
}

/// Only exists so UIKit can ask which orientations the app currently allows.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        MainActor.assumeIsolated { OrientationLock.shared.mask }
    }
}
