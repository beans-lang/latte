// tests/modes.b — render modes and the execution boundary they make.
//
// The claim this suite exists to hold is the one everything else rests on:
// **an inherited mode produces nothing.** No element, no descriptor, no
// instance. A mode that quietly wrapped every component in a marker would
// still pass a test that only looked at the boundaries; § 8 renders the same
// page under an empty scan and under a populated one and compares the bytes.
//
// The second claim is ownership: a parent renderer must not walk into a
// region another runtime owns. § 4 changes a prop on a client boundary whose
// body the server rendered, and the batch must carry exactly one attribute
// edit and no edit at all addressed inside.
package main

import std.io
import {Builder, Component, Layout, MouseEvent, Renderer, RenderMode, ModeScan, ModePlan,
        ModeSource, ResolvedMode, RenderRegion, PropsPlan, Serializer,
        Batch, ComponentUpdate, Edit, describe_edit, props_plan_for, encode_props,
        resolve_render_mode, is_execution_boundary, scan_render_modes,
        param, render_mode} from latte

// ---------------------------------------------------------------- fixtures

/// A component that runs in the browser. Two scalar parameters, so a props
/// object with more than one member is what gets compared — a one-field
/// object hides every ordering and separator bug there is.
@render_mode(value: "client")
pub class Counter extends Component {
    @param pub start: int = 0
    @param pub label: string = ""
    pub clicks: int = 0
    pub fn init() {}
    pub override fn render(b: Builder) {
        b.open(0, "div")
        b.attr(1, "class", "counter")
        b.open(2, "span")
        b.text(3, "{self.label}={self.start + self.clicks}")
        b.close()
        b.open(4, "button")
        b.on_click(5, fn(e: MouseEvent) { self.clicks += 1 })
        b.text(6, "+1")
        b.close()
        b.close()
    }
}

/// Server-rendered once, with nothing alive behind it.
@render_mode(value: "static")
pub class Banner extends Component {
    @param pub title: string = ""
    pub fn init() {}
    pub override fn render(b: Builder) {
        b.open(0, "h2")
        b.text(1, self.title)
        b.close()
    }
}

/// Static, and wrong: a handler in a region with no instance can never run.
@render_mode(value: "static")
pub class DeadButton extends Component {
    pub fn init() {}
    pub override fn render(b: Builder) {
        b.open(0, "button")
        b.on_click(1, fn(e: MouseEvent) {})
        b.text(2, "nothing")
        b.close()
    }
}

/// A client component whose parameter cannot cross.
@render_mode(value: "client")
pub class Unserializable extends Component {
    @param pub rows: List<string> = []
    pub fn init() {}
    pub override fn render(b: Builder) {
        b.open(0, "p")
        b.text(1, "{self.rows.len()}")
        b.close()
    }
}

/// A browser component that asks not to be prerendered.
@render_mode(value: "client", prerender: false)
pub class Late extends Component {
    @param pub note: string = ""
    pub fn init() {}
    pub override fn render(b: Builder) {
        b.open(0, "p")
        b.text(1, self.note)
        b.close()
    }
}

/// A static region that asked not to be prerendered, which is the one thing
/// a static region cannot be: it is nothing BUT a prerender.
@render_mode(value: "static", prerender: false)
pub class EagerStatic extends Component {
    pub fn init() {}
    pub override fn render(b: Builder) {}
}

/// `inherit` written out, which is the absence of a declaration.
@render_mode(value: "inherit")
pub class Inherits extends Component {
    pub fn init() {}
    pub override fn render(b: Builder) {}
}

/// A layout that asked to run in the browser. A layout wraps a page, so this
/// would put the page inside another runtime's region.
@render_mode(value: "client")
pub class ClientShell extends Layout {
    pub fn init() { super.init() }
    pub override fn render(b: Builder) { b.fragment(0, self.body) }
}

/// The control beside it: `server` on a layout is the mode it already has.
@render_mode(value: "server")
pub class ServerShell extends Layout {
    pub fn init() { super.init() }
    pub override fn render(b: Builder) { b.fragment(0, self.body) }
}

/// Two parameters that would cross under one name.
pub class TwoNames extends Component {
    @param(name: "x") pub first: string = ""
    @param(name: "x") pub second: string = ""
    pub fn init() {}
    pub override fn render(b: Builder) {}
}

/// A parameter reflection cannot read, because it is not public.
pub class HiddenProp extends Component {
    @param hidden: string = ""
    pub fn init() {}
    pub override fn render(b: Builder) { b.text(0, self.hidden) }
}

