// The reference applier: a batch of edits to a tree, in Beans.
//
// PLAN.md gate 3 is "apply equivalence": over thousands of random trees and
// mutations, the applier must land on the serializer's HTML of the new tree.
// This is the Beans half of that gate. The `latte.js` half — the same edits
// against a real DOM — is W5's, and neither half stands in for the other: a
// text test proves the encoder consistent with itself, and only a browser
// proves it means the same thing there.
//
// The applier holds a LOGICAL tree, which is what the edit stream addresses:
// a region, a fragment and a boundary are nodes here even though they write no
// HTML of their own, and so is a mounted child. That is the shape latte.js has
// to keep too, and it is the reason a keyed row may hold several roots and
// still move as one thing.
//
// It does NOT have a serializer of its own. It flattens its tree back into
// frames and hands them to the one in `serialize.b`. Two serializers would
// make gate 3 compare two bugs for equality — and this way the gate proves
// something stronger than it was asked to: that the applier reconstructed the
// frame list, not merely a string that looks like it.
package latte

pub class Node {
    pub kind: int = 0
    pub seq: int = 0
    pub tag: string = ""
    pub key: string = ""
    /// A text node's body, or a markup node's html.
    pub html: string = ""
    pub raw: bool = false
    pub failed: bool = false
    /// A mount's component id.
    pub component: int = 0
    pub type_name: string = ""
    /// Attribute slots, kept in `(seq, name)` order — the order the builder
    /// guarantees for a frame run, so the flattened frames come out in the
    /// order the serializer read them from.
    pub attrs: List<Attr> = []
    pub binds: List<Bind> = []
    pub refs: List<int> = []
    pub preserved: bool = false
    pub preserve_seq: int = -1
    pub kids: List<Node> = []
    pub fn init() {}
}

// ---- the kind rule ---------------------------------------------------------
//
// An edit names a POSITION. It does not name what is at that position, so the
// applier has to ask, and until it did, an edit landed on whatever was there.
//
// `diff.b`'s seven `SPAN_*` values are the node kinds and they split two ways.
// Two are LEAVES — a text node and a markup node hold a string and no children.
// The other five are CONTAINERS: an element, a mount, a region, a fragment and
// a boundary all hold children. Only an element carries attributes and
// handlers — `Applier.emit` writes an attribute run for `SPAN_ELEMENT` and for
// nothing else, so a slot stored anywhere else is written and then dropped.
//
// A kind-mismatched edit is DROPPED, one fault is recorded, the rest of the
// stream applies, and nothing ends. That is the same drop-and-record the
// eleven index and lookup refusals in `run` already use, and it is the rule
// `latte.js` applies to a real DOM with the SAME sentence, byte for byte —
// lanes/W5.md, THE APPLIER CONTRACT. Two appliers that answer a malformed
// batch differently are two appliers, and gate 3 exists to compare them.
//
// What it closes, and this is why it is a rule and not a nicety:
//
//   * `set_text` at a `raw` markup node rewrote `node.html` while `node.raw`
//     stayed true, so `emit` wrote the new bytes back out through `Frame.raw`
//     — UNESCAPED. `<img src=x onerror=alert(1)>` reached the page and nothing
//     was raised. The escaping context changed under the value; it was never
//     the harmless no-op the shape looks like.
//   * `set_text` at the mount a component sits in is `textContent` in a
//     browser, which WIPES that child's subtree. The child's next update
//     carries only what CHANGED, so the page never comes back.
//   * `insert` at a leaf appended a child to a text node and `emit` dropped it
//     again: content accepted, then silently lost. With `step_in` refusing a
//     descent into a leaf and `insert`/`relocate` refusing a leaf cursor, a
//     leaf cannot acquire children at all any more.
//
// No well-formed batch trips any of this — `Differ.pair` reaches `set_text`
// only under `SPAN_TEXT`, `set_markup` only under `SPAN_MARKUP`, `step_in`
// only onto an element, region, fragment or boundary, and the attribute edits
// only from `diff_element` after a `step_in` onto an element. So the sweep in
// `tests/apply.b` § 4 must still report ZERO faults, and if it ever does not,
// the check below is stricter than the differ and the check is wrong.

