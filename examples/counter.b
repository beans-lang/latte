// Generated from examples/counter.bx by latte-bx. Do not edit.
//
// The <beans> block below is counter.bx's, copied through byte for byte; its
// own package line is blanked so every line after it keeps its number. The
// render method under it is the markup, as Builder calls with fixed
// sequence numbers. Change counter.bx and regenerate:
//
//     latte-bx build examples/counter.bx
package main

import {Builder, Callback, Component, FocusEvent, InputEvent, KeyboardEvent, MouseEvent, Reference, SubmitEvent} from latte


// examples/counter.bx — the counter page, and the smallest whole latte
// program: a route, a parameter, a layout, an event, a branch, a keyed
// loop and a child component with a callback.
//
//     beansc run   examples/counter.b                     # the tree interpreter
//     beansc build examples/counter.b -o build/counter     # a native binary
//
// **`counter.b` beside this file is GENERATED and checked in.** A consumer
// installs no markup compiler and runs no build step — they add one `require`
// row and import the package. `test.sh` regenerates this file and diffs, so a
// stale `counter.b` fails the gate instead of shipping.
//
// Two classes in this block would be their own `.bx` file in a real app, and
// are hand-written here because one `.bx` file compiles the markup of **one**
// class — the one the file is named after:
//
//   * `Shell`, the layout. A layout is an ordinary component whose `body`
//     field is placed with `$slot`; in an app it is `shell.bx` and its whole
//     markup is `<main class="page">$slot</main>`.
//   * `Hint`, the child the `$else` arm mounts.
//
// The import line the generated file writes for you already binds `Builder`,
// `Callback`, `Component`, `Reference` and the five event classes, so this
// block must not import them again — two imports of one name is an error in a
// file you did not write, and latte-bx says so by name if you try.
//          

import std.io
import {Frame, Layout, Renderer, PageMap, PageMatch, PageInstance,
        Anonymous, scan_pages, open_page, mount_page,
        page, layout, param} from latte

/// A row of the list. Ordinary Beans; nothing about it is latte's.
pub class Row {
    pub id: int = 0
    pub title: string = ""
    pub fn init(id: int, title: string) {
        self.id = id
        self.title = title
    }
}

/// The layout. `@layout(name: "Shell")` on a page selects it by this class's
/// simple name, and nothing registers it — the scan resolves the name against
/// the types in the program.
pub class Shell extends Layout {
    pub fn init() { super.init() }
    pub override fn render(b: Builder) {
        b.open(0, "main")
        b.attr(1, "class", "page")
        b.fragment(2, self.body)
        b.close()
    }
}

/// The child the `$else` arm mounts.
///
/// `on_dismiss` is a `Callback<int>` and not a bare `fn(int)` for one reason:
/// a bare closure would run, change the parent's state, and re-render nothing,
/// because nobody told the renderer. A `Callback` marks the component that
/// SUPPLIED it — the page, not this child.
pub class Hint extends Component {
    @param pub text: string = ""
    @param pub on_dismiss: Option<Callback<int>> = none
    pub fn init() {}
    pub override fn render(b: Builder) {
        b.open(0, "p")
        b.attr(1, "class", "hint")
        b.text(2, "{self.text}")
        b.close()
    }
    /// What a real Hint would call from its own dismiss button.
    pub fn dismiss() {
        match self.on_dismiss {
            some(handler) => { handler.call(0) }
            none => {}
        }
    }
}

/// The page.
///
/// `partial` is not decoration: latte-bx appends the markup as a **second part
/// of this same class**, so the compiler never parses the Beans you wrote — it
/// copies this block through byte for byte and writes `render` next to it.
@page(route: r"/counter/{start}")
@layout(name: "Shell")
pub partial class Counter extends Component {
    @param pub start: int = 0
    pub count: int = 0
    pub note: string = ""
    pub rows: List<Row> = []
    pub fn init() {}

    /// `on_init` runs once, at the mount, after the route parameters are
    /// written. `start` is already bound here.
    pub override fn on_init() {
        self.count = self.start
        self.rows = [new Row(1, "write the page"), new Row(2, "click the button")]
    }

    fn hide() { self.rows.clear() }
}

// ============================================================= the program

/// Every handler slot the page bound, in the order the frames carry them.
///
/// A browser never computes these: latte puts the id in the batch beside the
/// element, and the client sends it back with the event. Reading them out of
/// the frames is what this file does instead of running a browser.
fn handler_slots(r: Renderer) -> List<int> {
    var slots: List<int> = []
    for id: int in r.ids() {
        match r.buffer(id) {
            some(buffer) => {
                for frame: Frame in buffer.frames.items {
                    match frame {
                        handler(_, _, slot) => { slots.push(slot) }
                        _ => {}
                    }
                }
            }
            none => {}
        }
    }
    return move slots
}

