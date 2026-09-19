// One parser, two targets.
//
// Stage 5's claim is that latte-bx has **one** front end. That is easy to say
// and easy to be wrong about: two emitters behind one `if` is not a shared
// foundation, it is two compilers that happen to live in one file. So this
// asks the question the claim actually makes.
//
// § 1 — the same markup, parsed for both targets, produces the same tree with
//       the same spans. If the two disagreed about where a `$for` ends or
//       which byte an expression starts at, an error message in one target
//       would point somewhere else in the other.
// § 2 — a form each target has and the other does not is refused by name, with
//       a message about the *program* rather than about a missing case.
// § 3 — the bindings, events and attributes each target really has.
// § 4 — the html target's output has not changed. `tests/markup.b` and the
//       checked-in generated files hold most of that; this holds the part that
//       a target abstraction could most easily break — the default.
package main

import std.io
import latte.bx

fn rule(title: string) {
    io.println("")
    io.println("== {title} ==")
}

/// Every node in a tree, as one line each — the shape and the positions, and
/// nothing about what it compiles into.
///
/// A tag's *meaning* is deliberately left out. `<Label>` is one of Latte's own
/// controls on the canvas and an author's component in HTML, and that is a
/// target's business — it is the thing a target is for. What has to be
/// identical is everything else: where a node starts, how deep it is, which
/// attributes it carries and of what kind. § 3 is where the two targets are
/// asked what a tag means, and there they answer differently on purpose.
fn syntax_only(line: string) -> string {
    return line.replace(" component @", " @").replace(" element @", " @")
}
fn shape(nodes: List<bx.Node>, depth: int, out: List<string>) {
    for node: bx.Node in nodes {
        out.push("{" ".repeat(depth * 2)}{syntax_only(node.show(0))}")
        match node as? bx.ElementNode {
            some(element) => {
                for attribute: bx.Attr in element.attrs {
                    out.push("{" ".repeat(depth * 2 + 2)}@{attribute.show()}")
                }
                shape(element.children, depth + 1, out)
            }
            none => {}
        }
        match node as? bx.IfNode {
            some(branch) => {
                for arm: bx.Branch in branch.branches { shape(arm.body, depth + 1, out) }
            }
            none => {}
        }
        match node as? bx.ForNode {
            some(loop_node) => { shape(loop_node.body, depth + 1, out) }
            none => {}
        }
    }
}

fn tree_of(source: string, target: bx.Target) -> List<string> {
    let doc: bx.Document = bx.parse_document_for(source, target)
    var out: List<string> = []
    shape(doc.nodes, 0, out)
    for d: bx.Diag in doc.diags { out.push("! {d.span.show()} {d.message}") }
    return move out
}

fn same_tree(name: string, source: string) {
    let html: List<string> = tree_of(source, bx.Target.html)
    let canvas: List<string> = tree_of(source, bx.Target.canvas)
    if html.len() != canvas.len() {
        io.println("{name}: DIFFERENT — html has {html.len()} lines, canvas has {canvas.len()}")
        for line: string in html { io.println("  html   {line}") }
        for line: string in canvas { io.println("  canvas {line}") }
        return
    }
    var index: int = 0
    for index < html.len() {
        if html[index] != canvas[index] {
            io.println("{name}: DIFFERENT at line {index + 1}")
            io.println("  html   {html[index]}")
            io.println("  canvas {canvas[index]}")
            return
        }
        index = index + 1
    }
    io.println("{name}: same tree, same spans ({html.len()} lines)")
}

fn refusals(name: string, source: string, target: bx.Target) {
    let doc: bx.Document = bx.parse_document_for(source, target)
    if doc.diags.is_empty() {
        io.println("{name}: accepted")
        return
    }
    for d: bx.Diag in doc.diags {
        io.println("{name}: {d.message}")
    }
}

/// How each target classifies one tag. The one place the two are *supposed*
/// to disagree.
fn tag_meaning(tag: string) {
    let html_rules: bx.TargetRules = bx.Target.html.rules()
    let canvas_rules: bx.TargetRules = bx.Target.canvas.rules()
    let html_word: string = if html_rules.names_a_component(tag) { "component" } else { "element" }
    var canvas_word: string = if canvas_rules.names_a_component(tag) { "component" } else { "control" }
    if canvas_rules.tag_refusal(tag) != "" { canvas_word = "refused" }
    io.println("<{tag}>: html {html_word}, canvas {canvas_word}")
}

