// `pages.b` — the page half: what a `@page` is, and what happens to it at
// startup.
//
// A latte application declares its pages as annotated classes and never
// registers anything. At startup the scan walks `reflect.types()` once, turns
// every `@page` into a **plan** — a parsed route, a cached initializer, a
// typed setter per `@param`, a resolved layout chain, an authorization
// requirement — and refuses, loudly and by name, anything it cannot serve. A
// request is then a match against the plans and a direct call; no reflection
// runs per event, and none runs per render.
//
// Everything a startup refusal protects is a thing that would otherwise fail
// at request time, in a message about the framework rather than the program.
// The one that matters most is BLOCKERS.md **B1a**: a reflective write to a
// field whose *declaring type* is generic is `ok` under `beansc run` and
// `unsupported` as a native binary. A page bound that way works all through
// the edit loop and breaks when it ships. The scan refuses exactly that field
// — see `generic_declaration`, and read its comment before touching it, because
// the obvious test for it is a question that always answers no.
//
// Nothing here imports std.io, std.fs, std.net, std.time, std.random or
// std.crypto — `test.sh --wasm` builds the root package for
// wasm32-unknown-unknown and a single OS-bound import at the module root kills
// that leg for everybody. std.crypto counts: it CHECKS for the freestanding
// target and fails at codegen with "the networking bridges need --runtime
// full", so the HMAC an antiforgery token needs is behind the `Signer`
// interface in `forms.b` and is supplied by the host.
package latte

import std.fmt
import std.reflect

// ============================================================== annotations
//
// All four are `@retention(value: "runtime")`, because a scan that cannot see
// them at runtime is not a scan. All four are `@target`ed, so `@page` on a
// function is a compile error in the author's own file rather than a type the
// scan silently never finds.

/// A routable page. `route` is a raw string literal so a placeholder needs no
/// escaping: `@page(route: r"/counter/{start}")`.
@target(value: ["type"])
@retention(value: "runtime")
pub annotation page {
    route: string
    methods: List<string> = ["GET"]
}

/// The layout that wraps this page — or this layout, since layouts nest.
///
/// `name` names a **type**, not a registration: either its qualified name
/// (`app.layouts.Main`) or its simple name (`Main`) when exactly one type in
/// the executable carries it. Two types with the same simple name is a startup
/// refusal naming both, not a silent pick. There is no layout registry and
/// none is needed, which is the same rule PLAN.md states for component tags.
@target(value: ["type"])
@retention(value: "runtime")
pub annotation layout {
    name: string
}

/// An authorization requirement. Repeatable: several requirements on one page
/// must ALL hold, and the roles inside one requirement are alternatives. That
/// is the rule Blazor and ASP.NET use, and a framework that inverted it would
/// widen access on a page that reads as if it narrowed it.
@target(value: ["type"])
@retention(value: "runtime")
@repeatable
pub annotation authorize {
    policy: string = ""
    roles: List<string> = []
}

/// A parameter: a field a parent — or a route — supplies.
///
/// `name` is the wire name; empty means the field's own name. `required` means
/// the route must carry it, and is checked at **startup**: a required parameter
/// with no matching `{name}` in the route is a page that can never be served,
/// so it is refused with the component named rather than 404ing at request
/// time.
@target(value: ["field"])
@retention(value: "runtime")
pub annotation param {
    name: string = ""
    required: bool = false
}

// ============================================================== the layout
//
/// A layout is a component with a body.
///
/// Its markup places the page with `$slot`, which compiles to
/// `b.fragment(seq, self.body)`. Latte fills `body` in; an author never
/// assigns it.
pub class Layout extends Component {
    pub body: fn(Builder) = fn(b: Builder) {}
    pub fn init() {}
}

// ============================================================== ParamWatch
//
/// The parameter snapshot a component compares in `should_render`.
///
/// This exists because getting it right by hand has one trap and everybody
/// falls in it once: **the snapshot belongs in `on_params_set`, never in
/// `should_render`.** `should_render` is consulted only from the *second*
/// render onward, so a component that snapshots there never records the first
/// render's parameters and answers "changed" for ever after — which is a
/// component that re-renders on every parent pass while every test still
/// passes, because re-rendering too much is invisible to a golden file.
/// `tests/renders.b` measures it and `tests/components.b` § 2 proves the
/// helper's own answer across the first render, where the hand-written mistake
/// would show.
///
/// ```beans
/// pub override fn on_params_set() { self.watch.record(["{self.label}", "{self.n}"]) }
/// pub override fn should_render() -> bool { return self.watch.differs() }
/// ```
pub class ParamWatch {
    /// What the last `record` was given. Empty before the first one, which is
    /// not the same as "recorded an empty list" — hence `first`.
    seen: List<string> = []
    first: bool = true
    changed: bool = true
    pub fn init() {}

    /// Call from `on_params_set`, every render, with this render's parameters.
    pub fn record(values: List<string>) {
        if self.first {
            self.first = false
            self.changed = true
            self.seen = values.clone()
            return
        }
        self.changed = !same_strings(self.seen, values)
        self.seen = values.clone()
    }

    /// Whether the last `record` differed from the one before it. True before
    /// any render, because a component that has never rendered must.
    pub fn differs() -> bool { return self.changed }

    /// Whether `record` has ever run. A component whose `should_render` is
    /// consulted while this is true has a `ParamWatch` it forgot to feed, and
    /// `tests/components.b` asserts the difference.
    pub fn empty() -> bool { return self.first }
}

fn same_strings(left: List<string>, right: List<string>) -> bool {
    if left.len() != right.len() { return false }
    var index: int = 0
    for index < left.len() {
        if left[index] != right[index] { return false }
        index += 1
    }
    return true
}

