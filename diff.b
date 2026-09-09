// The differ: one component's two frame lists to a batch of edits.
//
// It matches frames by sequence number, never by content, and never
// searches: a frame's seq is a SOURCE POSITION, so the same seq in both
// renders means the same place in the markup, and siblings carry strictly
// increasing seqs. The one exception is a keyed loop, where every row shares
// the loop's seq and is matched by its key instead.
//
// The batch it produces is a cursor walk over a logical tree — see "spans"
// below for what counts as one node in it. latte.js has to walk the same
// shape.
package latte

import std.fmt

// ---------------------------------------------------------------- the edits
//
// `insert` names an offset into the batch's `reference` frame pool rather than
// carrying a subtree of its own, so the applier's build-a-node path is exactly
// the path a first render takes: a diff against an empty old side stages every
// frame and the applier builds from frames either way. One builder, not two.
pub enum Edit {
    /// Descend into the child at `index` of the current node.
    step_in(index: int)
    /// Back to the parent.
    step_out
    /// Build the subtree staged at `at` in `Batch.reference` and put it at
    /// `index` among the current node's children.
    insert(index: int, at: int)
    remove(index: int)
    /// Move the child at `from` to `to` without rebuilding it. Spelled
    /// `relocate` because `move` is a Beans keyword and cannot name an enum
    /// variant.
    relocate(from: int, to: int)
    set_text(index: int, body: string)
    set_markup(index: int, html: string)

    // Attribute edits act on the CURRENT node, so they follow a `step_in`.
    // They are keyed by `(seq, name)`, which the builder guarantees is
    // strictly increasing within one element's attribute run.
    set_attr(seq: int, name: string, value: string)
    set_flag(seq: int, name: string, present: bool)
    remove_attr(seq: int, name: string)

    // Handlers are keyed by `(seq, event)` and carry the SLOT id — the wire
    // id. No name ever crosses.
    set_handler(seq: int, event: string, id: int)
    remove_handler(seq: int, event: string)
}

pub fn describe_edit(edit: Edit) -> string {
    match edit {
        step_in(index) => { return "in {index}" }
        step_out => { return "out" }
        insert(index, at) => { return "insert {index} <- ref@{at}" }
        remove(index) => { return "remove {index}" }
        relocate(from, to) => { return "move {from} -> {to}" }
        set_text(index, body) => { return "text {index} = {body}" }
        set_markup(index, html) => { return "markup {index} = {html}" }
        set_attr(seq, name, value) => { return "attr {seq}:{name} = {value}" }
        set_flag(seq, name, present) => { return "flag {seq}:{name} = {present}" }
        remove_attr(seq, name) => { return "-attr {seq}:{name}" }
        set_handler(seq, event, id) => { return "on:{event} {seq} -> {id}" }
        remove_handler(seq, event) => { return "-on:{event} {seq}" }
    }
}

/// One component's edits. A component is addressed by its slot id, which is
/// also its mount id and its handler-id space — one int, three jobs.
pub class ComponentUpdate {
    pub component: int = 0
    pub edits: List<Edit> = []
    pub fn init(component: int) { self.component = component }
}

/// What one render pass produced, for one page.
///
/// `updates` is in PRE-ORDER, parent before child, so the mount node a child's
/// edits are addressed to always exists by the time they arrive.
pub class Batch {
    /// Every subtree an `insert` refers to, staged end to end. An `insert`'s
    /// `at` is the index of that subtree's first frame.
    pub reference: Frames = new Frames()
    pub updates: List<ComponentUpdate> = []

    /// Components the sweep dropped. The applier holds one root node per
    /// mounted component and would otherwise keep the entry for a component
    /// that has left the page.
    pub disposed: List<int> = []
    pub fn init() {}

    pub fn edit_count() -> int {
        var total: int = 0
        for update: ComponentUpdate in self.updates { total += update.edits.len() }
        return total
    }

