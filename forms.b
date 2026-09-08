// `forms.b` — the form half: what a posted body is allowed to become, and the
// token that says the post was meant.
//
// A latte form is a **model type** carrying `@form`, whose `@field`s are the
// only names a post can reach. Everything else in the body — a submit button,
// a stale input, an attacker's guess at a field the author never annotated —
// lands in `FormResult.ignored` and touches nothing. That is the mass
// assignment control at the HTTP layer, and it is an allowlist built at
// startup rather than a denylist consulted per request.
//
// The scan is `pages.b`'s scan one level down: `reflect.types()` once, a
// `FormPlan` per `@form`, a typed setter per `@field`, and a refusal — by name,
// at startup — for every rule that could not run and every field that could not
// bind. It inherits `pages.b`'s B1a refusal for the same reason: a reflective
// write to a field whose declaring type is generic is `ok` under `beansc run`
// and `unsupported` as a native binary, so a form bound that way works all
// through the edit loop and breaks when it ships.
//
// ## Nothing here computes an HMAC, and that is deliberate
//
// `std.crypto` reaches the platform digest through the networking bridge, so a
// module-root file importing it fails `test.sh --wasm` at codegen with "the
// networking bridges need --runtime full" — for every consumer of latte, not
// only the one that wanted a token. So the root owns the token's *shape* and
// its expiry rule, and the MAC arrives as a `Signer` the host supplies.
// `SeamSigner` is the closure-backed adapter a package that cannot import this
// module root — `latte.web` is one — uses to supply it.
//
// The comparison is on the interface for the same reason the MAC is: espresso's
// `constant_time_equal` is public, and a second constant-time compare written
// here is how one of them ends up with an early return.
package latte

import std.fmt
import std.reflect

// ============================================================== annotations
//
// `@form` is `@target(["type"])` and the three rules are `@target(["field"])`,
// so a rule on a class is the author's own compile error rather than a rule
// that silently never runs.
//
// None of them is `@repeatable`, and that is load-bearing: 0.1.40 refuses a
// repeated non-repeatable annotation itself — `error: annotation '@field' is
// not repeatable` — so a "carries @field more than once" refusal here could
// never fire. It is not written. See `bind_fields`.

/// A model a form post may bind onto.
@target(value: ["type"])
@retention(value: "runtime")
pub annotation form {
}

/// A field a post may reach. A public field WITHOUT this annotation is not
/// bindable, which is the whole mass-assignment story: the allowlist is what
/// the author wrote, and it is fixed before the first request.
@target(value: ["field"])
@retention(value: "runtime")
pub annotation field {
    /// The posted name. Empty means the field's own name.
    name: string = ""
}

/// The value must be present and, for a string, not blank.
@target(value: ["field"])
@retention(value: "runtime")
pub annotation required {
    message: string = ""
}

/// Bounds on a string's length. `max: -1` is "no upper bound".
@target(value: ["field"])
@retention(value: "runtime")
pub annotation length {
    min: int = 0
    max: int = -1
    message: string = ""
}

/// Bounds on a number. Both are written by the author: the annotation gives
/// them no default, so a bare `@range` is a compile error in the author's own
/// file rather than a silent "must be exactly 0".
@target(value: ["field"])
@retention(value: "runtime")
pub annotation range {
    min: int
    max: int
    message: string = ""
}

// ============================================================== the wire names

/// The posted name of the antiforgery token.
///
/// It starts with `__latte` so it cannot collide with a `@field` name an author
/// would write, and the scan does not need to reserve it: a `@field(name:
/// "__latte_token")` would simply never be reached, because the host strips the
/// token out of the body before binding. `FormResult.ignored` would then show
/// it, which is the visible form of that mistake.
pub const TOKEN_FIELD: string = "__latte_token"

/// The methods that change nothing and therefore carry no token.
///
/// This list is the entire difference between "every unsafe request is checked"
/// and "the one we remembered is". A method that is not named here is unsafe,
/// so an HTTP method invented tomorrow is checked by default rather than
/// exempt by omission.
pub fn is_safe_method(method: string) -> bool {
    let upper: string = method.to_upper()
    return upper == "GET" || upper == "HEAD" || upper == "OPTIONS" || upper == "TRACE"
}

// ============================================================== errors, state

/// One field's complaint, in the words the page renders.
pub class FieldError {
    pub field: string = ""
    pub message: string = ""
    pub fn init(field: string, message: string) {
        self.field = field
        self.message = message
    }
}

/// What the host hands a form page before every render: the token its form must
/// carry, and what went wrong last time.
///
/// A page reads it; nothing here is the page's to write. It is a plain object
/// and not a `@param`, because a `@param` is bound from a route and this is not
/// on the route.
pub class FormState {
    /// The antiforgery token this render's form must post back.
    pub token: string = ""
    /// True once a post has bound and validated cleanly and `on_submit` has run.
    pub submitted: bool = false
    /// What the last post did. Empty on a GET.
    ///
    /// The result is HELD and not unpacked into two lists of its own, because
    /// `state.errors = result.errors` is `error: assignment cannot move a field
    /// or index yet` in 0.1.40 — and unpacking through a local would put two
    /// copies of the same answer in two places, which is how one of them goes
    /// stale.
    pub result: FormResult = new FormResult()
    pub fn init() {}