fn main() {
    rule("1 — the shared syntax parses identically for both targets")

    // Every form the two targets share, in one file: an element with a
    // literal, an expression and an event; a keyed loop; a conditional with an
    // else; a match; an interpolation; and a component tag with a parameter.
    let shared_lines: List<string> = [
        "<Panel title=\"Orders\" width=\{self.width\} on:click=\{fn(e) \{ self.open() \}\}>",
        "  $for row in self.rows \{",
        "    <Row key=\{row.id\} label=\{row.name\} />",
        "  \}",
        "  $if self.empty \{",
        "    <Label text=\"nothing yet\" />",
        "  \} else \{",
        "    <Label text=\{\"one\"\} />",
        "  \}",
        "</Panel>",
        "",
    ]
    let shared: string = shared_lines.join("\n")
    same_tree("a screen with every shared form", shared)

    // The expression scanner is the part most easily broken by a fork: it has
    // to find the end of a Beans expression through nested braces, strings and
    // comments.
    let tricky: string = "<Row label=\{self.name(\"x\")\} note=\{ /* c */ self.note \} />\n"
    same_tree("expressions with braces inside them", tricky)

    let blocks: string = ["$match self.state \{", "  loading => \{ <Label text=\"one\" /> \}", "  ready => \{ <Label text=\"done\" /> \}", "\}", ""].join("\n")
    same_tree("a match with two arms", blocks)

    rule("2 — a form one target has and the other has not")

    refusals("html doctype", "<!DOCTYPE html>\n<div />", bx.Target.html)
    refusals("canvas doctype", "<!DOCTYPE html>\n<VStack />", bx.Target.canvas)
    refusals("html raw", "<div>$html(self.body)</div>", bx.Target.html)
    refusals("canvas raw", "<VStack>$html(self.body)</VStack>", bx.Target.canvas)
    refusals("html splat", "<div attrs=\{self.extra\} />", bx.Target.html)
    refusals("canvas splat", "<VStack attrs=\{self.extra\} />", bx.Target.canvas)
    refusals("html preserve", "<div preserve />", bx.Target.html)
    refusals("canvas preserve", "<VStack preserve />", bx.Target.canvas)
    refusals("html live", "<div live />", bx.Target.html)
    refusals("canvas live", "<VStack live />", bx.Target.canvas)
    refusals("html inline handler", "<div onclick=\"go()\" />", bx.Target.html)

    rule("3 — what a tag means, which is where the two differ on purpose")

    tag_meaning("Label")
    tag_meaning("VStack")
    tag_meaning("div")
    tag_meaning("OrderRow")

    rule("3b — what each target really has")

    refusals("html bind:value on input", "<input bind:value=\{self.name\} />", bx.Target.html)
    refusals("html bind:value on a div", "<div bind:value=\{self.name\} />", bx.Target.html)
    refusals("canvas bind:value on TextField", "<TextField bind:value=\{self.name\} />", bx.Target.canvas)
    refusals("canvas bind:value on a Label", "<Label bind:value=\{self.name\} />", bx.Target.canvas)
    refusals("canvas bind:checked on Switch", "<Switch bind:checked=\{self.on\} />", bx.Target.canvas)
    refusals("html on:click", "<button on:click=\{fn(e: MouseEvent) \{\}\} />", bx.Target.html)
    refusals("canvas on:click", "<Button on:click=\{fn(e: UiEvent) \{\}\} />", bx.Target.canvas)
    refusals("canvas on:submit", "<Button on:submit=\{fn(e: UiEvent) \{\}\} />", bx.Target.canvas)
    refusals("canvas unknown attribute", "<Label wieght=\{2\} />", bx.Target.canvas)
    refusals("html unknown attribute", "<div data-thing=\"1\" />", bx.Target.html)
    refusals("canvas html element", "<div />", bx.Target.canvas)
    refusals("canvas retired container", "<VFlex />", bx.Target.canvas)

    rule("4 — the html target is what a file means when nobody says")

    let plain: bx.Document = bx.parse_document("<div class=\"x\">hi &amp; bye</div>")
    for node: bx.Node in plain.nodes { io.println("default target: {node.show(0)}") }
    match plain.nodes[0] as? bx.ElementNode {
        some(element) => {
            for child: bx.Node in element.children { io.println("  child: {child.show(0)}") }
        }
        none => {}
    }
}
