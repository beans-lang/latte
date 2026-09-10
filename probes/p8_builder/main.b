// The Builder signature, compiled and run.
//
// `core/builder.b` is the stub; `pages/counter.b` is a hand-written `<beans>`
// block and `pages/counter_gen.b` is the half latte-bx would write beside it,
// extended until every method on the Builder is called by generated code. If
// this file runs, the signature can express the worked example. If it did
// not, the signature would be a guess.
package main

import std.io
import {Builder, InputEvent, MouseEvent} from p8_builder.core
import {Counter, Hint, Row} from p8_builder.pages

fn fire_click(b: Builder, seq: int) -> bool {
    match b.mouse.get(seq) {
        some(handler) => { handler(new MouseEvent()); return true }
        none => { return false }
    }
}

fn fire_input(b: Builder, seq: int, value: string) -> bool {
    match b.input.get(seq) {
        some(handler) => {
            let event: InputEvent = new InputEvent()
            event.value = value
            handler(event)
            return true
        }
        none => { return false }
    }
}

fn main() {
    let page: Counter = new Counter()
    page.start = 2
    page.on_init()
    page.rows.push(new Row(7, "seven"))
    page.rows.push(new Row(8, "eight"))
    page.extra["data-tag"] = "x"
    page.rendered = "<b>trusted-by-the-author</b>"
    page.hint_body = fn(b: Builder) { b.text(0, "slotted") }

    let b1: Builder = new Builder()
    page.render(b1)
    let first_dump: string = b1.dump()
    let first_faults: int = b1.faults.len()
    let first_fault: string = if first_faults > 0 { b1.faults[0] } else { "" }
    io.println("balanced: {b1.balanced()}")
    io.println("faults: {first_faults} {first_fault}")
    io.println("frames: {b1.frames.len()}")
    io.println(first_dump)

    // The handler table is reachable by sequence number, which is the only id
    // the wire ever carries.
    io.println("click 9 ran: {fire_click(b1, 9)}, count now {page.count}")
    io.println("input 13 ran: {fire_input(b1, 13, "typed")}, note now {page.note}")
    let count_after_click: int = page.count
    let note_after_input: string = page.note
    io.println("no handler at 999: {!fire_click(b1, 999)}")

    // A second render on the SAME builder must reuse the mounted child rather
    // than activating a new one — probe 3 measured activation at 2.4 us, so
    // re-activating per render is the one shape that is not affordable.
    let before: int = b1.children.len()
    b1.reset()
    page.render(b1)
    io.println("the child was reused, not re-activated: {b1.children.len() == before && before == 1}")

    // A fresh builder is a fresh mount.
    let b2: Builder = new Builder()
    page.count = 20
    page.render(b2)
    io.println("the branch flipped, so no child mounted: {b2.children.len() == 0}")
    let warn_arm: bool = b2.dump().contains("[17:")
    let hint_arm: bool = b2.dump().contains(":Hint")
    io.println("branch arms have disjoint numbers: {warn_arm && !hint_arm}")

    let all_ok: bool =
        b1.balanced() && b2.balanced() &&
        // exactly one fault per render, and it is the javascript: href refused
        first_faults == 1 &&
        first_fault == "attribute href carried a refused scheme" &&
        b1.faults.len() == 1 &&
        first_dump.contains("35:href=about:blank") &&
        // the region restarts numbering at 0 for every row
        first_dump.contains("(#20/7<0:li[1:seven]>)") &&
        first_dump.contains("(#20/8<0:li[1:eight]>)") &&
        // a constant subtree is one frame carrying its html
        first_dump.contains("[40=<footer") &&
        // the child's own frames are numbered in the child's space
        first_dump.contains("\{18:Hint\}<0:aside") &&
        count_after_click == 3 && note_after_input == "typed" &&
        b1.children.len() == before && before == 1 &&
        b2.children.len() == 0 && warn_arm && !hint_arm
    if all_ok { io.println("probe p8_builder: ok") }
    else { io.println("probe p8_builder: FAILED") }
}
