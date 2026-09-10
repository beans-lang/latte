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
// The most important one: a reflective write
// to a field whose *declaring type* is generic was `ok` under `beansc run` and
// `unsupported` as a native binary, so a page bound that way worked all through
// the edit loop and broke when it shipped. beans 0.1.41 closed it (#158, #159)
// and latte's reconstruction of it is gone; `test.sh` pins that compiler, so
// the shape cannot come back under a supported one.
//
// What remains is a boundary rather than a divergence: a closed generic has no
// reflective initializer on either backend, because a receiver-less operation
// names no instantiation. `scan_pages` refuses a @page that IS one, and says
// what to write instead.
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
/// none is needed — latte resolves every type it needs (a component tag, a
/// `@form`, a `@page`, this) the same way: by name, at startup, from
/// `reflect.types()`.
@target(value: ["type"])
@retention(value: "runtime")
pub annotation layout {
    name: string
}

/// An authorization requirement. Repeatable: several requirements on one page
/// must ALL hold, and the roles inside one requirement are alternatives — AND
/// across requirements, OR across roles. A framework that inverted it would
/// widen access on a page that reads as if it narrowed it.
@target(value: ["type"])
@retention(value: "runtime")
@repeatable
pub annotation authorize {
    policy: string = ""
    roles: List<string> = []
}

/// Re-render this component only when one of its parameters changed.
///
/// It replaces four lines an author used to write by hand, once per component:
///
/// ```beans
/// watch: ParamWatch = new ParamWatch()
/// pub override fn on_params_set() {
///     self.watch.record([self.name, "{self.price}", "{self.chosen}"])
/// }
/// pub override fn should_render() -> bool { return self.watch.differs() }
/// ```
///
/// **The list was the problem, not the length.** It is written by hand and
/// stringly typed, so a parameter left out of it is a parameter whose changes
/// stop reaching the screen — and nothing says so. `@memo` reads the `@param`
/// fields themselves, so the list cannot drift from the fields it is meant to
/// mirror.
///
/// ## What is compared, and what is not
///
/// * **`string`, `int`, `bool`, `float` are compared.** These are a
///   component's state.
/// * **`Callback<T>` is not**, and this is deliberate rather than an omission.
///   A parent builds a fresh `Callback` on every render, so comparing one would
///   make the memo *never* fire — which is worse than not comparing it. Nothing
///   is lost: a handler is read when it is called, not when it is rendered.
/// * **Anything else is refused at startup**, by name, with the field named. A
///   `List`, a `Map`, another component — latte cannot compare it, and
///   *silently* not comparing it is exactly the trap the hand-written list set.
///   Write `should_render` yourself for those.
///
/// ## And a component that takes child content may not carry it
///
/// A `@param pub body: fn(Builder)` is a closure the parent rebuilds every
/// render, holding markup that may be completely different. Its parameters can
/// all be equal while its content is not. `shelf/cards/card.b` records this as
/// a rule an author has to remember; under `@memo` it is a startup refusal.
@target(value: ["type"])
@retention(value: "runtime")
pub annotation memo {
}

