// tests/actions.b — a typed call from a browser region into the server.
//
// Everything here runs the REAL dispatcher: `scan_actions` over this file's
// own types, and `run_action` over the JSON a browser would have sent. What
// it does not do is HTTP — the route, the antiforgery token and the status
// codes are `tests/w4_actions.b`'s, and the browser half is
// `tools/client_check.mjs`.
//
// The claim that matters most is § 4: an action is checked on the SERVER,
// every time, for authorization and for the type of every argument. A
// framework that trusted the browser would pass § 2 and § 3 just as well.
package main

import std.io
import std.reflect
import {ActionMap, ActionPlan, ActionReply, ActionRequest, Activator,
        Anonymous, AuthOutcome, Principal, PropsPlan, ACTION_FORBIDDEN,
        ACTION_INVALID, ACTION_UNKNOWN, ACTION_FAILED, ACTION_OK,
        action, actions, dto_plan_for, encode_reply, run_action,
        scan_actions} from latte

// ---------------------------------------------------------------- DTOs

/// A reply of more than one field, because a one-field object hides every
/// separator and ordering bug an encoder has.
pub class Saved {
    pub stamp: string = ""
    pub size: int = 0
    pub clean: bool = false
    pub fn init() {}
}

/// An argument object.
pub class Draft {
    pub title: string = ""
    pub words: int = 0
    pub fn init() {}
}

/// A DTO with a field that cannot cross.
pub class Bad {
    pub tags: List<string> = []
    pub fn init() {}
}

// ---------------------------------------------------------------- groups

/// The group every dispatch case calls.
@actions(name: "notes")
pub class NoteActions {
    pub fn init() {}

    @action
    pub fn save(id: int, body: string) -> Result<string, string> {
        if body == "" { return err("a note needs a body") }
        return ok("note {id}: {body}")
    }

    @action
    pub fn describe(draft: Draft) -> Saved {
        var out: Saved = new Saved()
        out.stamp = draft.title
        out.size = draft.words
        out.clean = draft.words > 0
        return out
    }

    @action
    pub fn count(of: int, by: float, up: bool) -> int {
        if up { return of + (by as int) }
        return of - (by as int)
    }

    @action(roles: ["editor"])
    pub fn publish(id: int) -> string { return "published {id}" }
}

/// A group whose name is not a word a URL can carry.
@actions(name: "not a name")
pub class BadlyNamed {
    pub fn init() {}
    @action
    pub fn go() -> string { return "" }
}

/// A group that declares no action at all.
@actions(name: "empty")
pub class NoActions {
    pub fn init() {}
    pub fn helper() -> string { return "" }
}

/// An `@action` on a type nothing routes to.
pub class Stray {
    pub fn init() {}
    @action
    pub fn wander() -> string { return "" }
}

/// Every per-method refusal in one group, so one scan raises all of them.
@actions(name: "broken")
pub class BrokenActions {
    pub fn init() {}

    @action
    fn hidden() -> string { return "" }

    @action
    pub static fn detached() -> string { return "" }

    @action
    pub fn generic<T>(value: T) -> string { return "" }

    @action
    pub fn wrong_argument(rows: List<string>) -> string { return "" }

    @action
    pub fn wrong_reply() -> List<string> { return [] }

    @action
    pub fn wrong_error() -> Result<string, int> { return ok("") }

    @action
    pub fn wrapped_dto() -> Result<Saved, string> { return ok(new Saved()) }
}

/// Two groups under one name, each with a `clash`, so both are refused.
@actions(name: "twice")
pub class FirstTwin {
    pub fn init() {}
    @action
    pub fn clash() -> string { return "one" }
}

@actions(name: "twice")
pub class SecondTwin {
    pub fn init() {}
    @action
    pub fn clash() -> string { return "two" }
}

// ---------------------------------------------------------------- who

/// A principal with roles, so authorization is exercised rather than
/// assumed.
pub class Editor implements Principal {
    pub fn init() {}
    pub fn authenticated() -> bool { return true }
    pub fn has_role(role: string) -> bool { return role == "editor" }
    pub fn satisfies(policy: string) -> bool { return false }
}

// ---------------------------------------------------------------- report

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
            io.println("FAIL {label}:")
            io.println("  got  {got}")
            io.println("  want {want}")
        }
    }
}

/// This file's package, as reflection spells it. A suite under the latte
/// module root is not `main`.
fn here() -> string {
    let name: string = type_of(Saved).qualified_name()
    return name.slice(0, name.len() - "Saved".len())
}

/// The one fault that mentions `needle`, or how many did instead.
fn only_fault(list: List<string>, needle: string) -> string {
    var found: List<string> = []
    for fault: string in list {
        if fault.contains(needle) { found.push(fault) }
    }
    if found.len() == 1 { return found[0] }
    return "{found.len()} faults mention \"{needle}\""
}