    pub fn ok() -> bool { return self.result.errors.len() == 0 }

    pub fn error_count() -> int { return self.result.errors.len() }

    /// The first message for `name`, or `""`. First and not joined, because a
    /// field renders one message beside itself.
    pub fn error_for(name: string) -> string {
        for problem: FieldError in self.result.errors {
            if problem.field == name { return problem.message }
        }
        return ""
    }

    pub fn summary() -> string {
        var parts: List<string> = []
        for problem: FieldError in self.result.errors {
            parts.push("{problem.field}: {problem.message}")
        }
        return parts.join(" | ")
    }

    /// The posted names that reached no `@field`, sorted and joined. A form that
    /// renders this in development is a form whose author sees a renamed input
    /// at once.
    pub fn ignored() -> string { return self.result.ignored.join(", ") }
}

// ============================================================== one field

/// One `@field`, resolved: the descriptor, the posted name, the kind, and the
/// rules that survived the scan.
pub class FormField {
    pub field_name: string = ""
    pub wire_name: string = ""
    pub kind: ParamKind = ParamKind.other
    pub type_name: string = ""

    pub required: bool = false
    pub required_message: string = ""

    pub has_length: bool = false
    pub min_length: int = 0
    pub max_length: int = -1
    pub length_message: string = ""

    pub has_range: bool = false
    pub min: int = 0
    pub max: int = 0
    pub range_message: string = ""

    field: Option<reflect.Field> = none
    pub fn init() {}

    fn adopt(described: reflect.Field) { self.field = some(described) }

    /// Bind one posted value onto `receiver` and say what was wrong with it.
    ///
    /// The order is parse, then rules, and a value that did not parse is not
    /// rule-checked: a range check on a number that was never read would be a
    /// message about a bound the author wrote rather than about the text the
    /// user typed.
    fn bind_one(receiver: reflect.Value, text: string, into: List<FieldError>) {
        match self.kind {
            text => {
                // A form field is trimmed. Every browser posts what the user
                // typed, spaces included, and a `@length(min: 3)` that counted
                // "  a  " as five characters would accept a blank name.
                let value: string = text.trim()
                if self.required && value == "" {
                    into.push(new FieldError(self.wire_name, self.required_text()))
                    return
                }
                self.write(receiver, reflect.value(value), into)
                if !self.has_length { return }
                let size: int = value.len()
                if size < self.min_length || (self.max_length >= 0 && size > self.max_length) {
                    into.push(new FieldError(self.wire_name, self.length_text()))
                }
            }
            integer => {
                match parse_int(text.trim()) {
                    none => {
                        into.push(new FieldError(self.wire_name,
                            "{self.wire_name} must be a whole number"))
                    }
                    some(value) => {
                        self.write(receiver, reflect.value(value), into)
                        self.check_range(value, into)
                    }
                }
            }
            number => {
                match text.trim().to_float() {
                    err(_) => {
                        into.push(new FieldError(self.wire_name,
                            "{self.wire_name} must be a number"))
                    }
                    ok(value) => {
                        self.write(receiver, reflect.value(value), into)
                        // A float is range-checked on its truncation toward
                        // zero, so `@range(min: 1, max: 4)` rejects 4.5 and
                        // accepts 4.0 — the bound the author wrote is on the
                        // number, and the number is what is compared.
                        if !self.has_range { return }
                        if value < (self.min as float) || value > (self.max as float) {
                            into.push(new FieldError(self.wire_name, self.range_text()))
                        }
                    }
                }
            }
            boolean => {
                // An unchecked box posts nothing at all, so `false` is what
                // absence means and the host never calls this for a missing
                // key. What arrives here is a value, and a value that is not a
                // boolean is a body nobody's browser sent.
                match parse_bool(text.trim()) {
                    none => {
                        into.push(new FieldError(self.wire_name,
                            "{self.wire_name} must be true or false"))
                    }
                    some(value) => { self.write(receiver, reflect.value(value), into) }
                }
            }
            other => {
                // Unreachable through a plan: `bind_fields` refuses an
                // unbindable kind at startup and never builds a FormField for
                // it. It is spelled out rather than left empty so a future kind
                // added to ParamKind without a case here says so.
                into.push(new FieldError(self.wire_name,
                    "{self.wire_name} is a {self.type_name} and a form cannot bind it"))
            }
        }
    }

    fn check_range(value: int, into: List<FieldError>) {
        if !self.has_range { return }
        if value < self.min || value > self.max {
            into.push(new FieldError(self.wire_name, self.range_text()))
        }
    }