/// What a node has to be for an edit to be allowed to address it.
const WANT_ELEMENT: int = 0
const WANT_TEXT: int = 1
const WANT_MARKUP: int = 2
const WANT_CONTAINER: int = 3
/// The edit does not constrain the kind of the node it acts on.
const WANT_ANY: int = 4

fn want_name(want: int) -> string {
    if want == WANT_ELEMENT { return "element" }
    if want == WANT_TEXT { return "text" }
    if want == WANT_MARKUP { return "markup" }
    if want == WANT_CONTAINER { return "container" }
    return "any"
}

/// The kind names the fault sentence carries — the same seven `latte.js`
/// prints, because the two halves are diffed against each other.
///
/// `node_` and not `kind_name`, because `circuit.b` already has a `kind_name`
/// for the client message opcodes and both are free functions in one package.
fn node_kind_name(kind: int) -> string {
    if kind == SPAN_ELEMENT { return "element" }
    if kind == SPAN_TEXT { return "text" }
    if kind == SPAN_MARKUP { return "markup" }
    if kind == SPAN_MOUNT { return "mount" }
    if kind == SPAN_REGION { return "region" }
    if kind == SPAN_FRAGMENT { return "fragment" }
    if kind == SPAN_BOUNDARY { return "boundary" }
    // Unreachable today: a Node's kind is a Span's, which `read_span` sets from
    // exactly those seven; a synthetic root is `SPAN_MOUNT`; a `step_in`
    // placeholder takes the field default, `SPAN_ELEMENT`. It answers the
    // NUMBER rather than folding into one of the seven, because a kind that
    // does show up one day should read as the thing it is instead of lying
    // about being a boundary.
    return "kind {kind}"
}

fn kind_satisfies(kind: int, want: int) -> bool {
    if want == WANT_CONTAINER { return kind != SPAN_TEXT && kind != SPAN_MARKUP }
    if want == WANT_ELEMENT { return kind == SPAN_ELEMENT }
    if want == WANT_TEXT { return kind == SPAN_TEXT }
    if want == WANT_MARKUP { return kind == SPAN_MARKUP }
    return true
}

/// What the CURRENT node has to be for this edit, or `WANT_ANY` when the edit
/// does not act on the current node's own kind.
///
/// `insert`, `remove` and `relocate` rearrange the current node's children, so
/// it has to be a node that can hold them. The five attribute and handler
/// edits write into the run only an element has. `step_in`, `set_text` and
/// `set_markup` address a CHILD and are checked against that child where they
/// are applied; `step_out` addresses the stack and no node at all.
fn cursor_want(edit: Edit) -> int {
    match edit {
        insert(_, _) => { return WANT_CONTAINER }
        remove(_) => { return WANT_CONTAINER }
        relocate(_, _) => { return WANT_CONTAINER }
        set_attr(_, _, _) => { return WANT_ELEMENT }
        set_flag(_, _, _) => { return WANT_ELEMENT }
        remove_attr(_, _) => { return WANT_ELEMENT }
        set_handler(_, _, _) => { return WANT_ELEMENT }
        remove_handler(_, _) => { return WANT_ELEMENT }
        _ => { return WANT_ANY }
    }
}

/// An edit's opcode NAME. `describe_edit` spells an edit's ARGUMENTS for a
/// dump — "in 3", "text 2 = x" — and a fault sentence carries the opcode, so
/// this is a second spelling on purpose and not a duplicate of that one.
fn edit_op(edit: Edit) -> string {
    match edit {
        step_in(_) => { return "step_in" }
        step_out => { return "step_out" }
        insert(_, _) => { return "insert" }
        remove(_) => { return "remove" }
        relocate(_, _) => { return "relocate" }
        set_text(_, _) => { return "set_text" }
        set_markup(_, _) => { return "set_markup" }
        set_attr(_, _, _) => { return "set_attr" }
        set_flag(_, _, _) => { return "set_flag" }
        remove_attr(_, _) => { return "remove_attr" }
        set_handler(_, _, _) => { return "set_handler" }
        remove_handler(_, _) => { return "remove_handler" }
    }
}

