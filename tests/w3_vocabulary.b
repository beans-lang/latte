// Do the compiler and the runtime agree about what a canvas component is?
//
// There are two tables and there have to be. `bx/canvas_widgets.b` answers at
// compile time, for generated components; `compose.Vocabulary` and
// `controls.WidgetKind` answer at run time, for components written by hand.
// The compiler cannot simply read the runtime's: `latte.bx` must build on a
// machine with no drawing surface, and a markup compiler that could only be
// built where a browser is would be a markup compiler nobody could run in CI.
//
// Two tables is one more than anybody wants, and this is the price: every pair
// is compared, in both directions, and a tag or an attribute added to one and
// not the other fails here rather than becoming a control that compiles and
// does not draw.
package main

import std.io
import latte.bx
import latte.compose
import latte.controls

fn rule(title: string) {
    io.println("")
    io.println("== {title} ==")
}

fn main() {
    rule("1 — every tag the compiler knows is a kind the runtime knows")

    var unknown_to_runtime: List<string> = []
    for tag: string in bx.canvas_widget_tags() {
        // The drawing shapes are not widget kinds: they are a `visual.Kind` on
        // a canvas, which `WidgetMaker.bare` resolves before it looks at the
        // kind at all.
        if bx.canvas_is_drawing_tag(tag) { continue }
        if compose.Vocabulary.kind_of(tag) == none { unknown_to_runtime.push(tag) }
    }
    if unknown_to_runtime.is_empty() {
        io.println("every one of the {bx.canvas_widget_tags().len()} tags resolves to a kind")
    } else {
        io.println("tags the runtime does not know: {unknown_to_runtime.join(", ")}")
    }

    rule("2 — every kind the runtime has is a tag the compiler knows")

    var missing_from_markup: List<string> = []
    for kind: controls.WidgetKind in controls.WidgetKind.all() {
        var found: bool = false
        for tag: string in bx.canvas_widget_tags() {
            if compose.Vocabulary.kind_of(tag) == some(kind) { found = true }
        }
        if !found { missing_from_markup.push(kind.name()) }
    }
    if missing_from_markup.is_empty() {
        io.println("every one of the {controls.WidgetKind.all().len()} kinds has a tag")
    } else {
        io.println("kinds with no tag: {missing_from_markup.join(", ")}")
    }

    rule("3 — the compiler refuses exactly the kinds the renderer cannot build")

    // The claim this section exists for: a tag the compiler accepts must be a
    // control the renderer can actually make. The two lists are written apart
    // — one in `canvas_tag_is_drawn`, one in `WidgetKind.available` — and this
    // is where they meet.
    var disagree: List<string> = []
    for tag: string in bx.canvas_widget_tags() {
        if bx.canvas_is_drawing_tag(tag) { continue }
        match compose.Vocabulary.kind_of(tag) {
            none => {}
            some(kind) => {
                let compiler: bool = bx.canvas_tag_is_drawn(tag)
                let runtime: bool = kind.available()
                if compiler != runtime {
                    disagree.push("{tag}: compiler says {compiler}, runtime says {runtime}")
                }
            }
        }
    }
    if disagree.is_empty() {
        io.println("the two tables agree on every tag")
    } else {
        for line: string in disagree { io.println(line) }
    }

    rule("4 — what a canvas component can be built from, today")

    io.println(bx.canvas_drawn_list())
}
