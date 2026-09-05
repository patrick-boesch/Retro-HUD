// Retro HUD by Patrick Bösch (2026)
// MIT License

import AppKit
import Foundation
import ServiceManagement

@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private weak var appDelegate: AppDelegate?
    private let loginItemManager: LoginItemManager
    private var statusItem: NSStatusItem?
    private var preferenceItems: [String: NSMenuItem] = [:]
    private let loginItem = NSMenuItem(title: "Open at Login", action: nil, keyEquivalent: "")

    init(appDelegate: AppDelegate, loginItemManager: LoginItemManager) {
        self.appDelegate = appDelegate
        self.loginItemManager = loginItemManager
        super.init()
    }

    func start() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let icon = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: RetroHUDIdentity.name)
        icon?.isTemplate = true
        item.button?.image = icon
        item.button?.toolTip = RetroHUDIdentity.name
        item.button?.setAccessibilityLabel(RetroHUDIdentity.name)
        statusItem = item

        let menu = NSMenu(title: RetroHUDIdentity.name)
        menu.autoenablesItems = false
        menu.delegate = self

        loginItem.target = self
        loginItem.action = #selector(toggleLogin)
        menu.addItem(loginItem)
        menu.addItem(.separator())

        let hudMenu = NSMenu(title: "HUD")
        hudMenu.autoenablesItems = false
        hudMenu.delegate = self
        hudMenu.addItem(preference("Brightness", key: RetroHUDPreferences.brightness))
        hudMenu.addItem(preference("Keyboard", key: RetroHUDPreferences.keyboard))
        hudMenu.addItem(preference("Volume", key: RetroHUDPreferences.volume))
        let hudItem = NSMenuItem(title: "HUD", action: nil, keyEquivalent: "")
        hudItem.submenu = hudMenu
        menu.addItem(hudItem)
        menu.addItem(preference("Follow Mouse", key: RetroHUDPreferences.followMouse))
        menu.addItem(preference("Relative Position", key: RetroHUDPreferences.relativePosition))
        menu.addItem(preference("Launch Notification", key: RetroHUDPreferences.launchNotification))
        menu.addItem(.separator())
        menu.addItem(command("About Retro HUD", action: #selector(showAbout)))
        menu.addItem(command("Quit Retro HUD", action: #selector(quit), key: "q"))
        item.menu = menu
        refresh()
    }

    func stop() {
        guard let statusItem else { return }
        NSStatusBar.system.removeStatusItem(statusItem)
        self.statusItem = nil
        preferenceItems.removeAll()
    }

    func showMenu() {
        statusItem?.button?.performClick(nil)
    }

    nonisolated func menuWillOpen(_: NSMenu) {
        guard Thread.isMainThread else { return }
        MainActor.assumeIsolated { self.refresh() }
    }

    private func refresh() {
        #if !SANDBOX
            appDelegate?.refreshAccessibilityAccess()
        #endif
        loginItemManager.updateStatus()
        loginItem.state = loginItemManager.requiresApproval ? .mixed : (loginItemManager.isEnabled ? .on : .off)
        for (key, item) in preferenceItems {
            item.state = UserDefaults.standard.bool(forKey: key) ? .on : .off
        }
        #if SANDBOX
            preferenceItems[RetroHUDPreferences.brightness]?.state = .off
            preferenceItems[RetroHUDPreferences.brightness]?.isEnabled = false
            preferenceItems[RetroHUDPreferences.keyboard]?.state = .off
            preferenceItems[RetroHUDPreferences.keyboard]?.isEnabled = false
        #endif
    }

    private func preference(_ title: String, key: String) -> NSMenuItem {
        let item = command(title, action: #selector(togglePreference(_:)))
        item.representedObject = key
        preferenceItems[key] = item
        return item
    }

    private func command(_ title: String, action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func togglePreference(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        let defaults = UserDefaults.standard
        defaults.set(!defaults.bool(forKey: key), forKey: key)
        appDelegate?.preferenceDidChange(key)
        refresh()
    }

    @objc private func toggleLogin() {
        loginItemManager.updateStatus()
        let enable = !(loginItemManager.isEnabled || loginItemManager.requiresApproval)
        loginItemManager.setEnabled(enable)
        if let error = loginItemManager.lastError {
            let alert = NSAlert()
            alert.messageText = "Could Not Change Open at Login"
            alert.informativeText = error
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        } else if enable, loginItemManager.requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
        refresh()
    }

    @objc private func showAbout() { appDelegate?.showAboutWindow() }
    @objc private func quit() { NSApp.terminate(nil) }
}
