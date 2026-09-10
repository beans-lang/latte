// Folding: whether `b.fold` collapses a constant subtree into one frame.
//
// The corpus-wide check — that the folded string equals what the unfolded
// walk would have produced, over every case in the html suite — runs in
// `tests/html.b`, because a package under a module root cannot import that
// root and a shared fixture package therefore has no spelling. This file holds
// what that comparison cannot see: that `b.fold` is honoured at all, that a
// folded subtree is ONE frame where the walk is many, that an unchanged
// constant costs zero edits and stages nothing, and that a changed one costs
// exactly one `set_markup`.
//
// A `constant` could in principle be diffed by its sequence number alone,
// since a number never means two things in one render — but only if the
// markup compiler is correct. A compiler bug that reused one number across two
// constant subtrees would produce valid HTML that is simply never updated: no
// fault, no crash, no wrong markup, just a page that stops changing. So the
// differ compares the html too. One string compare against a subtree walk is
// nothing, and the real content of the O(1) claim — that the differ does not
// walk the subtree — is kept.
package main

import std.io
import {Applier, Batch, Builder, Component, Differ, Serializer} from latte

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

const ICON: string = "<span class=\"icon\"><svg width=\"12\"><path d=\"M0 0\"></path></svg></span>"

/// What generated code looks like: BOTH arms, chosen by `b.fold`. The folded
/// arm takes one sequence number and the unfolded arm takes the numbers the
/// subtree would have used — each arm self-consistent, and a render never
/// mixes them.
pub class Panel extends Component {
    pub label: string = "hello"
    pub fn init() {}
    pub override fn render(b: Builder) {
        b.open(0, "div")
        b.attr(1, "class", "panel")
        if b.fold {
            b.constant(2, ICON)
        } else {
            b.open(2, "span")
            b.attr(3, "class", "icon")
            b.open(4, "svg")
            b.attr(5, "width", "12")
            b.open(6, "path")
            b.attr(7, "d", "M0 0")
            b.close()
            b.close()
            b.close()
        }
        b.text(10, self.label)
        b.close()
    }
}

/// A child with its own folded subtree, so folding is checked through a mount
/// as well as at the root.
pub class Badge extends Component {
    pub text_body: string = "new"
    pub fn init() {}
    pub override fn render(b: Builder) {
        if b.fold {
            b.constant(0, "<i class=\"star\"></i>")
        } else {
            b.open(0, "i")
            b.attr(1, "class", "star")
            b.close()
        }
        b.text(5, self.text_body)
    }
}

pub class Host extends Component {
    pub label: string = "hello"
    pub fn init() {}
    pub override fn render(b: Builder) {
        b.open(0, "div")
        if b.fold { b.constant(1, "<hr>") }
        else { b.open(1, "hr"); b.close() }
        b.component<Badge>(5, fn(x: Badge) { x.text_body = self.label })
        b.close()
    }
}

/// The compiler bug D5 defends against: two branch arms that share one
/// sequence number for two DIFFERENT constant subtrees. Nothing here faults —
/// the frame list is well formed, the HTML is valid, and a differ that trusted
/// the number would simply never update the page.
pub class Reused extends Component {
    pub arm: bool = true
    pub fn init() {}
    pub override fn render(b: Builder) {
        b.open(0, "div")
        if self.arm { b.constant(1, "<em>arm A</em>") }
        else { b.constant(1, "<em>arm B</em>") }
        b.close()
    }
}

fn frames_of(component: Component, fold: bool) -> Builder {
    let b: Builder = new Builder()
    b.fold = fold
    b.render_root(component)
    return b
}

fn html_of(b: Builder) -> string {
    let writer: Serializer = new Serializer()
    return writer.page(b)
}

// ---------------------------------------------------------------- sections

fn switch_is_honoured(r: Report) {
    io.println("== 1 the switch")
    let panel: Panel = new Panel()
    let folded: Builder = frames_of(panel, true)
    let walked: Builder = frames_of(panel, false)

    io.println("folded:")
    io.print(folded.dump())
    io.println("unfolded:")
    io.print(walked.dump())

    r.eq("folded html == unfolded html", html_of(folded), html_of(walked))
    io.println("html: {html_of(folded)}")
    // open div, class, ONE constant frame for the whole three-level icon,
    // text, close. The walk that produces the same bytes takes thirteen.
    r.eqi("folded is five frames", folded.frames.len(), 5)
    r.eqi("unfolded is thirteen", walked.frames.len(), 13)
    r.yes("folding collapses frames", folded.frames.len() < walked.frames.len())
    r.eqi("no faults folded", folded.all_faults().len(), 0)
    r.eqi("no faults unfolded", walked.all_faults().len(), 0)

    // Through a mount: a child buffer inherits the switch when it is created.
    let host: Host = new Host()
    let host_folded: Builder = frames_of(host, true)
    let host_walked: Builder = frames_of(host, false)
    r.eq("folded html == unfolded html through a mounted child",
        html_of(host_folded), html_of(host_walked))
    io.println("host html: {html_of(host_folded)}")
    var slots: List<int> = host_folded.nested.keys()
    slots.sort()
    match host_folded.child_buffer(slots[0]) {
        some(buffer) => { r.yes("the child inherited fold=true", buffer.fold) }
        none => { r.yes("the child has a buffer", false) }
    }
    var walked_slots: List<int> = host_walked.nested.keys()
    walked_slots.sort()
    match host_walked.child_buffer(walked_slots[0]) {
        some(buffer) => { r.no("and fold=false when the parent was unfolded", buffer.fold) }
        none => { r.yes("the child has a buffer", false) }
    }
}

