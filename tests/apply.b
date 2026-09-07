// PLAN.md gate 3, the Beans half: "a reference applier in Beans over thousands
// of random trees and mutations … required to land on the serializer's HTML of
// the new tree."
//
// The real `latte.js` half — the same edit stream against a real DOM — is W5's,
// and neither half stands in for the other. A text test proves the encoder
// consistent with itself; only a browser proves it means the same thing there.
//
// Two things about this suite are the whole point:
//
//   * **The generator obeys the builder's own rules.** Sibling sequence numbers
//     strictly increase inside a scope, `(seq, name)` strictly increases inside
//     one element's attribute run, a conditional node RESERVES its range so an
//     absent arm cannot renumber the arm beside it, and keys in one loop are
//     unique. A generator that ignored any of those would produce ten thousand
//     *faults* rather than ten thousand diffs, and every case would pass for
//     the wrong reason. Every case asserts the fault lists are empty, which is
//     what keeps that honest.
//   * **`preserve` is excluded, deliberately.** D6 says the differ emits
//     nothing at all for a preserved element, so "the applier lands on the
//     serializer's HTML" is knowingly false there. That divergence is asserted
//     by name — in both directions plus the resync — in `tests/diff.b` § 8, and
//     a fuzz that included it would only be able to assert a weaker thing.
//
// The named cases in § 1 and § 2 are shapes this sweep found. They are pinned
// by name because a fuzz that stops covering a shape goes quiet about it, and a
// named case does not.
package main

import std.io
import {Applier, Batch, Builder, Component, Differ, FocusEvent, InputEvent,
        KeyboardEvent, MouseEvent, Reference, Serializer, SubmitEvent,
        escape_attribute, escape_text} from latte

pub class Report {
    pub checks: int = 0
    pub bad: int = 0
    pub fn init() {}

    pub fn eq(name: string, got: string, want: string) {
        self.checks += 1
        if got == want {
            io.println("ok {name}")
        } else {
            self.bad += 1
            io.println("FAIL {name}: got {got}, want {want}")
        }
    }

    pub fn eqi(name: string, got: int, want: int) { self.eq(name, "{got}", "{want}") }
    pub fn yes(name: string, got: bool) { self.eq(name, "{got}", "true") }
    pub fn no(name: string, got: bool) { self.eq(name, "{got}", "false") }
}

// ---------------------------------------------------------------- randomness
//
// xorshift32, written here rather than taken from `std.random`. `std.random` is
// a CSPRNG: it is not seedable and not reproducible, and reproducibility is the
// entire value of a fuzz — a case that fails must be re-runnable from the seed
// printed beside it. Masking to 32 bits after every left shift keeps the state
// inside the range the algorithm is defined over, on a 64-bit int.

const M32: int = 4294967295

pub class Rng {
    state: int = 2463534242
    pub fn init(seed: int) {
        var s: int = seed & M32
        if s == 0 { s = 2463534242 }
        self.state = s
    }
    pub fn next() -> int {
        var x: int = self.state
        x = x ^ ((x << 13) & M32)
        x = x ^ (x >> 17)
        x = x ^ ((x << 5) & M32)
        x = x & M32
        self.state = x
        return x
    }
    /// A number in `[0, n)`.
    pub fn below(n: int) -> int {
        if n <= 1 { return 0 }
        return self.next() % n
    }
    pub fn chance(one_in: int) -> bool { return self.below(one_in) == 0 }
}

/// FNV-1a over every page the sweep produced, so the ten thousand cases are
/// part of the golden rather than merely counted by it. Two backends that
/// disagree about one byte of one case disagree about this number.
pub class Digest {
    pub value: int = 2166136261
    pub fn init() {}
    pub fn push(text: string) {
        var index: int = 0
        var h: int = self.value
        for index < text.len() {
            h = h ^ text.byte_at(index)
            h = (h * 16777619) & M32
            index += 1
        }
        self.value = h
    }
    pub fn push_int(value: int) { self.push("{value}") }
}

// ---------------------------------------------------------------- vocabulary

fn safe_tags() -> List<string> {
    var out: List<string> = ["div", "section", "p", "span", "b", "ul", "li", "article", "h1", "figure"]
    return move out
}
fn void_tags() -> List<string> { var out: List<string> = ["br", "hr", "img", "input", "wbr"]
    return move out }
fn raw_text_tags() -> List<string> { var out: List<string> = ["script", "style"]
    return move out }
fn rcdata_tags() -> List<string> { var out: List<string> = ["textarea", "title"]
    return move out }
fn newline_tags() -> List<string> { var out: List<string> = ["pre"]
    return move out }

