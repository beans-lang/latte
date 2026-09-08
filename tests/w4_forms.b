// tests/w4_forms.b — the form scan, what a post is allowed to become, and the
// antiforgery token.
//
// Every fixture in this file is scanned by one `scan_forms(scan_pages())`,
// healthy and broken together, which is the shape the suite wants: a refusal is
// only worth something beside an input that must be ACCEPTED, and here the
// controls and the refusals go through one code path in one pass.
//
// Three things in here are worth reading before changing anything:
//
//   * **§ 3's cross controls are the point of § 3.** A token check that forgot
//     to feed the session or the form id into the MAC would still accept every
//     token it issued, and every "the good token works" case would still pass.
//     What catches it is the token from ANOTHER session and the token from
//     ANOTHER form, both of which must be refused.
//   * **§ 4 proves a refused page is unroutable**, not merely reported. A rule
//     that only writes a line into a report is a rule a host can ignore by
//     never printing it.
//   * **§ 6 is the audit.** Every one of `forms.b`'s 17 fault sites is tripped
//     with its exact text and has a positive control beside it, and the tally
//     at the end is what `test.sh`'s refusal-coverage leg compares against the
//     source, so a new refusal cannot be added and quietly go untested.
//
// There is no `PageHost` here on purpose: this file's whole value is its broken
// fixtures, and a host refuses to answer anything while the scan has a fault.
// The host is `tests/w4_formhost.b`.
package main

import std.io
import std.reflect
import {Builder, Component, Renderer, Layout, PageMap, PagePlan, PageMatch,
        Principal, Anonymous, scan_pages, parse_int,
        page, param, layout, authorize,
        form, field, required, length, range,
        FormComponent, FormField, FormMap, FormPlan, FormResult, FormState,
        FieldError, Signer, SeamSigner, Antiforgery, TokenOutcome,
        describe_token, scan_forms, parse_form_body, form_decode,
        is_safe_method, TOKEN_FIELD} from latte
import {hmac_signer, same_bytes} from latte.web

// ================================================================ the healthy
//
// One model carrying every kind and every rule, and one page that posts it.
// This is the control for most of § 6: if the scan refused any of these, the
// refusals below would be "any @form at all" wearing a specific message.

@form
pub class Signup {
    @field @required @length(min: 3, max: 12) pub name: string = ""
    @field(name: "email") @required pub address: string = ""
    @field @range(min: 18, max: 120) pub age: int = 0
    @field pub subscribe: bool = false
    @field @range(min: 0, max: 100) pub score: float = 0.0
    /// Public, and NOT a `@field`. A body naming it must not reach it: this is
    /// the mass-assignment control, and § 2 posts it.
    pub is_admin: bool = false
    pub fn init() {}
}

pub class Shell extends Layout {
    pub fn init() { super.init() }
    pub override fn render(b: Builder) {
        b.open(0, "main")
        b.fragment(1, self.body)
        b.close()
    }
}

@page(route: r"/signup", methods: ["GET", "POST"])
@layout(name: "Shell")
pub class SignupPage extends FormComponent {
    pub model: Signup = new Signup()
    pub saved: int = 0
    pub fn init() { super.init() }
    pub override fn form_id() -> string { return "signup" }
    pub override fn form_model() -> reflect.Value { return reflect.value(self.model) }
    pub override fn on_submit() { self.saved += 1 }
    pub override fn render(b: Builder) {
        b.open(0, "form")
        b.text(1, self.state.summary())
        b.close()
    }
}

// ================================================================ the broken
//
// One fixture per refusal, each named for what is wrong with it, and each with
// a control beside it in `sites()`.

/// § 6.1 — a `@field` on a type nothing scans.
pub class LooseField {
    @field pub a: string = ""
    pub fn init() {}
}

/// § 6.2 — a rule on a type nothing scans.
pub class LooseRule {
    @required pub a: string = ""
    pub fn init() {}
}

/// § 6.3 — a form page no unsafe method can reach.
@page(route: r"/nopost", methods: ["GET"])
pub class NoPostPage extends FormComponent {
    pub model: Signup = new Signup()
    pub fn init() { super.init() }
    pub override fn form_id() -> string { return "nopost" }
    pub override fn form_model() -> reflect.Value { return reflect.value(self.model) }
    pub override fn render(b: Builder) { b.text(0, "nopost") }
}

