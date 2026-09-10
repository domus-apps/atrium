import CoreGraphics
import Testing

@testable import Atrium

@Test func onScreenWindowsComeFrontToBack() {
    let zOrder: [CGWindowID: Int] = [10: 2, 20: 0, 30: 1]
    #expect(WindowOrdering.ordered(ids: [10, 20, 30], zOrder: zOrder) == [1, 2, 0])
}

@Test func backgroundWindowsTrailInDiscoveryOrder() {
    /* Minimized windows have no CGWindowID rank (nil or absent from the
       on-screen list) — they follow the visible ones, order preserved. */
    #expect(WindowOrdering.ordered(ids: [nil, 5, nil], zOrder: [5: 0]) == [1, 0, 2])
}

@Test func idsAbsentFromTheOnScreenListAreBackground() {
    /* A window on another Space has an ID but no on-screen rank. */
    #expect(WindowOrdering.ordered(ids: [7, 5], zOrder: [5: 0]) == [1, 0])
}

@Test func emptyInputYieldsEmptyOrder() {
    #expect(WindowOrdering.ordered(ids: [], zOrder: [:]).isEmpty)
}

// MARK: - frontmostScope(owners:frontmost:)

@Test func frontmostScopeListsTheFrontmostAppsWindows() {
    #expect(WindowOrdering.frontmostScope(owners: [10, 20, 10, 30], frontmost: 10) == [0, 2])
    #expect(WindowOrdering.frontmostScope(owners: [10, 20, 10, 30], frontmost: 30) == [3])
}

@Test func frontmostScopeFallsBackToTheTopmostWindowsApp() {
    /* The active app (99) has no windows — a windowless menu bar app. */
    #expect(WindowOrdering.frontmostScope(owners: [20, 10, 20], frontmost: 99) == [0, 2])
    #expect(WindowOrdering.frontmostScope(owners: [20, 10, 20], frontmost: nil) == [0, 2])
}

@Test func frontmostScopeIsEmptyWithoutWindows() {
    #expect(WindowOrdering.frontmostScope(owners: [], frontmost: 42).isEmpty)
}
