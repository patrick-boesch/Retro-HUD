// Retro HUD by Patrick Bösch (2026)
// MIT License

#if !SANDBOX
    import AppKit
    import CoreGraphics
    import Foundation

    /// A bounded composition of clamped steps. Coalescing must preserve reversals at 0/100%.
    struct ExternalBrightnessAdjustment: Sendable {
        private var offset: Float = 0
        private var lower: Float = 0
        private var upper: Float = 1

        mutating func append(_ delta: Float) {
            offset += delta
            lower = min(1, max(0, lower + delta))
            upper = min(1, max(0, upper + delta))
            if lower == upper { offset = 0 }
        }

        func apply(to value: Float) -> Float {
            min(upper, max(lower, value + offset))
        }
    }

    /// Only pending requests/generation use the lock. Device handles stay on the serial queue.
    /// No DDC traffic, sleeps, or device discovery may run inside the CGEvent tap.
    private final class ExternalBrightnessWorker: @unchecked Sendable {
        private struct Request: Sendable {
            let candidates: [CGDirectDisplayID]
            let generation: UInt64
            var serial: UInt64
            var deadline: TimeInterval
            var adjustment = ExternalBrightnessAdjustment()
        }

        private let queue = DispatchQueue(label: "RetroHUD.externalBrightness", qos: .userInitiated)
        private let lock = NSLock()
        private let completion: @Sendable (UInt64, CGDirectDisplayID, Float) -> Void
        private var generation: UInt64 = 0
        private var pending: Request?
        private var scheduled = false
        private var devices: [CGDirectDisplayID: OpaquePointer] = [:]
        private var unavailable: Set<CGDirectDisplayID> = []
        private var failedControls: Set<CGDirectDisplayID> = []
        private var targets: [CGDirectDisplayID: (requested: Float, observed: Float, time: TimeInterval)] = [:]
        private var deviceGeneration: UInt64 = 0

        init(completion: @escaping @Sendable (UInt64, CGDirectDisplayID, Float) -> Void) {
            self.completion = completion
        }

        deinit {
            for device in devices.values { RHExternalBrightnessClose(device) }
        }

        func enqueue(candidates: [CGDirectDisplayID], delta: Float, serial: UInt64) {
            lock.lock()
            let now = ProcessInfo.processInfo.systemUptime
            var request: Request
            if let previous = pending, previous.candidates == candidates,
               previous.generation == generation, previous.deadline >= now
            {
                request = previous
            } else {
                request = Request(candidates: candidates, generation: generation, serial: serial, deadline: now + 0.8)
            }
            request.serial = serial
            request.deadline = now + 0.8
            request.adjustment.append(delta)
            pending = request
            let shouldSchedule = !scheduled
            scheduled = true
            lock.unlock()
            if shouldSchedule { queue.async { [self] in drain() } }
        }

        func invalidate() {
            lock.lock()
            generation &+= 1
            pending = nil
            lock.unlock()
            queue.async { [self] in closeDevices() }
        }

        private func closeDevices() {
            for device in devices.values { RHExternalBrightnessClose(device) }
            devices.removeAll()
            targets.removeAll()
            unavailable.removeAll()
            failedControls.removeAll()
        }

        private func isCurrent(_ request: Request) -> Bool {
            lock.lock()
            let current = generation == request.generation
            lock.unlock()
            return current && ProcessInfo.processInfo.systemUptime <= request.deadline
        }

        private func drain() {
            while true {
                lock.lock()
                guard let request = pending else {
                    scheduled = false
                    lock.unlock()
                    return
                }
                pending = nil
                lock.unlock()
                guard isCurrent(request) else { continue }
                if deviceGeneration != request.generation {
                    closeDevices()
                    deviceGeneration = request.generation
                }
                perform(request)
            }
        }

        private func markUnavailable(_ display: CGDirectDisplayID) {
            if let device = devices.removeValue(forKey: display) { RHExternalBrightnessClose(device) }
            targets.removeValue(forKey: display)
            unavailable.insert(display)
            failedControls.insert(display)
        }

        private func perform(_ request: Request) {
            for display in request.candidates {
                // Once a readable control fails, do not drift to another screen on repeats.
                if failedControls.contains(display) { return }
                if unavailable.contains(display) { continue }
                guard isCurrent(request) else { return }
                guard let device = devices[display] ?? RHExternalBrightnessOpen(display) else {
                    unavailable.insert(display)
                    continue
                }
                devices[display] = device
                var current: Float = 0
                guard isCurrent(request) else { return }
                guard RHExternalBrightnessRead(device, &current) else {
                    markUnavailable(display)
                    return
                }
                let now = ProcessInfo.processInfo.systemUptime
                let previous = targets[display]
                let baseline: Float
                if let previous, now - previous.time < 0.8, abs(previous.observed - current) < 0.005 {
                    baseline = previous.requested
                } else {
                    baseline = current
                }
                let target = request.adjustment.apply(to: baseline)
                guard isCurrent(request) else { return }
                if abs(target - current) > 0.001 {
                    guard RHExternalBrightnessWrite(device, target) else {
                        // Never redirect a failed write to another monitor or the built-in panel.
                        markUnavailable(display)
                        return
                    }
                    guard isCurrent(request) else { return }
                    var actual: Float = 0
                    guard RHExternalBrightnessRead(device, &actual) else {
                        markUnavailable(display)
                        return
                    }
                    if abs(actual - target) > 0.011 {
                        // One bounded retry for displays that apply writes with a short delay.
                        Thread.sleep(forTimeInterval: 0.15)
                        guard isCurrent(request) else { return }
                        guard RHExternalBrightnessRead(device, &actual), abs(actual - target) <= 0.011 else {
                            markUnavailable(display)
                            return
                        }
                    }
                    current = actual
                }
                guard isCurrent(request) else { return }
                targets[display] = (target, current, ProcessInfo.processInfo.systemUptime)
                completion(request.serial, display, current)
                return
            }
        }
    }

    @MainActor
    final class ExternalDisplayBrightnessController: NSObject {
        weak var hudController: HUDController?
        private var isRunning = false
        private var systemSleeping = false
        private var displaysSleeping = false
        private var sessionInactive = false
        private var enabled = false
        private var serial: UInt64 = 0
        private var hudTargets: [CGDirectDisplayID] = []
        private var keyTargets: [Int: [CGDirectDisplayID]] = [:]
        private lazy var worker = ExternalBrightnessWorker { [weak self] serial, display, brightness in
            Task { @MainActor [weak self] in
                guard let self, self.isRunning, self.enabled, !self.isSuspended, self.serial == serial else { return }
                self.hudController?.showBrightnessHUD(brightness: brightness, displayID: display)
            }
        }

        private var isSuspended: Bool { systemSleeping || displaysSleeping || sessionInactive }

        func start() {
            guard !isRunning else { return }
            isRunning = true
            enabled = UserDefaults.standard.bool(forKey: "brightnessEnabled")
            NotificationCenter.default.addObserver(self, selector: #selector(stateChanged(_:)), name: NSApplication.didChangeScreenParametersNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(stateChanged(_:)), name: UserDefaults.didChangeNotification, object: nil)
            let center = NSWorkspace.shared.notificationCenter
            for name in [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification,
                         NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification,
                         NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification]
            {
                center.addObserver(self, selector: #selector(stateChanged(_:)), name: name, object: nil)
            }
        }

        func preferencesDidChange() {
            handleStateChange(UserDefaults.didChangeNotification)
        }

        func stop() {
            isRunning = false
            NotificationCenter.default.removeObserver(self)
            NSWorkspace.shared.notificationCenter.removeObserver(self)
            cancelPending()
            keyTargets.removeAll()
            systemSleeping = false
            displaysSleeping = false
            sessionInactive = false
        }

        func handleKeyDown(keyCode: Int, shiftOnly: Bool, isRepeat: Bool) -> Bool {
            guard keyCode == 2 || keyCode == 3 else { return false }
            if let targets = keyTargets[keyCode] {
                // The target remains pinned until release, even if Shift or the pointer moves.
                if isRunning, enabled, !isSuspended { enqueue(keyCode: keyCode, targets: targets) }
                return true
            }
            guard isRunning, enabled, !isSuspended, shiftOnly, !isRepeat else { return false }
            let screens = NSScreen.screens.compactMap { screen -> (CGDirectDisplayID, Bool)? in
                guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                      CGDisplayIsBuiltin(number.uint32Value) == 0 else { return nil }
                return (number.uint32Value, screen.frame.contains(NSEvent.mouseLocation))
            }
            let targets = screens.sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 }
                return lhs.0 < rhs.0
            }.map(\.0)
            guard !targets.isEmpty else { return false }
            keyTargets[keyCode] = targets
            enqueue(keyCode: keyCode, targets: targets)
            return true
        }

        func handleKeyUp(keyCode: Int) -> Bool {
            keyTargets.removeValue(forKey: keyCode) != nil
        }

        private func enqueue(keyCode: Int, targets: [CGDirectDisplayID]) {
            if hudTargets != targets {
                serial &+= 1
                hudTargets = targets
            }
            worker.enqueue(candidates: targets, delta: keyCode == 2 ? 1.0 / 16.0 : -1.0 / 16.0, serial: serial)
        }

        /// A newer volume/keyboard/built-in key should not be covered by an old DDC callback.
        func suppressPendingHUD() {
            serial &+= 1
            hudTargets = []
        }

        private func cancelPending() {
            suppressPendingHUD()
            worker.invalidate()
        }

        @objc private nonisolated func stateChanged(_ notification: Notification) {
            let name = notification.name
            Task { @MainActor [weak self] in self?.handleStateChange(name) }
        }

        private func handleStateChange(_ name: Notification.Name) {
            guard isRunning else { return }
            switch name {
            case UserDefaults.didChangeNotification:
                let newEnabled = UserDefaults.standard.bool(forKey: "brightnessEnabled")
                guard enabled != newEnabled else { return }
                enabled = newEnabled
            case NSWorkspace.willSleepNotification: systemSleeping = true
            case NSWorkspace.didWakeNotification: systemSleeping = false
            case NSWorkspace.screensDidSleepNotification: displaysSleeping = true
            case NSWorkspace.screensDidWakeNotification: displaysSleeping = false
            case NSWorkspace.sessionDidResignActiveNotification: sessionInactive = true
            case NSWorkspace.sessionDidBecomeActiveNotification: sessionInactive = false
            default: break
            }
            cancelPending()
            // Preserve swallowed key releases, but cancel their old display IDs on topology changes.
            for key in Array(keyTargets.keys) { keyTargets[key] = [] }
        }
    }
#endif // !SANDBOX
