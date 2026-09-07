// A stub `latte.Builder` carrying the exact signature written down in
// probes/BUILDER.md, plus just enough behaviour to dump frames.
//
// It exists to be COMPILED. A signature that has never been through the
// checker is a guess, and W1, W2 and W4 all build against this one. The frame
// list and the dump are here so `main.b` can run it on both backends — a stub
// that only type-checks would not catch a method that cannot actually be
// called the way the generated code calls it.
//
// Nothing here imports std.fs, std.net or std.io: the core has to keep
// building for wasm32-unknown-unknown (PLAN.md, D4).
package latte

import std.reflect

// ---------------------------------------------------------------- events
//
// One class per DOM event family. The markup compiler's event table decides
// which family an `on:` attribute belongs to, and the Builder has one named
// method per event in that table typed to its family — so a handler's
// parameter type is fixed by the event name and the author never writes it.
pub class MouseEvent {
    pub button: int = 0
    pub x: int = 0
    pub y: int = 0
    pub fn init() {}
}

pub class InputEvent {
    pub value: string = ""
    pub checked: bool = false
    pub fn init() {}
}

pub class KeyboardEvent {
    pub key: string = ""
    pub repeated: bool = false
    pub fn init() {}
}

pub class SubmitEvent {
    pub fields: Map<string, string> = {}
    pub fn init() {}
}

pub class FocusEvent {
    pub fn init() {}
}

/// A handle to a rendered element or a mounted child, filled in after render.
pub class Reference {
    pub node: int = -1
    pub child: Option<Component> = none
    pub fn init() {}
}

// ---------------------------------------------------------------- frames
pub enum Frame {
    open(seq: int, tag: string)
    attribute(seq: int, name: string, value: string)
    flag(seq: int, name: string, present: bool)
    splat(seq: int, count: int)
    text(seq: int, body: string)
    raw(seq: int, html: string)
    constant(seq: int, html: string)
    handler(seq: int, event: string)
    child(seq: int, type_name: string)
    region_open(seq: int, key: string)
    region_close
    fragment_open(seq: int)
    fragment_close
    reference(seq: int)
    preserve(seq: int)
    close
}

// ---------------------------------------------------------------- component
pub class Component {
    /// The one method the markup compiler writes. It takes the builder rather
    /// than returning a fragment, so a markup block is a plain statement.
    pub fn render(b: Builder) {}
}

// ---------------------------------------------------------------- builder
pub class Builder {
    pub frames: List<Frame> = []

    // The handler tables. One list per event family, because dispatch has to
    // know which payload shape to build before it can call anything. The id on
    // the wire is the frame's sequence number, never a name.
    pub mouse: Map<int, fn(MouseEvent)> = {}
    pub input: Map<int, fn(InputEvent)> = {}
    pub keyboard: Map<int, fn(KeyboardEvent)> = {}
    pub submit: Map<int, fn(SubmitEvent)> = {}
    pub focus: Map<int, fn(FocusEvent)> = {}

    // Mounted children, keyed by the sequence number of their `component<T>`
    // call. Reuse is not an optimisation: probe 3 measured reflective
    // activation at 2.4 us, so re-activating 200 children every render would
    // be half a millisecond of churn per event.
    pub children: Map<int, Component> = {}

    // Balance checking. The generated code is machine-written, so an
    // unbalanced open/close is a compiler bug and must be loud.
    depth: int = 0
    regions: int = 0
    pub faults: List<string> = []

    pub fn init() {}

    // ---- elements ----
    pub fn open(seq: int, tag: string) {
        self.frames.push(Frame.open(seq, tag))
        self.depth += 1
    }

    pub fn close() {
        if self.depth <= 0 {
            self.faults.push("close with no open element")
            return
        }
        self.depth -= 1
        self.frames.push(Frame.close)
    }

    // ---- attributes ----
    //
    // Escaping is the serializer's job, not the caller's; every value here is
    // the raw text. The URL scheme allowlist is checked HERE, by attribute
    // name, so a hand-written builder call cannot forget it.
    pub fn attr(seq: int, name: string, value: string) {
        var safe: string = value
        if is_url_attribute(name) && !scheme_is_allowed(value) {
            safe = "about:blank"
            self.faults.push("attribute {name} carried a refused scheme")
        }
        self.frames.push(Frame.attribute(seq, name, safe))
    }

