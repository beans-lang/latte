// Server actions: a typed call a browser region makes into the server.
//
// A `client` region runs in the browser and the server's code is not there.
// What crosses is a call: a name, arguments, and a reply — and the whole of
// this file exists so that an author writes neither the fetch, nor the JSON,
// nor the endpoint.
//
// ## The shape
//
// ```beans
// @actions(name: "notes")
// pub class NoteActions {
//     store: Notes
//     pub fn init(store: Notes) { self.store = store }
//
//     @action
//     pub fn save(id: int, body: string) -> Result<string, string> { … }
// }
// ```
//
// The class is **server-only**: nothing a browser bundle imports names it, so
// its implementation, its services and its connection strings are not in the
// bundle. What the browser has is the NAME, `"notes.save"`, and a typed
// sender that encodes the arguments and decodes the reply by reflection.
//
// ## What this file will not do
//
// * **It never retries.** Not on a timeout, not on a dropped connection, not
//   on a 500. An action is a mutation until proven otherwise and there is no
//   way for a framework to prove it; a caller that knows its action is safe
//   to repeat can send it again, and that is a decision with a person behind
//   it. So there is no `idempotent` flag either — a flag with no runtime
//   effect is worse than the sentence you are reading.
// * **It never trusts the browser.** Authorization, the antiforgery token and
//   every argument's type are checked here, on the server, for every call.
//   A control the browser hides is not a control.
//
// Nothing here imports std.io, std.fs or std.net. See beans.pot.
package latte

import std.fmt
import std.reflect

/// A group of server actions. `name` is what the wire calls it; empty means
/// the type's simple name.
@target(value: ["type"])
@retention(value: "runtime")
pub annotation actions {
    name: string = ""
}

/// One action. Repeatable authorization, the same AND-across / OR-within rule
/// `@authorize` uses on a page.
@target(value: ["method"])
@retention(value: "runtime")
pub annotation action {
    policy: string = ""
    roles: List<string> = []
}

/// What every action answers under, so a path can never be mistaken for a
/// page's.
pub const ACTION_PREFIX: string = "/_latte/action/"

// ---------------------------------------------------------------- the DTO

/// What crosses in an argument or a reply, worked out once.
///
/// EVERY public scalar field, and not only the annotated ones: a DTO is a
/// record whose whole purpose is to cross, so asking an author to mark each
/// field would be a list that drifts from the fields it mirrors — the same
/// trap `@memo` was built to close.
pub fn dto_plan_for(described: reflect.Type) -> PropsPlan {
    var plan: PropsPlan = new PropsPlan()
    plan.type_name = described.qualified_name()
    for field: reflect.Field in described.fields() {
        if !field.is_public() { continue }
        let kind: ParamKind = props_kind_of(field.type())
        match kind {
            other => {
                plan.faults.push(
                    "{plan.type_name}.{field.name()} is a {field.type().qualified_name()}, which cannot cross a server action; a field of a DTO is a string, an int, a bool or a float")
                continue
            }
            _ => {}
        }
        plan.fields.push(field)
        plan.kinds.push(kind)
        plan.names.push(field.name())
    }
    return move plan
}

/// Whether a type can be an argument or a reply at all.
pub fn crosses(described: reflect.Type) -> bool {
    match props_kind_of(described) {
        other => {}
        _ => { return true }
    }
    // A class of scalars does, and a class with one field that does not
    // cross does not — which `dto_plan_for` says by name.
    return dto_plan_for(described).usable() && described.fields().len() > 0
}

// ---------------------------------------------------------------- the plan

/// One action, resolved: where to call it and what it takes.
pub class ActionPlan {
    /// `"notes.save"` — what the wire carries.
    pub wire_name: string = ""
    pub type_name: string = ""
    pub method_name: string = ""
    pub requirements: List<AuthRequirement> = []
    /// The parameter names, in declaration order, and the type of each.
    pub parameters: List<string> = []
    pub kinds: List<ParamKind> = []
    pub types: List<reflect.Type> = []
    /// The reply's type, and whether it is wrapped in a `Result`.
    pub result_name: string = ""
    pub result_is_result: bool = false
    pub faults: List<string> = []
    described: Option<reflect.Type> = none
    handle: Option<reflect.Method> = none
    pub fn init() {}

    pub fn usable() -> bool { return self.faults.len() == 0 }
    pub fn describes() -> Option<reflect.Type> { return self.described }
    pub fn method() -> Option<reflect.Method> { return self.handle }

    pub fn authorize(who: Principal) -> AuthOutcome {
        return authorize_all(self.requirements, who)
    }
}