/// The control for both: two distinct public scalar parameters.
pub class GoodProps extends Component {
    @param pub first: string = ""
    @param(name: "second") pub other: int = 0
    pub fn init() {}
    pub override fn render(b: Builder) {}
}

/// An `auto` component that could never run in the browser.
@render_mode(value: "auto")
pub class AutoBad extends Component {
    @param pub rows: List<string> = []
    pub fn init() {}
    pub override fn render(b: Builder) {}
}

/// The control beside it: an `auto` component whose props cross.
@render_mode(value: "auto")
pub class AutoGood extends Component {
    @param pub n: int = 0
    pub fn init() {}
    pub override fn render(b: Builder) {
        b.open(0, "b")
        b.text(1, "{self.n}")
        b.close()
    }
}

/// A page rendered by a CLIENT region: the component a nested-boundary case
/// mounts inside one. It holds a static child and a client child, so the
/// four nestings latte has are all reachable from one fixture.
pub class Inner extends Component {
    @param pub label: string = ""
    pub show_static: bool = false
    pub show_client: bool = false
    pub fn init() {}
    pub override fn render(b: Builder) {
        b.open(0, "div")
        b.attr(1, "class", "inner")
        b.text(2, self.label)
        if self.show_static {
            b.component_in<Banner>(3, "", fn(c: Banner) { c.title = self.label })
        }
        if self.show_client {
            b.component_in<Counter>(4, "", fn(c: Counter) {
                c.label = self.label
                c.start = 0
            })
        }
        b.close()
    }
}

/// Not a component at all.
@render_mode(value: "client")
pub class NotAComponent {
    pub fn init() {}
}

/// A mode nobody has.
@render_mode(value: "edge")
pub class Misspelled extends Component {
    pub fn init() {}
    pub override fn render(b: Builder) {}
}

/// An ordinary child: no declaration anywhere on it.
pub class Plain extends Component {
    @param pub note: string = ""
    pub fn init() {}
    pub override fn render(b: Builder) {
        b.open(0, "em")
        b.text(1, self.note)
        b.close()
    }
}

/// An element whose children another runtime owns — and the same element
/// without the mark, which is the positive control.
///
/// § 9 needs both: "the differ emitted nothing inside" proves nothing unless
/// the same shape without `opaque` proves it WOULD have.
pub class Owned extends Component {
    pub inside: string = "a"
    pub guarded: bool = true
    pub fn init() {}
    pub override fn render(b: Builder) {
        b.open(0, "div")
        b.attr(1, "data-x", self.inside)
        if self.guarded { b.opaque(2) }
        b.text(3, self.inside)
        b.close()
    }
}

/// The page every section renders. `mode` is what a markup `render:mode=`
/// would have written; `""` is a tag that wrote none.
pub class Page extends Component {
    pub heading: string = "board"
    pub start: int = 1
    pub show_counter: bool = true
    pub show_banner: bool = false
    pub show_plain: bool = false
    pub show_late: bool = false
    pub show_bad_param: bool = false
    pub show_dead: bool = false
    pub show_auto: bool = false
    pub counter_mode: string = ""
    pub plain_mode: string = ""
    pub fn init() {}

    pub override fn render(b: Builder) {
        b.open(0, "main")
        b.attr(1, "id", "page")
        if self.show_counter {
            b.component_in<Counter>(2, self.counter_mode, fn(c: Counter) {
                c.start = self.start
                c.label = self.heading
            })
        }
        if self.show_banner {
            b.component_in<Banner>(3, "", fn(c: Banner) { c.title = self.heading })
        }
        if self.show_plain {
            b.component_in<Plain>(4, self.plain_mode, fn(c: Plain) {
                c.note = self.heading
            })
        }
        if self.show_late {
            b.component_in<Late>(5, "", fn(c: Late) { c.note = self.heading })
        }
        if self.show_bad_param {
            b.component_in<Unserializable>(6, "", fn(c: Unserializable) {})
        }
        if self.show_dead {
            b.component_in<DeadButton>(7, "", fn(c: DeadButton) {})
        }
        if self.show_auto {
            b.component_in<AutoGood>(8, "", fn(c: AutoGood) { c.n = 3 })
        }
        b.close()
    }
}

// ---------------------------------------------------------------- helpers

/// Module-level values are `const` in Beans, so the counters live in an
/// object rather than in a mutable global.
class Report {
    pub checks: int = 0
    pub bad: int = 0
    pub fn init() {}