/// Text bodies. The specials are here on purpose: `&`, `<`, `>` are escaped in
/// a text node and in RCDATA and written literally inside `<script>`, and a
/// body that begins with a newline is what the `<pre>` rule turns on.
fn text_bodies() -> List<string> {
    var out: List<string> = ["plain", "a<b", "x&y", "q\"z", "'apos'", "\nleading", "", "ünïcode",
                 "tab\there", "10 > 9", "&amp;"]
    return move out
}
/// `$html(expr)` bodies — author markup, written through untouched.
fn raw_bodies() -> List<string> {
    var out: List<string> = ["<i>i</i>", "<br>", "&amp;", "<b>x</b>", "", "a &lt; b"]
    return move out
}
/// Content for a raw-text element. Nothing here can close its own element or
/// open a comment-like state, which the serializer refuses.
fn code_bodies() -> List<string> {
    var out: List<string> = ["var x = 1;", "a < b && c > d;", "/* c */", ".k \{ color: red \}", ""]
    return move out
}
fn attr_names() -> List<string> {
    var out: List<string> = ["class", "id", "data-a", "data-b", "title", "role", "lang", "aria-label",
                 "href", "src"]
    return move out
}
fn attr_values() -> List<string> {
    var out: List<string> = ["a", "b<c", "d&e", "f\"g", "", "'h'", "one two"]
    return move out
}
/// `href` and `src` go through the scheme allowlist inside `attr`, so a refused
/// scheme would be a builder fault rather than a diff. The refusal has its own
/// named cases in `tests/frames.b`; here every URL is one the allowlist keeps.
fn url_values() -> List<string> {
    var out: List<string> = ["/x", "https://example.test/p", "#frag", "", "mailto:a@example.test"]
    return move out
}
fn flag_names() -> List<string> { var out: List<string> = ["hidden", "disabled", "checked", "required"]
    return move out }
fn splat_names() -> List<string> { var out: List<string> = ["class", "data-s1", "data-s2", "data-s3"]
    return move out }
fn row_pool() -> List<string> { var out: List<string> = ["a", "b", "c", "d", "e", "f", "g", "h"]
    return move out }

fn is_url_name(name: string) -> bool { return name == "href" || name == "src" }

// ---------------------------------------------------------------- template
//
// The template is a fixed SOURCE, with fixed sequence numbers, exactly as a
// generated `render` would be. What a mutation changes is the state the source
// reads — a condition, a value, a loop's rows — never the numbering. A node
// that a condition turns off leaves its reserved range unused, which is the
// same rule the folded arm of a constant subtree follows.

const T_ELEMENT: int = 0
const T_TEXT: int = 1
const T_RAW: int = 2
const T_FOLD: int = 3
const T_LOOP: int = 4
const T_FRAGMENT: int = 5
const T_BOUNDARY: int = 6
const T_MOUNT: int = 7

const S_ATTR: int = 0
const S_FLAG: int = 1
const S_SPLAT: int = 2
const S_HANDLER: int = 3
const S_REF: int = 4

pub class Slot {
    pub kind: int = 0
    pub seq: int = 0
    pub name: string = ""
    pub value: string = ""
    pub present: bool = true
    pub names: List<string> = []
    pub vals: List<string> = []
    pub live: List<bool> = []
    pub event: int = 0
    pub cond: int = -1
    pub fn init() {}
}

pub class Tnode {
    pub kind: int = 0
    pub seq: int = 0
    pub cond: int = -1
    pub tag: string = ""
    pub body: string = ""
    /// A foldable subtree: the folded arm's html, and the attribute the
    /// unfolded arm writes. Both arms reserve `seq` through `seq + 2`.
    pub fold_html: string = ""
    pub fold_name: string = ""
    pub fold_value: string = ""
    pub slots: List<Slot> = []
    pub kids: List<Tnode> = []
    /// A keyed loop: the pool it draws from, and the ordered subset it renders.
    pub pool: List<string> = []
    pub keys: List<string> = []
    /// A boundary that fails when this condition is on.
    pub fail_cond: int = -1
    /// A mounted child: which class, its parameters, and its `should_render`.
    pub which: int = 0
    pub label: string = ""
    pub rows: List<string> = []
    pub quiet_cond: int = -1
    pub fn init() {}

    pub fn set_keys(values: List<string>) {
        self.keys.clear()
        for value: string in values { self.keys.push(value) }
    }
}

pub class Model {
    pub roots: List<Tnode> = []
    pub bits: int = 0
    pub fn init() {}

    pub fn on(cond: int) -> bool {
        if cond < 0 { return true }
        return (self.bits >> cond) % 2 == 1
    }

    /// `quiet_cond` and `fail_cond` default OFF when unset, unlike `cond`.
    pub fn armed(cond: int) -> bool {
        if cond < 0 { return false }
        return self.on(cond)
    }

    pub fn render_into(b: Builder) { self.nodes(b, self.roots) }

    fn nodes(b: Builder, list: List<Tnode>) {
        for node: Tnode in list { self.node(b, node) }
    }

    fn node(b: Builder, n: Tnode) {
        if !self.on(n.cond) { return }
        if n.kind == T_TEXT { b.text(n.seq, n.body); return }
        if n.kind == T_RAW { b.raw(n.seq, n.body); return }
        if n.kind == T_FOLD {
            // Both arms, exactly as generated code writes them. The folded call
            // takes the subtree's FIRST number and the unfolded arm spends the
            // whole reserved range, so whatever comes next is numbered the same
            // either way.
            if b.fold {
                b.constant(n.seq, n.fold_html)
            } else {
                b.open(n.seq, n.tag)
                b.attr(n.seq + 1, n.fold_name, n.fold_value)
                b.text(n.seq + 2, n.body)
                b.close()
            }
            return
        }
        if n.kind == T_ELEMENT {
            b.open(n.seq, n.tag)
            for slot: Slot in n.slots { self.slot(b, slot) }
            self.nodes(b, n.kids)
            b.close()
            return
        }
        if n.kind == T_LOOP {
            for key: string in n.keys {
                b.region(n.seq, key)
                self.nodes(b, n.kids)
                b.end_region()
            }
            return
        }
        if n.kind == T_FRAGMENT {
            b.fragment(n.seq, fn(inner: Builder) { self.nodes(inner, n.kids) })
            return
        }
        if n.kind == T_BOUNDARY {
            b.boundary(n.seq)
            if self.armed(n.fail_cond) {
                // A panic partway through the body: some of it was written, and
                // `fail_boundary` has to undo all of it before the fallback.
                var index: int = 0
                let half: int = n.kids.len() / 2
                for index < half {
                    self.node(b, n.kids[index])
                    index += 1
                }
                b.fail_boundary("boom at {n.seq}")
                b.text(0, "fallback {n.seq}")
            } else {
                self.nodes(b, n.kids)
            }
            b.end_boundary()
            return
        }
        if n.kind == T_MOUNT {
            if n.which == 0 {
                b.component<KidA>(n.seq, fn(c: KidA) {
                    c.label = n.label
                    c.quiet = self.armed(n.quiet_cond)
                    c.set_rows(n.rows)
                })
            } else {
                b.component<KidB>(n.seq, fn(c: KidB) {
                    c.label = n.label
                    c.quiet = self.armed(n.quiet_cond)
                    c.set_rows(n.rows)
                })
            }
            return
        }
    }

