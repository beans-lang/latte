// Everything that holds children, and the one place that logic lives.
package controls

import latte.scene

/// A widget with a child list.
///
/// Abstract, because "a thing that holds children" is not a control — `Container` is the plain one
/// and `GroupBox` is the titled one, and the only difference between them is
/// the kind they are built as and the words on the frame. Everything else —
/// the list, the ordering, the platform calls, the lifetime — is here, so
/// there is one copy of it rather than one per kind that holds children.
///
/// A box owns its children: it holds a Beans reference to each, so the subtree
/// stays alive exactly as long as the box does. The platform's own view
/// hierarchy mirrors that, it does not drive it — which is what keeps one
/// lifetime story instead of two that can disagree.
pub abstract class ChildHolder extends Widget implements Holder {
    contents: List<Widget> = []

    fn init(kind: WidgetKind, context: scene.UiContext) {
        super.init(kind, context)
    }

    /// A copy of the child list, so a caller walking the tree cannot mutate
    /// it underneath the container.
    pub override fn children() -> List<Widget> {
        var copy: List<Widget> = []
        for child: Widget in self.contents {
            copy.push(child)
        }
        return move copy
    }

    pub fn count() -> int {
        return self.contents.len()
    }

    pub fn child_at(index: int) -> Option<Widget> {
        if index < 0 || index >= self.contents.len() {
            return none
        }
        return some(self.contents[index])
    }

    /// Appends `child`.
    pub fn add(child: Widget) -> Result<bool> {
        return self.insert(child, self.contents.len())
    }

    pub fn insert(child: Widget, index: int) -> Result<bool> {
        if index < 0 || index > self.contents.len() {
            return err("cannot insert a {child.kind().name()} at {index}: this container has {self.contents.len()} children",
                       "out_of_range")
        }
        self.attach_child(child, index)?
        self.contents.insert(index, child)
        return ok(true)
    }

    pub fn remove(index: int) -> Result<bool> {
        if index < 0 || index >= self.contents.len() {
            return err("cannot remove child {index}: this container has {self.contents.len()} children",
                       "out_of_range")
        }
        let child: Widget = self.contents[index]
        self.detach_child(child)?
        self.contents.remove(index)
        return ok(true)
    }

    /// Moves the child at `from` to `to`, in one host call.
    ///
    /// Removing and re-inserting is not the same thing. GTK4 finalizes a
    /// widget the instant its last reference drops on unparent, and AppKit
    /// takes first-responder status away from a view that leaves its superview
    /// — so a list that reorders while someone is typing in it would lose
    /// either the row or the caret. The host does whichever dance its platform
    /// needs; this stays one call so it cannot be got wrong from up here.
    pub fn move_child(from: int, to: int) -> Result<bool> {
        let count: int = self.contents.len()
        if from < 0 || from >= count || to < 0 || to >= count {
            return err("cannot move child {from} to {to}: this container has {count} children",
                       "out_of_range")
        }
        if from == to {
            return ok(true)
        }
        self.reorder_child(from, to)?
        let moving: Widget = self.contents[from]
        self.contents.remove(from)
        self.contents.insert(to, moving)
        return ok(true)
    }
}
