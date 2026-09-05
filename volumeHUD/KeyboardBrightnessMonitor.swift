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

        var isConnected: Bool { client != nil }

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
    /// Brief readback sampling follows macOS's fade, then stops completely.
    @MainActor
    final class KeyboardBrightnessMonitor: NSObject {
        weak var hudController: HUDController?

        private let reader = KeyboardBacklightReader()
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
            // No timer, CoreBrightness reads, or HUD at launch/re-enable.
        }

        func stopMonitoring() {
            isMonitoring = false
            NSWorkspace.shared.notificationCenter.removeObserver(self)
            stopSampling()
            reader.disconnect()
            hasLoggedUnavailable = false
            systemSleeping = false
            displaysSleeping = false
            sessionInactive = false
        }

        /// The existing event tap calls this for NX illumination up/down/toggle (21/22/23).
        /// Native keys and the supplied hidutil remapping use this same path.
        func keyboardKeyPressed() {
            guard
                isMonitoring, !isSuspended,
                UserDefaults.standard.bool(forKey: "keyboardBrightnessEnabled")
            else { return }

            if !reader.isConnected, !reader.connect() {
                if !hasLoggedUnavailable {
                    logger.info("Keyboard HUD: no supported built-in backlight is available.")
                    hasLoggedUnavailable = true
                }
                return
            }
            hasLoggedUnavailable = false

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
        }

        private func sampleAfterKeyPress() {
            guard
                isMonitoring, !isSuspended,
                UserDefaults.standard.bool(forKey: "keyboardBrightnessEnabled"),
                ProcessInfo.processInfo.systemUptime <= keyReadbackDeadline
            else {
                stopSampling()
                return
            }
            guard let brightness = reader.brightness() else {
                logger.info("Keyboard HUD: backlight unavailable; retrying on the next illumination key.")
                stopSampling()
                reader.disconnect()
                return
            }

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
            // Wake only clears suspension. A new key press must arm the HUD again.
        }
    }
#endif // !SANDBOX
