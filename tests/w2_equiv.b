// Generated from tests/w2cases/equiv.bx by latte-bx. Do not edit.
//
// The <beans> block below is equiv.bx's, copied through byte for byte; its
// own package line is blanked so every line after it keeps its number. The
// render method under it is the markup, as Builder calls with fixed
// sequence numbers. Change equiv.bx and regenerate:
//
//     latte-bx build tests/w2cases/equiv.bx
package main

import {Builder, Callback, Component, FocusEvent, InputEvent, KeyboardEvent, MouseEvent, Reference, SubmitEvent} from latte


//          

// PLAN.md gate 4, second half: **a hand-written builder and a generated
// builder must produce identical frames.**
//
// This file is the input AND the suite. `tests/w2_equiv.b` is generated from
// it by latte-bx and checked in, `tests/markup.b` regenerates it and fails on
// a diff, and `test.sh` runs it on both backends against `tests/w2_equiv.out`.
// So one artefact proves four things: that the markup compiles, that what it
// compiles to is what a person would have written, that the two arms of the
// fold switch say the same thing, and that the generated file on disk is not
// stale.
//
// `EquivHand` below is the twin. It was written from `probes/BUILDER.md`'s
// rules — source order from 0, disjoint ranges for branch arms, a region and a
// fragment restarting at 0 — BEFORE the generator was run against it, which is
// the only way the comparison means anything.

import std.io
import {Serializer} from latte

pub class Row {
    pub id: int = 0
    pub title: string = ""
    pub fn init(id: int, title: string) { self.id = id; self.title = title }
}

/// The child. Its own frames are numbered in its own space, which is what the
/// `component <Hint> #<slot>` leaf in the parent's dump stands for.
pub class Hint extends Component {
    pub label: string = ""
    pub body: fn(Builder) = fn(target: Builder) {}
    pub extra: fn(Builder, int) = fn(target: Builder, n: int) {}
    pub fn init() {}
    pub override fn render(target: Builder) {
        target.open(0, "aside")
        target.text(1, "{self.label}")
        target.fragment(2, self.body)
        target.fragment(3, fn(nested: Builder) { self.extra(nested, 7) })
        target.close()
    }
}

/// Everything both halves render. One class of state, so the two renders
/// cannot differ because they were looking at different data.
pub class State {
    pub count: int = 0
    pub note: string = ""
    pub rendered: string = ""
    pub rows: List<Row> = []
    pub tags: List<string> = []
    pub extra: Map<string, string> = {}
    pub fn init() {}
}

pub fn sample() -> State {
    let state: State = new State()
    state.count = 1
    state.note = "hi"
    state.rendered = "<i>raw</i>"
    state.rows.push(new Row(4, "four"))
    state.rows.push(new Row(9, "nine"))
    state.tags.push("red")
    state.tags.push("blue")
    state.extra["data-x"] = "1"
    state.extra["onclick"] = "steal()"
    state.extra["class"] = "from-the-splat"
    return state
}

pub partial class Equiv extends Component {
    pub state: State = new State()
    pub fn init() {}
}

/// The twin, by hand.
pub class EquivHand extends Component {
    pub state: State = new State()
    pub fn init() {}

