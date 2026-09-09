// `ViewModel`, `Command`, and the line an author stops writing.
//
// `Signal<T>.own(self)` had to be written by hand, in `on_init`, once per
// signal. Forgetting it is not loud: the signal records no binding, so the
// expression that reads it renders once and never moves again, and the only
// thing that says so is a fault buried in a buffer's list
// (`live_text / live expression N read no signal`). The framework can do it —
// walk the component's fields at mount and own every `Signal` — and this is
// what proves it does, on both backends.
//
// Every section carries a control that must behave the OTHER way, because
// "the signal updated" is worth nothing without "and this one, which nothing
// owned, did not".
package main

import std.io
import std.reflect
import {Builder, Cell, Component, Renderer, Signal, ViewModel,
        Command} from latte

// ---------------------------------------------------------------- subjects

/// A component with a signal and no `on_init` at all. Before this lane, its
/// signal was deaf.
pub class Counter extends Component {
    pub ticks: Signal<int> = new Signal<int>(0)
    pub fn init() {}
    pub override fn render(b: Builder) {
        b.open(0, "p")
        b.live_text(1, fn() -> string { return "{self.ticks.get()}" })
        b.close()
    }
}

/// THE CONTROL: a signal the framework cannot see, because it is not public.
/// Reflection does not bypass visibility, so this one stays deaf — which is
/// what says the section above measured ownership and not "live_text works".
pub class Private extends Component {
    hidden: Signal<int> = new Signal<int>(0)
    pub fn init() {}
    pub fn bump() { self.hidden.set(self.hidden.peek() + 1) }
    pub override fn render(b: Builder) {
        b.open(0, "p")
        b.live_text(1, fn() -> string { return "{self.hidden.get()}" })
        b.close()
    }
}

// ---------------------------------------------------------------- the model

pub class OrderModel extends ViewModel {
    pub placed: Signal<int> = new Signal<int>(0)
    pub open: bool = true
    pub place: Command = new Command()
    pub attaches: int = 0

    pub fn init() { super.init() }

    pub override fn on_attach() {
        self.attaches += 1
        // Commands are built here and not in a field initializer, because a
        // field initializer cannot name `self` — the compiler refuses it while
        // the object is still being assembled, which is when one runs.
        self.place = Command.guarded(self,
            fn(model: ViewModel) {
                match model as? OrderModel {
                    some(order) => { order.placed.set(order.placed.peek() + 1) }
                    none => {}
                }
            },
            fn(model: ViewModel) -> bool {
                match model as? OrderModel {
                    some(order) => { return order.open }
                    none => { return false }
                }
            })
    }
}

pub class OrderPage extends Component {
    pub model: OrderModel = new OrderModel()
    pub fn init() {}
    pub override fn render(b: Builder) {
        b.open(0, "p")
        b.live_text(1, fn() -> string { return "{self.model.placed.get()}" })
        b.close()
    }
}

// ---------------------------------------------------------------- reporting

fn report(what: string, got: string, want: string) {
    if got == want { io.println("ok   {what}: {got}") }
    else { io.println("FAIL {what}: got [{got}], want [{want}]") }
}

fn main() {
    io.println("== 1. the framework owns a component's signals ==")
    let counter: Counter = new Counter()
    let r1: Renderer = new Renderer()
    r1.mount(counter)
    report("it rendered", r1.html(), "<p>0</p>")
    report("nothing was refused — the signal was NOT deaf",
           r1.all_faults().join(" | "), "")
    report("and the framework owned it", "{counter.ticks.cell.attached()}", "true")
    counter.ticks.set(3)
    let _flush1: int = r1.flush()
    report("a write moved the page with no on_init anywhere", r1.html(), "<p>3</p>")

    io.println("")
    io.println("== 2. THE CONTROL: a signal reflection cannot see ==")
    let private_page: Private = new Private()
    let r2: Renderer = new Renderer()
    r2.mount(private_page)
    report("it renders",  r2.html(), "<p>0</p>")
    // The fault is the control's whole value: a non-public signal is exactly
    // as deaf as every signal was before this lane, and it says so.
    report("and it IS deaf, loudly", r2.all_faults().join(" | "),
           "0: live expression 1 read no signal")
    private_page.bump()
    let _flush2: int = r2.flush()
    report("so a write moves nothing", r2.html(), "<p>0</p>")

    io.println("")
    io.println("== 3. a view-model is attached, and its signals owned ==")
    let page: OrderPage = new OrderPage()
    let r3: Renderer = new Renderer()
    r3.mount(page)
    report("the model was attached exactly once", "{page.model.attaches}", "1")
    report("it knows its component", "{page.model.attached()}", "true")
    report("the page rendered", r3.html(), "<p>0</p>")
    report("nothing was refused", r3.all_faults().join(" | "), "")

    io.println("")
    io.println("== 4. a command runs, and its guard is asked twice ==")
    report("the command can run", "{page.model.place.can_run()}", "true")
    page.model.place.run()
    let _flush3: int = r3.flush()
    report("running it moved the page through the model's signal",
           r3.html(), "<p>1</p>")
    // The guard is asked by `run` as well as by `can_run`, so a control
    // rendered while the command was live cannot fire it after the model has
    // closed. A stale click is a race the model already decided.
    page.model.open = false
    report("the command now refuses", "{page.model.place.can_run()}", "false")
    page.model.place.run()
    let _flush4: int = r3.flush()
    report("and running it anyway does nothing", r3.html(), "<p>1</p>")

    io.println("")
    io.println("== 5. a command with no owner is inert ==")
    // The default a `Command` field holds before `on_attach` builds a real one.
    // It must be safe to call, because a render can reach a field before the
    // model that owns it has done anything.
    let bare: Command = new Command()
    report("it cannot run", "{bare.can_run()}", "false")
    bare.run()
    io.println("ok   and running it did not fail")
}
