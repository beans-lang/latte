// `@persist`: the state a view-model carries across a prerender into the
// attach that follows.
//
// ## The hole this fills
//
// A POST is answered by a rendered page that holds what the post produced — the
// field errors, or the receipt. A circuit attaching to that page carries a URL
// and nothing else, so it re-renders the *pristine* page and replaces
// everything the user is reading. `examples/cafe` worked around it by serving
// POST answers with the circuit switched off (`ShellOptions.circuit = false`),
// which is correct and costs the page its interactivity for one navigation.
//
// ## Why the state rides in the document
//
// The obvious alternative is to keep it on the server, keyed by session. It is
// simpler and it is wrong: a POST is answered on one connection and the socket
// is accepted on another, and espresso gives every worker its own application
// and its own memory. A POST answered by worker 2 and a socket accepted by
// worker 3 would find nothing. Blazor carries its prerender state through the
// document for the same reason.
//
// ## Which makes it attacker-controlled
//
// Anything that leaves the browser and comes back is a value the user chose. So
// an island is **HMAC-signed with the application's own signer**, bound to the
// session and the url it was minted for, and stamped with an expiry — the same
// four properties `Antiforgery` already gives a form token, from the same
// `Signer`. A tampered island is refused and the circuit renders the pristine
// page, which is exactly today's behaviour: the failure mode of this feature is
// the absence of this feature.
//
// ## And bounded
//
// `PersistOptions.max_bytes` caps what one page may carry. Without it a
// view-model with a large list would put it in every document, and the first
// person to notice would be a user on a slow connection.
//
// This file must stay free of std.io, std.fs, std.net, std.time and
// std.random: it compiles for wasm32-unknown-unknown with the rest of the core.
package latte

import std.reflect

/// A view-model field that survives a prerender.
///
/// Scalars only — `string`, `int`, `float`, `bool`. Latte has no object-graph
/// serializer (`serialize.b` writes frames, not objects) and reflection should
/// not grow one on a security boundary: every field that crosses it is a field
/// an attacker gets to choose, and a scalar can be checked by reading it.
/// Anything richer is the author's own `pack`/`restore`.
@target(value: ["field"])
@retention(value: "runtime")
pub annotation persist {
}

/// What one page carries across the seam.
pub class PersistOptions {
    /// The most bytes one page's island may hold, before signing.
    pub max_bytes: int = 4096
    /// How long an island stays valid, in seconds.
    pub seconds: int = 300
    pub fn init() {}
}

/// One `@persist` field, resolved to how it is read and written.
class PersistBinding {
    field: reflect.Field
    kind: ParamKind
    fault: string = ""

    fn init(field: reflect.Field, kind: ParamKind) {
        self.field = field
        self.kind = kind
    }
}

/// The `@persist` fields of one type, worked out once.
class PersistPlan {
    pub bindings: List<PersistBinding> = []
    pub faults: List<string> = []
    fn init() {}
}

/// Everything a page wants to carry, as flat text.
///
/// A `Map<string, string>` and not a typed structure, because what crosses the
/// seam has to survive being written into a document, read back by a browser
/// and handed to a different process. Flat text is the only shape that has one
/// meaning at every one of those steps.
pub class PersistState {
    pub values: Map<string, string> = {}
    pub fn init() {}

    pub fn put(key: string, value: string) { self.values[key] = value }

    pub fn get(key: string) -> string {
        match self.values.get(key) {
            some(found) => { return found }
            none => { return "" }
        }
    }

    pub fn len() -> int { return self.values.len() }
}

// ============================================================== the plan

/// The `@persist` fields of one type.
fn persist_plan(described: reflect.Type) -> PersistPlan {
    var plan: PersistPlan = new PersistPlan()
    for field: reflect.Field in described.fields() {
        if annotations_named(field.annotations(), "persist").len() == 0 { continue }
        let shown: string = "{described.qualified_name()}.{field.name()}"
        if !field.is_public() {
            plan.faults.push(
                "{shown} is @persist but is not public, and reflection does not bypass visibility")
            continue
        }
        let kind: ParamKind = kind_of(field.type())
        var binding: PersistBinding = new PersistBinding(field, kind)
        if kind == ParamKind.other {
            binding.fault =
                "{shown} is @persist but is a {field.type().qualified_name()}; only string, int, bool and float cross the seam"
        }
        plan.bindings.push(binding)
    }
    return move plan
}