    fn slot(b: Builder, s: Slot) {
        if !self.on(s.cond) { return }
        if s.kind == S_ATTR { b.attr(s.seq, s.name, s.value); return }
        if s.kind == S_FLAG { b.flag(s.seq, s.name, s.present); return }
        if s.kind == S_SPLAT {
            var extra: Map<string, string> = {}
            var index: int = 0
            for index < s.names.len() {
                if s.live[index] { extra[s.names[index]] = s.vals[index] }
                index += 1
            }
            b.attrs(s.seq, extra)
            return
        }
        if s.kind == S_REF { b.reference(s.seq, fn(h: Reference) {}); return }
        bind_event(b, s.seq, s.event)
    }
}

fn bind_event(b: Builder, seq: int, which: int) {
    if which == 0 { b.on_click(seq, fn(e: MouseEvent) {}) }
    else if which == 1 { b.on_dblclick(seq, fn(e: MouseEvent) {}) }
    else if which == 2 { b.on_mouseover(seq, fn(e: MouseEvent) {}) }
    else if which == 3 { b.on_input(seq, fn(e: InputEvent) {}) }
    else if which == 4 { b.on_change(seq, fn(e: InputEvent) {}) }
    else if which == 5 { b.on_keydown(seq, fn(e: KeyboardEvent) {}) }
    else if which == 6 { b.on_submit(seq, fn(e: SubmitEvent) {}) }
    else if which == 7 { b.on_focus(seq, fn(e: FocusEvent) {}) }
    else { b.on_blur(seq, fn(e: FocusEvent) {}) }
}

// ---------------------------------------------------------------- children

pub class KidA extends Component {
    pub label: string = ""
    pub rows: List<string> = []
    pub quiet: bool = false
    pub fn init() {}
    pub fn set_rows(values: List<string>) {
        self.rows.clear()
        for value: string in values { self.rows.push(value) }
    }
    pub override fn should_render() -> bool { return !self.quiet }
    pub override fn render(b: Builder) {
        b.open(0, "div")
        b.attr(1, "class", "kid")
        b.text(2, self.label)
        b.open(3, "ul")
        for row: string in self.rows {
            b.region(4, row)
            b.open(0, "li")
            b.attr(1, "data-k", row)
            b.on_click(2, fn(e: MouseEvent) {})
            b.text(3, row)
            b.close()
            b.end_region()
        }
        b.close()
        b.close()
    }
}

/// Three levels deep: the sweep's root mounts a `KidB`, which mounts a `KidA`,
/// which runs a keyed loop of its own. A batch therefore carries updates for a
/// component whose parent is itself a mounted child.
pub class KidB extends Component {
    pub label: string = ""
    pub rows: List<string> = []
    pub quiet: bool = false
    pub fn init() {}
    pub fn set_rows(values: List<string>) {
        self.rows.clear()
        for value: string in values { self.rows.push(value) }
    }
    pub override fn should_render() -> bool { return !self.quiet }
    pub override fn render(b: Builder) {
        b.open(0, "section")
        b.attr(1, "data-label", self.label)
        b.component<KidA>(2, fn(c: KidA) {
            c.label = "in-{self.label}"
            c.set_rows(self.rows)
        })
        b.close()
    }
}

pub class Fuzz extends Component {
    pub model: Model = new Model()
    pub fn init() {}
    pub override fn render(b: Builder) { self.model.render_into(b) }
}

// ---------------------------------------------------------------- generation

pub class Gen {
    pub rng: Rng = new Rng(1)
    pub budget: int = 0
    pub conds: int = 8
    /// One counter per node kind, so the golden says what the sweep actually
    /// built rather than what it was asked to build.
    pub made: List<int> = [0, 0, 0, 0, 0, 0, 0, 0]
    pub fn init(seed: int) { self.rng = new Rng(seed) }
    pub fn pick(list: List<string>) -> string { return list[self.rng.below(list.len())] }
}

fn gen_list(g: Gen, depth: int, start: int, into: List<Tnode>) -> int {
    var cursor: int = start
    var wanted: int = 2 + g.rng.below(3)
    if depth <= 0 { wanted = 1 + g.rng.below(3) }
    var index: int = 0
    for index < wanted {
        if g.budget <= 0 { break }
        cursor = gen_node(g, depth, cursor, into)
        index += 1
    }
    return cursor
}

