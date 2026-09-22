// Where a component runs, and how one of four answers is chosen.
//
// A mode is not a flag on a component. It is the property of a REGION: the
// component that declared it, and everything under it that did not declare
// something else. A region whose owner differs from its parent's is an
// execution boundary — a separate instance, a separate lifecycle, a separate
// piece of the DOM — and the only way to make one is to change the mode.
//
// That distinction is the whole design. A mode that were a flag would let a
// parent and a child disagree about who owns a DOM node while sharing one
// render tree, and there is no correct behaviour for that. So an inherited
// mode produces NOTHING: no boundary, no element, no descriptor. An
// application that declares no mode anywhere renders exactly the bytes it
// rendered before this file existed.
//
// Nothing here imports std.io, std.fs or std.net. See beans.pot.
package latte

import std.reflect

// ---------------------------------------------------------------- the word

/// A component's default execution mode.
///
/// `@render_mode(value: "server")` on a type, `render:mode="client"` on one
/// instance of it, `<RenderBlock mode="client">` around a markup block.
///
/// `prerender` asks for server-rendered HTML inside the boundary before the
/// browser runtime takes it over. It is meaningful only for `client` and
/// `auto`; `static` IS a prerender, and a `server` region's first render is
/// one, so declaring it false on either is refused rather than ignored.
@target(value: ["type"])
@retention(value: "runtime")
pub annotation render_mode {
    value: string
    prerender: bool = true
}

/// The four modes, and the fifth answer that means "nobody said".
pub enum RenderMode {
    /// No declaration at this level. Never a resolved answer — resolution
    /// walks up until it finds one, and the application default is the floor.
    inherit
    /// Server-rendered HTML with no live instance behind it. Authored as
    /// "static", which is a Beans keyword and cannot name a variant.
    plain
    server
    client
    auto

    /// The word an author writes and the wire carries.
    pub fn name() -> string {
        return match self {
            inherit => "inherit"
            plain => "static"
            server => "server"
            client => "client"
            auto => "auto"
        }
    }

    pub static fn of(word: string) -> Option<RenderMode> {
        if word == "static" { return some(RenderMode.plain) }
        if word == "server" { return some(RenderMode.server) }
        if word == "client" { return some(RenderMode.client) }
        if word == "auto" { return some(RenderMode.auto) }
        if word == "inherit" { return some(RenderMode.inherit) }
        return none
    }

    /// Whether a region in this mode has a live instance that answers events.
    pub fn interactive() -> bool {
        return match self {
            inherit => false
            plain => false
            server => true
            client => true
            auto => true
        }
    }

    /// Whether the browser owns this region's instance.
    ///
    /// `auto` answers false: it is not a runtime of its own, it is a decision
    /// taken once per mount between the two that are. `AutoDecision` is what
    /// resolves it, and what it resolves to is `server` or `client`.
    pub fn in_browser() -> bool {
        return match self {
            inherit => false
            plain => false
            server => false
            client => true
            auto => false
        }
    }

    pub fn equals(other: RenderMode) -> bool { return self.name() == other.name() }
}

/// The four words, for a refusal that has to list them.
pub fn render_mode_words() -> string { return "static, server, client or auto" }

// ---------------------------------------------------------------- one type

/// What one component type declared, worked out once.
pub class ModePlan {
    pub type_name: string = ""
    pub mode: RenderMode = RenderMode.inherit
    pub prerender: bool = true
    /// Why this declaration cannot be honoured. A plan with a fault is never
    /// applied — `ModeScan.mode_of` answers `inherit` for it — so a refused
    /// declaration cannot half-work.
    pub faults: List<string> = []
    pub fn init() {}

    pub fn usable() -> bool { return self.faults.len() == 0 }
}

/// Every `@render_mode` in the executable, and everything wrong with them.
///
/// Built once at startup, by name, before a socket exists — the same contract
/// as `scan_pages`, `scan_memo` and `scan_persist`. A mode that only failed
/// when a user reached the page is a mode nobody would find.
pub class ModeScan {
    /// The application-wide floor. Every region inherits from it.
    pub default_mode: RenderMode = RenderMode.server
    pub plans: Map<string, ModePlan> = {}
    pub faults: List<string> = []
    pub fn init() {}