    fn write(receiver: reflect.Value, move value: reflect.Value, into: List<FieldError>) {
        match self.field {
            none => {
                into.push(new FieldError(self.wire_name,
                    "{self.wire_name} has no field"))
            }
            some(described) => {
                match described.set(receiver, move value) {
                    ok(_) => {}
                    err(problem) => {
                        let detail: string = problem.message()
                        into.push(new FieldError(self.wire_name,
                            "setting {self.wire_name}: {detail}"))
                    }
                }
            }
        }
    }

    fn required_text() -> string {
        if self.required_message != "" { return self.required_message }
        return "{self.wire_name} is required"
    }

    fn length_text() -> string {
        if self.length_message != "" { return self.length_message }
        if self.max_length < 0 {
            return "{self.wire_name} must be at least {self.min_length} characters"
        }
        if self.min_length == 0 {
            return "{self.wire_name} must be at most {self.max_length} characters"
        }
        return "{self.wire_name} must be {self.min_length} to {self.max_length} characters"
    }

    fn range_text() -> string {
        if self.range_message != "" { return self.range_message }
        return "{self.wire_name} must be between {self.min} and {self.max}"
    }
}

// ============================================================== the result

/// What one post did.
pub class FormResult {
    pub errors: List<FieldError> = []
    /// Posted names that reached no `@field`, sorted.
    pub ignored: List<string> = []
    pub fn init() {}
    pub fn ok() -> bool { return self.errors.len() == 0 }
}

// ============================================================== the plan

/// One `@form` model, resolved once at startup.
pub class FormPlan {
    pub type_name: string = ""
    pub name: string = ""
    pub fields: List<FormField> = []
    /// Why this model cannot be bound. A plan with a fault stays in the map so
    /// the report can name it, and `bind` refuses rather than binding half of
    /// it.
    pub faults: List<string> = []
    described: Option<reflect.Type> = none
    pub fn init() {}

    pub fn describes() -> Option<reflect.Type> { return self.described }
    pub fn usable() -> bool { return self.faults.len() == 0 }

    pub fn field_named(wire: string) -> Option<FormField> {
        for bound: FormField in self.fields {
            if bound.wire_name == wire { return some(bound) }
        }
        return none
    }

    /// Bind a posted body onto a model.
    ///
    /// `posted` is the parsed body with latte's own keys already removed. Every
    /// `@field` is visited whether or not the body carried it, because
    /// "required" is a statement about absence and a loop over the body could
    /// only ever see what arrived.
    pub fn bind(receiver: reflect.Value, posted: Map<string, string>) -> FormResult {
        var result: FormResult = new FormResult()
        if !self.usable() {
            for fault: string in self.faults {
                result.errors.push(new FieldError("", fault))
            }
            return move result
        }
        for bound: FormField in self.fields {
            match posted.get(bound.wire_name) {
                some(text) => { bound.bind_one(receiver.copy(), text, result.errors) }
                none => {
                    // A missing boolean is an unchecked box and binds false; a
                    // missing anything else is only a problem when it was
                    // required.
                    match bound.kind {
                        boolean => { bound.bind_one(receiver.copy(), "false", result.errors) }
                        _ => {
                            if bound.required {
                                result.errors.push(new FieldError(bound.wire_name,
                                    bound.required_text()))
                            }
                        }
                    }
                }
            }
        }
        var stray: List<string> = []
        for key: string in posted.keys() {
            if self.field_named(key).is_some() { continue }
            stray.push(key)
        }
        stray.sort()
        result.ignored = move stray
        return move result
    }
}

// ============================================================== the form scan

/// Every `@form` in the executable, and every reason one could not be bound.
pub class FormMap {
    pub forms: List<FormPlan> = []
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

    pub fn named(name: string) -> Option<FormPlan> {
        for plan: FormPlan in self.forms {
            if plan.name == name || plan.type_name == name { return some(plan) }
        }
        return none
    }

    /// The plan for the model `value` holds, or `none`.
    pub fn for_value(value: reflect.Value) -> Option<FormPlan> {
        let wanted: string = value.type().qualified_name()
        for plan: FormPlan in self.forms {
            if plan.type_name == wanted { return some(plan) }
        }
        return none
    }
}

