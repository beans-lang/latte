// tests/js_cases.b — the fixtures the browser applier is judged against.
//
// PLAN.md gate 3 is "apply equivalence", and it names TWO appliers: "a
// reference applier in Beans over thousands of random trees and mutations,
// **and** the real `latte.js` applier over a small DOM, both required to land
// on the serializer's HTML of the new tree." `tests/apply.b` is the first half.
// This file is the input to the second: it drives real components through a
// real `Renderer` and a real `Differ`, and prints — as a JavaScript source
// file — every batch that came out, together with three things the browser has
// to reproduce for each one:
//
//   `h`  the SERIALIZER's HTML of the new tree. The thing gate 3 names.
//   `a`  the Beans applier's HTML. Equal to `h`, and emitted separately so a
//        browser mismatch says WHICH of the two it disagrees with.
//   `d`  the Beans applier's frame dump. The strongest of the three: it is the
//        logical TREE the applier reconstructed, so a browser that lands on
//        the right HTML by luck still fails here.
//
// The suite's own golden is that JavaScript file, so both backends must emit
// it byte for byte and a change to any of frames.b, builder.b, diff.b, apply.b
// or serialize.b that moves a batch shows up here as a diff a person reads.
// `test.sh`'s js-apply leg then feeds the same file to headless Chrome.
//
// The refusal cases are NOT here. They are hand-built batches with no Beans
// counterpart yet — apply.b does not implement the kind rules — and they live
// in `tests/js_apply.js` beside the expectations the contract fixes. See
// lanes/W5.md § "THE APPLIER CONTRACT".
package main

import std.io
import std.fmt
import {Applier, Batch, Builder, Component, ErrorBoundary, InputEvent,
        MouseEvent, Renderer, encode_batch, write_json_string} from latte

// ============================================================== components
//
// Every shape the applier has to hold is here, and each is driven by a field
// so one class serves the first render and every mutation after it. Two
// classes would let the two drift.

/// The deepest child: one element, one attribute, one text node.
pub class Leaf extends Component {
    pub label: string = ""
    pub tone: string = "plain"
    pub fn init() {}
    pub override fn render(b: Builder) {
        b.open(0, "em")
        b.attr(1, "class", self.tone)
        b.text(2, self.label)
        b.close()
    }
}

/// A child that mounts a child. Three levels of component is where a
/// re-inserted mount stops being a special case and starts being a subtree.
pub class Branch extends Component {
    pub label: string = ""
    pub leaf: Leaf = new Leaf()
    pub fn init() {}
    pub override fn render(b: Builder) {
        b.open(0, "span")
        b.attr(1, "class", "branch")
        b.text(2, self.label)
        b.component_made<Leaf>(3, fn() -> Leaf { return self.leaf },
                               fn(l: Leaf) { l.label = "leaf {self.label}" })
        b.close()
    }
}

/// The page. Everything at once: an element whose TAG is a field, escaped
/// text, a trusted `constant`, an author `raw` whose node count changes, a
/// fragment, a keyed loop, a void element, a form control with a live `value`,
/// two handlers, and a mounted child two levels deep.
pub class Page extends Component {
    pub wrapper: string = "div"
    pub title: string = "hello & <goodbye>"
    pub count: int = 0
    pub note: string = "<b>one</b>"
    pub busy: bool = false
    pub extra: bool = false
    pub field: string = "typed"
    pub show_kid: bool = true
    pub rows: List<string> = []
    pub kid: Branch = new Branch()

    pub fn init() {}

