// examples/todo.b — the same framework, written without the markup compiler.
//
//     beansc run   examples/todo.b                  # the tree interpreter
//     beansc build examples/todo.b -o build/todo     # a native binary
//
// **Nothing here is generated.** `examples/counter.bx` is the way most pages
// are written; this file is the other option — everything a consumer touches
// is ordinary Beans, so a component library works for someone who never
// installs a second compiler. The `render` methods below are exactly
// what latte-bx would have emitted for the markup in the comment above each
// one, sequence numbers and all.
//
// What it shows that `counter.bx` does not:
//
//   * **child content** — `Card.body` is a `fn(Builder)` the caller supplies
//     and `Card` places with `b.fragment`. In markup that field is `$slot`.
//   * **a callback that marks the right component** — an `Item` calls
//     `on_toggle`, and the component that *supplied* the callback re-renders.
//     The child does not mark itself and does not mark the world.
//   * **a parameter that did not change costs nothing** — three of the four
//     items run zero renders when the fourth is toggled, because `ParamWatch`
//     answers `should_render` from the parameters recorded in `on_params_set`.
//     That number is printed, so a framework that quietly re-renders
//     everything fails this file rather than passing it.
//   * **a required parameter** — `@param(required: true)` on `filter`, which
//     the startup scan checks against the route's `{filter}`. A page that
//     declares one the route does not capture never runs at all.
package main

import std.io
import {Builder, Component, Callback, Renderer, ParamWatch, Frame,
        MouseEvent, PageMap, PageInstance, Anonymous,
        scan_pages, open_page, mount_page,
        page, param} from latte

/// One task. Ordinary data; latte never sees it.
pub class Task {
    pub id: int = 0
    pub label: string = ""
    pub done: bool = false
    pub fn init(id: int, label: string, done: bool) {
        self.id = id
        self.label = label
        self.done = done
    }
}

// ============================================================== components

/// A reusable component with **child content**.
///
/// Markup:
///
///     <div class="card">
///       <h3>$self.title</h3>
///       $slot
///     </div>
///
/// `$slot` compiles to the `b.fragment(4, self.body)` below: the caller's
/// closure renders into this component's own buffer, so what it draws is part
/// of the card's subtree and diffs with it.
pub class Card extends Component {
    @param pub title: string = ""
    @param pub body: fn(Builder) = fn(b: Builder) {}
    pub fn init() {}
    pub override fn render(b: Builder) {
        b.open(0, "div")
        b.attr(1, "class", "card")
        b.open(2, "h3")
        b.text(3, "{self.title}")
        b.close()
        b.fragment(4, self.body)
        b.close()
    }
}

/// One row.
///
/// Markup:
///
///     <li class={if self.done { "done" } else { "open" }}
///         on:click={fn(e: MouseEvent) { self.toggled() }}>$self.label</li>
///
/// `on_toggle` is a `Callback<int>` rather than a bare `fn(int)`. A bare
/// closure would run, change the page's list, and re-render nothing, because
/// nobody told the renderer. A callback marks the component that supplied it.
pub class Item extends Component {
    @param pub id: int = 0
    @param pub label: string = ""
    @param pub done: bool = false
    @param pub on_toggle: Option<Callback<int>> = none
    watch: ParamWatch = new ParamWatch()
    pub fn init() {}

    /// The snapshot belongs HERE and not in `should_render`. `should_render`
    /// is consulted only from the second render onward, so a component that
    /// snapshots there never records the first render's parameters and answers
    /// "changed" for ever after — which is a component that re-renders on
    /// every parent pass while every golden file still passes.
    pub override fn on_params_set() {
        self.watch.record(["{self.id}", self.label, "{self.done}"])
    }
    pub override fn should_render() -> bool { return self.watch.differs() }

    pub override fn render(b: Builder) {
        b.open(0, "li")
        b.attr(1, "class", if self.done { "done" } else { "open" })
        b.on_click(2, fn(e: MouseEvent) { self.toggled() })
        b.text(3, "{self.label}")
        b.close()
    }

    fn toggled() {
        match self.on_toggle {
            some(handler) => { handler.call(self.id) }
            none => {}
        }
    }
}

// ================================================================== the page

/// Markup:
///
///     <section class="todo">
///       <Card title={self.heading()}>
///         <ul>
///           $for task: Task in self.tasks {
///             $if self.shows(task) {
///               <Item key={task.id} id={task.id} label={task.label}
///                     done={task.done} on_toggle={...} />
///             }
///           }
///         </ul>
///       </Card>
///     </section>
@page(route: r"/todo/{filter}")
pub class TodoPage extends Component {
    /// Required, and the route captures it. A `@param(required: true)` whose
    /// name is not a placeholder in the route is refused at **startup**, by
    /// name, rather than rendering a page with a silently empty field.
    @param(required: true) pub filter: string = "all"
    pub tasks: List<Task> = []
    pub fn init() {}

    pub override fn on_init() {
        self.tasks = [new Task(1, "buy beans", true),
                      new Task(2, "grind beans", false),
                      new Task(3, "boil water", false),
                      new Task(4, "pour", false)]
    }

    fn heading() -> string {
        var open: int = 0
        for task: Task in self.tasks {
            if !task.done { open += 1 }
        }
        return "{self.filter} — {open} open of {self.tasks.len()}"
    }

    fn shows(task: Task) -> bool {
        if self.filter == "all" { return true }
        if self.filter == "open" { return !task.done }
        if self.filter == "done" { return task.done }
        return false
    }