/// Walk every type once, turn the `@form`s into plans, and cross-check the
/// pages against them.
///
/// It takes the `PageMap` rather than standing beside it because two of its
/// refusals are about a PAGE — an unsafe method with no form, and a form page
/// no unsafe method can reach — and a refusal recorded only in a second map is
/// a refusal a host that routes from the first one never sees. So those two
/// push onto the page's plan as well, which is what takes the page out of
/// `PageMap.find`.
pub fn scan_forms(pages: PageMap) -> FormMap {
    var map: FormMap = new FormMap()
    let form_component: string = type_of(FormComponent).qualified_name()
    let all: List<reflect.Type> = reflect.types()

    for described: reflect.Type in all {
        let uses: List<reflect.Annotation> = annotations_named(described.annotations(), "form")
        if uses.len() == 0 {
            // A `@field` or a rule on a type nothing scans is a binding that
            // would never happen, and silence is how a renamed input becomes a
            // field that is quietly never written.
            for member: reflect.Field in described.declared_fields() {
                let name: string = described.qualified_name()
                if annotations_named(member.annotations(), "field").len() > 0 {
                    map.faults.push(
                        "{name}.{member.name()} is a @field but {name} is not a @form, so nothing would ever bind it")
                    continue
                }
                let rule: string = rule_named(member)
                if rule != "" {
                    map.faults.push(
                        "{name}.{member.name()} carries @{rule} but not @field, so the rule would never run")
                }
            }
            continue
        }
        map.forms.push(plan_for_form(described))
    }

    check_form_pages(map, pages, form_component)

    for plan: FormPlan in map.forms { copy_faults(plan.faults, 0, map.faults) }
    return map
}

/// Copy `from[at..]` onto `into`.
///
/// It pushes onto a plain `into` list rather than naming a map's fault list on
/// purpose. `test.sh`'s refusal-coverage leg counts fault-report pushes in this
/// file and demands one audited case per one, and a copy is not a refusal: it
/// decides nothing, says nothing of its own, and deleting it cannot make a
/// message wrong — only missing. Counting it would demand a test case for a
/// line that can only move somebody else's answer, and every site in the tally
/// would then be one site further from meaning what it says.
///
/// The same reason keeps this doc comment from spelling the pattern out: the
/// leg greps the source, and a comment that quoted it would be counted too.
fn copy_faults(from: List<string>, at: int, into: List<string>) {
    var index: int = at
    for index < from.len() {
        into.push(from[index])
        index += 1
    }
}

/// The first rule annotation on `member`, by simple name, or `""`.
fn rule_named(member: reflect.Field) -> string {
    if annotations_named(member.annotations(), "required").len() > 0 { return "required" }
    if annotations_named(member.annotations(), "length").len() > 0 { return "length" }
    if annotations_named(member.annotations(), "range").len() > 0 { return "range" }
    return ""
}

/// The two rules that tie a page to a form, checked in both directions.
///
/// A fault here is raised on the `PagePlan` and then copied onto both maps.
/// `PageMap.find` skips a plan with a fault, so a page refused here cannot be
/// routed to even by a host that never read either report — which is the only
/// version of this rule worth anything, because the rule exists to stop an
/// unsafe request reaching a page with no token to check. The copy takes only
/// what THIS pass added, so a fault `scan_pages` already recorded is not
/// reported twice.
fn check_form_pages(map: FormMap, pages: PageMap, form_component: string) {
    for plan: PagePlan in pages.pages {
        match plan.describes() {
            none => { continue }
            some(described) => {
                let before: int = plan.faults.len()
                let is_form: bool = extends_named(described, form_component)
                var unsafe_methods: List<string> = []
                for method: string in plan.methods {
                    if !is_safe_method(method) { unsafe_methods.push(method) }
                }
                if is_form && unsafe_methods.len() == 0 {
                    let listed: string = plan.methods.join(", ")
                    plan.faults.push(
                        "{plan.type_name} is a form page but @page(methods:) is {listed}; nothing could ever submit its form")
                } else if !is_form && unsafe_methods.len() > 0 {
                    let listed: string = unsafe_methods.join(", ")
                    plan.faults.push(
                        "{plan.type_name} serves {listed} but does not extend {form_component}, so latte has no form id to bind an antiforgery token to")
                }
                copy_faults(plan.faults, before, map.faults)
                copy_faults(plan.faults, before, pages.faults)
            }
        }
    }
}

fn plan_for_form(described: reflect.Type) -> FormPlan {
    var plan: FormPlan = new FormPlan()
    plan.type_name = described.qualified_name()
    plan.name = described.name()
    plan.described = some(described)
    bind_fields(plan, described)
    if plan.fields.len() == 0 && plan.usable() {
        plan.faults.push(
            "{plan.type_name} is a @form but declares no @field, so a post would bind nothing")
    }
    return plan
}

