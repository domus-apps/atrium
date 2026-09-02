import AppKit

/// One entry in the switcher: a window plus everything the panel needs to
/// draw it and the controller needs to focus it.
struct SwitcherWindow {
    let app: NSRunningApplication
    let window: AccessibilityWindow
    let windowID: CGWindowID?
    let title: String
    /// True for minimized windows and windows of hidden (⌘H) apps — both are
    /// invisible on screen and drawn dimmed in the panel.
    let isBackground: Bool
    /// Minimized specifically (a subset of isBackground): marked with the
    /// Window-menu diamond in the panel.
    let isMinimized: Bool

    func focus() {
        window.focus(activating: app)
    }
}

/// Pure ordering core, kept free of AppKit/AX so it stays testable: on-screen
/// windows come first in z-order (front to back), everything the window
/// server doesn't show — minimized windows, hidden apps, other Spaces —
/// follows in discovery order.
enum WindowOrdering {
    /// Returns indices into `ids` in switcher order. `zOrder` maps a
    /// CGWindowID to its front-to-back rank; ids that are `nil` or absent
    /// from the map keep their relative order at the end.
    static func ordered(ids: [CGWindowID?], zOrder: [CGWindowID: Int]) -> [Int] {
        var onScreen: [(order: Int, index: Int)] = []
        var background: [Int] = []
        for (index, id) in ids.enumerated() {
            if let id, let order = zOrder[id] {
                onScreen.append((order, index))
            } else {
                background.append(index)
            }
        }
        return onScreen.sorted { $0.order < $1.order }.map(\.index) + background
    }
}

enum WindowEnumerator {
    /// Every switchable window of every regular app, front-to-back, with
    /// minimized/hidden/off-Space windows trailing.
    static func list() -> [SwitcherWindow] {
        let zOrder = onScreenZOrder()
        var candidates: [SwitcherWindow] = []
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && !app.isTerminated {
            /* Skip ourselves — the switcher panel must never list itself. */
            guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier
            else { continue }
            for window in AccessibilityWindow.windows(of: app.processIdentifier) {
                guard isSwitchable(window) else { continue }
                let title = window.title ?? ""
                let minimized = window.isMinimized
                candidates.append(
                    SwitcherWindow(
                        app: app,
                        window: window,
                        windowID: window.windowID,
                        title: title.isEmpty ? (app.localizedName ?? "Window") : title,
                        isBackground: minimized || app.isHidden,
                        isMinimized: minimized
                    ))
            }
        }
        let order = WindowOrdering.ordered(ids: candidates.map(\.windowID), zOrder: zOrder)
        return order.map { candidates[$0] }
    }

    /* Panels, popovers, and toolbars also come back from kAXWindows; only
       document-style windows belong in a switcher. */
    private static func isSwitchable(_ window: AccessibilityWindow) -> Bool {
        guard let subrole = window.subrole else { return false }
        return subrole == kAXStandardWindowSubrole as String
            || subrole == kAXDialogSubrole as String
    }

    /* Front-to-back rank of every window the window server is currently
       showing. Layer 0 filters out the menu bar, Dock, and other system
       chrome that shares the on-screen list. */
    private static func onScreenZOrder() -> [CGWindowID: Int] {
        let info =
            CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: AnyObject]] ?? []
        var order: [CGWindowID: Int] = [:]
        for (rank, entry) in info.enumerated() {
            guard
                let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
                let number = entry[kCGWindowNumber as String] as? NSNumber
            else { continue }
            order[CGWindowID(truncating: number)] = rank
        }
        return order
    }
}
