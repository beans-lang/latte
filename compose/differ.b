// What changed between two renders.
package compose

import latte.input
import latte.platform

/// Compares the tree a render just produced with the one before it.
///
/// The output is a list of `Change`s, and the whole of latte's rendering
/// cost is decided here: a render that changed one label's text should produce
/// one `set`, and a render that reordered a list should produce `move`s rather
/// than rebuilding every row. A control that is rebuilt loses its focus, its
/// text selection, its input-method session and its scroll position, all of
/// which a person can see happen.
///
/// This class touches no platform at all. It takes two `Element` trees and
/// answers a list of values — which is why `tests/diff.b` can check its
/// behaviour exhaustively on every operating system with no display.
pub class Differ {
    changes: List<Change> = []

    pub fn init() {}

    /// The edits that turn `before` into `after`.
    ///
    /// `before` is `none` for a first render, which produces a single `create`
    /// carrying the whole tree.
    pub fn diff(before: Option<Element>, after: Element) -> List<Change> {
        self.changes = []
        var here: Path = new Path()
        match before {
            none => {
                self.at_surface(ChangeKind.create, 0, some(after))
            }
            some(old) => {
                if old.matches(after) {
                    self.walk(here, old, after)
                } else {
                    // A different kind or a different key is a different
                    // thing. There is no platform operation that turns a label
                    // into a button, and pretending otherwise would carry the
                    // old one's state into something it does not belong to.
                    self.at_surface(ChangeKind.remove, 0, none)
                    self.at_surface(ChangeKind.create, 0, some(after))
                }
            }
        }
        var out: List<Change> = []
        for change: Change in self.changes {
            out.push(change)
        }
        return move out
    }

    // ---- one matched pair ----

    fn walk(here: Path, before: Element, after: Element) {
        self.walk_attributes(here, before, after)
        self.walk_listeners(here, before, after)
        self.walk_children(here, before, after)
    }

    fn walk_attributes(here: Path, before: Element, after: Element) {
        // A choice list decides which selected indices are legal. Apply it
        // first, regardless of markup order, then reapply selected even when
        // its numeric value did not change.
        var items_changed: bool = false
        if before.ordered || after.ordered { items_changed = self.walk_ordered(here, before, after) }
        var index: int = 0
        for index: int in 0..after.attribute_count() {
            let wanted: Attribute = after.attribute_at(index)
            if wanted.kind == AttributeKind.items || wanted.kind == AttributeKind.numbers ||
               wanted.kind == AttributeKind.table_source { continue }
            match before.attribute(wanted.property, wanted.kind) {
                some(held) => {
                    if !held.same_as(wanted) || (items_changed && wanted.property == platform.P_SELECTED) { self.property(here, wanted) }
                }
                none => { self.property(here, wanted) }
            }
        }
        // A property that was set and is not any more has to be put back to
        // what a fresh control of this kind would have. Leaving it alone is
        // how a control stays disabled after the markup that disabled it was
        // deleted.
        for index: int in 0..before.attribute_count() {
            let gone: Attribute = before.attribute_at(index)
            if gone.kind == AttributeKind.items || gone.kind == AttributeKind.numbers ||
               gone.kind == AttributeKind.table_source { continue }
            match after.attribute(gone.property, gone.kind) {
                some(still) => {}
                none => { self.property(here, Attribute.default_for(gone.property, gone.kind)) }
            }
        }
    }

