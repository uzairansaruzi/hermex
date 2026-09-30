import SwiftUI
import UIKit

/// Puts `AppLock`'s window on the app's one window scene (#885). `PushAppDelegate` names
/// this class in the scene configuration; SwiftUI still creates and owns the app window and
/// forwards the scene's lifecycle calls here.
///
/// The window sits above alerts, so it also covers sheets, full-screen covers, alerts and
/// menus, which an overlay on `ContentView` would sit under. It appears in the same call
/// that reports the phase, before the first frame of a cold launch and before the app
/// switcher snapshot, with no animation.
@MainActor final class AppLockSceneDelegate: NSObject, UIWindowSceneDelegate {
    private let lock = AppLock.shared
    private var lockWindow: UIWindow?
    private var lockHost: UIHostingController<AppLockView>?
    /// The app window that was key when the lock appeared; it is key again when the lock goes.
    private weak var coveredKeyWindow: UIWindow?
    /// The text input that last had the keyboard behind the lock; it gets it back after.
    private weak var coveredTextInput: UIResponder?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene, session.role == .windowApplication else { return }
        let window = UIWindow(windowScene: windowScene)
        window.windowLevel = .alert + 1
        let host = UIHostingController(rootView: AppLockView(lock: lock, icon: .current))
        host.view.backgroundColor = .systemBackground
        window.rootViewController = host
        // VoiceOver reads only the lock while it is up.
        window.accessibilityViewIsModal = true
        lockWindow = window
        lockHost = host
        for name in [UITextField.textDidBeginEditingNotification, UITextView.textDidBeginEditingNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(textInputDidBeginEditing(_:)), name: name, object: nil)
        }
        update()
        followLock()
    }

    func sceneWillResignActive(_ scene: UIScene) {
        guard lockWindow != nil else { return }
        lock.sceneWillResignActive()
        update()
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        guard lockWindow != nil else { return }
        lock.sceneDidEnterBackground()
        update()
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        guard lockWindow != nil else { return }
        lock.sceneDidBecomeActive()
        update()
    }

    /// Follows changes that don't come with a scene call: an unlock, Continue, or the toggle.
    private func followLock() {
        withObservationTracking {
            _ = lock.showsLockWindow
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.update()
                self?.followLock()
            }
        }
    }

    /// Something behind the lock took the keyboard after it appeared, such as the composer of
    /// a new chat an App Intent or share opened: it goes until the lock does, like one that was
    /// focused before, so no keys (⌘↩ included) reach the hidden app.
    @objc private func textInputDidBeginEditing(_ notification: Notification) {
        guard let window = lockWindow, !window.isHidden, let input = notification.object as? UIResponder else { return }
        // On the next turn: resigning inside the begin-editing call leaves UIKit half done.
        Task { @MainActor [weak self, weak input] in
            guard let self, let input, input.isFirstResponder,
                  let window = lockWindow, !window.isHidden else { return }
            coveredTextInput = input
            input.resignFirstResponder()
            if !window.isKeyWindow { window.makeKey() }
        }
    }

    private func update() {
        guard let window = lockWindow, let scene = window.windowScene else { return }
        if lock.showsLockWindow {
            if window.isHidden {
                coveredKeyWindow = scene.keyWindow
                // The keyboard sits above every window, so it goes until the lock does.
                if let input = UIResponder.currentFirstResponder, input is UIKeyInput {
                    coveredTextInput = input
                    input.resignFirstResponder()
                }
                // The icon can change in Settings, which SwiftUI doesn't observe.
                lockHost?.rootView = AppLockView(lock: lock, icon: .current)
                window.overrideUserInterfaceStyle = Self.themeStyle
                window.isHidden = false
                UIAccessibility.post(notification: .screenChanged, argument: nil)
            }
            // SwiftUI may make its own window key after ours appears on a cold launch.
            if !window.isKeyWindow { window.makeKey() }
        } else if !window.isHidden {
            window.isHidden = true
            let appWindow = coveredKeyWindow
                ?? scene.windows.first { $0 !== window && $0.windowLevel == .normal && !$0.isHidden }
            appWindow?.makeKey()
            if let input = coveredTextInput, (input as? UIView)?.window != nil {
                input.becomeFirstResponder()
            }
            coveredKeyWindow = nil
            coveredTextInput = nil
            UIAccessibility.post(notification: .screenChanged, argument: nil)
        }
    }

    /// The Theme setting, which the app window gets through `preferredColorScheme`.
    private static var themeStyle: UIUserInterfaceStyle {
        switch AppTheme.storedValue(UserDefaults.standard.string(forKey: AppTheme.storageKey) ?? "") {
        case .system: .unspecified
        case .light: .light
        case .dark: .dark
        }
    }
}

