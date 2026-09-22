// The browser half of an execution boundary.
//
// A `client` region is a latte `Renderer` like any other. It mounts the
// component, runs its handlers, re-renders what changed and diffs it — the
// same `Builder`, the same `Differ`, the same wire encoder the server uses.
// What differs is only where the edits go: into the page's own applier,
// through one WebAssembly call, instead of down a socket.
//
// That is the whole point of the design, and the reason it is not a second
// framework: a component compiled for the browser and the same component
// rendered on the server are one class running one `render`, and the bytes
// they produce are compared by `tests/client.b` on both server backends and
// by `tools/client_check.mjs` in three real browsers.
//
// Three rules hold here and each one is a thing a page could otherwise do:
//
//   1. **A region never renders the page.** It is handed a boundary id, a
//      type name and a props object, and it mounts exactly that. Nothing
//      here has a route, a session or a service.
//   2. **Every string crosses as (pointer, length) and is copied.** The call
//      that follows may grow the memory; a borrowed pointer would then be
//      looking at a different page of it.
//   3. **An export answers an integer.** The reason for a -1 comes back
//      through `last_error`, because there is nowhere else for it to go.
package latte_client

import std.reflect
import {Batch, ClientMessage, Component, Json, ModeScan, PropsPlan, RenderMode,
        Renderer, ServiceSource, WireLimits, CLIENT_EVENT, FAMILY_FOCUS, FAMILY_INPUT,
        FAMILY_KEYBOARD, FAMILY_MOUSE, FAMILY_SUBMIT, decode_client,
        decode_props, encode_batch, focus_event, input_event, keyboard_event,
        extends_named, mouse_event, parse_json, props_limits, props_plan_for,
        scan_render_modes, submit_event} from latte

/// One mounted region: a component, a renderer, and the edits it owes the
/// page.
class Region {
    pub handle: int = 0
    pub boundary: string = ""
    pub type_name: string = ""
    pub renderer: Renderer = new Renderer()
    pub plan: PropsPlan = new PropsPlan()
    pub instance: Option<reflect.Value> = none
    /// The batch number, which counts per region. The page applies a
    /// region's batches into that region's applier and nowhere else, so two
    /// regions' numbers never meet.
    pub number: int = 0
    /// The encoded batch waiting to be read, or `""`.
    pub outbox: string = ""
    pub fn init() {}
}