    pub fn same(label: string, got: string, want: string) {
        self.checks += 1
        if got == want {
            io.println("ok   {label}: {got}")
        } else {
            self.bad += 1
            io.println("FAIL {label}: got \"{got}\", want \"{want}\"")
        }
    }

    pub fn same_int(label: string, got: int, want: int) {
        self.checks += 1
        if got == want {
            io.println("ok   {label}: {got}")
        } else {
            self.bad += 1
            io.println("FAIL {label}: got {got}, want {want}")
        }
    }

    /// A line that is its own evidence: printed, and counted.
    pub fn shown(text: string) {
        self.checks += 1
        io.println(text)
    }
}

/// Every edit in a batch, component by component, as text.
fn edits_of(batch: Batch) -> string {
    var out: List<string> = []
    for update: ComponentUpdate in batch.updates {
        for edit: Edit in update.edits {
            out.push("#{update.component} {describe_edit(edit)}")
        }
    }
    if out.len() == 0 { return "(nothing)" }
    return out.join(" | ")
}

fn page_with(scan: ModeScan) -> Renderer {
    let renderer: Renderer = new Renderer()
    renderer.modes = scan
    renderer.owner_mode = RenderMode.server
    renderer.inherited_mode = scan.default_mode
    return renderer
}

/// This file's package, as reflection spells it.
///
/// A suite under the latte module root is not `main` — the entry file gets a
/// package of its own — and pinning whichever name that is would make this
/// suite a test of the compiler's naming rather than of latte's.
fn here() -> string {
    let name: string = type_of(Plain).qualified_name()
    return name.slice(0, name.len() - "Plain".len())
}

fn faults_of(renderer: Renderer) -> string {
    let all: List<string> = renderer.all_faults()
    if all.len() == 0 { return "(none)" }
    return all.join(" | ")
}

// ---------------------------------------------------------------- 1. scan

fn section_scan(report: Report) {
    io.println("== 1. the scan reads every @render_mode, and refuses four shapes ==")
    let scan: ModeScan = scan_render_modes(RenderMode.server)
    report.same("default", scan.default_mode.name(), "server")
    report.same("Counter", scan.mode_of("{here()}Counter").name(), "client")
    report.same("Banner", scan.mode_of("{here()}Banner").name(), "static")
    report.same("Plain declares nothing", scan.mode_of("{here()}Plain").name(), "inherit")
    report.same("Late prerender", "{scan.prerender_of("{here()}Late")}", "false")
    report.same("Counter prerender", "{scan.prerender_of("{here()}Counter")}", "true")
    report.same("a type that declared nothing prerenders",
         "{scan.prerender_of("{here()}Plain")}", "true")

    // A refused declaration answers `inherit`, so it cannot half-work.
    report.same("a misspelled mode is not applied",
         scan.mode_of("{here()}Misspelled").name(), "inherit")
    report.same("a non-component is not applied",
         scan.mode_of("{here()}NotAComponent").name(), "inherit")

    var wrong_word: int = 0
    var not_component: int = 0
    for fault: string in scan.faults {
        if fault.contains("\"edge\"") { wrong_word += 1 }
        if fault.contains("does not extend") { not_component += 1 }
    }
    report.same_int("the misspelling is refused once", wrong_word, 1)
    report.same_int("the non-component is refused once", not_component, 1)
    report.same("browser types", scan.browser_types().join(","),
         "{here()}AutoGood,{here()}Counter,{here()}Late,{here()}Unserializable")
}

// ---------------------------------------------------------------- 2. rules

fn section_precedence(report: Report) {
    io.println("")
    io.println("== 2. precedence: block, then instance, then the type, then around it ==")
    let inherited: RenderMode = RenderMode.server
    let none_: RenderMode = RenderMode.inherit

    report.same("nothing declared inherits",
         resolve_render_mode(inherited, none_, none_, none_, true).mode.name(),
         "server")
    report.same("the type wins over what is around it",
         resolve_render_mode(inherited, RenderMode.client, none_, none_, true).mode.name(),
         "client")
    report.same("the instance wins over the type",
         resolve_render_mode(inherited, RenderMode.client, RenderMode.server,
                             none_, true).mode.name(),
         "server")
    report.same("a block wins over the instance",
         resolve_render_mode(inherited, RenderMode.client, RenderMode.server,
                             RenderMode.plain, true).mode.name(),
         "static")
    report.same("and says where it came from",
         resolve_render_mode(inherited, RenderMode.client, none_, none_, true).source.name(),
         "@render_mode")
    report.same("an inherited answer says so",
         resolve_render_mode(inherited, none_, none_, none_, true).source.name(),
         "application default")

    report.same("equal modes are not a boundary",
         "{is_execution_boundary(RenderMode.server, RenderMode.server)}", "false")
    report.same("different modes are",
         "{is_execution_boundary(RenderMode.server, RenderMode.client)}", "true")
    report.same("static inside server is a boundary too",
         "{is_execution_boundary(RenderMode.server, RenderMode.plain)}", "true")
}