fn main() {
    // No registry and no registration call: one walk of the program's types
    // turns every `@page` into a plan. A page nothing else references is still
    // routable, because being reachable by URL is the only thing that matters.
    let pages: PageMap = scan_pages()
    if !pages.ok() {
        io.println("the page scan refused this program:")
        io.println(pages.report())
        return
    }

    // ---- 1. static server rendering: no socket, no client ---------------
    io.println("== GET /counter/3 ==")
    match pages.find("GET", "/counter/3") {
        none => { io.println("nothing is routed at /counter/3") }
        some(found) => { serve(found) }
    }

    // ---- 4. a second route, a different parameter -----------------------
    io.println("")
    io.println("== GET /counter/40 ==")
    match pages.find("GET", "/counter/40") {
        none => { io.println("nothing is routed at /counter/40") }
        some(found) => {
            let other: PageInstance = open_page(found, new Anonymous(), none)
            let r: Renderer = new Renderer()
            if mount_page(r, other) { io.println(r.html()) }
            else { io.println("the page did not mount") }
        }
    }

    // ---- 5. a route nobody serves ---------------------------------------
    io.println("")
    io.println(r"== GET /counter (no {start} in the path) ==")
    match pages.find("GET", "/counter") {
        none => { io.println("no page is routed there — the host answers 404") }
        some(_) => { io.println("matched, which it should not have") }
    }
}

/// Everything a host does with a matched route: activate the page, bind the
/// route values, build the layout chain, mount and serialize.
fn serve(found: PageMatch) {
    let instance: PageInstance = open_page(found, new Anonymous(), none)
    if !instance.ok() {
        for problem: string in instance.problems { io.println("refused: {problem}") }
        return
    }
    let r: Renderer = new Renderer()
    if !mount_page(r, instance) {
        io.println("the page did not mount")
        return
    }
    io.println(r.html())

    // ---- 2. one click is one render -------------------------------------
    // The button first, then the input: `handler_slots` reads them in frame
    // order and the markup binds them in that order.
    let slots: List<int> = handler_slots(r)
    io.println("")
    io.println("== the page bound {slots.len()} handler(s) ==")
    let button: int = slots[0]
    let box: int = slots[1]

    io.println("")
    io.println("== one click on the button ==")
    // The `new` is on its own line, and the interpolation below just reads
    // the variable — clearer than constructing an object inside `"{ }"`.
    let click: MouseEvent = new MouseEvent()
    io.println("the click found its handler: {r.fire_mouse(button, click)}")
    io.println("renders this pass: {r.flush()}")
    io.println(r.html())

    // ---- 3. eight events, still one render, and the branch flips --------
    // `bind:value` writes the field from the event, and eight more clicks
    // carry the count past ten — so the `$if` takes its other arm, the child
    // component the `$else` had mounted is disposed, and the whole thing is
    // still one render of one component.
    var typed: InputEvent = new InputEvent()
    typed.value = "tea"
    io.println("")
    io.println("== typing, then eight more clicks ==")
    io.println("the input found its handler: {r.fire_input(box, typed)}")
    var again: int = 0
    for again < 8 {
        let more: MouseEvent = new MouseEvent()
        let _: bool = r.fire_mouse(button, more)
        again += 1
    }
    io.println("renders this pass: {r.flush()}")
    io.println(r.html())
}

// Every component tag in counter.bx, checked by beansc rather than by latte-bx:
// a tag whose type is not a Component is a type error naming the type,
// instead of a blank subtree and a fault at run time. Unused, and an
// unused free function is not an error.
fn _latte_component_counter_Hint(value: Hint) -> Component { return value }

partial class Counter {
    pub override fn render(b: Builder) {
        b.open(0, "section")  // counter.bx:224
        b.attr(1, "class", "counter")
        b.open(2, "h2")  // counter.bx:225
        b.text(3, "Count: {self.count}")
        b.close()
        b.open(4, "button")  // counter.bx:227
        b.attr(5, "class", "primary")
        b.on_click(6, fn(e: MouseEvent) { self.count += 1 })
        b.text(7, "Add one")
        b.close()
        b.open(8, "input")  // counter.bx:231
        b.attr(9, "value", "{self.note}")
        b.on_input(10, fn(e: InputEvent) { self.note = e.value })
        b.attr(11, "placeholder", "A note")
        b.close()
        if self.count > 10 {  // counter.bx:233
            b.open(12, "p")  // counter.bx:234
            b.attr(13, "class", "warn")
            b.text(14, "That is a lot, {self.note}")
            b.close()
        } else {  // counter.bx:235
            b.component<Hint>(15, fn(_latte_c: Hint) {  // counter.bx:236
                _latte_c.text = "Keep going"
                _latte_c.on_dismiss = some(new Callback<int>(self, fn(id: int) { self.hide() }))
            })
        }
        b.open(16, "ul")  // counter.bx:240
        for row: Row in self.rows {  // counter.bx:241
            b.region(17, "{row.id}")
            b.open(0, "li")  // counter.bx:242
            b.text(1, "{row.title}")
            b.close()
            b.end_region()
        }
        b.close()
        b.close()
    }
}