fn unchanged_costs_nothing(r: Report) {
    io.println("== 2 an unchanged constant is free")
    let panel: Panel = new Panel()
    let b: Builder = new Builder()
    let a: Applier = new Applier()
    let d: Differ = new Differ()

    b.render_root(panel)
    let first: Batch = d.batch(b)
    a.apply(first)
    r.eq("the first render applies", a.html(), html_of(b))

    // Change something ELSE. The constant sits beside it and must contribute
    // nothing at all — no edit, and nothing staged in the reference pool,
    // which is what "the differ does not walk the subtree" means in practice.
    panel.label = "goodbye"
    b.render_root(panel)
    let second: Batch = d.batch(b)
    io.print(second.dump())
    a.apply(second)
    r.eqi("changing the label costs one step pair and one set_text",
        second.edit_count(), 3)
    r.eqi("and stages no frames at all", second.reference.len(), 0)
    r.eq("the applier agrees", a.html(), html_of(b))
    r.yes("the icon is still there", a.html().contains("<svg width=\"12\">"))

    // And a pass that changes nothing at all.
    b.render_root(panel)
    let third: Batch = d.batch(b)
    r.eqi("an identical render is an empty batch", third.edit_count(), 0)
    r.eqi("with no updates", third.updates.len(), 0)
}

fn changed_constant(r: Report) {
    io.println("== 3 a changed constant is one set_markup")
    let reused: Reused = new Reused()
    let b: Builder = new Builder()
    let a: Applier = new Applier()
    let d: Differ = new Differ()

    b.render_root(reused)
    a.apply(d.batch(b))
    r.eq("arm A rendered", a.html(), html_of(b))
    io.println("arm A: {a.html()}")

    // THE D5 CASE. Both arms wrote `constant(1, …)`, so the sequence number is
    // identical and only the html differs. A differ that compared the number
    // alone emits nothing here and the page shows arm A forever — no fault, no
    // crash, just content that stopped changing.
    reused.arm = false
    b.render_root(reused)
    let flip: Batch = d.batch(b)
    io.print(flip.dump())
    a.apply(flip)
    r.eqi("flipping to arm B costs exactly one set_markup plus its step pair",
        flip.edit_count(), 3)
    r.eq("and the applier lands on arm B", a.html(), html_of(b))
    r.yes("which is arm B", a.html().contains("arm B"))
    r.no("and no longer arm A", a.html().contains("arm A"))
    io.println("arm B: {a.html()}")

    reused.arm = true
    b.render_root(reused)
    let back: Batch = d.batch(b)
    a.apply(back)
    r.eqi("and back again", back.edit_count(), 3)
    r.eq("the applier follows", a.html(), html_of(b))

    r.eqi("no differ faults", d.faults.len(), 0)
    r.eqi("no applier faults", a.faults.len(), 0)
    r.eqi("no builder faults — the frame list was never malformed",
        b.all_faults().len(), 0)
}

fn same_edits_either_way(r: Report) {
    io.println("== 4 the same page, folded and unfolded, end to end")
    var folded_html: string = ""
    var walked_html: string = ""
    var index: int = 0
    for index < 2 {
        let fold: bool = index == 0
        let host: Host = new Host()
        let b: Builder = new Builder()
        b.fold = fold
        let a: Applier = new Applier()
        let d: Differ = new Differ()

        b.render_root(host)
        a.apply(d.batch(b))
        var name: string = "unfolded"
        if fold { name = "folded" }
        r.eq("{name}: first render applies", a.html(), html_of(b))

        host.label = "second"
        b.render_root(host)
        let batch: Batch = d.batch(b)
        a.apply(batch)
        r.eq("{name}: the child's text changed", a.html(), html_of(b))
        // The change is inside the CHILD, so the parent says nothing at all
        // and the whole batch is the child's one set_text.
        r.eqi("{name}: one component spoke", batch.updates.len(), 1)
        r.eqi("{name}: one edit", batch.edit_count(), 1)
        io.println("{name}: {a.html()}")
        if fold { folded_html = a.html() } else { walked_html = a.html() }
        index += 1
    }
    r.eq("both arms of the switch reach the same page", folded_html, walked_html)
}

fn switch_flipped_midlife(r: Report) {
    io.println("== 5 flipping the switch under a live builder")
    // A debugging action, not something generated code does — the point of the
    // switch is to render a suspect page twice and compare. It still has to be
    // sound, because the two arms use different sequence numbers and the frame
    // at seq 2 changes KIND: a `constant` becomes an `open`. That is a
    // replacement, and the applier has to follow it.
    let panel: Panel = new Panel()
    let b: Builder = new Builder()
    let a: Applier = new Applier()
    let d: Differ = new Differ()

    b.render_root(panel)
    a.apply(d.batch(b))
    r.eq("folded first", a.html(), html_of(b))

    b.fold = false
    b.render_root(panel)
    let flip: Batch = d.batch(b)
    io.print(flip.dump())
    a.apply(flip)
    r.eq("unfolded after", a.html(), html_of(b))
    r.eqi("a kind change at one seq is a replacement", flip.edit_count(), 4)

    b.fold = true
    b.render_root(panel)
    a.apply(d.batch(b))
    r.eq("and back", a.html(), html_of(b))
    r.eqi("no faults anywhere", d.faults.len() + a.faults.len() + b.all_faults().len(), 0)
}

fn main() {
    let r: Report = new Report()
    switch_is_honoured(r)
    unchanged_costs_nothing(r)
    changed_constant(r)
    same_edits_either_way(r)
    switch_flipped_midlife(r)
    io.println("== summary")
    io.println("checks: {r.checks}, failed: {r.bad}")
}