fn gen_node(g: Gen, depth: int, start: int, into: List<Tnode>) -> int {
    g.budget -= 1
    let node: Tnode = new Tnode()
    node.seq = start
    var cursor: int = start + 1

    var kind: int = T_TEXT
    let pick: int = g.rng.below(100)
    if depth <= 0 {
        if pick < 45 { kind = T_TEXT }
        else if pick < 65 { kind = T_RAW }
        else if pick < 85 { kind = T_FOLD }
        else { kind = T_ELEMENT }
    } else {
        if pick < 22 { kind = T_ELEMENT }
        else if pick < 36 { kind = T_TEXT }
        else if pick < 44 { kind = T_RAW }
        else if pick < 54 { kind = T_FOLD }
        else if pick < 72 { kind = T_LOOP }
        else if pick < 79 { kind = T_FRAGMENT }
        else if pick < 86 { kind = T_BOUNDARY }
        else { kind = T_MOUNT }
    }
    node.kind = kind
    g.made[kind] = g.made[kind] + 1
    // A quarter of the nodes are behind a condition. A condition that is off
    // leaves the node's whole reserved range unused, which is what makes two
    // arms of one branch impossible to confuse.
    if g.rng.chance(4) { node.cond = g.rng.below(g.conds) }

    if kind == T_TEXT {
        node.body = g.pick(text_bodies())
        into.push(node)
        return cursor
    }
    if kind == T_RAW {
        node.body = g.pick(raw_bodies())
        into.push(node)
        return cursor
    }
    if kind == T_FOLD {
        node.tag = g.pick(["b", "i", "span", "em"])
        node.fold_name = g.pick(["class", "id", "title"])
        node.fold_value = g.pick(attr_values())
        node.body = g.pick(text_bodies())
        node.fold_html = "<{node.tag} {node.fold_name}=\"{escape_attribute(node.fold_value)}\">{escape_text(node.body)}</{node.tag}>"
        into.push(node)
        return start + 3
    }
    if kind == T_ELEMENT {
        let shape: int = g.rng.below(100)
        var void_element: bool = false
        var raw_text: bool = false
        var rcdata: bool = false
        if shape < 62 { node.tag = g.pick(safe_tags()) }
        else if shape < 76 { node.tag = g.pick(void_tags()); void_element = true }
        else if shape < 84 { node.tag = g.pick(raw_text_tags()); raw_text = true }
        else if shape < 93 { node.tag = g.pick(rcdata_tags()); rcdata = true }
        else { node.tag = g.pick(newline_tags()) }

        let slots: int = g.rng.below(4)
        var made: int = 0
        for made < slots {
            cursor = gen_slot(g, cursor, node.slots)
            made += 1
        }
        if void_element {
            into.push(node)
            return cursor
        }
        if raw_text {
            // Only a literal body: content that could close a `<script>` is a
            // serializer refusal, and this sweep asserts there are none.
            let text: Tnode = new Tnode()
            text.kind = T_TEXT
            text.seq = cursor
            text.body = g.pick(code_bodies())
            node.kids.push(text)
            g.made[T_TEXT] = g.made[T_TEXT] + 1
            cursor += 1
            into.push(node)
            return cursor
        }
        var inner: int = depth - 1
        if rcdata { inner = 0 }
        if depth > 0 { cursor = gen_list(g, inner, cursor, node.kids) }
        else if g.rng.chance(2) { cursor = gen_node(g, -1, cursor, node.kids) }
        into.push(node)
        return cursor
    }
    if kind == T_LOOP || kind == T_FRAGMENT || kind == T_BOUNDARY {
        if kind == T_LOOP {
            var pool: List<string> = row_pool()
            let size: int = 3 + g.rng.below(4)
            var index: int = 0
            for index < size {
                node.pool.push(pool[index])
                index += 1
            }
            let rows: int = g.rng.below(node.pool.len() + 1)
            index = 0
            for index < rows {
                node.keys.push(node.pool[index])
                index += 1
            }
        }
        if kind == T_BOUNDARY && g.rng.chance(2) { node.fail_cond = g.rng.below(g.conds) }
        // A region, a fragment and a boundary each restart numbering at 0.
        let _: int = gen_list(g, depth - 1, 0, node.kids)
        into.push(node)
        return cursor
    }
    // T_MOUNT
    node.which = g.rng.below(2)
    node.label = g.pick(text_bodies())
    var pool: List<string> = row_pool()
    let rows: int = g.rng.below(5)
    var index: int = 0
    for index < rows {
        node.rows.push(pool[index])
        index += 1
    }
    if g.rng.chance(4) { node.quiet_cond = g.rng.below(g.conds) }
    into.push(node)
    return cursor
}

fn gen_slot(g: Gen, start: int, into: List<Slot>) -> int {
    let slot: Slot = new Slot()
    slot.seq = start
    let pick: int = g.rng.below(100)
    if pick < 45 {
        slot.kind = S_ATTR
        slot.name = g.pick(attr_names())
        if is_url_name(slot.name) { slot.value = g.pick(url_values()) }
        else { slot.value = g.pick(attr_values()) }
    } else if pick < 65 {
        slot.kind = S_FLAG
        slot.name = g.pick(flag_names())
        slot.present = g.rng.chance(2)
    } else if pick < 77 {
        slot.kind = S_SPLAT
        var names: List<string> = splat_names()
        var index: int = 0
        for index < names.len() {
            slot.names.push(names[index])
            slot.vals.push(g.pick(attr_values()))
            slot.live.push(g.rng.chance(2))
            index += 1
        }
    } else if pick < 95 {
        slot.kind = S_HANDLER
        slot.event = g.rng.below(9)
    } else {
        slot.kind = S_REF
    }
    if g.rng.chance(4) { slot.cond = g.rng.below(g.conds) }
    into.push(slot)
    return start + 1
}