private extension UIResponder {
    private static weak var found: UIResponder?

    /// The key window's first responder, found by sending an action to no target.
    static var currentFirstResponder: UIResponder? {
        found = nil
        UIApplication.shared.sendAction(#selector(hermexRecordFirstResponder), to: nil, from: nil, for: nil)
        return found
    }

    @objc private func hermexRecordFirstResponder() {
        UIResponder.found = self
    }
}

/// The lock window's content: the lock or the "can't lock" note while the scene is active, and
/// the app icon alone whenever it's covered, locked or not, so the app switcher never shows the
/// Unlock button. The icon stays in the same spot, so switching needs no motion.
/// Static: nothing animates or repaints.
struct AppLockView: View {
    let lock: AppLock
    /// The user's chosen app icon, read each time the window appears.
    let icon: AppIconChoice

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    AppLockIcon(choice: icon)

                    // Covered, it's the icon alone.
                    if !lock.isCovered {
                        if lock.isPasscodeMissing {
                            passcodeMissing
                        } else if lock.isLocked {
                            locked
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 28)
                .padding(.top, proxy.size.height * (dynamicTypeSize.isAccessibilitySize ? 0.1 : 0.3))
                .padding(.bottom, 24)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(Color(.systemBackground).ignoresSafeArea())
    }

    private var locked: some View {
        VStack(spacing: 0) {
            title("Hermex is locked")

            AppLockButton(title: String(localized: "Unlock"), systemImage: lock.capability.method.systemImage) {
                Task { await lock.unlock() }
            }
            .disabled(lock.isAuthenticating)
        }
    }

    private var passcodeMissing: some View {
        VStack(spacing: 0) {
            title("Hermex can’t lock")

            Text("This iPhone no longer has a passcode, so the lock is off. Set a passcode, then turn the lock back on in Settings.")
                .font(AppFont.subheadline())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 310)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)

            AppLockButton(title: String(localized: "Continue"), systemImage: nil) {
                lock.continueWithoutPasscode()
            }
        }
    }

    private func title(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(AppFont.title3(weight: .semibold))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 20)
            .accessibilityAddTraits(.isHeader)
    }
}

extension AppLockCapability.Method {
    /// The glyph beside Unlock and on the Settings toggle.
    var systemImage: String {
        switch self {
        case .faceID: "faceid"
        case .touchID: "touchid"
        case .passcode: "lock"
        }
    }
}

/// The user's chosen app icon, as the Settings icon picker previews it.
private struct AppLockIcon: View {
    let choice: AppIconChoice

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 17, style: .continuous)
        Image(previewImageName)
            .resizable()
            .scaledToFit()
            .frame(width: 76, height: 76)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
            .accessibilityHidden(true)
    }

    private var previewImageName: String {
        choice.previewImageName
            ?? (colorScheme == .dark ? AppIconChoice.dark : AppIconChoice.light).previewImageName
            ?? "AppIconLightPreview"
    }
}

/// Settings' button look, sized to its title rather than the full width.
private struct AppLockButton: View {
    let title: String
    let systemImage: String?
    let action: () -> Void

    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)

        Button(action: action) {
            Group {
                if let systemImage {
                    Label(title, systemImage: systemImage)
                } else {
                    Text(title)
                }
            }
            .font(AppFont.subheadline(weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 22)
            .padding(.vertical, 10)
            .frame(minWidth: 190, minHeight: 46)
            .background { shape.fill(Color.primary.opacity(0.08)) }
            .adaptiveGlass(.regular, isInteractive: true, fallbackMaterial: .thinMaterial, in: shape)
            .overlay {
                shape
                    .stroke(Color.primary.opacity(colorSchemeContrast == .increased ? 0.24 : 0.12), lineWidth: 0.7)
                    .allowsHitTesting(false)
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .padding(.top, 22)
    }
}