    /// What `type_name` declared, or `inherit` when it declared nothing and
    /// when what it declared was refused.
    pub fn mode_of(type_name: string) -> RenderMode {
        match self.plans.get(type_name) {
            some(plan) => {
                if !plan.usable() { return RenderMode.inherit }
                return plan.mode
            }
            none => { return RenderMode.inherit }
        }
    }

    /// Whether `type_name` asked for its boundary to be prerendered. True for
    /// a type that declared nothing: prerendering is the default everywhere.
    pub fn prerender_of(type_name: string) -> bool {
        match self.plans.get(type_name) {
            some(plan) => {
                if !plan.usable() { return true }
                return plan.prerender
            }
            none => { return true }
        }
    }

    /// Every type that declared `client` or `auto`, in name order.
    ///
    /// This is the browser bundle's contents: what a client build has to be
    /// able to construct, and what `latte check --client` reports.
    pub fn browser_types() -> List<string> {
        var out: List<string> = []
        for name: string in self.plans.keys() {
            match self.plans.get(name) {
                some(plan) => {
                    if !plan.usable() { continue }
                    if plan.mode.equals(RenderMode.client) ||
                       plan.mode.equals(RenderMode.auto) {
                        out.push(name)
                    }
                }
                none => {}
            }
        }
        out.sort()
        return move out
    }

    pub fn report() -> string {
        var out: List<string> = []
        out.push("default {self.default_mode.name()}")
        var names: List<string> = self.plans.keys()
        names.sort()
        for name: string in names {
            match self.plans.get(name) {
                some(plan) => {
                    if plan.usable() {
                        out.push("{name} {plan.mode.name()} prerender={plan.prerender}")
                    } else {
                        out.push("{name} REFUSED")
                    }
                }
                none => {}
            }
        }
        for fault: string in self.faults { out.push("fault: {fault}") }
        return out.join("\n")
    }
}

/// Read every `@render_mode` in the executable.
///
/// `default_mode` is the application's floor. `server` is what every latte
/// application did before modes existed, so it is what a host that names
/// nothing gets, and an existing application renders unchanged: every
/// component inherits, no component's mode differs from its parent's, and no
/// boundary is ever made.
pub fn scan_render_modes(default_mode: RenderMode) -> ModeScan {
    var scan: ModeScan = new ModeScan()
    scan.default_mode = default_mode
    if default_mode.equals(RenderMode.inherit) {
        scan.faults.push(
            "the application's default render mode is \"inherit\", which names nothing to inherit from; it must be one of {render_mode_words()}")
        scan.default_mode = RenderMode.server
    }
    let component_name: string = type_of(Component).qualified_name()
    let layout_name: string = type_of(Layout).qualified_name()
    for described: reflect.Type in reflect.types() {
        let uses: List<reflect.Annotation> =
            annotations_named(described.annotations(), "render_mode")
        if uses.len() == 0 { continue }
        var plan: ModePlan = new ModePlan()
        plan.type_name = described.qualified_name()
        // No "carries @render_mode more than once" guard here, unlike
        // `scan_pages`: the annotation is not @repeatable, so a second one is
        // a compile error in the author's own file and the refusal would be a
        // site no program can reach.
        let word: string = argument_string(uses[0], "value")
        let asked: Option<RenderMode> = RenderMode.of(word)
        match asked {
            none => {
                plan.faults.push(
                    "{plan.type_name} is annotated @render_mode(value: \"{word}\"), which is not a mode; it must be one of {render_mode_words()}")
            }
            some(mode) => {
                plan.mode = mode
                if mode.equals(RenderMode.inherit) {
                    plan.faults.push(
                        "{plan.type_name} is annotated @render_mode(value: \"inherit\"), which is the absence of a declaration; delete the annotation to inherit")
                }
            }
        }
        plan.prerender = argument_bool_or(uses[0], "prerender", true)
        if !plan.prerender && !plan.mode.in_browser() &&
           !plan.mode.equals(RenderMode.auto) {
            plan.faults.push(
                "{plan.type_name} is annotated @render_mode(value: \"{plan.mode.name()}\", prerender: false); a {plan.mode.name()} region IS server-rendered HTML, so there is nothing to switch off")
        }
        // An `auto` region is a client region on some visits, so everything
        // that has to cross for a client one has to cross for it too. It is
        // checked HERE because the alternative is a page that works until
        // the day a browser arrives with the bundle already cached.
        if plan.mode.equals(RenderMode.auto) &&
           extends_named(described, component_name) {
            let props: PropsPlan = props_plan_for(described)
            for fault: string in props.faults {
                plan.faults.push(
                    "{plan.type_name} is annotated @render_mode(value: \"auto\"), so it must be able to run in the browser: {fault}")
            }
        }
        if !extends_named(described, component_name) {
            plan.faults.push(
                "{plan.type_name} is annotated @render_mode but does not extend {component_name}, so it renders nothing that could run anywhere")
        } else if extends_named(described, layout_name) &&
                  !plan.mode.equals(RenderMode.server) {
            // A layout wraps a page, so a non-server layout would make the
            // page it wraps a region inside another runtime's region. That is
            // the nested case, and it is refused until it is implemented.
            plan.faults.push(
                "{plan.type_name} is a latte.Layout annotated @render_mode(value: \"{plan.mode.name()}\"); a layout wraps a page, so this would put the page inside another runtime's region — a nesting latte does not have. Put the mode on the components inside the page")
        }
        for fault: string in plan.faults { scan.faults.push(fault) }
        scan.plans[plan.type_name] = plan
    }
    return move scan
}

