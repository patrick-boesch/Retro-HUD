//
//  KeyboardBrightnessMonitor.swift
//  MIT License
//

#if !SANDBOX
    import AppKit
    import Darwin
    import Foundation
    import ObjectiveC

    /// Observes the built-in keyboard without changing its backlight or consuming its keys.
    /// CoreBrightness is private, so all selectors and their ABI are checked before use.
    @MainActor
    private final class KeyboardBacklightReader {
        private typealias BrightnessFunction = @convention(c) (AnyObject, Selector, UInt64) -> Float
        private typealias BooleanFunction = @convention(c) (AnyObject, Selector, UInt64) -> Bool

        private var client: NSObject?
        private var keyboardID: UInt64?
        private var brightnessFunction: BrightnessFunction?
        private var booleanFunctions: [String: BooleanFunction] = [:]
        private let brightnessSelector = NSSelectorFromString("brightnessForKeyboard:")

        /// Enumerate IDs instead of assuming that keyboard 1 exists (desktop/clamshell Macs).
        func connect() -> Bool {
            disconnect()
            guard
                let framework = Bundle(path: "/System/Library/PrivateFrameworks/CoreBrightness.framework"),
                framework.load(),
                let clientClass = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type
            else { return false }

            let instance = clientClass.init()
            guard
                checkedMethod(on: instance, name: "copyKeyboardBacklightIDs", returns: ["@"], arguments: []) != nil,
                let readMethod = checkedMethod(
                    on: instance, name: "brightnessForKeyboard:", returns: ["f"], arguments: ["Q"],
                )
            else { return false }

            // Optional status methods let us filter idle/ambient dimming when the OS exposes it.
            for name in [
                "isKeyboardBuiltIn:", "isBacklightDimmedOnKeyboard:",
                "isBacklightSuppressedOnKeyboard:", "isBacklightSaturatedOnKeyboard:",
                "isAutoBrightnessEnabledForKeyboard:",
            ] {
                if let method = checkedMethod(on: instance, name: name, returns: ["B", "c"], arguments: ["Q"]) {
                    booleanFunctions[name] = unsafeBitCast(method_getImplementation(method), to: BooleanFunction.self)
                }
            }

            let idsSelector = NSSelectorFromString("copyKeyboardBacklightIDs")
            // The Objective-C copy method family returns an owned object.
            guard
                let ids = instance.perform(idsSelector)?.takeRetainedValue() as? [NSNumber],
                let isBuiltIn = booleanFunctions["isKeyboardBuiltIn:"],
                let id = ids.first(where: {
                    isBuiltIn(instance, NSSelectorFromString("isKeyboardBuiltIn:"), $0.uint64Value)
                })
            else {
                disconnect()
                return false
            }

            client = instance
            keyboardID = id.uint64Value
            brightnessFunction = unsafeBitCast(method_getImplementation(readMethod), to: BrightnessFunction.self)
            guard brightness() != nil else {
                disconnect()
                return false
            }
            return true
        }

        func disconnect() {
            client = nil
            keyboardID = nil
            brightnessFunction = nil
            booleanFunctions.removeAll()
            // Do not unload a framework that has registered Objective-C classes.
        }

        func brightness() -> Float? {
            guard let client, let keyboardID, let brightnessFunction else { return nil }
            let value = brightnessFunction(client, brightnessSelector, keyboardID)
            guard value.isFinite, (0.0 ... 1.0).contains(value) else { return nil }
            return value
        }

        func isSystemDimming(brightness: Float) -> Bool {
            flag("isBacklightDimmedOnKeyboard:")
                || flag("isBacklightSuppressedOnKeyboard:")
                || (brightness <= 0.001
                    && flag("isBacklightSaturatedOnKeyboard:")
                    && flag("isAutoBrightnessEnabledForKeyboard:"))
        }

        private func flag(_ name: String) -> Bool {
            guard let client, let keyboardID, let function = booleanFunctions[name] else { return false }
            return function(client, NSSelectorFromString(name), keyboardID)
        }

        private func checkedMethod(
            on instance: NSObject, name: String, returns returnTypes: Set<String>, arguments: [String],
        ) -> Method? {
            let selector = NSSelectorFromString(name)
            guard
                instance.responds(to: selector),
                let method = class_getInstanceMethod(type(of: instance), selector),
                method_getNumberOfArguments(method) == UInt32(arguments.count + 2)
            else { return nil }
            let returnType = method_copyReturnType(method)
            defer { free(returnType) }
            guard returnTypes.contains(String(cString: returnType)) else { return nil }
            for (index, expected) in arguments.enumerated() {
                guard let argumentType = method_copyArgumentType(method, UInt32(index + 2)) else { return nil }
                let actual = String(cString: argumentType)
                free(argumentType)
                guard actual == expected else { return nil }
            }
            return method
        }
    }

    @MainActor
    final class KeyboardBrightnessMonitor: NSObject {
        weak var hudController: HUDController?

        private let reader = KeyboardBacklightReader()
        private let logger = Logger()
        private var pollingTimer: Timer?
        private var isMonitoring = false
        private var systemSleeping = false
        private var displaysSleeping = false
        private var sessionInactive = false
        private var generation = 0
        private var previousBrightness: Float?
        private var wasSystemDimming = false
        private var suppressChangesUntil: TimeInterval = 0
        private var lastKeyboardKeyTime: TimeInterval = -.infinity
        private var needsKeyHUD = false

        private var isSuspended: Bool { systemSleeping || displaysSleeping || sessionInactive }

        func startMonitoring() {
            guard !isMonitoring else { return }
            isMonitoring = true
            let center = NSWorkspace.shared.notificationCenter
            center.addObserver(self, selector: #selector(workspaceStateChanged(_:)), name: NSWorkspace.willSleepNotification, object: nil)
            center.addObserver(self, selector: #selector(workspaceStateChanged(_:)), name: NSWorkspace.didWakeNotification, object: nil)
            center.addObserver(self, selector: #selector(workspaceStateChanged(_:)), name: NSWorkspace.screensDidSleepNotification, object: nil)
            center.addObserver(self, selector: #selector(workspaceStateChanged(_:)), name: NSWorkspace.screensDidWakeNotification, object: nil)
            center.addObserver(self, selector: #selector(workspaceStateChanged(_:)), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
            center.addObserver(self, selector: #selector(workspaceStateChanged(_:)), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
            beginPolling()
        }

        func stopMonitoring() {
            isMonitoring = false
            NSWorkspace.shared.notificationCenter.removeObserver(self)
            pausePolling()
            systemSleeping = false
            displaysSleeping = false
            sessionInactive = false
        }

        /// Called by the existing media-key tap. Let macOS process the key before reading it.
        /// Repeats and presses at 0/100% should also extend the HUD's existing display timer.
        func keyboardKeyPressed() {
            guard isMonitoring, !isSuspended, pollingTimer != nil else { return }
            lastKeyboardKeyTime = ProcessInfo.processInfo.systemUptime
            needsKeyHUD = true
            let token = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
                guard let self, self.generation == token, self.isMonitoring, !self.isSuspended else { return }
                self.checkForChange()
            }
        }

        private func beginPolling() {
            guard isMonitoring, !isSuspended else { return }
            pausePolling()
            guard reader.connect(), let initial = reader.brightness() else {
                logger.info("Keyboard HUD: no supported built-in backlight is available.")
                return
            }
            // Establish a silent baseline on launch/re-enable/wake. Never show a startup HUD.
            previousBrightness = initial
            wasSystemDimming = reader.isSystemDimming(brightness: initial)
            let token = generation
            let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == token, self.isMonitoring, !self.isSuspended else { return }
                    self.checkForChange()
                }
            }
            timer.tolerance = 0.05
            RunLoop.main.add(timer, forMode: .common)
            pollingTimer = timer
        }

        private func pausePolling() {
            generation += 1
            pollingTimer?.invalidate()
            pollingTimer = nil
            previousBrightness = nil
            needsKeyHUD = false
            lastKeyboardKeyTime = -.infinity
            wasSystemDimming = false
            suppressChangesUntil = 0
            reader.disconnect()
        }

        private func checkForChange() {
            guard UserDefaults.standard.bool(forKey: "keyboardBrightnessEnabled") else { return }
            guard let brightness = reader.brightness() else {
                logger.info("Keyboard HUD: brightness became unavailable; monitoring paused until wake or re-enable.")
                pausePolling()
                return
            }
            guard let previous = previousBrightness else {
                previousBrightness = brightness
                return
            }
            let changed = abs(brightness - previous) > 0.005
            guard changed || needsKeyHUD else { return }
            previousBrightness = brightness

            // Only query these additional properties on a change, not on every polling tick.
            let systemDimming = reader.isSystemDimming(brightness: brightness)
            let now = ProcessInfo.processInfo.systemUptime
            let recentKey = now - lastKeyboardKeyTime < 1.0
            if systemDimming || wasSystemDimming {
                suppressChangesUntil = now + 1.0
            }
            wasSystemDimming = systemDimming
            needsKeyHUD = false
            // Restoration can fade through several readings; ignore the whole transition.
            guard !systemDimming, recentKey || now >= suppressChangesUntil else { return }

            hudController?.showKeyboardBrightnessHUD(brightness: brightness)
        }

        @objc
        private nonisolated func workspaceStateChanged(_ notification: Notification) {
            let name = notification.name
            Task { @MainActor [weak self] in
                self?.handleWorkspaceStateChange(name)
            }
        }

        private func handleWorkspaceStateChange(_ name: Notification.Name) {
            guard isMonitoring else { return }
            switch name {
            case NSWorkspace.willSleepNotification: systemSleeping = true
            case NSWorkspace.didWakeNotification: systemSleeping = false
            case NSWorkspace.screensDidSleepNotification: displaysSleeping = true
            case NSWorkspace.screensDidWakeNotification: displaysSleeping = false
            case NSWorkspace.sessionDidResignActiveNotification: sessionInactive = true
            case NSWorkspace.sessionDidBecomeActiveNotification: sessionInactive = false
            default: return
            }
            pausePolling()
            guard isMonitoring, !isSuspended else { return }
            let token = generation
            // Allow the hardware to settle, then take a fresh baseline without flashing a HUD.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self, self.generation == token else { return }
                self.beginPolling()
            }
        }
    }
#endif // !SANDBOX