    /// Edits below the `step_in` that scoped them. A one-line dump is
    /// unreadable in a failing diff, and a golden is read by a person exactly
    /// once — when it breaks.
    pub fn dump() -> string {
        var out: fmt.StringBuilder = new fmt.StringBuilder()
        for update: ComponentUpdate in self.updates {
            out.push("component {update.component}\n")
            var depth: int = 0
            for edit: Edit in update.edits {
                match edit {
                    step_out => { depth -= 1 }
                    _ => {}
                }
                if depth < 0 { depth = 0 }
                out.push("  ".repeat(depth + 1))
                out.push(describe_edit(edit))
                out.push("\n")
                match edit {
                    step_in(_) => { depth += 1 }
                    _ => {}
                }
            }
        }
        if self.disposed.len() > 0 { out.push("disposed {self.disposed}\n") }
        return out.to_string()
    }
}

// ---------------------------------------------------------------- spans
//
// A span is one logical child: the frames from its opener to its closer. The
// kinds are the applier's node kinds too — one numbering, so a walker cannot
// map them wrong.

pub const SPAN_ELEMENT: int = 0
pub const SPAN_TEXT: int = 1
pub const SPAN_MARKUP: int = 2
pub const SPAN_MOUNT: int = 3
pub const SPAN_REGION: int = 4
pub const SPAN_FRAGMENT: int = 5
pub const SPAN_BOUNDARY: int = 6

pub class Span {
    pub kind: int = 0
    pub seq: int = 0
    /// The opening frame.
    pub start: int = 0
    /// The first child frame — past the attribute run for an element, past the
    /// opener for a group.
    pub body: int = 0
    /// The closing frame, or `start` for a leaf.
    pub stop: int = 0
    /// One past the closing frame: where the next sibling begins.
    pub next: int = 0
    pub tag: string = ""
    pub key: string = ""
    pub html: string = ""
    pub raw: bool = false
    pub failed: bool = false
    pub id: int = 0
    pub type_name: string = ""
    pub fn init() {}
}

/// One event binding on an element, keyed by `(seq, event)`.
pub class Bind {
    pub seq: int = 0
    pub event: string = ""
    pub id: int = 0
    pub fn init() {}
}

/// An element's attribute run, read once.
pub class Head {
    pub attrs: List<Attr> = []
    pub binds: List<Bind> = []
    pub refs: List<int> = []
    pub preserved: bool = false
    pub preserve_seq: int = -1
    pub fn init() {}
}

/// The index of the frame that closes the container opened at `opener`, or the
/// end of the list. The builder guarantees balance; a walker that trusts a
/// guarantee absolutely is a walker that crashes when the guarantee has a bug.
pub fn matching_close(frames: Frames, opener: int) -> int {
    var index: int = opener + 1
    var depth: int = 0
    for index < frames.len() {
        let frame: Frame = frames.at(index)
        var opens: bool = false
        var closes: bool = false
        match frame {
            open(_, _) => { opens = true }
            region_open(_, _) => { opens = true }
            fragment_open(_) => { opens = true }
            boundary_open(_, _) => { opens = true }
            close => { closes = true }
            region_close => { closes = true }
            fragment_close => { closes = true }
            boundary_close => { closes = true }
            _ => {}
        }
        if closes {
            if depth == 0 { return index }
            depth -= 1
        }
        if opens { depth += 1 }
        index += 1
    }
    return frames.len()
}

