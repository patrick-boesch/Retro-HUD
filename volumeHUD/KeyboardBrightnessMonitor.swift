//
//  KeyboardBrightnessMonitor.swift
//  MIT License
//

#if !SANDBOX
    import AppKit
    import Darwin
    import Foundation
    import ObjectiveC

    /// Reads and adjusts the built-in keyboard backlight for explicit illumination-key presses.
    /// CoreBrightness is private, so all selectors and their ABI are checked before use.
    @MainActor
    private final class KeyboardBacklightController {
        private typealias BrightnessFunction = @convention(c) (AnyObject, Selector, UInt64) -> Float
        private typealias SetBrightnessFunction = @convention(c) (AnyObject, Selector, Float, UInt64) -> Bool
        private typealias BooleanFunction = @convention(c) (AnyObject, Selector, UInt64) -> Bool

        private var client: NSObject?
        private var keyboardID: UInt64?
        private var brightnessFunction: BrightnessFunction?
        private var setBrightnessFunction: SetBrightnessFunction?
        private var booleanFunctions: [String: BooleanFunction] = [:]
        private let brightnessSelector = NSSelectorFromString("brightnessForKeyboard:")
        private let setBrightnessSelector = NSSelectorFromString("setBrightness:forKeyboard:")

        var isConnected: Bool { client != nil }
        var canSetBrightness: Bool { setBrightnessFunction != nil }

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

            for name in ["isKeyboardBuiltIn:"] {
                if let method = checkedMethod(on: instance, name: name, returns: ["B", "c"], arguments: ["Q"]) {
                    booleanFunctions[name] = unsafeBitCast(method_getImplementation(method), to: BooleanFunction.self)
                }
            }

            if let writeMethod = checkedMethod(
                on: instance, name: "setBrightness:forKeyboard:", returns: ["B", "c"], arguments: ["f", "Q"],
            ) {
                setBrightnessFunction = unsafeBitCast(method_getImplementation(writeMethod), to: SetBrightnessFunction.self)
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
            setBrightnessFunction = nil
            booleanFunctions.removeAll()
            // Do not unload a framework that has registered Objective-C classes.
        }

        func brightness() -> Float? {
            guard let client, let keyboardID, let brightnessFunction else { return nil }
            let value = brightnessFunction(client, brightnessSelector, keyboardID)
            guard value.isFinite, (0.0 ... 1.0).contains(value) else { return nil }
            return value
        }

        /// A false result leaves the original key event available to macOS.
        func setBrightness(_ value: Float) -> Bool {
            guard
                let client, let keyboardID, let setBrightnessFunction,
                value.isFinite, (0.0 ... 1.0).contains(value)
            else { return false }
            return setBrightnessFunction(client, setBrightnessSelector, value, keyboardID)
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

    /// The keyboard HUD is armed exclusively by an illumination-key event.
    /// Brief readback sampling follows the hardware fade, then stops completely.
    @MainActor
    final class KeyboardBrightnessMonitor: NSObject {
        weak var hudController: HUDController?

        private let reader = KeyboardBacklightController()
        private let logger = Logger()
        private var samplingTimer: Timer?
        private var isMonitoring = false
        private var systemSleeping = false
        private var displaysSleeping = false
        private var sessionInactive = false
        private var generation = 0
        private var keyReadbackDeadline: TimeInterval = 0
        private var needsKeyHUD = false
        private var lastDisplayedBrightness: Float?
        private var hasLoggedUnavailable = false
        private var interceptionWorking = true
        private var consumedKeys: Set<Int> = []
        private var requestedBrightness: Float?
        private var lastObservedBrightness: Float?
        private var brightnessBeforeToggle: Float = 1

        private var isSuspended: Bool { systemSleeping || displaysSleeping || sessionInactive }

        func startMonitoring() {
            guard !isMonitoring else { return }
            isMonitoring = true
            interceptionWorking = true
            let center = NSWorkspace.shared.notificationCenter
            center.addObserver(self, selector: #selector(workspaceStateChanged(_:)), name: NSWorkspace.willSleepNotification, object: nil)
            center.addObserver(self, selector: #selector(workspaceStateChanged(_:)), name: NSWorkspace.didWakeNotification, object: nil)
            center.addObserver(self, selector: #selector(workspaceStateChanged(_:)), name: NSWorkspace.screensDidSleepNotification, object: nil)
            center.addObserver(self, selector: #selector(workspaceStateChanged(_:)), name: NSWorkspace.screensDidWakeNotification, object: nil)
            center.addObserver(self, selector: #selector(workspaceStateChanged(_:)), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
            center.addObserver(self, selector: #selector(workspaceStateChanged(_:)), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
            // No timer, CoreBrightness reads, or HUD at launch/re-enable.
        }

        func stopMonitoring() {
            isMonitoring = false
            NSWorkspace.shared.notificationCenter.removeObserver(self)
            stopSampling()
            reader.disconnect()
            hasLoggedUnavailable = false
            interceptionWorking = true
            systemSleeping = false
            displaysSleeping = false
            sessionInactive = false
        }

        /// Called synchronously by the existing main-run-loop event tap.
        /// Consume a native/remapped illumination key only when we can handle it.
        func handleKeyDown(keyCode: Int, useFineStep: Bool) -> Bool {
            guard (21 ... 23).contains(keyCode) else { return false }
            guard
                isMonitoring, !isSuspended,
                UserDefaults.standard.bool(forKey: "keyboardBrightnessEnabled")
            else {
                consumedKeys.remove(keyCode)
                return false
            }

            if samplingTimer != nil, ProcessInfo.processInfo.systemUptime > keyReadbackDeadline {
                finishReadback()
            }
            if !reader.isConnected, !reader.connect() {
                if !hasLoggedUnavailable {
                    logger.info("Keyboard HUD: no supported built-in backlight is available.")
                    hasLoggedUnavailable = true
                }
                consumedKeys.remove(keyCode)
                return false
            }
            hasLoggedUnavailable = false
            guard let current = reader.brightness() else {
                interceptionWorking = false
                stopSampling()
                reader.disconnect()
                consumedKeys.remove(keyCode)
                return false
            }

            guard interceptionWorking, reader.canSetBrightness else {
                // Unsupported writes leave macOS in control; retain the key-only readback HUD.
                requestedBrightness = nil
                consumedKeys.remove(keyCode)
                startKeyReadback()
                return false
            }

            // A held toggle key must not switch the backlight off/on on every repeat.
            if keyCode == 23, consumedKeys.contains(keyCode) {
                startKeyReadback()
                return true
            }

            // Advance from our last target while the hardware is still fading to it.
            let baseline = requestedBrightness ?? current
            let step: Float = useFineStep ? 1.0 / 64.0 : 1.0 / 16.0
            let target: Float
            switch keyCode {
            case 21: target = min(1, (baseline / step).rounded() * step + step)
            case 22: target = max(0, (baseline / step).rounded() * step - step)
            default: target = baseline > 0 ? 0 : brightnessBeforeToggle
            }

            // Do not restart a fade when a held key repeats the same accepted target.
            // New targets must be accepted by the setter before swallowing the key.
            guard requestedBrightness == target || reader.setBrightness(target) else {
                logger.info("Keyboard HUD: backlight write failed; returning keyboard control to macOS.")
                interceptionWorking = false
                requestedBrightness = nil
                consumedKeys.remove(keyCode)
                startKeyReadback()
                return false
            }
            if baseline > 0 { brightnessBeforeToggle = baseline }
            requestedBrightness = target
            lastObservedBrightness = current
            consumedKeys.insert(keyCode)
            startKeyReadback()
            return true
        }

        /// Suppress the release only if the matching press was handled by this app.
        func handleKeyUp(keyCode: Int) -> Bool {
            consumedKeys.remove(keyCode) != nil
        }

        private func startKeyReadback() {
            // Repeats extend one bounded readback session; they do not reset its first tick.
            keyReadbackDeadline = ProcessInfo.processInfo.systemUptime + 0.6
            needsKeyHUD = true
            guard samplingTimer == nil else { return }

            let token = generation
            let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == token else { return }
                    self.sampleAfterKeyPress()
                }
            }
            timer.fireDate = Date().addingTimeInterval(0.04)
            timer.tolerance = 0.01
            RunLoop.main.add(timer, forMode: .common)
            samplingTimer = timer
        }

        private func stopSampling() {
            // Reject timer callbacks already queued before disable/sleep/expiration.
            generation += 1
            samplingTimer?.invalidate()
            samplingTimer = nil
            keyReadbackDeadline = 0
            needsKeyHUD = false
            lastDisplayedBrightness = nil
            requestedBrightness = nil
            lastObservedBrightness = nil
        }

        private func finishReadback() {
            // Verify after the hardware fade, without reading outside the key window.
            if let target = requestedBrightness,
               lastObservedBrightness.map({ abs($0 - target) > 0.005 }) ?? true
            {
                logger.info("Keyboard HUD: backlight did not reach the requested level; returning keyboard control to macOS.")
                interceptionWorking = false
            }
            stopSampling()
        }

        private func sampleAfterKeyPress() {
            guard
                isMonitoring, !isSuspended,
                UserDefaults.standard.bool(forKey: "keyboardBrightnessEnabled")
            else {
                stopSampling()
                return
            }
            guard ProcessInfo.processInfo.systemUptime <= keyReadbackDeadline else {
                finishReadback()
                return
            }
            guard let brightness = reader.brightness() else {
                logger.info("Keyboard HUD: backlight unavailable; returning keyboard control to macOS.")
                interceptionWorking = false
                stopSampling()
                reader.disconnect()
                return
            }

            lastObservedBrightness = brightness

            // A key at 0/100% still shows the actual level; automatic changes cannot arm us.
            let changed = lastDisplayedBrightness.map { abs(brightness - $0) > 0.005 } ?? true
            guard needsKeyHUD || changed else { return }
            needsKeyHUD = false
            lastDisplayedBrightness = brightness
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
            stopSampling()
            reader.disconnect()
            hasLoggedUnavailable = false
            interceptionWorking = true
            consumedKeys.removeAll()
            // Wake only clears suspension. A new key press must arm the HUD again.
        }
    }
#endif // !SANDBOX
