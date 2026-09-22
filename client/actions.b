// Calling a server action from a browser region.
//
// The author writes this:
//
// ```beans
// var args: ActionArgs = new ActionArgs()
// args.int("id", self.id)
// args.text("body", self.draft)
// self.call = call_action<Saved>("notes.save", args,
//     fn(answer: Result<Saved, ActionError>) {
//         self.pending = false
//         match answer {
//             ok(saved) => { self.stamp = saved.stamp }
//             err(problem) => { self.trouble = problem.message }
//         }
//         self.notify()
//     })
// ```
//
// and nothing else: no fetch, no JSON, no endpoint, no token. The arguments
// are encoded here, the reply is decoded into `Saved` by reflection, and the
// page performs the request with the antiforgery token the document carries.
//
// ## Three rules, and each one is a decision
//
// **Nothing is retried.** Not a timeout, not a dropped connection, not a 500.
// An action is a mutation until somebody proves otherwise, and a framework
// cannot. A caller who knows theirs is safe to repeat calls it again.
//
// **Replies arrive in the order the network answers, not the order you
// sent.** Two calls in flight can land either way round. An action that must
// not interleave with the one before it is sent from the previous one's
// callback — which is a sequence you can see, rather than a guarantee this
// file would have to keep and could not.
//
// **A cancelled call is forgotten, not stopped.** `cancel` drops the callback
// and tells the page to abandon the request; the server may already have run
// the action. Cancelling a mutation does not undo it.
package latte_client

import std.fmt
import std.reflect
import {ActionError, Json, ParamKind, PropsPlan, decode_props, dto_plan_for,
        parse_json, props_limits, props_kind_of, write_json_string} from latte

/// How a call reaches the page, installed by the browser entry.
///
/// **Two closures and not two `extern "C"` declarations, and the reason is a
/// link error.** A `client` component that calls an action imports this
/// module, and the SERVER renders that same component for the prerender —
/// so a declaration here would put `latte_js_action` in the server binary,
/// where nothing defines it and the link fails with a symbol nobody wrote.
/// The entry that runs in a browser declares the imports and hands them over
/// here; every other build links two closures that are never called.
///
/// With none installed, `send` answers -1, which `ActionSender` reads as
/// "the page would not send this call" — the right answer on a server,
/// where there is no page.
pub class ActionTransport {
    pub send: fn(int, RawPtr<i8>, int, RawPtr<i8>, int) -> int =
        fn(call: int, name: RawPtr<i8>, name_len: int,
           body: RawPtr<i8>, body_len: int) -> int { return -1 }
    pub cancel: fn(int) -> int = fn(call: int) -> int { return 0 }
    pub fn init() {}
}

/// Hand the region runtime the page's half of a call. The browser entry
/// calls this before `boot`.
pub fn install_action_transport(
        send: fn(int, RawPtr<i8>, int, RawPtr<i8>, int) -> int,
        cancel: fn(int) -> int) {
    var transport: ActionTransport = new ActionTransport()
    transport.send = send
    transport.cancel = cancel
    ActionSender.instance.install(transport)
}

/// The arguments of one call, by the names the server's method declares.
///
/// A builder and not a second DTO class, because the parameter names are the
/// server's and a class here would be a copy of a signature that lives
/// somewhere else. A name the method does not take, or one it takes and this
/// does not set, is refused by the server with the parameter named.
pub class ActionArgs {
    parts: List<string> = []
    pub fn init() {}

    pub fn text(name: string, value: string) {
        self.parts.push("{quoted(name)}:{quoted(value)}")
    }

    pub fn int(name: string, value: int) {
        self.parts.push("{quoted(name)}:{value}")
    }

    pub fn bool(name: string, value: bool) {
        if value { self.parts.push("{quoted(name)}:true") }
        else { self.parts.push("{quoted(name)}:false") }
    }

    pub fn number(name: string, value: float) {
        self.parts.push("{quoted(name)}:{value}")
    }

    /// The JSON object the call carries.
    pub fn encode() -> string { return "\{{self.parts.join(",")}\}" }
}

fn quoted(text: string) -> string {
    var out: fmt.StringBuilder = new fmt.StringBuilder()
    write_json_string(out, text)
    return out.to_string()
}

/// Every call in flight, and what to do when one answers.
pub singleton class ActionSender {
    next: int = 1
    /// call id -> the decoder-and-callback pair, as one closure over text.
    pending: Map<int, fn(bool, string)> = {}
    /// call id -> the region that started it, so the page knows whose batch
    /// to take once the callback has run.
    owners: Map<int, int> = {}
    pub sent: int = 0
    pub answered: int = 0
    pub cancelled: int = 0
    transport: ActionTransport = new ActionTransport()

    fn init() {}

    pub fn install(made: ActionTransport) { self.transport = made }

    /// The page's half, for `ask_page` and `cancel`.
    pub fn page() -> ActionTransport { return self.transport }

    pub fn in_flight() -> int { return self.pending.len() }
    pub fn waiting(call: int) -> bool { return self.pending.contains_key(call) }

    /// Send one call. Answers its id, or -1 when the page would not send it.
    pub fn send(region: int, name: string, body: string,
                then: fn(bool, string)) -> int {
        let call: int = self.next
        self.next += 1
        self.pending[call] = then
        self.owners[call] = region
        self.sent += 1
        let bytes: Bytes = Bytes.from(name)
        let payload: Bytes = Bytes.from(body)
        let answer: int = ask_page(self.transport, call, bytes, payload)
        if answer < 0 {
            let _: bool = self.pending.remove(call)
            let _: bool = self.owners.remove(call)
            then(false, "\{\"k\":\"offline\",\"e\":\"the page would not send this call\"\}")
            return -1
        }
        return call
    }

    /// Forget a call. The server may already have run it.
    pub fn cancel(call: int) -> bool {
        if !self.pending.contains_key(call) { return false }
        let _: bool = self.pending.remove(call)
        let _: bool = self.owners.remove(call)
        self.cancelled += 1
        let abandon: fn(int) -> int = self.transport.cancel
        let _: int = abandon(call)
        return true
    }

    /// One answer from the page. Returns the region that must be re-read, or
    /// 0 when the call belonged to nobody.
    pub fn deliver(call: int, ok: bool, payload: string) -> int {
        match self.pending.get(call) {
            none => { return 0 }
            some(then) => {
                var region: int = 0
                match self.owners.get(call) { some(id) => { region = id } none => {} }
                let _: bool = self.pending.remove(call)
                let _: bool = self.owners.remove(call)
                self.answered += 1
                then(ok, payload)
                return region
            }
        }
    }
}