/// The span that starts at `index`, or `none` if the frame there closes a
/// scope or is a stray attribute in a child position.
pub fn span_at(frames: Frames, index: int) -> Option<Span> {
    if index < 0 || index >= frames.len() { return none }
    let span: Span = new Span()
    span.start = index
    span.stop = index
    span.body = index + 1
    span.next = index + 1
    match frames.at(index) {
        open(seq, tag) => {
            span.kind = SPAN_ELEMENT
            span.seq = seq
            span.tag = tag
            let close_at: int = matching_close(frames, index)
            span.stop = close_at
            span.next = close_at + 1
            var body: int = index + 1
            for body < close_at {
                if !frame_is_attribute(frames.at(body)) { break }
                body += 1
            }
            span.body = body
        }
        text(seq, body) => {
            span.kind = SPAN_TEXT
            span.seq = seq
            span.html = body
        }
        raw(seq, html) => {
            span.kind = SPAN_MARKUP
            span.seq = seq
            span.html = html
            span.raw = true
        }
        constant(seq, html) => {
            span.kind = SPAN_MARKUP
            span.seq = seq
            span.html = html
            span.raw = false
        }
        child(seq, type_name, id) => {
            span.kind = SPAN_MOUNT
            span.seq = seq
            span.type_name = type_name
            span.id = id
        }
        region_open(seq, key) => {
            span.kind = SPAN_REGION
            span.seq = seq
            span.key = key
            span.stop = matching_close(frames, index)
            span.next = span.stop + 1
        }
        fragment_open(seq) => {
            span.kind = SPAN_FRAGMENT
            span.seq = seq
            span.stop = matching_close(frames, index)
            span.next = span.stop + 1
        }
        boundary_open(seq, failed) => {
            span.kind = SPAN_BOUNDARY
            span.seq = seq
            span.failed = failed
            span.stop = matching_close(frames, index)
            span.next = span.stop + 1
        }
        _ => { return none }
    }
    return some(span)
}

/// Every logical child between `start` and `stop`.
///
/// `span_at` answers `none` for two different things and they are not the same
/// problem. A frame that CLOSES a scope means the scope really ended, whatever
/// `stop` said, so the walk stops — reading on would take an outer scope's
/// children for this one's. An attribute-run frame in a CHILD position is a
/// stray: it belongs to no span, and the walk steps over it and keeps reading
/// siblings.
///
/// Stepping over is not a nicety, it is the only answer that agrees with
/// `serialize.b`, which reports that frame by name and then writes the
/// children after it anyway. Breaking instead — which this did — silently
/// dropped every sibling past the stray, so the applier's tree and the
/// serializer's HTML of the SAME frames came out different with no fault
/// anywhere: `<b>one</b>` against `<b>onetwo</b>`. Two walkers over the same
/// frames have to agree, which is why they step the same way now.
/// `tests/w1_faults.b` § 5 pins all six stray frame kinds.
///
/// Nothing in this repo produces one — `take_attribute_slot` refuses and drops
/// the frame before it is written, which § 4 asserts — so this is reached by a
/// hand-assembled `Builder.frames` and by a differ bug, and neither is a
/// reason for two walkers to answer differently.
pub fn scan_spans(frames: Frames, start: int, stop: int) -> List<Span> {
    var out: List<Span> = []
    var index: int = start
    for index < stop {
        match span_at(frames, index) {
            some(span) => {
                out.push(span)
                index = span.next
            }
            none => {
                if index >= frames.len() { break }
                if !frame_is_attribute(frames.at(index)) { break }
                index += 1
            }
        }
    }
    return move out
}

pub fn read_head(frames: Frames, span: Span) -> Head {
    let head: Head = new Head()
    var index: int = span.start + 1
    for index < span.body {
        match frames.at(index) {
            attribute(seq, name, value) => {
                let slot: Attr = new Attr()
                slot.seq = seq
                slot.name = name
                slot.value = value
                slot.present = true
                slot.flag = false
                head.attrs.push(slot)
            }
            flag(seq, name, present) => {
                let slot: Attr = new Attr()
                slot.seq = seq
                slot.name = name
                slot.value = ""
                slot.present = present
                slot.flag = true
                head.attrs.push(slot)
            }
            handler(seq, event, id) => {
                let bind: Bind = new Bind()
                bind.seq = seq
                bind.event = event
                bind.id = id
                head.binds.push(bind)
            }
            reference(seq) => { head.refs.push(seq) }
            preserve(seq) => {
                head.preserved = true
                head.preserve_seq = seq
            }
            _ => {}
        }
        index += 1
    }
    return head
}

