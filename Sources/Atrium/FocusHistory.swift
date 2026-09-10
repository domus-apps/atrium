import AppKit
import ApplicationServices

/* Most-recently-focused window history, the order the switcher lists windows
   in. The window server's z-order alone is the wrong signal: activating an
   app from the Dock or ⌘Tab brings every one of its windows forward, so four
   VS Code windows would all jump ahead of the Chrome window the user came
   from, even though three of them were never looked at. Focus is tracked by
   observing the active app's focused-window changes through Accessibility,
   which is exactly the event the user perceives as "I went to that window". */
final class FocusHistory {
    private static let capacity = 256

    /// Window IDs, most recently focused first.
    private(set) var recent: [CGWindowID] = []

    private var observer: AXObserver?
    private var observedApp: AXUIElement?
    private var observedPid: pid_t = 0

    init() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication
            else { return }
            self?.follow(app.processIdentifier)
        }
        if let front = NSWorkspace.shared.frontmostApplication {
            follow(front.processIdentifier)
        }
    }

    /// Recency rank per window: 0 is the focused window, 1 the one before it…
    func ranks() -> [CGWindowID: Int] {
        var ranks: [CGWindowID: Int] = [:]
        for (rank, id) in recent.enumerated() { ranks[id] = rank }
        return ranks
    }

    func note(_ id: CGWindowID) {
        recent.removeAll { $0 == id }
        recent.insert(id, at: 0)
        if recent.count > Self.capacity { recent.removeLast() }
    }

    /* Re-point the AX observer at the newly active app. Observing needs the
       Accessibility permission; before it is granted every attempt fails
       quietly and the switcher simply keeps the z-order fallback. */
    private func follow(_ pid: pid_t) {
        guard pid != ProcessInfo.processInfo.processIdentifier, pid != observedPid else {
            recordFocusedWindow()
            return
        }
        stopObserving()
        observedPid = pid
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.25)
        observedApp = appElement

        var created: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            Unmanaged<FocusHistory>.fromOpaque(refcon).takeUnretainedValue().recordFocusedWindow()
        }
        guard AXObserverCreate(pid, callback, &created) == .success, let created else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification] {
            AXObserverAddNotification(created, appElement, name as CFString, refcon)
        }
        CFRunLoopAddSource(
            CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
        observer = created

        /* Activation itself changes no focus inside the app, so no AX event
           follows it — read the focused window now, and once more shortly
           after in case the app is still settling its key window. */
        recordFocusedWindow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, observedPid == pid else { return }
            recordFocusedWindow()
        }
    }

    private func stopObserving() {
        if let observer {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
            if let observedApp {
                for name in [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification] {
                    AXObserverRemoveNotification(observer, observedApp, name as CFString)
                }
            }
        }
        observer = nil
        observedApp = nil
        observedPid = 0
    }

    private func recordFocusedWindow() {
        guard let observedApp else { return }
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                observedApp, kAXFocusedWindowAttribute as CFString, &value) == .success,
            let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return }
        let window = AccessibilityWindow(element: unsafeDowncast(value, to: AXUIElement.self))
        if let id = window.windowID {
            note(id)
        }
    }
}