/// § 6.4 — an unsafe method on a page with no form to bind a token to.
@page(route: r"/rawpost", methods: ["POST"])
pub class RawPostPage extends Component {
    pub fn init() {}
    pub override fn render(b: Builder) { b.text(0, "rawpost") }
}

/// § 6.4's control: the same method list on a page that IS a form.
@page(route: r"/okpost", methods: ["GET", "POST"])
pub class OkPostPage extends FormComponent {
    pub model: Signup = new Signup()
    pub fn init() { super.init() }
    pub override fn form_id() -> string { return "okpost" }
    pub override fn form_model() -> reflect.Value { return reflect.value(self.model) }
    pub override fn render(b: Builder) { b.text(0, "okpost") }
}

/// § 6.5 — a `@form` that binds nothing.
@form
pub class EmptyForm {
    pub a: string = ""
    pub fn init() {}
}

/// § 6.6 — a rule on a field of a `@form` that is not a `@field`.
@form
pub class RuleNoField {
    @field pub a: string = ""
    @length(min: 1, max: 2) pub b: string = ""
    pub fn init() {}
}

/// § 6.7 — two fields claiming one posted name.
@form
pub class TwoNames {
    @field(name: "x") pub a: string = ""
    @field(name: "x") pub b: string = ""
    pub fn init() {}
}

/// § 6.8 — a `@field` reflection cannot write.
@form
pub class HiddenField {
    @field a: string = ""
    @field pub b: string = ""
    pub fn init() {}
}

// § 6.9 — BLOCKERS.md B1a, with its control in the same hierarchy:
//
//   Base        non-generic, declares `plain`   -> must be ACCEPTED
//   Rows<T>     generic, declares `caption`     -> must be REFUSED
//   OrderForm   extends Rows<int>, carries @form
//
// The obvious test for this reads FALSE for exactly the field that fails; see
// `generic_declaration` in pages.b.

pub class FormBase {
    @field pub plain: string = ""
    pub fn init() {}
}

pub class Rows<T> extends FormBase {
    @field pub caption: string = ""
    pub fn init() { super.init() }
}

@form
pub class OrderForm extends Rows<int> {
    pub fn init() { super.init() }
}

/// § 6.9's control: the same shape over a NON-generic base. If this were
/// refused too, the refusal would be "any inherited field" and its message
/// would be a lie.
@form
pub class PlainOrderForm extends FormBase {
    pub fn init() { super.init() }
}

/// § 6.10 — a `@field` no form can bind.
@form
pub class BadKind {
    @field pub items: List<string> = []
    @field pub ok: string = ""
    pub fn init() {}
}

/// § 6.11 — `@required` on a checkbox.
@form
pub class RequiredBool {
    @field @required pub flag: bool = false
    pub fn init() {}
}

/// § 6.12 — a negative length floor.
@form
pub class LengthNegative {
    @field @length(min: -1, max: 5) pub s: string = ""
    pub fn init() {}
}

/// § 6.13 — a length window nothing fits in.
@form
pub class LengthBackwards {
    @field @length(min: 5, max: 2) pub s: string = ""
    pub fn init() {}
}

/// § 6.13's control: a window of exactly one size, which IS satisfiable.
@form
pub class LengthTight {
    @field @length(min: 2, max: 2) pub s: string = ""
    pub fn init() {}
}

/// § 6.14 — a `@length` no value could fail.
@form
pub class LengthOpen {
    @field @length pub s: string = ""
    pub fn init() {}
}

/// § 6.14's control: a `@length` that bounds only from above, which is a real
/// rule. `max: 0` is the tightest one there is and must be accepted.
@form
pub class LengthCeiling {
    @field @length(max: 0) pub s: string = ""
    pub fn init() {}
}

/// § 6.15 — `@length` on something with no length.
@form
pub class LengthOnInt {
    @field @length(min: 1, max: 2) pub n: int = 0
    pub fn init() {}
}

/// § 6.16 — `@range` on something with no order latte reads.
@form
pub class RangeOnText {
    @field @range(min: 1, max: 2) pub s: string = ""
    pub fn init() {}
}

/// § 6.17 — a numeric window nothing fits in.
@form
pub class RangeBackwards {
    @field @range(min: 9, max: 2) pub n: int = 0
    pub fn init() {}
}