    /// What the callback runs. It changes the page's own state; the callback
    /// marks the page dirty, and the next flush renders it.
    fn toggle(id: int) {
        for task: Task in self.tasks {
            if task.id == id { task.done = !task.done }
        }
    }

    /// Dropping a task changes state that no event touched, so the page has
    /// to say so itself: `notify()` marks this component dirty and the next
    /// flush renders it. That is the one case a callback does not cover — a
    /// timer, a push from another thread, or a caller like `main` below.
    pub fn drop(id: int) {
        var index: int = 0
        for index < self.tasks.len() {
            if self.tasks[index].id == id {
                let _: Task = self.tasks.remove(index)
                self.notify()
                return
            }
            index += 1
        }
    }

    pub override fn render(b: Builder) {
        b.open(0, "section")
        b.attr(1, "class", "todo")
        b.component<Card>(2, fn(card: Card) {
            card.title = self.heading()
            card.body = fn(inner: Builder) { self.rows(inner) }
        })
        b.close()
    }

    /// The `$slot` the card places. A `$for` is a region: its body restarts
    /// sequence numbering at 0 and its key names the row's identity, so
    /// reordering the list moves nodes instead of rewriting them.
    fn rows(b: Builder) {
        b.open(0, "ul")
        for task: Task in self.tasks {
            if self.shows(task) {
                b.region(1, "{task.id}")
                b.component<Item>(0, fn(child: Item) {
                    child.id = task.id
                    child.label = task.label
                    child.done = task.done
                    child.on_toggle = some(new Callback<int>(
                        self, fn(id: int) { self.toggle(id) }))
                })
                b.end_region()
            }
        }
        b.close()
    }
}

// ================================================================= the program

/// The click handler an `Item` bound, found the way a browser finds it: latte
/// puts the id in the batch beside the element and the client sends it back.
fn item_handler(r: Renderer, nth: int) -> int {
    var seen: int = 0
    for id: int in r.ids() {
        match r.component(id) {
            some(component) => {
                match component as? Item {
                    some(_) => {
                        if seen == nth {
                            match r.buffer(id) {
                                some(buffer) => {
                                    for frame: Frame in buffer.frames.items {
                                        match frame {
                                            handler(_, _, slot) => { return slot }
                                            _ => {}
                                        }
                                    }
                                }
                                none => {}
                            }
                        }
                        seen += 1
                    }
                    none => {}
                }
            }
            none => {}
        }
    }
    return -1
}

/// The mounted page itself. `Renderer.component` hands back the component at a
/// slot; the page is whichever one is a `TodoPage`.
fn page_of(r: Renderer) -> Option<TodoPage> {
    for id: int in r.ids() {
        match r.component(id) {
            some(component) => {
                match component as? TodoPage {
                    some(page_) => { return some(page_) }
                    none => {}
                }
            }
            none => {}
        }
    }
    return none
}

fn items_mounted(r: Renderer) -> int {
    var n: int = 0
    for id: int in r.ids() {
        match r.component(id) {
            some(component) => {
                match component as? Item {
                    some(_) => { n += 1 }
                    none => {}
                }
            }
            none => {}
        }
    }
    return n
}

fn render_page(pages: PageMap, path: string) -> Option<Renderer> {
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

/// Everything the interactive path does to a mounted page: read a handler id
/// out of the frames the way a browser reads it out of the batch, dispatch,
/// flush, and serialize again.
fn walk(r: Renderer) {
    io.println(r.html())
    io.println("components mounted: {r.ids().len()} — the page, the card and {items_mounted(r)} items")

    io.println("")
    io.println("== clicking the third item ==")
    let third: int = item_handler(r, 2)
    // The `new` is on its own line, and the interpolation below just reads
    // the variable — clearer than constructing an object inside `"{ }"`.
    let click: MouseEvent = new MouseEvent()
    io.println("the click found its handler: {r.fire_mouse(third, click)}")
    // The page, the card and the one item whose `done` changed. The other
    // three items answer `should_render` false, because their recorded
    // parameters are the ones they already rendered.
    io.println("renders this pass: {r.flush()} of {r.ids().len()} mounted components")
    io.println(r.html())

    io.println("")
    io.println("== clicking it again puts it back ==")
    let again: MouseEvent = new MouseEvent()
    let _: bool = r.fire_mouse(third, again)
    io.println("renders this pass: {r.flush()}")
    io.println(r.html())

    io.println("")
    io.println("== dropping a task, from outside any event ==")
    match page_of(r) {
        none => { io.println("the page is not mounted") }
        some(todo) => {
            todo.drop(2)
            io.println("renders this pass: {r.flush()}")
            io.println("items still mounted: {items_mounted(r)}")
            io.println(r.html())
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

    io.println("== GET /todo/all ==")
    match render_page(pages, "/todo/all") {
        none => { return }
        some(r) => { walk(r) }
    }
    io.println("")
    io.println("== GET /todo/open — the same page, a different parameter ==")
    match render_page(pages, "/todo/open") {
        some(other) => { io.println(other.html()) }
        none => {}
    }

    io.println("")
    io.println("== GET /todo/done ==")
    match render_page(pages, "/todo/done") {
        some(other) => { io.println(other.html()) }
        none => {}
    }

    io.println("")
    io.println(r"== GET /todo — no {filter} in the path ==")
    match pages.find("GET", "/todo") {
        none => { io.println("no page is routed there — the host answers 404") }
        some(_) => { io.println("matched, which it should not have") }
    }
}
