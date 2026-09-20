// tests/pages.b — the startup scan, and every refusal it makes.
//
// A latte application registers nothing: `scan_pages()` walks
// `reflect.types()` once and turns every `@page` into a plan. That means every
// fixture in this file is scanned by the same call, healthy and broken
// together, which is exactly the shape the suite wants — a refusal is only
// worth anything beside an input that must be ACCEPTED, and here the controls
// and the refusals go through one code path in one pass.
//
// Every refusal below has a positive control declared next to it, and the
// control is named in the output so a reader can see the pair. The one that
// matters most is a
// `@param` whose declaring type is generic — because the obvious way to detect
// it reads FALSE for exactly the fields that fail. Section 2 asserts that
// false directly, so a future "simplification" back to the obvious spelling
// fails here rather than shipping a page that works under `beansc run` and
// breaks as a binary.
package main

import std.io
import {Builder, Component, Renderer, Layout, ParamWatch,
        PageMap, PagePlan, PageMatch, PageInstance, ParamBinding, RoutePattern, RouteSegment,
        Principal, Anonymous, AuthOutcome, AuthRequirement, describe_outcome, authorize_all,
        scan_pages, open_page, mount_page, percent_decode, percent_encode,
        extends_named,
        page, param, layout, authorize} from latte
import std.reflect

// ================================================================ layouts

/// The outer layout. `$slot` compiles to `b.fragment(seq, self.body)`.
pub class Main extends Layout {
    pub fn init() { super.init() }
    pub override fn render(b: Builder) {
        b.open(0, "main")
        b.attr(1, "class", "shell")
        b.fragment(2, self.body)
        b.close()
    }
}

/// A layout that nests inside another one — the same `@layout` annotation,
/// because it only ever SELECTS.
@layout(name: "Main")
pub class Admin extends Layout {
    pub fn init() { super.init() }
    pub override fn render(b: Builder) {
        b.open(0, "div")
        b.attr(1, "class", "admin")
        b.fragment(2, self.body)
        b.close()
    }
}

/// Named to collide with `latte.Attr` on the simple name, so
/// `@layout(name: "Attr")` is genuinely ambiguous and the refusal has two real
/// candidates rather than none.
pub class Attr extends Layout {
    pub fn init() { super.init() }
}

// ================================================================ healthy pages

@page(route: r"/counter/{start}")
@layout(name: "Main")
pub class Counter extends Component {
    @param pub start: int = 0
    pub count: int = 0
    pub fn init() {}
    pub override fn on_init() { self.count = self.start }
    pub override fn render(b: Builder) {
        b.open(0, "section")
        b.text(1, "count {self.count}")
        b.close()
    }
}

/// Every parameter shape in one page: required-from-route, optional-from-route,
/// renamed, and one that is not bindable from a route at all and must
/// therefore be ACCEPTED rather than refused — the control for the
/// "unbindable type captured by a route" refusal below.
@page(route: r"/todo/{id}/{done}", methods: ["GET", "POST"])
@layout(name: "Admin")
@authorize(roles: ["editor", "admin"])
@authorize(policy: "beta")
pub class Todo extends Component {
    @param(required: true) pub id: int = 0
    @param pub done: bool = false
    @param(name: "q") pub query: string = ""
    @param pub ratio: float = 0.0
    /// Not bindable from a route, not captured by one: a parent-supplied
    /// parameter, which the scan must accept.
    @param pub body: fn(Builder) = fn(b: Builder) {}
    pub fn init() {}
    pub override fn render(b: Builder) {
        b.open(0, "article")
        b.text(1, "todo {self.id} done={self.done} q={self.query} ratio={self.ratio}")
        b.close()
    }
}

/// Nothing in this program mentions `Home` anywhere else. If the registry only
/// held types something referenced, a latte page that is only reachable by URL
/// would silently not exist — so this is a claim about `reflect.types()`, not
/// about `Home`.
@page(route: "/")
pub class Home extends Component {
    pub fn init() {}
    pub override fn render(b: Builder) { b.text(0, "home") }
}

@page(route: r"/orders/new")
pub class NewOrder extends Component {
    pub fn init() {}
    pub override fn render(b: Builder) { b.text(0, "new order") }
}

@page(route: r"/orders/{id}")
pub class ShowOrder extends Component {
    @param pub id: string = ""
    pub fn init() {}
    pub override fn render(b: Builder) { b.text(0, "order {self.id}") }
}

