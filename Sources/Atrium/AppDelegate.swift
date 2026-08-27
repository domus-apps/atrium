import AppKit
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let hotKeys = HotKeyCenter()
    private let switcher = SwitcherController()
    private let updater = UpdaterController()
    private var statusItem: NSStatusItem?
    private var settingsWindowController: SettingsWindowController?
    private var onboardingController: OnboardingWindowController?

    private static let onboardingCompletedKey = "onboarding.completed"

    func applicationDidFinishLaunching(_ notification: Notification) {
        /* A translocated launch relaunches itself from the real bundle —
           nothing else must start in this doomed instance. */
        if TranslocationHealer.healIfNeeded() { return }

        setUpMainMenu()
        observePreferenceChanges()
        updateStatusItemVisibility()
        registerShortcuts()

        if CommandLine.arguments.contains("--settings") {
            openSettings()
        }

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

    /* Launching the app again while it's already running sends "reopen" to
       the live instance. With the menu bar icon hidden this is the only way
       back into the UI, so surface Settings (which also puts the app in the
       Dock via updateActivationPolicy). */
    func applicationShouldHandleReopen(
        _ sender: NSApplication, hasVisibleWindows: Bool
    ) -> Bool {
        if AppPreferences.isMenuBarIconHidden {
            openSettings()
        }
        return false
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
        let settingsItem = NSMenuItem(
            title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
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
        let settingsMenuItem = NSMenuItem(
            title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsMenuItem.target = self
        menu.addItem(settingsMenuItem)
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

    private func observePreferenceChanges() {
        NotificationCenter.default.addObserver(
            forName: AppPreferences.changed, object: nil, queue: .main
        ) { [weak self] _ in
            self?.updateStatusItemVisibility()
        }
    }

    private func updateStatusItemVisibility() {
        if AppPreferences.isMenuBarIconHidden {
            if let statusItem {
                NSStatusBar.system.removeStatusItem(statusItem)
            }
            statusItem = nil
        } else if statusItem == nil {
            setUpStatusItem()
        }
        updateActivationPolicy()
    }

    private var isSettingsWindowVisible: Bool {
        settingsWindowController?.window?.isVisible == true
    }

    /* Dock presence: the app normally stays invisible (accessory policy),
       but while the menu bar icon is hidden AND Settings is open there would
       be no sign the app is running — so it joins the Dock for the duration
       and leaves again when the settings window closes. */
    private func updateActivationPolicy() {
        let wantsDock = AppPreferences.isMenuBarIconHidden && isSettingsWindowVisible
        let policy: NSApplication.ActivationPolicy = wantsDock ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        /* Flipping the policy can drop activation; keep Settings in front. */
        if isSettingsWindowVisible {
            NSApp.activate(ignoringOtherApps: true)
            settingsWindowController?.window?.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func openSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(updater: updater)
            if let window = settingsWindowController?.window {
                NotificationCenter.default.addObserver(
                    forName: NSWindow.willCloseNotification, object: window, queue: .main
                ) { [weak self] _ in
                    /* isVisible is still true inside willClose; re-evaluate
                       (and leave the Dock) on the next runloop cycle. */
                    DispatchQueue.main.async { self?.updateActivationPolicy() }
                }
            }
        }
        /* Accessory apps don't come forward on their own — activate first or
           the window opens behind the current app. */
        NSApp.activate(ignoringOtherApps: true)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
        updateActivationPolicy()
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
