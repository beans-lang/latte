// An execution boundary: the one element a region of another runtime is,
// seen from the renderer that does not own it.
//
// A boundary exists only where a resolved mode DIFFERS from the mode of the
// region around it (`modes.b`). What it renders is a single element carrying
// a descriptor — which component, in which mode, with which props — and,
// when the region is prerendered, that component's HTML inside it.
//
// The element is `opaque`: the differ walks its attributes and never its
// children. That is what makes "a parent must not overwrite a differently
// owned child region" a property of the frame list rather than a rule
// somebody has to keep remembering. Props still cross, because props ARE the
// attributes.
//
// Nothing here imports std.io, std.fs or std.net. See beans.pot.
package latte

import std.fmt
import std.reflect

/// The element every boundary renders as.
///
/// A custom element and not a `<div>`: it must not inherit a stylesheet rule
/// written for a div, and a reader looking at the page source has to be able
/// to see where one runtime stops and the next begins.
pub const BOUNDARY_TAG: string = "latte-boundary"

pub const BOUNDARY_ID_ATTRIBUTE: string = "data-latte-boundary"
pub const BOUNDARY_MODE_ATTRIBUTE: string = "data-latte-mode"
pub const BOUNDARY_TYPE_ATTRIBUTE: string = "data-latte-component"
pub const BOUNDARY_PROPS_ATTRIBUTE: string = "data-latte-props"
/// Whether the content inside the element is a server prerender the browser
/// runtime should adopt, rather than an empty region it should fill.
pub const BOUNDARY_PRERENDER_ATTRIBUTE: string = "data-latte-prerendered"

// ---------------------------------------------------------------- props

/// What crosses a boundary for one component type, worked out once.
///
/// Only `@param` fields cross, and only the four scalars. A parent's `self`,
/// a service, a `Callback` and a child's own handle are all things that exist
/// in one runtime and have no meaning in the other, so there is no encoding
/// for them and there is no "best effort" either: the boundary refuses, with
/// the field named.
pub class PropsPlan {
    pub type_name: string = ""
    pub fields: List<reflect.Field> = []
    pub kinds: List<ParamKind> = []
    pub names: List<string> = []
    /// Why this type cannot cross a boundary. A plan with a fault still lists
    /// the fields that DO cross, so the refusal can name every bad one at once
    /// instead of one per render.
    pub faults: List<string> = []
    pub fn init() {}

    pub fn usable() -> bool { return self.faults.len() == 0 }
}

/// Read one component type's crossable parameters.
pub fn props_plan_for(described: reflect.Type) -> PropsPlan {
    var plan: PropsPlan = new PropsPlan()
    plan.type_name = described.qualified_name()
    var seen: Map<string, bool> = {}
    for field: reflect.Field in described.fields() {
        if annotations_named(field.annotations(), "param").len() == 0 { continue }
        var wire: string = argument_string(
            annotations_named(field.annotations(), "param")[0], "name")
        if wire == "" { wire = field.name() }
        if seen.contains_key(wire) {
            plan.faults.push(
                "{plan.type_name}.{field.name()}: two @param fields both cross as \"{wire}\"")
            continue
        }
        seen[wire] = true
        if !field.is_public() {
            plan.faults.push(
                "{plan.type_name}.{field.name()} is a @param but is not public, and reflection does not bypass visibility, so nothing would cross")
            continue
        }
        let kind: ParamKind = props_kind_of(field.type())
        match kind {
            other => {
                plan.faults.push(
                    "{plan.type_name}.{field.name()} is a @param of type {field.type().qualified_name()}, which cannot cross an execution boundary; a prop is a string, an int, a bool or a float. A callback across a boundary is a server action, not a closure")
                continue
            }
            _ => {}
        }
        plan.fields.push(field)
        plan.kinds.push(kind)
        plan.names.push(wire)
    }
    return move plan
}

/// Which of the four scalars a type is, or `other`.
///
/// The one table that says what crosses a boundary. Props read it, a server
/// action's arguments read it, and a reply reads it, so "a prop is a string,
/// an int, a bool or a float" is one rule and not three.
pub fn props_kind_of(described: reflect.Type) -> ParamKind {
    let name: string = described.qualified_name()
    if name == "string" { return ParamKind.text }
    if name == "int" { return ParamKind.integer }
    if name == "bool" { return ParamKind.boolean }
    if name == "float" { return ParamKind.number }
    return ParamKind.other
}

/// One instance's props as a JSON object, keys in declaration order.
///
/// Declaration order and not sorted: it is the order an author reads the
/// fields in, it is stable across renders, and a props string that reorders
/// itself would look like a change to the differ on every render.
pub fn encode_props(receiver: reflect.Value, plan: PropsPlan,
                    faults: List<string>) -> string {
    var out: fmt.StringBuilder = new fmt.StringBuilder()
    out.push("\{")
    var index: int = 0
    for index < plan.fields.len() {
        if index > 0 { out.push(",") }
        write_json_string(out, plan.names[index])
        out.push(":")
        match plan.fields[index].get(receiver.copy()) {
            err(problem) => {
                faults.push(
                    "{plan.type_name}.{plan.names[index]}: {problem.message()}")
                out.push("null")
            }
            ok(value) => { write_prop(out, value, plan.kinds[index]) }
        }
        index += 1
    }
    out.push("\}")
    return out.to_string()
}