/// § 6.17's control: a window of exactly one value, which IS satisfiable.
@form
pub class RangeTight {
    @field @range(min: 2, max: 2) pub n: int = 0
    pub fn init() {}
}

// ================================================================ reporting

class Report {
    pub failures: int = 0
    pub checks: int = 0
    pub fn init() {}

    pub fn eq(label: string, got: string, want: string) {
        self.checks += 1
        if got == want { io.println("ok   {label}: {got}") }
        else { io.println("FAIL {label}: got \"{got}\", want \"{want}\"") ; self.failures += 1 }
    }

    pub fn eqi(label: string, got: int, want: int) {
        self.checks += 1
        if got == want { io.println("ok   {label}: {got}") }
        else { io.println("FAIL {label}: got {got}, want {want}") ; self.failures += 1 }
    }

    pub fn yes(label: string, got: bool) {
        self.checks += 1
        if got { io.println("ok   {label}") }
        else { io.println("FAIL {label}: got false, want true") ; self.failures += 1 }
    }

    pub fn no(label: string, got: bool) {
        self.checks += 1
        if !got { io.println("ok   {label}") }
        else { io.println("FAIL {label}: got true, want false") ; self.failures += 1 }
    }
}

/// This file's own package name, as reflection reports it.
///
/// An entry file compiled inside a module is `<module>$entry`, not `main`, and
/// every fault message this suite compares against carries it. It is computed
/// once rather than written out seventeen times, so the day the compiler names
/// entry packages differently this file changes in one place — and the golden
/// still changes, which is the point of a golden.
fn here() -> string {
    let named: string = type_of(Signup).qualified_name()
    match named.rfind(".") {
        some(at) => { return named.slice(0, at) }
        none => { return named }
    }
}

/// Every fault naming `owner`, joined. Faults are matched by what they SAY and
/// by whom they name, never by position, so a fixture added later does not
/// renumber the suite.
fn faults_for(map: FormMap, owner: string) -> string {
    let prefix: string = "{here()}.{owner}"
    var out: List<string> = []
    for fault: string in map.faults {
        if fault.starts_with("{prefix} ") || fault.starts_with("{prefix}.") ||
           fault.starts_with("{prefix}:") { out.push(fault) }
    }
    return out.join(" | ")
}

fn plan_named(map: FormMap, name: string) -> Option<FormPlan> {
    return map.named(name)
}

fn field_list(plan: FormPlan) -> string {
    var out: List<string> = []
    for bound: FormField in plan.fields { out.push(bound.wire_name) }
    out.sort()
    return out.join(",")
}

/// One refusal, its exact message, and the fixture that must be accepted.
class Site {
    pub site: string = ""
    pub name: string = ""
    pub raised: string = ""
    pub want: string = ""
    pub control: string = ""
    pub fn init(site: string, name: string, raised: string, want: string,
                control: string) {
        self.site = site
        self.name = name
        self.raised = raised
        self.want = want
        self.control = control
    }
}

// ================================================================ the gate

fn main() {
    let report: Report = new Report()
    var pages: PageMap = scan_pages()
    let forms: FormMap = scan_forms(pages)

    section_one(report, forms)
    section_two(report, forms)
    section_three(report)
    section_four(report, pages, forms)
    section_five(report)
    section_six(report, forms)

    io.println("")
    io.println("{report.checks} checks, {report.failures} bad")
}

// ---------------------------------------------------------------- § 1 the scan

