// Retro HUD by Patrick Bösch (2026)
// MIT License

import Foundation

enum RetroHUDIdentity {
    static let name = "Retro HUD"
    // This existing GitHub URL continues to redirect after the repository is renamed.
    static let repositoryURL = URL(string: "https://github.com/patrick-boesch/volumeHUD")!
    static let upstreamURL = URL(string: "https://github.com/dannystewart/volumeHUD")!

    // Retained only for compatibility: changing bundle identity resets preferences, TCC and login registration.
    static let compatibleBundleIdentifiers: Set<String> = [
        "com.dannystewart.volumehud", "com.dannystewart.volumehud.debug",
        "com.dannystewart.volumehud.mas", "com.dannystewart.volumehud.mas.debug",
    ]
}

enum RetroHUDPreferences {
    static let volume = "volumeEnabled"
    static let brightness = "brightnessEnabled"
    static let keyboard = "keyboardBrightnessEnabled"
    static let followMouse = "hudFollowsMouse"
    static let relativePosition = "useRelativePositioning"
    static let launchNotification = "showLaunchNotification"

    static func prepare(_ defaults: UserDefaults = .standard) {
        // Preserve the old placement choice while removing the product name from the setting key.
        if defaults.object(forKey: followMouse) == nil,
           let oldValue = defaults.object(forKey: "volumeHUDFollowsMouse") as? Bool
        {
            defaults.set(oldValue, forKey: followMouse)
        }
        defaults.register(defaults: [
            volume: true, brightness: false, keyboard: true,
            followMouse: true, relativePosition: true, launchNotification: false,
        ])
    }
}