/// Every action in the executable, and everything wrong with them.
pub class ActionMap {
    /// The first plan scanned under each wire name. A second one under the
    /// same name refuses both and does not replace this — keeping the later
    /// one would lose the earlier one's refusal and leave one of the two
    /// pretending to be routable.
    pub plans: Map<string, ActionPlan> = {}
    /// Every plan, in scan order, refused ones included. The map's fault
    /// list is built from this at the end, because a clash found by a later
    /// action adds a fault to an earlier one.
    pub all: List<ActionPlan> = []
    pub faults: List<string> = []
    pub fn init() {}

    pub fn find(wire_name: string) -> Option<ActionPlan> {
        match self.plans.get(wire_name) {
            some(plan) => {
                if !plan.usable() { return none }
                return some(plan)
            }
            none => { return none }
        }
    }

    /// Every action name scanned, refused ones included, in name order.
    pub fn names() -> List<string> {
        var out: List<string> = []
        for plan: ActionPlan in self.all {
            if !out.contains(plan.wire_name) { out.push(plan.wire_name) }
        }
        out.sort()
        return move out
    }

    pub fn report() -> string { return self.faults.join(" | ") }
}

/// Read every `@actions` class and the `@action` methods on it.
pub fn scan_actions() -> ActionMap {
    var map: ActionMap = new ActionMap()
    for described: reflect.Type in reflect.types() {
        let group_uses: List<reflect.Annotation> =
            annotations_named(described.annotations(), "actions")
        if group_uses.len() == 0 {
            // An `@action` on a type nothing dispatches is a method that
            // silently never answers, which is the failure mode this whole
            // file is built to avoid.
            for method: reflect.Method in described.methods() {
                if annotations_named(method.annotations(), "action").len() > 0 {
                    map.faults.push(
                        "{described.qualified_name()}.{method.name()} is annotated @action but {described.qualified_name()} is not annotated @actions, so nothing would ever route to it")
                }
            }
            continue
        }
        var group: string = argument_string(group_uses[0], "name")
        if group == "" { group = described.name() }
        if !is_wire_word(group) {
            map.faults.push(
                "{described.qualified_name()} is annotated @actions(name: \"{group}\"); an action group's name reaches a URL path, so it is letters, digits, '-' and '_'")
            continue
        }
        var found: int = 0
        for method: reflect.Method in described.methods() {
            let uses: List<reflect.Annotation> =
                annotations_named(method.annotations(), "action")
            if uses.len() == 0 { continue }
            found += 1
            var plan: ActionPlan = plan_for_action(described, method, uses[0],
                                                   group)
            match map.plans.get(plan.wire_name) {
                some(first) => {
                    // BOTH are refused, for the reason two pages on one route
                    // are: nothing at request time could choose between them,
                    // and refusing only the one scanned second would make the
                    // answer depend on declaration order across files.
                    let message: string = "{plan.type_name}.{plan.method_name} and {first.type_name}.{first.method_name} both answer the action \"{plan.wire_name}\""
                    plan.faults.push(message)
                    first.faults.push(message)
                }
                none => { map.plans[plan.wire_name] = plan }
            }
            map.all.push(plan)
        }
        if found == 0 {
            map.faults.push(
                "{described.qualified_name()} is annotated @actions and declares no @action method, so the group answers nothing")
        }
    }
    // LAST, because a clash found by a later action adds a fault to an
    // earlier plan — which a relay written inside the loop above would
    // already have passed.
    for plan: ActionPlan in map.all {
        for fault: string in plan.faults { map.faults.push(fault) }
    }
    return move map
}