/// Everything the page drives. One per module, because one page loads one
/// bundle and a second instance would be a second reflection scan.
pub singleton class ClientApp {
    regions: Map<int, Region> = {}
    next: int = 1
    booted: bool = false
    current: int = 0
    /// Where a client region's `@inject` fields come from.
    ///
    /// EMPTY by default, and that is a decision rather than an omission: a
    /// browser has no request, no session and no connection pool, so the
    /// container an application registers on the server is not a thing that
    /// could be shipped here. A browser implementation of a service
    /// interface is an object this side builds, and `provide` is where an
    /// entry hands one over — before `boot`, from its own code:
    ///
    /// ```beans
    /// pub extern "C" fn latte_client_boot() -> i32 {
    ///     provide_services(new BrowserClock())
    ///     return boot_raw() as i32
    /// }
    /// ```
    ///
    /// With none, a component with an `@inject` field refuses at mount with
    /// the field named, rather than mounting with its placeholder.
    services: Option<ServiceSource> = none
    modes: ModeScan = new ModeScan()
    /// Qualified name -> the type, built once. A linear scan of
    /// `reflect.types()` per mount is what a page with fifty regions would
    /// otherwise pay, and the answer never changes.
    types: Map<string, reflect.Type> = {}
    last_error: string = ""

    fn init() {}

    // ---- the page's calls -------------------------------------------------

    /// Read the type table and the mode declarations. Idempotent.
    pub fn boot() -> int {
        if self.booted { return 0 }
        self.booted = true
        // Inside a client region the mode that is inherited is `client`: the
        // region around this one is this runtime. A nested region that
        // declares `static` is a boundary here exactly as it would be on the
        // server, and one that declares `client` is not a boundary at all.
        self.modes = scan_render_modes(RenderMode.client)
        for described: reflect.Type in reflect.types() {
            self.types[described.qualified_name()] = described
        }
        if self.modes.faults.len() > 0 {
            self.last_error = self.modes.faults.join("; ")
        }
        return 0
    }

    /// Mount one region and answer its handle, or -1.
    pub fn mount(boundary: string, type_name: string, props: string) -> int {
        let _: int = self.boot()
        match self.types.get(type_name) {
            none => {
                return self.fail("this browser bundle has no {type_name}; the component is not reachable from the browser entry, so nothing in the page can build it")
            }
            some(described) => {
                match activate(described) {
                    err(problem) => { return self.fail(problem) }
                    ok(made) => {
                        match made.copy() as? Component {
                            none => {
                                return self.fail("{type_name} is not a latte Component")
                            }
                            some(component) => {
                                return self.start(boundary, type_name, described,
                                                  made, component, props)
                            }
                        }
                    }
                }
            }
        }
    }

    fn start(boundary: string, type_name: string, described: reflect.Type,
             made: reflect.Value, component: Component, props: string) -> int {
        var region: Region = new Region()
        region.handle = self.next
        self.next += 1
        region.boundary = boundary
        region.type_name = type_name
        region.plan = props_plan_for(described)
        if !region.plan.usable() {
            return self.fail(region.plan.faults.join("; "))
        }
        region.instance = some(made.copy())
        let problems: List<string> = self.write_props(region, props)
        if problems.len() > 0 { return self.fail(problems.join("; ")) }
        region.renderer.modes = self.modes
        region.renderer.services = self.services
        region.renderer.owner_mode = RenderMode.client
        region.renderer.inherited_mode = RenderMode.client
        region.renderer.region_path = "{boundary}."
        // A component may start a server action from `on_init`, which runs
        // inside this mount, so the region has to be the current one before
        // the mount rather than after it.
        self.regions[region.handle] = region
        let held: int = self.current
        self.current = region.handle
        region.renderer.mount(component)
        self.current = held
        let faults: List<string> = region.renderer.all_faults()
        if faults.len() > 0 {
            let _: bool = self.regions.remove(region.handle)
            return self.fail(faults.join("; "))
        }
        self.publish(region)
        return region.handle
    }

    /// New props from the region around this one.
    ///
    /// The instance is the same one: a prop change is a parameter pass, not a
    /// remount. Anything the component holds that is not a prop — a count, a
    /// draft, a scroll position — survives it, which is the behaviour a
    /// parameter has everywhere else in latte.
    pub fn props(handle: int, props: string) -> int {
        match self.regions.get(handle) {
            none => { return self.fail("no region {handle}") }
            some(region) => {
                let problems: List<string> = self.write_props(region, props)
                if problems.len() > 0 { return self.fail(problems.join("; ")) }
                match region.renderer.page {
                    none => { return self.fail("region {handle} has no component") }
                    some(component) => {
                        component.params_arrived()
                        component.notify()
                    }
                }
                let _: int = region.renderer.flush()
                self.publish(region)
                return 0
            }
        }
    }

    /// One DOM event, as the page's own serializer wrote it.
    ///
    /// The message is decoded by `wire.b`'s reader — the same one the server
    /// uses — so a payload the page could not have produced is refused here
    /// the way it would be there, and `k` selects a family rather than a
    /// method name.
    pub fn event(handle: int, message_text: string) -> int {
        match self.regions.get(handle) {
            none => { return self.fail("no region {handle}") }
            some(region) => {
                var limits: WireLimits = new WireLimits()
                let message: ClientMessage = decode_client(message_text, limits)
                if message.kind != CLIENT_EVENT {
                    return self.fail("region {handle}: {message.fault}")
                }
                var landed: bool = false
                let held: int = self.current
                self.current = handle
                if message.family == FAMILY_MOUSE {
                    landed = region.renderer.fire_mouse(message.handler, mouse_event(message))
                } else if message.family == FAMILY_INPUT {
                    landed = region.renderer.fire_input(message.handler, input_event(message))
                } else if message.family == FAMILY_KEYBOARD {
                    landed = region.renderer.fire_keyboard(message.handler, keyboard_event(message))
                } else if message.family == FAMILY_SUBMIT {
                    landed = region.renderer.fire_submit(message.handler, submit_event(message))
                } else if message.family == FAMILY_FOCUS {
                    landed = region.renderer.fire_focus(message.handler, focus_event(message))
                }
                self.current = held
                // A stale slot is not an error: it is what a click that
                // raced a re-render looks like, and the server drops one the
                // same way.
                if !landed { return 0 }
                let _: int = region.renderer.flush()
                self.publish(region)
                return 0
            }
        }
    }

    /// Hand this bundle the services its regions may inject. Before `boot`.
    pub fn provide(source: ServiceSource) { self.services = some(source) }

    /// The region whose code is running right now, or 0.
    ///
    /// A server action is always started from inside a region — from a
    /// handler, or from a component's own `on_init` at mount — so the region
    /// is known without every caller having to carry it. It is set around a
    /// mount and around an event and cleared after, so a call made from
    /// anywhere else answers 0 and its reply re-renders nothing.
    pub fn current_region() -> int { return self.current }

    /// Render whatever the region has been marked for, and make its batch
    /// ready for the page to take.
    pub fn settle(handle: int) {
        match self.regions.get(handle) {
            none => {}
            some(region) => {
                let _: int = region.renderer.flush()
                self.publish(region)
            }
        }
    }

    /// The batch this region owes the page, without consuming it.
    ///
    /// Not consumed here, because the page reads it with the two-call shape:
    /// once for the length and once for the bytes. A read that cleared on
    /// the first call would answer the second with an empty string.
    pub fn peek(handle: int) -> string {
        match self.regions.get(handle) {
            none => { return "" }
            some(region) => { return region.outbox }
        }
    }

    /// Forget the batch the page has now taken.
    pub fn clear(handle: int) {
        match self.regions.get(handle) {
            none => {}
            some(region) => { region.outbox = "" }
        }
    }

    pub fn unmount(handle: int) -> int {
        match self.regions.get(handle) {
            none => { return self.fail("no region {handle}") }
            some(_) => {
                let _: bool = self.regions.remove(handle)
                return 0
            }
        }
    }

    pub fn error() -> string { return self.last_error }

    pub fn region_count() -> int { return self.regions.len() }

    /// Every component type this bundle can build, in name order. The
    /// development inspector reads it, and so does the build check that says
    /// what a browser bundle actually contains.
    pub fn catalogue() -> string {
        let _: int = self.boot()
        var names: List<string> = []
        for name: string in self.types.keys() {
            match self.types.get(name) {
                some(described) => {
                    if is_component(described) { names.push(name) }
                }
                none => {}
            }
        }
        names.sort()
        return names.join("\n")
    }

    // ---- the inside -------------------------------------------------------

    fn write_props(region: Region, props: string) -> List<string> {
        var problems: List<string> = []
        match region.instance {
            none => {
                problems.push("region {region.handle} has no instance")
                return move problems
            }
            some(instance) => {
                if props == "" { return move problems }
                match parse_json(props, props_limits()) {
                    err(problem) => {
                        problems.push("the props for {region.type_name} are not JSON: {problem}")
                        return move problems
                    }
                    ok(root) => {
                        if !root.is_object() {
                            problems.push("the props for {region.type_name} are not a JSON object")
                            return move problems
                        }
                        for problem: string in decode_props(instance.copy(),
                                                            region.plan, root) {
                            problems.push("{region.type_name}: {problem}")
                        }
                        return move problems
                    }
                }
            }
        }
    }

    fn publish(region: Region) {
        let batch: Batch = region.renderer.batch()
        if batch.updates.len() == 0 && batch.disposed.len() == 0 { return }
        region.number += 1
        region.outbox = encode_batch(region.number, batch)
    }

    fn fail(message: string) -> int {
        self.last_error = message
        return -1
    }
}