    pub override fn render(b: Builder) {
        b.open(0, "section")
        b.attr(1, "class", "counter")

        // Literal text and the expression beside it are ONE frame: PLAN.md's
        // wire example is `["ut",3,"Count: 4"]`, one text edit for the whole
        // string.
        b.open(2, "h2")
        b.text(3, "Count: {self.state.count}")
        b.close()

        // One constant subtree: three numbered calls folded into one frame,
        // and the numbering after it is the same either way.
        if b.fold { b.constant(4, "<p class=\"muted\">a fixed line</p>") }
        else {
            b.open(4, "p")
            b.attr(5, "class", "muted")
            b.text(6, "a fixed line")
            b.close()
        }

        b.open(7, "button")
        b.on_click(8, fn(e: MouseEvent) { self.state.count += 1 })
        b.text(9, "Add one")
        b.close()

        // `bind:value` is two frames: the value out, and the write-back.
        b.open(10, "input")
        b.attr(11, "value", "{self.state.note}")
        b.on_input(12, fn(e: InputEvent) { self.state.note = e.value })
        b.attr(13, "placeholder", "A note")
        b.close()

        // The arms hold disjoint ranges, so a number never means two things.
        if self.state.count > 2 {
            b.open(14, "p")
            b.attr(15, "class", "warn")
            b.text(16, "That is a lot, {self.state.note}")
            b.close()
        } else {
            b.component<Hint>(17, fn(child: Hint) {
                child.label = "Keep going"
                child.body = fn(nested: Builder) {
                    // A fragment body restarts at 0.
                    if nested.fold { nested.constant(0, "<em>child content</em>") }
                    else {
                        nested.open(0, "em")
                        nested.text(1, "child content")
                        nested.close()
                    }
                }
                child.extra = fn(nested: Builder, n: int) {
                    nested.open(0, "b")
                    nested.text(1, "extra {n}")
                    nested.close()
                }
            })
        }

        b.open(18, "ul")
        for row: Row in self.state.rows {
            b.region(19, "{row.id}")
            b.open(0, "li")
            b.text(1, "{row.title}")
            b.close()
            b.end_region()
        }
        b.close()

        b.open(20, "ol")
        var index: int = 0
        for tag: string in self.state.tags {
            b.region(21, "{index}")
            b.open(0, "li")
            b.text(1, "{tag}")
            b.close()
            b.end_region()
            index += 1
        }
        b.close()

        b.open(22, "div")
        b.attrs(23, self.state.extra)
        b.attr(24, "class", "base")
        b.text(25, "splat")
        b.close()

        b.open(26, "div")
        b.preserve(27)
        if b.fold { b.constant(28, "<span>owned</span>") }
        else {
            b.open(28, "span")
            b.text(29, "owned")
            b.close()
        }
        b.close()

        b.open(30, "div")
        b.raw(31, self.state.rendered)
        b.close()

        if b.fold { b.constant(32, "<footer class=\"c\"><small>fixed</small></footer>") }
        else {
            b.open(32, "footer")
            b.attr(33, "class", "c")
            b.open(34, "small")
            b.text(35, "fixed")
            b.close()
            b.close()
        }

        b.close()
    }
}

fn render_generated(fold: bool) -> Builder {
    let b: Builder = new Builder()
    b.fold = fold
    let page: Equiv = new Equiv()
    page.state = sample()
    b.render_root(page)
    return b
}

fn render_hand(fold: bool) -> Builder {
    let b: Builder = new Builder()
    b.fold = fold
    let page: EquivHand = new EquivHand()
    page.state = sample()
    b.render_root(page)
    return b
}

fn faults_of(b: Builder) -> string {
    let lines: List<string> = []
    for fault: string in b.all_faults() { lines.push("  fault {fault}") }
    if lines.is_empty() { return "  (no faults)" }
    return lines.join("\n")
}

fn main() {
    // ---- gate 4: the same frames, folded and unfolded --------------------
    var index: int = 0
    for index < 2 {
        let fold: bool = index == 0
        let generated: Builder = render_generated(fold)
        let hand: Builder = render_hand(fold)
        let same: bool = generated.dump_tree() == hand.dump_tree()
        io.println("fold={fold}: generated frames == hand-written frames: {same}")
        if !same {
            io.println("---- generated ----")
            io.print(generated.dump_tree())
            io.println("---- hand-written ----")
            io.print(hand.dump_tree())
        }
        index += 1
    }

    // ---- gate 2: the folded string is what the unfolded walk produces -----
    let folded: Builder = render_generated(true)
    let walked: Builder = render_generated(false)
    let one: Serializer = new Serializer()
    let two: Serializer = new Serializer()
    let folded_html: string = one.page(folded)
    let walked_html: string = two.page(walked)
    io.println("folded html == unfolded html: {folded_html == walked_html}")
    io.println("html: {folded_html}")
    if folded_html != walked_html { io.println("unfolded: {walked_html}") }

    // Folding has to actually do something, or the comparison above is two
    // identical walks agreeing with each other.
    io.println("frames folded={folded.frames.len()} unfolded={walked.frames.len()}")

    // ---- the splat is the hole in the compile-time on* refusal -----------
    //
    // `attrs={self.state.extra}` carries a runtime Map, and one of its keys is
    // `onclick`. latte-bx cannot see it: there is no literal to refuse. The
    // control is `latte.Builder.attrs`, which drops the name and records a
    // fault, and this is the assertion that it still does.
    io.println("onclick through the splat is in the html: {folded_html.contains("onclick")}")
    io.println("faults:")
    io.println(faults_of(folded))

    // The frame dump, once, as the golden's record of the numbering.
    io.println("---- frames, folded ----")
    io.print(folded.dump_tree())
    io.println("---- frames, unfolded ----")
    io.print(walked.dump_tree())
}