fn plan_for_action(described: reflect.Type, method: reflect.Method,
                   use: reflect.Annotation, group: string) -> ActionPlan {
    var plan: ActionPlan = new ActionPlan()
    plan.type_name = described.qualified_name()
    plan.method_name = method.name()
    plan.wire_name = "{group}.{method.name()}"
    plan.described = some(described)
    plan.handle = some(method)

    // No "the method's name is not a URL word" guard: a Beans identifier is
    // letters, digits and underscores, every one of which `is_wire_word`
    // accepts, so the refusal would be a site no program can reach. The
    // GROUP's name is checked, because an author writes that one.
    if !method.is_public() {
        plan.faults.push(
            "{plan.type_name}.{plan.method_name} is annotated @action but is not public, and reflection does not bypass visibility")
    }
    if method.is_generic() {
        plan.faults.push(
            "{plan.type_name}.{plan.method_name} is annotated @action and is generic; a reflective call cannot name which instantiation to run, so latte could never dispatch it")
    }
    if method.is_static() {
        plan.faults.push(
            "{plan.type_name}.{plan.method_name} is annotated @action and is static; an action group is built by the container so it can hold its services, and a static method has no receiver to build")
    }

    let policy: string = argument_string(use, "policy")
    let roles: List<string> = argument_strings(use, "roles")
    if policy != "" || roles.len() > 0 {
        var requirement: AuthRequirement = new AuthRequirement()
        requirement.policy = policy
        requirement.roles = move roles
        plan.requirements.push(requirement)
    }

    for parameter: reflect.Parameter in method.parameters() {
        let kind: ParamKind = props_kind_of(parameter.type())
        plan.parameters.push(parameter.name())
        plan.kinds.push(kind)
        plan.types.push(parameter.type())
        match kind {
            other => {
                let inner: PropsPlan = dto_plan_for(parameter.type())
                if !inner.usable() || inner.fields.len() == 0 {
                    plan.faults.push(
                        "{plan.type_name}.{plan.method_name}: the parameter \"{parameter.name()}\" is a {parameter.type().qualified_name()}, which cannot cross a server action. A parameter is a string, an int, a bool, a float, or a class whose public fields are all of those")
                }
            }
            _ => {}
        }
    }

    var result: reflect.Type = method.result_type()
    plan.result_name = result.qualified_name()
    let arguments: List<reflect.Type> = result.type_arguments()
    // A `Result` with anything but two arguments is not a shape the language
    // has, so there is no refusal for it: `result` is left as the whole type
    // and the reply check below says it cannot cross, naming it.
    if plan.result_name.starts_with("Result<") && arguments.len() == 2 {
        plan.result_is_result = true
        if arguments[1].qualified_name() != "string" {
            plan.faults.push(
                "{plan.type_name}.{plan.method_name} returns {plan.result_name}; an action's failure crosses as text, so the error side of its Result must be a string")
        }
        result = arguments[0]
    }
    if plan.result_name != "unit" && !crosses(result) {
        plan.faults.push(
            "{plan.type_name}.{plan.method_name} answers a {result.qualified_name()}, which cannot cross a server action. A reply is a string, an int, a bool, a float, or a class whose public fields are all of those")
    }
    // A `Result` whose value is a class is refused, and the reason is a
    // language boundary rather than a policy: latte reads a returned
    // `Result` back with `as?`, which needs the closed type written out, and
    // a dispatcher that only has a `reflect.Type` cannot write one.
    // `reflect.Value` reports a value's type and never its enum variant or
    // its payload, so there is no other way in.
    if plan.result_is_result {
        match props_kind_of(result) {
            other => {
                plan.faults.push(
                    "{plan.type_name}.{plan.method_name} answers {plan.result_name}; latte can read a Result of a string, an int, a bool or a float, and not of a class — reading one back needs the closed type spelled out and a dispatcher only has a descriptor. Answer the {result.qualified_name()} directly and carry the failure in a field of it, or answer a Result of one scalar")
            }
            _ => {}
        }
    }
    return plan
}