// ---------------------------------------------------------------- mutation

fn collect(node: Tnode, nodes: List<Tnode>, slots: List<Slot>) {
    nodes.push(node)
    for slot: Slot in node.slots { slots.push(slot) }
    for kid: Tnode in node.kids { collect(kid, nodes, slots) }
}

fn of_kind(nodes: List<Tnode>, kind: int, into: List<Tnode>) {
    for node: Tnode in nodes {
        if node.kind == kind { into.push(node) }
    }
}

fn slots_of_kind(slots: List<Slot>, kind: int, into: List<Slot>) {
    for slot: Slot in slots {
        if slot.kind == kind { into.push(slot) }
    }
}

/// One ordered subset of a pool becomes another. Every op keeps the keys
/// unique, because a duplicate key in one loop is a builder fault (it is
/// suffixed `#dup<n>` and reported), and this sweep asserts there are none.
fn mutate_keys(g: Gen, node: Tnode) {
    let op: int = g.rng.below(7)
    let size: int = node.keys.len()
    if op == 0 || size == 0 {
        // add a key the list does not have, at a random position
        var candidates: List<string> = []
        for key: string in node.pool {
            var held: bool = false
            for have: string in node.keys { if have == key { held = true } }
            if !held { candidates.push(key) }
        }
        if candidates.len() == 0 { return }
        let key: string = candidates[g.rng.below(candidates.len())]
        node.keys.insert(g.rng.below(size + 1), key)
        return
    }
    if op == 1 {
        let _: string = node.keys.remove(g.rng.below(size))
        return
    }
    if op == 2 && size > 1 {
        let a: int = g.rng.below(size)
        let b: int = g.rng.below(size)
        let held: string = node.keys[a]
        node.keys[a] = node.keys[b]
        node.keys[b] = held
        return
    }
    if op == 3 && size > 1 {
        let head: string = node.keys.remove(0)
        node.keys.push(head)
        return
    }
    if op == 4 && size > 1 {
        let tail: string = node.keys.remove(size - 1)
        node.keys.insert(0, tail)
        return
    }
    if op == 5 && size > 1 {
        var lo: int = 0
        var hi: int = size - 1
        for lo < hi {
            let held: string = node.keys[lo]
            node.keys[lo] = node.keys[hi]
            node.keys[hi] = held
            lo += 1
            hi -= 1
        }
        return
    }
    // a full reshuffle of a fresh subset
    var wanted: List<string> = []
    for key: string in node.pool {
        if g.rng.chance(2) { wanted.push(key) }
    }
    var index: int = wanted.len() - 1
    for index > 0 {
        let j: int = g.rng.below(index + 1)
        let held: string = wanted[index]
        wanted[index] = wanted[j]
        wanted[j] = held
        index -= 1
    }
    node.set_keys(wanted)
}

fn mutate_rows(g: Gen, node: Tnode) {
    var pool: List<string> = row_pool()
    var wanted: List<string> = []
    var index: int = 0
    for index < 5 {
        if g.rng.chance(2) { wanted.push(pool[index]) }
        index += 1
    }
    index = wanted.len() - 1
    for index > 0 {
        let j: int = g.rng.below(index + 1)
        let held: string = wanted[index]
        wanted[index] = wanted[j]
        wanted[j] = held
        index -= 1
    }
    node.rows.clear()
    for key: string in wanted { node.rows.push(key) }
}

pub class Tree {
    pub model: Model = new Model()
    pub nodes: List<Tnode> = []
    pub slots: List<Slot> = []
    pub texts: List<Tnode> = []
    pub loops: List<Tnode> = []
    pub mounts: List<Tnode> = []
    pub fn init() {}
}

fn build_tree(g: Gen, depth: int) -> Tree {
    let tree: Tree = new Tree()
    g.budget = 12 + g.rng.below(12)
    let _: int = gen_list(g, depth, 0, tree.model.roots)
    tree.model.bits = g.rng.next() & 255
    for node: Tnode in tree.model.roots { collect(node, tree.nodes, tree.slots) }
    of_kind(tree.nodes, T_TEXT, tree.texts)
    of_kind(tree.nodes, T_RAW, tree.texts)
    of_kind(tree.nodes, T_LOOP, tree.loops)
    of_kind(tree.nodes, T_MOUNT, tree.mounts)
    return tree
}