/// Activate a component type reflectively.
///
/// A closed generic has no reflective initializer on either backend, so a
/// generic component cannot be a region's root. It is refused by name here
/// rather than mounting an empty element.
fn activate(described: reflect.Type) -> Result<reflect.Value, string> {
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
            return err("{described.qualified_name()} has no zero-argument initializer, so nothing in the browser can build it. A closed generic component is the usual cause: reflection has no initializer for one on either backend")
        }
    }
}

fn is_component(described: reflect.Type) -> bool {
    return extends_named(described, type_of(Component).qualified_name())
}

// ---------------------------------------------------------------- the ABI
//
// The page calls these. Each is the pointer-and-length spelling of one method
// above; the generated browser entry re-exports them under `extern "C"`,
// because `--emit shared` exports the names the module being BUILT declares.

pub fn boot_raw() -> int { return ClientApp.instance.boot() }

/// Hand the bundle a service source before it boots. See `ClientApp.provide`.
pub fn provide_services(source: ServiceSource) {
    ClientApp.instance.provide(source)
}

pub fn mount_raw(id: RawPtr<i8>, id_len: int, name: RawPtr<i8>, name_len: int,
                 props: RawPtr<i8>, props_len: int) -> int {
    return ClientApp.instance.mount(text_in(id, id_len),
                                    text_in(name, name_len),
                                    text_in(props, props_len))
}

pub fn props_raw(handle: int, props: RawPtr<i8>, props_len: int) -> int {
    return ClientApp.instance.props(handle, text_in(props, props_len))
}

pub fn event_raw(handle: int, message: RawPtr<i8>, message_len: int) -> int {
    return ClientApp.instance.event(handle, text_in(message, message_len))
}

/// The two-call shape, and the one place the batch is dropped.
///
/// Cleared only when the bytes were really written: a probe call (a null
/// buffer) and a buffer too small both leave the batch where it is, so a
/// page that asked the length and then could not allocate does not lose it.
pub fn take_raw(handle: int, out: RawPtr<i8>, cap: int) -> int {
    let text: string = ClientApp.instance.peek(handle)
    let needed: int = text_out(text, out, cap)
    if !out.is_null() && cap > 0 && needed <= cap {
        ClientApp.instance.clear(handle)
    }
    return needed
}

pub fn unmount_raw(handle: int) -> int { return ClientApp.instance.unmount(handle) }

pub fn last_error_raw(out: RawPtr<i8>, cap: int) -> int {
    return text_out(ClientApp.instance.error(), out, cap)
}

pub fn catalogue_raw(out: RawPtr<i8>, cap: int) -> int {
    return text_out(ClientApp.instance.catalogue(), out, cap)
}