pub class Applier {
    /// Anything the edit stream asked for that the tree could not do. Every
    /// one of these is a differ bug or a batch applied out of order, so they
    /// are loud rather than tolerated.
    pub faults: List<string> = []

    /// One root per mounted component, keyed by component id. Component 0 is
    /// the page root and has no mount frame, so its node is synthetic.
    pub roots: Map<int, Node> = {}

    /// Whatever the last `html()` call's serializer complained about.
    pub serializer_faults: List<string> = []

    pub fn init() {}

    // ---- applying ---------------------------------------------------------

    pub fn apply(batch: Batch) {
        for update: ComponentUpdate in batch.updates {
            self.run(batch, update)
        }
        for id: int in batch.disposed {
            // A disposal for a component this applier never mounted is not a
            // fault. A component can be mounted and dropped inside ONE render
            // pass — an error boundary whose body mounts a child and then
            // panics does exactly that — in which case its mount frame was
            // truncated away before any batch went out, and the builder has no
            // way to know the client never saw it. So the batch names it and
            // this drops what it holds, if anything.
            let _: bool = self.roots.remove(id)
        }
    }

    fn root_for(id: int) -> Node {
        match self.roots.get(id) {
            some(node) => { return node }
            none => {
                let made: Node = new Node()
                made.kind = SPAN_MOUNT
                made.component = id
                self.roots[id] = made
                if id != 0 {
                    // The batch is supposed to be in pre-order, parent before
                    // child, exactly so this cannot happen.
                    self.faults.push(
                        "update for component {id} arrived before its mount")
                }
                return made
            }
        }
    }

    fn run(batch: Batch, update: ComponentUpdate) {
        var stack: List<Node> = []
        stack.push(self.root_for(update.component))
        for edit: Edit in update.edits {
            let cur: Node = stack[stack.len() - 1]
            // The kind rule, for every edit that acts on the CURRENT node. One
            // gate rather than eight, because eight copies of a rule are eight
            // chances to spell it differently — and `latte.js` has to spell it
            // the same as this one. `step_in`, `set_text` and `set_markup`
            // address a CHILD and are checked below, against that child.
            let want: int = cursor_want(edit)
            if !kind_satisfies(cur.kind, want) {
                self.wrong_kind(update.component, edit_op(edit), want, cur.kind)
                continue
            }
            match edit {
                step_in(index) => {
                    if index < 0 || index >= cur.kids.len() {
                        self.faults.push(
                            "component {update.component}: step_in {index} of {cur.kids.len()}")
                        // Descend into a placeholder rather than skipping, so
                        // the matching step_out still balances and the rest of
                        // the stream is not silently reinterpreted.
                        stack.push(new Node())
                    } else if !kind_satisfies(cur.kids[index].kind, WANT_CONTAINER) {
                        self.wrong_kind_at(update.component, "step_in", index,
                                           WANT_CONTAINER, cur.kids[index].kind)
                        // The same placeholder, for the same reason. Refusing
                        // the descent without pushing one would leave the
                        // matching `step_out` to pop this node's PARENT, and
                        // every edit after it would land somewhere it was
                        // never addressed to.
                        stack.push(new Node())
                    } else {
                        stack.push(cur.kids[index])
                    }
                }
                step_out => {
                    if stack.len() <= 1 {
                        self.faults.push(
                            "component {update.component}: step_out at the root")
                    } else {
                        let _: Node = stack.remove(stack.len() - 1)
                    }
                }
                insert(index, at) => {
                    match span_at(batch.reference, at) {
                        some(span) => {
                            let node: Node = self.build(batch.reference, span)
                            if index < 0 || index > cur.kids.len() {
                                self.faults.push(
                                    "component {update.component}: insert at {index} of {cur.kids.len()}")
                                cur.kids.push(node)
                            } else {
                                cur.kids.insert(index, node)
                            }
                        }
                        none => {
                            self.faults.push(
                                "component {update.component}: no staged subtree at {at}")
                        }
                    }
                }
                remove(index) => {
                    if index < 0 || index >= cur.kids.len() {
                        self.faults.push(
                            "component {update.component}: remove {index} of {cur.kids.len()}")
                    } else {
                        let _: Node = cur.kids.remove(index)
                    }
                }
                relocate(from, to) => {
                    if from < 0 || from >= cur.kids.len() {
                        self.faults.push(
                            "component {update.component}: move from {from} of {cur.kids.len()}")
                    } else {
                        let node: Node = cur.kids.remove(from)
                        if to < 0 || to > cur.kids.len() {
                            self.faults.push(
                                "component {update.component}: move to {to} of {cur.kids.len()}")
                            cur.kids.push(node)
                        } else {
                            cur.kids.insert(to, node)
                        }
                    }
                }
                set_text(index, body) => {
                    match self.kid(cur, index, update.component, "set_text", WANT_TEXT) {
                        some(node) => { node.html = body }
                        none => {}
                    }
                }
                set_markup(index, html) => {
                    match self.kid(cur, index, update.component, "set_markup", WANT_MARKUP) {
                        some(node) => { node.html = html }
                        none => {}
                    }
                }
                set_attr(seq, name, value) => {
                    let slot: Attr = new Attr()
                    slot.seq = seq
                    slot.name = name
                    slot.value = value
                    slot.present = true
                    slot.flag = false
                    put_slot(cur, slot)
                }
                set_flag(seq, name, present) => {
                    let slot: Attr = new Attr()
                    slot.seq = seq
                    slot.name = name
                    slot.value = ""
                    slot.present = present
                    slot.flag = true
                    put_slot(cur, slot)
                }
                remove_attr(seq, name) => {
                    let probe: Attr = new Attr()
                    probe.seq = seq
                    probe.name = name
                    if !drop_slot(cur, probe) {
                        self.faults.push(
                            "component {update.component}: no attribute {seq}:{name} to remove")
                    }
                }
                set_handler(seq, event, id) => {
                    let bind: Bind = new Bind()
                    bind.seq = seq
                    bind.event = event
                    bind.id = id
                    put_bind(cur, bind)
                }
                remove_handler(seq, event) => {
                    let probe: Bind = new Bind()
                    probe.seq = seq
                    probe.event = event
                    if !drop_bind(cur, probe) {
                        self.faults.push(
                            "component {update.component}: no handler {seq}:{event} to remove")
                    }
                }
            }
        }
        if stack.len() != 1 {
            self.faults.push(
                "component {update.component}: the edit stream ended {stack.len() - 1} level(s) deep")
        }
    }