fn mutate(g: Gen, tree: Tree, b: Builder) {
    let roll: int = g.rng.below(100)
    if roll < 26 {
        tree.model.bits = tree.model.bits ^ (1 << g.rng.below(g.conds))
        return
    }
    if roll < 44 && tree.loops.len() > 0 {
        mutate_keys(g, tree.loops[g.rng.below(tree.loops.len())])
        return
    }
    if roll < 58 && tree.texts.len() > 0 {
        let node: Tnode = tree.texts[g.rng.below(tree.texts.len())]
        if node.kind == T_RAW { node.body = g.pick(raw_bodies()) }
        else { node.body = g.pick(text_bodies()) }
        return
    }
    if roll < 74 && tree.slots.len() > 0 {
        let slot: Slot = tree.slots[g.rng.below(tree.slots.len())]
        if slot.kind == S_ATTR {
            if is_url_name(slot.name) { slot.value = g.pick(url_values()) }
            else { slot.value = g.pick(attr_values()) }
        } else if slot.kind == S_FLAG {
            slot.present = !slot.present
        } else if slot.kind == S_SPLAT {
            let which: int = g.rng.below(slot.names.len())
            if g.rng.chance(2) { slot.live[which] = !slot.live[which] }
            else { slot.vals[which] = g.pick(attr_values()) }
        } else if slot.kind == S_HANDLER {
            slot.event = g.rng.below(9)
        }
        return
    }
    if roll < 90 && tree.mounts.len() > 0 {
        let node: Tnode = tree.mounts[g.rng.below(tree.mounts.len())]
        if g.rng.chance(2) { node.label = g.pick(text_bodies()) }
        else { mutate_rows(g, node) }
        return
    }
    if roll < 94 {
        // The debug switch, flipped under a live builder. Every foldable
        // subtree changes KIND at one sequence number, which is a replacement
        // the applier has to follow.
        b.fold = !b.fold
        return
    }
    // fall back to a condition flip, so a tree with no loops and no mounts
    // still moves
    tree.model.bits = tree.model.bits ^ (1 << g.rng.below(g.conds))
}

// ---------------------------------------------------------------- invariants

fn buffer_count(b: Builder) -> int {
    var total: int = 0
    var slots: List<int> = b.nested.keys()
    slots.sort()
    for slot: int in slots {
        match b.nested.get(slot) {
            some(child) => { total += 1 + buffer_count(child) }
            none => {}
        }
    }
    return total
}

/// Every mounted component in the builder tree, in slot order.
fn buffer_ids(b: Builder, into: List<int>) {
    var slots: List<int> = b.nested.keys()
    slots.sort()
    for slot: int in slots {
        match b.nested.get(slot) {
            some(child) => {
                into.push(slot)
                buffer_ids(child, into)
            }
            none => {}
        }
    }
}

fn ints_to_text(values: List<int>) -> string {
    var out: string = ""
    for value: int in values { out = "{out} {value}" }
    return out
}

pub class Verdict {
    pub ok: bool = true
    pub why: string = ""
    pub edits: int = 0
    pub want: string = ""
    pub got: string = ""
    pub fn init() {}
    pub fn fail(reason: string) { self.ok = false; self.why = reason }
}

/// One case: render, diff, apply, and check every invariant that must hold
/// between the two sides. This is `Harness.quiet_step()` from `tests/diff.b`
/// with the checks it left implicit made explicit, because a sweep of ten
/// thousand cases can only report what it was told to look at.
fn one_case(fuzz: Fuzz, b: Builder, d: Differ, a: Applier, digest: Digest) -> Verdict {
    let verdict: Verdict = new Verdict()
    b.render_root(fuzz)
    let batch: Batch = d.batch(b)
    a.apply(batch)
    verdict.edits = batch.edit_count()

    let writer: Serializer = new Serializer()
    verdict.want = writer.page(b)
    verdict.got = a.html()
    digest.push(verdict.want)
    digest.push_int(verdict.edits)

    if verdict.want != verdict.got { verdict.fail("the applier landed somewhere else") }
    else if d.faults.len() > 0 { verdict.fail("differ: {d.faults[0]}") }
    else if a.faults.len() > 0 { verdict.fail("applier: {a.faults[0]}") }
    else if b.all_faults().len() > 0 { verdict.fail("builder: {b.all_faults()[0]}") }
    else if writer.faults.len() > 0 { verdict.fail("serializer: {writer.faults[0]}") }
    else if a.serializer_faults.len() > 0 {
        verdict.fail("applier's serializer: {a.serializer_faults[0]}")
    } else {
        // The applier holds one root node per mounted component. A component
        // the builder dropped without telling the applier, or one the applier
        // never heard of, never shows in the HTML — nothing renders it — so
        // this is the only check that can see either.
        //
        // The page root, component 0, is not in this comparison: the applier
        // allocates it when the first update addressed to it arrives, and a
        // page that renders nothing at all has no updates and no root.
        var mounted: List<int> = []
        buffer_ids(b, mounted)
        var held: List<int> = []
        for id: int in a.roots.keys() {
            if id != 0 { held.push(id) }
        }
        held.sort()
        mounted.sort()
        if ints_to_text(held) != ints_to_text(mounted) {
            verdict.fail("the applier holds components{ints_to_text(held)}, the builder has{ints_to_text(mounted)}")
        }
    }
    a.faults.clear()
    return verdict
}

/// The same page again with nothing changed must produce an EMPTY batch. That
/// is the headline claim of the whole update model, and it is also the strongest
/// determinism check there is: anything that leaked a map's iteration order or
/// a fresh id into the frames shows up here as an edit.
fn steady(fuzz: Fuzz, b: Builder, d: Differ, a: Applier) -> int {
    b.render_root(fuzz)
    let batch: Batch = d.batch(b)
    a.apply(batch)
    return batch.edit_count()
}

// ---------------------------------------------------------------- § 1
//
// Shapes this sweep found. They are pinned by name because a fuzz that stops
// covering a shape goes quiet about it, and a named case does not.

/// A child with state of its own, so "the same instance came back" is
/// something the page can show rather than something the test asserts about
/// pointers.
pub class Kid extends Component {
    pub label: string = "kid"
    pub renders: int = 0
    pub quiet: bool = false
    pub fn init() {}
    pub override fn should_render() -> bool { return !self.quiet }
    pub override fn render(b: Builder) {
        self.renders += 1
        b.open(0, "em")
        b.text(1, "{self.label}/{self.renders}")
        b.close()
    }
}

