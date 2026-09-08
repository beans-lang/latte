// p12 — B8 measured from inside a CONSUMER's module, and located.
//
// BLOCKERS.md **B8** says `type_of(T)` for a type reached through a **named
// import** answers `<importing module>.<simple name>` — a name that does not
// exist — so `is_assignable_from` is false for a genuine base and subclass.
// It was measured once, in `p11_type_of_name`, from a `package main` entry.
// Nobody had asked it from a real consumer: a different MODULE, importing
// latte's root package by name, which is what every third-party component
// library is.
//
// The answer is not the one anybody expected. **The importing package is not
// what decides it.** The same expression, in the same function, answers
// correctly or incorrectly depending on whether it is written INSIDE a string
// interpolation — which makes B8 the same bug as **B9**, not merely the same
// shape. This probe is the matrix that shows it: four kinds of name, each
// asked both ways, in an entry file and in a named package.
package main

import std.io
import std.reflect
import std.fmt
import {Builder, Component, Renderer} from latte
import {Card} from p12_consumer.widgets
import {component_inside, component_outside, card_inside, card_outside,
        dotpath_inside, dotpath_outside,
        assignable_inside, assignable_outside} from p12_consumer.widgets2

/// A base and subclass declared HERE. The control: a name that needed no
/// import cannot be lost by an import table, and must read right both ways.
pub class LocalBase { pub fn init() {} }
pub class LocalSub extends LocalBase { pub fn init() { super.init() } }

/// A consumer component: it extends a type from ANOTHER MODULE.
pub class Panel extends Component {
    pub fn init() {}
    pub override fn render(b: Builder) {
        b.open(0, "section")
        b.close()
    }
}

fn row(what: string, inside: string, outside: string) {
    let verdict: string = if inside == outside { "same" } else { "DIFFERENT" }
    io.println("  {pad(what)} inside={pad2(inside)} outside={pad2(outside)}  {verdict}")
}

fn pad(text: string) -> string {
    var out: string = text
    for out.len() < 34 { out = "{out} " }
    return out
}

fn pad2(text: string) -> string {
    var out: string = text
    for out.len() < 28 { out = "{out} " }
    return out
}

fn main() {
    io.println("== the entry file (package main, module p12_consumer) ==")

    // control: declared in this file, so no import binding is involved.
    let local_out: reflect.Type = type_of(LocalBase)
    row("LocalBase (declared here)",
        "{type_of(LocalBase).qualified_name()}", local_out.qualified_name())

    // control: a dot-path package reference, which B9 also found unaffected.
    let dot_out: reflect.Type = type_of(fmt.StringBuilder)
    row("fmt.StringBuilder (dot-path)",
        "{type_of(fmt.StringBuilder).qualified_name()}", dot_out.qualified_name())

    // subject: a named import from ANOTHER MODULE — latte's own base type.
    let comp_out: reflect.Type = type_of(Component)
    row("Component (named, other module)",
        "{type_of(Component).qualified_name()}", comp_out.qualified_name())

    // subject: a named import from a SUBPACKAGE of this module.
    let card_out: reflect.Type = type_of(Card)
    row("Card (named, own subpackage)",
        "{type_of(Card).qualified_name()}", card_out.qualified_name())

    io.println("")
    io.println("== a named package (package widgets2, same module) ==")
    row("LocalBase equivalent", "n/a — declared in the entry", "n/a — declared in the entry")
    row("fmt.StringBuilder (dot-path)", dotpath_inside(), dotpath_outside())
    row("Component (named, other module)", component_inside(), component_outside())
    row("Card (named, own subpackage)", card_inside(), card_outside())

    io.println("")
    io.println("== the question a framework actually asks ==")
    let base: reflect.Type = type_of(Component)
    let panel: reflect.Type = type_of(Panel)
    io.println("  entry, inside an interpolation:  Component.is_assignable_from(Panel) = {type_of(Component).is_assignable_from(type_of(Panel))}")
    io.println("  entry, outside:                  Component.is_assignable_from(Panel) = {base.is_assignable_from(panel)}")
    io.println("  widgets2, inside an interpolation: Component.is_assignable_from(Card) = {assignable_inside()}")
    io.println("  widgets2, outside:                 Component.is_assignable_from(Card) = {assignable_outside()}")
    match type_of(Panel).base_type() {
        some(link) => { io.println("  Panel's base link (always right)  = {link.qualified_name()}") }
        none => {}
    }

    io.println("")
    io.println("== what the wrong name is, exactly ==")
    let wrong: string = "{type_of(Component).qualified_name()}"
    let right: string = comp_out.qualified_name()
    io.println("  wrong = {wrong}   find_type finds it: {reflect.find_type(wrong).is_some()}")
    io.println("  right = {right}   find_type finds it: {reflect.find_type(right).is_some()}")

    io.println("")
    io.println("== it still renders; only the NAME is lost ==")
    let r: Renderer = new Renderer()
    let card: Card = new Card()
    card.title = "hello"
    r.mount(card)
    io.println("  {r.html()}")
}