fn section_one(r: Report, forms: FormMap) {
    io.println("== 1. the scan finds a @form and resolves its fields ==")
    match plan_named(forms, "Signup") {
        none => { r.eq("Signup was planned", "no", "yes") }
        some(plan) => {
            r.yes("Signup is usable", plan.usable())
            r.eq("Signup's fields", field_list(plan), "age,email,name,score,subscribe")
            r.eq("Signup's type name", plan.type_name, "{here()}.Signup")
            match plan.field_named("email") {
                none => { r.eq("the renamed field is found by its wire name", "no", "yes") }
                some(bound) => {
                    r.eq("a @field(name:) binds under the posted name",
                         bound.field_name, "address")
                    r.yes("and it is required", bound.required)
                    r.no("and it carries no length rule", bound.has_length)
                }
            }
            match plan.field_named("name") {
                none => { r.eq("name is a field", "no", "yes") }
                some(bound) => {
                    r.yes("a @length is read", bound.has_length)
                    r.eqi("its floor", bound.min_length, 3)
                    r.eqi("its ceiling", bound.max_length, 12)
                }
            }
            match plan.field_named("age") {
                none => { r.eq("age is a field", "no", "yes") }
                some(bound) => {
                    r.yes("a @range is read", bound.has_range)
                    r.eqi("its floor", bound.min, 18)
                    r.eqi("its ceiling", bound.max, 120)
                    r.no("and an unannotated field is not required", bound.required)
                }
            }
            r.eq("a public field with no @field is not bindable",
                 describe_option(plan.field_named("is_admin")), "none")
        }
    }
    // A model nothing points at is still scanned: there is no registration, so
    // a `@form` that no page uses is a `@form` the scan still has to check.
    r.yes("a @form nothing references is still planned",
          plan_named(forms, "LengthTight").is_some())
}

fn describe_option(value: Option<FormField>) -> string {
    match value {
        some(bound) => { return bound.wire_name }
        none => { return "none" }
    }
}

// ---------------------------------------------------------------- § 2 binding

/// Bind a body onto a fresh model and report what happened, in one line.
fn bind(forms: FormMap, body: string) -> string {
    match plan_named(forms, "Signup") {
        none => { return "<no plan>" }
        some(plan) => {
            let model: Signup = new Signup()
            let result: FormResult = plan.bind(reflect.value(model), parse_form_body(body))
            var parts: List<string> = []
            for problem: FieldError in result.errors {
                parts.push("{problem.field}: {problem.message}")
            }
            let complaints: string = parts.join(" | ")
            let ignored: string = result.ignored.join(",")
            let flag: string = if model.subscribe { "on" } else { "off" }
            let admin: string = if model.is_admin { "yes" } else { "no" }
            return "name={model.name} email={model.address} age={model.age} sub={flag} score={model.score} admin={admin} ignored=[{ignored}] errors=[{complaints}]"
        }
    }
}

