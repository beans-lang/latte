// examples/shop/main.b — a THIRD-PARTY component library, used from another
// module.
//
//     beansc run   examples/shop/main.b
//     beansc build examples/shop/main.b -o build/shop
//
// `examples/counter.bx` and `examples/todo.b` both declare their components
// in the same file that mounts them; this is the first example that crosses
// a package boundary, let alone a module one. Here the chain is four
// packages in three modules:
//
//     shop (this file)  ->  shelf.Panel  ->  shelf.cards.Card  ->  shelf.atoms.Badge
//                                    all three extend  latte.Component
//
// What it proves that the other two examples do not:
//
//   * **three levels, each in a different package**, each with its own frame
//     buffer, mounted through `Builder.component<T>` across a module boundary.
//   * **child content across a module boundary.** `Panel` hands `Card` a
//     `fn(Builder)` closure and `Card` places it with `b.fragment`, so a
//     library component's `$slot` is filled by another package's code and
//     diffs as part of the card's subtree. `Card` therefore has no
//     `should_render` — read the comment there before adding one.
//   * **an event crossing three modules.** A click binds in `shelf`'s buffer,
//     dispatches through `latte`'s registry, and runs a closure this file
//     wrote. The `Callback` marks THIS page, not the library component that
//     fired it.
//   * **a `@page` declared in a consumer's module.** The startup scan is
//     `reflect.types()` and a comparison against `latte.Component`; a page in
//     another module has to be found by it, and its `@param(required: true)`
//     has to be checked against its route, or a library consumer gets neither.
//   * **the render counts stay small across the boundary.** Picking an item
//     re-renders this page and the one component whose parameters changed.
//     The numbers are printed, so a framework that re-rendered the world would
//     fail this file instead of passing it.
//
// **The one trap a consumer has to know**, and the reason this file never
// writes `type_of(Component)` inside a string: a type name written inside a
// `"{ }"` interpolation is resolved without this file's named imports, and
// answers a package name that does not exist — BLOCKERS.md **B10**. Bind it to
// a `let` first, as `identity()` below does, and it is right.
package main

import std.io
import std.reflect
import {Builder, Callback, Component, MouseEvent, Frame, Renderer,
        PageMap, PageMatch, PageInstance, Anonymous,
        scan_pages, open_page, mount_page, extends_named,
        page, param} from latte
import {Panel, VERSION} from shelf
import {Card} from shelf.cards
import {Badge} from shelf.atoms

// ================================================================== the page

/// The consumer's page. It is a `latte.Component` — a base from another module
/// — and it mounts a component from a second one.
@page(route: r"/shop/{tab}")
pub class Storefront extends Component {
    /// Required, and the route carries it. A `@param(required: true)` whose
    /// name is not a placeholder in the route is refused at startup, by name.
    /// That check runs over a type declared HERE, in a module latte has never
    /// heard of, which is the half of it this example exists to prove.
    @param(required: true) pub tab: string = "all"

    /// What the callback changed. Ordinary state; the library never sees it.
    pub picked: string = ""
    pub picks: int = 0
    pub stock: List<string> = []
    /// State that touches nothing below this component. It is what makes the
    /// "a page-only change renders one component" pass possible, and that pass
    /// is the only thing in this file that `Panel.should_render` decides.
    pub views: int = 0
    pub fn init() {}

    /// `on_init` runs after the route has bound `tab` — `open_page` applies
    /// the route values at activation and `Renderer.mount` calls `on_init`
    /// afterwards — so the initial stock can depend on the parameter.
    pub override fn on_init() {
        if self.tab == "gear" { self.stock = ["grinder", "kettle", "scale"] }
        else if self.tab == "beans" { self.stock = ["ethiopia", "colombia"] }
        else { self.stock = ["ethiopia", "colombia", "grinder", "kettle", "scale"] }
    }

    /// Removing the picked item is state no event touched, so the page says so
    /// itself: `notify()` marks it dirty and the next flush renders it. The
    /// item count then changes, which is the ONLY thing three levels down
    /// `Badge` watches — so this is the pass where the leaf re-renders and the
    /// two clicks before it are the passes where it does not.
    /// A change that no component below can see. `notify()` marks this page
    /// dirty; `Panel`'s parameters are unchanged, so it keeps its frames and
    /// so does everything under it.
    pub fn view() {
        self.views += 1
        self.notify()
    }

