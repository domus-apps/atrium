import Testing

@testable import Atrium

@Test func nextAdvancesAndWraps() {
    #expect(SelectionCycler.next(after: 0, count: 3) == 1)
    #expect(SelectionCycler.next(after: 2, count: 3) == 0)
}

@Test func previousRecedesAndWraps() {
    #expect(SelectionCycler.previous(before: 2, count: 3) == 1)
    #expect(SelectionCycler.previous(before: 0, count: 3) == 2)
}

@Test func singleEntryCyclesToItself() {
    #expect(SelectionCycler.next(after: 0, count: 1) == 0)
    #expect(SelectionCycler.previous(before: 0, count: 1) == 0)
}

@Test func noEntriesMeansNowhereToGo() {
    #expect(SelectionCycler.next(after: 0, count: 0) == nil)
    #expect(SelectionCycler.previous(before: 0, count: 0) == nil)
}

@Test func outOfRangeIndexStillLandsInRange() {
    /* A stale index (window closed under the switcher) must not crash or
       escape the valid range. */
    #expect(SelectionCycler.next(after: 7, count: 3) == 2)
    #expect(SelectionCycler.previous(before: -1, count: 3) == 1)
}
