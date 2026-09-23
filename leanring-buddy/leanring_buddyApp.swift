//
//  leanring_buddyApp.swift
//  leanring-buddy
//
//  Menu bar-only companion app. No dock icon, no main window — just an
//  always-available status item in the macOS menu bar. Clicking the icon
//  opens a floating panel with companion voice controls.
//

import ServiceManagement
import SwiftUI

@main
struct leanring_buddyApp: App {
    @NSApplicationDelegateAdaptor(CompanionAppDelegate.self) var appDelegate

    var body: some Scene {
        // The app lives entirely in the menu bar panel managed by the AppDelegate.
        // This empty Settings scene satisfies SwiftUI's requirement for at least
        // one scene but is never shown (LSUIElement=true removes the app menu).
        Settings {
            EmptyView()
        }
    }
}

/// Manages the companion lifecycle: creates the menu bar panel and starts
/// the companion voice pipeline on launch.
@MainActor
final class CompanionAppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarPanelManager: MenuBarPanelManager?
    /// Created after settings are migrated, since it reads them on init.
    private var companionManager: CompanionManager!

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLogFile.redirectOutputIfNeeded()
        print("🎯 YoClicky: Starting...")
        print("🎯 YoClicky: Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")")

        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 0])
        LegacySettingsMigration.migrateIfNeeded()

        companionManager = CompanionManager()

        menuBarPanelManager = MenuBarPanelManager(companionManager: companionManager)
        companionManager.start()
        // Auto-open the panel if the user still needs to do something:
        // either they haven't onboarded yet, or permissions were revoked.
        if !companionManager.hasCompletedOnboarding || !companionManager.allPermissionsGranted {
            menuBarPanelManager?.showPanelOnLaunch()
        }
        // Launch at login is now opt-in: Settings > General.
    }

    func applicationWillTerminate(_ notification: Notification) {
        companionManager?.stop()
    }
}

/// Copies preferences saved under the app's old bundle identifier
/// (com.yourcompany.leanring-buddy, used before it became YoClicky) so
/// existing users keep their settings. Runs once.
enum LegacySettingsMigration {
    private static let legacyBundleIdentifier = "com.yourcompany.leanring-buddy"
    private static let didMigrateKey = "didMigrateLegacySettings"

    static func migrateIfNeeded() {
        let userDefaults = UserDefaults.standard
        guard !userDefaults.bool(forKey: didMigrateKey) else { return }
        userDefaults.set(true, forKey: didMigrateKey)

        guard Bundle.main.bundleIdentifier != legacyBundleIdentifier,
              let legacyPreferences = userDefaults.persistentDomain(forName: legacyBundleIdentifier),
              !legacyPreferences.isEmpty else {
            return
        }
        for (preferenceKey, preferenceValue) in legacyPreferences where userDefaults.object(forKey: preferenceKey) == nil {
            userDefaults.set(preferenceValue, forKey: preferenceKey)
        }
        print("🎯 YoClicky: migrated \(legacyPreferences.count) settings from \(legacyBundleIdentifier)")
    }
}
