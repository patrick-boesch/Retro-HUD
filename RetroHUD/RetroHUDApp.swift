//
// Retro HUD by Patrick Bösch (2026)
// Based on volumeHUD by Danny Stewart (2025).
// MIT License
//

import AppKit
#if !SANDBOX
    import ApplicationServices
#endif
import Foundation
@preconcurrency import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, @preconcurrency UNUserNotificationCenterDelegate {
    private var volumeMonitor: VolumeMonitor?
    #if !SANDBOX
        private var brightnessMonitor: BrightnessMonitor?
        private var keyboardBrightnessMonitor: KeyboardBrightnessMonitor?
        private var mediaKeyInterceptor: MediaKeyInterceptor?
    #endif
    private var hudController: HUDController?
    private var statusMenu: StatusMenuController?
    private var loginItemManager: LoginItemManager?
    private let logger = Logger()

    func applicationDidFinishLaunching(_: Notification) {
        guard ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1" else { return }
        RetroHUDPreferences.prepare()
        NSApp.setActivationPolicy(.accessory)

        if let path = conflictingApplicationPath() {
            let alert = NSAlert()
            alert.messageText = "Another HUD App Is Already Running"
            alert.informativeText = "Quit the existing copy before starting Retro HUD:\n\n\(path)"
            alert.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        let hud = HUDController(isPreviewMode: false)
        hudController = hud
        let volume = VolumeMonitor(isPreviewMode: false)
        volume.hudController = hud
        volumeMonitor = volume
        #if !SANDBOX
            let brightness = BrightnessMonitor(isPreviewMode: false)
            brightness.hudController = hud
            brightnessMonitor = brightness
            let keyboard = KeyboardBrightnessMonitor()
            keyboard.hudController = hud
            keyboardBrightnessMonitor = keyboard
        #endif
        let login = LoginItemManager()
        loginItemManager = login
        let menu = StatusMenuController(appDelegate: self, loginItemManager: login)
        statusMenu = menu
        menu.start()
        installApplicationMenu()
        applyHUDPreferences()

        #if !SANDBOX
            requestAccessibilityPermissionsIfNeeded()
            startMediaKeyInterceptor()
        #endif
        hud.startDisplayChangeMonitoring()
        UNUserNotificationCenter.current().delegate = self
        if UserDefaults.standard.bool(forKey: RetroHUDPreferences.launchNotification),
           ProcessInfo.processInfo.systemUptime >= 180
        {
            requestNotificationAuthorization { [weak self] granted in
                guard granted else { return }
                Task { @MainActor [weak self] in self?.postLaunchNotification() }
            }
        }
    }

    func application(_: NSApplication, open _: [URL]) {
        statusMenu?.showMenu()
    }

    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows _: Bool) -> Bool {
        statusMenu?.showMenu()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool { false }

    func applicationWillTerminate(_: Notification) {
        statusMenu?.stop()
        volumeMonitor?.stopMonitoring()
        #if !SANDBOX
            brightnessMonitor?.stopMonitoring()
            keyboardBrightnessMonitor?.stopMonitoring()
            mediaKeyInterceptor?.stop()
        #endif
        hudController?.stopDisplayChangeMonitoring()
    }

    func preferenceDidChange(_ key: String) {
        if [RetroHUDPreferences.volume, RetroHUDPreferences.brightness, RetroHUDPreferences.keyboard].contains(key) {
            applyHUDPreferences()
        }
        hudController?.preferencesDidChange()
        if key == RetroHUDPreferences.launchNotification, UserDefaults.standard.bool(forKey: key) {
            requestNotificationAuthorization { _ in }
        }
    }

    private func applyHUDPreferences() {
        if UserDefaults.standard.bool(forKey: RetroHUDPreferences.volume) {
            volumeMonitor?.startMonitoring()
        } else {
            volumeMonitor?.stopMonitoring()
        }
        #if !SANDBOX
            if UserDefaults.standard.bool(forKey: RetroHUDPreferences.brightness) {
                brightnessMonitor?.startMonitoring()
            } else {
                brightnessMonitor?.stopMonitoring()
            }
            if UserDefaults.standard.bool(forKey: RetroHUDPreferences.keyboard) {
                keyboardBrightnessMonitor?.startMonitoring()
            } else {
                keyboardBrightnessMonitor?.stopMonitoring()
            }
            mediaKeyInterceptor?.preferencesDidChange()
        #endif
    }

    #if !SANDBOX
        private func startMediaKeyInterceptor() {
            if mediaKeyInterceptor == nil {
                let interceptor = MediaKeyInterceptor()
                interceptor.hudController = hudController
                interceptor.keyboardBrightnessMonitor = keyboardBrightnessMonitor
                mediaKeyInterceptor = interceptor
                volumeMonitor?.mediaKeyInterceptor = interceptor
            }
            if mediaKeyInterceptor?.start() != true {
                logger.warning("Media keys are using macOS behavior; Accessibility access may be required.")
            }
        }

        private func requestAccessibilityPermissionsIfNeeded() {
            guard !AXIsProcessTrusted() else { return }
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }

        // Re-check when returning from System Settings; no permission polling timer is needed.
        func applicationDidBecomeActive(_: Notification) {
            refreshAccessibilityAccess()
        }

        func refreshAccessibilityAccess() {
            guard hudController != nil, volumeMonitor != nil, AXIsProcessTrusted() else { return }
            volumeMonitor?.updateAccessibilityStatus()
            brightnessMonitor?.updateAccessibilityStatus()
            startMediaKeyInterceptor()
        }
    #endif

    private func conflictingApplicationPath() -> String? {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let currentURL = Bundle.main.bundleURL.standardizedFileURL
        for application in NSWorkspace.shared.runningApplications {
            guard application.processIdentifier != currentPID,
                  let identifier = application.bundleIdentifier,
                  RetroHUDIdentity.compatibleBundleIdentifiers.contains(identifier),
                  let url = application.bundleURL,
                  url.standardizedFileURL != currentURL else { continue }
            return url.path
        }
        return nil
    }

    private func installApplicationMenu() {
        let main = NSMenu()
        let application = NSMenuItem()
        let menu = NSMenu(title: RetroHUDIdentity.name)
        let about = NSMenuItem(title: "About Retro HUD", action: #selector(showAboutWindow), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Retro HUD", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        application.submenu = menu
        main.addItem(application)
        NSApp.mainMenu = main
    }

    @objc func showAboutWindow() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "4.0.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        let credits = NSMutableAttributedString(string: "Retro HUD by Patrick Bösch\nBased on volumeHUD by Danny Stewart.\n\n")
        credits.append(NSAttributedString(string: "Retro HUD on GitHub", attributes: [.link: RetroHUDIdentity.repositoryURL]))
        credits.append(NSAttributedString(string: "  ·  "))
        credits.append(NSAttributedString(string: "Original volumeHUD", attributes: [.link: RetroHUDIdentity.upstreamURL]))
        credits.append(NSAttributedString(string: "\nMIT License"))
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: RetroHUDIdentity.name,
            .applicationVersion: version,
            .version: build,
            .credits: credits,
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): "© 2026 Patrick Bösch · Original © 2025 Danny Stewart",
        ])
    }

    func userNotificationCenter(
        _: UNUserNotificationCenter, willPresent _: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) { completionHandler([.banner]) }

    func userNotificationCenter(
        _: UNUserNotificationCenter, didReceive _: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor [weak self] in self?.statusMenu?.showMenu() }
        completionHandler()
    }

    private func requestNotificationAuthorization(completion: @escaping @Sendable (Bool) -> Void) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral: completion(true)
            case .notDetermined:
                center.requestAuthorization(options: [.alert]) { granted, _ in completion(granted) }
            default: completion(false)
            }
        }
    }

    private func postLaunchNotification() {
        guard UserDefaults.standard.bool(forKey: RetroHUDPreferences.launchNotification) else { return }
        let content = UNMutableNotificationContent()
        content.title = "Retro HUD started"
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { [logger] error in
            if let error { logger.warning("Launch notification failed: \(error)") }
        }
    }
}

// A native menu-bar app has no placeholder WindowGroup or settings window.
@main
@MainActor
enum RetroHUDApp {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { application.run() }
    }
}