fn section_two(r: Report, forms: FormMap) {
    io.println("")
    io.println("== 2. a post binds only what the author annotated ==")

    r.eq("a clean post",
         bind(forms, "name=Ada&email=ada%40example.com&age=36&subscribe=on&score=99.5"),
         "name=Ada email=ada@example.com age=36 sub=on score=99.5 admin=no ignored=[] errors=[]")

    // The mass-assignment control. `is_admin` is public and is not a `@field`,
    // so a body naming it must leave it alone AND must say that it did.
    r.eq("a body naming a field the author did not annotate",
         bind(forms, "name=Ada&email=a%40b.c&age=36&is_admin=true"),
         "name=Ada email=a@b.c age=36 sub=off score=0 admin=no ignored=[is_admin] errors=[]")

    // `+` is a space in a body and a literal plus in a path. Both spellings of
    // a space arrive as one.
    r.eq("a plus and a percent-twenty are both spaces",
         bind(forms, "name=Ada+B&email=a%40b.c&age=36"),
         "name=Ada B email=a@b.c age=36 sub=off score=0 admin=no ignored=[] errors=[]")

    // A form field is trimmed, so `@length(min: 3)` counts characters and not
    // the spaces around them.
    r.eq("a value is trimmed before it is measured",
         bind(forms, "name=++Al++&email=a%40b.c&age=36"),
         "name=Al email=a@b.c age=36 sub=off score=0 admin=no errors=[name: name must be 3 to 12 characters] ignored=[] errors=[name: name must be 3 to 12 characters]".replace("admin=no errors=[name: name must be 3 to 12 characters] ignored=", "admin=no ignored="))

    r.eq("a missing required field",
         bind(forms, "age=36"),
         "name= email= age=36 sub=off score=0 admin=no ignored=[] errors=[name: name is required | email: email is required]")

    r.eq("a blank required field is missing too",
         bind(forms, "name=+++&email=a%40b.c&age=36"),
         "name= email=a@b.c age=36 sub=off score=0 admin=no ignored=[] errors=[name: name is required]")

    r.eq("too long",
         bind(forms, "name=Bartholomew+Fitzwilliam&email=a%40b.c&age=36"),
         "name=Bartholomew Fitzwilliam email=a@b.c age=36 sub=off score=0 admin=no ignored=[] errors=[name: name must be 3 to 12 characters]")

    r.eq("a number that is not one",
         bind(forms, "name=Ada&email=a%40b.c&age=twelve"),
         "name=Ada email=a@b.c age=0 sub=off score=0 admin=no ignored=[] errors=[age: age must be a whole number]")

    r.eq("a number outside its range",
         bind(forms, "name=Ada&email=a%40b.c&age=7"),
         "name=Ada email=a@b.c age=7 sub=off score=0 admin=no ignored=[] errors=[age: age must be between 18 and 120]")

    r.eq("a float outside its range",
         bind(forms, "name=Ada&email=a%40b.c&age=36&score=100.5"),
         "name=Ada email=a@b.c age=36 sub=off score=100.5 admin=no ignored=[] errors=[score: score must be between 0 and 100]")

    r.eq("a float on the boundary is inside it",
         bind(forms, "name=Ada&email=a%40b.c&age=36&score=100"),
         "name=Ada email=a@b.c age=36 sub=off score=100 admin=no ignored=[] errors=[]")

    // An unchecked box posts NOTHING. A form library that treated absence as an
    // error would refuse every form with a box in it, and one that treated it
    // as an error only for the box it remembered would be worse.
    r.eq("a checked box binds true",
         bind(forms, "name=Ada&email=a%40b.c&age=36&subscribe=on"),
         "name=Ada email=a@b.c age=36 sub=on score=0 admin=no ignored=[] errors=[]")
    r.eq("an unchecked box posts nothing and binds false",
         bind(forms, "name=Ada&email=a%40b.c&age=36"),
         "name=Ada email=a@b.c age=36 sub=off score=0 admin=no ignored=[] errors=[]")

    r.eq("a checkbox value nobody's browser sends",
         bind(forms, "name=Ada&email=a%40b.c&age=36&subscribe=maybe"),
         "name=Ada email=a@b.c age=36 sub=off score=0 admin=no ignored=[] errors=[subscribe: subscribe must be true or false]")

    io.println("-- the body parser")
    r.eqi("an empty body has no fields", parse_form_body("").len(), 0)
    r.eq("a key with no value", describe_body("a"), "a=")
    r.eq("a repeated key keeps the last", describe_body("a=1&a=2"), "a=2")
    r.eq("an empty pair is skipped", describe_body("&a=1&"), "a=1")
    r.eq("a nameless pair is skipped", describe_body("=1&a=2"), "a=2")
    r.eq("a value carrying an equals sign", describe_body("a=1=2"), "a=1=2")
    r.eq("a plus in a body is a space", form_decode("a+b"), "a b")
    r.eq("an encoded plus stays a plus", form_decode("a%2Bb"), "a+b")
}

fn describe_body(text: string) -> string {
    let parsed: Map<string, string> = parse_form_body(text)
    var keys: List<string> = parsed.keys()
    keys.sort()
    var parts: List<string> = []
    for key: string in keys {
        match parsed.get(key) {
            some(value) => { parts.push("{key}={value}") }
            none => {}
        }
    }
    return parts.join("&")
}

// ---------------------------------------------------------------- § 3 tokens