    /// The child at `index` when it is there AND it is the kind the edit needs
    /// — otherwise a fault and `none`, and the caller does nothing.
    ///
    /// Two questions, and the second one is the kind rule above. `set_text`
    /// only ever means a text node and `set_markup` only ever means a markup
    /// node; addressed at anything else the edit is a differ bug or a
    /// hand-built batch, because `Differ.pair` reaches `set_text` only under
    /// `o.kind == SPAN_TEXT` and `set_markup` only under `SPAN_MARKUP`.
    ///
    /// The index is asked first because there is no kind to name at an index
    /// that holds nothing, and because two faults for one edit would say the
    /// stream was twice as wrong as it is.
    fn kid(parent: Node, index: int, component: int, what: string,
           want: int) -> Option<Node> {
        if index < 0 || index >= parent.kids.len() {
            self.faults.push("component {component}: {what} {index} of {parent.kids.len()}")
            return none
        }
        let node: Node = parent.kids[index]
        if !kind_satisfies(node.kind, want) {
            self.wrong_kind_at(component, what, index, want, node.kind)
            return none
        }
        return some(node)
    }

    /// A kind-mismatched edit that named a CHILD, and what that child really
    /// is. `set_text`, `set_markup` and `step_in` all carry an index, and the
    /// sentence names it, because "set_text needs a text node" against a node
    /// with four children says nothing about which one was meant.
    ///
    /// The wording is fixed by lanes/W5.md, THE APPLIER CONTRACT: `latte.js`
    /// emits this sentence byte for byte from the same stream, so a reword
    /// here is a wire-contract change and breaks the two-appliers-one-answer
    /// premise gate 3 rests on.
    fn wrong_kind_at(component: int, op: string, index: int, want: int, got: int) {
        self.faults.push(
            "component {component}: {op} {index} needs a {want_name(want)} node, not a {node_kind_name(got)} node")
    }