// ---------------------------------------------------------------- 3. client

fn section_client_boundary(report: Report) {
    io.println("")
    io.println("== 3. a client component in a server page is one opaque element ==")
    let scan: ModeScan = scan_render_modes(RenderMode.server)
    let renderer: Renderer = page_with(scan)
    let page: Page = new Page()
    renderer.mount(page)
    io.println(renderer.html())
    report.same("faults", faults_of(renderer), "(none)")

    // The frames the server wrote for the boundary itself — the proof that
    // the element is opaque and that the props ride as an attribute.
    match renderer.buffer(renderer.ids()[1]) {
        some(buffer) => { io.print(buffer.dump()) }
        none => { io.println("FAIL: the boundary has no buffer"); report.bad += 1 }
    }
    report.checks += 1
}

// ---------------------------------------------------------------- 4. props

fn section_props_cross(report: Report) {
    io.println("")
    io.println("== 4. a prop change is one attribute edit, and nothing inside ==")
    let scan: ModeScan = scan_render_modes(RenderMode.server)
    let renderer: Renderer = page_with(scan)
    let page: Page = new Page()
    renderer.mount(page)
    let _: Batch = renderer.batch()

    page.start = 42
    page.notify()
    let _: int = renderer.flush()
    let batch: Batch = renderer.batch()
    report.same("one prop changed", edits_of(batch),
         "#1 in 0 | #1 attr 4:data-latte-props = \{\"start\":42,\"label\":\"board\"\} | #1 out")

    // And the body the server prerendered is NOT re-rendered: the browser
    // owns that DOM now, so a second render of it would describe a tree
    // nobody has.
    report.same("the prerendered body is untouched",
         "{renderer.html().contains("board=1")}", "true")

    // A render that changes nothing sends nothing.
    page.notify()
    let _: int = renderer.flush()
    report.same("an unchanged render", edits_of(renderer.batch()), "(nothing)")
}

// ---------------------------------------------------------------- 5. static

fn section_static(report: Report) {
    io.println("")
    io.println("== 5. a static region has no instance, and its HTML is its props ==")
    let scan: ModeScan = scan_render_modes(RenderMode.server)
    let renderer: Renderer = page_with(scan)
    let page: Page = new Page()
    page.show_counter = false
    page.show_banner = true
    renderer.mount(page)
    io.println(renderer.html())
    let _: Batch = renderer.batch()

    page.heading = "counter"
    page.notify()
    let _: int = renderer.flush()
    report.same("a static region re-renders from its props", edits_of(renderer.batch()),
         "#1 in 0 | #1 attr 4:data-latte-props = \{\"title\":\"counter\"\} | #1 markup 0 = <h2>counter</h2> | #1 out")
}

// ---------------------------------------------------------------- 6. no prerender

fn section_no_prerender(report: Report) {
    io.println("")
    io.println("== 6. prerender: false leaves the element empty ==")
    let scan: ModeScan = scan_render_modes(RenderMode.server)
    let renderer: Renderer = page_with(scan)
    let page: Page = new Page()
    page.show_counter = false
    page.show_late = true
    renderer.mount(page)
    io.println(renderer.html())
    report.same("faults", faults_of(renderer), "(none)")
}

// ---------------------------------------------------------------- 7. refusals

fn section_refusals(report: Report) {
    io.println("")
    io.println("== 7. what a boundary refuses, at the boundary, by name ==")

    let plan: PropsPlan = props_plan_for(type_of(Unserializable))
    report.same("a List parameter cannot cross",
         only_fault(plan.faults, "cannot cross"),
         "{here()}Unserializable.rows is a @param of type List<string>, which cannot cross an execution boundary; a prop is a string, an int, a bool or a float. A callback across a boundary is a server action, not a closure")

    let scan: ModeScan = scan_render_modes(RenderMode.server)
    let renderer: Renderer = page_with(scan)
    let page: Page = new Page()
    page.show_counter = false
    page.show_dead = true
    renderer.mount(page)
    io.println("  {faults_of(renderer)}")
    report.checks += 1

    // An instance override nobody has a mode for.
    let second: Renderer = page_with(scan)
    let other: Page = new Page()
    other.counter_mode = "sideways"
    second.mount(other)
    var named: bool = false
    for fault: string in second.all_faults() {
        if fault.contains("\"sideways\"") { named = true }
    }
    report.same("a misspelled render:mode is refused with the word in it",
         "{named}", "true")
}

