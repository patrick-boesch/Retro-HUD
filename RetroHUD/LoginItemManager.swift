//
//  LoginItemManager.swift
//  Retro HUD additions by Patrick Bösch (2026)
//  Based on volumeHUD by Danny Stewart (2025)
//  MIT License
//  https://github.com/dannystewart/volumeHUD
//

import Combine
import Foundation
import ServiceManagement

// MARK: - LoginItemManager

/// Manages login item functionality using the modern SMAppService API.
@MainActor
class LoginItemManager: ObservableObject {
    @Published var isEnabled: Bool = false
    @Published private(set) var lastError: String?

    private let logger: Logger = .init()

    private var isUpdatingFromSystem = false

    private var service: SMAppService {
        SMAppService.mainApp
    }

    init() {
        updateStatus()
    }

    /// Updates the current login item status from the system
    func updateStatus() {
        isUpdatingFromSystem = true
        isEnabled = service.status == .enabled
        isUpdatingFromSystem = false
        logger.debug("Login item status: \(service.status)")
    }

    var requiresApproval: Bool { service.status == .requiresApproval }

    /// Sets the login item state
    func setEnabled(_ enabled: Bool) {
        guard !isUpdatingFromSystem else { return }
        if enabled, service.status == .enabled { return }
        if !enabled, service.status == .notRegistered { return }

        do {
            if enabled {
                try service.register()
                logger.info("Login item enabled.")
            } else {
                try service.unregister()
                logger.info("Login item disabled.")
            }
            lastError = nil
            updateStatus()
        } catch {
            logger.error("Failed to set login item: \(error)")
            lastError = error.localizedDescription
            updateStatus()
        }
    }
}