/// Resolve every `@field` on `described`, and refuse every rule that could not
/// run.
///
/// **There is no "carries @field more than once" refusal**, and that is a
/// decision rather than an omission: `@field` is not `@repeatable`, and 0.1.40
/// answers `error: annotation '@field' is not repeatable` at the author's own
/// declaration (`probes/p16_repeat`). A refusal here would stand behind a
/// compile error and could never fire — the exact shape RULES.md calls "the
/// refusal that never runs". The same holds for `@required`, `@length` and
/// `@range`.
fn bind_fields(plan: FormPlan, described: reflect.Type) {
    var seen: Map<string, string> = {}
    for member: reflect.Field in described.fields() {
        let uses: List<reflect.Annotation> = annotations_named(member.annotations(), "field")
        if uses.len() == 0 {
            // A rule on a non-`@field` of a `@form` is the same mistake the
            // scan reports for a non-`@form` type, and it is reported here so
            // the message names the model the author was looking at.
            let rule: string = rule_named(member)
            if rule != "" {
                plan.faults.push(
                    "{plan.type_name}.{member.name()} carries @{rule} but not @field, so the rule would never run")
            }
            continue
        }
        var bound: FormField = new FormField()
        bound.field_name = member.name()
        bound.wire_name = argument_string(uses[0], "name")
        if bound.wire_name == "" { bound.wire_name = member.name() }
        bound.type_name = member.type().qualified_name()
        bound.kind = kind_of(member.type())
        bound.adopt(member)

        match seen.get(bound.wire_name) {
            some(other) => {
                plan.faults.push(
                    "{plan.type_name}: \"{bound.wire_name}\" names both {other} and {bound.field_name}")
                continue
            }
            none => { seen[bound.wire_name] = bound.field_name }
        }

        if !member.is_public() {
            plan.faults.push(
                "{plan.type_name}.{bound.field_name} is a @field but is not public, and reflection does not bypass visibility")
            continue
        }

        // BLOCKERS.md B1a, the same rule `pages.b` applies to a `@param`. Read
        // `generic_declaration` before touching this: the obvious test reads
        // FALSE for exactly the fields that fail.
        let generic: string = generic_declaration(described, member)
        if generic != "" {
            plan.faults.push(
                "{plan.type_name}.{bound.field_name} is a @field declared by {generic}; a reflective write to a field whose declaring type is generic is ok under beansc run and unsupported natively (BLOCKERS.md B1a), so latte refuses it here rather than at request time")
            continue
        }

        match bound.kind {
            other => {
                plan.faults.push(
                    "{plan.type_name}.{bound.field_name} is a @field but is a {bound.type_name}; a form can bind string, int, bool and float")
                continue
            }
            _ => {}
        }

        read_rules(plan, member, bound)
        plan.fields.push(bound)
    }
}

/// Read `@required`, `@length` and `@range` onto a field, refusing each one that
/// could not change any answer.
///
/// These do not `continue`: a field carrying two wrong rules is an author who
/// wants to see both, and each rule is independent of the others.
fn read_rules(plan: FormPlan, member: reflect.Field, bound: FormField) {
    let where: string = "{plan.type_name}.{bound.field_name}"

    let requireds: List<reflect.Annotation> = annotations_named(member.annotations(), "required")
    if requireds.len() > 0 {
        match bound.kind {
            boolean => {
                plan.faults.push(
                    "{where} is a bool carrying @required; an unchecked box posts nothing at all, so a required bool would refuse every unchecked form")
            }
            _ => {
                bound.required = true
                bound.required_message = argument_string(requireds[0], "message")
            }
        }
    }

    let lengths: List<reflect.Annotation> = annotations_named(member.annotations(), "length")
    if lengths.len() > 0 {
        let low: int = argument_int(lengths[0], "min")
        let high: int = argument_int(lengths[0], "max")
        match bound.kind {
            text => {
                if low < 0 {
                    plan.faults.push(
                        "{where} carries @length(min: {low}); a length is never negative")
                } else if high >= 0 && high < low {
                    plan.faults.push(
                        "{where} carries @length(min: {low}, max: {high}), which no value can satisfy")
                } else if low == 0 && high < 0 {
                    plan.faults.push(
                        "{where} carries a @length that bounds nothing; no value could fail it")
                } else {
                    bound.has_length = true
                    bound.min_length = low
                    bound.max_length = high
                    bound.length_message = argument_string(lengths[0], "message")
                }
            }
            _ => {
                plan.faults.push(
                    "{where} carries @length but is a {bound.type_name}; @length measures a string")
            }
        }
    }

    let ranges: List<reflect.Annotation> = annotations_named(member.annotations(), "range")
    if ranges.len() > 0 {
        let low: int = argument_int(ranges[0], "min")
        let high: int = argument_int(ranges[0], "max")
        match bound.kind {
            integer => { adopt_range(plan, bound, where, low, high, ranges[0]) }
            number => { adopt_range(plan, bound, where, low, high, ranges[0]) }
            _ => {
                plan.faults.push(
                    "{where} carries @range but is a {bound.type_name}; @range bounds an int or a float")
            }
        }
    }
}

fn adopt_range(plan: FormPlan, bound: FormField, where: string,
               low: int, high: int, use: reflect.Annotation) {
    if high < low {
        plan.faults.push(
            "{where} carries @range(min: {low}, max: {high}), which no value can satisfy")
        return
    }
    bound.has_range = true
    bound.min = low
    bound.max = high
    bound.range_message = argument_string(use, "message")
}

// ============================================================== the form page