// ========================================== a generic ancestor's @param field
//
// The shape, with its controls in the same hierarchy:
//
//   Node        non-generic base, declares `label`   -> ordinary @param
//   Grid<T>     generic, declares `title`            -> @param on a generic-declared field
//   OrderGrid   extends Grid<int>, carries @page     -> both fields bind, page is usable

pub class Node extends Component {
    @param pub label: string = ""
    pub fn init() {}
}

pub class Grid<T> extends Node {
    @param pub title: string = ""
    pub rows: int = 0
    pub fn init() { super.init() }
}

@page(route: r"/grid/{label}/{title}")
pub class OrderGrid extends Grid<int> {
    pub fn init() { super.init() }
    pub override fn render(b: Builder) { b.text(0, "grid {self.label}/{self.title}") }
}

/// The control: the same shape with a NON-generic base. Both OrderGrid and
/// PlainGrid are usable — a generic ancestor is not special-cased.
pub class PlainBase extends Component {
    @param pub label: string = ""
    pub fn init() {}
}

@page(route: r"/plain/{label}")
pub class PlainGrid extends PlainBase {
    pub fn init() { super.init() }
    pub override fn render(b: Builder) { b.text(0, "plain {self.label}") }
}

// ================================================================ refusals

/// `@page` on something that is not a Component.
@page(route: r"/not-a-component")
pub class NotAComponent {
    pub fn init() {}
}

@page(route: "counter")
pub class BadRouteStart extends Component {
    pub fn init() {}
}

@page(route: r"/x/o{id}")
pub class BadPlaceholder extends Component {
    @param pub id: string = ""
    pub fn init() {}
}

@page(route: r"/files/{*rest}")
pub class BadCatchAll extends Component {
    @param pub rest: string = ""
    pub fn init() {}
}

@page(route: r"/dup/{a}/{a}")
pub class BadDuplicatePlaceholder extends Component {
    @param pub a: string = ""
    pub fn init() {}
}

@page(route: r"/needs-nothing")
pub class BadRequiredNotInRoute extends Component {
    @param(required: true) pub id: int = 0
    pub fn init() {}
}

@page(route: r"/unbindable/{tags}")
pub class BadUnbindable extends Component {
    @param pub tags: List<string> = []
    pub fn init() {}
}

@page(route: r"/private/{secret}")
pub class BadPrivateParam extends Component {
    @param secret: string = ""
    pub fn init() {}
}

@page(route: r"/orphan/{missing}")
pub class BadOrphanPlaceholder extends Component {
    pub fn init() {}
}

@page(route: r"/clash/{x}")
pub class BadClashA extends Component {
    @param pub x: string = ""
    pub fn init() {}
}

@page(route: r"/clash/{y}")
pub class BadClashB extends Component {
    @param pub y: string = ""
    pub fn init() {}
}

@page(route: r"/no-such-layout")
@layout(name: "Nope")
pub class BadLayoutUnknown extends Component {
    pub fn init() {}
}

@page(route: r"/layout-is-a-page")
@layout(name: "Counter")
pub class BadLayoutNotALayout extends Component {
    pub fn init() {}
}

@page(route: r"/ambiguous-layout")
@layout(name: "Attr")
pub class BadLayoutAmbiguous extends Component {
    pub fn init() {}
}

@layout(name: "LoopB")
pub class LoopA extends Layout {
    pub fn init() { super.init() }
}

@layout(name: "LoopA")
pub class LoopB extends Layout {
    pub fn init() { super.init() }
}

@page(route: r"/loop")
@layout(name: "LoopA")
pub class BadLayoutLoop extends Component {
    pub fn init() {}
}

/// `@authorize` where nothing would ever check it.
@authorize(policy: "admin")
pub class NotAPageButGuarded extends Component {
    pub fn init() {}
}

/// `@layout` on something that is neither a page nor a Layout.
@layout(name: "Main")
pub class NotAPageButWrapped extends Component {
    pub fn init() {}
}

@page(route: r"/no-methods", methods: [])
pub class BadNoMethods extends Component {
    pub fn init() {}
}

// ================================================================ ParamWatch

