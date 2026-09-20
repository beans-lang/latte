// Do the compiler and the runtime agree about what a canvas component is?
// Two tables, because `latte.bx` must build with no renderer. This is the price.
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
        // The drawing shapes are a `visual.Kind` on a canvas, not a widget
        // kind: `WidgetMaker.bare` resolves them before it reads the kind.
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

    // A tag the compiler accepts must be a control the renderer can make.
    // `canvas_tag_is_drawn` and `WidgetKind.available` meet here.
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

    rule("5 — the two tables agree on every tag and attribute pair")

    // What a tag *carries*, with a table on each side. A layout name is left
    // out — it is the parent's — and 5b holds the one name that means both.
    var wrong: List<string> = []
    var pairs: int = 0
    for tag: string in bx.canvas_widget_tags() {
        if bx.canvas_is_drawing_tag(tag) { continue }
        match compose.Vocabulary.kind_of(tag) {
            none => {}
            some(kind) => {
                for name: string in bx.canvas_attribute_names() {
                    if compose.Vocabulary.is_layout_name(name) { continue }
                    pairs = pairs + 1
                    let compiler: bool = bx.canvas_tag_carries(tag, name)
                    let runtime: bool = compose.Vocabulary.carries(kind, name)
                    if compiler != runtime {
                        wrong.push("{tag}.{name}: compiler says {compiler}, runtime says {runtime}")
                    }
                }
            }
        }
    }
    if wrong.is_empty() {
        io.println("{pairs} pair(s) checked, and the two tables answer the same for every one")
    } else {
        for line: string in wrong { io.println(line) }
    }

    rule("5b — the names that mean a layout to one tag and a property to another")

    // Not a pass or a fail: a printed list the golden holds. `columns` is a
    // Grid's track list and a Table's column titles, by two different roads.
    for name: string in bx.canvas_attribute_names() {
        if !compose.Vocabulary.is_layout_name(name) { continue }
        if compose.Vocabulary.property_of(name) < 0 { continue }
        var takers: List<string> = []
        for tag: string in bx.canvas_widget_tags() {
            if bx.canvas_is_drawing_tag(tag) { continue }
            match compose.Vocabulary.kind_of(tag) {
                none => {}
                some(kind) => {
                    if compose.Vocabulary.carries(kind, name) { takers.push(tag) }
                }
            }
        }
        io.println("{name}: a layout name everywhere, and a property on {takers.join(", ")}")
    }

    rule("6 — the placement names, which are written out on both sides")

    // What a component tag may carry: the run its root sits in reads these,
    // and the compiler has to know the same set to refuse the rest.
    var split: List<string> = []
    for name: string in bx.canvas_attribute_names() {
        let compiler: bool = bx.canvas_is_placement_attribute(name)
        let runtime: bool = compose.Vocabulary.is_placement_name(name)
        if compiler != runtime {
            split.push("{name}: compiler says {compiler}, runtime says {runtime}")
        }
    }
    if split.is_empty() {
        io.println("every name is a placement name to both, or to neither")
    } else {
        for line: string in split { io.println(line) }
    }
}
