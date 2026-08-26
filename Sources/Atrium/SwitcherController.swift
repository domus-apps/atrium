import AppKit
import Carbon.HIToolbox

/* The switcher's lifecycle: first Option+Tab snapshots the window list and
   shows the panel, further presses (Shift for backwards) move the selection,
   releasing Option commits to the selected window, Escape cancels. */
final class SwitcherController {
    /// What the switcher lists: every window of every app (Option+Tab), or
    /// only the frontmost app's windows (Option+`, like the system's ⌘`).
    enum Scope {
        case allWindows
        case frontmostApp
    }

    private let panel = SwitcherPanel()
    /* Escape only means "cancel" while the panel is up; registering it
       permanently would swallow the key system-wide. A dedicated center makes
       releasing it on hide a plain unregisterAll. */
    private let transientHotKeys = HotKeyCenter()
    private var windows: [SwitcherWindow] = []
    private var selection = 0
    private var flagsMonitors: [Any] = []
    private var previewTask: Task<Void, Never>?
    private var repeatTimer: Timer?
    private var nextRepeatAt: Date?
    private var heldRepeatKey: Int?
    private var mouseAtShow = NSPoint.zero

    init() {
        panel.onItemClick = { [weak self] index in
            self?.selection = index
            self?.commit()
        }
        /* Hover moves the selection — but only once the cursor has actually
           moved (however slightly) since the panel appeared. The panel opens
           centered under wherever the cursor happens to sit; a stationary
           cursor must not steal the selection, or a quick Option+Tab with
           the mouse parked over the panel would stop going to the previous
           window. */
        panel.onItemHover = { [weak self] index in
            guard let self, panel.isPresented else { return }
            let mouse = NSEvent.mouseLocation
            guard hypot(mouse.x - mouseAtShow.x, mouse.y - mouseAtShow.y) > 2 else { return }
            guard selection != index else { return }
            selection = index
            panel.select(index)
        }
        /* Pre-warm shortly after launch: lay the dormant panel out at its
           real size (so the first show doesn't resize the glass and flash
           stock material) and prime the AX connections that make the first
           enumeration slow. Skipped when Accessibility isn't granted yet —
           the list comes back empty. */
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, !panel.isPresented else { return }
            let windows = WindowEnumerator.list()
            guard !windows.isEmpty, let screen = screenUnderMouse() else { return }
            panel.preLayout(windows: windows, on: screen)
        }
    }

    func cycle(_ step: Int, scope: Scope = .allWindows) {
        /* Once the panel is up, every cycle key just moves the selection
           within the list it opened with — the scope only picks what to
           list when opening. */
        if panel.isPresented {
            advance(step)
            return
        }

        /* The TCC grant is per-binary, so it's easy to end up with the
           hotkey firing but enumeration returning nothing (permission was
           given to the dev binary, not the bundle, or vice versa). Since the
           user is actively invoking the switcher, re-prompt right here
           instead of failing silently. */
        guard AXIsProcessTrusted() else {
            NSLog("Atrium: hotkey fired but Accessibility is not granted to this binary — prompting.")
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            AXIsProcessTrustedWithOptions(options as CFDictionary)
            return
        }

        var list = WindowEnumerator.list()
        if scope == .frontmostApp {
            guard let frontmost = NSWorkspace.shared.frontmostApplication else { return }
            list = list.filter {
                $0.app.processIdentifier == frontmost.processIdentifier
            }
        }
        windows = list
        guard !windows.isEmpty, let screen = screenUnderMouse() else { return }
        /* Start one step in, not at the frontmost window: a quick tap should
           land on the window you were just in, like the system switcher. */
        selection = landing(from: 0, step: step)
        mouseAtShow = NSEvent.mouseLocation
        panel.show(windows: windows, selectedIndex: selection, on: screen)
        previewTask = PreviewLoader.load(
            for: windows, isCompleteList: scope == .allWindows
        ) { [weak self] index, image in
            self?.panel.setPreview(image, at: index)
        }
        installOptionReleaseMonitors()
        registerTransientKeys()
        startRepeatTimer()
        /* A fast tap can release Option before the monitors exist — the
           release event is already gone, so check the live modifier state.
           Asking the event system (not NSEvent.modifierFlags, which is
           derived from this app's own event stream and stays stale/empty in
           a background app that never receives key events). */
        if !CGEventSource.flagsState(.combinedSessionState).contains(.maskAlternate) {
            commit()
        }
    }

    private func advance(_ step: Int) {
        selection = landing(from: selection, step: step)
        panel.select(selection)
    }

    /* Arrow up/down: one visual row at a time, stopping at the edges (a
       vertical wraparound would feel like teleporting in a grid). The panel
       resolves the target geometrically — rows are centered, so "the item
       above" is a matter of on-screen position, not index arithmetic. */
    private func moveRow(_ step: Int) {
        guard let target = panel.itemIndex(rowStep: step, from: selection) else { return }
        selection = target
        panel.select(selection)
    }

    /* Escape and the arrows must match the keystroke as typed, and while
       the switcher is up Option (and possibly Shift, for backwards cycling)
       is still held — so cover every modifier state the gesture can be in.
       All of these are transient: registered only while the panel is up,
       so they never swallow keys system-wide otherwise. */
    private func registerTransientKeys() {
        let bindings: [(Int, () -> Void)] = [
            (kVK_Escape, { [weak self] in self?.cancel() }),
            (kVK_LeftArrow, { [weak self] in self?.advance(-1) }),
            (kVK_RightArrow, { [weak self] in self?.advance(1) }),
            (kVK_UpArrow, { [weak self] in self?.moveRow(-1) }),
            (kVK_DownArrow, { [weak self] in self?.moveRow(1) }),
            /* Return commits to the highlighted window, like clicking it. */
            (kVK_Return, { [weak self] in self?.commit() }),
            (kVK_ANSI_KeypadEnter, { [weak self] in self?.commit() }),
        ]
        for (keyCode, handler) in bindings {
            for modifiers in [UInt32(optionKey), UInt32(optionKey | shiftKey), 0] {
                transientHotKeys.register(
                    keyCode: UInt32(keyCode), modifiers: modifiers, handler: handler)
            }
        }
    }

    /* Carbon hotkeys fire once per press — no autorepeat events — so
       holding a cycle key (Tab, `, or an arrow) is detected by polling its
       physical state while the panel is up, mimicking the system repeat
       feel (an initial delay, then a steady cadence). Shift is read per
       repeat, so pressing or releasing it mid-hold flips the Tab direction
       immediately. */
    private func startRepeatTimer() {
        nextRepeatAt = nil
        heldRepeatKey = nil
        /* The tick quantizes the repeat interval, so it must be well finer
           than the cadence for the cadence to be real. */
        repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) {
            [weak self] _ in
            guard let self else { return }
            guard let held = heldRepeatAction() else {
                heldRepeatKey = nil
                nextRepeatAt = nil
                return
            }
            let now = Date()
            if held.key != heldRepeatKey || nextRepeatAt == nil {
                /* Fresh hold (or the held key changed): the press itself
                   already acted via its hotkey — just start the clock. */
                heldRepeatKey = held.key
                nextRepeatAt = now.addingTimeInterval(0.3)
                return
            }
            if let due = nextRepeatAt, now >= due {
                held.run()
                nextRepeatAt = now.addingTimeInterval(0.07)
            }
        }
    }

    /// The repeat-eligible key currently held, with its per-repeat action.
    /// First match wins when several are down at once.
    private func heldRepeatAction() -> (key: Int, run: () -> Void)? {
        func down(_ key: Int) -> Bool {
            CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(key))
        }
        if down(kVK_Tab) || down(kVK_ANSI_Grave) {
            let backward = CGEventSource.flagsState(.combinedSessionState)
                .contains(.maskShift)
            return (kVK_Tab, { [weak self] in self?.advance(backward ? -1 : 1) })
        }
        if down(kVK_LeftArrow) { return (kVK_LeftArrow, { [weak self] in self?.advance(-1) }) }
        if down(kVK_RightArrow) { return (kVK_RightArrow, { [weak self] in self?.advance(1) }) }
        if down(kVK_UpArrow) { return (kVK_UpArrow, { [weak self] in self?.moveRow(-1) }) }
        if down(kVK_DownArrow) { return (kVK_DownArrow, { [weak self] in self?.moveRow(1) }) }
        return nil
    }

    private func landing(from index: Int, step: Int) -> Int {
        let next =
            step > 0
            ? SelectionCycler.next(after: index, count: windows.count)
            : SelectionCycler.previous(before: index, count: windows.count)
        return next ?? 0
    }

    /* The commit gesture is releasing Option. The panel never has keyboard
       focus, so the release is only observable through event monitors —
       global for when another app is focused (the usual case), local in
       case an event is routed to us. */
    private func installOptionReleaseMonitors() {
        let handleFlags: (NSEvent) -> Void = { [weak self] event in
            if !event.modifierFlags.contains(.option) {
                self?.commit()
            }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(
            matching: .flagsChanged, handler: handleFlags)
        {
            flagsMonitors.append(global)
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            handleFlags(event)
            return event
        }
        if let local {
            flagsMonitors.append(local)
        }
    }

    private func commit() {
        let target = windows.indices.contains(selection) ? windows[selection] : nil
        hide()
        target?.focus()
    }

    private func cancel() {
        hide()
    }

    private func hide() {
        previewTask?.cancel()
        previewTask = nil
        repeatTimer?.invalidate()
        repeatTimer = nil
        nextRepeatAt = nil
        heldRepeatKey = nil
        for monitor in flagsMonitors {
            NSEvent.removeMonitor(monitor)
        }
        flagsMonitors.removeAll()
        transientHotKeys.unregisterAll()
        panel.dismiss()
        windows = []
    }

    private func screenUnderMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
    }
}