/// Letters, digits, `-` and `_`, at least one. An action name reaches a URL
/// path, so it is checked before it is ever put in one.
pub fn is_wire_word(text: string) -> bool {
    if text.len() == 0 { return false }
    for index: int in 0..text.len() {
        let byte: int = text.byte_at(index)
        let letter: bool = (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
        let digit: bool = byte >= 48 && byte <= 57
        if !letter && !digit && byte != 45 && byte != 95 { return false }
    }
    return true
}

// ---------------------------------------------------------------- calling

/// Why an action did not run, as a word the client can branch on.
pub const ACTION_OK: string = "ok"
pub const ACTION_UNKNOWN: string = "unknown"
pub const ACTION_FORBIDDEN: string = "forbidden"
pub const ACTION_STALE: string = "stale"
pub const ACTION_INVALID: string = "invalid"
pub const ACTION_FAILED: string = "failed"
pub const ACTION_REFUSED: string = "refused"

/// Why a call did not answer with a value.
///
/// One class for every failure a caller can see, with the kind as a word
/// rather than a status: a caller branches on "forbidden" and "stale", and
/// the number those arrived as is the transport's business.
pub class ActionError {
    /// One of `unknown`, `forbidden`, `stale`, `invalid`, `failed`,
    /// `refused`, or `offline` when the page never sent the call.
    pub kind: string = ACTION_FAILED
    pub message: string = ""
    pub fn init(kind: string, message: string) {
        self.kind = kind
        self.message = message
    }

    /// Whether sending the same call again could reasonably answer
    /// differently. It is never acted on by latte — nothing here retries —
    /// and it is here so a caller that wants to offer a retry button has one
    /// rule to read rather than a list of kinds to remember.
    pub fn worth_retrying() -> bool {
        return self.kind == "offline" || self.kind == ACTION_REFUSED
    }
}

/// What one call answered.
pub class ActionReply {
    pub kind: string = ACTION_OK
    /// The reply, as JSON, when `kind` is `ok`.
    pub value: string = "null"
    /// What went wrong, in words meant for the person who wrote the caller.
    pub message: string = ""
    pub fn init() {}

    pub fn ok() -> bool { return self.kind == ACTION_OK }

    /// The body that goes on the wire.
    pub fn encode() -> string {
        var out: fmt.StringBuilder = new fmt.StringBuilder()
        out.push("\{\"ok\":")
        if self.ok() { out.push("true") } else { out.push("false") }
        out.push(",\"k\":")
        write_json_string(out, self.kind)
        out.push(",\"v\":")
        out.push(self.value)
        out.push(",\"e\":")
        write_json_string(out, self.message)
        out.push("\}")
        return out.to_string()
    }
}

fn refuse_action(kind: string, message: string) -> ActionReply {
    var out: ActionReply = new ActionReply()
    out.kind = kind
    out.message = message
    return move out
}

/// Where an action group comes from, and who is asking.
///
/// An interface over the two things the core cannot have — a container and a
/// principal — so `latte.web` can dispatch without the core learning what
/// either is.
pub class ActionRequest {
    pub name: string = ""
    /// The arguments, as the JSON object the client sent.
    pub arguments: string = "\{\}"
    pub who: Principal = new Anonymous()
    /// The antiforgery token the caller presented, and the session it is
    /// bound to. Both checked by the host before this reaches `run`.
    pub token: string = ""
    pub session: string = ""
    pub fn init() {}
}

/// Dispatch one action against a map.
///
/// The antiforgery check is NOT here: it needs the application's signer and
/// its clock, neither of which the core has. `latte.web` does it before
/// calling this and answers `stale` on its own. Everything else — the name,
/// the authorization, the arguments, the call — is here, so a host that is
/// not espresso gets the same rules.
pub fn run_action(map: ActionMap, request: ActionRequest,
                  activator: Option<Activator>) -> ActionReply {
    match map.find(request.name) {
        none => {
            return refuse_action(ACTION_UNKNOWN,
                "no action is named \"{request.name}\"")
        }
        some(plan) => {
            let outcome: AuthOutcome = plan.authorize(request.who)
            match outcome {
                allow => {}
                _ => {
                    return refuse_action(ACTION_FORBIDDEN,
                        "{plan.wire_name}: {describe_outcome(outcome)}")
                }
            }
            var root: Json = new Json()
            match parse_json(request.arguments, props_limits()) {
                err(problem) => {
                    return refuse_action(ACTION_INVALID,
                        "{plan.wire_name}: the arguments are not JSON: {problem}")
                }
                ok(parsed) => { root = parsed }
            }
            if !root.is_object() {
                return refuse_action(ACTION_INVALID,
                    "{plan.wire_name}: the arguments must be a JSON object")
            }
            var arguments: List<reflect.Value> = []
            var index: int = 0
            for index < plan.parameters.len() {
                match read_argument(plan, index, root) {
                    err(problem) => { return refuse_action(ACTION_INVALID, problem) }
                    ok(value) => { arguments.push(value) }
                }
                index += 1
            }
            match build_group(plan, activator) {
                err(problem) => { return refuse_action(ACTION_REFUSED, problem) }
                ok(receiver) => {
                    match plan.method() {
                        none => {
                            return refuse_action(ACTION_REFUSED,
                                "{plan.wire_name} has no method descriptor")
                        }
                        some(method) => {
                            match method.call(receiver, move arguments) {
                                err(problem) => {
                                    return refuse_action(ACTION_REFUSED,
                                        "{plan.wire_name}: {problem.message()}")
                                }
                                ok(answer) => { return read_answer(plan, answer) }
                            }
                        }
                    }
                }
            }
        }
    }
}

fn read_argument(plan: ActionPlan, index: int,
                 root: Json) -> Result<reflect.Value, string> {
    let name: string = plan.parameters[index]
    let kind: ParamKind = plan.kinds[index]
    match root.field(name) {
        none => {
            return err("{plan.wire_name}: the argument \"{name}\" is missing")
        }
        some(value) => {
            match kind {
                text => {
                    if !value.is_text() {
                        return err("{plan.wire_name}: \"{name}\" is not a string")
                    }
                    return ok(reflect.value(value.text))
                }
                integer => {
                    if !value.is_int() {
                        return err("{plan.wire_name}: \"{name}\" is not an int")
                    }
                    return ok(reflect.value(value.number))
                }
                boolean => {
                    if value.kind != JSON_BOOL {
                        return err("{plan.wire_name}: \"{name}\" is not a bool")
                    }
                    return ok(reflect.value(value.truth))
                }
                number => {
                    if !value.is_number() {
                        return err("{plan.wire_name}: \"{name}\" is not a number")
                    }
                    return ok(reflect.value(value.as_float()))
                }
                other => {
                    if !value.is_object() {
                        return err("{plan.wire_name}: \"{name}\" is a {plan.types[index].qualified_name()} and must be a JSON object")
                    }
                    let described: reflect.Type = plan.types[index]
                    match activate_type(described) {
                        err(problem) => {
                            return err("{plan.wire_name}: \"{name}\": {problem}")
                        }
                        ok(made) => {
                            let inner: PropsPlan = dto_plan_for(described)
                            let problems: List<string> =
                                decode_props(made.copy(), inner, value)
                            if problems.len() > 0 {
                                return err("{plan.wire_name}: \"{name}\": {problems.join("; ")}")
                            }
                            return ok(made)
                        }
                    }
                }
            }
        }
    }
}

fn build_group(plan: ActionPlan,
               activator: Option<Activator>) -> Result<reflect.Value, string> {
    match plan.describes() {
        none => { return err("{plan.wire_name} has no type descriptor") }
        some(described) => {
            match activator {
                some(container) => {
                    match container.make(described) {
                        ok(made) => { return ok(made) }
                        err(problem) => {
                            return err("cannot build {plan.type_name}: {problem}")
                        }
                    }
                }
                none => { return activate_type(described) }
            }
        }
    }
}

/// Turn what the method returned into a reply.
fn read_answer(plan: ActionPlan, answer: reflect.Value) -> ActionReply {
    var value: reflect.Value = answer.copy()
    if plan.result_is_result {
        match answer.copy() as? Result<string, string> {
            some(text) => {
                match text {
                    ok(held) => { return plain_reply(json_of_text(held)) }
                    err(problem) => { return refuse_action(ACTION_FAILED, problem) }
                }
            }
            none => {}
        }
        match answer.copy() as? Result<int, string> {
            some(number) => {
                match number {
                    ok(held) => { return plain_reply("{held}") }
                    err(problem) => { return refuse_action(ACTION_FAILED, problem) }
                }
            }
            none => {}
        }
        match answer.copy() as? Result<bool, string> {
            some(flag) => {
                match flag {
                    ok(held) => { return plain_reply(if held { "true" } else { "false" }) }
                    err(problem) => { return refuse_action(ACTION_FAILED, problem) }
                }
            }
            none => {}
        }
        match answer.copy() as? Result<float, string> {
            some(decimal) => {
                match decimal {
                    ok(held) => { return plain_reply("{held}") }
                    err(problem) => { return refuse_action(ACTION_FAILED, problem) }
                }
            }
            none => {}
        }
        // A `Result` of a DTO. There is no way to name it without the type,
        // so the host that scanned the action is the one that knows: it is
        // refused at startup unless the payload is one of the four above or
        // a class, and a class arrives here as a Value of its own type.
        return refuse_action(ACTION_REFUSED,
            "{plan.wire_name} answers {plan.result_name}, which latte cannot read back. A Result action answers a string, an int, a bool or a float")
    }
    if plan.result_name == "unit" { return plain_reply("null") }
    return plain_reply(encode_reply(value))
}

fn plain_reply(payload: string) -> ActionReply {
    var out: ActionReply = new ActionReply()
    out.value = payload
    return move out
}

fn json_of_text(text: string) -> string {
    var out: fmt.StringBuilder = new fmt.StringBuilder()
    write_json_string(out, text)
    return out.to_string()
}

/// One reply value as JSON: a scalar as itself, a class as an object.
pub fn encode_reply(value: reflect.Value) -> string {
    let described: reflect.Type = value.type()
    match props_kind_of(described) {
        text => {
            match value.copy() as? string {
                some(held) => { return json_of_text(held) }
                none => { return "null" }
            }
        }
        integer => {
            match value.copy() as? int {
                some(held) => { return "{held}" }
                none => { return "null" }
            }
        }
        boolean => {
            match value.copy() as? bool {
                some(held) => { if held { return "true" } return "false" }
                none => { return "null" }
            }
        }
        number => {
            match value.copy() as? float {
                some(held) => { return "{held}" }
                none => { return "null" }
            }
        }
        other => {
            var faults: List<string> = []
            return encode_props(value.copy(), dto_plan_for(described), faults)
        }
    }
}