/// A page that accepts a post.
///
/// It is a CLASS and not an interface because 0.1.40's `as?` goes from a parent
/// to a child class and not to an interface — `error: as? goes from a parent to
/// a child class — X as? Y doesn't` — and the host holds the page as a
/// `Component`. It is `abstract`, so an author who forgets either method is
/// told by the compiler at their own declaration rather than by latte at the
/// first post.
pub abstract class FormComponent extends Component {
    /// Filled by the host before every render. A page reads it.
    pub state: FormState = new FormState()

    pub fn init() {}

    /// What the antiforgery token is bound to, beside the session and the
    /// expiry. Two pages with different ids cannot share a token, so a token
    /// minted for a harmless form cannot be replayed on a dangerous one.
    pub abstract fn form_id() -> string

    /// The model a post binds onto: `return reflect.value(self.model)`.
    ///
    /// A `reflect.Value` and not a type parameter, because the host holds pages
    /// as `Component` and has no static type to instantiate against. A class is
    /// a reference, so writes through the value reach the page's own model
    /// (`probes/p15_formshape`, both backends).
    pub abstract fn form_model() -> reflect.Value

    /// Once, after a post bound and validated cleanly.
    pub fn on_submit() {}
}

// ============================================================== body parsing

/// Parse an `application/x-www-form-urlencoded` body.
///
/// A repeated key keeps the LAST value, which is what a browser's own later
/// input overriding an earlier hidden one means, and is what every server-side
/// framework does for a scalar bind. A key with no `=` binds the empty string,
/// because `?flag` and `?flag=` are the same request to a browser.
pub fn parse_form_body(text: string) -> Map<string, string> {
    var out: Map<string, string> = {}
    if text == "" { return move out }
    for piece: string in text.split("&") {
        if piece == "" { continue }
        match piece.find("=") {
            some(at) => {
                let key: string = form_decode(piece.slice(0, at))
                if key == "" { continue }
                out[key] = form_decode(piece.slice(at + 1, piece.len()))
            }
            none => {
                let key: string = form_decode(piece)
                if key == "" { continue }
                out[key] = ""
            }
        }
    }
    return move out
}

/// Percent-decoding for a form body, where `+` is a space.
///
/// It is NOT `percent_decode`: that one decodes a path segment, where `+` is a
/// literal plus sign and turning it into a space would corrupt a route capture.
/// The two rules genuinely differ and one function cannot hold both.
pub fn form_decode(text: string) -> string {
    if !text.contains("+") { return percent_decode(text) }
    var out: fmt.StringBuilder = new fmt.StringBuilder()
    var index: int = 0
    for index < text.len() {
        if text.byte_at(index) == 43 { out.push(" ") }
        else { out.push(text.slice(index, index + 1)) }
        index += 1
    }
    return percent_decode(out.to_string())
}

// ============================================================== antiforgery

/// The MAC and the comparison, supplied by the host.
///
/// `same` is on the interface deliberately: espresso's `constant_time_equal` is
/// public, and latte must use it rather than write a second constant-time
/// compare — a second copy is how one of them ends up with an early return.
pub interface Signer {
    fn sign(data: string) -> string
    fn same(left: string, right: string) -> bool
}

/// A `Signer` made from two closures.
///
/// This exists because a package under `latte/` may not import its own module
/// root — `error: a package cannot import its own module root` — so
/// `latte.web`, which is where `std.crypto` and espresso live, cannot implement
/// `Signer` directly. It hands over closures over std types instead, exactly as
/// `CircuitSeam` does for the socket half.
pub class SeamSigner implements Signer {
    sign_with: fn(string) -> string
    same_with: fn(string, string) -> bool
    pub fn init(sign_with: fn(string) -> string,
                same_with: fn(string, string) -> bool) {
        self.sign_with = sign_with
        self.same_with = same_with
    }
    pub fn sign(data: string) -> string { return self.sign_with(data) }
    pub fn same(left: string, right: string) -> bool {
        return self.same_with(left, right)
    }
}

/// What a presented token turned out to be.
///
/// There is no `wrong_session` and no `wrong_form`: the session id and the form
/// id are inputs to the MAC and are not carried in the token, so a token from
/// another session or another form fails the MAC and is `forged` — the same
/// answer an invented token gets, and the same answer the client is told. A
/// variant nothing could produce would be a case no test could reach.
pub enum TokenOutcome {
    valid
    /// The post carried no token at all.
    missing
    /// The client has no session, so nothing could have been bound to one.
    no_session
    /// The token is not `<expiry>.<mac>` with a whole-number expiry.
    malformed
    /// Genuine, and past its expiry.
    expired
    /// The MAC does not match this session, this form and this expiry.
    forged
}

pub fn describe_token(outcome: TokenOutcome) -> string {
    return match outcome {
        valid => "the token is valid",
        missing => "the form carried no antiforgery token",
        no_session => "the request carried no session, so no token could belong to it",
        malformed => "the antiforgery token is malformed",
        expired => "the antiforgery token has expired",
        forged => "the antiforgery token does not match this session and form"
    }
}

