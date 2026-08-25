/// Pure switcher arithmetic: which entry a cycle keypress lands on.
/// Kept free of AppKit so the wraparound edge cases stay testable.
enum SelectionCycler {
    /// Index of the entry after `index`, wrapping past the end.
    /// `nil` when there are no entries.
    static func next(after index: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        return mod(index + 1, count)
    }

    /// Index of the entry before `index`, wrapping past the start.
    /// `nil` when there are no entries.
    static func previous(before index: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        return mod(index - 1, count)
    }

    /// True modulo — non-negative even for negative operands, unlike `%`.
    private static func mod(_ a: Int, _ n: Int) -> Int {
        ((a % n) + n) % n
    }
}