fn ask_page(transport: ActionTransport, call: int, name: Bytes,
            body: Bytes) -> int {
    let send: fn(int, RawPtr<i8>, int, RawPtr<i8>, int) -> int = transport.send
    unsafe {
        let name_ptr: RawPtr<i8> = RawPtr.from_address(name.as_ptr().address())
        let body_ptr: RawPtr<i8> = RawPtr.from_address(body.as_ptr().address())
        return send(call, name_ptr, name.len(), body_ptr, body.len())
    }
}

/// Send one action and decode its reply into `T`.
///
/// `T` is a string, an int, a bool, a float, or a class whose public fields
/// are all of those. A reply that does not fit is an `ActionError` with the
/// reason, never a half-filled object.
pub fn call_action<T>(name: string, args: ActionArgs,
                      then: fn(Result<T, ActionError>)) -> int {
    let region: int = ClientApp.instance.current_region()
    return ActionSender.instance.send(region, name, args.encode(),
        fn(ok: bool, payload: string) {
            then(read_reply<T>(ok, payload))
        })
}

fn read_reply<T>(ok: bool, payload: string) -> Result<T, ActionError> {
    var root: Json = new Json()
    match parse_json(payload, props_limits()) {
        err(problem) => {
            return err(new ActionError("invalid",
                "the server's answer is not JSON: {problem}"))
        }
        ok(parsed) => { root = parsed }
    }
    if !root.is_object() {
        return err(new ActionError("invalid",
            "the server's answer is not a JSON object"))
    }
    if !root.bool_field("ok", false) {
        return err(new ActionError(root.text_field("k", "failed"),
                                   root.text_field("e", "the action did not run")))
    }
    match root.field("v") {
        none => {
            return err(new ActionError("invalid",
                "the server's answer carries no value"))
        }
        some(value) => { return decode_reply<T>(value) }
    }
}

fn decode_reply<T>(value: Json) -> Result<T, ActionError> {
    let described: reflect.Type = type_of(T)
    match props_kind_of(described) {
        text => {
            if !value.is_text() { return wrong<T>("a string", described) }
            return cast<T>(reflect.value(value.text), described)
        }
        integer => {
            if !value.is_int() { return wrong<T>("an int", described) }
            return cast<T>(reflect.value(value.number), described)
        }
        boolean => {
            if !value.is_bool() { return wrong<T>("a bool", described) }
            return cast<T>(reflect.value(value.truth), described)
        }
        number => {
            if !value.is_number() { return wrong<T>("a number", described) }
            return cast<T>(reflect.value(value.as_float()), described)
        }
        other => {
            if !value.is_object() { return wrong<T>("an object", described) }
            match activate_reply(described) {
                err(problem) => { return err(new ActionError("invalid", problem)) }
                ok(made) => {
                    let plan: PropsPlan = dto_plan_for(described)
                    if !plan.usable() {
                        return err(new ActionError("invalid",
                            plan.faults.join("; ")))
                    }
                    let problems: List<string> = decode_props(made.copy(), plan, value)
                    if problems.len() > 0 {
                        return err(new ActionError("invalid", problems.join("; ")))
                    }
                    return cast<T>(made, described)
                }
            }
        }
    }
}

fn cast<T>(value: reflect.Value, described: reflect.Type) -> Result<T, ActionError> {
    match value.copy() as? T {
        some(held) => { return ok(held) }
        none => {
            return err(new ActionError("invalid",
                "the server's answer is not a {described.qualified_name()}"))
        }
    }
}

fn wrong<T>(wanted: string, described: reflect.Type) -> Result<T, ActionError> {
    return err(new ActionError("invalid",
        "the server answered something that is not {wanted}, and {described.qualified_name()} needs one"))
}

fn activate_reply(described: reflect.Type) -> Result<reflect.Value, string> {
    match described.initializer() {
        some(ctor) => {
            match ctor.call([]) {
                ok(made) => { return ok(made) }
                err(problem) => {
                    return err("cannot build {described.qualified_name()}: {problem.message()}")
                }
            }
        }
        none => {
            return err("{described.qualified_name()} has no zero-argument initializer, so a reply cannot be decoded into one")
        }
    }
}

// ---------------------------------------------------------------- the ABI

pub fn action_result_raw(call: int, ok: int, payload: RawPtr<i8>,
                         payload_len: int) -> int {
    let region: int = ActionSender.instance.deliver(call, ok == 1,
                                                    text_in(payload, payload_len))
    if region <= 0 { return 0 }
    // The callback may have changed the component's state, so the region is
    // rendered and its batch made ready before the page is told which one to
    // read.
    ClientApp.instance.settle(region)
    return region
}

pub fn action_cancel_raw(call: int) -> int {
    if ActionSender.instance.cancel(call) { return 1 }
    return 0
}

pub fn actions_in_flight() -> int { return ActionSender.instance.in_flight() }