fn section_three(r: Report) {
    io.println("")
    io.println("== 3. the antiforgery token ==")
    let signer: Signer = new SeamSigner(hmac_signer("a shared secret"), same_bytes())
    let anti: Antiforgery = new Antiforgery(signer, 900)

    // The token is a pure function of the key, the session, the form id and the
    // clock, so it is printable and pinned. If the payload's shape changes,
    // this line changes with it — which is the point.
    let token: string = anti.issue("s1", "signup", 1000)
    io.println("a token at t=1000: {token}")
    r.eq("the expiry is the head", token.slice(0, 5), "1900.")
    r.eqi("the mac is sha256 in hex", token.len() - 5, 64)

    // Checked against an implementation that is not this one. Python:
    //
    //   hmac.new(b"a shared secret", b"2:s1|6:signup|1900",
    //            hashlib.sha256).hexdigest()
    //
    // A latte-only assertion would only prove `issue` and `check` agree with
    // each other, which they would even if the payload were the empty string.
    // This pins the payload's exact shape — the length prefixes included — to a
    // third party's answer.
    r.eq("the whole token, against Python's hmac", token,
         "1900.ac52c8491de8cd2bde19c700e075d0c34ca1ce6e1e123ec0972514fb83335b2b")

    r.eq("the token it issued", describe_token(anti.check(token, "s1", "signup", 1000)),
         "the token is valid")
    r.eq("one second before it expires",
         describe_token(anti.check(token, "s1", "signup", 1899)), "the token is valid")

    // Each of these is a DIFFERENT input and each must be refused. Together
    // they are what proves the MAC covers what it claims to cover: a signer
    // that forgot the session, or the form, or the expiry would still pass
    // every "the good token works" case above.
    r.eq("the same token in another session",
         describe_token(anti.check(token, "s2", "signup", 1000)),
         "the antiforgery token does not match this session and form")
    r.eq("the same token on another form",
         describe_token(anti.check(token, "s1", "login", 1000)),
         "the antiforgery token does not match this session and form")
    r.eq("the same mac under another expiry",
         describe_token(anti.check("1901.{token.slice(5, token.len())}", "s1", "signup", 1000)),
         "the antiforgery token does not match this session and form")
    r.eq("one byte of the mac changed",
         describe_token(anti.check(flip_last(token), "s1", "signup", 1000)),
         "the antiforgery token does not match this session and form")

    r.eq("the moment it expires",
         describe_token(anti.check(token, "s1", "signup", 1900)),
         "the antiforgery token has expired")
    r.eq("long after it expires",
         describe_token(anti.check(token, "s1", "signup", 99999)),
         "the antiforgery token has expired")

    r.eq("no token at all", describe_token(anti.check("", "s1", "signup", 1000)),
         "the form carried no antiforgery token")
    r.eq("a token with no session",
         describe_token(anti.check(token, "", "signup", 1000)),
         "the request carried no session, so no token could belong to it")
    r.eq("a token with no separator",
         describe_token(anti.check("garbage", "s1", "signup", 1000)),
         "the antiforgery token is malformed")
    r.eq("a token whose expiry is not a number",
         describe_token(anti.check("soon.{token.slice(5, token.len())}", "s1", "signup", 1000)),
         "the antiforgery token is malformed")
    r.eq("a token with an empty mac",
         describe_token(anti.check("1900.", "s1", "signup", 1000)),
         "the antiforgery token is malformed")

    // A forged token that claims to be expired must NOT be told it is expired:
    // the MAC is checked first, so the answer never depends on a number the
    // client chose.
    r.eq("a forged token carrying an expiry in the past",
         describe_token(anti.check("1.deadbeef", "s1", "signup", 1000)),
         "the antiforgery token does not match this session and form")

    // Two lifetimes, so the expiry is read from the Antiforgery and not from a
    // constant somebody baked into `issue`.
    let brief: Antiforgery = new Antiforgery(signer, 5)
    let short_token: string = brief.issue("s1", "signup", 1000)
    r.eq("a five-second lifetime expires in five seconds",
         short_token.slice(0, 5), "1005.")
    r.eq("and it is valid until then",
         describe_token(brief.check(short_token, "s1", "signup", 1004)),
         "the token is valid")
    r.eq("and not one tick past",
         describe_token(brief.check(short_token, "s1", "signup", 1005)),
         "the antiforgery token has expired")

    // A session id and a form id that would collide if the payload joined them
    // without lengths: "ab|c" and "a|bc" are one string either way, and the
    // MAC would be the same for both.
    let left: string = anti.issue("ab", "c", 1000)
    let right: string = anti.issue("a", "bc", 1000)
    r.no("two triples that would collide without length prefixes do not",
         left == right)

    io.println("-- the safe methods")
    r.yes("GET is safe", is_safe_method("get"))
    r.yes("HEAD is safe", is_safe_method("HEAD"))
    r.yes("OPTIONS is safe", is_safe_method("OPTIONS"))
    r.no("POST is not", is_safe_method("POST"))
    r.no("DELETE is not", is_safe_method("delete"))
    r.no("a method nobody has heard of is not", is_safe_method("FROB"))
}

/// The token with the last hex digit of its MAC changed.
fn flip_last(token: string) -> string {
    let head: string = token.slice(0, token.len() - 1)
    let last: string = token.slice(token.len() - 1, token.len())
    if last == "0" { return "{head}1" }
    return "{head}0"
}

// ---------------------------------------------------------------- § 4 pages