/// `(seq, name)` order: the merge key for an attribute slot, and the order the
/// applier keeps its slots in so its HTML matches the serializer's frame walk.
pub fn compare_slot(a: Attr, b: Attr) -> int {
    if a.seq < b.seq { return -1 }
    if a.seq > b.seq { return 1 }
    if a.name < b.name { return -1 }
    if a.name > b.name { return 1 }
    return 0
}

pub fn compare_bind(a: Bind, b: Bind) -> int {
    if a.seq < b.seq { return -1 }
    if a.seq > b.seq { return 1 }
    if a.event < b.event { return -1 }
    if a.event > b.event { return 1 }
    return 0
}

fn bind_key(bind: Bind) -> string { return "{bind.seq}|{bind.event}" }

// ---------------------------------------------------------------- units
//
// A REGION RUN is the maximal run of adjacent regions carrying one seq: the
// rows one loop produced. Everything else is a run of one. The sibling merge
// walks units, so a loop is a single position in its parent's sequence however
// many rows it has, which is what lets a 50,000-row table be numbered once.

class Unit {
    pub seq: int = 0
    pub kind: int = 0
    pub spans: List<Span> = []
    pub fn init() {}
}

fn group_units(spans: List<Span>) -> List<Unit> {
    var out: List<Unit> = []
    var index: int = 0
    for index < spans.len() {
        let unit: Unit = new Unit()
        unit.seq = spans[index].seq
        unit.kind = spans[index].kind
        unit.spans.push(spans[index])
        index += 1
        if unit.kind == SPAN_REGION {
            for index < spans.len() {
                if spans[index].kind != SPAN_REGION { break }
                if spans[index].seq != unit.seq { break }
                unit.spans.push(spans[index])
                index += 1
            }
        }
        out.push(unit)
    }
    return move out
}

// ---------------------------------------------------------------- the differ

pub class Differ {
    /// NOTHING WRITES TO THIS TODAY. The differ has no refusals: it reads two
    /// frame lists the builder has already validated and answers edits, and
    /// every shape it cannot match it REPLACES rather than reporting. So every
    /// `differ.faults.len() == 0` in the suites is a tautology, and a reader
    /// should not take the field for evidence that the differ validates.
    ///
    /// It is kept because `batch()` clears it and callers read it, so a first
    /// refusal is a one-line change here rather than an API change everywhere.
    /// The day one lands, `test.sh`'s refusal-coverage leg fails and asks for
    /// the audit — `refusal_coverage_none diff.b` is what makes that true, and
    /// it is the only reason this is a checked fact rather than a comment.
    pub faults: List<string> = []
    out: Batch = new Batch()
    current: ComponentUpdate = new ComponentUpdate(0)
    old_frames: Frames = new Frames()
    new_frames: Frames = new Frames()
    pub fn init() {}

    /// Every component in the tree that has rendered since the last batch,
    /// parent before child.
    ///
    /// The walk visits the whole tree rather than a dirty set, because a
    /// buffer knows on its own whether it has unsent frames — `Builder.diffed`
    /// — and one map lookup per mounted component is nothing beside the render
    /// that produced the pass. If `Renderer.batch` ever narrows to a subtree
    /// using its own dirty set, it can pass that root here instead; nothing in
    /// this file would have to change.
    pub fn batch(root: Builder) -> Batch {
        self.out = new Batch()
        self.faults.clear()
        self.collect(root)
        self.out.disposed = root.registry.drain_disposed()
        return self.out
    }

    fn collect(b: Builder) {
        if !b.diffed {
            self.diff_component(b)
            b.diffed = true
        }
        var slots: List<int> = b.nested.keys()
        slots.sort()
        for slot: int in slots {
            match b.nested.get(slot) {
                some(child) => { self.collect(child) }
                none => {}
            }
        }
    }

