// `<Canvas>` is the one control latte draws and markup cannot write. Both
// refusals, and the form that works. See `tools/check_gallery.sh`.
package main

import std.io
import latte.compose
import latte.geometry
import latte.headless
import latte.stage

pub class Shape extends compose.Component {
    pub form: int = 0
    pub fn init() { super.init() }
    pub override fn render(b: compose.Builder) {
        b.open("VStack")
        if self.form == 0 {
            b.open("Canvas")
            b.number("width", 80.0)
            b.number("height", 40.0)
            b.close()
        }
        if self.form == 1 {
            b.open("Canvas")
            b.number("width", 80.0)
            b.number("height", 40.0)
            b.open("Rectangle")
            b.word("fill", "#365eea")
            b.close()
            b.close()
        }
        if self.form == 2 {
            b.open("Box")
            b.number("width", 80.0)
            b.number("height", 40.0)
            b.open("Rectangle")
            b.word("fill", "#365eea")
            b.close()
            b.close()
        }
        b.close()
    }
}

fn mount(form: int, name: string) {
    let view: Shape = new Shape()
    view.form = form
    let page: stage.Scene = new stage.Scene(new headless.MetricRenderer(),
                                            geometry.Size.of(300.0, 200.0))
    io.println("-- {name}")
    match page.show(view) {
        ok(_) => { io.println("   mounted") }
        err(problem) => { io.println("   refused: {problem.msg}") }
    }
    page.close()
}

fn say(what: string, held: bool) {
    if held { io.println("ok {what}") } else { io.println("FAIL {what}") }
}

pub extern "C" fn run() -> i32 as "latte_canvas_tag_run" {
    io.println("== 1 the two shapes of a <Canvas> markup cannot write ==")
    mount(0, "a bare <Canvas />")
    mount(1, "a <Canvas> with a shape inside it")

    io.println("")
    io.println("== 2 and the form that draws ==")
    mount(2, "the shape itself, inside a <Box>")

    // Neither refusal may send the reader at the other one. The bare form used
    // to say "give it a shape", which is exactly what the second form refuses.
    io.println("")
    let bare: string = refusal_of(0)
    let nested: string = refusal_of(1)
    say("the bare refusal does not ask for a nested shape", !bare.contains("give it a shape"))
    say("it names the tag to write instead", bare.contains("Rectangle"))
    say("it says the shape replaces the canvas", bare.contains("IS the canvas"))
    say("the nested refusal says to drop the <Canvas>", nested.contains("Drop the <Canvas>"))
    say("and the working form raises nothing", refusal_of(2) == "")
    return 0
}

/// What `form` refused, or "" when it mounted.
fn refusal_of(form: int) -> string {
    let view: Shape = new Shape()
    view.form = form
    let page: stage.Scene = new stage.Scene(new headless.MetricRenderer(),
                                            geometry.Size.of(300.0, 200.0))
    var said: string = ""
    match page.show(view) {
        ok(_) => {}
        err(problem) => { said = problem.msg }
    }
    page.close()
    return said
}

fn main() { run() }