// ---------------------------------------------------------------- 8. nothing

fn section_inheritance_is_free(report: Report) {
    io.println("")
    io.println("== 8. an application that declares no mode renders the same bytes ==")

    // The same page, twice: once with the real scan, once with an empty one.
    // `Plain` declares nothing, so under both it must be an ordinary child
    // with no element of its own and no descriptor.
    let empty: ModeScan = new ModeScan()
    let quiet: Renderer = page_with(empty)
    let one: Page = new Page()
    one.show_counter = false
    one.show_plain = true
    quiet.mount(one)

    let scan: ModeScan = scan_render_modes(RenderMode.server)
    let loud: Renderer = page_with(scan)
    let two: Page = new Page()
    two.show_counter = false
    two.show_plain = true
    loud.mount(two)

    report.same("no scan", quiet.html(), "<main id=\"page\"><em>board</em></main>")
    report.same("a scan that knows about other types changes nothing",
         loud.html(), quiet.html())
    report.same("and mounts the same number of components",
         "{quiet.ids().len()}={loud.ids().len()}", "2=2")

    // An instance override on a component that declares nothing still makes
    // a boundary: the override is a declaration.
    let asked: Renderer = page_with(scan)
    let three: Page = new Page()
    three.show_counter = false
    three.show_plain = true
    three.plain_mode = "client"
    asked.mount(three)
    report.same("render:mode on an undeclared component makes a boundary",
         "{asked.html().contains("latte-boundary")}", "true")
}

// ---------------------------------------------------------------- 9. opaque

fn section_opaque(report: Report) {
    io.println("")
    io.println("== 9. opaque stops the differ at the element, attributes and all ==")
    let guarded: Renderer = new Renderer()
    let one: Owned = new Owned()
    guarded.mount(one)
    let _: Batch = guarded.batch()
    one.inside = "b"
    one.notify()
    let _: int = guarded.flush()
    report.same("an opaque element sends its attributes and nothing inside",
                edits_of(guarded.batch()),
                "#0 in 0 | #0 attr 1:data-x = b | #0 out")

    let plain: Renderer = new Renderer()
    let two: Owned = new Owned()
    two.guarded = false
    plain.mount(two)
    let _: Batch = plain.batch()
    two.inside = "b"
    two.notify()
    let _: int = plain.flush()
    report.same("and without the mark the same change reaches the child",
                edits_of(plain.batch()),
                "#0 in 0 | #0 attr 1:data-x = b | #0 text 0 = b | #0 out")
}


// ---------------------------------------------------------------- 10. sites
//
// Every `faults.push` in modes.b and region.b, with the case that trips it
// and the nearest legal shape beside it.
//
// The tally at the end is what `test.sh`'s refusal-coverage leg reads. It
// counts SITES, not cases: a refusal nothing feeds raises nothing and is
// counted by nobody, so a new one that nothing exercises turns this red
// rather than sitting green for a release.

const M_DEFAULT: string = "scan_render_modes / the application default is inherit"
const M_WORD: string = "scan_render_modes / a value that is not a mode"
const M_INHERIT: string = "scan_render_modes / a value of inherit"
const M_PRERENDER: string = "scan_render_modes / prerender: false where there is nothing to switch off"
const M_AUTO: string = "scan_render_modes / an auto component that cannot cross"
const M_COMPONENT: string = "scan_render_modes / @render_mode on something that is not a Component"
const M_LAYOUT: string = "scan_render_modes / a layout in a mode that is not server"
const M_RELAY: string = "scan_render_modes / a plan's faults reach the scan's"
const R_TWICE: string = "props_plan_for / two @param fields cross as one name"
const R_HIDDEN: string = "props_plan_for / a @param that is not public"
const R_TYPE: string = "props_plan_for / a @param that cannot cross"
const R_RELAY: string = "RenderRegion.render / a region's problems reach the Builder"

/// The one fault in `list` that mentions `needle`, or a sentence saying how
/// many there were instead. Exactly one: a refusal that fires twice for one
/// shape is a refusal whose message a reader will see doubled.
fn running_in_of(renderer: Renderer) -> string {
    var out: List<string> = []
    for id: int in renderer.ids() {
        match renderer.component(id) {
            some(component) => { out.push(component.running_in().name()) }
            none => {}
        }
    }
    return out.join("/")
}