    /// The five attributes whose order matters, for the elements that have
    /// any. Answers whether a list this element's `selected` is judged against
    /// was rewritten.
    fn walk_ordered(here: Path, before: Element, after: Element) -> bool {
        var items_changed: bool = false
        match after.attribute(CHOICES_PROPERTY, AttributeKind.items) {
            some(wanted_items) => {
                match before.attribute(CHOICES_PROPERTY, AttributeKind.items) {
                    some(held_items) => { if !held_items.same_as(wanted_items) { self.property(here, wanted_items); items_changed = true } }
                    none => { self.property(here, wanted_items); items_changed = true }
                }
            }
            none => {
                match before.attribute(CHOICES_PROPERTY, AttributeKind.items) {
                    some(held_items) => { self.property(here, Attribute.of_items([])); items_changed = true }
                    none => {}
                }
            }
        }
        match after.attribute(TAB_LABELS_PROPERTY, AttributeKind.items) {
            some(wanted_labels) => {
                match before.attribute(TAB_LABELS_PROPERTY, AttributeKind.items) {
                    some(held_labels) => { if !held_labels.same_as(wanted_labels) { self.property(here, wanted_labels); items_changed = true } }
                    none => { self.property(here, wanted_labels); items_changed = true }
                }
            }
            none => {
                match before.attribute(TAB_LABELS_PROPERTY, AttributeKind.items) {
                    some(held_labels) => { self.property(here, Attribute.of_labels([])); items_changed = true }
                    none => {}
                }
            }
        }
        let columns_changed: bool = self.ordered_attribute(here, before, after,
            TABLE_COLUMNS_PROPERTY, AttributeKind.items, false)
        self.ordered_attribute(here, before, after,
            TABLE_WIDTHS_PROPERTY, AttributeKind.numbers, columns_changed)
        self.ordered_attribute(here, before, after,
            TABLE_SOURCE_PROPERTY, AttributeKind.table_source, false)
        return items_changed
    }

    fn ordered_attribute(here: Path, before: Element, after: Element,
                         property: int, kind: AttributeKind, force: bool) -> bool {
        match after.attribute(property, kind) {
            some(wanted) => {
                match before.attribute(property, kind) {
                    some(held) => {
                        if force || !held.same_as(wanted) { self.property(here, wanted); return true }
                    }
                    none => { self.property(here, wanted); return true }
                }
            }
            none => {
                match before.attribute(property, kind) {
                    some(held) => { self.property(here, Attribute.default_for(property, kind)); return true }
                    none => {}
                }
            }
        }
        return false
    }

    // Only the *set of event kinds* is compared, never the handlers
    // themselves. Two closures are never equal in any useful sense, so a
    // differ that compared them would unsubscribe and resubscribe every
    // handler on every render. The handler itself is refreshed by the applier,
    // which is a Beans-side table write and not a platform call.
    fn walk_listeners(here: Path, before: Element, after: Element) {
        var index: int = 0
        for index: int in 0..after.listener_count() {
            let wanted: input.EventKind = after.listener_at(index).kind
            if !before.listens_for(wanted) {
                self.subscription(ChangeKind.bind, here, wanted)
            }
        }
        for index: int in 0..before.listener_count() {
            let gone: input.EventKind = before.listener_at(index).kind
            if !after.listens_for(gone) {
                self.subscription(ChangeKind.unbind, here, gone)
            }
        }
    }