    fn diff_component(b: Builder) {
        let update: ComponentUpdate = new ComponentUpdate(b.id)
        self.current = update
        self.old_frames = b.previous
        self.new_frames = b.frames
        self.merge(scan_spans(b.previous, 0, b.previous.len()),
                   scan_spans(b.frames, 0, b.frames.len()))
        if update.edits.len() > 0 { self.out.updates.push(update) }
    }

    fn push(edit: Edit) { self.current.edits.push(edit) }

    /// Copy a subtree's frames into the batch's reference pool and answer where
    /// they start.
    fn stage(span: Span, frames: Frames) -> int {
        let at: int = self.out.reference.len()
        var index: int = span.start
        for index < span.next {
            self.out.reference.push(frames.at(index))
            index += 1
        }
        return at
    }

    // ---- the sibling merge ------------------------------------------------
    //
    // Seqs inside a scope strictly increase, so one ordered walk answers all
    // three questions. `remove` leaves the cursor index alone because the next
    // sibling shifts into the hole; `insert` advances it because the inserted
    // child now occupies that position. That is only sound because the applier
    // applies edits strictly left to right, which it does.
    fn merge(old_spans: List<Span>, new_spans: List<Span>) {
        var olds: List<Unit> = group_units(old_spans)
        var news: List<Unit> = group_units(new_spans)
        var oi: int = 0
        var ni: int = 0
        var index: int = 0
        for oi < olds.len() || ni < news.len() {
            if ni >= news.len() {
                self.remove_unit(olds[oi], index)
                oi += 1
            } else if oi >= olds.len() {
                self.insert_unit(news[ni], index)
                index += news[ni].spans.len()
                ni += 1
            } else if olds[oi].seq < news[ni].seq {
                self.remove_unit(olds[oi], index)
                oi += 1
            } else if news[ni].seq < olds[oi].seq {
                self.insert_unit(news[ni], index)
                index += news[ni].spans.len()
                ni += 1
            } else {
                let o: Unit = olds[oi]
                let n: Unit = news[ni]
                if o.kind == SPAN_REGION && n.kind == SPAN_REGION {
                    index = self.keyed(o, n, index)
                } else if o.kind != n.kind {
                    // One source position cannot be two kinds in one render —
                    // branch arms get disjoint ranges — so this is either a
                    // markup-compiler bug or the fold switch being flipped
                    // between two renders of one component. Replacing is right
                    // either way.
                    self.remove_unit(o, index)
                    self.insert_unit(n, index)
                    index += n.spans.len()
                } else {
                    self.pair(o.spans[0], n.spans[0], index)
                    index += 1
                }
                oi += 1
                ni += 1
            }
        }
    }

    fn insert_unit(unit: Unit, index: int) {
        var k: int = 0
        for k < unit.spans.len() {
            self.push(Edit.insert(index + k, self.stage(unit.spans[k], self.new_frames)))
            k += 1
        }
    }

    fn remove_unit(unit: Unit, index: int) {
        var k: int = 0
        for k < unit.spans.len() {
            self.push(Edit.remove(index))
            k += 1
        }
    }

    fn replace(new_span: Span, index: int) {
        self.push(Edit.remove(index))
        self.push(Edit.insert(index, self.stage(new_span, self.new_frames)))
    }

    // ---- one matched pair -------------------------------------------------

