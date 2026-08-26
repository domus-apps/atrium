import AppKit
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let hotKeys = HotKeyCenter()
    private let switcher = SwitcherController()
    private let updater = UpdaterController()
    private var statusItem: NSStatusItem?
    private var onboardingController: OnboardingWindowController?

    private static let onboardingCompletedKey = "onboarding.completed"

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpMainMenu()
        setUpStatusItem()
        registerShortcuts()

        /* The permission asks live inside onboarding — no launch-time
           prompts. Completion is only recorded when onboarding is finished
           properly, so an interrupted (or force-quit) run shows it again. */
        if !UserDefaults.standard.bool(forKey: Self.onboardingCompletedKey)
            || CommandLine.arguments.contains("--onboarding")
        {
            showOnboarding()
        }

        /* Same report as the menu's Copy Diagnostics, to stdout. */
        if CommandLine.arguments.contains("--diagnose") {
            Task {
                print(await PreviewLoader.diagnostics())
                await MainActor.run { NSApp.terminate(nil) }
            }
        }
    }

    private func showOnboarding() {
        if onboardingController == nil {
            onboardingController = OnboardingWindowController { [weak self] in
                UserDefaults.standard.set(true, forKey: Self.onboardingCompletedKey)
                self?.onboardingController = nil
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        onboardingController?.window?.makeKeyAndOrderFront(nil)
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

    /* An accessory app has no visible menu bar, but ⌘-key equivalents are
       still dispatched through the main menu — without one, ⌘Q does nothing
       while the onboarding window is frontmost. */
    private func setUpMainMenu() {
        let appMenu = NSMenu()
        appMenu.addItem(updater.makeMenuItem())
        appMenu.addItem(.separator())
        appMenu.addItem(
            NSMenuItem(
                title: "Quit Atrium",
                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        let mainMenu = NSMenu()
        let item = NSMenuItem()
        item.submenu = appMenu
        mainMenu.addItem(item)
        NSApp.mainMenu = mainMenu
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
        let onboardingItem = NSMenuItem(
            title: "Show Welcome Guide…", action: #selector(reopenOnboarding),
            keyEquivalent: "")
        onboardingItem.target = self
        menu.addItem(onboardingItem)
        menu.addItem(updater.makeMenuItem())
        /* Remote-debugging aid: one click copies a preview-capture report
           (permission state and a per-window verdict) for pasting back. */
        let diagnosticsItem = NSMenuItem(
            title: "Copy Diagnostics", action: #selector(copyDiagnostics), keyEquivalent: "")
        diagnosticsItem.target = self
        menu.addItem(diagnosticsItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "Quit Atrium",
            action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }

    @objc private func reopenOnboarding() {
        showOnboarding()
    }

    @objc private func copyDiagnostics() {
        Task {
            let report = await PreviewLoader.diagnostics()
            await MainActor.run {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(report, forType: .string)
                NSSound(named: "Glass")?.play()
            }
        }
    }
}