fn call(map: ActionMap, name: string, arguments: string,
        who: Principal) -> ActionReply {
    var asked: ActionRequest = new ActionRequest()
    asked.name = name
    asked.arguments = arguments
    asked.who = who
    return run_action(map, asked, none)
}

// ---------------------------------------------------------------- 1. scan

fn section_scan(report: Report, map: ActionMap) {
    io.println("== 1. the scan finds every action and names every group ==")
    report.same("the actions this executable answers", map.names().join(", "),
                "broken.detached, broken.generic, broken.hidden, broken.wrapped_dto, broken.wrong_argument, broken.wrong_error, broken.wrong_reply, notes.count, notes.describe, notes.publish, notes.save, twice.clash")
    match map.find("notes.save") {
        none => { report.same("notes.save is usable", "missing", "found") }
        some(plan) => {
            report.same("notes.save is usable", "found", "found")
            report.same("  its parameters", plan.parameters.join(", "), "id, body")
            report.same("  its reply", plan.result_name, "Result<string, string>")
            report.same("  read as a Result", "{plan.result_is_result}", "true")
        }
    }
    match map.find("notes.publish") {
        none => { report.same("notes.publish is usable", "missing", "found") }
        some(plan) => {
            report.same("notes.publish carries its roles",
                        "{plan.requirements.len()}", "1")
        }
    }
    // A refused action is not routable, which is the whole point of refusing
    // it at startup rather than at the call.
    match map.find("broken.hidden") {
        none => { report.same("a refused action is not routable", "gone", "gone") }
        some(_) => { report.same("a refused action is not routable", "found", "gone") }
    }
}

// ---------------------------------------------------------------- 2. call

fn section_call(report: Report, map: ActionMap) {
    io.println("")
    io.println("== 2. a call, its arguments and its reply ==")
    let who: Principal = new Anonymous()

    let saved: ActionReply = call(map, "notes.save",
                                  "\{\"id\":7,\"body\":\"hello\"\}", who)
    report.same("a Result that succeeded", saved.encode(),
                "\{\"ok\":true,\"k\":\"ok\",\"v\":\"note 7: hello\",\"e\":\"\"\}")

    let failed: ActionReply = call(map, "notes.save",
                                   "\{\"id\":7,\"body\":\"\"\}", who)
    report.same("a Result that failed", failed.encode(),
                "\{\"ok\":false,\"k\":\"failed\",\"v\":null,\"e\":\"a note needs a body\"\}")

    let described: ActionReply = call(map, "notes.describe",
        "\{\"draft\":\{\"title\":\"a note\",\"words\":12\}\}", who)
    report.same("a DTO in and a DTO out", described.encode(),
                "\{\"ok\":true,\"k\":\"ok\",\"v\":\{\"stamp\":\"a note\",\"size\":12,\"clean\":true\},\"e\":\"\"\}")

    let counted: ActionReply = call(map, "notes.count",
        "\{\"of\":10,\"by\":2.5,\"up\":true\}", who)
    report.same("three scalars, one of them a float", counted.encode(),
                "\{\"ok\":true,\"k\":\"ok\",\"v\":12,\"e\":\"\"\}")

    // A whole number is a legal float on the wire: JSON has one number type.
    let whole: ActionReply = call(map, "notes.count",
        "\{\"of\":10,\"by\":2,\"up\":false\}", who)
    report.same("and a whole number is a float too", whole.encode(),
                "\{\"ok\":true,\"k\":\"ok\",\"v\":8,\"e\":\"\"\}")
}

// ---------------------------------------------------------------- 3. refuse

fn section_refuse(report: Report, map: ActionMap) {
    io.println("")
    io.println("== 3. what a call is refused for, before it runs ==")
    let who: Principal = new Anonymous()

    report.same("an action nobody declared",
                call(map, "notes.nowhere", "\{\}", who).message,
                "no action is named \"notes.nowhere\"")
    report.same("an argument that is missing",
                call(map, "notes.save", "\{\"id\":1\}", who).message,
                "notes.save: the argument \"body\" is missing")
    report.same("an argument of the wrong type",
                call(map, "notes.save", "\{\"id\":\"one\",\"body\":\"x\"\}", who).message,
                "notes.save: \"id\" is not an int")
    report.same("a body that is not JSON",
                call(map, "notes.save", "not json", who).kind, ACTION_INVALID)
    report.same("a body that is not an object",
                call(map, "notes.save", "[1,2]", who).message,
                "notes.save: the arguments must be a JSON object")
    report.same("a DTO argument that is not an object",
                call(map, "notes.describe", "\{\"draft\":3\}", who).message,
                "notes.describe: \"draft\" is a {here()}Draft and must be a JSON object")

    // The one that matters: the browser cannot talk its way past a role.
    report.same("a role the caller does not have",
                call(map, "notes.publish", "\{\"id\":1\}", who).kind,
                ACTION_FORBIDDEN)
    let editor: Principal = new Editor()
    report.same("and the same call from somebody who does",
                call(map, "notes.publish", "\{\"id\":1\}", editor).encode(),
                "\{\"ok\":true,\"k\":\"ok\",\"v\":\"published 1\",\"e\":\"\"\}")
}

