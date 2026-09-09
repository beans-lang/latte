// `@inject` on a component field: what fills it, what refuses, and the
// controls that tell one from the other.
//
// Constructor injection reaches a `@page`, because the container builds one.
// It cannot reach a CHILD: children are constructed by the renderer at mount,
// from a zero-argument initializer, and the renderer is not a container. Before
// this, a nested component could only see a shared object if every ancestor
// between it and the page passed it down as a `@param` — which is a prop chain
// for something that is not a prop.
//
// The names in the expected faults are `latte$entry.X` and not `main.X`: a
// library's `tests/` entry gets a synthetic package, and the `0:` in front is
// the id of the buffer that raised the fault. Both are what a reader of a real
// fault list sees, so they are in the goldens rather than filed off.
//
// The source here is a hand-written `ServiceSource` and not a container. That
// is the point of the interface: latte's core knows what a service source is
// and nothing about what a service collection is, so this suite needs no
// dependency to exercise the whole path.
package main

import std.io
import std.reflect
import {Builder, Component, Renderer, ServiceSource, inject,
        scan_injections} from latte

// ---------------------------------------------------------------- services

pub class Clock {
    static made: int = 0
    pub tag: int = 0
    pub fn init() {
        Clock.made += 1
        self.tag = Clock.made
    }
    pub fn reading() -> string { return "clock#{self.tag}" }
}

/// A source that knows about exactly one type. Everything else it refuses by
/// name, which is what the "unknown service" case reads.
pub class OneService implements ServiceSource {
    pub asked: int = 0
    pub fn init() {}
    pub fn provide(described: reflect.Type) -> Result<reflect.Value, string> {
        self.asked += 1
        if self.knows(described) { return ok(reflect.value(new Clock())) }
        return err("nothing provides {described.qualified_name()}")
    }

    pub fn knows(described: reflect.Type) -> bool {
        return described.qualified_name() == type_of(Clock).qualified_name()
    }
}

// ---------------------------------------------------------------- components

/// The subject: a child that asks for a service by field.
pub class Stamped extends Component {
    @inject pub clock: Clock = new Clock()
    pub fn init() {}
    pub override fn render(b: Builder) {
        b.open(0, "span")
        b.text(1, "{self.clock.reading()}")
        b.close()
    }
}

/// The control: the same shape with no `@inject` at all. It must mount and
/// render whether a source is present or not — otherwise "the injected one
/// worked" could not be told from "mounting works".
pub class Plain extends Component {
    pub label: string = "plain"
    pub fn init() {}
    pub override fn render(b: Builder) {
        b.open(0, "span")
        b.text(1, "{self.label}")
        b.close()
    }
}

/// A field reflection cannot write. It must be refused by name rather than
/// left silently at its default.
pub class Hidden extends Component {
    @inject clock: Clock = new Clock()
    pub fn init() {}
    pub override fn render(b: Builder) {
        b.open(0, "span")
        b.text(1, "hidden")
        b.close()
    }
}

/// A field whose type nothing provides.
pub class Missing extends Component {
    @inject pub other: Plain = new Plain()
    pub fn init() {}
    pub override fn render(b: Builder) {
        b.open(0, "span")
        b.text(1, "missing")
        b.close()
    }
}

/// The page that mounts children. Which one it mounts is a field, so one page
/// class drives every case.
pub class Host extends Component {
    pub which: string = "stamped"
    pub fn init() {}
    pub override fn render(b: Builder) {
        b.open(0, "div")
        if self.which == "stamped" {
            b.component<Stamped>(1, fn(c: Stamped) {})
        } else if self.which == "plain" {
            b.component<Plain>(1, fn(c: Plain) {})
        } else if self.which == "hidden" {
            b.component<Hidden>(1, fn(c: Hidden) {})
        } else {
            b.component<Missing>(1, fn(c: Missing) {})
        }
        b.close()
    }
}

// ---------------------------------------------------------------- the checks

fn report(what: string, got: string, want: string) {
    if got == want { io.println("ok   {what}: {got}") }
    else { io.println("FAIL {what}: got [{got}], want [{want}]") }
}

class Run {
    pub html: string = ""
    pub faults: string = ""
    pub fn init() {}
}

fn render(which: string, source: Option<ServiceSource>) -> Run {
    var out: Run = new Run()
    let renderer: Renderer = new Renderer()
    renderer.services = source
    var page: Host = new Host()
    page.which = which
    renderer.mount(page)
    out.html = renderer.html()
    // `all_faults()` and not `faults`: the Renderer's own list holds only
    // what the renderer noticed, and a mount fault — which is what a failed
    // injection is — lives on the Builder that raised it.
    out.faults = renderer.all_faults().join(" | ")
    return move out
}