/// A dynamic tag name — `b.open(0, self.tag)` — with mounted children under it,
/// one directly and one a level down. When the tag changes the differ replaces
/// the whole element, while `component<Kid>` kept both slots live, so neither
/// child is disposed and neither sends any edits of its own.
pub class TagFlip extends Component {
    pub tag: string = "div"
    pub hush: bool = false
    pub fn init() {}
    pub override fn render(b: Builder) {
        b.open(0, self.tag)
        b.text(1, "before ")
        b.component<Kid>(2, fn(c: Kid) { c.label = "top"; c.quiet = self.hush })
        b.open(3, "p")
        b.component<Kid>(4, fn(c: Kid) { c.label = "deep"; c.quiet = self.hush })
        b.close()
        b.close()
    }
}

/// An error boundary whose body mounts a child, binds a handler, and then
/// panics.
pub class Boom extends Component {
    pub fail: bool = false
    pub fn init() {}
    pub override fn render(b: Builder) {
        b.open(0, "div")
        b.boundary(1)
        b.open(0, "p")
        b.on_click(1, fn(e: MouseEvent) {})
        b.component<Kid>(2, fn(c: Kid) { c.label = "inside" })
        b.close()
        if self.fail {
            b.fail_boundary("boom")
            b.text(0, "fallback")
        }
        b.end_boundary()
        b.close()
    }
}

fn mount_reinsert(r: Report) {
    io.println("== 1 a mount frame that is re-inserted brings its subtree back")
    // A mount frame is a LEAF: it names a component and carries none of that
    // component's content. So an applier that builds an EMPTY node for a
    // re-inserted mount loses the child's whole subtree — silently and for
    // good, because the child's own update carries only what CHANGED and an
    // unchanged child sends nothing at all. The sweep found this with no fault
    // on any side; only the HTML said so.
    let host: TagFlip = new TagFlip()
    let b: Builder = new Builder()
    let a: Applier = new Applier()
    let d: Differ = new Differ()
    b.render_root(host)
    a.apply(d.batch(b))
    let w1: Serializer = new Serializer()
    r.eq("both children are there to begin with", a.html(), w1.page(b))
    r.eq("the first page", a.html(),
        "<div>before <em>top/1</em><p><em>deep/1</em></p></div>")

    host.tag = "section"
    b.render_root(host)
    let flip: Batch = d.batch(b)
    io.print(flip.dump())
    a.apply(flip)
    let w2: Serializer = new Serializer()
    r.eq("the element's tag changed under two mounted children", a.html(), w2.page(b))
    // The children were NOT re-activated — their render counters climb rather
    // than reset — so an applier that rebuilt them from their own updates would
    // have had nothing to rebuild from.
    r.eq("and both subtrees came with it", a.html(),
        "<section>before <em>top/2</em><p><em>deep/2</em></p></section>")
    // One remove and one insert for the element, plus each child's own two
    // edits for its render counter. The children's edits land INSIDE the node
    // the insert rebuilt, which is the second thing this case pins: an applier
    // that built an empty node would fault on `text 0 of 0`.
    r.eqi("one remove, one insert, and each child's own update", flip.edit_count(), 8)
    r.eqi("nothing was disposed", flip.disposed.len(), 0)
    r.eqi("no faults", d.faults.len() + a.faults.len() + b.all_faults().len(), 0)

    // Now the case with nothing to rebuild from. Both children answer
    // `should_render() == false`, so they are not re-rendered and send no edits
    // at all — and the batch is the two element edits and nothing else. An
    // applier that built an empty mount node here would print
    // `<div>before <p></p></div>` with no fault anywhere, which is exactly how
    // this shipped before the sweep found it.
    host.hush = true
    host.tag = "div"
    b.render_root(host)
    let quiet: Batch = d.batch(b)
    io.print(quiet.dump())
    a.apply(quiet)
    let w3: Serializer = new Serializer()
    r.eq("and back, with both children silent", a.html(), w3.page(b))
    r.eqi("the batch is the element and nothing else", quiet.edit_count(), 2)
    r.eq("and the silent children are still on the page", a.html(),
        "<div>before <em>top/2</em><p><em>deep/2</em></p></div>")
    r.eqi("no faults", d.faults.len() + a.faults.len() + b.all_faults().len(), 0)
}

