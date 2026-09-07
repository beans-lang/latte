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
            if !self.roots.remove(id) {
                self.faults.push("disposed component {id} was never mounted")
            }
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
            match edit {
                step_in(index) => {
                    if index < 0 || index >= cur.kids.len() {
                        self.faults.push(
                            "component {update.component}: step_in {index} of {cur.kids.len()}")
                        // Descend into a placeholder rather than skipping, so
                        // the matching step_out still balances and the rest of
                        // the stream is not silently reinterpreted.
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
                    match self.kid(cur, index, update.component, "set_text") {
                        some(node) => { node.html = body }
                        none => {}
                    }
                }
                set_markup(index, html) => {
                    match self.kid(cur, index, update.component, "set_markup") {
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

    fn kid(parent: Node, index: int, component: int, what: string) -> Option<Node> {
        if index < 0 || index >= parent.kids.len() {
            self.faults.push("component {component}: {what} {index} of {parent.kids.len()}")
            return none
        }
        return some(parent.kids[index])
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