/// A field the framework fills from the application's service container.
///
/// Constructor injection reaches a `@page`, because the container builds one.
/// It cannot reach a CHILD component: children are constructed by the renderer
/// at mount, from a zero-argument initializer, and the renderer is not the
/// container. Before this, a nested component could only see a shared object if
/// every ancestor between it and the page passed it down as a `@param`.
///
/// The mechanism is the one `@param` already uses — a `reflect.Field` written
/// through a plan compiled once per component type — so the reflection happens
/// at mount and not on any event path.
///
/// Two limits, both stated rather than discovered:
///
///  * **The field must be `pub`.** Reflection answers `inaccessible` for
///    anything else, cross-package and same-package alike, and `scan_injections`
///    refuses it at startup with that sentence rather than leaving the field at
///    its default.
///  * **A `weak` field cannot be injected.** Weak slots are invisible to
///    reflection (`spec/SYNTAX.md`), so `@inject weak` is not refused — it is
///    not seen at all. Do not write one.
@target(value: ["field"])
@retention(value: "runtime")
pub annotation inject {
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
            if piece.contains("\{") || piece.contains("\}") {
                if !piece.starts_with("\{") || !piece.ends_with("\}") {
                    self.faults.push(
                        "route \"{self.source}\": a placeholder is a whole segment, so \"{piece}\" is not one")
                    continue
                }
                let name: string = piece.slice(1, piece.len() - 1)
                if name.contains("\{") || name.contains("\}") {
                    self.faults.push("route \"{self.source}\": \"{piece}\" nests braces")
                    continue
                }
                if name == "" {
                    self.faults.push("route \"{self.source}\" has an unnamed placeholder")
                    continue
                }
                if name.starts_with("*") {
                    self.faults.push(
                        "route \"{self.source}\": a catch-all placeholder (\"{piece}\") is not supported — a placeholder captures one segment")
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
            if segment.is_parameter { out.push("\{\}") } else { out.push(segment.text) }
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
    /// This is the ONE place latte writes a field reflectively. A field
    /// declared by a generic ancestor used to write fine under `beansc run`
    /// and fail natively — silently, since a failure here is just a 400 —
    /// which is why the scan used to refuse that shape outright rather than
    /// let it reach this point. Both backends agree now, so `apply` just
    /// writes the field like any other.
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

/// A whole number in a ROUTE segment, where one resource has one spelling.
///
/// `parse_form_int` does the number: digits, a sign, and the overflow refusal.
/// This adds the one extra rule a URL carries — the text must be the canonical
/// spelling of the value it names, so `/notes/007` is not `/notes/7` wearing a
/// disguise. A form field is the other rule and lives in `forms.b`; see
/// `parse_form_int` for why one function cannot hold both.
///
/// `+7` is still accepted, exactly as before: `strip_plus` is what the
/// comparison runs against and this file's route suites already stand on that.
pub fn parse_int(text: string) -> Option<int> {
    match parse_form_int(text) {
        none => { return none }
        some(value) => {
            if "{value}" != strip_plus(text) { return none }
            return some(value)
        }
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

/// Who is asking. Latte ships no identity: an application supplies one,
/// because a framework whose security depends on a component it does not
/// provide would have a hole exactly where that component should be.
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
                    ok(made) => { return ok(made) }
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
    /// Why this page cannot be served. A plan with a fault stays in the map so
    /// `report()` can name it and a test can inspect what survived — but
    /// `find()` never routes to it, so a host that ignored `ok()` still cannot
    /// serve a page latte refused.
    pub faults: List<string> = []
    described: Option<reflect.Type> = none
    /// Cached at scan time: the initializer lookup costs about half of what a
    /// reflective activation does, and a page activates once per request.
    ctor: Option<reflect.Initializer> = none
    pub fn init() {}

    pub fn describes() -> Option<reflect.Type> { return self.described }

    pub fn usable() -> bool { return self.faults.len() == 0 }

    pub fn serves(method: string) -> bool {
        return self.methods.contains(method.to_upper())
    }

    /// Activate through the cached initializer.
    pub fn activate() -> Result<reflect.Value, string> {
        match self.ctor {
            some(ctor) => {
                match ctor.call([]) {
                    ok(made) => { return ok(made) }
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
    pub fn init(plan: PagePlan, move values: Map<string, string>) {
        self.plan = plan
        self.values = move values
    }
}

// ============================================================== the scan

/// What `@memo` compares on one component type.
pub class MemoPlan {
    /// Whether the type carries `@memo` at all.
    pub present: bool = false
    /// The `@param` fields to compare, in declaration order, with the scalar
    /// kind to read each as.
    pub params: List<reflect.Field> = []
    pub kinds: List<ParamKind> = []
    /// Why `@memo` cannot work here. A type with any of these never memoizes —
    /// `scan_memo` refuses the application at startup, and a host that skipped
    /// the scan gets every render rather than a wrong one.
    pub faults: List<string> = []
    pub fn init() {}
}

/// Work out what `@memo` compares on one type.
///
/// One function and two callers — the mount path and the startup scan — so
/// what a page refuses at startup and what it memoizes at render can never be
/// two different answers.
pub fn memo_plan_for(described: reflect.Type) -> MemoPlan {
    var plan: MemoPlan = new MemoPlan()
    plan.present = annotations_named(described.annotations(), "memo").len() > 0
    if !plan.present { return move plan }
    let key: string = described.qualified_name()
    for field: reflect.Field in described.fields() {
        if annotations_named(field.annotations(), "param").len() == 0 { continue }
        let shown: string = "{key}.{field.name()}"
        if !field.is_public() {
            plan.faults.push(
                "{shown} is a @param on a @memo component but is not public, and reflection does not bypass visibility")
            continue
        }
        let type_name: string = field.type().qualified_name()
        let kind: ParamKind = kind_of(field.type())
        if kind != ParamKind.other {
            plan.params.push(field)
            plan.kinds.push(kind)
        } else if type_name.starts_with("fn(") {
            plan.faults.push(
                "{shown} is a @param of type {type_name} on a @memo component — a closure the parent rebuilds every render, holding markup that may be completely different. Its parameters can all be equal while its content is not. Drop @memo, or take the content another way")
        } else if type_name.contains("latte.Callback<") {
            // Skipped on purpose and not overlooked: a parent builds a fresh
            // Callback every render, so comparing one would make the memo never
            // fire. Nothing is lost — a handler is read when it is called, not
            // when it is rendered.
        } else {
            plan.faults.push(
                "{shown} is a @param of type {type_name} on a @memo component, and latte cannot compare one — only string, int, bool and float. Write should_render yourself, or drop @memo")
        }
    }
    return move plan
}

/// Every `@memo` in the executable that cannot work, and every `@memo` on a
/// type that is not a component.
///
/// A startup scan for the reason `scan_injections` is one: a `@memo` that
/// cannot compare a parameter is a component that stops updating, and there is
/// nothing about that which needs a request to discover.
pub fn scan_memo() -> List<string> {
    var problems: List<string> = []
    let component_name: string = type_of(Component).qualified_name()
    for described: reflect.Type in reflect.types() {
        if annotations_named(described.annotations(), "memo").len() == 0 {
            continue
        }
        if !extends_named(described, component_name) {
            problems.push(
                "{described.qualified_name()} is annotated @memo but does not extend {component_name}, so nothing would ever consult it")
            continue
        }
        for fault: string in memo_plan_for(described).faults { problems.push(fault) }
    }
    return move problems
}

/// Every `@inject` field in the executable that could not be filled.
///
/// An empty list is a clean application. Anything in it is a component that
/// would have mounted with the field at its default and a fault buried in a
/// buffer's list — a page that renders, answers 200, and is wrong.
///
/// **Why this is a startup scan and not a render-time check.** latte's
/// rendering already treats a mount fault as a hole rather than a failure: a
/// subtree that cannot be built leaves the rest of the page standing, which is
/// the right call for a live circuit and the wrong one for "the service you
/// asked for does not exist". That is not a rendering condition at all — it is
/// a configuration one, decidable before a socket exists, which is where every
/// other configuration refusal in latte already lives.
///
/// Three things are checked, and each is fatal for the same reason: the field
/// will silently keep its default.
///
///  * the field is not `pub`, so reflection cannot write it;
///  * nothing is registered for its type;
///  * there is no container at all, and some component asks for one.
pub fn scan_injections(source: Option<ServiceSource>) -> List<string> {
    var problems: List<string> = []
    let component_name: string = type_of(Component).qualified_name()
    for described: reflect.Type in reflect.types() {
        if !extends_named(described, component_name) { continue }
        for field: reflect.Field in described.fields() {
            if annotations_named(field.annotations(), "inject").len() == 0 {
                continue
            }
            let shown: string = "{described.qualified_name()}.{field.name()}"
            if !field.is_public() {
                problems.push(
                    "{shown} is @inject but is not public, and reflection does not bypass visibility")
                continue
            }
            match source {
                none => {
                    problems.push(
                        "{shown} is @inject, but this application has no service container to fill it from")
                }
                some(known) => {
                    if !known.knows(field.type()) {
                        problems.push(
                            "{shown} is @inject but nothing is registered for {field.type().qualified_name()}")
                    }
                }
            }
        }
    }
    return move problems
}

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
            if plan.usable() && plan.serves(method) {
                match plan.route.matches(path) {
                    some(values) => {
                        let score: int = plan.route.specificity()
                        if score > best_score {
                            best = index
                            best_score = score
                            best_values = values.clone()
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

    /// Every method some usable page serves at `path`, sorted and without
    /// repeats.
    ///
    /// `find` deliberately answers `none` for a path that matches a page whose
    /// methods do not serve the request, so that two pages can share a path and
    /// split the methods. That leaves the caller unable to tell "no such page"
    /// from "not that method", which is a 404 where the answer is a 405 — and a
    /// 405 is not cosmetic here: a form posting to a page that only serves GET
    /// is one of the two ways a form silently does nothing, and a 404 sends its
    /// author looking at the route.
    pub fn allowed(path: string) -> List<string> {
        var out: List<string> = []
        for plan: PagePlan in self.pages {
            if !plan.usable() { continue }
            match plan.route.matches(path) {
                some(_) => {
                    for method: string in plan.methods {
                        if !out.contains(method) { out.push(method) }
                    }
                }
                none => {}
            }
        }
        out.sort()
        return move out
    }
}

/// Walk every type in the executable once and turn the annotated ones into
/// plans.
///
/// There is no registry and no registration call: `reflect.types()` is the
/// registry, in declaration order, and a page is a page because it says so.
pub fn scan_pages() -> PageMap {
    return scan_pages_for(false)
}

/// `scan_pages`, told whether a service container will be present.
///
/// The one thing it changes is the refusal for a page whose `init` takes
/// arguments. With a container that page is ordinary — the activator resolves
/// each parameter. Without one, nothing could, and latte would activate it with
/// an empty argument list and answer 500 on every request; so it is refused at
/// startup instead, which is where every other unservable page is refused.
///
/// A host that builds a container calls this with `true`. `scan_pages()` is
/// `false`, which is what every existing caller means.
pub fn scan_pages_for(container: bool) -> PageMap {
    var map: PageMap = new PageMap()
    let component_name: string = type_of(Component).qualified_name()
    let layout_name: string = type_of(Layout).qualified_name()
    let all: List<reflect.Type> = reflect.types()

    var shapes: Map<string, int> = {}
    for described: reflect.Type in all {
        var uses: List<reflect.Annotation> = annotations_named(described.annotations(), "page")
        if uses.len() == 0 {
            // A `@layout` or `@authorize` on a type that is not a page is a
            // typo with no effect, and silence is how a security annotation
            // gets lost. A layout carrying `@layout` is the nesting case and
            // is fine.
            if annotations_named(described.annotations(), "authorize").len() > 0 {
                map.faults.push(
                    "{described.qualified_name()} is annotated @authorize but is not a @page; the requirement would never be checked")
            }
            if annotations_named(described.annotations(), "layout").len() > 0 &&
               !extends_named(described, layout_name) {
                map.faults.push(
                    "{described.qualified_name()} is annotated @layout but is neither a @page nor a latte.Layout, so nothing would ever wrap it")
            }
            continue
        }
        if uses.len() > 1 {
            // Unreachable: @page is not @repeatable. See `annotations_named`.
            map.faults.push("{described.qualified_name()} carries @page more than once")
            continue
        }
        var plan: PagePlan = plan_for(described, uses[0], component_name, container)
        match plan.describes() {
            none => {
                for fault: string in plan.faults { map.faults.push(fault) }
                continue
            }
            some(_) => {}
        }
        resolve_layouts(plan, described, all, layout_name)
        // A route that did not parse has no shape worth comparing: an
        // unparseable pattern collapses to zero segments, which would then
        // "clash" with the page at "/" and refuse a healthy page for somebody
        // else's typo.
        let shape: string = plan.route.shape()
        for method: string in plan.methods {
            if !plan.route.ok() { break }
            let key: string = "{method} {shape}"
            match shapes.get(key) {
                some(first) => {
                    // BOTH pages are refused, not only the second one. Nothing
                    // at request time could choose between them, so serving
                    // either is serving a coin toss — and refusing only the one
                    // that happened to be scanned second would make the answer
                    // depend on declaration order across files.
                    let message: string = "{plan.type_name} and {map.pages[first].type_name} both answer {method} {shape}; nothing at request time could choose between them"
                    plan.faults.push(message)
                    map.pages[first].faults.push(message)
                }
                none => { shapes[key] = map.pages.len() }
            }
        }
        map.pages.push(plan)
    }
    // The map's fault list is built LAST, because a clash discovered by a later
    // page adds a fault to an earlier one.
    for plan: PagePlan in map.pages {
        for fault: string in plan.faults { map.faults.push(fault) }
    }
    return map
}

fn plan_for(described: reflect.Type, use: reflect.Annotation,
            component_name: string, container: bool) -> PagePlan {
    var plan: PagePlan = new PagePlan()
    plan.type_name = described.qualified_name()
    plan.name = described.name()

    if !extends_named(described, component_name) {
        plan.faults.push(
            "{plan.type_name} is annotated @page but does not extend {component_name}, so it has nothing to render")
        return plan
    }

    // A page is activated
    // reflectively — that is what "no registry" costs — and a receiver-less
    // operation on a generic declaration names no instantiation, so a closed
    // generic has no reflective initializer. That is now a stated compiler
    // boundary (`spec/SYNTAX.md`), not a divergence: both backends answer
    // `none`, so a page of that shape fails the same way everywhere.
    //
    // What this used to refuse and no longer does is the SUBCLASS: 0.1.40
    // constructed `OrderGrid extends Grid<int>` under `beansc run` and answered
    // `unsupported` natively, which is why the whole chain was refused
    // here. 0.1.41 constructs it on both backends, so a page with a generic
    // ANCESTOR is ordinary now, and only a page that IS one is refused.
    // The check is "can this be activated", not "is this generic". A refusal
    // written as `described.type_arguments().len() > 0` would never fire:
    // annotation rows are filed on the OPEN declaration, so a scanned page type
    // never arrives closed, and a guard that cannot fire is indistinguishable
    // from one that passes. Asking for the initializer asks the real question,
    // and catches a page with no zero-argument `init` for any other reason too
    // — which used to be a 500 at request time. `check_layout` below has asked
    // it this way all along.
    match described.initializer() {
        none => {
            plan.faults.push(
                "{plan.type_name} is a @page with no reflective zero-argument initializer, so latte cannot activate it. A closed generic is one way to get here — a receiver-less reflective operation names no instantiation, so it has none on either backend; give it a non-generic subclass and put @page on that. A class with no zero-argument `init` is the other.")
        }
        // A page whose `init` takes arguments has an initializer descriptor,
        // so the check above says nothing about it — and `PagePlan.activate`
        // calls it with an empty argument list, which is a 500 at request time
        // saying "wrong reflected argument count". That is the exact shape this
        // whole refusal exists to move to startup, and it walked straight past
        // it for as long as the check asked only whether a descriptor existed.
        //
        // With a container the page is ordinary: `activate_with` resolves each
        // parameter and calls it. Without one there is nothing that could, so
        // it is refused here, by name, with the sentence that fixes it.
        some(ctor) => {
            if !container && ctor.parameters().len() > 0 {
                plan.faults.push(
                    "{plan.type_name} is a @page whose `init` takes {ctor.parameters().len()} argument(s), and this application has no service container to supply them — latte would activate it with none and answer 500 on every request. Register the services it asks for, or give it a zero-argument `init`.")
            }
        }
    }

    let route_text: string = argument_string(use, "route")
    plan.route = new RoutePattern(route_text)
    for fault: string in plan.route.faults { plan.faults.push("{plan.type_name}: {fault}") }

    plan.methods = upper_all(argument_strings(use, "methods"))
    if plan.methods.len() == 0 {
        plan.faults.push("{plan.type_name}: @page(methods:) is empty")
    }
    for method: string in plan.methods {
        if !is_identifier(method) {
            plan.faults.push("{plan.type_name}: \"{method}\" is not an HTTP method")
        }
    }

    for use2: reflect.Annotation in annotations_named(described.annotations(), "authorize") {
        var requirement: AuthRequirement = new AuthRequirement()
        requirement.policy = argument_string(use2, "policy")
        requirement.roles = argument_strings(use2, "roles")
        if requirement.policy == "" && requirement.roles.len() == 0 {
            // A bare `@authorize` means "signed in, with no further
            // requirement" — deliberate, not an empty/no-op requirement.
            plan.requirements.push(requirement)
        } else {
            plan.requirements.push(requirement)
        }
    }

    let layouts: List<reflect.Annotation> = annotations_named(described.annotations(), "layout")
    if layouts.len() > 1 {
        // Unreachable: @layout is not @repeatable. See `annotations_named`.
        plan.faults.push("{plan.type_name} carries @layout more than once")
    } else if layouts.len() == 1 {
        plan.layout_name = argument_string(layouts[0], "name")
        if plan.layout_name == "" {
            plan.faults.push("{plan.type_name}: @layout(name:) is empty")
        }
    }

    var declared: List<string> = []
    bind_params(plan, described, declared)

    // Every placeholder must be a parameter. A route that captures into
    // nothing is a page that can never see half its own URL.
    //
    // `declared` holds every `@param` wire name the scan SAW, including the
    // ones it refused, so a refused field does not also produce "no @param
    // binds it" — one cause, one message. Without that, the specific
    // refusal reads like a missing declaration and the reader fixes the wrong
    // thing.
    for name: string in plan.route.names() {
        if !declared.contains(name) {
            plan.faults.push(
                "{plan.type_name}: route \"{plan.route.source}\" captures \"{name}\" but no @param binds it")
        }
    }

    plan.ctor = described.initializer()
    plan.described = some(described)
    return plan
}

fn bind_params(plan: PagePlan, described: reflect.Type, declared: List<string>) {
    var seen: Map<string, string> = {}
    for field: reflect.Field in described.fields() {
        let uses: List<reflect.Annotation> = annotations_named(field.annotations(), "param")
        if uses.len() == 0 { continue }
        if uses.len() > 1 {
            // Unreachable: @param is not @repeatable. See `annotations_named`.
            plan.faults.push("{plan.type_name}.{field.name()} carries @param more than once")
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
        declared.push(binding.wire_name)

        match seen.get(binding.wire_name) {
            some(other) => {
                plan.faults.push(
                    "{plan.type_name}: \"{binding.wire_name}\" names both {other} and {binding.field_name}")
                continue
            }
            none => { seen[binding.wire_name] = binding.field_name }
        }

        if !field.is_public() {
            plan.faults.push(
                "{plan.type_name}.{binding.field_name} is a @param but is not public, and reflection does not bypass visibility")
            continue
        }

        if binding.required && !binding.from_route {
            plan.faults.push(
                "{plan.type_name}.{binding.field_name} is @param(required: true) but route \"{plan.route.source}\" does not capture \"{binding.wire_name}\"")
            continue
        }
        if binding.from_route {
            match binding.kind {
                other => {
                    plan.faults.push(
                        "{plan.type_name}.{binding.field_name} is captured by route \"{plan.route.source}\" but is a {binding.type_name}; a route can bind string, int, bool and float")
                    continue
                }
                _ => {}
            }
        }
        plan.params.push(binding)
    }
}

// `generic_declaration` and `generic_ancestor` lived here until 0.1.41. They
// were the base-chain reconstruction one divergence forced on latte: a
// reflective write to a field declared by a generic type was `ok` under
// `beansc run` and `unsupported` natively, and the obvious guard for it --
// `field.declaring_type().type_arguments().len() > 0` -- read FALSE for exactly
// the fields that failed, because a declaring type came back open. So latte
// walked the receiver's chain, stripped each link's arguments, and matched the
// link the field named.
//
// beans #158 made the write agree on both backends and #159 made
// `declaring_type()` answer the closed form, so both the divergence and the
// reason the guard could not see it are gone. Nothing reconstructs anything
// now; `scan_pages` and `scan_form` bind such a field like any other.

pub fn strip_type_arguments(name: string) -> string {
    match name.find("<") {
        some(at) => { return name.slice(0, at) }
        none => { return name }
    }
}

/// Whether `described` is, or descends from, the type with this qualified name.
///
/// It walks `base_type()`, and the chain's names are always the real ones —
/// they come from the runtime's own inheritance links and no name resolution
/// happens on the way. `wanted` is the half a caller can get wrong.
///
/// beans 0.1.41 (#164) closed the hazard this function was written around.
/// It is recorded here because the shape of the API — a string argument
/// rather than a `reflect.Type` — is what that bug left behind, and a reader
/// who finds that odd deserves the reason.
///
/// The bug: a type name written **inside a string interpolation** was
/// resolved without the file's named-import bindings, and fell back to
/// composing the asking package's own name with the simple name. So
///
/// ```beans
/// extends_named(t, "{type_of(Component).qualified_name()}")   // was latte$entry.Component — false, always
/// let base: reflect.Type = type_of(Component)
/// extends_named(t, base.qualified_name())                     // latte.Component — right
/// ```
///
/// disagreed, in the same file, about the same type. Latte's own callers could
/// not trip it — `Component` is declared in the package `pages.b` is written
/// in, so the composed fallback `latte.Component` was right by coincidence —
/// and every consumer could, because their package is not `latte`. That
/// asymmetry is why `tests/pages.b` § 10 measures it from an entry package,
/// where latte's own file cannot. On 0.1.41 both spellings answer the same
/// name, and § 10 asserts that they do.
///
/// **The function stays, for a reason that was never about the interpolation
/// bug:** it is a
/// chain walk and not an `is_assignable_from`, so `strip_type_arguments` lets
/// `Grid<Order>` match a `wanted` of `Grid` — what a framework asking "is this
/// one of mine?" needs of a generic component. beans #169 taught
/// `is_assignable_from` that an argument-free name denotes the declaration
/// itself, so the two now agree on this case; the walk stays because the names
/// it compares come from the runtime's own inheritance links and are never
/// resolved by a name lookup.
///
/// It is `pub` because a host package needs it.
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

fn resolve_layouts(plan: PagePlan, described: reflect.Type, all: List<reflect.Type>, layout_name: string) {
    var chain: List<reflect.Type> = []
    var seen: List<string> = []
    var wanted: string = plan.layout_name
    var owner: string = plan.type_name
    for wanted != "" {
        match find_layout(wanted, all, layout_name, owner, plan.faults) {
            none => { return }
            some(found) => {
                if seen.contains(found.qualified_name()) {
                    plan.faults.push(
                        "{plan.type_name}: the layout chain loops at {found.qualified_name()}")
                    return
                }
                seen.push(found.qualified_name())
                chain.push(found)
                owner = found.qualified_name()
                let nested: List<reflect.Annotation> =
                    annotations_named(found.annotations(), "layout")
                if nested.len() > 1 {
                    // Unreachable: @layout is not @repeatable. See `annotations_named`.
                    plan.faults.push("{owner} carries @layout more than once")
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

fn find_layout(wanted: string, all: List<reflect.Type>, layout_name: string, owner: string, into: List<string>) -> Option<reflect.Type> {
    var hits: List<reflect.Type> = []
    for described: reflect.Type in all {
        if described.qualified_name() == wanted || described.name() == wanted {
            hits.push(described)
        }
    }
    if hits.len() == 0 {
        into.push("{owner}: @layout(name: \"{wanted}\") names no type in this program")
        return none
    }
    if hits.len() > 1 {
        var names: List<string> = []
        for hit: reflect.Type in hits { names.push(hit.qualified_name()) }
        let listed: string = names.join(", ")
        into.push(
            "{owner}: @layout(name: \"{wanted}\") is ambiguous — {listed}; spell the qualified name")
        return none
    }
    let found: reflect.Type = hits[0]
    if !extends_named(found, layout_name) {
        into.push(
            "{owner}: @layout(name: \"{wanted}\") resolves to {found.qualified_name()}, which does not extend {layout_name}")
        return none
    }
    if found.initializer().is_none() {
        into.push(
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

/// **Four refusals in this file cannot fire, and this is where that is
/// written down.** `@page`, `@layout` and `@param` are not `@repeatable`, and
/// 0.1.40 refuses a repeated non-repeatable annotation at the author's own
/// declaration — `error: annotation '@once' is not repeatable`, measured in
/// `probes/p16_repeat`. So the four `carries @X more than once` faults below
/// stand behind a compile error and no program can reach them:
///
///   scan_pages      "... carries @page more than once"
///   plan_for        "... carries @layout more than once"
///   bind_params     "... carries @param more than once"
///   find_layout     "... carries @layout more than once"
///
/// They are kept rather than deleted because what makes them unreachable is a
/// property of latte's OWN annotation declarations, thirty lines above: adding
/// `@repeatable` to `@layout` one day would make the third one live again, and
/// the scan would be silently taking the first of two layouts without it. They
/// are marked here so a reader auditing `pages.b` does not spend the afternoon
/// trying to build an input that reaches one — said here, with the evidence,
/// rather than left for a reader to assume it is covered.
pub fn annotations_named(uses: List<reflect.Annotation>, simple: string) -> List<reflect.Annotation> {
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

pub fn argument_int(use: reflect.Annotation, name: string) -> int {
    match use.argument(name) {
        some(argument) => {
            match argument.value().as_int() {
                some(value) => { return value }
                none => { return 0 }
            }
        }
        none => { return 0 }
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
// root, each layout's `body` mounts the next as a CHILD COMPONENT, and the
// innermost body mounts the page.
//
// It is a real mount and not an inline `page.render(b)`, and the difference is
// the whole update model: a mounted child has its own frame buffer, its own
// slot id and its own entry in the dirty set, so an event on the page marks the
// page. Rendered inline, the page's frames would live in the layout's buffer
// and every click on a page would re-render its layout.
//
// The mount goes through `Builder.component_made<T>` rather than
// `component<T>`, because latte never knows a page's type statically — the scan
// hands it a `reflect.Type` and an instance — and `component<T>` activates by
// static type. `T` here is `Component`, which is what a factory returning an
// already-activated page can be typed as; the one visible consequence is that
// the child frame carries the name `Component` rather than `Counter`, which is
// a label in a dump and in the wire's mount frame, not something the differ or
// the applier decides anything from.

/// One link of the layout chain. It exists so each layout's `body` closure
/// captures one object rather than a loop variable, and so the factory the
/// mount calls returns an instance that already exists rather than making one.
class LayoutLink {
    next: Option<Layout> = none
    page: Option<Component> = none
    pub fn init() {}

    fn render_body(b: Builder) {
        match self.next {
            some(layout) => {
                b.component_made<Component>(0,
                    fn() -> Component { return layout },
                    fn(mounted: Component) {})
            }
            none => {
                match self.page {
                    some(page) => {
                        b.component_made<Component>(0,
                            fn() -> Component { return page },
                            fn(mounted: Component) {})
                    }
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

}

/// Activate a matched page, bind its route values, and build its layout chain.
///
/// `who` is checked HERE and not only by the host's middleware, because a
/// circuit outlives the request that opened it and re-mounts on navigation —
/// authorization that only ran once, at the original request, would keep
/// holding after a session expired or a role was revoked. A caller that has
/// already checked pays one comparison to check again; a caller that has not
/// is not able to skip it.
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
            return instance
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
            return instance
        }
        ok(value) => {
            match value.copy() as? Component {
                none => {
                    instance.problems.push(
                        "{found.plan.name} activated as {value.type().qualified_name()}, which is not a Component")
                    return instance
                }
                some(page) => { instance.component = some(page) }
            }
            for problem: string in found.plan.apply(value.copy(), found.values) {
                instance.problems.push(problem)
            }
        }
    }
    if instance.problems.len() > 0 { return instance }

    for described: reflect.Type in found.plan.layouts {
        match described.initializer() {
            none => {
                instance.problems.push(
                    "layout {described.qualified_name()} has no zero-argument initializer")
                return instance
            }
            some(ctor) => {
                match ctor.call([]) {
                    err(problem) => {
                        instance.problems.push(
                            "cannot activate layout {described.name()}: {problem.message()}")
                        return instance
                    }
                    ok(value) => {
                        match value.copy() as? Layout {
                            some(layout) => { instance.layouts.push(layout) }
                            none => {
                                instance.problems.push(
                                    "{described.qualified_name()} is not a Layout")
                                return instance
                            }
                        }
                    }
                }
            }
        }
    }

    // Nothing here runs `on_init` or `on_params_set`: the layouts and the page
    // are all mounted components now, and `Builder.mount_made` runs `on_init`
    // at the mount while `render_child` runs `on_params_set` before every
    // render. The root is `Renderer.mount`'s, which does the same. Running them
    // here as well would run them twice.
    instance.link()
    return instance
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