fn section_four(r: Report, pages: PageMap, forms: FormMap) {
    io.println("")
    io.println("== 4. a page refused by the form scan is unroutable ==")

    // Reported is not enough. A rule that only writes a line into a report is a
    // rule a host can ignore by never printing it, so the refusal has to reach
    // the table a request is routed through.
    r.no("the form scan refused this application", forms.ok())
    r.no("and said so in the page map too", pages.ok())

    r.eq("a POST to a page with no form", describe_match(pages, "POST", "/rawpost"), "none")
    r.eq("and its GET is gone with it", describe_match(pages, "GET", "/rawpost"), "none")
    r.eq("a form page no POST can reach", describe_match(pages, "GET", "/nopost"), "none")

    // The control, and it is the whole reason the two lines above mean
    // anything: the same shapes, done right, still route.
    r.eq("the control: a form page that serves POST",
         describe_match(pages, "POST", "/okpost"), "{here()}.OkPostPage")
    r.eq("and its GET", describe_match(pages, "GET", "/okpost"), "{here()}.OkPostPage")
    r.eq("and the healthy signup page", describe_match(pages, "POST", "/signup"),
         "{here()}.SignupPage")

    io.println("-- the method that is not allowed")
    r.eq("a path that answers other methods", pages.allowed("/signup").join(","), "GET,POST")
    r.eq("a path nothing answers", pages.allowed("/nowhere").join(","), "")
    r.eq("a refused page allows nothing", pages.allowed("/rawpost").join(","), "")
}

fn describe_match(pages: PageMap, method: string, path: string) -> string {
    match pages.find(method, path) {
        some(found) => { return found.plan.type_name }
        none => { return "none" }
    }
}

// ---------------------------------------------------------------- § 5 state

fn section_five(r: Report) {
    io.println("")
    io.println("== 5. what a page reads off its form state ==")
    var state: FormState = new FormState()
    r.yes("a fresh state is clean", state.ok())
    r.eq("and has nothing to say", state.summary(), "")
    r.eq("and nothing was ignored", state.ignored(), "")
    r.eq("and no field has an error", state.error_for("name"), "")

    var result: FormResult = new FormResult()
    result.errors.push(new FieldError("name", "name is required"))
    result.errors.push(new FieldError("age", "age must be between 18 and 120"))
    result.ignored.push("is_admin")
    state.result = move result

    r.no("a state carrying errors is not clean", state.ok())
    r.eqi("and counts them", state.error_count(), 2)
    r.eq("a field's own message", state.error_for("age"),
         "age must be between 18 and 120")
    r.eq("a field with no message", state.error_for("email"), "")
    r.eq("the whole summary", state.summary(),
         "name: name is required | age: age must be between 18 and 120")
    r.eq("what was ignored", state.ignored(), "is_admin")
}

// ---------------------------------------------------------------- § 6 audit

