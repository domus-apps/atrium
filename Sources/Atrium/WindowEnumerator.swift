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

/// Pure ordering core, kept free of AppKit/AX so it stays testable. Windows
/// the user has focused come first, most recent first (the topmost on-screen
/// window is pinned to the front in case the history missed a change); then
/// on-screen windows never focused, in z-order; then everything the window
/// server doesn't show — minimized windows, hidden apps, other Spaces — in
/// discovery order.
enum WindowOrdering {
    /// Returns indices into `ids` in switcher order. `zOrder` maps a
    /// CGWindowID to its front-to-back rank, `recency` to its focus-history
    /// rank (0 = focused most recently); ids in neither keep their relative
    /// order at the end.
    static func ordered(
        ids: [CGWindowID?], zOrder: [CGWindowID: Int], recency: [CGWindowID: Int] = [:]
    ) -> [Int] {
        var recent: [(rank: Int, index: Int)] = []
        var onScreen: [(order: Int, index: Int)] = []
        var background: [Int] = []
        for (index, id) in ids.enumerated() {
            if let id, let rank = recency[id] {
                recent.append((rank, index))
            } else if let id, let order = zOrder[id] {
                onScreen.append((order, index))
            } else {
                background.append(index)
            }
        }
        var result = recent.sorted { $0.rank < $1.rank }.map(\.index)
        if let top = ids.indices.min(by: { a, b in
            (ids[a].flatMap { zOrder[$0] } ?? .max) < (ids[b].flatMap { zOrder[$0] } ?? .max)
        }), ids[top].flatMap({ zOrder[$0] }) != nil, let at = result.firstIndex(of: top), at != 0 {
            result.remove(at: at)
            result.insert(top, at: 0)
        }
        return result + onScreen.sorted { $0.order < $1.order }.map(\.index) + background
    }

    /// Indices of the windows to list for the frontmost-app scope (Option+`).
    /// `owners` holds each window's owning pid in switcher order, so the first
    /// entry belongs to the topmost window on screen. The frontmost app is
    /// whatever the system reports, but that can be an app with no windows at
    /// all: a menu bar app that activated itself to show its settings stays
    /// the active app after the window closes, because macOS never moves
    /// activation on window close. Listing nothing there made the shortcut
    /// look dead (only quitting the windowless app "fixed" it), so fall back
    /// to the app owning the topmost window — the app the user sees as front.
    static func frontmostScope(owners: [pid_t], frontmost: pid_t?) -> [Int] {
        if let frontmost {
            let own = owners.indices.filter { owners[$0] == frontmost }
            if !own.isEmpty { return own }
        }
        guard let top = owners.first else { return [] }
        return owners.indices.filter { owners[$0] == top }
    }
}

enum WindowEnumerator {
    /// Every switchable window of every regular app, front-to-back, with
    /// minimized/hidden/off-Space windows trailing.
    static func list(recency: [CGWindowID: Int] = [:]) -> [SwitcherWindow] {
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
        let order = WindowOrdering.ordered(
            ids: candidates.map(\.windowID), zOrder: zOrder, recency: recency)
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