// ============================================================== routes
//
// A route is a sequence of segments. A segment is a literal or a single
// placeholder, and a placeholder is a WHOLE segment: `/orders/{id}` is a route
// and `/orders/o{id}` is refused. That keeps matching to one string compare per
// segment and keeps a captured value unambiguous, and nothing in the plan needs
// the other form. A catch-all (`{*rest}`) is refused for the same reason and
// would need a different capture type — the rest of the path, not a segment —
// to be added.

pub class RouteSegment {
    /// The literal text, for a literal segment.
    pub text: string = ""
    /// The placeholder name, for a parameter segment.
    pub name: string = ""
    pub is_parameter: bool = false
    pub fn init() {}
}

pub class RoutePattern {
    pub source: string = ""
    pub segments: List<RouteSegment> = []
    /// Why this pattern cannot be used. Empty means it can.
    pub faults: List<string> = []

    pub fn init(source: string) {
        self.source = source
        self.parse()
    }

    fn parse() {
        if !self.source.starts_with("/") {
            self.faults.push("a route must start with \"/\"; this one is \"{self.source}\"")
            return
        }
        var seen: Map<string, bool> = {}
        let pieces: List<string> = self.source.split("/")
        var index: int = 1                      // piece 0 is the empty text before the first "/"
        for index < pieces.len() {
            let piece: string = pieces[index]
            index += 1
            // A trailing slash is not a segment: "/orders/" and "/orders" name
            // the same page, and `match` normalises the request the same way.
            if piece == "" {
                if index <= pieces.len() - 1 {
                    self.faults.push("route \"{self.source}\" has an empty segment")
                }
                continue
            }
            if piece.contains("{") || piece.contains("}") {
                if !piece.starts_with("{") || !piece.ends_with("}") {
                    self.faults.push(
                        "route \"{self.source}\": a placeholder is a whole segment, so \"{piece}\" is not one")
                    continue
                }
                let name: string = piece.slice(1, piece.len() - 1)
                if name.contains("{") || name.contains("}") {
                    self.faults.push("route \"{self.source}\": \"{piece}\" nests braces")
                    continue
                }
                if name == "" {
                    self.faults.push("route \"{self.source}\" has an unnamed placeholder")
                    continue
                }
                if name.starts_with("*") {
                    self.faults.push(
                        "route \"{self.source}\": a catch-all placeholder (\"{piece}\") is not supported — " +
                        "a placeholder captures one segment")
                    continue
                }
                if !is_identifier(name) {
                    self.faults.push(
                        "route \"{self.source}\": \"{name}\" is not a parameter name")
                    continue
                }
                if seen.contains_key(name) {
                    self.faults.push("route \"{self.source}\" names \"{name}\" twice")
                    continue
                }
                seen[name] = true
                var segment: RouteSegment = new RouteSegment()
                segment.name = name
                segment.is_parameter = true
                self.segments.push(segment)
            } else {
                var literal: RouteSegment = new RouteSegment()
                literal.text = piece
                self.segments.push(literal)
            }
        }
    }

    pub fn ok() -> bool { return self.faults.len() == 0 }

    /// The placeholder names, in route order.
    pub fn names() -> List<string> {
        var out: List<string> = []
        for segment: RouteSegment in self.segments {
            if segment.is_parameter { out.push(segment.name) }
        }
        return move out
    }

    pub fn names_parameter(name: string) -> bool {
        for segment: RouteSegment in self.segments {
            if segment.is_parameter && segment.name == name { return true }
        }
        return false
    }

    /// The shape two routes share when one hides the other: literals stay,
    /// placeholders become `{}`. `/a/{x}` and `/a/{y}` have the same shape and
    /// are a startup refusal, because nothing at request time could choose.
    pub fn shape() -> string {
        var out: fmt.StringBuilder = new fmt.StringBuilder()
        for segment: RouteSegment in self.segments {
            out.push("/")
            if segment.is_parameter { out.push("{}") } else { out.push(segment.text) }
        }
        if self.segments.len() == 0 { out.push("/") }
        return out.to_string()
    }

    /// More literal segments wins, then more segments. A page at `/orders/new`
    /// must beat `/orders/{id}` however they were declared, because declaration
    /// order is not something an author reasons about across files.
    pub fn specificity() -> int {
        var score: int = 0
        for segment: RouteSegment in self.segments {
            if segment.is_parameter { score += 1 } else { score += 16 }
        }
        return score
    }

    /// Match a request path, and capture. `none` is "this is not that page".
    ///
    /// The path is split FIRST and each captured value percent-decoded after,
    /// never before: decoding first would let `%2F` invent a segment boundary
    /// and let one route match a path its author never wrote.
    pub fn matches(path: string) -> Option<Map<string, string>> {
        var actual: List<string> = []
        let pieces: List<string> = path.split("/")
        var index: int = 0
        for index < pieces.len() {
            let piece: string = pieces[index]
            index += 1
            if piece == "" { continue }
            actual.push(piece)
        }
        if actual.len() != self.segments.len() { return none }
        var values: Map<string, string> = {}
        var at: int = 0
        for at < self.segments.len() {
            let segment: RouteSegment = self.segments[at]
            let piece: string = actual[at]
            at += 1
            if segment.is_parameter {
                values[segment.name] = percent_decode(piece)
            } else if segment.text != piece {
                return none
            }
        }
        return some(move values)
    }

    /// The reverse: a link to this page. A value that is missing is a caller
    /// bug and is reported rather than written as an empty segment, which would
    /// silently produce a URL for a different page.
    pub fn link(values: Map<string, string>) -> Result<string, string> {
        var out: fmt.StringBuilder = new fmt.StringBuilder()
        for segment: RouteSegment in self.segments {
            out.push("/")
            if segment.is_parameter {
                match values.get(segment.name) {
                    some(text) => { out.push(percent_encode(text)) }
                    none => {
                        return err("route \"{self.source}\" needs \"{segment.name}\"")
                    }
                }
            } else {
                out.push(segment.text)
            }
        }
        if self.segments.len() == 0 { out.push("/") }
        return ok(out.to_string())
    }
}