/// The right way: snapshot in `on_params_set`, answer from the snapshot.
pub class Watched extends Component {
    pub label: string = ""
    watch: ParamWatch = new ParamWatch()
    pub fn init() {}
    pub override fn on_params_set() { self.watch.record(["{self.label}"]) }
    pub override fn should_render() -> bool { return self.watch.differs() }
    pub override fn render(b: Builder) { b.text(0, "{self.label}") }
}

/// The hand-written mistake the helper exists to stop: the snapshot is taken
/// in `should_render`, which is consulted only from the SECOND render on, so
/// the first render's parameters are never recorded and the answer is
/// "changed" for ever. It is here as a control: it must re-render when
/// `Watched` does not.
pub class Unwatched extends Component {
    pub label: string = ""
    seen: string = "<unset>"
    pub fn init() {}
    pub override fn should_render() -> bool {
        let changed: bool = self.seen != self.label
        self.seen = self.label
        return changed
    }
    pub override fn render(b: Builder) { b.text(0, "{self.label}") }
}

pub class WatchHost extends Component {
    pub label: string = ""
    pub fn init() {}
    pub override fn render(b: Builder) {
        b.open(0, "div")
        let text: string = self.label
        b.component<Watched>(1, fn(c: Watched) { c.label = text })
        b.component<Unwatched>(2, fn(c: Unwatched) { c.label = text })
        b.close()
    }
}

// ================================================================ principals

pub class User implements Principal {
    pub signed_in: bool = true
    pub roles: List<string> = []
    pub policies: List<string> = []
    pub fn init() {}
    pub fn authenticated() -> bool { return self.signed_in }
    pub fn has_role(role: string) -> bool { return self.roles.contains(role) }
    pub fn satisfies(policy: string) -> bool { return self.policies.contains(policy) }
}

// ================================================================ reporting

class Report {
    pub failures: int = 0
    pub fn init() {}

    pub fn check(label: string, got: int, want: int) {
        if got == want { io.println("ok   {label}: {got}") }
        else { io.println("FAIL {label}: got {got}, want {want}") ; self.failures += 1 }
    }

    pub fn check_text(label: string, got: string, want: string) {
        if got == want { io.println("ok   {label}: {got}") }
        else { io.println("FAIL {label}: got \"{got}\", want \"{want}\"") ; self.failures += 1 }
    }

    pub fn check_true(label: string, got: bool) {
        if got { io.println("ok   {label}") }
        else { io.println("FAIL {label}: got false, want true") ; self.failures += 1 }
    }

    pub fn check_false(label: string, got: bool) {
        if !got { io.println("ok   {label}") }
        else { io.println("FAIL {label}: got true, want false") ; self.failures += 1 }
    }
}

/// Whether any fault mentions all of these fragments. A fault is matched by
/// what it SAYS, not by its position in the list, so adding a page later does
/// not renumber the suite.
fn mentions(faults: List<string>, a: string, b: string) -> bool {
    for fault: string in faults {
        if fault.contains(a) && fault.contains(b) { return true }
    }
    return false
}

/// Whether the plan for this page exists AND carries no fault.
fn is_usable(map: PageMap, name: string) -> bool {
    match plan_named(map, name) {
        some(plan) => { return plan.usable() }
        none => { return false }
    }
}

fn plan_named(map: PageMap, name: string) -> Option<PagePlan> {
    for plan: PagePlan in map.pages {
        if plan.name == name { return some(plan) }
    }
    return none
}

fn param_names(plan: PagePlan) -> string {
    var out: List<string> = []
    for binding: ParamBinding in plan.params { out.push(binding.wire_name) }
    out.sort()
    return out.join(",")
}

fn html_of(instance: PageInstance) -> string {
    let r: Renderer = new Renderer()
    if !mount_page(r, instance) { return "<not mounted>" }
    return r.html()
}

// ================================================================ the check