/// Every `@persist` field on any view-model in the executable that could not
/// cross the seam. Empty is a clean application.
///
/// A startup scan, for the reason `scan_injections` is one: a field that cannot
/// be packed is a page that silently loses state on one navigation, and there
/// is nothing about it that needs a request to discover.
pub fn scan_persist() -> List<string> {
    var problems: List<string> = []
    let model_name: string = type_of(ViewModel).qualified_name()
    for described: reflect.Type in reflect.types() {
        if !extends_named(described, model_name) { continue }
        if described.qualified_name() == model_name { continue }
        let plan: PersistPlan = persist_plan(described)
        for fault: string in plan.faults { problems.push(fault) }
        for binding: PersistBinding in plan.bindings {
            if binding.fault != "" { problems.push(binding.fault) }
        }
    }
    return move problems
}

// ============================================================== pack / restore

/// Read every `@persist` field of `model` into flat text.
pub fn pack_state(model: ViewModel) -> PersistState {
    var state: PersistState = new PersistState()
    let boxed: reflect.Value = reflect.value(model)
    let described: reflect.Type = boxed.type()
    let plan: PersistPlan = persist_plan(described)
    for binding: PersistBinding in plan.bindings {
        if binding.fault != "" { continue }
        match binding.field.get(boxed.copy()) {
            err(problem) => {}
            ok(value) => {
                match binding.kind {
                    text => {
                        match value as? string {
                            some(held) => { state.put(binding.field.name(), held) }
                            none => {}
                        }
                    }
                    integer => {
                        match value as? int {
                            some(held) => { state.put(binding.field.name(), "{held}") }
                            none => {}
                        }
                    }
                    boolean => {
                        match value as? bool {
                            some(held) => { state.put(binding.field.name(), "{held}") }
                            none => {}
                        }
                    }
                    number => {
                        match value as? float {
                            some(held) => { state.put(binding.field.name(), "{held}") }
                            none => {}
                        }
                    }
                    other => {}
                }
            }
        }
    }
    return move state
}

/// Write flat text back onto `model`'s `@persist` fields.
///
/// Answers what could not be written. **Every value here came from a browser**,
/// so a value that does not parse is reported and skipped rather than trusted:
/// the field keeps whatever the model built it with, which is the pristine
/// state — the same place a page with no island starts from.
pub fn restore_state(model: ViewModel, state: PersistState) -> List<string> {
    var problems: List<string> = []
    let boxed: reflect.Value = reflect.value(model)
    let described: reflect.Type = boxed.type()
    let plan: PersistPlan = persist_plan(described)
    for binding: PersistBinding in plan.bindings {
        if binding.fault != "" { continue }
        let name: string = binding.field.name()
        if !state.values.contains_key(name) { continue }
        let raw: string = state.get(name)
        match binding.kind {
            text => {
                let problem: string = report(
                    binding.field.set(boxed.copy(), reflect.value(raw)), name)
                if problem != "" { problems.push(problem) }
            }
            integer => {
                match parse_int(raw) {
                    some(value) => {
                        let problem: string = report(
                            binding.field.set(boxed.copy(), reflect.value(value)), name)
                        if problem != "" { problems.push(problem) }
                    }
                    none => { problems.push("\"{raw}\" is not an int for \"{name}\"") }
                }
            }
            boolean => {
                match parse_bool(raw) {
                    some(value) => {
                        let problem: string = report(
                            binding.field.set(boxed.copy(), reflect.value(value)), name)
                        if problem != "" { problems.push(problem) }
                    }
                    none => { problems.push("\"{raw}\" is not a bool for \"{name}\"") }
                }
            }
            number => {
                match raw.to_float() {
                    ok(value) => {
                        let problem: string = report(
                            binding.field.set(boxed.copy(), reflect.value(value)), name)
                        if problem != "" { problems.push(problem) }
                    }
                    err(_) => { problems.push("\"{raw}\" is not a float for \"{name}\"") }
                }
            }
            other => {}
        }
    }
    return move problems
}