/// The one fault in `list` that mentions `needle`, or a sentence saying how
/// many there were instead.
fn only_fault(list: List<string>, needle: string) -> string {
    var found: List<string> = []
    for fault: string in list {
        if fault.contains(needle) { found.push(fault) }
    }
    if found.len() == 1 { return found[0] }
    return "{found.len()} faults mention \"{needle}\""
}

fn section_sites(report: Report) {
    io.println("")
    io.println("== 10. every fault site in modes.b and region.b ==")
    var reached: Map<string, int> = {}
    let scan: ModeScan = scan_render_modes(RenderMode.server)

    // -- modes.b ----------------------------------------------------------

    let refused: ModeScan = scan_render_modes(RenderMode.inherit)
    site_case(report, reached, "a-default-of-inherit", M_DEFAULT,
        only_fault(refused.faults, "default render mode"),
        "the application's default render mode is \"inherit\", which names nothing to inherit from; it must be one of static, server, client or auto",
        only_fault(scan.faults, "default render mode"))
    report.same("a-default-of-inherit: and it falls back to server",
                refused.default_mode.name(), "server")

    site_case(report, reached, "a-mode-nobody-has", M_WORD,
        only_fault(scan.faults, "Misspelled"),
        "{here()}Misspelled is annotated @render_mode(value: \"edge\"), which is not a mode; it must be one of static, server, client or auto",
        only_fault(scan.faults, "Banner"))

    site_case(report, reached, "a-mode-of-inherit", M_INHERIT,
        only_fault(scan.faults, "Inherits"),
        "{here()}Inherits is annotated @render_mode(value: \"inherit\"), which is the absence of a declaration; delete the annotation to inherit",
        only_fault(scan.faults, "Plain"))

    site_case(report, reached, "no-prerender-to-switch-off", M_PRERENDER,
        only_fault(scan.faults, "EagerStatic"),
        "{here()}EagerStatic is annotated @render_mode(value: \"static\", prerender: false); a static region IS server-rendered HTML, so there is nothing to switch off",
        only_fault(scan.faults, "Late"))

    site_case(report, reached, "an-auto-component-that-cannot-cross", M_AUTO,
        only_fault(scan.faults, "AutoBad"),
        "{here()}AutoBad is annotated @render_mode(value: \"auto\"), so it must be able to run in the browser: {here()}AutoBad.rows is a @param of type List<string>, which cannot cross an execution boundary; a prop is a string, an int, a bool or a float. A callback across a boundary is a server action, not a closure",
        only_fault(scan.faults, "AutoGood"))

    site_case(report, reached, "a-mode-on-a-non-component", M_COMPONENT,
        only_fault(scan.faults, "NotAComponent"),
        "{here()}NotAComponent is annotated @render_mode but does not extend latte.Component, so it renders nothing that could run anywhere",
        only_fault(scan.faults, "Counter"))

    site_case(report, reached, "a-layout-in-the-browser", M_LAYOUT,
        only_fault(scan.faults, "ClientShell"),
        "{here()}ClientShell is a latte.Layout annotated @render_mode(value: \"client\"); a layout wraps a page, so this would put the page inside another runtime's region — a nesting latte does not have. Put the mode on the components inside the page",
        only_fault(scan.faults, "ServerShell"))

    // The relay: a plan's own faults are copied onto the scan's list, which
    // is the list a host refuses on. Without it every refusal above would be
    // recorded on a plan nobody reads.
    var relayed: int = 0
    for name: string in scan.plans.keys() {
        match scan.plans.get(name) {
            some(plan) => {
                for fault: string in plan.faults {
                    if scan.faults.contains(fault) { relayed += 1 }
                }
            }
            none => {}
        }
    }
    site_case(report, reached, "a-plans-faults-reach-the-scan", M_RELAY,
        "{relayed} of a plan's faults reached the scan",
        "6 of a plan's faults reached the scan",
        only_fault(scan.faults, "GoodProps"))

    // -- region.b ---------------------------------------------------------

    let good: PropsPlan = props_plan_for(type_of(GoodProps))
    let control: string = "{good.usable()} with {good.names.join(",")}"

    let twice: PropsPlan = props_plan_for(type_of(TwoNames))
    site_case(report, reached, "two-params-under-one-name", R_TWICE,
        only_fault(twice.faults, "cross as"),
        "{here()}TwoNames.second: two @param fields both cross as \"x\"",
        control)

    let hidden: PropsPlan = props_plan_for(type_of(HiddenProp))
    site_case(report, reached, "a-param-that-is-not-public", R_HIDDEN,
        only_fault(hidden.faults, "not public"),
        "{here()}HiddenProp.hidden is a @param but is not public, and reflection does not bypass visibility, so nothing would cross",
        control)

    let wrong: PropsPlan = props_plan_for(type_of(Unserializable))
    site_case(report, reached, "a-param-that-cannot-cross", R_TYPE,
        only_fault(wrong.faults, "cannot cross"),
        "{here()}Unserializable.rows is a @param of type List<string>, which cannot cross an execution boundary; a prop is a string, an int, a bool or a float. A callback across a boundary is a server action, not a closure",
        control)

    // The relay out of a region: what `RenderRegion` refused has to reach the
    // Builder's fault list, or a host that checks faults sees none.
    let dead: Renderer = page_with(scan)
    let one: Page = new Page()
    one.show_counter = false
    one.show_dead = true
    dead.mount(one)
    let alive: Renderer = page_with(scan)
    let two: Page = new Page()
    two.show_counter = false
    two.show_banner = true
    alive.mount(two)
    site_case(report, reached, "a-regions-problems-reach-the-builder", R_RELAY,
        only_fault(dead.all_faults(), "DeadButton"),
        "1: {here()}DeadButton is rendered static and binds on:click; a static region has no instance, so the handler can never run",
        faults_of(alive))

    var names: List<string> = reached.keys()
    names.sort()
    io.println("-- the sites in modes.b, and how many shapes reach each")
    for name: string in names {
        if !name.starts_with("scan_render_modes") { continue }
        match reached.get(name) { some(n) => { io.println("   {n}x {name}") } none => {} }
    }
    io.println("-- the sites in region.b, and how many shapes reach each")
    for name: string in names {
        if name.starts_with("scan_render_modes") { continue }
        match reached.get(name) { some(n) => { io.println("   {n}x {name}") } none => {} }
    }
}

