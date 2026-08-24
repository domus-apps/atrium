import Testing

@testable import Atrium

@Test func nextAdvancesAndWraps() {
    #expect(SpaceCycler.next(after: 0, count: 3) == 1)
    #expect(SpaceCycler.next(after: 2, count: 3) == 0)
}

@Test func previousRecedesAndWraps() {
    #expect(SpaceCycler.previous(before: 2, count: 3) == 1)
    #expect(SpaceCycler.previous(before: 0, count: 3) == 2)
}

@Test func singleSpaceCyclesToItself() {
    #expect(SpaceCycler.next(after: 0, count: 1) == 0)
    #expect(SpaceCycler.previous(before: 0, count: 1) == 0)
}

@Test func noSpacesMeansNowhereToGo() {
    #expect(SpaceCycler.next(after: 0, count: 0) == nil)
    #expect(SpaceCycler.previous(before: 0, count: 0) == nil)
}

@Test func outOfRangeIndexStillLandsInRange() {
    /* A stale index (space closed under the switcher) must not crash or
       escape the valid range. */
    #expect(SpaceCycler.next(after: 7, count: 3) == 2)
    #expect(SpaceCycler.previous(before: -1, count: 3) == 1)
}
