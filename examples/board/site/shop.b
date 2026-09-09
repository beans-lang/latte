// The services this application is built out of, and the view-model its page
// renders through.
//
// None of these is a component. That is the point of the file: a page's state
// and its behaviour live somewhere a test can reach without mounting anything,
// and its data comes from an object the page did not build.
package site

import {Command, Signal, ViewModel} from latte

// ---------------------------------------------------------------- services

/// The board's orders. One per process — it is the shop's book, not a
/// request's scratch pad — so it is registered as a singleton.
pub class Orders {
    pub tickets: List<string> = []
    pub fn init() {
        self.tickets = ["flat white", "cortado"]
    }
    pub fn add(drink: string) { self.tickets.push(drink) }
    pub fn count() -> int { return self.tickets.len() }
    pub fn at(index: int) -> string {
        if index < 0 || index >= self.tickets.len() { return "" }
        return self.tickets[index]
    }
}

/// What a drink costs, in pence. A second service, so the demo shows a
/// component reaching one its parent never passed it.
pub class Prices {
    pub fn init() {}
    pub fn of(drink: string) -> int {
        if drink == "espresso" { return 190 }
        if drink == "flat white" { return 320 }
        if drink == "cortado" { return 280 }
        if drink == "mocha" { return 340 }
        return 250
    }
}

// ---------------------------------------------------------------- the model

/// The page's state and behaviour, with no render tree anywhere in it.
///
/// `placed` is a `Signal`, so writing it patches the one text node that reads
/// it — no render, no diff. Nobody calls `own(self)` on it: the framework owns
/// every `pub Signal` field at mount, which is what `@memo` is to
/// `ParamWatch` — the same job, without a hand-written list to drift.
pub class BoardModel extends ViewModel {
    orders: Orders
    /// Not a `Signal`: it is bound with `bind:value`, which writes a `string`
    /// into a place, and a signal is not one. It changes on every keystroke and
    /// the page re-renders for it, which is what a bound input is for.
    pub draft: string = ""
    pub placed: Signal<int> = new Signal<int>(0)
    pub add: Command = new Command()

    pub fn init(orders: Orders) {
        // Own fields first, then the base: a base initializer may call an
        // overridden method, and the compiler refuses the other order rather
        // than letting that method see an unassigned field.
        self.orders = orders
        super.init()
    }

    /// Commands are built here and not in a field initializer, because a field
    /// initializer cannot name `self` — the compiler refuses it while the
    /// object is still being assembled, which is exactly when one runs.
    pub override fn on_attach() {
        self.add = Command.guarded(self,
            fn(model: ViewModel) {
                match model as? BoardModel {
                    some(board) => { board.place() }
                    none => {}
                }
            },
            fn(model: ViewModel) -> bool {
                match model as? BoardModel {
                    some(board) => { return board.ready() }
                    none => { return false }
                }
            })
    }

    /// A command's guard is asked twice — once to decide whether to disable the
    /// control, and again by `run` — so a button rendered while an order was
    /// valid cannot place an empty one after the box was cleared.
    pub fn ready() -> bool { return self.draft.trim() != "" }

    fn place() {
        self.orders.add(self.draft.trim())
        self.draft = ""
        // A signal write patches the one bound expression that read it. The
        // rest of the page is not re-rendered for it.
        self.placed.set(self.placed.peek() + 1)
        // The list DID change, and the list is not a signal, so this one asks
        // for a render.
        self.notify()
    }

    /// One row, by position. The markup loops over an index rather than over
    /// the list, because a `List` is move-only: returning the field would take
    /// it out of the service, and returning a copy would rebuild the whole list
    /// on every render to read it once.
    pub fn at(index: int) -> string { return self.orders.at(index) }
    pub fn total() -> int { return self.orders.count() }
}