    pub override fn render(b: Builder) {
        b.open(0, self.wrapper)
        b.attr(1, "id", "wrap")
        b.attr(2, "class", if self.busy { "page busy" } else { "page" })
        if self.extra { b.attr(3, "data-extra", "yes") }
        b.flag(4, "hidden", self.busy)
        b.on_click(5, fn(e: MouseEvent) { self.count += 1 })

        b.text(6, self.title)
        b.constant(7, "<i>fixed</i>")
        b.raw(8, self.note)

        b.fragment(9, fn(inner: Builder) {
            inner.open(0, "p")
            inner.text(1, "count {self.count}")
            inner.close()
        })

        var index: int = 0
        for index < self.rows.len() {
            b.region(10, self.rows[index])
            b.open(0, "li")
            b.attr(1, "data-key", self.rows[index])
            b.text(2, "row {self.rows[index]}")
            b.close()
            b.end_region()
            index += 1
        }

        b.open(11, "br")
        b.close()

        b.open(12, "input")
        b.attr(0, "name", "q")
        b.attr(1, "value", self.field)
        b.on_input(2, fn(e: InputEvent) { self.field = e.value })
        b.close()

        if self.show_kid {
            b.component_made<Branch>(13, fn() -> Branch { return self.kid },
                                     fn(c: Branch) { c.label = "kid {self.count}" })
        }
        b.close()
    }
}

/// An `ErrorBoundary` with a mounted child inside it. A boundary that fails
/// and then recovers is the second shape that re-inserts a live mount, and it
/// is the one an app actually hits.
pub class Shell extends ErrorBoundary {
    pub inner: Branch = new Branch()
    pub tag: string = "main"
    pub fn init() {
        super.init()
        self.body = fn(b: Builder) {
            b.open(0, self.tag)
            b.attr(1, "class", "shell")
            b.component_made<Branch>(2, fn() -> Branch { return self.inner },
                                     fn(c: Branch) { c.label = "guarded" })
            b.close()
        }
    }
}

/// Transparent containers with nothing in them, between siblings that DO write
/// HTML. An empty fragment contributes no DOM node at all, so inserting after
/// one has to walk up out of it to find where the next sibling starts — which
/// is the one piece of the applier a tree of only elements never exercises.
pub class Hollow extends Component {
    pub before: bool = true
    pub middle: int = 0
    pub after: bool = true
    pub fn init() {}
    pub override fn render(b: Builder) {
        b.open(0, "div")
        if self.before {
            b.open(1, "u")
            b.text(0, "before")
            b.close()
        }
        b.fragment(2, fn(inner: Builder) {
            var index: int = 0
            for index < self.middle {
                inner.region(0, "m{index}")
                inner.fragment(0, fn(deep: Builder) {
                    deep.text(0, "m")
                })
                inner.end_region()
                index += 1
            }
        })
        if self.after {
            b.open(3, "s")
            b.text(0, "after")
            b.close()
        }
        b.close()
    }
}

// ============================================================== recording

class Step {
    pub batch: string = ""
    pub html: string = ""
    pub applied: string = ""
    pub dump: string = ""
    pub faults: List<string> = []
    pub fn init() {}
}

class Case {
    pub name: string = ""
    pub steps: List<Step> = []
    pub fn init(name: string) { self.name = name }
}

/// One render pass to one step. The batch is taken once — `Differ.batch`
/// marks every buffer diffed, so taking it twice answers an empty batch the
/// second time and would silently record nothing.
fn record(kase: Case, renderer: Renderer, applier: Applier, number: int) {
    let batch: Batch = renderer.batch()
    let step: Step = new Step()
    step.batch = encode_batch(number, batch)
    applier.apply(batch)
    step.html = renderer.html()
    step.applied = applier.html()
    step.dump = applier.dump()
    for fault: string in applier.faults { step.faults.push(fault) }
    for fault: string in applier.serializer_faults { step.faults.push(fault) }
    kase.steps.push(step)
}

fn settle(renderer: Renderer) {
    var guard: int = 0
    for renderer.pending() > 0 && guard < 16 {
        let _: int = renderer.flush()
        guard += 1
    }
}

// ============================================================== the cases