    /// A change to the ITEMS that leaves the count alone. `Panel` re-renders
    /// because its `items` differ; `Card` re-renders because a component
    /// holding child content never skips; `Badge` does not, because the count
    /// it watches did not move.
    pub fn rename(from: string, to: string) {
        var index: int = 0
        for index < self.stock.len() {
            if self.stock[index] == from {
                self.stock[index] = to
                self.notify()
                return
            }
            index += 1
        }
    }

    pub fn drop_picked() {
        var index: int = 0
        for index < self.stock.len() {
            if self.stock[index] == self.picked {
                let _: string = self.stock.remove(index)
                self.notify()
                return
            }
            index += 1
        }
    }

    fn heading() -> string {
        if self.picked == "" { return "{self.tab} — nothing picked" }
        return "{self.tab} — {self.picked} ({self.picks})"
    }

    pub override fn render(b: Builder) {
        b.open(0, "main")
        b.attr(1, "class", "shop")
        b.component<Panel>(2, fn(panel: Panel) {
            panel.heading = self.heading()
            panel.items = self.stock.clone()
            panel.on_pick = some(new Callback<string>(
                self, fn(item: string) { self.took(item) }))
        })
        b.open(3, "p")
        b.attr(4, "class", "views")
        b.text(5, "views: {self.views}")
        b.close()
        b.close()
    }

    /// What the library's click runs. It changes this page's own state; the
    /// `Callback` marks this page dirty and the next flush renders it.
    fn took(item: string) {
        self.picked = item
        self.picks += 1
    }
}

// =============================================================== the program

/// The identity question a consumer's own code asks — written the one way that
/// is correct.
///
/// `type_of(Component)` bound to a `let` and interpolated afterwards answers
/// `latte.Component`. Written inline inside the quotes it answers
/// `shop.Component`, a type that does not exist, and every check built on it
/// reads false. BLOCKERS.md **B10**; `tests/pages.b` § 10 gates the split.
fn identity() {
    let base: reflect.Type = type_of(Component)
    let name: string = base.qualified_name()
    io.println("latte's base, named from the consumer: {name}")
    io.println("does the page extend it: {extends_named(type_of(Storefront), name)}")
    io.println("shelf version: {VERSION}")
}

/// The mounted tree, indented by depth, each component with its render count.
///
/// The nesting comes from `Builder.nested` — one frame buffer per mounted
/// child — so the indentation is the framework's own answer to "what is
/// inside what" rather than a shape this file assumed. Four components, three
/// levels, three modules, and the render counts are what say the update model
/// survived the boundary.
fn tree(r: Renderer) {
    io.println("  faults: {r.all_faults().len()}")
    limb(r, 0, 0)
}

fn limb(r: Renderer, id: int, depth: int) {
    var pad: string = ""
    for pad.len() < depth * 2 { pad = "{pad} " }
    match r.component(id) {
        some(component) => {
            io.println("  {pad}slot {id}: {name_of(component)} — {r.render_count(id)} render(s)")
        }
        none => { return }
    }
    match r.buffer(id) {
        some(buffer) => {
            var slots: List<int> = buffer.nested.keys()
            slots.sort()
            for slot: int in slots { limb(r, slot, depth + 1) }
        }
        none => {}
    }
}

/// A component's own name, by downcast.
///
/// `reflect.value(component).type().name()` cannot do this: `reflect.value`
/// boxes the STATIC type of its argument (BLOCKERS.md **B6**), and the static
/// type here is `Component`, so every row would read "Component". An `as?`
/// goes through the inheritance chain instead, and three of the four types it
/// tries live in another module — which is the cross-module downcast latte's
/// own mount path depends on, exercised from a consumer.
fn name_of(component: Component) -> string {
    match component as? Storefront { some(_) => { return "Storefront (shop)" } none => {} }
    match component as? Panel { some(_) => { return "Panel (shelf)" } none => {} }
    match component as? Card { some(_) => { return "Card (shelf.cards)" } none => {} }
    match component as? Badge { some(_) => { return "Badge (shelf.atoms)" } none => {} }
    return "an unrecognised component"
}