    /// A boolean attribute: present or absent, never `="false"`.
    pub fn flag(seq: int, name: string, present: bool) {
        self.frames.push(Frame.flag(seq, name, present))
    }

    /// Pass-through attributes — `attrs={self.extra}`. Reserved: spelled now
    /// so the interface does not change under W4.
    pub fn attrs(seq: int, extra: Map<string, string>) {
        self.frames.push(Frame.splat(seq, extra.len()))
    }

    // ---- content ----
    pub fn text(seq: int, body: string) {
        self.frames.push(Frame.text(seq, body))
    }

    /// `$html(expr)` — unescaped, and the only bypass there is.
    pub fn raw(seq: int, html: string) {
        self.frames.push(Frame.raw(seq, html))
    }

    /// A subtree with no expression anywhere inside it, serialized at build
    /// time. `html` is compiler-produced and trusted; `raw` is not.
    pub fn constant(seq: int, html: string) {
        self.frames.push(Frame.constant(seq, html))
    }

    // ---- children ----
    //
    // `component<T>` MUST be a method. A free generic function with a `fn(T)`
    // parameter type-checks, runs under `beansc run`, and cannot be built
    // natively — BLOCKERS.md B3.
    pub fn component<T>(seq: int, setup: fn(T)) {
        let described: reflect.Type = type_of(T)
        var mounted: Option<Component> = self.children.get(seq)
        match mounted {
            some(existing) => {
                match reflect.value(existing).copy() as? T {
                    some(typed) => { setup(typed) }
                    none => {
                        self.faults.push(
                            "seq {seq} holds a {described.name()} of another type")
                    }
                }
            }
            none => {
                match described.initializer() {
                    some(ctor) => {
                        match ctor.call([]) {
                            ok(made) => {
                                let typed: Option<T> = made.copy() as? T
                                let based: Option<Component> = made as? Component
                                match typed {
                                    some(instance) => { setup(instance) }
                                    none => {}
                                }
                                match based {
                                    some(component) => {
                                        self.children[seq] = component
                                    }
                                    none => {
                                        self.faults.push(
                                            "{described.name()} is not a Component")
                                    }
                                }
                            }
                            err(problem) => {
                                self.faults.push(
                                    "cannot activate {described.name()}: {problem.message()}")
                            }
                        }
                    }
                    none => {
                        self.faults.push(
                            "{described.name()} has no zero-argument initializer")
                    }
                }
            }
        }
        self.frames.push(Frame.child(seq, described.name()))
        match self.children.get(seq) {
            some(child) => { child.render(self) }
            none => {}
        }
    }

    /// `$slot` and `$slot(expr)`: child content, or any `fn(Builder)`.
    pub fn fragment(seq: int, body: fn(Builder)) {
        self.frames.push(Frame.fragment_open(seq))
        body(self)
        self.frames.push(Frame.fragment_close)
    }

    // ---- lists ----
    //
    // `seq` names the LOOP; `key` names the row. Sequence numbers inside a
    // region start again at 0, so the body of a loop is numbered once no
    // matter how many rows it produces.
    pub fn region(seq: int, key: string) {
        self.frames.push(Frame.region_open(seq, key))
        self.regions += 1
    }

    pub fn end_region() {
        if self.regions <= 0 {
            self.faults.push("end_region with no open region")
            return
        }
        self.regions -= 1
        self.frames.push(Frame.region_close)
    }

    // ---- events ----
    //
    // One named method per event in the markup compiler's table, typed to its
    // family. Six of them here; the full table is W2's. The handler is stored
    // under `seq`, which is the id the wire carries — no name ever crosses.
    pub fn on_click(seq: int, handler: fn(MouseEvent)) {
        self.mouse[seq] = handler
        self.frames.push(Frame.handler(seq, "click"))
    }

    pub fn on_dblclick(seq: int, handler: fn(MouseEvent)) {
        self.mouse[seq] = handler
        self.frames.push(Frame.handler(seq, "dblclick"))
    }

    pub fn on_input(seq: int, handler: fn(InputEvent)) {
        self.input[seq] = handler
        self.frames.push(Frame.handler(seq, "input"))
    }

    pub fn on_change(seq: int, handler: fn(InputEvent)) {
        self.input[seq] = handler
        self.frames.push(Frame.handler(seq, "change"))
    }