fn boundary_takes_its_mounts(r: Report) {
    io.println("== 2 a failed boundary takes its body's mounts with it")
    // `fail_boundary` drops everything the body wrote. Slots are the sixth
    // thing it writes — after frames, depth, regions, scopes and paths — and
    // they were the one it did not unwind. A mount left behind by a failed
    // boundary is a component that is not on the page, whose `dispose` never
    // runs, whose handlers a stale wire id can still reach, and whose buffer
    // still holds unsent frames — which arrives at the applier as "update for
    // component N arrived before its mount". The sweep found it that way.
    let boom: Boom = new Boom()
    let b: Builder = new Builder()
    let a: Applier = new Applier()
    let d: Differ = new Differ()
    b.render_root(boom)
    a.apply(d.batch(b))
    let w1: Serializer = new Serializer()
    r.eq("the body rendered", a.html(), w1.page(b))
    r.eq("the page", a.html(), "<div><p><em>inside/1</em></p></div>")
    r.eqi("one child, one handler", b.nested.keys().len() + b.registry.mouse.keys().len(), 2)
    var first: List<int> = b.nested.keys()

    boom.fail = true
    b.render_root(boom)
    let broke: Batch = d.batch(b)
    io.print(broke.dump())
    a.apply(broke)
    let w2: Serializer = new Serializer()
    r.eq("the fallback replaced it", a.html(), w2.page(b))
    r.eq("and the page says so", a.html(), "<div>fallback</div>")
    r.eqi("the child buffer went with the body", b.nested.keys().len(), 0)
    r.eqi("and so did the handler", b.registry.mouse.keys().len(), 0)
    r.eqi("the applier was told to drop it", broke.disposed.len(), 1)
    r.eqi("and it holds no component roots now", a.roots.keys().len(), 1)
    r.eqi("no faults", d.faults.len() + a.faults.len() + b.all_faults().len(), 0)

    boom.fail = false
    b.render_root(boom)
    let back: Batch = d.batch(b)
    io.print(back.dump())
    a.apply(back)
    let w3: Serializer = new Serializer()
    r.eq("recovering renders the body again", a.html(), w3.page(b))
    // A NEW instance: a failed boundary discards its content, so the child that
    // comes back has never rendered before. Its counter says so.
    r.eq("with a fresh child", a.html(), "<div><p><em>inside/1</em></p></div>")
    var second: List<int> = b.nested.keys()
    r.eqi("one child again", second.len(), 1)
    r.no("and it is not the one that went down with the boundary",
        first[0] == second[0])
    r.eqi("no faults", d.faults.len() + a.faults.len() + b.all_faults().len(), 0)
}

// ---------------------------------------------------------------- § 2

const MASTER_SEED: int = 20260908
const TREES: int = 100
const STEPS: int = 10

fn sweep(r: Report) {
    io.println("== 3 {TREES} random trees, {STEPS} mutations each")
    let digest: Digest = new Digest()
    var cases: int = 0
    var bad: int = 0
    var reported: int = 0
    var worst: int = 0
    var total_edits: int = 0
    var steady_checked: int = 0
    var steady_bad: int = 0
    var peak_components: int = 0
    var kinds: List<int> = [0, 0, 0, 0, 0, 0, 0, 0]

    var tree_index: int = 0
    for tree_index < TREES {
        let seed: int = (MASTER_SEED + tree_index * 2654435761) & M32
        let g: Gen = new Gen(seed)
        let depth: int = 2 + (tree_index % 2)
        let tree: Tree = build_tree(g, depth)
        var kind: int = 0
        for kind < 8 {
            kinds[kind] = kinds[kind] + g.made[kind]
            kind += 1
        }

        let fuzz: Fuzz = new Fuzz()
        fuzz.model = tree.model
        let b: Builder = new Builder()
        let a: Applier = new Applier()
        let d: Differ = new Differ()

        var step: int = 0
        for step < STEPS {
            if step > 0 { mutate(g, tree, b) }
            let verdict: Verdict = one_case(fuzz, b, d, a, digest)
            cases += 1
            total_edits += verdict.edits
            if verdict.edits > worst { worst = verdict.edits }
            let components: int = 1 + buffer_count(b)
            if components > peak_components { peak_components = components }
            if !verdict.ok {
                bad += 1
                if reported < 3 {
                    reported += 1
                    io.println("-- FAIL tree {tree_index} (seed {seed}) step {step}: {verdict.why}")
                    io.println("   want {verdict.want}")
                    io.println("   got  {verdict.got}")
                    io.println("   builder frames:")
                    io.print(b.dump_tree())
                    io.println("   applier frames:")
                    io.print(a.dump())
                }
            } else {
                let again: int = steady(fuzz, b, d, a)
                steady_checked += 1
                if again != 0 {
                    steady_bad += 1
                    if reported < 3 {
                        reported += 1
                        io.println("-- FAIL tree {tree_index} (seed {seed}) step {step}: an unchanged render produced {again} edit(s)")
                        io.print(b.dump_tree())
                    }
                }
            }
            step += 1
        }
        tree_index += 1
    }

    io.println("seed: {MASTER_SEED}")
    io.println("cases: {cases}")
    io.println("nodes generated: element {kinds[0]}, text {kinds[1]}, raw {kinds[2]}, constant {kinds[3]}, loop {kinds[4]}, fragment {kinds[5]}, boundary {kinds[6]}, mount {kinds[7]}")
    io.println("edits: {total_edits} total, worst batch {worst}")
    io.println("peak live components in one tree: {peak_components}")
    io.println("digest: {digest.value}")
    r.eqi("every case in the sweep ran", cases, 1000)
    r.eqi("every one applied to the serializer's html", bad, 0)
    r.eqi("and every one was checked for a steady state", steady_checked, cases)
    r.eqi("an unchanged render is always an empty batch", steady_bad, 0)
    r.yes("the sweep built every node kind", kinds[0] > 0 && kinds[1] > 0 &&
        kinds[2] > 0 && kinds[3] > 0 && kinds[4] > 0 && kinds[5] > 0 &&
        kinds[6] > 0 && kinds[7] > 0)
    r.yes("and mounted components three levels deep", peak_components >= 3)
}

fn main() {
    let r: Report = new Report()
    mount_reinsert(r)
    boundary_takes_its_mounts(r)
    sweep(r)
    io.println("== summary")
    io.println("checks: {r.checks}, failed: {r.bad}")
}