/// The click handler the library bound, found the way a browser finds it:
/// latte puts the id in the batch beside the element and the client sends it
/// back. `nth` counts them in mount order, so 0 is the first row.
fn row_handler(r: Renderer, nth: int) -> int {
    var seen: int = 0
    for id: int in r.ids() {
        match r.buffer(id) {
            some(buffer) => {
                for frame: Frame in buffer.frames.items {
                    match frame {
                        handler(_, _, slot) => {
                            if seen == nth { return slot }
                            seen += 1
                        }
                        _ => {}
                    }
                }
            }
            none => {}
        }
    }
    return -1
}

/// The mounted page itself. `Renderer.component` hands back the component at a
/// slot; the page is the one at slot 0, and the downcast is what proves it.
fn page_of(r: Renderer) -> Option<Storefront> {
    match r.component(0) {
        some(component) => { return component as? Storefront }
        none => { return none }
    }
}

fn open(pages: PageMap, path: string) -> Option<Renderer> {
    match pages.find("GET", path) {
        none => {
            io.println("nothing is routed at {path}")
            return none
        }
        some(found) => {
            let instance: PageInstance = open_page(found, new Anonymous(), none)
            if !instance.ok() {
                for problem: string in instance.problems { io.println("refused: {problem}") }
                return none
            }
            let r: Renderer = new Renderer()
            if !mount_page(r, instance) {
                io.println("the page did not mount")
                return none
            }
            return some(r)
        }
    }
}

fn main() {
    let pages: PageMap = scan_pages()
    if !pages.ok() {
        io.println("the page scan refused this program:")
        io.println(pages.report())
        return
    }
    io.println("== the scan found the page, in a module latte never heard of ==")
    identity()

    io.println("")
    io.println("== GET /shop/all ==")
    match open(pages, "/shop/all") {
        none => { return }
        some(r) => {
            io.println(r.html())
            io.println("the tree:")
            tree(r)

            io.println("")
            io.println("== clicking the third row — an event across three modules ==")
            let third: int = row_handler(r, 2)
            let click: MouseEvent = new MouseEvent()
            io.println("the click found its handler: {r.fire_mouse(third, click)}")
            io.println("renders this pass: {r.flush()} of {r.ids().len()} mounted components")
            io.println(r.html())
            io.println("the tree:")
            tree(r)

            io.println("")
            io.println("== clicking the same row again — the heading changes, the list does not ==")
            let again: MouseEvent = new MouseEvent()
            let _: bool = r.fire_mouse(third, again)
            io.println("renders this pass: {r.flush()}")
            io.println(r.html())
            io.println("the tree:")
            tree(r)

            io.println("")
            io.println("== a page-only change: nothing below re-renders ==")
            io.println("   the view counter lives in this page's own markup")
            match page_of(r) {
                some(shop) => {
                    shop.view()
                    io.println("renders this pass: {r.flush()} of {r.ids().len()} mounted components")
                    io.println(r.html())
                    io.println("the tree:")
                    tree(r)
                }
                none => { io.println("the page is not mounted") }
            }

            io.println("")
            io.println("== renaming an item: the count does not move ==")
            io.println("   Panel and Card re-render, Badge does not")
            match page_of(r) {
                some(shop) => {
                    shop.rename("kettle", "kettle (last one)")
                    io.println("renders this pass: {r.flush()} of {r.ids().len()} mounted components")
                    io.println(r.html())
                    io.println("the tree:")
                    tree(r)
                }
                none => { io.println("the page is not mounted") }
            }

            io.println("")
            io.println("== dropping the picked item, from outside any event ==")
            io.println("   the list shrinks, so the count Badge watches changes")
            match page_of(r) {
                some(shop) => {
                    shop.drop_picked()
                    io.println("renders this pass: {r.flush()} of {r.ids().len()} mounted components")
                    io.println(r.html())
                    io.println("the tree:")
                    tree(r)
                }
                none => { io.println("the page is not mounted") }
            }
        }
    }

    io.println("")
    io.println("== GET /shop/gear — the same page, a different parameter ==")
    match open(pages, "/shop/gear") {
        some(other) => {
            io.println(other.html())
            io.println("the tree:")
            tree(other)
        }
        none => {}
    }

    io.println("")
    io.println(r"== GET /shop — no {tab} in the path ==")
    match pages.find("GET", "/shop") {
        none => { io.println("no page is routed there — the host answers 404") }
        some(_) => { io.println("matched, which it should not have") }
    }
}
