import AppKit
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let hotKeys = HotKeyCenter()
    private let switcher = SwitcherController()
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        ensureAccessibilityPermission()
        ensureScreenRecordingPermission()
        setUpStatusItem()
        registerShortcuts()
    }

    /* Window previews capture via ScreenCaptureKit, which sits behind the
       Screen Recording permission. Not strictly required — without it the
       switcher falls back to app icons — so only nudge, never block. The
       system prompts just once; afterwards it's a manual Settings toggle,
       and granting takes effect on the next launch. */
    private func ensureScreenRecordingPermission() {
        if !CGPreflightScreenCaptureAccess() {
            NSLog(
                "Atrium: no Screen Recording permission — window previews are "
                    + "disabled, showing app icons. Grant it in System Settings > "
                    + "Privacy & Security > Screen & System Audio Recording, then relaunch."
            )
            CGRequestScreenCaptureAccess()
        }
    }

    /* Window enumeration, raising, and the Option-release monitor all sit on
       the Accessibility API — without the grant the switcher shows nothing. */
    private func ensureAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        let trusted = AXIsProcessTrustedWithOptions(options as CFDictionary)
        NSLog("Atrium: launched from %@ — Accessibility %@.",
            Bundle.main.bundlePath, trusted ? "granted" : "NOT granted")
        if !trusted {
            NSLog(
                "Atrium: waiting for Accessibility permission. "
                    + "Grant it in System Settings > Privacy & Security > Accessibility, "
                    + "then press Option+Tab again."
            )
        }
    }

    private func registerShortcuts() {
        hotKeys.register(keyCode: UInt32(kVK_Tab), modifiers: UInt32(optionKey)) { [weak self] in
            self?.switcher.cycle(1)
        }
        hotKeys.register(
            keyCode: UInt32(kVK_Tab), modifiers: UInt32(optionKey | shiftKey)
        ) { [weak self] in
            self?.switcher.cycle(-1)
        }
        /* Option+`: the same switcher, scoped to the frontmost app's own
           windows — the panel version of the system's ⌘`. */
        hotKeys.register(
            keyCode: UInt32(kVK_ANSI_Grave), modifiers: UInt32(optionKey)
        ) { [weak self] in
            self?.switcher.cycle(1, scope: .frontmostApp)
        }
        hotKeys.register(
            keyCode: UInt32(kVK_ANSI_Grave), modifiers: UInt32(optionKey | shiftKey)
        ) { [weak self] in
            self?.switcher.cycle(-1, scope: .frontmostApp)
        }
    }

    private func setUpStatusItem() {
        /* A fixed length instead of squareLength: square items are as wide
           as the menu bar is tall, which pads a ~18pt symbol with a lot of
           dead space. 20pt hugs the icon while keeping its natural size. */
        let item = NSStatusBar.system.statusItem(withLength: 20)
        item.button?.image = NSImage(
            systemSymbolName: "square.grid.2x2", accessibilityDescription: "Atrium")

        let menu = NSMenu()
        let version =
            Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let about = NSMenuItem(title: "Atrium \(version)", action: nil, keyEquivalent: "")
        about.isEnabled = false
        menu.addItem(about)
        for hintTitle in ["Option+Tab to switch windows", "Option+` for this app's windows"] {
            let hint = NSMenuItem(title: hintTitle, action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "Quit Atrium",
            action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }
}
