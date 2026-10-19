import SwiftUI
import UIKit

/// Uses a separate alert-level window so the privacy cover sits above sheets,
/// full-screen covers, and any other presentation captured by the app switcher.
struct PrivacyShieldHost: UIViewControllerRepresentable {
    let isPresented: Bool

    func makeUIViewController(context: Context) -> PrivacyShieldController { PrivacyShieldController() }

    func updateUIViewController(_ controller: PrivacyShieldController, context: Context) {
        controller.setPresented(isPresented)
    }
}

final class PrivacyShieldController: UIViewController {
    private var shieldWindow: UIWindow?
    private var requestedBySwiftUI = false
    private var lifecycleRequiresShield = false

    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillResignActive),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        updateWindow()
    }

    func setPresented(_ value: Bool) {
        requestedBySwiftUI = value
        updateWindow()
    }

    @objc private func applicationWillResignActive() {
        lifecycleRequiresShield = true
        updateWindow()
    }

    @objc private func applicationDidBecomeActive() {
        lifecycleRequiresShield = false
        updateWindow()
    }

    private func updateWindow() {
        guard requestedBySwiftUI || lifecycleRequiresShield else {
            // Keep the hosting controller alive after hiding its window. Releasing
            // it while UIKit is finishing an app lifecycle appearance transition
            // can leave the controller with an unmatched begin/end transition.
            if let shieldWindow, !shieldWindow.isHidden {
                shieldWindow.isHidden = true
            }
            return
        }
        // updateUIViewController may run before SwiftUI has attached this host to
        // a scene. viewDidAppear performs the reliable retry without a dispatch
        // loop that could otherwise spin while the scene is inactive.
        guard let scene = view.window?.windowScene else { return }
        if shieldWindow == nil {
            let window = UIWindow(windowScene: scene)
            window.windowLevel = .alert + 1
            window.backgroundColor = .systemBackground
            window.isOpaque = true
            let host = UIHostingController(rootView: PrivacyCover())
            host.view.accessibilityViewIsModal = true
            window.rootViewController = host
            shieldWindow = window
        }
        shieldWindow?.frame = scene.effectiveGeometry.coordinateSpace.bounds
        if let shieldWindow, shieldWindow.isHidden {
            shieldWindow.isHidden = false
        }
    }
}