    fn pair(o: Span, n: Span, index: int) {
        if o.kind == SPAN_TEXT {
            if o.html != n.html { self.push(Edit.set_text(index, n.html)) }
            return
        }
        if o.kind == SPAN_MARKUP {
            // A `constant` is compiler output and a `raw` is an author's
            // `$html(expr)`; they are never the same position.
            if o.raw != n.raw { self.replace(n, index); return }
            // The html is compared, not only the seq, even though a number
            // comparison would suffice if the markup compiler always gives
            // branch arms disjoint ranges. This guards against a compiler bug
            // that reuses one seq across two different constant subtrees,
            // which would produce valid-but-different HTML that silently
            // never updates. A string compare costs nothing next to a subtree
            // walk, so the differ still never walks one — the O(1) claim
            // holds.
            if o.html != n.html { self.push(Edit.set_markup(index, n.html)) }
            return
        }
        if o.kind == SPAN_MOUNT {
            // A mount is a LEAF here. The child's own frames live in its own
            // buffer and reach the client as a separate ComponentUpdate.
            if o.id != n.id { self.replace(n, index) }
            return
        }
        if o.kind == SPAN_ELEMENT {
            if o.tag != n.tag { self.replace(n, index); return }
            let oh: Head = read_head(self.old_frames, o)
            let nh: Head = read_head(self.new_frames, n)
            // `preserve` means the differ emits NOTHING for this element —
            // not its attributes and not its children — because the point is
            // that something else owns what is under there now. It is checked
            // on BOTH sides: if the old render preserved it, our old frames do
            // not describe what is in the DOM any more, so diffing against
            // them would emit edits for a tree we do not control.
            if oh.preserved || nh.preserved { return }
            self.push(Edit.step_in(index))
            let mark: int = self.current.edits.len()
            self.diff_attrs(oh.attrs, nh.attrs)
            self.diff_binds(oh.binds, nh.binds)
            self.merge(scan_spans(self.old_frames, o.body, o.stop),
                       scan_spans(self.new_frames, n.body, n.stop))
            self.close_step(mark)
            return
        }
        if o.kind == SPAN_BOUNDARY && o.failed != n.failed {
            // A boundary that failed and then rendered — or the other way — is
            // a content replacement. Matching it would leave the fallback and
            // the recovered body diffed against each other, which is a diff
            // between two unrelated trees that happen to share a scope.
            self.replace(n, index)
            return
        }
        if o.kind == SPAN_REGION && o.key != n.key {
            self.replace(n, index)
            return
        }
        // A region, a fragment or a boundary: transparent, no attributes.
        self.push(Edit.step_in(index))
        let mark: int = self.current.edits.len()
        self.merge(scan_spans(self.old_frames, o.body, o.stop),
                   scan_spans(self.new_frames, n.body, n.stop))
        self.close_step(mark)
    }

    /// Drop the `step_in` we speculatively pushed if the descent said nothing.
    /// Without this an unchanged page still costs one `in`/`out` pair per node,
    /// and "an unchanged constant subtree produces zero edits" would be false
    /// for every subtree that contains one.
    fn close_step(mark: int) {
        if self.current.edits.len() == mark {
            let _: Edit = self.current.edits.remove(mark - 1)
        } else {
            self.push(Edit.step_out)
        }
    }