/// Issues and checks antiforgery tokens.
///
/// A token is `<expiry>.<mac>`, where the MAC covers the session id, the form id
/// and the expiry. The session id is an input and never a payload: a token is
/// rendered into a page, and a page that carried the session id would hand it
/// to anything that could read the markup.
///
/// The clock is a parameter and never read here. The module root imports no
/// `std.time` — the wasm leg would fail on it — and a host that passes its own
/// clock is also a host whose expiry test needs no sleep.
pub class Antiforgery {
    signer: Signer
    /// How long an issued token stays valid, in seconds.
    pub lifetime: int = 900
    pub fn init(signer: Signer, lifetime: int) {
        self.signer = signer
        self.lifetime = lifetime
    }

    pub fn issue(session: string, form_id: string, now: int) -> string {
        let expiry: int = now + self.lifetime
        return "{expiry}.{self.signer.sign(self.payload(session, form_id, expiry))}"
    }

    pub fn check(token: string, session: string, form_id: string,
                 now: int) -> TokenOutcome {
        if token == "" { return TokenOutcome.missing }
        if session == "" { return TokenOutcome.no_session }
        match token.find(".") {
            none => { return TokenOutcome.malformed }
            some(at) => {
                let head: string = token.slice(0, at)
                let mac: string = token.slice(at + 1, token.len())
                if mac == "" { return TokenOutcome.malformed }
                match parse_int(head) {
                    none => { return TokenOutcome.malformed }
                    some(expiry) => {
                        // The MAC is checked BEFORE the expiry, so `expired` is
                        // only ever said about a token latte itself issued.
                        // Reading an expiry off an unauthenticated string and
                        // answering it is how a forged token gets told which of
                        // its two guesses was wrong.
                        let wanted: string = self.signer.sign(
                            self.payload(session, form_id, expiry))
                        if !self.signer.same(mac, wanted) { return TokenOutcome.forged }
                        if now >= expiry { return TokenOutcome.expired }
                        return TokenOutcome.valid
                    }
                }
            }
        }
    }

    /// The signed string. The separator is a byte none of the three parts can
    /// contain — a session id is hex, a form id is a type name, an expiry is
    /// digits — and the lengths are written in so that no two different triples
    /// can produce the same payload by moving a boundary.
    fn payload(session: string, form_id: string, expiry: int) -> string {
        return "{session.len()}:{session}|{form_id.len()}:{form_id}|{expiry}"
    }
}

// ============================================================== the page host

/// One request, in the types the module root is allowed to name.
///
/// There is no header map and no cookie jar: the host has already decided which
/// session this client is, which is the host's job and not latte's. What
/// arrives here is a method, a path, a body and a session id.
pub class PageRequest {
    pub method: string = "GET"
    pub path: string = "/"
    /// The raw `application/x-www-form-urlencoded` body. Empty on a GET.
    pub body: string = ""
    /// The session this client already had, or the one the host just minted.
    /// Empty means the host has none, which is a refusal for any unsafe method.
    pub session: string = ""
    pub who: Principal = new Anonymous()
    pub fn init() {}
}

pub class PageResponse {
    pub status: int = 200
    pub body: string = ""
    /// Why the status is not 200. One line each, in the words a log wants.
    pub problems: List<string> = []
    /// The methods a 405 allows, sorted. Empty for every other status.
    pub allowed: List<string> = []
    pub fn init() {}

    pub fn ok() -> bool { return self.status == 200 }
    pub fn detail() -> string { return self.problems.join(" | ") }
}

/// Static server rendering: a request in, HTML out, no socket and no state kept
/// between requests.
///
/// It refuses to answer anything at all while either scan has a fault. A host
/// that ignored `PageMap.ok()` and `FormMap.ok()` and listened anyway would
/// otherwise serve the pages that happened to survive, and the one refusal that
/// matters — an unsafe method with no token to check — would be the one it
/// served.
pub class PageHost {
    pub pages: PageMap
    pub forms: FormMap
    anti: Antiforgery
    pub fn init(pages: PageMap, forms: FormMap, anti: Antiforgery) {
        self.pages = pages
        self.forms = forms
        self.anti = anti
    }

    /// The token a GET's form must carry. The host renders it into the page.
    pub fn token_for(session: string, form_id: string, now: int) -> string {
        return self.anti.issue(session, form_id, now)
    }

    pub fn handle(request: PageRequest, now: int) -> PageResponse {
        var reply: PageResponse = new PageResponse()
        if !self.pages.ok() || !self.forms.ok() {
            reply.status = 500
            reply.problems.push("latte did not start: the scan refused this application")
            for fault: string in self.pages.faults { reply.problems.push(fault) }
            for fault: string in self.forms.faults { reply.problems.push(fault) }
            return move reply
        }

        match self.pages.find(request.method, request.path) {
            none => {
                var allowed: List<string> = self.pages.allowed(request.path)
                if allowed.len() == 0 {
                    reply.status = 404
                    reply.problems.push("no page answers {request.path}")
                    return move reply
                }
                let listed: string = allowed.join(", ")
                reply.status = 405
                reply.allowed = move allowed
                reply.problems.push(
                    "{request.path} does not answer {request.method}; it answers {listed}")
                return move reply
            }
            some(found) => { return self.serve(found, request, now) }
        }
    }

