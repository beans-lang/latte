// `@memo`: which renders it skips, which it must not, and what it refuses.
//
// **This suite exists because the example's checks do not measure it.**
// `examples/cafe` asserts that picking one drink leaves the other two off the
// wire, and the comment beside its `ParamWatch` claimed that was the memo's
// doing. It is not: removing the memo entirely leaves that assertion passing,
// because the DIFFER is what keeps an unchanged row off the wire — it compares
// frames and emits nothing for two that match. The memo saves the *render*
// that produced those identical frames, and nothing in that example counted
// renders. So the hand-written `ParamWatch` there was, for its whole life,
// untested.
//
// What follows counts renders.
package main

import std.io
import {Builder, Callback, Component, ParamWatch, Renderer, memo,
        param, scan_memo} from latte

// ---------------------------------------------------------------- subjects

/// The subject: three scalar parameters and a callback, which is the shape a
/// list row actually has.
@memo
pub class Row extends Component {
    @param pub label: string = ""
    @param pub price: int = 0
    @param pub chosen: bool = false
    @param pub on_pick: Option<Callback<string>> = none
    pub renders: int = 0
    pub fn init() {}
    pub override fn render(b: Builder) {
        self.renders += 1
        b.open(0, "li")
        b.text(1, "{self.label}/{self.price}/{self.chosen}")
        b.close()
    }
}

/// THE CONTROL: the same component with no `@memo`. It must render every time
/// its parent does — otherwise "the memo skipped a render" could not be told
/// from "the framework skips renders".
pub class Plain extends Component {
    @param pub label: string = ""
    pub renders: int = 0
    pub fn init() {}
    pub override fn render(b: Builder) {
        self.renders += 1
        b.open(0, "li")
        b.text(1, "{self.label}")
        b.close()
    }
}

/// A parent that renders one of each, with parameters it is told to use.
pub class Page extends Component {
    pub label: string = "a"
    pub price: int = 1
    pub chosen: bool = false
    pub renders: int = 0
    pub fn init() {}
    pub override fn render(b: Builder) {
        self.renders += 1
        b.open(0, "ul")
        b.component<Row>(1, fn(c: Row) {
            c.label = self.label
            c.price = self.price
            c.chosen = self.chosen
            c.on_pick = some(new Callback<string>(self, fn(pick: string) {}))
        })
        b.component<Plain>(2, fn(c: Plain) { c.label = self.label })
        b.close()
    }
}

// ------------------------------------------------------- what it refuses

/// `@memo` on something that is not a component. Nothing would ever consult it.
@memo
pub class NotAComponent {
    @param pub label: string = ""
    pub fn init() {}
}

/// A component that takes child content. Its parameters can all be equal while
/// the markup inside it is completely different.
@memo
pub class TakesContent extends Component {
    @param pub label: string = ""
    @param pub body: fn(Builder) = fn(b: Builder) {}
    pub fn init() {}
    pub override fn render(b: Builder) {
        b.open(0, "div")
        b.fragment(1, self.body)
        b.close()
    }
}

/// A parameter latte cannot compare.
@memo
pub class TakesAList extends Component {
    @param pub rows: List<string> = []
    pub fn init() {}
    pub override fn render(b: Builder) {
        b.open(0, "div")
        b.text(1, "{self.rows.len()}")
        b.close()
    }
}

/// THE CONTROL for the scan: `@memo` on a component whose parameters are all
/// comparable. It must NOT be named.
@memo
pub class Fine extends Component {
    @param pub label: string = ""
    @param pub count: int = 0
    pub fn init() {}
    pub override fn render(b: Builder) {
        b.open(0, "div")
        b.text(1, "{self.label}{self.count}")
        b.close()
    }
}

// ---------------------------------------------------------------- reporting

fn report(what: string, got: string, want: string) {
    if got == want { io.println("ok   {what}: {got}") }
    else { io.println("FAIL {what}: got [{got}], want [{want}]") }
}

// Two concrete lookups and not one generic helper: `x as? T` on an unbounded
// `T` is refused — "as? goes from a parent to a child class" — because the test
// is decided at run time from the object's own class and `T` names no class
// there.
fn row_at(renderer: Renderer, id: int) -> Option<Row> {
    match renderer.component(id) {
        some(found) => { return found as? Row }
        none => { return none }
    }
}

