// The Builder signature in `probes/BUILDER.md`, compiled and run.
//
// `core/builder.b` is the stub; `pages/counter.b` is a hand-written `<beans>`
// block and `pages/counter_gen.b` is the half latte-bx would write beside it,
// translated from PLAN.md's worked example and extended until every method on
// the Builder is called by generated code. If this file runs, the signature
// can express the example. If it did not, the signature would be a guess.
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
    io.println("balanced: {b1.balanced()}")
    io.println("faults: {b1.faults.len()} {if b1.faults.len() > 0 { b1.faults[0] } else { "" }}")
    io.println("frames: {b1.frames.len()}")
    io.println(b1.dump())

    // The handler table is reachable by sequence number, which is the only id
    // the wire ever carries.
    io.println("click 9 ran: {fire_click(b1, 9)}, count now {page.count}")
    io.println("input 13 ran: {fire_input(b1, 13, "typed")}, note now {page.note}")
    io.println("no handler at 999: {!fire_click(b1, 999)}")

    // A second render on the SAME builder must reuse the mounted child rather
    // than activating a new one — probe 3 measured activation at 2.4 us, so
    // re-activating per render is the one shape that is not affordable.
    let before: int = b1.children.len()
    b1.frames.clear()
    page.render(b1)
    io.println("the child was reused, not re-activated: {b1.children.len() == before && before == 1}")

    // A fresh builder is a fresh mount.
    let b2: Builder = new Builder()
    page.count = 20
    page.render(b2)
    io.println("the branch flipped, so no child mounted: {b2.children.len() == 0}")
    io.println("branch arms have disjoint numbers: {b2.dump().contains("[17:") && !b2.dump().contains("{18:")}")
}