// ---------------------------------------------------------------- 4. sites

const A_DTO: string = "dto_plan_for / a field that cannot cross"
const A_STRAY: string = "scan_actions / @action on a type that is not @actions"
const A_GROUP: string = "scan_actions / a group name a URL cannot carry"
const A_CLASH_NEW: string = "scan_actions / two actions under one name, the second"
const A_CLASH_OLD: string = "scan_actions / two actions under one name, the first"
const A_RELAY: string = "scan_actions / a plan's faults reach the map's"
const A_EMPTY: string = "scan_actions / a group with no action in it"
const A_PUBLIC: string = "plan_for_action / a method that is not public"
const A_GENERIC: string = "plan_for_action / a generic method"
const A_STATIC: string = "plan_for_action / a static method"
const A_ARGUMENT: string = "plan_for_action / a parameter that cannot cross"
const A_ERROR: string = "plan_for_action / a Result whose error is not a string"
const A_REPLY: string = "plan_for_action / a reply that cannot cross"
const A_WRAPPED: string = "plan_for_action / a Result of something that is not a scalar"

fn site_case(report: Report, reached: Map<string, int>, name: string,
             site: string, got: string, want: string, control: string) {
    io.println("-- {name}")
    io.println("   site:    {site}")
    io.println("   fault:   {got}")
    io.println("   control: {control}")
    report.same("{name}: the exact fault", got, want)
    report.same("{name}: the control is quiet", control, "(quiet)")
    match reached.get(site) {
        some(n) => { reached[site] = n + 1 }
        none => { reached[site] = 1 }
    }
}

/// `"(quiet)"` when nothing in `list` mentions `needle`.
fn quiet_about(list: List<string>, needle: string) -> string {
    for fault: string in list {
        if fault.contains(needle) { return fault }
    }
    return "(quiet)"
}