// Every component tag in equiv.bx, checked by beansc rather than by latte-bx:
// a tag whose type is not a Component is a type error naming the type,
// instead of a blank subtree and a fault at run time. Unused, and an
// unused free function is not an error.
fn _latte_component_equiv_Hint(value: Hint) -> Component { return value }

partial class Equiv {
    pub override fn render(b: Builder) {
        b.open(0, "section")  // equiv.bx:272
        b.attr(1, "class", "counter")
        b.open(2, "h2")  // equiv.bx:273
        b.text(3, "Count: {self.state.count}")
        b.close()
        if b.fold { b.constant(4, "<p class=\"muted\">a fixed line</p>") }  // equiv.bx:274
        else {
            b.open(4, "p")  // equiv.bx:274
            b.attr(5, "class", "muted")
            b.text(6, "a fixed line")
            b.close()
        }
        b.open(7, "button")  // equiv.bx:275
        b.on_click(8, fn(e: MouseEvent) { self.state.count += 1 })
        b.text(9, "Add one")
        b.close()
        b.open(10, "input")  // equiv.bx:276
        b.attr(11, "value", "{self.state.note}")
        b.on_input(12, fn(e: InputEvent) { self.state.note = e.value })
        b.attr(13, "placeholder", "A note")
        b.close()
        if self.state.count > 2 {  // equiv.bx:277
            b.open(14, "p")  // equiv.bx:278
            b.attr(15, "class", "warn")
            b.text(16, "That is a lot, {self.state.note}")
            b.close()
        } else {  // equiv.bx:279
            b.component<Hint>(17, fn(_latte_c: Hint) {  // equiv.bx:280
                _latte_c.label = "Keep going"
                _latte_c.body = fn(_latte_inner: Builder) {
                    if _latte_inner.fold { _latte_inner.constant(0, "<em>child content</em>") }  // equiv.bx:281
                    else {
                        _latte_inner.open(0, "em")  // equiv.bx:281
                        _latte_inner.text(1, "child content")
                        _latte_inner.close()
                    }
                }
                _latte_c.extra = fn(_latte_inner: Builder, n: int) {
                    _latte_inner.open(0, "b")  // equiv.bx:282
                    _latte_inner.text(1, "extra {n}")
                    _latte_inner.close()
                }
            })
        }
        b.open(18, "ul")  // equiv.bx:285
        for row: Row in self.state.rows {  // equiv.bx:286
            b.region(19, "{row.id}")
            b.open(0, "li")  // equiv.bx:287
            b.text(1, "{row.title}")
            b.close()
            b.end_region()
        }
        b.close()
        b.open(20, "ol")  // equiv.bx:290
        var _latte_row_0: int = 0
        for tag: string in self.state.tags {  // equiv.bx:291
            b.region(21, "{_latte_row_0}")
            b.open(0, "li")  // equiv.bx:292
            b.text(1, "{tag}")
            b.close()
            b.end_region()
            _latte_row_0 += 1
        }
        b.close()
        b.open(22, "div")  // equiv.bx:295
        b.attrs(23, self.state.extra)
        b.attr(24, "class", "base")
        b.text(25, "splat")
        b.close()
        b.open(26, "div")  // equiv.bx:296
        b.preserve(27)
        if b.fold { b.constant(28, "<span>owned</span>") }
        else {
            b.open(28, "span")
            b.text(29, "owned")
            b.close()
        }
        b.close()
        b.open(30, "div")  // equiv.bx:297
        b.raw(31, self.state.rendered)
        b.close()
        if b.fold { b.constant(32, "<footer class=\"c\"><small>fixed</small></footer>") }  // equiv.bx:298
        else {
            b.open(32, "footer")  // equiv.bx:298
            b.attr(33, "class", "c")
            b.open(34, "small")
            b.text(35, "fixed")
            b.close()
            b.close()
        }
        b.close()
    }
}