/// One refusal, in the shape `probes/delete_faults.sh` reads: the case name,
/// the site it names, what it said, and the nearest legal shape beside it.
///
/// The control is a string that must be EMPTY of any fault. Every one here is
/// a sibling of the refusing case — the same annotation done right, the same
/// props plan with legal fields — because a control that shares nothing with
/// the trip proves only that unrelated code works.
fn site_case(report: Report, reached: Map<string, int>, name: string,
             site: string, got: string, want: string, control: string) {
    io.println("-- {name}")
    io.println("   site:    {site}")
    io.println("   fault:   {got}")
    io.println("   control: {control}")
    report.same("{name}: the exact fault", got, want)
    report.same("{name}: the control is quiet", control_is_quiet(control), "true")
    match reached.get(site) {
        some(n) => { reached[site] = n + 1 }
        none => { reached[site] = 1 }
    }
}

/// Whether a control said nothing. `only_fault` answers "0 faults mention …"
/// when there were none, and the two renderer controls answer "(none)".
fn control_is_quiet(control: string) -> string {
    if control.starts_with("0 faults mention ") { return "true" }
    if control == "(none)" { return "true" }
    if control.starts_with("true with ") { return "true" }
    return "false: {control}"
}

// ---------------------------------------------------------------- 11. auto

fn section_auto(report: Report) {
    io.println("")
    io.println("== 11. auto is a decision between the two runtimes, taken once ==")
    let scan: ModeScan = scan_render_modes(RenderMode.server)

    // No bundle yet: the region runs on the server, which means it is not a
    // region at all — it is an ordinary child of the page, interactive
    // through the circuit that is already there.
    let cold: Renderer = page_with(scan)
    let one: Page = new Page()
    one.show_counter = false
    one.show_auto = true
    cold.mount(one)
    report.same("with no bundle, an auto component is not a boundary",
                cold.html(), "<main id=\"page\"><b>3</b></main>")
    report.same("and nothing in the page says client",
                "{cold.html().contains("client")}", "false")

    // The browser has the bundle: the same component, the same page, and now
    // a client region with its props on it.
    let warm: Renderer = page_with(scan)
    warm.auto_mode = RenderMode.client
    let two: Page = new Page()
    two.show_counter = false
    two.show_auto = true
    warm.mount(two)
    report.same("with a bundle, the same component is a client region",
                "{warm.html().contains("data-latte-mode=\"client\"")}", "true")
    report.same("carrying its props", "{warm.html().contains("\{&quot;n&quot;:3\}")}",
                "true")
    report.same("and its server render inside it, to paint before the bundle runs",
                "{warm.html().contains("<b>3</b>")}", "true")

    // Pinned: the decision belongs to the render, so a later flush cannot
    // move a live instance between runtimes.
    two.heading = "second"
    two.notify()
    let _: int = warm.flush()
    report.same("a re-render does not move a mounted region",
                "{warm.html().contains("data-latte-mode=\"client\"")}", "true")
}

