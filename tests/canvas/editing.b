// Text editing: what a caret does, and what it must never do.
//
// Everything here runs in Beans. The browser supplies keystrokes and an input
// method's composition; where the caret lands, what a word is, what a
// selection covers and what a delete removes are decided in `scene/`, which is
// why this file can ask about them with no browser at all.
//
// The cases are the ones that break a naive editor: a caret inside a family
// emoji, a selection that cuts a combining accent off its letter, a word
// boundary in a right-to-left run, and a secure field that must not hand back
// what it is holding.
package main

import std.io
import latte.compose
import latte.geometry
import latte.headless
import latte.input
import latte.paint
import latte.scene
import latte.stage

pub class Form extends compose.Component {
    pub name: string = ""
    pub secret: string = ""

    pub fn init() { super.init() }

    pub override fn render(b: compose.Builder) {
        b.open("VStack")
        b.number("padding", 8.0)
        b.number("spacing", 6.0)
        b.open("TextField")
        b.key("name")
        b.text(self.name)
        b.number("width", 240.0)
        b.close()
        b.open("SecureField")
        b.key("secret")
        b.text(self.secret)
        b.number("width", 240.0)
        b.close()
        b.close()
    }
}

fn field_of(node: scene.RenderObject, secure: bool) -> Option<scene.TextFieldRender> {
    match node as? scene.SecureFieldRender {
        some(found) => { if secure { return some(found) } }
        none => {}
    }
    match node as? scene.TextFieldRender {
        some(found) => {
            if !secure {
                match found as? scene.SecureFieldRender {
                    some(_) => {}
                    none => { return some(found) }
                }
            }
        }
        none => {}
    }
    for index: int in 0..node.child_count() {
        match node.child_at(index) {
            some(child) => {
                match field_of(child, secure) {
                    some(found) => { return some(found) }
                    none => {}
                }
            }
            none => {}
        }
    }
    return none
}

fn rule(title: string) {
    io.println("")
    io.println("== {title} ==")
}

/// The boundaries a renderer finds in a string, as a readable line.
fn boundaries(renderer: headless.MetricRenderer, text: string) -> string {
    var out: List<string> = []
    for at: int in renderer.graphemes(text).expect("graphemes") { out.push("{at}") }
    return out.join(" ")
}

pub extern "C" fn run() -> i32 as "latte_editing_run" {
    let renderer: headless.MetricRenderer = new headless.MetricRenderer()
    let page: stage.Scene = new stage.Scene(renderer, geometry.Size.of(320.0, 200.0))
    let form: Form = new Form()
    page.show(form).expect("show")

    rule("1 — a grapheme is not a byte and not a code point")

    // "Zoë" is four bytes and three graphemes; the accent is two of them.
    io.println("Zoe with an accent: {boundaries(renderer, "Zoë")}")
    // A family emoji is one grapheme made of seven code points and 25 bytes.
    io.println("a family emoji: {boundaries(renderer, "👩‍👩‍👧‍👦")}")
    // A flag is a pair of regional indicators and **one** grapheme. This
    // renderer says two, and that is a stated limit rather than a bug to
    // find later: `MetricRenderer` carries the joins a caret must not split —
    // combining marks, the zero-width joiner, the emoji presentation selector
    // — and not the whole Unicode table. `latte.canvaskit` asks
    // `Intl.Segmenter` and answers one; `tests/canvas/browser_text.b` is where
    // the two are compared.
    io.println("a flag, which this renderer splits: {boundaries(renderer, "🇯🇵")}")
    io.println("an Arabic word: {boundaries(renderer, "مرحبا")}")

    rule("2 — the caret moves by grapheme, never into one")

    match field_of(page.root().render_object().expect("root"), false) {
        none => { io.println("no text field") }
        some(field) => {
            let editor: scene.TextEditor = field.editor()
            editor.set_text("a👩‍👩‍👧‍👦b").expect("set")
            editor.select(0, 0).expect("home")
            io.println("text is {editor.text().len()} bytes")
            var stops: List<string> = []
            for step: int in 0..5 {
                stops.push("{editor.caret()}")
                editor.move_cursor(true, false).expect("right")
            }
            io.println("caret stops moving right: {stops.join(" ")}")
            var back: List<string> = []
            for step: int in 0..5 {
                back.push("{editor.caret()}")
                editor.move_cursor(false, false).expect("left")
            }
            io.println("and coming back: {back.join(" ")}")

            rule("3 — a delete removes a whole grapheme")

            editor.select(0, 0).expect("home")
            editor.move_cursor(true, false).expect("right")
            editor.move_cursor(true, false).expect("right")
            editor.erase(true).expect("backspace")
            io.println("after one backspace over the emoji: {editor.text().len()} bytes")
            io.println("what is left: \"{editor.text()}\"")

            rule("4 — a selection covers whole graphemes")

            editor.set_text("café résumé").expect("set")
            editor.select_word(2).expect("double-click in the first word")
            let first: int = editor.anchor()
            let last: int = editor.caret()
            io.println("a double-click selects {first}..{last}")
            io.println("which is \"{editor.text().slice(first, last)}\"")

            rule("4b — and a word moves by word, not by character")

            editor.select(0, 0).expect("home")
            editor.move_word(true, false).expect("word right")
            io.println("one word right lands at {editor.caret()}")
            editor.move_word(true, false).expect("word right")
            io.println("two words right lands at {editor.caret()}")
        }
    }

    rule("5 — a secure field holds text and shows none of it")

    match field_of(page.root().render_object().expect("root"), true) {
        none => { io.println("no secure field") }
        some(secure) => {
            secure.editor().set_text("hunter2").expect("set")
            secure.set_text("hunter2").expect("set")
            io.println("it holds {secure.editing_text().len()} bytes")
            // What it *draws* is dots. A secure field that returned its own
            // text to the painter would put a password on screen, and a
            // screenshot would carry it.
            io.println("what it draws: \"{secure.visible_text()}\"")
            io.println("the two are different: {secure.visible_text() != secure.editing_text()}")
        }
    }

    page.close()
    return 0
}

fn main() { run() }
