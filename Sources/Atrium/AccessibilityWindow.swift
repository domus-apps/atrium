import AppKit
import ApplicationServices

/* Private but long-stable HIServices symbol that maps an AXWindow element to
   its CGWindowID. It is the only way to correlate AX windows (which know
   about minimized windows) with the CGWindowList (which knows the z-order);
   every switcher of this kind (AltTab, alt-tab-macos forks) relies on it. */
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(
    _ element: AXUIElement, _ identifier: UnsafeMutablePointer<CGWindowID>
) -> AXError

/* Thin wrapper over an AXUIElement of role AXWindow, scoped to what the
   switcher needs: identity, display metadata, and bringing a window (even a
   minimized one) to the front. */
struct AccessibilityWindow {
    let element: AXUIElement

    /// All AX windows of one app, minimized ones included — which is exactly
    /// what CGWindowList can't provide.
    static func windows(of pid: pid_t) -> [AccessibilityWindow] {
        let appElement = AXUIElementCreateApplication(pid)
        /* An unresponsive app must not stall the switcher: the default AX
           messaging timeout is several seconds per call, and enumeration
           touches every running app. */
        AXUIElementSetMessagingTimeout(appElement, 0.25)
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                appElement, kAXWindowsAttribute as CFString, &value) == .success,
            let array = value as? [AnyObject]
        else { return [] }
        return array.compactMap { item in
            guard CFGetTypeID(item) == AXUIElementGetTypeID() else { return nil }
            return AccessibilityWindow(element: unsafeDowncast(item, to: AXUIElement.self))
        }
    }

    var title: String? {
        copyValue(kAXTitleAttribute) as? String
    }

    var subrole: String? {
        copyValue(kAXSubroleAttribute) as? String
    }

    var isMinimized: Bool {
        copyValue(kAXMinimizedAttribute) as? Bool ?? false
    }

    var windowID: CGWindowID? {
        var id = CGWindowID(0)
        guard _AXUIElementGetWindow(element, &id) == .success, id != 0 else { return nil }
        return id
    }

    /// Brings the window to the front and gives it focus, restoring it first
    /// if it is minimized and unhiding the app if it is hidden.
    func focus(activating app: NSRunningApplication) {
        if isMinimized {
            AXUIElementSetAttributeValue(
                element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        if app.isHidden {
            app.unhide()
        }
        /* Raise + mark main before activating: activation alone brings the
           app's previously frontmost window forward, not necessarily the one
           the user picked. */
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        app.activate(options: [])
    }

    private func copyValue(_ attribute: String) -> AnyObject? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value
    }
}