    /// The same refusal for an edit that acts on the CURRENT node and has no
    /// index to name: the three that rearrange children and the five that
    /// write an attribute or a handler.
    ///
    /// Reachable through `apply()` for `WANT_ELEMENT` and not for
    /// `WANT_CONTAINER`, and the asymmetry is worth writing down rather than
    /// leaving a reader to assume both are ordinary. The cursor is the
    /// component's root — always `SPAN_MOUNT` — or a node `step_in` descended
    /// into, and `step_in` now refuses a leaf, or a `step_in` placeholder,
    /// which is an element. So a cursor that is a mount, a region, a fragment
    /// or a boundary reaches the element check from an ordinary edit stream,
    /// while a cursor that is a leaf can only be arrived at by putting one
    /// into `Applier.roots` by hand — the field is `pub`, so the refusal is
    /// live rather than dead, and `tests/w1_faults.b` § 1 trips it that way.
    /// It is kept because the rule is one rule: a node that cannot hold
    /// children never gains any, however the applier got there.
    fn wrong_kind(component: int, op: string, want: int, got: int) {
        self.faults.push(
            "component {component}: {op} needs a {want_name(want)} node, not a {node_kind_name(got)} node")
    }

    // ---- building from frames ---------------------------------------------
    //
    // The same span scan the differ uses, so "build a node" and "diff against
    // an empty old side" read the same frames the same way.
    fn build(frames: Frames, span: Span) -> Node {
        let node: Node = new Node()
        node.kind = span.kind
        node.seq = span.seq
        node.tag = span.tag
        node.key = span.key
        node.html = span.html
        node.raw = span.raw
        node.failed = span.failed
        node.component = span.id
        node.type_name = span.type_name

        if span.kind == SPAN_ELEMENT {
            let head: Head = read_head(frames, span)
            for slot: Attr in head.attrs { node.attrs.push(slot) }
            for bind: Bind in head.binds { node.binds.push(bind) }
            for seq: int in head.refs { node.refs.push(seq) }
            node.preserved = head.preserved
            node.preserve_seq = head.preserve_seq
        }

        if span.kind == SPAN_MOUNT {
            // A mount frame is a LEAF: it names a component id and carries none
            // of that component's content, which arrives as its own
            // ComponentUpdate addressed to this node.
            //
            // So a mount frame that is being re-inserted must bring back the
            // subtree we already hold for that id, NOT an empty node. A
            // component id names a live component; re-inserting its mount point
            // re-parents what it already rendered. Building an empty node
            // instead loses the child's whole subtree silently and forever,
            // because the child's next update carries only what CHANGED and an
            // unchanged child sends nothing at all.
            //
            // Two shapes reach here, both found by the fuzz and both pinned by
            // name in tests/apply.b § 1: an element whose TAG changed with a
            // mount inside it — the differ replaces the element while
            // `component<T>` kept the slot live — and an error boundary that
            // failed and then recovered around one. latte.js inherits the rule:
            // it must move the component's existing nodes, not create new ones.
            match self.roots.get(span.id) {
                some(existing) => {
                    existing.seq = span.seq
                    existing.type_name = span.type_name
                    return existing
                }
                none => {}
            }
            self.roots[span.id] = node
            return node
        }

        if span.kind == SPAN_TEXT || span.kind == SPAN_MARKUP { return node }

        for kid: Span in scan_spans(frames, span.body, span.stop) {
            node.kids.push(self.build(frames, kid))
        }
        return node
    }

    // ---- reading it back --------------------------------------------------

    /// The applier's tree as a `Builder`, so the ONE serializer in this package
    /// can walk it. Nothing here writes HTML.
    pub fn to_builder() -> Builder {
        let root: Builder = new Builder()
        match self.roots.get(0) {
            some(node) => { self.flatten(node, root) }
            none => {}
        }
        return root
    }

    fn flatten(node: Node, into: Builder) {
        for kid: Node in node.kids { self.emit(kid, into) }
    }