fn case_page() -> Case {
    let kase: Case = new Case("page")
    let page: Page = new Page()
    page.rows.push("a")
    page.rows.push("b")
    page.rows.push("c")
    let renderer: Renderer = new Renderer()
    renderer.mount(page)
    let applier: Applier = new Applier()
    record(kase, renderer, applier, 1)

    // Two text edits and nothing else. The headline claim of the whole update
    // model is that this is what a click costs.
    page.count = 1
    page.title = "second & <title>"
    page.notify()
    settle(renderer)
    record(kase, renderer, applier, 2)

    // An attribute added, one changed, and a flag toggled on.
    page.busy = true
    page.extra = true
    page.notify()
    settle(renderer)
    record(kase, renderer, applier, 3)

    // The added attribute removed and the flag toggled off, so the removal
    // path runs on both an `attribute` and a `flag`.
    page.busy = false
    page.extra = false
    page.notify()
    settle(renderer)
    record(kase, renderer, applier, 4)

    // THE MOUNT MOVE. The wrapper's tag changes, so the differ replaces the
    // whole element — and the replacement's frames carry a `child` frame for a
    // component that is still live and whose own buffer has not changed, so it
    // sends nothing. An applier that builds a fresh empty node here loses the
    // Branch and the Leaf under it, permanently and silently.
    page.wrapper = "section"
    page.notify()
    settle(renderer)
    record(kase, renderer, applier, 5)

    // A `raw` node going from one DOM node to three, and its neighbours must
    // not move.
    page.note = "<b>one</b><i>two</i><u>three</u>"
    page.notify()
    settle(renderer)
    record(kase, renderer, applier, 6)

    // ...to none at all. A markup node that contributes nothing is where an
    // applier that anchors on "the node at index i" walks off the end.
    page.note = ""
    page.notify()
    settle(renderer)
    record(kase, renderer, applier, 7)

    // ...and back to one, which has to land between the constant before it and
    // the fragment after it.
    page.note = "<b>back</b>"
    page.notify()
    settle(renderer)
    record(kase, renderer, applier, 8)

    // A live value on a form control: the attribute AND the property.
    page.field = "changed"
    page.notify()
    settle(renderer)
    record(kase, renderer, applier, 9)

    // The child unmounted — a disposal — and then mounted again at a NEW slot,
    // because slot ids are never reused.
    page.show_kid = false
    page.notify()
    settle(renderer)
    record(kase, renderer, applier, 10)

    page.show_kid = true
    page.notify()
    settle(renderer)
    record(kase, renderer, applier, 11)
    return kase
}

fn case_keyed() -> Case {
    let kase: Case = new Case("keyed")
    let page: Page = new Page()
    page.show_kid = false
    page.rows.push("a")
    page.rows.push("b")
    page.rows.push("c")
    page.rows.push("d")
    page.rows.push("e")
    page.rows.push("f")
    let renderer: Renderer = new Renderer()
    renderer.mount(page)
    let applier: Applier = new Applier()
    record(kase, renderer, applier, 1)

    // A full reversal of six rows. Five moves at least, and the one shape a
    // two-row test cannot produce.
    reset_rows(page, "f e d c b a")
    settle_page(page, renderer)
    record(kase, renderer, applier, 2)

    // Rotate right by one, then left by one. `tests/diff.b` pins that the two
    // cost different numbers of moves; the applier has to land on the same
    // list either way.
    reset_rows(page, "a f e d c b")
    settle_page(page, renderer)
    record(kase, renderer, applier, 3)

    reset_rows(page, "f e d c b a")
    settle_page(page, renderer)
    record(kase, renderer, applier, 4)

    // Two rows out of the middle.
    reset_rows(page, "f e b a")
    settle_page(page, renderer)
    record(kase, renderer, applier, 5)

    // Two new rows into the middle, and one of them takes a key that left.
    reset_rows(page, "f e x c b a")
    settle_page(page, renderer)
    record(kase, renderer, applier, 6)

    // Empty, then full again. A loop that produced nothing still has to leave
    // its neighbours where they were.
    reset_rows(page, "")
    settle_page(page, renderer)
    record(kase, renderer, applier, 7)

    reset_rows(page, "p q r")
    settle_page(page, renderer)
    record(kase, renderer, applier, 8)
    return kase
}

fn reset_rows(page: Page, spec: string) {
    page.rows.clear()
    if spec.len() == 0 { return }
    for key: string in spec.split(" ") { page.rows.push(key) }
}

