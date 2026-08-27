import Foundation

/* App-level preferences. Same UserDefaults caveat as the rest of the app:
   `swift run` and the bundled app use different defaults domains. */
enum AppPreferences {
    static let changed = Notification.Name("Atrium.PreferencesChanged")

    private static let hideMenuBarIconKey = "pref.hideMenuBarIcon"

    static var isMenuBarIconHidden: Bool {
        get { UserDefaults.standard.bool(forKey: hideMenuBarIconKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: hideMenuBarIconKey)
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }
}