fn section_sites(report: Report, map: ActionMap) {
    io.println("")
    io.println("== 4. every fault site in actions.b ==")
    var reached: Map<string, int> = {}
    var faults: List<string> = []
    for fault: string in map.faults { faults.push(fault) }

    let bad_dto: PropsPlan = dto_plan_for(type_of(Bad))
    site_case(report, reached, "a-dto-field-that-cannot-cross", A_DTO,
        only_fault(bad_dto.faults, "tags"),
        "{here()}Bad.tags is a List<string>, which cannot cross a server action; a field of a DTO is a string, an int, a bool or a float",
        quiet_about(dto_plan_for(type_of(Saved)).faults, "Saved"))

    site_case(report, reached, "an-action-outside-a-group", A_STRAY,
        only_fault(faults, "Stray.wander"),
        "{here()}Stray.wander is annotated @action but {here()}Stray is not annotated @actions, so nothing would ever route to it",
        quiet_about(faults, "NoteActions.save"))

    site_case(report, reached, "a-group-name-a-url-cannot-carry", A_GROUP,
        only_fault(faults, "not a name"),
        "{here()}BadlyNamed is annotated @actions(name: \"not a name\"); an action group's name reaches a URL path, so it is letters, digits, '-' and '_'",
        quiet_about(faults, "\"notes\""))

    // The clash is one message recorded on BOTH plans, so it shows up twice
    // in the map's list — which is the point: refusing only the second would
    // make the answer depend on declaration order.
    var clashes: int = 0
    for fault: string in faults {
        if fault.contains("both answer the action") { clashes += 1 }
    }
    site_case(report, reached, "two-actions-under-one-name-the-second",
        A_CLASH_NEW,
        "{clashes} plan(s) carry the clash",
        "2 plan(s) carry the clash",
        quiet_about(faults, "notes.save and"))

    // And the FIRST of the two is refused as well, which is what stops the
    // pair being a coin toss decided by declaration order.
    var routable: string = "twice.clash is still routable"
    match map.find("twice.clash") { none => { routable = "refused" } some(_) => {} }
    site_case(report, reached, "two-actions-under-one-name-the-first",
        A_CLASH_OLD, routable, "refused",
        quiet_about(["notes.save"], "twice"))

    site_case(report, reached, "a-group-with-no-action", A_EMPTY,
        only_fault(faults, "NoActions"),
        "{here()}NoActions is annotated @actions and declares no @action method, so the group answers nothing",
        quiet_about(faults, "NoteActions is annotated"))

    site_case(report, reached, "a-method-that-is-not-public", A_PUBLIC,
        only_fault(faults, "hidden"),
        "{here()}BrokenActions.hidden is annotated @action but is not public, and reflection does not bypass visibility",
        quiet_about(faults, "notes.count"))

    site_case(report, reached, "a-generic-method", A_GENERIC,
        only_fault(faults, "is generic"),
        "{here()}BrokenActions.generic is annotated @action and is generic; a reflective call cannot name which instantiation to run, so latte could never dispatch it",
        quiet_about(faults, "notes.describe"))

    site_case(report, reached, "a-static-method", A_STATIC,
        only_fault(faults, "is static"),
        "{here()}BrokenActions.detached is annotated @action and is static; an action group is built by the container so it can hold its services, and a static method has no receiver to build",
        quiet_about(faults, "notes.publish"))

    site_case(report, reached, "a-parameter-that-cannot-cross", A_ARGUMENT,
        only_fault(faults, "the parameter \"rows\""),
        "{here()}BrokenActions.wrong_argument: the parameter \"rows\" is a List<string>, which cannot cross a server action. A parameter is a string, an int, a bool, a float, or a class whose public fields are all of those",
        quiet_about(faults, "the parameter \"id\""))

    site_case(report, reached, "an-error-side-that-is-not-a-string", A_ERROR,
        only_fault(faults, "the error side"),
        "{here()}BrokenActions.wrong_error returns Result<string, int>; an action's failure crosses as text, so the error side of its Result must be a string",
        quiet_about(faults, "Result<string, string>"))

    site_case(report, reached, "a-reply-that-cannot-cross", A_REPLY,
        only_fault(faults, "answers a List<string>"),
        "{here()}BrokenActions.wrong_reply answers a List<string>, which cannot cross a server action. A reply is a string, an int, a bool, a float, or a class whose public fields are all of those",
        quiet_about(faults, "answers a {here()}Saved"))

    site_case(report, reached, "a-result-of-a-class", A_WRAPPED,
        only_fault(faults, "wrapped_dto"),
        "{here()}BrokenActions.wrapped_dto answers Result<{here()}Saved, string>; latte can read a Result of a string, an int, a bool or a float, and not of a class — reading one back needs the closed type spelled out and a dispatcher only has a descriptor. Answer the {here()}Saved directly and carry the failure in a field of it, or answer a Result of one scalar",
        quiet_about(faults, "notes.describe"))

    // The relay: a plan's own faults are copied onto the map's, which is the
    // list a host refuses on.
    var relayed: int = 0
    for name: string in map.plans.keys() {
        match map.plans.get(name) {
            some(plan) => {
                for fault: string in plan.faults {
                    if faults.contains(fault) { relayed += 1 }
                }
            }
            none => {}
        }
    }
    site_case(report, reached, "a-plans-faults-reach-the-map", A_RELAY,
        "{relayed} of a plan's faults reached the map",
        "9 of a plan's faults reached the map",
        quiet_about(faults, "notes.save:"))

    var names: List<string> = reached.keys()
    names.sort()
    io.println("-- the sites in actions.b, and how many shapes reach each")
    for name: string in names {
        match reached.get(name) { some(n) => { io.println("   {n}x {name}") } none => {} }
    }
}

// ---------------------------------------------------------------- 5. encode

fn section_encode(report: Report) {
    io.println("")
    io.println("== 5. a reply's encoding, one value at a time ==")
    report.same("a string", encode_reply(reflect.value("a \"quoted\" word")),
                "\"a \\\"quoted\\\" word\"")
    report.same("an int", encode_reply(reflect.value(-9)), "-9")
    report.same("a bool", encode_reply(reflect.value(true)), "true")
    report.same("a float", encode_reply(reflect.value(0.5)), "0.5")
    var saved: Saved = new Saved()
    saved.stamp = "s"
    saved.size = 2
    report.same("a DTO, in declaration order", encode_reply(reflect.value(saved)),
                "\{\"stamp\":\"s\",\"size\":2,\"clean\":false\}")
}

fn main() {
    let report: Report = new Report()
    let map: ActionMap = scan_actions()
    section_scan(report, map)
    section_call(report, map)
    section_refuse(report, map)
    section_sites(report, map)
    section_encode(report)
    io.println("")
    io.println("{report.checks} checks, {report.bad} bad")
}