fn write_prop(out: fmt.StringBuilder, value: reflect.Value, kind: ParamKind) {
    match kind {
        text => {
            match value as? string {
                some(held) => { write_json_string(out, held) }
                none => { out.push("null") }
            }
        }
        integer => {
            match value as? int {
                some(held) => { out.push("{held}") }
                none => { out.push("null") }
            }
        }
        boolean => {
            match value as? bool {
                some(held) => { if held { out.push("true") } else { out.push("false") } }
                none => { out.push("null") }
            }
        }
        number => {
            match value as? float {
                some(held) => { out.push("{held}") }
                none => { out.push("null") }
            }
        }
        other => { out.push("null") }
    }
}

/// Write a props object onto an instance. What comes back is what could not
/// be written — every value in it came from the other side of a boundary.
///
/// A prop the object does not carry is LEFT ALONE, at the field's own
/// default. That is what makes adding a parameter a compatible change: an
/// older props string still mounts.
pub fn decode_props(receiver: reflect.Value, plan: PropsPlan,
                    props: Json) -> List<string> {
    var problems: List<string> = []
    var index: int = 0
    for index < plan.fields.len() {
        let name: string = plan.names[index]
        match props.field(name) {
            none => { index += 1; continue }
            some(value) => {
                let written: string =
                    write_field(receiver.copy(), plan.fields[index],
                                plan.kinds[index], name, value)
                if written != "" { problems.push(written) }
            }
        }
        index += 1
    }
    return move problems
}

fn write_field(receiver: reflect.Value, field: reflect.Field, kind: ParamKind,
               name: string, value: Json) -> string {
    match kind {
        text => {
            if !value.is_text() { return "prop \"{name}\" is not a string" }
            return props_report(field.set(receiver, reflect.value(value.text)), name)
        }
        integer => {
            if !value.is_int() { return "prop \"{name}\" is not an int" }
            return props_report(field.set(receiver, reflect.value(value.number)), name)
        }
        boolean => {
            if !value.is_bool() { return "prop \"{name}\" is not a bool" }
            return props_report(field.set(receiver, reflect.value(value.truth)), name)
        }
        number => {
            // An int is a legal float on the wire: JSON has one number type
            // and `3` is what a whole 3.0 is written as.
            if !value.is_number() { return "prop \"{name}\" is not a float" }
            return props_report(field.set(receiver, reflect.value(value.as_float())), name)
        }
        other => { return "prop \"{name}\" has no type that crosses" }
    }
}

fn props_report(outcome: Result<bool, reflect.ReflectError>, name: string) -> string {
    match outcome {
        ok(_) => { return "" }
        err(problem) => { return "setting prop \"{name}\": {problem.message()}" }
    }
}

// ---------------------------------------------------------------- the region

/// One execution boundary, as the renderer that does not own it sees it.
///
/// It is a `Component` and not a special case in the Builder because a
/// boundary needs exactly what a component already has: a slot id that is
/// stable across renders, a place to keep what it worked out last time, and a
/// lifecycle the sweep already drives.
pub class RenderRegion extends Component {
    /// Stable for the life of this mount: the enclosing region's path and
    /// this component's slot. Two renderers never share a Registry, so the
    /// path is what keeps two nested regions' slot numbers apart.
    pub region_id: string = ""
    /// Who owns what is inside. Never `inherit`.
    pub mode: RenderMode = RenderMode.server
    /// The mode of the region AROUND this one — whose renderer is writing
    /// these frames. `opaque` is set exactly when the two differ in who runs
    /// the code, which is what "not mine to touch" means.
    pub host_mode: RenderMode = RenderMode.server
    pub type_name: string = ""
    pub prerender: bool = true
    pub source: ModeSource = ModeSource.declaration
    /// What `auto` resolved to for the render that made this region, carried
    /// down so a nested `auto` answers the same way.
    pub auto_mode: RenderMode = RenderMode.server

    /// Build one instance of the component this region holds.
    pub make: fn() -> Result<reflect.Value, string> =
        fn() -> Result<reflect.Value, string> { return err("this region has no factory") }
    /// Write the parent's parameters onto one.
    pub apply: fn(reflect.Value) = fn(value: reflect.Value) {}

    /// Everything this region has refused. It is read by `Builder.all_faults`
    /// through the frames the region writes, so a refusal here reaches the
    /// same check every other latte refusal does.
    pub problems: List<string> = []

    props: string = "\{\}"
    /// The HTML the server rendered inside the boundary, or "".
    body: string = ""
    /// Whether `body` has been produced. A client region prerenders ONCE: the
    /// browser owns that DOM afterwards, so producing it again would describe
    /// a tree nobody has.
    prerendered: bool = false
    plan: Option<PropsPlan> = none

    pub fn init() {}

    pub fn props_text() -> string { return self.props }
    pub fn body_html() -> string { return self.body }