fn main() {
    let report: Report = new Report()
    let map: PageMap = scan_pages()

    io.println("== 1. the scan finds the healthy pages ==")
    report.check_true("a page nothing references is still found",
                      plan_named(map, "Home").is_some())
    match plan_named(map, "Counter") {
        some(plan) => {
            report.check_text("Counter's route", plan.route.source, r"/counter/{start}")
            report.check_text("Counter's methods", plan.methods.join(","), "GET")
            report.check_text("Counter's parameters", param_names(plan), "start")
            report.check("Counter's layout chain", plan.layouts.len(), 1)
            report.check_true("Counter is usable", plan.usable())
        }
        none => { report.check("Counter was planned", 0, 1) }
    }
    match plan_named(map, "Todo") {
        some(plan) => {
            report.check_text("Todo's methods", plan.methods.join(","), "GET,POST")
            report.check_text("Todo's parameters", param_names(plan), "body,done,id,q,ratio")
            report.check("Todo's layout chain is two deep", plan.layouts.len(), 2)
            report.check("Todo's authorization requirements", plan.requirements.len(), 2)
            report.check_true("Todo is usable", plan.usable())
        }
        none => { report.check("Todo was planned", 0, 1) }
    }

    io.println("")
    io.println("== 2. a field declared by a generic ancestor ==")
    // This section used to assert a refusal. It asserts the repair now, and it
    // keeps the trap as a row because the trap is the interesting part: the
    // obvious guard, `field.declaring_type().type_arguments().len() > 0`, read
    // 0 for exactly the fields that failed, so a refusal written the obvious
    // way never fired. beans #159 made the declaring type answer the closed
    // form, which is what makes the row below a 1 rather than a 0.
    let grid: reflect.Type = type_of(OrderGrid)
    let closed_grid: string = type_of(Grid<int>).qualified_name()
    match grid.field("title") {
        some(field) => {
            report.check("the trap is gone: title's declaring type reports its arguments",
                         field.declaring_type().type_arguments().len(), 1)
            report.check_text("...and names the closed form",
                              field.declaring_type().qualified_name(), closed_grid)
        }
        none => { report.check("OrderGrid has a title field", 0, 1) }
    }
    match grid.field("label") {
        some(field) => {
            report.check("the CONTROL: label is declared by a non-generic base",
                         field.declaring_type().type_arguments().len(), 0)
        }
        none => { report.check("OrderGrid has a label field", 0, 1) }
    }
    report.check_false("the scan no longer refuses title",
                       mentions(map.faults, "OrderGrid.title", "generic"))
    report.check_false("...and never refused label",
                       mentions(map.faults, "OrderGrid.label", "generic"))
    match plan_named(map, "OrderGrid") {
        some(plan) => {
            report.check_text("BOTH @params bind now, the generic-declared one included",
                              param_names(plan), "label,title")
        }
        none => { report.check("OrderGrid was planned", 0, 1) }
    }

    io.println("")
    io.println("== 2b. a page whose chain holds a closed generic ==")
    // 0.1.40 constructed OrderGrid under `beansc run` and answered
    // `unsupported` natively, so latte refused the whole chain at startup. Both
    // backends construct it now, and this suite runs on both, so the row below
    // is the measurement rather than a claim.
    report.check_true("OrderGrid is usable — a generic ancestor is ordinary now",
                      plan_named(map, "OrderGrid").is_some())
    report.check_false("the scan does not refuse it for its chain",
                       mentions(map.faults, "OrderGrid is a @page", "generic"))
    match type_of(OrderGrid).initializer() {
        some(ctor) => {
            match ctor.call([]) {
                ok(made) => {
                    report.check_true("...and reflection actually constructs one",
                                      made.type().qualified_name() ==
                                      type_of(OrderGrid).qualified_name())
                }
                err(e) => { report.check_text("OrderGrid constructs", e.message(), "") }
            }
        }
        none => { report.check("OrderGrid has an initializer descriptor", 0, 1) }
    }
    match plan_named(map, "PlainGrid") {
        some(plan) => {
            report.check_true("the CONTROL: PlainGrid is usable", plan.usable())
            report.check_text("...and its inherited @param binds", param_names(plan), "label")
        }
        none => { report.check("PlainGrid was planned", 0, 1) }
    }

    io.println("== 3. every other refusal, each beside a control ==")
    report.check_true("a @page that is not a Component",
                      mentions(map.faults, "NotAComponent", "does not extend"))
    report.check_true("a route that does not start with a slash",
                      mentions(map.faults, "BadRouteStart", "must start with"))
    report.check_true("a placeholder that is not a whole segment",
                      mentions(map.faults, "BadPlaceholder", "whole segment"))
    report.check_true("a catch-all placeholder",
                      mentions(map.faults, "BadCatchAll", "catch-all"))
    report.check_true("one name captured twice",
                      mentions(map.faults, "BadDuplicatePlaceholder", "twice"))
    report.check_true("required with no placeholder",
                      mentions(map.faults, "BadRequiredNotInRoute.id", "does not capture"))
    report.check_true("a route capturing an unbindable type",
                      mentions(map.faults, "BadUnbindable.tags", "a route can bind"))
    report.check_true("a @param that is not public",
                      mentions(map.faults, "BadPrivateParam.secret", "not public"))
    report.check_true("a placeholder nothing binds",
                      mentions(map.faults, "BadOrphanPlaceholder", "no @param binds it"))
    report.check_true("two pages answering one method and shape",
                      mentions(map.faults, "BadClash", "could choose between them"))
    report.check_true("a layout naming no type",
                      mentions(map.faults, "BadLayoutUnknown", "names no type"))
    report.check_true("a layout naming a page",
                      mentions(map.faults, "BadLayoutNotALayout", "does not extend"))
    report.check_true("a layout name two types answer to",
                      mentions(map.faults, "BadLayoutAmbiguous", "ambiguous"))
    report.check_true("a layout chain that loops",
                      mentions(map.faults, "BadLayoutLoop", "loops"))
    report.check_true("@authorize where nothing checks it",
                      mentions(map.faults, "NotAPageButGuarded", "never be checked"))
    report.check_true("@layout where nothing wraps it",
                      mentions(map.faults, "NotAPageButWrapped", "would ever wrap it"))
    report.check_true("a page that serves no method",
                      mentions(map.faults, "BadNoMethods", "methods:) is empty"))
    io.println("-- the controls: every one of these is USABLE --")
    // `usable()` and not "no fault mentions this name": a fault that names a
    // page as somebody else's layout mentions it too, and a control written on
    // the message would have called `Counter` refused because
    // `BadLayoutNotALayout` names it.
    report.check_true("Counter", is_usable(map, "Counter"))
    report.check_true("Todo", is_usable(map, "Todo"))
    report.check_true("Home", is_usable(map, "Home"))
    report.check_true("NewOrder", is_usable(map, "NewOrder"))
    report.check_true("ShowOrder", is_usable(map, "ShowOrder"))
    report.check_true("PlainGrid", is_usable(map, "PlainGrid"))
    io.println("-- and every one of these is not --")
    report.check_false("NotAComponent has no plan at all", plan_named(map, "NotAComponent").is_some())
    report.check_false("BadRouteStart", is_usable(map, "BadRouteStart"))
    report.check_false("BadPlaceholder", is_usable(map, "BadPlaceholder"))
    report.check_false("BadCatchAll", is_usable(map, "BadCatchAll"))
    report.check_false("BadDuplicatePlaceholder", is_usable(map, "BadDuplicatePlaceholder"))
    report.check_false("BadRequiredNotInRoute", is_usable(map, "BadRequiredNotInRoute"))
    report.check_false("BadUnbindable", is_usable(map, "BadUnbindable"))
    report.check_false("BadPrivateParam", is_usable(map, "BadPrivateParam"))
    report.check_false("BadOrphanPlaceholder", is_usable(map, "BadOrphanPlaceholder"))
    report.check_false("BadClashA — the FIRST of the pair, not only the second",
                       is_usable(map, "BadClashA"))
    report.check_false("BadClashB", is_usable(map, "BadClashB"))
    report.check_false("BadLayoutUnknown", is_usable(map, "BadLayoutUnknown"))
    report.check_false("BadLayoutNotALayout", is_usable(map, "BadLayoutNotALayout"))
    report.check_false("BadLayoutAmbiguous", is_usable(map, "BadLayoutAmbiguous"))
    report.check_false("BadLayoutLoop", is_usable(map, "BadLayoutLoop"))
    report.check_false("BadNoMethods", is_usable(map, "BadNoMethods"))
    // OrderGrid is NOT in this list any more. It used to be refused for its
    // generic ancestor; 0.1.41 constructs it on both backends, and § 2b
    // asserts it is usable rather than this section asserting it is not.
    report.check_false("the map as a whole is ok", map.ok())

    io.println("")
    io.println("== 3b. every refusal message, sorted, so the expected output reads them ==")
    var messages: List<string> = map.faults.clone()
    messages.sort()
    for message: string in messages { io.println("  {message}") }

    io.println("")
    io.println("== 4. a refused page is never routed to ==")
    report.check_true("a healthy page routes", map.find("GET", "/counter/3").is_some())
    report.check_false("a refused one does not", map.find("GET", "/orphan/x").is_some())
    report.check_false("nor does the ambiguous pair", map.find("GET", "/clash/x").is_some())

    io.println("")
    io.println("== 5. routes: parsing, matching, specificity, encoding ==")
    let pattern: RoutePattern = new RoutePattern(r"/orders/{id}/lines")
    report.check("segments", pattern.segments.len(), 3)
    report.check_text("shape", pattern.shape(), r"/orders/{}/lines")
    report.check_true("a trailing slash is the same page",
                      pattern.matches("/orders/7/lines/").is_some())
    report.check_false("a longer path is not", pattern.matches("/orders/7/lines/x").is_some())
    report.check_false("a shorter path is not", pattern.matches("/orders/7").is_some())
    match pattern.matches("/orders/a%2Fb/lines") {
        some(values) => {
            match values.get("id") {
                some(text) => {
                    report.check_text("a percent-escaped slash stays inside its segment",
                                      text, "a/b")
                }
                none => { report.check("id captured", 0, 1) }
            }
        }
        none => { report.check("the escaped path matched", 0, 1) }
    }
    report.check_text("percent_decode leaves a malformed escape alone",
                      percent_decode("a%zzb"), "a%zzb")
    report.check_text("percent_encode escapes a slash", percent_encode("a/b"), "a%2Fb")
    match new RoutePattern(r"/orders/{id}").link({"id": "a/b"}) {
        ok(url) => { report.check_text("a link round-trips through the encoder", url, "/orders/a%2Fb") }
        err(problem) => { report.check_text("link", problem, "/orders/a%2Fb") }
    }
    match new RoutePattern(r"/orders/{id}").link({}) {
        ok(url) => { report.check_text("a link with no value", url, "<refused>") }
        err(problem) => { report.check_true("a link with no value is refused",
                                            problem.contains("needs \"id\"")) }
    }
    // Specificity: `/orders/new` must win over `/orders/{id}` however they were
    // declared. Two literals against one literal and one placeholder is the
    // whole rule, and a suite that only had one route could never see it.
    match map.find("GET", "/orders/new") {
        some(found) => { report.check_text("a literal route wins", found.plan.name, "NewOrder") }
        none => { report.check("/orders/new matched", 0, 1) }
    }
    match map.find("GET", "/orders/12") {
        some(found) => { report.check_text("a placeholder takes the rest", found.plan.name, "ShowOrder") }
        none => { report.check("/orders/12 matched", 0, 1) }
    }
    report.check_false("a method the page does not serve is not a match",
                       map.find("DELETE", "/counter/3").is_some())
    report.check_true("a method it does is", map.find("POST", "/todo/4/true").is_some())

    io.println("")
    io.println("== 6. binding: every type, and every way it can fail ==")
    match map.find("GET", "/todo/12/yes") {
        some(found) => {
            let instance: PageInstance = open_page(found, allowed(), none)
            report.check("bound with no problem", instance.problems.len(), 0)
            report.check_text("and rendered", html_of(instance),
                "<main class=\"shell\"><div class=\"admin\"><article>todo 12 done=true q= ratio=0</article></div></main>")
        }
        none => { report.check("/todo/12/yes matched", 0, 1) }
    }
    match map.find("GET", "/todo/x/true") {
        some(found) => {
            let instance: PageInstance = open_page(found, allowed(), none)
            report.check("a bad int is one problem", instance.problems.len(), 1)
            report.check_text("...and says which parameter", instance.problems[0],
                              "\"x\" is not an int for \"id\"")
        }
        none => { report.check("/todo/x/true matched", 0, 1) }
    }
    match map.find("GET", "/todo/1/maybe") {
        some(found) => {
            let instance: PageInstance = open_page(found, allowed(), none)
            report.check_text("a bad bool", instance.problems[0],
                              "\"maybe\" is not a bool for \"done\"")
        }
        none => { report.check("/todo/1/maybe matched", 0, 1) }
    }
    // `to_int` saturates and stops at the first byte it dislikes, so these two
    // would otherwise bind as 12 and i64-max.
    match map.find("GET", "/todo/12abc/true") {
        some(found) => {
            report.check("a trailing-garbage int is refused, not truncated",
                         open_page(found, allowed(), none).problems.len(), 1)
        }
        none => { report.check("/todo/12abc/true matched", 0, 1) }
    }
    match map.find("GET", "/todo/99999999999999999999/true") {
        some(found) => {
            report.check("an overflowing int is refused, not saturated",
                         open_page(found, allowed(), none).problems.len(), 1)
        }
        none => { report.check("the overflowing path matched", 0, 1) }
    }

    io.println("")
    io.println("== 7. authorization ==")
    var none_needed: List<AuthRequirement> = []
    report.check_text("no requirement allows anyone",
                      describe_outcome(authorize_all(none_needed, new Anonymous())), "allow")
    match plan_named(map, "Todo") {
        some(plan) => {
            report.check_text("anonymous is challenged, not forbidden",
                              describe_outcome(plan.authorize(new Anonymous())), "challenge")
            report.check_text("signed in without the role is forbidden",
                              describe_outcome(plan.authorize(signed_in([], []))), "forbid")
            report.check_text("one of the roles is enough...",
                              describe_outcome(plan.authorize(signed_in(["editor"], []))), "forbid")
            report.check_text("...but the second @authorize must also hold",
                              describe_outcome(plan.authorize(signed_in(["editor"], ["beta"]))), "allow")
            report.check_text("the other role works too",
                              describe_outcome(plan.authorize(signed_in(["admin"], ["beta"]))), "allow")
            report.check_text("the policy alone is not enough",
                              describe_outcome(plan.authorize(signed_in([], ["beta"]))), "forbid")
        }
        none => { report.check("Todo was planned", 0, 1) }
    }
    match map.find("GET", "/todo/1/true") {
        some(found) => {
            let refused: PageInstance = open_page(found, new Anonymous(), none)
            report.check_false("open_page refuses an unauthorized mount", refused.ok())
            report.check_text("...and says which", refused.problems[0], "Todo: challenge")
            let r: Renderer = new Renderer()
            report.check_false("mount_page will not mount it", mount_page(r, refused))
            report.check("...and nothing was mounted", r.ids().len(), 0)
        }
        none => { report.check("/todo/1/true matched", 0, 1) }
    }

    io.println("")
    io.println("== 8. a layout chain is MOUNTED, not inlined ==")
    // This is the section that would pass just as well for a framework that
    // renders the page inline into its layout's frames — except for the render
    // counts. Marking the page must run one render; the two layouts above it
    // must stay where they were.
    match map.find("GET", "/todo/5/false") {
        some(found) => {
            let instance: PageInstance = open_page(found, allowed(), none)
            let r: Renderer = new Renderer()
            report.check_true("mounted", mount_page(r, instance))
            report.check("three components: two layouts and the page", r.ids().len(), 3)
            report.check("each rendered once", r.render_count(0) + r.render_count(r.ids()[1]) +
                                               r.render_count(r.ids()[2]), 3)
            let page_id: int = r.ids()[2]
            report.check("the page is the innermost", page_id, r.ids()[2])
            r.mark(page_id)
            report.check("marking the page runs ONE render", r.flush(), 1)
            report.check("the outer layout stayed at one", r.render_count(0), 1)
            report.check("the inner layout stayed at one", r.render_count(r.ids()[1]), 1)
            report.check("the page is at two", r.render_count(page_id), 2)
            report.check("faults", r.all_faults().len(), 0)
        }
        none => { report.check("/todo/5/false matched", 0, 1) }
    }
    // A page with no layout mounts as the root itself.
    match map.find("GET", "/") {
        some(found) => {
            let instance: PageInstance = open_page(found, allowed(), none)
            let r: Renderer = new Renderer()
            report.check_true("a page with no layout mounts", mount_page(r, instance))
            report.check("...as one component", r.ids().len(), 1)
            report.check_text("...and is the whole document", r.html(), "home")
        }
        none => { report.check("/ matched", 0, 1) }
    }

    io.println("")
    io.println("== 9. ParamWatch, beside the mistake it exists to stop ==")
    let host: WatchHost = new WatchHost()
    host.label = "a"
    let r: Renderer = new Renderer()
    r.mount(host)
    let watched: int = r.ids()[1]
    let unwatched: int = r.ids()[2]
    report.check("both children mounted", r.ids().len(), 3)
    report.check("Watched rendered once", r.render_count(watched), 1)
    report.check("Unwatched rendered once", r.render_count(unwatched), 1)
    r.mark(0)
    report.check("a parent pass with the SAME parameter", r.flush(), 2)
    report.check("Watched did not re-render", r.render_count(watched), 1)
    report.check("the hand-written version DID — that is the trap",
                 r.render_count(unwatched), 2)
    host.label = "b"
    r.mark(0)
    let _: int = r.flush()
    report.check("a parameter that changed re-renders Watched", r.render_count(watched), 2)
    report.check_false("ParamWatch has been fed", new ParamWatch().empty() == false)

    io.println("")
    io.println("== 10. a type name inside a string interpolation ==")
    //
    // This section used to assert a COMPILER BUG, deliberately, and said so:
    // "the day it is fixed, THIS EXPECTED OUTPUT GOES RED". The bug was that a type
    // name written inside `"{ }"` resolved without the file's
    // named-import bindings and fell back to composing the asking package's
    // own name with the simple name, so a consumer's `type_of(Component)`
    // read `<their package>.Component` — a name that exists nowhere.
    //
    // beans #164 closed it in 0.1.41, the expected output went red exactly as designed,
    // and this section now asserts the fix from the same place: an ENTRY
    // package, whose name is not `latte`, which is the only vantage point that
    // could ever see the bug. Latte's own files could not — `Component` is
    // declared in the package `pages.b` is written in, so the composed
    // fallback was right by coincidence.
    //
    // `probes/p12_consumer_type_of` and `probes/p13_interpolation_fixed` are
    // the same measurement from a consumer's module and across every
    // expression form; both backends agree on every line of both.
    let outside: reflect.Type = type_of(Component)
    let bound: string = outside.qualified_name()
    let inside: string = "{type_of(Component).qualified_name()}"
    io.println("   bound to a let, then interpolated: {bound}")
    io.println("   written inside the interpolation:  {inside}")
    report.check_text("outside an interpolation, type_of(Component) is right",
                      bound, "latte.Component")
    report.check_text("and inside one it is the SAME name, from an entry package",
                      inside, "latte.Component")
    report.check_true("the name from outside names a type",
                      reflect.find_type(bound).is_some())
    report.check_true("and so does the one from inside — find_type round-trips now",
                      reflect.find_type(inside).is_some())

    // The negative control, and it is the one that makes the two lines above
    // mean something. `latte$entry.Component` is the name the bug used to
    // compose. It must name NOTHING — otherwise "find_type round-trips" would
    // pass on a compiler that resolved every spelling to something.
    report.check_false("the name the bug used to compose still names nothing",
                       reflect.find_type("latte$entry.Component").is_some())

    // The controls that were here before the fix, kept: a type declared in
    // THIS file needs no import binding and could never be lost by one, and a
    // dot-path reference was unaffected too — which is what showed the bug was
    // about named imports and not about interpolation in general. They are the
    // reason the two assertions above can tell "imports are honoured" from
    // "interpolation mangles nothing at all".
    let local_outside: reflect.Type = type_of(Home)
    report.check_text("control: a type declared here reads the same inside",
                      "{type_of(Home).qualified_name()}", local_outside.qualified_name())
    let dotted: reflect.Type = type_of(reflect.Type)
    report.check_text("control: a dot-path type reads the same inside",
                      "{type_of(reflect.Type).qualified_name()}", dotted.qualified_name())

    // What the bug used to cost, now recovered: the two spellings agree about
    // a real subclass, inside an interpolation and out.
    report.check_true("is_assignable_from is right outside an interpolation",
                      outside.is_assignable_from(type_of(Home)))
    report.check_true("...and right inside one too, for the same real subclass",
                      "{type_of(Component).is_assignable_from(type_of(Home))}" == "true")
    report.check_true("extends_named answers true for the name from outside",
                      extends_named(type_of(Home), bound))
    report.check_true("...and true for the name from inside an interpolation",
                      extends_named(type_of(Home), inside))
    // extends_named's own negative control: a real name that is not an
    // ancestor must still answer false, or the four trues above would pass on
    // a function that answered true to everything.
    report.check_false("extends_named still says no to a type that is not an ancestor",
                       extends_named(type_of(Home), "std.reflect.Type"))

    io.println("")
    io.println("checks failed: {report.failures}")
}

fn allowed() -> Principal { return signed_in(["editor"], ["beta"]) }

fn signed_in(roles: List<string>, policies: List<string>) -> Principal {
    var who: User = new User()
    who.roles = roles.clone()
    who.policies = policies.clone()
    return who
}