// ============================================================== the wire form

/// One state, as `key=value` pairs joined by `&`.
///
/// Keys are Beans field names, so they need no escaping; values are whatever a
/// user typed, so they do. Three bytes are escaped and no others: `%`, `&` and
/// `=`, which are exactly the three that would otherwise change what the text
/// parses as. Everything else — including every non-ASCII byte — travels as it
/// is, because the island ends up inside an HTML comment and a UTF-8 byte is
/// not special there.
pub fn encode_state(state: PersistState) -> string {
    var keys: List<string> = state.values.keys()
    keys.sort()
    var parts: List<string> = []
    for key: string in keys {
        parts.push("{key}={escape_island(state.get(key))}")
    }
    return parts.join("&")
}

pub fn decode_state(text: string) -> PersistState {
    var state: PersistState = new PersistState()
    if text == "" { return move state }
    for pair: string in text.split("&") {
        match pair.find("=") {
            none => {}
            some(at) => {
                let key: string = pair.slice(0, at)
                let value: string = pair.slice(at + 1, pair.len())
                if key != "" { state.put(key, unescape_island(value)) }
            }
        }
    }
    return move state
}

fn escape_island(text: string) -> string {
    var out: List<string> = []
    for index: int in 0..text.len() {
        let byte: int = text.byte_at(index)
        if byte == 37 { out.push("%25") }
        else if byte == 38 { out.push("%26") }
        else if byte == 61 { out.push("%3D") }
        else { out.push(text.slice(index, index + 1)) }
    }
    return out.join("")
}

fn unescape_island(text: string) -> string {
    var out: List<string> = []
    var index: int = 0
    for index < text.len() {
        if text.byte_at(index) == 37 && index + 2 < text.len() {
            let code: string = text.slice(index + 1, index + 3)
            if code == "25" { out.push("%"); index += 3; continue }
            if code == "26" { out.push("&"); index += 3; continue }
            if code == "3D" { out.push("="); index += 3; continue }
        }
        out.push(text.slice(index, index + 1))
        index += 1
    }
    return out.join("")
}

/// Write a state back onto a component's view-model fields.
///
/// A free function and not a `Renderer` method, because a circuit restores
/// **before** it mounts: the model's fields are set, and then the first render
/// shows them. Restoring after a mount would render the pristine page first and
/// then correct it, which is a flash on a real screen.
///
/// Keys are `<field>.<model field>`, so a page's models are told apart by names
/// the author wrote. Answers what could not be written; every value came from a
/// browser.
pub fn restore_models(component: Component, state: PersistState) -> List<string> {
    var problems: List<string> = []
    let boxed: reflect.Value = reflect.value(component)
    let model_name: string = type_of(ViewModel).qualified_name()
    for field: reflect.Field in boxed.type().fields() {
        if !field.is_public() { continue }
        if !type_of(ViewModel).is_assignable_from(field.type()) { continue }
        if field.type().qualified_name() == model_name { continue }
        match field.get(boxed.copy()) {
            err(problem) => {}
            ok(value) => {
                match value as? ViewModel {
                    none => {}
                    some(model) => {
                        var mine: PersistState = new PersistState()
                        let prefix: string = "{field.name()}."
                        for key: string in state.values.keys() {
                            if key.starts_with(prefix) {
                                mine.put(key.slice(prefix.len(), key.len()),
                                         state.get(key))
                            }
                        }
                        if mine.len() > 0 {
                            for problem: string in restore_state(model, mine) {
                                problems.push("{field.name()}.{problem}")
                            }
                        }
                    }
                }
            }
        }
    }
    return move problems
}

// ============================================================== sealing