fn plain_at(renderer: Renderer, id: int) -> Option<Plain> {
    match renderer.component(id) {
        some(found) => { return found as? Plain }
        none => { return none }
    }
}

fn main() {
    io.println("== 1. a parent re-render with no parameter change ==")
    let page: Page = new Page()
    let r: Renderer = new Renderer()
    r.mount(page)
    var row: Row = new Row()
    var plain: Plain = new Plain()
    for id: int in r.ids() {
        match row_at(r, id) { some(found) => { row = found } none => {} }
        match plain_at(r, id) { some(found) => { plain = found } none => {} }
    }
    report("everything rendered once", "{page.renders}/{row.renders}/{plain.renders}",
           "1/1/1")

    // Mark the PARENT dirty and flush. The parent re-renders, so both children
    // get a parameter pass — and the memoized one must decline.
    r.mark(0)
    let _f1: int = r.flush()
    report("the parent rendered again", "{page.renders}", "2")
    report("the memoized child did NOT", "{row.renders}", "1")
    report("THE CONTROL: the plain child did", "{plain.renders}", "2")

    io.println("")
    io.println("== 2. a parameter that actually changed ==")
    page.price = 2
    r.mark(0)
    let _f2: int = r.flush()
    report("the memoized child rendered", "{row.renders}", "2")
    report("and the html is the new value", r.html(),
           "<ul><li>a/2/false</li><li>a</li></ul>")

    io.println("")
    io.println("== 3. every scalar kind moves it, one at a time ==")
    page.label = "b"
    r.mark(0)
    let _f3: int = r.flush()
    report("a string parameter", "{row.renders}", "3")
    page.chosen = true
    r.mark(0)
    let _f4: int = r.flush()
    report("a bool parameter", "{row.renders}", "4")
    // And back to where it was: the memo compares against the LAST render, not
    // against the first, so returning a value to an earlier one is a change.
    page.chosen = false
    r.mark(0)
    let _f5: int = r.flush()
    report("and changing it back is a change too", "{row.renders}", "5")

    io.println("")
    io.println("== 4. a fresh Callback every render is not a change ==")
    // The parent builds a new `Callback` in its setter on every render. If the
    // memo compared it, the memo would never fire — which is worse than not
    // comparing it, and is why it does not.
    r.mark(0)
    let _f6: int = r.flush()
    report("the memoized child still declined", "{row.renders}", "5")
    report("THE CONTROL: the plain one still rendered", "{plain.renders}", "7")

    io.println("")
    io.println("== 5. what the startup scan refuses ==")
    var found: List<string> = scan_memo()
    found.sort()
    report("three, and no more", "{found.len()}", "3")
    report("a @memo that is not a component", found[0],
           "latte$entry.NotAComponent is annotated @memo but does not extend latte.Component, so nothing would ever consult it")
    report("a parameter it cannot compare", found[1],
           "latte$entry.TakesAList.rows is a @param of type List<string> on a @memo component, and latte cannot compare one — only string, int, bool and float. Write should_render yourself, or drop @memo")
    report("a component that takes child content", found[2],
           "latte$entry.TakesContent.body is a @param of type fn(latte.Builder) -> unit on a @memo component — a closure the parent rebuilds every render, holding markup that may be completely different. Its parameters can all be equal while its content is not. Drop @memo, or take the content another way")
    var named_fine: bool = false
    for problem: string in found {
        if problem.contains("Fine") { named_fine = true }
        if problem.contains("latte$entry.Row.") { named_fine = true }
    }
    report("THE CONTROL: a @memo that works is not named", "{named_fine}", "false")

    io.println("")
    io.println("== 6. ParamWatch by hand still works ==")
    // `@memo` is sugar over it, not a replacement for it: a component whose
    // parameters latte cannot compare writes one, and the scan tells it to.
    var watch: ParamWatch = new ParamWatch()
    report("a fresh watch has recorded nothing", "{watch.empty()}", "true")
    watch.record(["a", "1"])
    report("the first record is always a change", "{watch.differs()}", "true")
    watch.record(["a", "1"])
    report("the same values are not", "{watch.differs()}", "false")
    watch.record(["a", "2"])
    report("a different one is", "{watch.differs()}", "true")
}
