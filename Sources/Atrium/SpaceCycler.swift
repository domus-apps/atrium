/// Pure task-space arithmetic: which space a cycle shortcut lands on.
/// The space switcher (not built yet) will drive this; keeping it pure
/// keeps the wraparound edge cases testable.
enum SpaceCycler {
    /// Index of the space after `index`, wrapping past the end.
    /// `nil` when there are no spaces.
    static func next(after index: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        return mod(index + 1, count)
    }

    /// Index of the space before `index`, wrapping past the start.
    /// `nil` when there are no spaces.
    static func previous(before index: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        return mod(index - 1, count)
    }

    /// True modulo — non-negative even for negative operands, unlike `%`.
    private static func mod(_ a: Int, _ n: Int) -> Int {
        ((a % n) + n) % n
    }
}