/// What a presented island turned out to be.
///
/// The shape mirrors `TokenOutcome`, and for the same reason: the session and
/// the url are inputs to the MAC and are not carried in the island, so an
/// island minted for another session or another page fails the MAC and is
/// `forged` — the same answer an invented one gets.
pub enum IslandOutcome {
    valid
    /// The document carried no island.
    missing
    /// Not `<expiry>.<mac>.<body>` with a whole-number expiry.
    malformed
    /// Genuine, and past its expiry.
    expired
    /// The MAC does not match this session, this url and this expiry.
    forged
    /// Longer than the application allows.
    oversize
}

pub fn describe_island(outcome: IslandOutcome) -> string {
    return match outcome {
        valid => "the island is valid",
        missing => "the document carried no state island",
        malformed => "the state island is malformed",
        expired => "the state island has expired",
        forged => "the state island does not match this session and page",
        oversize => "the state island is larger than this application allows"
    }
}

/// What `open_island` answered.
pub class Island {
    pub outcome: IslandOutcome = IslandOutcome.missing
    pub state: PersistState = new PersistState()
    pub fn init() {}
    pub fn ok() -> bool { return self.outcome == IslandOutcome.valid }
}

/// Seals one page's state for the document.
///
/// `<expiry>.<mac>.<body>`, where the MAC covers the session, the url, the
/// expiry and the body. The body IS carried — unlike the session id in an
/// antiforgery token — because it is the payload: it is the state the page has
/// already rendered, so the document does not learn anything from it that it
/// does not already show.
///
/// **Which is the rule for `@persist`: do not persist a secret.** An island
/// sits in the markup. It is signed so it cannot be *changed*, not so it cannot
/// be *read*.
pub class Islands {
    signer: Signer
    pub options: PersistOptions

    pub fn init(signer: Signer, options: PersistOptions) {
        self.signer = signer
        self.options = options
    }

    fn payload(session: string, url: string, expiry: int, body: string) -> string {
        return "{session}\n{url}\n{expiry}\n{body}"
    }

    /// Seal a state for one session and one url. `""` when there is nothing to
    /// carry — an empty island is a document byte for nothing.
    pub fn seal(state: PersistState, session: string, url: string,
                now: int) -> Result<string, string> {
        if state.len() == 0 { return ok("") }
        let body: string = encode_state(state)
        if body.len() > self.options.max_bytes {
            return err(
                "this page's @persist state is {body.len()} bytes and the limit is {self.options.max_bytes} — persist less, or raise PersistOptions.max_bytes deliberately")
        }
        let expiry: int = now + self.options.seconds
        let mac: string = self.signer.sign(self.payload(session, url, expiry, body))
        return ok("{expiry}.{mac}.{body}")
    }

    /// Open one, or say why not.
    pub fn open(sealed: string, session: string, url: string, now: int) -> Island {
        var answer: Island = new Island()
        if sealed == "" { return move answer }
        if sealed.len() > self.options.max_bytes + 256 {
            answer.outcome = IslandOutcome.oversize
            return move answer
        }
        match sealed.find(".") {
            none => { answer.outcome = IslandOutcome.malformed; return move answer }
            some(first) => {
                let head: string = sealed.slice(0, first)
                let rest: string = sealed.slice(first + 1, sealed.len())
                match rest.find(".") {
                    none => { answer.outcome = IslandOutcome.malformed; return move answer }
                    some(second) => {
                        let mac: string = rest.slice(0, second)
                        let body: string = rest.slice(second + 1, rest.len())
                        match parse_int(head) {
                            none => {
                                answer.outcome = IslandOutcome.malformed
                                return move answer
                            }
                            some(expiry) => {
                                // The MAC is checked BEFORE the expiry, so a
                                // forged island cannot be told from an expired
                                // one by how long the answer takes, and so an
                                // attacker cannot learn that a made-up expiry
                                // was in range.
                                let want: string = self.signer.sign(
                                    self.payload(session, url, expiry, body))
                                if !self.signer.same(want, mac) {
                                    answer.outcome = IslandOutcome.forged
                                    return move answer
                                }
                                if expiry <= now {
                                    answer.outcome = IslandOutcome.expired
                                    return move answer
                                }
                                answer.outcome = IslandOutcome.valid
                                answer.state = decode_state(body)
                                return move answer
                            }
                        }
                    }
                }
            }
        }
    }
}