    pub fn on_keydown(seq: int, handler: fn(KeyboardEvent)) {
        self.keyboard[seq] = handler
        self.frames.push(Frame.handler(seq, "keydown"))
    }

    pub fn on_submit(seq: int, handler: fn(SubmitEvent)) {
        self.submit[seq] = handler
        self.frames.push(Frame.handler(seq, "submit"))
    }

    pub fn on_focus(seq: int, handler: fn(FocusEvent)) {
        self.focus[seq] = handler
        self.frames.push(Frame.handler(seq, "focus"))
    }

    // ---- handles ----
    /// `ref={self.input}`. Reserved.
    pub fn reference(seq: int, sink: fn(Reference)) {
        self.frames.push(Frame.reference(seq))
        let handle: Reference = new Reference()
        handle.node = seq
        handle.child = self.children.get(seq)
        sink(handle)
    }

    /// `preserve`: render this subtree once and never diff into it. Reserved.
    pub fn preserve(seq: int) {
        self.frames.push(Frame.preserve(seq))
    }

    // ---- what the renderer asks afterwards ----
    pub fn balanced() -> bool {
        return self.depth == 0 && self.regions == 0
    }

    pub fn dump() -> string {
        var out: string = ""
        for frame: Frame in self.frames {
            match frame {
                open(seq, tag) => { out = "{out}<{seq}:{tag}" }
                attribute(seq, name, value) => { out = "{out} {seq}:{name}={value}" }
                flag(seq, name, present) => { out = "{out} {seq}:{name}?{present}" }
                splat(seq, count) => { out = "{out} {seq}:splat{count}" }
                text(seq, body) => { out = "{out}[{seq}:{body}]" }
                raw(seq, html) => { out = "{out}[{seq}!{html}]" }
                constant(seq, html) => { out = "{out}[{seq}={html}]" }
                handler(seq, event) => { out = "{out} {seq}:on{event}" }
                child(seq, type_name) => { out = "{out}\{{seq}:{type_name}\}" }
                region_open(seq, key) => { out = "{out}(#{seq}/{key}" }
                region_close => { out = "{out})" }
                fragment_open(seq) => { out = "{out}(slot{seq}" }
                fragment_close => { out = "{out})" }
                reference(seq) => { out = "{out} {seq}:ref" }
                preserve(seq) => { out = "{out} {seq}:preserve" }
                close => { out = "{out}>" }
            }
        }
        return out
    }
}

// ---------------------------------------------------------------- the URL rule
fn is_url_attribute(name: string) -> bool {
    return name == "href" || name == "src" || name == "action" ||
           name == "formaction" || name == "poster" || name == "data"
}

fn scheme_is_allowed(value: string) -> bool {
    let trimmed: string = value.trim().to_lower()
    let colon: int = trimmed.find_byte(58, 0)
    let slash: int = trimmed.find_byte(47, 0)
    // No colon before the first slash means it is a relative reference.
    if colon < 0 { return true }
    if slash >= 0 && slash < colon { return true }
    let scheme: string = trimmed.slice(0, colon)
    return scheme == "http" || scheme == "https" || scheme == "mailto" ||
           scheme == "tel"
}

// ---------------------------------------------------------------- callback
/// The event-out type. It holds a **weak** owner, and probe 6 says why: not to
/// break a cycle — the handler closure captures `self` on its own and the
/// cycle collector is what kills that — but so a callback fired after its
/// owner is gone reads `none` and does nothing instead of marking a dead
/// component dirty. The weak read turns `none` before the referent's `deinit`
/// body runs, so it can never resurrect anything.
pub class Callback<T> {
    pub weak owner: Option<Component> = none
    pub handler: fn(T) = fn(value: T) {}

    /// `new Callback<int>(self, fn(id: int) { self.select(id) })`.
    ///
    /// NOT a static factory. A `static fn` on a generic class can never bind
    /// the class's type parameter (BLOCKERS.md B5), and a static taking a
    /// `fn(T)` cannot be emitted natively either (B3), so PLAN.md's
    /// `Callback.of(self, …)` has no spelling. The constructor does, and it
    /// infers `T` from the declared type of the binding.
    pub fn init(owner: Component, handler: fn(T)) {
        self.owner = some(owner)
        self.handler = handler
    }

    pub fn call(value: T) {
        match self.owner {
            some(component) => { self.handler(value) }
            none => {}
        }
    }
}