    pub override fn render(b: Builder) {
        self.refresh()
        b.open(0, BOUNDARY_TAG)
        b.attr(1, BOUNDARY_ID_ATTRIBUTE, self.region_id)
        b.attr(2, BOUNDARY_MODE_ATTRIBUTE, self.mode.name())
        b.attr(3, BOUNDARY_TYPE_ATTRIBUTE, self.type_name)
        b.attr(4, BOUNDARY_PROPS_ATTRIBUTE, self.props)
        if self.body != "" { b.flag(5, BOUNDARY_PRERENDER_ATTRIBUTE, true) }
        // The children belong to the other runtime exactly when the other
        // runtime is a different PROCESS. A static region has no instance
        // anywhere, so the renderer that wrote it still owns its DOM and its
        // markup must keep diffing.
        if self.foreign() { b.opaque(6) }
        if self.body != "" { b.raw(7, self.body) }
        b.close()
        for problem: string in self.problems { b.faults.push(problem) }
    }

    /// Whether what is inside runs somewhere this renderer is not.
    ///
    /// A `static` region has no runtime at all — whoever rendered it owns
    /// its DOM — so it is never foreign, wherever it sits. Only an
    /// INTERACTIVE region on the other side of the process boundary is, and
    /// that is what decides whether the element is `opaque` and whether its
    /// body is ever rendered twice.
    pub fn foreign() -> bool {
        if !self.mode.interactive() { return false }
        return self.mode.in_browser() != self.host_mode.in_browser()
    }

    /// Rebuild the props, and the body when the mode says to.
    fn refresh() {
        self.problems.clear()
        var made: Option<reflect.Value> = none
        match self.make() {
            err(problem) => {
                self.problems.push("{self.type_name}: {problem}")
                return
            }
            ok(value) => { made = some(value) }
        }
        match made {
            none => { return }
            some(instance) => {
                self.apply(instance.copy())
                let plan: PropsPlan = self.props_plan(instance.type())
                for fault: string in plan.faults { self.problems.push(fault) }
                var faults: List<string> = []
                let fresh: string = encode_props(instance.copy(), plan, faults)
                for fault: string in faults { self.problems.push(fault) }
                let changed: bool = fresh != self.props
                self.props = fresh
                self.rebuild_body(instance.copy(), changed)
            }
        }
    }

    fn props_plan(described: reflect.Type) -> PropsPlan {
        match self.plan {
            some(held) => { return held }
            none => {
                let made: PropsPlan = props_plan_for(described)
                self.plan = some(made)
                return made
            }
        }
    }

    /// The server-rendered HTML inside the boundary.
    ///
    /// Two rules, and they are different rules for different reasons:
    ///
    ///  * A **foreign** region prerenders once and never again. After the
    ///    browser runtime has taken the element over, the server's idea of
    ///    what is in there is history, and rendering it a second time would
    ///    write a description of a tree that does not exist.
    ///  * A **static** region has no instance anywhere, so its HTML is a pure
    ///    function of its props: it is re-rendered exactly when they change.
    fn rebuild_body(instance: reflect.Value, props_changed: bool) {
        if self.foreign() {
            if self.prerendered || !self.prerender { return }
            self.prerendered = true
            self.body = self.render_once(instance)
            return
        }
        if self.mode.interactive() { return }
        if self.prerendered && !props_changed { return }
        self.prerendered = true
        self.body = self.render_once(instance)
    }

    /// Render one component to HTML with a renderer of its own.
    ///
    /// A renderer of its own is the point: the instance, its registry, its
    /// handler table and its dirty set all die with this call, which is what
    /// "no live interactive instance" means for a static region and what
    /// "the server does not own this" means for a client one.
    fn render_once(instance: reflect.Value) -> string {
        match instance.copy() as? Component {
            none => {
                self.problems.push("{self.type_name} is not a Component")
                return ""
            }
            some(component) => {
                let inner: Renderer = new Renderer()
                match self.mount.page {
                    some(registry) => {
                        inner.services = registry.services
                        inner.modes = registry.modes
                    }
                    none => {}
                }
                inner.owner_mode = self.mode
                inner.inherited_mode = self.mode
                inner.auto_mode = self.auto_mode
                inner.region_path = "{self.region_id}."
                inner.mount(component)
                for fault: string in inner.all_faults() {
                    self.problems.push("{self.region_id}: {fault}")
                }
                if !self.mode.interactive() {
                    for name: string in inner.bound_events() {
                        self.problems.push(
                            "{self.type_name} is rendered static and binds on:{name}; a static region has no instance, so the handler can never run")
                    }
                }
                return inner.html()
            }
        }
    }
}

/// Activate one component type reflectively, for a boundary that has to build
/// an instance it was handed only the descriptor of.
pub fn activate_type(described: reflect.Type) -> Result<reflect.Value, string> {
    match described.initializer() {
        some(ctor) => {
            match ctor.call([]) {
                ok(made) => { return ok(made) }
                err(problem) => {
                    return err("cannot activate {described.name()}: {problem.message()}")
                }
            }
        }
        none => { return err("{described.name()} has no zero-argument initializer") }
    }
}