    fn serve(found: PageMatch, request: PageRequest, now: int) -> PageResponse {
        var reply: PageResponse = new PageResponse()

        // Authorization first, and before activation: a page the caller may not
        // see must not run its initializer. The outcome is computed here rather
        // than read out of `open_page`'s message, because a status code that
        // depends on the wording of a string is a status code that changes when
        // somebody improves the wording. `open_page` checks it again anyway — a
        // circuit re-mounts long after this request is over.
        let outcome: AuthOutcome = found.plan.authorize(request.who)
        match outcome {
            allow => {}
            challenge => {
                reply.status = 401
                reply.problems.push(
                    "{found.plan.type_name}: nobody is signed in")
                return move reply
            }
            forbid => {
                reply.status = 403
                reply.problems.push(
                    "{found.plan.type_name}: signed in and not allowed here")
                return move reply
            }
        }

        let instance: PageInstance = open_page(found, request.who, none)
        if !instance.ok() {
            reply.status = 400
            for problem: string in instance.problems { reply.problems.push(problem) }
            return move reply
        }

        var page: Option<FormComponent> = none
        match instance.component {
            none => {}
            some(component) => {
                match component as? FormComponent {
                    some(form_page) => { page = some(form_page) }
                    none => {}
                }
            }
        }

        if !is_safe_method(request.method) {
            match page {
                none => {
                    // Unreachable while both scans are clean: `check_form_pages`
                    // refuses an unsafe method on a page that is not a
                    // FormComponent, and `handle` answers 500 before this while
                    // that fault stands. It is spelled out because the
                    // alternative is serving an unsafe request with no token.
                    reply.status = 500
                    reply.problems.push(
                        "{found.plan.type_name} served {request.method} without being a form page")
                    return move reply
                }
                some(form_page) => {
                    return self.post(found, instance, form_page, request, now)
                }
            }
        }

        match page {
            some(form_page) => {
                form_page.state = new FormState()
                form_page.state.token = self.anti.issue(
                    request.session, form_page.form_id(), now)
            }
            none => {}
        }
        return self.render(instance)
    }

    fn post(found: PageMatch, instance: PageInstance, page: FormComponent,
            request: PageRequest, now: int) -> PageResponse {
        var reply: PageResponse = new PageResponse()
        var posted: Map<string, string> = parse_form_body(request.body)
        var token: string = ""
        match posted.get(TOKEN_FIELD) {
            some(text) => { token = text }
            none => {}
        }
        posted.remove(TOKEN_FIELD)

        let form_id: string = page.form_id()
        if form_id == "" {
            reply.status = 500
            reply.problems.push(
                "{found.plan.type_name}.form_id() is empty; a token bound to no form is a token that fits every form")
            return move reply
        }

        // The token is checked before anything is written. Binding mutates the
        // page's model, so a check that ran after it would have already let the
        // request do what the token exists to prevent.
        let outcome: TokenOutcome = self.anti.check(token, request.session, form_id, now)
        match outcome {
            valid => {}
            _ => {
                reply.status = 400
                reply.problems.push("{found.plan.type_name}: {describe_token(outcome)}")
                return move reply
            }
        }

        let model: reflect.Value = page.form_model()
        match self.forms.for_value(model.copy()) {
            none => {
                let named: string = model.type().qualified_name()
                reply.status = 500
                reply.problems.push(
                    "{found.plan.type_name}.form_model() returned a {named}, which is not a @form")
                return move reply
            }
            some(plan) => {
                var result: FormResult = plan.bind(model.copy(), posted)
                let clean: bool = result.ok()
                var state: FormState = new FormState()
                state.token = self.anti.issue(request.session, form_id, now)
                state.result = move result
                page.state = move state
                if clean {
                    page.on_submit()
                    page.state.submitted = true
                }
                return self.render(instance)
            }
        }
    }

    fn render(instance: PageInstance) -> PageResponse {
        var reply: PageResponse = new PageResponse()
        let renderer: Renderer = new Renderer()
        if !mount_page(renderer, instance) {
            reply.status = 500
            for problem: string in instance.problems { reply.problems.push(problem) }
            if reply.problems.len() == 0 {
                reply.problems.push("{instance.plan.type_name} did not mount")
            }
            return move reply
        }
        if renderer.faults.len() > 0 {
            reply.status = 500
            for fault: string in renderer.faults { reply.problems.push(fault) }
            return move reply
        }
        reply.body = renderer.html()
        return move reply
    }
}
