// 1. Repeating the type parameter on the continuation.
package pages

partial class Grid<T> {
    pub fn count_repeats() -> int { return self.rows.len() }
}
