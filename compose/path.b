// Where in the tree something is.
package compose

/// The child indices that reach one element from the root.
///
/// Mutable and shared, pushed and popped as the differ walks: a fresh list per
/// node would allocate once per element per render, and `List` is move-only so
/// passing one down a recursion is a fight with the ownership checker at every
/// level. `snapshot()` is what gets stored on a `Change`, and that copy is the
/// only one that outlives the walk.
class Path {
    steps: List<int> = []

    fn init() {}

    fn push(step: int) {
        self.steps.push(step)
    }

    fn pop() {
        if self.steps.len() > 0 {
            self.steps.remove(self.steps.len() - 1)
        }
    }

    fn depth() -> int {
        return self.steps.len()
    }

    fn snapshot() -> List<int> {
        var out: List<int> = []
        for step: int in self.steps {
            out.push(step)
        }
        return move out
    }
}