// ---------------------------------------------------------------- 12. nesting

fn section_nesting(report: Report) {
    io.println("")
    io.println("== 12. the four nestings, and the one that is refused ==")
    let scan: ModeScan = scan_render_modes(RenderMode.server)

    // A STATIC region inside a CLIENT one. The browser renders it, so it is
    // not foreign: its element is not opaque and its body follows its props.
    let inner: Renderer = new Renderer()
    inner.modes = scan
    inner.owner_mode = RenderMode.client
    inner.inherited_mode = RenderMode.client
    let one: Inner = new Inner()
    one.label = "a"
    one.show_static = true
    inner.mount(one)
    report.same("a static region inside a client one renders", inner.html(),
                "<div class=\"inner\">a<latte-boundary data-latte-boundary=\"1\" data-latte-mode=\"static\" data-latte-component=\"{here()}Banner\" data-latte-props=\"\{&quot;title&quot;:&quot;a&quot;\}\" data-latte-prerendered=\"\"><h2>a</h2></latte-boundary></div>")
    report.same("and nothing about it is foreign", faults_of(inner), "(none)")

    // Its props still reach it, which a foreign region's would not: a
    // static region has no runtime, so the browser owns its DOM and must
    // keep it right.
    let _: Batch = inner.batch()
    one.label = "b"
    one.notify()
    let _: int = inner.flush()
    report.same("a static region inside a client one follows its props",
                edits_of(inner.batch()),
                "#0 in 0 | #0 text 0 = b | #0 out | #1 in 0 | #1 attr 4:data-latte-props = \{\"title\":\"b\"\} | #1 markup 0 = <h2>b</h2> | #1 out")

    // A CLIENT region inside a CLIENT one is not a boundary: it is the same
    // runtime, so there is nothing to cross.
    let same_runtime: Renderer = new Renderer()
    same_runtime.modes = scan
    same_runtime.owner_mode = RenderMode.client
    same_runtime.inherited_mode = RenderMode.client
    let two: Inner = new Inner()
    two.label = "c"
    two.show_client = true
    same_runtime.mount(two)
    report.same("a client region inside a client one is no boundary at all",
                "{same_runtime.html().contains("latte-boundary")}", "false")
    report.same("it is just a child", same_runtime.html(),
                "<div class=\"inner\">c<div class=\"counter\"><span>c=0</span><button>+1</button></div></div>")

    // And the one latte does not have, refused by name.
    let refused: Renderer = new Renderer()
    refused.modes = scan
    refused.owner_mode = RenderMode.client
    refused.inherited_mode = RenderMode.client
    let three: Page = new Page()
    three.show_counter = false
    three.show_plain = true
    three.plain_mode = "server"
    refused.mount(three)
    report.same("a component can ask where it is running",
                "{one.running_in().name()}", "client")
    // The region component itself is in the client region too — what is
    // inside it has a renderer of its own, which is the whole point.
    report.same("and so can everything the same renderer holds",
                running_in_of(inner), "client/client")

    // That renderer's own answer, from the other side: a component a static
    // region renders is told `static`, which is what a component that must
    // not start a timer needs to hear.
    let still: Renderer = new Renderer()
    still.modes = scan
    still.owner_mode = RenderMode.plain
    still.inherited_mode = RenderMode.plain
    let quiet: Banner = new Banner()
    quiet.title = "a"
    still.mount(quiet)
    report.same("a static render says so", running_in_of(still), "static")

    report.same("a server region inside a client one is refused",
                faults_of(refused),
                "0: <Plain> at 4 resolves to server inside a client region; a server region inside a browser one needs a server mount protocol latte does not have yet. Move it out of the client region, or make it client")
    report.same("and the component renders where it is, rather than vanishing",
                refused.html(), "<main id=\"page\"><em>board</em></main>")
}

fn main() {
    let report: Report = new Report()
    section_scan(report)
    section_precedence(report)
    section_client_boundary(report)
    section_props_cross(report)
    section_static(report)
    section_no_prerender(report)
    section_refusals(report)
    section_inheritance_is_free(report)
    section_opaque(report)
    section_sites(report)
    section_auto(report)
    section_nesting(report)
    io.println("")
    io.println("{report.checks} checks, {report.bad} bad")
}