// ---------------------------------------------------------------- choosing

/// Where a resolved mode came from. The inspector prints it, and a refusal
/// that says "server, because the application default is server" is a
/// different bug report from one that says "server, because Shell says so".
pub enum ModeSource {
    application
    declaration
    instance
    block

    pub fn name() -> string {
        return match self {
            application => "application default"
            declaration => "@render_mode"
            instance => "render:mode"
            block => "RenderBlock"
        }
    }
}

/// One resolved answer: the mode, and why.
pub class ResolvedMode {
    pub mode: RenderMode = RenderMode.server
    pub source: ModeSource = ModeSource.application
    pub prerender: bool = true
    pub fn init(mode: RenderMode, source: ModeSource, prerender: bool) {
        self.mode = mode
        self.source = source
        self.prerender = prerender
    }
}

/// The precedence rule, in one place because it is the thing everything else
/// has to agree about.
///
/// Highest wins:
///
///   1. `<RenderBlock mode="...">` — an explicit boundary around a block.
///   2. `render:mode="..."` — an override on one component instance.
///   3. `@render_mode` on the component's own type.
///   4. The enclosing region's resolved mode — inheritance.
///
/// `inherited` is (4) and is never `inherit` itself: the application default
/// is the floor, written into the root region before anything renders.
pub fn resolve_render_mode(inherited: RenderMode, declared: RenderMode,
                           instance: RenderMode, block: RenderMode,
                           declared_prerender: bool) -> ResolvedMode {
    if !block.equals(RenderMode.inherit) {
        return new ResolvedMode(block, ModeSource.block, declared_prerender)
    }
    if !instance.equals(RenderMode.inherit) {
        return new ResolvedMode(instance, ModeSource.instance, declared_prerender)
    }
    if !declared.equals(RenderMode.inherit) {
        return new ResolvedMode(declared, ModeSource.declaration, declared_prerender)
    }
    // An inherited mode is not a declaration, so it cannot carry a prerender
    // answer of its own: the region it inherits from already made that choice.
    return new ResolvedMode(inherited, ModeSource.application, true)
}

/// Whether a region in `child` inside a region in `parent` is a boundary.
///
/// Equality is the whole rule, and it is what keeps an application that
/// declares nothing byte-identical: everything inherits, nothing differs,
/// no boundary is made.
pub fn is_execution_boundary(parent: RenderMode, child: RenderMode) -> bool {
    return !parent.equals(child)
}

/// An annotation argument that may be absent, with the default written once.
///
/// `argument_bool` answers false for a missing argument, which is the wrong
/// answer for a flag whose default is true — it would read every undeclared
/// `@render_mode` as `prerender: false`.
fn argument_bool_or(use: reflect.Annotation, name: string, fallback: bool) -> bool {
    match use.argument(name) {
        some(argument) => {
            match argument.value().as_bool() {
                some(value) => { return value }
                none => { return fallback }
            }
        }
        none => { return fallback }
    }
}