fn is_identifier(name: string) -> bool {
    if name == "" { return false }
    var index: int = 0
    for index < name.len() {
        let byte: int = name.byte_at(index)
        let alpha: bool = (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
        let digit: bool = byte >= 48 && byte <= 57
        if index == 0 {
            if !alpha && byte != 95 { return false }
        } else if !alpha && !digit && byte != 95 {
            return false
        }
        index += 1
    }
    return true
}

fn hex_value(byte: int) -> int {
    if byte >= 48 && byte <= 57 { return byte - 48 }
    if byte >= 97 && byte <= 102 { return byte - 87 }
    if byte >= 65 && byte <= 70 { return byte - 55 }
    return -1
}

const HEX_DIGITS: string = "0123456789ABCDEF"

/// Percent-decoding for ONE path segment. A malformed escape is left as
/// written rather than dropped: `%zz` is three characters someone typed, and
/// inventing a byte for it is how a decoder becomes a filter bypass.
pub fn percent_decode(text: string) -> string {
    if !text.contains("%") && !text.contains("+") { return text }
    var out: fmt.StringBuilder = new fmt.StringBuilder()
    var index: int = 0
    for index < text.len() {
        let byte: int = text.byte_at(index)
        if byte == 37 && index + 2 < text.len() {
            let high: int = hex_value(text.byte_at(index + 1))
            let low: int = hex_value(text.byte_at(index + 2))
            if high >= 0 && low >= 0 {
                out.push(byte_text(high * 16 + low))
                index += 3
                continue
            }
        }
        out.push(text.slice(index, index + 1))
        index += 1
    }
    return out.to_string()
}

fn byte_text(value: int) -> string {
    // `\xNN` is one raw byte and a Beans string is binary-safe, so a decoded
    // byte goes back as itself. The table is spelled out because an escape
    // cannot be built from a runtime value.
    var out: fmt.StringBuilder = new fmt.StringBuilder()
    out.push_byte(value)
    return out.to_string()
}

/// Percent-encoding for one path segment: everything outside the unreserved
/// set is escaped, `/` included, so a value can never grow a segment.
pub fn percent_encode(text: string) -> string {
    var out: fmt.StringBuilder = new fmt.StringBuilder()
    var index: int = 0
    for index < text.len() {
        let byte: int = text.byte_at(index)
        index += 1
        let alpha: bool = (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
        let digit: bool = byte >= 48 && byte <= 57
        let safe: bool = byte == 45 || byte == 46 || byte == 95 || byte == 126
        if alpha || digit || safe {
            out.push(byte_text(byte))
        } else {
            out.push("%")
            out.push(HEX_DIGITS.slice(byte / 16, byte / 16 + 1))
            out.push(HEX_DIGITS.slice(byte % 16, byte % 16 + 1))
        }
    }
    return out.to_string()
}

// ============================================================== parameters

/// What latte can bind from a route. Anything else is a parent-to-child
/// parameter — a `fn(Builder)`, a `Callback<T>`, a `Map<string, string>` — and
/// is set by a compiled setter with no reflection in the path at all.
pub enum ParamKind {
    text
    integer
    boolean
    number
    /// Not bindable from a route. Legal as a `@param`; refused only if the
    /// route names it.
    other
}

fn kind_of(described: reflect.Type) -> ParamKind {
    let name: string = described.qualified_name()
    if name == "string" { return ParamKind.text }
    if name == "int" { return ParamKind.integer }
    if name == "bool" { return ParamKind.boolean }
    if name == "float" { return ParamKind.number }
    return ParamKind.other
}

pub fn describe_kind(kind: ParamKind) -> string {
    return match kind {
        text => "string",
        integer => "int",
        boolean => "bool",
        number => "float",
        other => "unbindable"
    }
}

/// One `@param`, resolved: the field descriptor, the wire name, and whether
/// this page's route carries it.
pub class ParamBinding {
    pub field_name: string = ""
    pub wire_name: string = ""
    pub required: bool = false
    pub from_route: bool = false
    pub kind: ParamKind = ParamKind.other
    pub type_name: string = ""
    field: Option<reflect.Field> = none
    pub fn init() {}

    fn adopt(field: reflect.Field) { self.field = some(field) }

    /// Write one value onto an instance. `""` is success; anything else is the
    /// message a 400 carries.
    ///
    /// This is the ONE place latte writes a field reflectively, which is why
    /// the scan refuses B1a's shape rather than discovering it here: at this
    /// point a refusal is a request that failed, and under `beansc run` it
    /// would not even fail.
    pub fn apply(receiver: reflect.Value, text: string) -> string {
        match self.field {
            none => { return "parameter \"{self.wire_name}\" has no field" }
            some(field) => {
                match self.kind {
                    text => { return report(field.set(receiver, reflect.value(text)), self.wire_name) }
                    integer => {
                        match parse_int(text) {
                            some(value) => {
                                return report(field.set(receiver, reflect.value(value)), self.wire_name)
                            }
                            none => { return "\"{text}\" is not an int for \"{self.wire_name}\"" }
                        }
                    }
                    boolean => {
                        match parse_bool(text) {
                            some(value) => {
                                return report(field.set(receiver, reflect.value(value)), self.wire_name)
                            }
                            none => { return "\"{text}\" is not a bool for \"{self.wire_name}\"" }
                        }
                    }
                    number => {
                        match text.to_float() {
                            ok(value) => {
                                return report(field.set(receiver, reflect.value(value)), self.wire_name)
                            }
                            err(_) => { return "\"{text}\" is not a float for \"{self.wire_name}\"" }
                        }
                    }
                    other => {
                        return "\"{self.wire_name}\" is a {self.type_name} and cannot be bound from a route"
                    }
                }
            }
        }
    }
}

fn report(outcome: Result<bool, reflect.ReflectError>, name: string) -> string {
    match outcome {
        ok(_) => { return "" }
        err(problem) => { return "setting \"{name}\": {problem.message()}" }
    }
}

/// `to_int` saturates at the i64 limits and stops at the first byte it does not
/// like, so `"12abc"` is 12 and `"99999999999999999999"` is the maximum. A
/// route value is a wire value, so both are refused here: the text must be a
/// whole integer and nothing else.
pub fn parse_int(text: string) -> Option<int> {
    if text == "" { return none }
    var index: int = 0
    if text.starts_with("-") || text.starts_with("+") { index = 1 }
    if index >= text.len() { return none }
    var digits: int = index
    for digits < text.len() {
        let byte: int = text.byte_at(digits)
        if byte < 48 || byte > 57 { return none }
        digits += 1
    }
    match text.to_int() {
        ok(value) => {
            // The saturating cases come back with a different spelling than
            // they went in with, which is the only signal `to_int` offers.
            if "{value}" != strip_plus(text) { return none }
            return some(value)
        }
        err(_) => { return none }
    }
}

fn strip_plus(text: string) -> string {
    if text.starts_with("+") { return text.slice(1, text.len()) }
    return text
}

pub fn parse_bool(text: string) -> Option<bool> {
    let lower: string = text.to_lower()
    if lower == "true" || lower == "1" || lower == "on" || lower == "yes" { return some(true) }
    if lower == "false" || lower == "0" || lower == "off" || lower == "no" { return some(false) }
    return none
}

// ============================================================== authorization

pub class AuthRequirement {
    pub policy: string = ""
    pub roles: List<string> = []
    pub fn init() {}
}

/// Who is asking. Latte ships no identity: an application supplies one, which
/// is PLAN.md D6 — "a framework whose security depends on a component it does
/// not provide is a framework with a hole in it" — applied to the caller side.
pub interface Principal {
    fn authenticated() -> bool
    fn has_role(role: string) -> bool
    fn satisfies(policy: string) -> bool
}

/// Nobody. The default, so a page with `@authorize` that is mounted with no
/// principal is challenged rather than allowed.
pub class Anonymous implements Principal {
    pub fn init() {}
    pub fn authenticated() -> bool { return false }
    pub fn has_role(role: string) -> bool { return false }
    pub fn satisfies(policy: string) -> bool { return false }
}

pub enum AuthOutcome {
    /// Render the page.
    allow
    /// Nobody is signed in: send them to sign in.
    challenge
    /// Somebody is signed in and is not allowed: 403, never a redirect loop.
    forbid
}

pub fn describe_outcome(outcome: AuthOutcome) -> string {
    return match outcome { allow => "allow", challenge => "challenge", forbid => "forbid" }
}

/// Several `@authorize` annotations must ALL hold; the roles inside one are
/// alternatives.
pub fn authorize_all(requirements: List<AuthRequirement>, who: Principal) -> AuthOutcome {
    if requirements.len() == 0 { return AuthOutcome.allow }
    if !who.authenticated() { return AuthOutcome.challenge }
    for requirement: AuthRequirement in requirements {
        if requirement.policy != "" && !who.satisfies(requirement.policy) {
            return AuthOutcome.forbid
        }
        if requirement.roles.len() > 0 {
            var any: bool = false
            for role: string in requirement.roles {
                if who.has_role(role) { any = true }
            }
            if !any { return AuthOutcome.forbid }
        }
    }
    return AuthOutcome.allow
}

// ============================================================== the plans

/// How an instance is made. The default is the cached zero-argument
/// initializer; a host with a DI container — espresso's `activate` — supplies
/// its own, which is the only way a page whose `init` takes services can be
/// activated at all.
pub interface Activator {
    fn make(described: reflect.Type) -> Result<reflect.Value, string>
}

/// The zero-argument route, with the initializer descriptor looked up once per
/// call. `PagePlan` caches its own and does not use this; it is here for a
/// caller holding a bare `reflect.Type`.
pub class PlainActivator implements Activator {
    pub fn init() {}
    pub fn make(described: reflect.Type) -> Result<reflect.Value, string> {
        match described.initializer() {
            some(ctor) => {
                match ctor.call([]) {
                    ok(made) => { return ok(move made) }
                    err(problem) => {
                        return err("cannot activate {described.name()}: {problem.message()}")
                    }
                }
            }
            none => { return err("{described.name()} has no zero-argument initializer") }
        }
    }
}

pub class PagePlan {
    pub type_name: string = ""
    pub name: string = ""
    pub route: RoutePattern = new RoutePattern("/")
    pub methods: List<string> = []
    /// The `@layout` name as written. Resolution happens once, at scan time.
    pub layout_name: string = ""
    /// The layout chain, outermost first. Empty when the page has no layout.
    pub layouts: List<reflect.Type> = []
    pub params: List<ParamBinding> = []
    pub requirements: List<AuthRequirement> = []
    described: Option<reflect.Type> = none
    /// Cached at scan time. W0 measured the lookup as about half of what a
    /// reflective activation costs, and a page activates once per request.
    ctor: Option<reflect.Initializer> = none
    pub fn init() {}

    pub fn describes() -> Option<reflect.Type> { return self.described }

    pub fn serves(method: string) -> bool {
        return self.methods.contains(method.to_upper())
    }

    /// Activate through the cached initializer.
    pub fn activate() -> Result<reflect.Value, string> {
        match self.ctor {
            some(ctor) => {
                match ctor.call([]) {
                    ok(made) => { return ok(move made) }
                    err(problem) => {
                        return err("cannot activate {self.name}: {problem.message()}")
                    }
                }
            }
            none => { return err("{self.name} has no zero-argument initializer") }
        }
    }

    /// Activate through a host's container.
    pub fn activate_with(activator: Activator) -> Result<reflect.Value, string> {
        match self.described {
            some(described) => { return activator.make(described) }
            none => { return err("{self.name} has no type descriptor") }
        }
    }

    /// Write the route's captures onto an instance. The returned list is empty
    /// when every value bound; otherwise it is what a 400 says.
    pub fn apply(receiver: reflect.Value, values: Map<string, string>) -> List<string> {
        var problems: List<string> = []
        for binding: ParamBinding in self.params {
            if !binding.from_route { continue }
            match values.get(binding.wire_name) {
                some(text) => {
                    let problem: string = binding.apply(receiver.copy(), text)
                    if problem != "" { problems.push(problem) }
                }
                none => {
                    if binding.required {
                        problems.push("\"{binding.wire_name}\" is required by {self.name}")
                    }
                }
            }
        }
        return move problems
    }

    pub fn authorize(who: Principal) -> AuthOutcome {
        return authorize_all(self.requirements, who)
    }
}

/// A request that found a page.
pub class PageMatch {
    pub plan: PagePlan = new PagePlan()
    pub values: Map<string, string> = {}
    pub fn init(plan: PagePlan, values: Map<string, string>) {
        self.plan = plan
        self.values = values
    }
}

// ============================================================== the scan

/// Every plan in the executable, and every reason one could not be made.
pub class PageMap {
    pub pages: List<PagePlan> = []
    /// Why the application must not start. A latte host calls `ok()` before it
    /// listens, and prints `report()` when it is false.
    pub faults: List<string> = []
    pub fn init() {}

    pub fn ok() -> bool { return self.faults.len() == 0 }

    pub fn report() -> string {
        var out: fmt.StringBuilder = new fmt.StringBuilder()
        for fault: string in self.faults {
            out.push("latte: ")
            out.push(fault)
            out.push("\n")
        }
        return out.to_string()
    }

    pub fn named(name: string) -> Option<PagePlan> {
        for plan: PagePlan in self.pages {
            if plan.name == name || plan.type_name == name { return some(plan) }
        }
        return none
    }

    /// The page a request lands on, most specific route first.
    ///
    /// A path that matches a route whose method does not serve the request is
    /// NOT a match: a `POST` to a `GET`-only page falls through, which is what
    /// lets two pages share a path and split the methods.
    pub fn find(method: string, path: string) -> Option<PageMatch> {
        var best: int = -1
        var best_score: int = -1
        var best_values: Map<string, string> = {}
        var index: int = 0
        for index < self.pages.len() {
            let plan: PagePlan = self.pages[index]
            if plan.serves(method) {
                match plan.route.matches(path) {
                    some(values) => {
                        let score: int = plan.route.specificity()
                        if score > best_score {
                            best = index
                            best_score = score
                            best_values = values
                        }
                    }
                    none => {}
                }
            }
            index += 1
        }
        if best < 0 { return none }
        return some(new PageMatch(self.pages[best], move best_values))
    }
}

/// Walk every type in the executable once and turn the annotated ones into
/// plans.
///
/// There is no registry and no registration call: `reflect.types()` is the
/// registry, in declaration order, and a page is a page because it says so.
pub fn scan_pages() -> PageMap {
    var map: PageMap = new PageMap()
    let component_name: string = type_of(Component).qualified_name()
    let layout_name: string = type_of(Layout).qualified_name()
    let all: List<reflect.Type> = reflect.types()

    var shapes: Map<string, string> = {}
    for described: reflect.Type in all {
        var uses: List<reflect.Annotation> = annotations_named(described.annotations(), "page")
        if uses.len() == 0 {
            // A `@layout` or `@authorize` on a type that is not a page is a
            // typo with no effect, and silence is how a security annotation
            // gets lost. A layout carrying `@layout` is the nesting case and
            // is fine.
            if annotations_named(described.annotations(), "authorize").len() > 0 {
                map.faults.push(
                    "{described.qualified_name()} is annotated @authorize but is not a @page; " +
                    "the requirement would never be checked")
            }
            if annotations_named(described.annotations(), "layout").len() > 0 &&
               !extends_named(described, layout_name) {
                map.faults.push(
                    "{described.qualified_name()} is annotated @layout but is neither a @page " +
                    "nor a latte.Layout, so nothing would ever wrap it")
            }
            continue
        }
        if uses.len() > 1 {
            map.faults.push("{described.qualified_name()} carries @page more than once")
            continue
        }
        var plan: PagePlan = plan_for(described, uses[0], component_name, map)
        match plan.describes() {
            none => { continue }
            some(_) => {}
        }
        resolve_layouts(plan, described, all, layout_name, map)
        let shape: string = plan.route.shape()
        for method: string in plan.methods {
            let key: string = "{method} {shape}"
            match shapes.get(key) {
                some(owner) => {
                    map.faults.push(
                        "{plan.type_name} and {owner} both answer {method} {shape}; " +
                        "nothing at request time could choose between them")
                }
                none => { shapes[key] = plan.type_name }
            }
        }
        map.pages.push(plan)
    }
    return move map
}

fn plan_for(described: reflect.Type, use: reflect.Annotation,
            component_name: string, map: PageMap) -> PagePlan {
    var plan: PagePlan = new PagePlan()
    plan.type_name = described.qualified_name()
    plan.name = described.name()

    if !extends_named(described, component_name) {
        map.faults.push(
            "{plan.type_name} is annotated @page but does not extend {component_name}, " +
            "so it has nothing to render")
        return move plan
    }

    let route_text: string = argument_string(use, "route")
    plan.route = new RoutePattern(route_text)
    for fault: string in plan.route.faults { map.faults.push("{plan.type_name}: {fault}") }

    plan.methods = upper_all(argument_strings(use, "methods"))
    if plan.methods.len() == 0 {
        map.faults.push("{plan.type_name}: @page(methods:) is empty")
    }
    for method: string in plan.methods {
        if !is_identifier(method) {
            map.faults.push("{plan.type_name}: \"{method}\" is not an HTTP method")
        }
    }

    for use2: reflect.Annotation in annotations_named(described.annotations(), "authorize") {
        var requirement: AuthRequirement = new AuthRequirement()
        requirement.policy = argument_string(use2, "policy")
        requirement.roles = argument_strings(use2, "roles")
        if requirement.policy == "" && requirement.roles.len() == 0 {
            // A bare `@authorize` is "signed in", which is Blazor's meaning and
            // is deliberate rather than an empty requirement.
            plan.requirements.push(requirement)
        } else {
            plan.requirements.push(requirement)
        }
    }

    let layouts: List<reflect.Annotation> = annotations_named(described.annotations(), "layout")
    if layouts.len() > 1 {
        map.faults.push("{plan.type_name} carries @layout more than once")
    } else if layouts.len() == 1 {
        plan.layout_name = argument_string(layouts[0], "name")
        if plan.layout_name == "" {
            map.faults.push("{plan.type_name}: @layout(name:) is empty")
        }
    }

    bind_params(plan, described, map)

    // Every placeholder must be a parameter. A route that captures into
    // nothing is a page that can never see half its own URL.
    for name: string in plan.route.names() {
        var bound: bool = false
        for binding: ParamBinding in plan.params {
            if binding.wire_name == name { bound = true }
        }
        if !bound {
            map.faults.push(
                "{plan.type_name}: route \"{plan.route.source}\" captures \"{name}\" but no " +
                "@param binds it")
        }
    }

    plan.ctor = described.initializer()
    plan.described = some(described)
    return move plan
}

fn bind_params(plan: PagePlan, described: reflect.Type, map: PageMap) {
    var seen: Map<string, string> = {}
    for field: reflect.Field in described.fields() {
        let uses: List<reflect.Annotation> = annotations_named(field.annotations(), "param")
        if uses.len() == 0 { continue }
        if uses.len() > 1 {
            map.faults.push("{plan.type_name}.{field.name()} carries @param more than once")
            continue
        }
        var binding: ParamBinding = new ParamBinding()
        binding.field_name = field.name()
        binding.wire_name = argument_string(uses[0], "name")
        if binding.wire_name == "" { binding.wire_name = field.name() }
        binding.required = argument_bool(uses[0], "required")
        binding.type_name = field.type().qualified_name()
        binding.kind = kind_of(field.type())
        binding.from_route = plan.route.names_parameter(binding.wire_name)
        binding.adopt(field)

        match seen.get(binding.wire_name) {
            some(other) => {
                map.faults.push(
                    "{plan.type_name}: \"{binding.wire_name}\" names both {other} and " +
                    "{binding.field_name}")
                continue
            }
            none => { seen[binding.wire_name] = binding.field_name }
        }

        if !field.is_public() {
            map.faults.push(
                "{plan.type_name}.{binding.field_name} is a @param but is not public, " +
                "and reflection does not bypass visibility")
            continue
        }

        // BLOCKERS.md B1a. Read `generic_declaration` before changing this.
        let generic: string = generic_declaration(described, field)
        if generic != "" {
            map.faults.push(
                "{plan.type_name}.{binding.field_name} is a @param declared by {generic}; " +
                "a reflective write to a field whose declaring type is generic is ok under " +
                "beansc run and unsupported natively (BLOCKERS.md B1a), so latte refuses it " +
                "here rather than at request time")
            continue
        }

        if binding.required && !binding.from_route {
            map.faults.push(
                "{plan.type_name}.{binding.field_name} is @param(required: true) but route " +
                "\"{plan.route.source}\" does not capture \"{binding.wire_name}\"")
            continue
        }
        if binding.from_route {
            match binding.kind {
                other => {
                    map.faults.push(
                        "{plan.type_name}.{binding.field_name} is captured by route " +
                        "\"{plan.route.source}\" but is a {binding.type_name}; a route can bind " +
                        "string, int, bool and float")
                    continue
                }
                _ => {}
            }
        }
        plan.params.push(binding)
    }
}

/// Whether `field` is declared by a GENERIC type in `owner`'s ancestry, and by
/// which one. `""` means it is not.
///
/// **The obvious test does not work, and writing it is how the divergence
/// ships.** `field.declaring_type().type_arguments().len() > 0` reads **0** for
/// exactly the fields that fail: a field's declaring type comes back as the
/// OPEN `…Grid`, never the closed `…Grid<int>` (BLOCKERS.md B1a, measured on
/// both backends by `probes/p10_factory_mount`).
///
/// What does work is the receiver's own base chain, which reports the closed
/// form:
///
///     Grid<int>: …Grid<int>(args=1) -> …Node(args=0)
///     OrderGrid: …OrderGrid(args=0) -> …Grid<int>(args=1) -> …Node(args=0)
///
/// so: walk the chain, strip each link's type arguments from its qualified
/// name, and find the link the field says declares it. If THAT link carries
/// type arguments, the field is generic-declared.
///
/// A field whose declaring type is not in the chain at all cannot happen for a
/// field that came out of `owner.fields()`; if it does, latte says so rather
/// than guessing, because guessing "accept" is the answer that ships the
/// divergence.
pub fn generic_declaration(owner: reflect.Type, field: reflect.Field) -> string {
    let declared: string = field.declaring_type().qualified_name()
    var walk: Option<reflect.Type> = some(owner)
    for true {
        match walk {
            some(link) => {
                if strip_type_arguments(link.qualified_name()) == declared {
                    if link.type_arguments().len() > 0 { return link.qualified_name() }
                    return ""
                }
                walk = link.base_type()
            }
            none => {
                return "{declared}, which is not in {owner.qualified_name()}'s base chain"
            }
        }
    }
    return ""
}

pub fn strip_type_arguments(name: string) -> string {
    match name.find("<") {
        some(at) => { return name.slice(0, at) }
        none => { return name }
    }
}

/// Whether `described` is, or descends from, the type with this qualified name.
///
/// It walks `base_type()` rather than asking `is_assignable_from`, because
/// `is_assignable_from` answers **false** for a base class and its subclass:
/// `type_of(Base).is_assignable_from(type_of(Derived))` is `false` on both
/// backends in 0.1.40, while `type_of(Derived).is_assignable_from(type_of(
/// Derived))` is true. A scan written on it would find no pages at all.
pub fn extends_named(described: reflect.Type, wanted: string) -> bool {
    var walk: Option<reflect.Type> = some(described)
    for true {
        match walk {
            some(link) => {
                if strip_type_arguments(link.qualified_name()) == wanted { return true }
                walk = link.base_type()
            }
            none => { return false }
        }
    }
    return false
}

// ---- layout resolution -----------------------------------------------------

fn resolve_layouts(plan: PagePlan, described: reflect.Type, all: List<reflect.Type>,
                   layout_name: string, map: PageMap) {
    var chain: List<reflect.Type> = []
    var seen: List<string> = []
    var wanted: string = plan.layout_name
    var owner: string = plan.type_name
    for wanted != "" {
        match find_layout(wanted, all, layout_name, owner, map) {
            none => { return }
            some(found) => {
                if seen.contains(found.qualified_name()) {
                    map.faults.push(
                        "{plan.type_name}: the layout chain loops at {found.qualified_name()}")
                    return
                }
                seen.push(found.qualified_name())
                chain.push(found)
                owner = found.qualified_name()
                let nested: List<reflect.Annotation> =
                    annotations_named(found.annotations(), "layout")
                if nested.len() > 1 {
                    map.faults.push("{owner} carries @layout more than once")
                    return
                }
                if nested.len() == 1 { wanted = argument_string(nested[0], "name") }
                else { wanted = "" }
            }
        }
    }
    // The chain was built innermost-first; a render wraps outermost-first.
    chain.reverse()
    plan.layouts = move chain
}

fn find_layout(wanted: string, all: List<reflect.Type>, layout_name: string,
               owner: string, map: PageMap) -> Option<reflect.Type> {
    var hits: List<reflect.Type> = []
    for described: reflect.Type in all {
        if described.qualified_name() == wanted || described.name() == wanted {
            hits.push(described)
        }
    }
    if hits.len() == 0 {
        map.faults.push("{owner}: @layout(name: \"{wanted}\") names no type in this program")
        return none
    }
    if hits.len() > 1 {
        var names: List<string> = []
        for hit: reflect.Type in hits { names.push(hit.qualified_name()) }
        map.faults.push(
            "{owner}: @layout(name: \"{wanted}\") is ambiguous — {names.join(\", \")}; " +
            "spell the qualified name")
        return none
    }
    let found: reflect.Type = hits[0]
    if !extends_named(found, layout_name) {
        map.faults.push(
            "{owner}: @layout(name: \"{wanted}\") resolves to {found.qualified_name()}, " +
            "which does not extend {layout_name}")
        return none
    }
    if found.initializer().is_none() {
        map.faults.push(
            "{owner}: layout {found.qualified_name()} has no zero-argument initializer")
        return none
    }
    return some(found)
}

// ---- reading annotations ---------------------------------------------------
//
// An annotation's `qualified_name()` is `latte.page`, so matching on the simple
// name would also match `app.page`. These compare the whole name against
// latte's own package, taken from a type in it rather than written down.

fn latte_annotation(simple: string) -> string {
    let owner: string = type_of(Component).qualified_name()
    match owner.rfind(".") {
        some(at) => { return "{owner.slice(0, at)}.{simple}" }
        none => { return simple }
    }
}

pub fn annotations_named(uses: List<reflect.Annotation>, simple: string)
        -> List<reflect.Annotation> {
    let wanted: string = latte_annotation(simple)
    var out: List<reflect.Annotation> = []
    for use: reflect.Annotation in uses {
        if use.qualified_name() == wanted { out.push(use) }
    }
    return move out
}

pub fn argument_string(use: reflect.Annotation, name: string) -> string {
    match use.argument(name) {
        some(argument) => {
            match argument.value().as_string() {
                some(text) => { return text }
                none => { return "" }
            }
        }
        none => { return "" }
    }
}

pub fn argument_bool(use: reflect.Annotation, name: string) -> bool {
    match use.argument(name) {
        some(argument) => {
            match argument.value().as_bool() {
                some(value) => { return value }
                none => { return false }
            }
        }
        none => { return false }
    }
}

pub fn argument_strings(use: reflect.Annotation, name: string) -> List<string> {
    var out: List<string> = []
    match use.argument(name) {
        some(argument) => {
            for item: reflect.AnnotationValue in argument.value().items() {
                match item.as_string() {
                    some(text) => { out.push(text) }
                    none => {}
                }
            }
        }
        none => {}
    }
    return move out
}

fn upper_all(values: List<string>) -> List<string> {
    var out: List<string> = []
    for value: string in values { out.push(value.to_upper()) }
    return move out
}

// ============================================================== mounting
//
// A page with a layout renders as a chain: the outermost layout is the render
// root, each layout's `body` renders the next, and the innermost body renders
// the page.
//
// **What this does not do yet, and what would change it.** The page is
// rendered INTO the innermost layout's frame buffer rather than mounted as a
// child component of it, so the page is not separately markable: an event on
// the page marks the layout, which re-renders the layout and the page together.
// The output is identical either way — that is what `tests/pages.b` § layouts
// asserts on both backends — and static rendering, which is what this lane
// ships, cannot tell the difference. What it costs is one extra layout render
// per event once circuits exist.
//
// The reason it is written this way is a missing primitive, not a design
// choice: `Builder.component<T>` activates by static type, and latte never
// knows a page's type statically — it holds a `reflect.Type` the scan found.
// Mounting an instance the caller already made needs `Builder.component_made<T>
// (seq, make: fn() -> T, setup: fn(T))`, which W4 asked W1 for and which has
// not landed. When it does, `LayoutLink.render_body` below becomes
//
//     inner.component_made<Component>(0, fn() -> Component { return page },
//                                     fn(c: Component) {})
//
// and nothing else in this file moves.

/// One link of the layout chain. It exists so each layout's `body` closure
/// captures one object rather than a loop variable.
class LayoutLink {
    next: Option<Layout> = none
    following: Option<LayoutLink> = none
    page: Option<Component> = none
    pub fn init() {}

    fn render_body(b: Builder) {
        match self.next {
            some(layout) => { layout.render(b) }
            none => {
                match self.page {
                    some(page) => { page.render(b) }
                    none => {}
                }
            }
        }
    }
}

/// A page, its layout chain, and everything needed to render it.
pub class PageInstance {
    pub plan: PagePlan = new PagePlan()
    pub component: Option<Component> = none
    /// Outermost first.
    pub layouts: List<Layout> = []
    pub problems: List<string> = []
    pub fn init() {}

    pub fn ok() -> bool { return self.problems.len() == 0 && self.component.is_some() }

    /// The component a renderer mounts: the outermost layout, or the page when
    /// there is no layout.
    pub fn root() -> Option<Component> {
        if self.layouts.len() > 0 { return some(self.layouts[0]) }
        return self.component
    }

    /// Wire the chain together. Called once, by `open_page`.
    fn link() {
        var index: int = 0
        for index < self.layouts.len() {
            var link: LayoutLink = new LayoutLink()
            if index + 1 < self.layouts.len() { link.next = some(self.layouts[index + 1]) }
            else { link.page = self.component }
            let layout: Layout = self.layouts[index]
            layout.body = fn(b: Builder) { link.render_body(b) }
            index += 1
        }
    }

    /// `on_init` and `on_params_set` for everything the chain holds.
    ///
    /// The renderer runs them for the component it mounts; everything below the
    /// root in a layout chain is not a mounted child (see the note above), so
    /// latte runs them here. Order is Blazor's: outermost layout first, page
    /// last, each fully initialised before the render begins.
    fn start() {
        for layout: Layout in self.layouts {
            layout.on_init()
            layout.on_params_set()
        }
        match self.component {
            some(page) => {
                if self.layouts.len() > 0 { page.on_init() ; page.on_params_set() }
            }
            none => {}
        }
    }
}

/// Activate a matched page, bind its route values, and build its layout chain.
///
/// `who` is checked HERE and not only by the host's middleware, because a
/// circuit outlives the request that opened it and re-mounts on navigation —
/// PLAN.md's "authorization outliving its token", which is Blazor's best-known
/// pitfall. A caller that has already checked pays one comparison to check
/// again; a caller that has not is not able to skip it.
pub fn open_page(found: PageMatch, who: Principal,
                 activator: Option<Activator>) -> PageInstance {
    var instance: PageInstance = new PageInstance()
    instance.plan = found.plan

    let outcome: AuthOutcome = found.plan.authorize(who)
    match outcome {
        allow => {}
        _ => {
            instance.problems.push(
                "{found.plan.name}: {describe_outcome(outcome)}")
            return move instance
        }
    }

    var made: Result<reflect.Value, string> = found.plan.activate()
    match activator {
        some(host) => { made = found.plan.activate_with(host) }
        none => {}
    }
    match made {
        err(problem) => {
            instance.problems.push(problem)
            return move instance
        }
        ok(value) => {
            match value.copy() as? Component {
                none => {
                    instance.problems.push(
                        "{found.plan.name} activated as {value.type().qualified_name()}, " +
                        "which is not a Component")
                    return move instance
                }
                some(page) => { instance.component = some(page) }
            }
            for problem: string in found.plan.apply(value.copy(), found.values) {
                instance.problems.push(problem)
            }
        }
    }
    if instance.problems.len() > 0 { return move instance }

    for described: reflect.Type in found.plan.layouts {
        match described.initializer() {
            none => {
                instance.problems.push(
                    "layout {described.qualified_name()} has no zero-argument initializer")
                return move instance
            }
            some(ctor) => {
                match ctor.call([]) {
                    err(problem) => {
                        instance.problems.push(
                            "cannot activate layout {described.name()}: {problem.message()}")
                        return move instance
                    }
                    ok(value) => {
                        match value.copy() as? Layout {
                            some(layout) => { instance.layouts.push(layout) }
                            none => {
                                instance.problems.push(
                                    "{described.qualified_name()} is not a Layout")
                                return move instance
                            }
                        }
                    }
                }
            }
        }
    }

    instance.link()
    instance.start()
    return move instance
}

/// Mount a page instance into a renderer. `false` means it did not, and
/// `instance.problems` says why.
pub fn mount_page(renderer: Renderer, instance: PageInstance) -> bool {
    if !instance.ok() { return false }
    match instance.root() {
        some(root) => {
            renderer.mount(root)
            return true
        }
        none => { return false }
    }
}