    // ---- children ----
    //
    // Three phases, in this order, because each depends on the one before:
    //
    //   1. Decide which old child each new child reuses. Keys first, so a
    //      keyed child is never taken by a positional match.
    //   2. Remove the old children nobody claimed, from the back, so removing
    //      one does not renumber the ones still waiting to be removed.
    //   3. Walk the new children in order, moving each claimed child into
    //      place and creating the rest.
    //
    // The bookkeeping list `living` holds, for each surviving child, the index
    // it had in the old tree. That is what makes "where is old child 4 now"
    // answerable without comparing object references — which the native
    // backend refuses for class values anyway.
    fn walk_children(here: Path, before: Element, after: Element) {
        let old_count: int = before.count()
        let new_count: int = after.count()
        if old_count == 0 && new_count == 0 {
            return
        }

        // Phase 1.
        var claimed: List<int> = []          // new index -> old index, or -1
        var taken: List<bool> = []           // old index -> spoken for
        var index: int = 0
        for index: int in 0..old_count { taken.push(false) }
        for index: int in 0..new_count { claimed.push(-1) }

        for index: int in 0..new_count {
            let want: Element = after.child_at(index)
            if want.key == "" { continue }
            var scan: int = 0
            for scan: int in 0..old_count {
                if taken[scan] { continue }
                let held: Element = before.child_at(scan)
                if held.matches(want) {
                    claimed[index] = scan
                    taken[scan] = true
                    break
                }
            }
        }
        // Unkeyed children match by order among the unkeyed, so inserting a
        // keyed row into a list of unkeyed ones does not shift every one of
        // them onto its neighbour.
        var cursor: int = 0
        for index: int in 0..new_count {
            let want: Element = after.child_at(index)
            if want.key != "" { continue }
            var scan: int = cursor
            for scan < old_count {
                if !taken[scan] && before.child_at(scan).key == "" &&
                   before.child_at(scan).matches(want) {
                    claimed[index] = scan
                    taken[scan] = true
                    cursor = scan + 1
                    break
                }
                scan = scan + 1
            }
        }

        // Phase 2.
        var living: List<int> = []
        for index: int in 0..old_count { living.push(index) }
        var back: int = old_count - 1
        for back >= 0 {
            if !taken[back] {
                self.structural(ChangeKind.remove, here, position_of(living, back), none)
                remove_value(inout living, back)
            }
            back = back - 1
        }

        // Phase 3.
        for index: int in 0..new_count {
            let want: Element = after.child_at(index)
            let from: int = claimed[index]
            if from < 0 {
                self.structural(ChangeKind.create, here, index, some(want))
                insert_at(inout living, index, -1)
                continue
            }
            let at: int = position_of(living, from)
            if at != index {
                self.structural_move(here, at, index)
                move_within(inout living, at, index)
            }
            here.push(index)
            self.walk(here, before.child_at(from), want)
            here.pop()
        }
    }

    // ---- emitting ----

    fn property(here: Path, attribute: Attribute) {
        var change: Change = new Change(ChangeKind.set, here.snapshot())
        change.attribute = attribute
        self.changes.push(change)
    }

    fn subscription(kind: ChangeKind, here: Path, event: input.EventKind) {
        var change: Change = new Change(kind, here.snapshot())
        change.event = event
        self.changes.push(change)
    }

    fn structural(kind: ChangeKind, here: Path, index: int, what: Option<Element>) {
        var change: Change = new Change(kind, here.snapshot())
        change.index = index
        change.element = what
        self.changes.push(change)
    }

    // The two changes that act on the container the mount was given, rather
    // than on an element inside it: a first render, and a render whose root
    // became something else.
    fn at_surface(kind: ChangeKind, index: int, what: Option<Element>) {
        var empty: Path = new Path()
        var change: Change = new Change(kind, empty.snapshot())
        change.at_surface = true
        change.index = index
        change.element = what
        self.changes.push(change)
    }

    fn structural_move(here: Path, from: int, to: int) {
        var change: Change = new Change(ChangeKind.relocate, here.snapshot())
        change.index = from
        change.target = to
        self.changes.push(change)
    }
}

// Where the child that used to be at old index `wanted` sits now.
fn position_of(living: List<int>, wanted: int) -> int {
    var index: int = 0
    for index: int in 0..living.len() {
        if living[index] == wanted { return index }
    }
    return -1
}

fn remove_value(inout living: List<int>, wanted: int) {
    var index: int = 0
    for index: int in 0..living.len() {
        if living[index] == wanted {
            living.remove(index)
            return
        }
    }
}

fn insert_at(inout living: List<int>, index: int, value: int) {
    living.push(value)
    var back: int = living.len() - 1
    for back > index {
        let held: int = living[back - 1]
        living[back - 1] = living[back]
        living[back] = held
        back = back - 1
    }
}

fn move_within(inout living: List<int>, from: int, to: int) {
    let held: int = living[from]
    living.remove(from)
    insert_at(inout living, to, held)
}
