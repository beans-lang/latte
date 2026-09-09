// The startup refusal for a page whose `init` takes arguments, and the control
// that makes it mean something.
//
// The hole this closes: `plan_for` asked `described.initializer().is_none()`,
// which is false for a page whose `init` takes three services — the descriptor
// exists, it just cannot be called with an empty argument list. So such a page
// scanned CLEAN and answered 500 on every request with "wrong reflected
// argument count", which is precisely the failure the refusal was written to
// move to startup. It walked past it for as long as the check asked only
// whether a descriptor existed.
//
// Both halves are asserted here because either alone proves nothing:
//
//   * with no container, the page must be REFUSED, by name, at startup;
//   * with a container, the same page must be ACCEPTED — otherwise the
//     refusal is not "no container", it is "latte cannot serve this page".
package main

import std.io
import {Builder, Component, PageMap, PagePlan, page, scan_pages,
        scan_pages_for} from latte

/// The subject: three arguments, none of which a zero-argument activation
/// could supply.
pub class Repo { pub fn init() {} }
pub class Clock { pub fn init() {} }

@page(route: r"/needs")
pub class NeedsServices extends Component {
    repo: Repo
    clock: Clock
    pub fn init(repo: Repo, clock: Clock) {
        self.repo = repo
        self.clock = clock
    }
    pub override fn render(b: Builder) {
        b.open(0, "p")
        b.text(1, "needs")
        b.close()
    }
}

/// The control page: an ordinary zero-argument `@page` in the same scan. It
/// must survive BOTH scans, or a refusal that took the whole page table down
/// would read the same as one that took only its subject.
@page(route: r"/plain")
pub class PlainPage extends Component {
    pub fn init() {}
    pub override fn render(b: Builder) {
        b.open(0, "p")
        b.text(1, "plain")
        b.close()
    }
}

fn usable(map: PageMap, name: string) -> bool {
    for plan: PagePlan in map.pages {
        if plan.name == name { return plan.usable() }
    }
    return false
}

fn report(what: string, got: string, want: string) {
    if got == want { io.println("ok   {what}: {got}") }
    else { io.println("FAIL {what}: got [{got}], want [{want}]") }
}

fn mentions(map: PageMap, needle: string) -> bool {
    for fault: string in map.faults {
        if fault.contains(needle) { return true }
    }
    return false
}

fn main() {
    io.println("== 1. no container: the page is refused at startup ==")
    let alone: PageMap = scan_pages_for(false)
    report("NeedsServices is refused", "{usable(alone, "NeedsServices")}", "false")
    report("the refusal names the argument count",
           "{mentions(alone, "whose `init` takes 2 argument(s)")}", "true")
    report("...and says what to do about it",
           "{mentions(alone, "Register the services it asks for")}", "true")
    report("THE CONTROL: the plain page survives the same scan",
           "{usable(alone, "PlainPage")}", "true")
    report("so the scan refused one page, not the table",
           "{alone.faults.len()}", "1")

    io.println("")
    io.println("== 2. with a container: the same page is ordinary ==")
    let with_container: PageMap = scan_pages_for(true)
    report("NeedsServices is accepted",
           "{usable(with_container, "NeedsServices")}", "true")
    report("the control is still fine",
           "{usable(with_container, "PlainPage")}", "true")
    report("and nothing was refused at all",
           "{with_container.faults.len()}", "0")

    io.println("")
    io.println("== 3. scan_pages() is scan_pages_for(false) ==")
    // The default must be the strict one: a host with no container is the
    // common case, and the refusal is only useful if it is the default.
    let plain_scan: PageMap = scan_pages()
    report("the no-argument scan refuses it too",
           "{usable(plain_scan, "NeedsServices")}", "false")
    report("with the same one fault", "{plain_scan.faults.len()}", "1")
}