fn settle_page(page: Page, renderer: Renderer) {
    page.notify()
    settle(renderer)
}

fn case_boundary() -> Case {
    let kase: Case = new Case("boundary")
    let shell: Shell = new Shell()
    let renderer: Renderer = new Renderer()
    renderer.mount(shell)
    let applier: Applier = new Applier()
    record(kase, renderer, applier, 1)

    // The boundary fails: everything its body wrote is dropped, the child is
    // disposed, and the fallback takes its place.
    shell.fail("t1")
    settle(renderer)
    record(kase, renderer, applier, 2)

    // ...and recovers, which mounts a NEW child at a NEW slot. A browser that
    // cached the old handler id would now be sending clicks to a component
    // that is gone.
    shell.recover()
    settle(renderer)
    record(kase, renderer, applier, 3)

    // The element around the recovered child changes tag, so the live mount
    // moves once more — the second of the two shapes that reach the reuse
    // path in `Applier.build`.
    shell.tag = "article"
    shell.notify()
    settle(renderer)
    record(kase, renderer, applier, 4)
    return kase
}

fn case_hollow() -> Case {
    let kase: Case = new Case("hollow")
    let page: Hollow = new Hollow()
    let renderer: Renderer = new Renderer()
    renderer.mount(page)
    let applier: Applier = new Applier()
    record(kase, renderer, applier, 1)

    // Content appears inside a fragment that had none, between two siblings
    // that do write HTML. The insert has to find the element after it.
    page.middle = 3
    page.notify()
    settle(renderer)
    record(kase, renderer, applier, 2)

    // The sibling BEFORE it goes away, so the fragment is now first.
    page.before = false
    page.notify()
    settle(renderer)
    record(kase, renderer, applier, 3)

    // The sibling AFTER it goes away, so an insert at the end of the fragment
    // has to append to the enclosing element rather than before anything.
    page.after = false
    page.notify()
    settle(renderer)
    record(kase, renderer, applier, 4)

    page.middle = 1
    page.before = true
    page.after = true
    page.notify()
    settle(renderer)
    record(kase, renderer, applier, 5)
    return kase
}

// ============================================================== emitting

fn emit_faults(out: fmt.StringBuilder, faults: List<string>) {
    out.push("[")
    var index: int = 0
    for index < faults.len() {
        if index > 0 { out.push(",") }
        write_json_string(out, faults[index])
        index += 1
    }
    out.push("]")
}

fn emit(cases: List<Case>) -> string {
    var out: fmt.StringBuilder = new fmt.StringBuilder()
    out.push("// Generated by tests/js_cases.b. Do not edit.\n")
    out.push("//\n")
    out.push("// Every batch below came out of a real Renderer and a real Differ, and\n")
    out.push("// every expectation beside it came out of the Beans serializer and the\n")
    out.push("// Beans applier. tests/js_apply.js feeds them to latte.js in a browser.\n")
    out.push("var LATTE_CASES = [\n")
    var first_case: bool = true
    for kase: Case in cases {
        if !first_case { out.push(",\n") }
        first_case = false
        out.push("\{\"name\":")
        write_json_string(out, kase.name)
        out.push(",\"steps\":[\n")
        var first_step: bool = true
        for step: Step in kase.steps {
            if !first_step { out.push(",\n") }
            first_step = false
            out.push("\{\"b\":")
            out.push(step.batch)
            out.push(",\"h\":")
            write_json_string(out, step.html)
            out.push(",\"a\":")
            write_json_string(out, step.applied)
            out.push(",\"d\":")
            write_json_string(out, step.dump)
            out.push(",\"f\":")
            emit_faults(out, step.faults)
            out.push("\}")
        }
        out.push("\n]\}")
    }
    out.push("\n];\n")
    return out.to_string()
}

fn main() {
    var cases: List<Case> = []
    cases.push(case_page())
    cases.push(case_keyed())
    cases.push(case_boundary())
    cases.push(case_hollow())
    io.print(emit(cases))
}