fn sites(forms: FormMap) -> List<Site> {
    let good: string = faults_for(forms, "Signup")
    let at: string = here()
    var out: List<Site> = []

    out.push(new Site("scan / a @field on a type that is not a @form",
        "a @field nothing scans",
        faults_for(forms, "LooseField"),
        "{at}.LooseField.a is a @field but {at}.LooseField is not a @form, so nothing would ever bind it",
        good))
    out.push(new Site("scan / a rule on a type that is not a @form",
        "a rule nothing scans",
        faults_for(forms, "LooseRule"),
        "{at}.LooseRule.a carries @required but not @field, so the rule would never run",
        good))
    out.push(new Site("check_form_pages / a form page no unsafe method reaches",
        "a form page with no POST",
        faults_for(forms, "NoPostPage"),
        "{at}.NoPostPage is a form page but @page(methods:) is GET; nothing could ever submit its form",
        faults_for(forms, "OkPostPage")))
    out.push(new Site("check_form_pages / an unsafe method with no form",
        "a POST page that is not a form",
        faults_for(forms, "RawPostPage"),
        "{at}.RawPostPage serves POST but does not extend latte.FormComponent, so latte has no form id to bind an antiforgery token to",
        faults_for(forms, "OkPostPage")))
    out.push(new Site("plan_for_form / a @form that declares no @field",
        "a @form that binds nothing",
        faults_for(forms, "EmptyForm"),
        "{at}.EmptyForm is a @form but declares no @field, so a post would bind nothing",
        good))
    out.push(new Site("bind_fields / a rule on a field that is not a @field",
        "a rule on a plain field of a @form",
        faults_for(forms, "RuleNoField"),
        "{at}.RuleNoField.b carries @length but not @field, so the rule would never run",
        good))
    out.push(new Site("bind_fields / two @fields with one posted name",
        "two fields claiming one name",
        faults_for(forms, "TwoNames"),
        "{at}.TwoNames: \"x\" names both a and b",
        good))
    out.push(new Site("bind_fields / a @field that is not public",
        "a @field reflection cannot write",
        faults_for(forms, "HiddenField"),
        "{at}.HiddenField.a is a @field but is not public, and reflection does not bypass visibility",
        good))
    out.push(new Site("bind_fields / a @field declared by a generic type",
        "BLOCKERS.md B1a",
        faults_for(forms, "OrderForm"),
        "{at}.OrderForm.caption is a @field declared by {at}.Rows<int>; a reflective write to a field whose declaring type is generic is ok under beansc run and unsupported natively (BLOCKERS.md B1a), so latte refuses it here rather than at request time",
        faults_for(forms, "PlainOrderForm")))
    out.push(new Site("bind_fields / a @field a form cannot bind",
        "a field of a type no body carries",
        faults_for(forms, "BadKind"),
        "{at}.BadKind.items is a @field but is a List<string>; a form can bind string, int, bool and float",
        good))
    out.push(new Site("read_rules / @required on a checkbox",
        "@required on a bool",
        faults_for(forms, "RequiredBool"),
        "{at}.RequiredBool.flag is a bool carrying @required; an unchecked box posts nothing at all, so a required bool would refuse every unchecked form",
        good))
    out.push(new Site("read_rules / a negative @length floor",
        "a negative length",
        faults_for(forms, "LengthNegative"),
        "{at}.LengthNegative.s carries @length(min: -1); a length is never negative",
        faults_for(forms, "LengthTight")))
    out.push(new Site("read_rules / a @length no value can satisfy",
        "a backwards length window",
        faults_for(forms, "LengthBackwards"),
        "{at}.LengthBackwards.s carries @length(min: 5, max: 2), which no value can satisfy",
        faults_for(forms, "LengthTight")))
    out.push(new Site("read_rules / a @length that bounds nothing",
        "a @length with no bounds",
        faults_for(forms, "LengthOpen"),
        "{at}.LengthOpen.s carries a @length that bounds nothing; no value could fail it",
        faults_for(forms, "LengthCeiling")))
    out.push(new Site("read_rules / @length on something that is not a string",
        "@length on an int",
        faults_for(forms, "LengthOnInt"),
        "{at}.LengthOnInt.n carries @length but is a int; @length measures a string",
        good))
    out.push(new Site("read_rules / @range on something that is not a number",
        "@range on a string",
        faults_for(forms, "RangeOnText"),
        "{at}.RangeOnText.s carries @range but is a string; @range bounds an int or a float",
        good))
    out.push(new Site("adopt_range / a @range no value can satisfy",
        "a backwards numeric window",
        faults_for(forms, "RangeBackwards"),
        "{at}.RangeBackwards.n carries @range(min: 9, max: 2), which no value can satisfy",
        faults_for(forms, "RangeTight")))
    return move out
}

fn section_six(r: Report, forms: FormMap) {
    io.println("")
    io.println("== 6. every refusal forms.b makes, with a control beside it ==")
    var reached: Map<string, int> = {}
    for probe: Site in sites(forms) {
        io.println("-- {probe.name}")
        io.println("   site:    {probe.site}")
        io.println("   faults:  {probe.raised}")
        r.eq("{probe.name}: the exact fault", probe.raised, probe.want)
        r.eq("{probe.name}: the control raises nothing", probe.control, "")
        match reached.get(probe.site) {
            some(n) => { reached[probe.site] = n + 1 }
            none => { reached[probe.site] = 1 }
        }
    }

    var names: List<string> = reached.keys()
    names.sort()
    io.println("-- the sites in forms.b, and how many shapes reach each")
    for name: string in names {
        match reached.get(name) {
            some(n) => { io.println("   {n}x {name}") }
            none => {}
        }
    }
    r.eqi("every fault site in forms.b has a case", names.len(), 17)
}