    // ---- keyed rows -------------------------------------------------------
    //
    // Rows are matched by key, so a row that moved is moved and an appended row
    // is one insert. `live` holds, for each position the client currently has,
    // the index of the old row sitting there — or -1 for a row this batch built.
    //
    // Cost: the search for a row that moved scans forward from the current
    // position, so a full reversal of n rows is O(n^2). That is deliberate for
    // now. The pass is provably correct, emits at most n moves, and n is the
    // number of rows in ONE keyed loop — bounding that is `virtual.b`'s job,
    // not a cleverer diff. What would remove it is a longest-increasing-
    // subsequence pass, which also makes the two rotation directions cost the
    // same; today rotate-right is one move and rotate-left is n-1.
    // `tests/diff.b` asserts both numbers so the asymmetry is a golden rather
    // than a claim.
    fn keyed(o: Unit, n: Unit, base: int) -> int {
        var live: List<int> = []
        var p: int = 0
        for p < o.spans.len() {
            live.push(p)
            p += 1
        }

        var wanted: Map<string, bool> = {}
        for span: Span in n.spans { wanted[span.key] = true }

        // 1 — every row whose key is gone. The index does not advance: the
        // next row shifts into the hole.
        p = 0
        for p < live.len() {
            if wanted.contains_key(o.spans[live[p]].key) {
                p += 1
            } else {
                self.push(Edit.remove(base + p))
                let _: int = live.remove(p)
            }
        }

        // 2 — one left-to-right selection pass. At step p, positions before p
        // already hold the right rows, so the row wanted at p is either later
        // in `live` (a move) or not there at all (an insert).
        p = 0
        for p < n.spans.len() {
            let want: string = n.spans[p].key
            var here: bool = false
            if p < live.len() {
                if live[p] >= 0 && o.spans[live[p]].key == want { here = true }
            }
            if !here {
                var j: int = -1
                var k: int = p
                for k < live.len() {
                    if live[k] >= 0 && o.spans[live[k]].key == want {
                        j = k
                        break
                    }
                    k += 1
                }
                if j >= 0 {
                    self.push(Edit.relocate(base + j, base + p))
                    let owner: int = live.remove(j)
                    live.insert(p, owner)
                } else {
                    self.push(Edit.insert(base + p,
                        self.stage(n.spans[p], self.new_frames)))
                    live.insert(p, -1)
                }
            }
            p += 1
        }

        // 3 — bodies, only once the list is in its final order, because a
        // `step_in` names a position and the positions were still moving.
        p = 0
        for p < n.spans.len() {
            if p < live.len() {
                if live[p] >= 0 { self.pair(o.spans[live[p]], n.spans[p], base + p) }
            }
            p += 1
        }
        return base + n.spans.len()
    }

    // ---- attributes and handlers ------------------------------------------

    fn diff_attrs(old: List<Attr>, fresh: List<Attr>) {
        var oi: int = 0
        var ni: int = 0
        for oi < old.len() || ni < fresh.len() {
            if ni >= fresh.len() {
                self.push(Edit.remove_attr(old[oi].seq, old[oi].name))
                oi += 1
            } else if oi >= old.len() {
                self.set_slot(fresh[ni])
                ni += 1
            } else {
                let order: int = compare_slot(old[oi], fresh[ni])
                if order < 0 {
                    self.push(Edit.remove_attr(old[oi].seq, old[oi].name))
                    oi += 1
                } else if order > 0 {
                    self.set_slot(fresh[ni])
                    ni += 1
                } else {
                    if old[oi].flag != fresh[ni].flag ||
                       old[oi].present != fresh[ni].present ||
                       old[oi].value != fresh[ni].value {
                        self.set_slot(fresh[ni])
                    }
                    oi += 1
                    ni += 1
                }
            }
        }
    }

    fn set_slot(slot: Attr) {
        if slot.flag { self.push(Edit.set_flag(slot.seq, slot.name, slot.present)) }
        else { self.push(Edit.set_attr(slot.seq, slot.name, slot.value)) }
    }

    // Handlers are keyed rather than merged positionally, because a handler
    // frame writes no HTML at all and so its position among the other
    // attribute frames means nothing to anyone.
    fn diff_binds(old: List<Bind>, fresh: List<Bind>) {
        var have: Map<string, int> = {}
        for bind: Bind in fresh { have[bind_key(bind)] = bind.id }
        for bind: Bind in old {
            if !have.contains_key(bind_key(bind)) {
                self.push(Edit.remove_handler(bind.seq, bind.event))
            }
        }
        var had: Map<string, int> = {}
        for bind: Bind in old { had[bind_key(bind)] = bind.id }
        for bind: Bind in fresh {
            var send: bool = true
            match had.get(bind_key(bind)) {
                some(id) => { if id == bind.id { send = false } }
                none => {}
            }
            if send { self.push(Edit.set_handler(bind.seq, bind.event, bind.id)) }
        }
    }
}
