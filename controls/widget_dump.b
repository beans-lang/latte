// A widget tree as text.
package controls

import std.fmt

/// Prints a widget tree the way the test goldens record it.
///
/// Useful when debugging, and load-bearing in the test suite: a native control
/// has no output to compare, but it does have a shape, a class name, an
/// accessibility role, a frame and a state, and all five are answers only the
/// real platform object can give. A tree that prints identically under the
/// interpreter and under a native build, and identically on macOS, Windows and
/// Linux, is what "write once, run anywhere" means in a form a machine can
/// check.
pub class WidgetDump {
    /// The tree under `root`, one widget per line, two spaces per level.
    pub static fn of(root: Widget) -> Result<string> {
        var out: fmt.StringBuilder = new fmt.StringBuilder()
        WidgetDump.walk(root, 0, inout out)?
        return ok(out.to_string())
    }

    static fn walk(widget: Widget, depth: int, inout out: fmt.StringBuilder) -> Result<bool> {
        var indent: int = 0
        for indent < depth {
            out.push("  ")
            indent = indent + 1
        }
        out.push(widget.describe()?)

        // The two trees are compared here, every time the dump runs. latte's
        // child list and the platform's own must agree; if they ever drift,
        // the test that prints a tree is exactly the test that should fail.
        let mine: List<Widget> = widget.children()
        let theirs: int = widget.native_child_count()?
        if mine.len() != theirs {
            return err("{widget.kind().name()} has {mine.len()} children in latte but {theirs} on the platform",
                       "tree_drift")
        }
        if theirs > 0 {
            out.push(" children={theirs}")
        }
        out.push("\n")
        for child: Widget in mine {
            WidgetDump.walk(child, depth + 1, inout out)?
        }
        return ok(true)
    }
}