fn main() {
    io.println("== 1. with a source, an @inject field is filled ==")
    let one: OneService = new OneService()
    let filled: Run = render("stamped", some(one))
    // `clock#2`, not `#1`: the field's own initializer runs when the component
    // is constructed and the injected value replaces it. That is worth seeing
    // rather than hiding — a `@inject` field's default is a real object that is
    // really built, so do not put anything expensive in one.
    report("the child rendered its injected service",
           filled.html, "<div><span>clock#2</span></div>")
    report("and nothing was refused", filled.faults, "")
    report("the source was asked exactly once", "{one.asked}", "1")

    io.println("")
    io.println("== 2. THE CONTROL: a component with no @inject ==")
    let two: OneService = new OneService()
    let plain: Run = render("plain", some(two))
    report("it renders", plain.html, "<div><span>plain</span></div>")
    report("nothing was refused", plain.faults, "")
    // This is the line that says the plan is per type and not "ask for every
    // field of everything": a component with no @inject never reaches the
    // source at all, so a page of them costs nothing.
    report("and the source was never asked", "{two.asked}", "0")

    io.println("")
    io.println("== 3. no source: an @inject field is refused, by name ==")
    let orphan: Run = render("stamped", none)
    report("the fault names the field and says why",
           orphan.faults,
           "0: latte$entry.Stamped.clock is @inject, but this page has no service container to fill it from")
    // The control for section 3: with no source, the component that asks for
    // nothing is still fine. Without this, "no source refuses" could mean
    // "no source breaks rendering".
    let orphan_control: Run = render("plain", none)
    report("THE CONTROL: a component with no @inject still renders",
           orphan_control.html, "<div><span>plain</span></div>")
    report("...and raises nothing", orphan_control.faults, "")

    io.println("")
    io.println("== 4. a field reflection cannot write ==")
    let hidden: Run = render("hidden", some(new OneService()))
    report("a non-public @inject field is refused",
           hidden.faults,
           "0: latte$entry.Hidden.clock is @inject but is not public, and reflection does not bypass visibility")

    io.println("")
    io.println("== 5. a service nothing provides ==")
    let missing: Run = render("missing", some(new OneService()))
    report("the source's own words reach the fault",
           missing.faults,
           "0: latte$entry.Missing.other: nothing provides latte$entry.Plain")
    io.println("")
    io.println("== 6. the same three faults, found at STARTUP ==")
    // Sections 3 to 5 are what a render does with a bad `@inject`: it leaves
    // the field at its default and buries a fault in a buffer's list, and the
    // page still answers 200. That is right for rendering — a subtree that
    // cannot be built leaves the rest of the page standing, which is what a
    // live circuit needs — and wrong for "the service you asked for does not
    // exist", which is a configuration fault and decidable before a socket
    // exists.
    //
    // `scan_injections` walks every Component in the executable once. This
    // file declares four of them, and the assertion is not "it found some
    // faults" but exactly WHICH: the two that cannot be filled, and neither of
    // the two that can. A scan that reported all four would pass a weaker test
    // and be useless.
    let found: List<string> = scan_injections(some(new OneService()))
    var sorted: List<string> = found.clone()
    sorted.sort()
    report("it found exactly two", "{sorted.len()}", "2")
    report("the non-public field", sorted[0],
           "latte$entry.Hidden.clock is @inject but is not public, and reflection does not bypass visibility")
    report("the unregistered service", sorted[1],
           "latte$entry.Missing.other is @inject but nothing is registered for latte$entry.Plain")

    // The controls, and they are the point of the section. `Stamped` has an
    // @inject field the source CAN fill, and `Plain` has none at all; neither
    // may appear.
    var named_stamped: bool = false
    var named_plain: bool = false
    for problem: string in found {
        if problem.contains("Stamped") { named_stamped = true }
        if problem.contains("Plain.") { named_plain = true }
    }
    report("THE CONTROL: a fillable @inject is not reported", "{named_stamped}", "false")
    report("THE CONTROL: a component with no @inject is not reported", "{named_plain}", "false")

    io.println("")
    io.println("== 7. no container at all ==")
    let orphaned: List<string> = scan_injections(none)
    // Three now, not two: with no source, `Stamped` joins them — its field is
    // public and fillable, and there is nothing to fill it from.
    report("every @inject field is reported", "{orphaned.len()}", "3")
    var says_container: int = 0
    for problem: string in orphaned {
        if problem.contains("no service container") { says_container += 1 }
    }
    report("and two of them say why", "{says_container}", "2")
}