    fn emit(node: Node, into: Builder) {
        if node.kind == SPAN_ELEMENT {
            into.frames.push(Frame.open(node.seq, node.tag))
            for slot: Attr in node.attrs {
                if slot.flag {
                    into.frames.push(Frame.flag(slot.seq, slot.name, slot.present))
                } else {
                    into.frames.push(Frame.attribute(slot.seq, slot.name, slot.value))
                }
            }
            for bind: Bind in node.binds {
                into.frames.push(Frame.handler(bind.seq, bind.event, bind.id))
            }
            for seq: int in node.refs { into.frames.push(Frame.reference(seq)) }
            if node.preserved { into.frames.push(Frame.preserve(node.preserve_seq)) }
            for kid: Node in node.kids { self.emit(kid, into) }
            into.frames.push(Frame.close)
        } else if node.kind == SPAN_TEXT {
            into.frames.push(Frame.text(node.seq, node.html))
        } else if node.kind == SPAN_MARKUP {
            if node.raw { into.frames.push(Frame.raw(node.seq, node.html)) }
            else { into.frames.push(Frame.constant(node.seq, node.html)) }
        } else if node.kind == SPAN_MOUNT {
            into.frames.push(Frame.child(node.seq, node.type_name, node.component))
            let child: Builder = new Builder()
            child.id = node.component
            self.flatten(node, child)
            into.nested[node.component] = child
        } else if node.kind == SPAN_REGION {
            into.frames.push(Frame.region_open(node.seq, node.key))
            for kid: Node in node.kids { self.emit(kid, into) }
            into.frames.push(Frame.region_close)
        } else if node.kind == SPAN_FRAGMENT {
            into.frames.push(Frame.fragment_open(node.seq))
            for kid: Node in node.kids { self.emit(kid, into) }
            into.frames.push(Frame.fragment_close)
        } else if node.kind == SPAN_BOUNDARY {
            into.frames.push(Frame.boundary_open(node.seq, node.failed))
            for kid: Node in node.kids { self.emit(kid, into) }
            into.frames.push(Frame.boundary_close)
        }
    }

    /// The HTML of the tree the applier holds, through the same serializer a
    /// render goes through.
    pub fn html() -> string {
        let writer: Serializer = new Serializer()
        let text: string = writer.page(self.to_builder())
        self.serializer_faults.clear()
        for fault: string in writer.faults { self.serializer_faults.push(fault) }
        return text
    }

    /// The frames the applier reconstructed, one per line — the same shape
    /// `Builder.dump_tree()` prints, so a failing gate-3 case can be read as
    /// two frame lists side by side rather than two long strings.
    pub fn dump() -> string { return self.to_builder().dump_tree() }
}

// ---- attribute and handler slots ------------------------------------------
//
// Free functions rather than methods, because they are pure list surgery on a
// node and the applier has nothing to add.

fn put_slot(node: Node, slot: Attr) {
    var index: int = 0
    for index < node.attrs.len() {
        let order: int = compare_slot(node.attrs[index], slot)
        if order == 0 {
            node.attrs[index] = slot
            return
        }
        if order > 0 {
            node.attrs.insert(index, slot)
            return
        }
        index += 1
    }
    node.attrs.push(slot)
}

fn drop_slot(node: Node, probe: Attr) -> bool {
    var index: int = 0
    for index < node.attrs.len() {
        if compare_slot(node.attrs[index], probe) == 0 {
            let _: Attr = node.attrs.remove(index)
            return true
        }
        index += 1
    }
    return false
}

fn put_bind(node: Node, bind: Bind) {
    var index: int = 0
    for index < node.binds.len() {
        let order: int = compare_bind(node.binds[index], bind)
        if order == 0 {
            node.binds[index] = bind
            return
        }
        if order > 0 {
            node.binds.insert(index, bind)
            return
        }
        index += 1
    }
    node.binds.push(bind)
}

fn drop_bind(node: Node, probe: Bind) -> bool {
    var index: int = 0
    for index < node.binds.len() {
        if compare_bind(node.binds[index], probe) == 0 {
            let _: Bind = node.binds.remove(index)
            return true
        }
        index += 1
    }
    return false
}
