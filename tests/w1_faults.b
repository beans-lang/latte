// Every report site in `apply.b` and `serialize.b`: a trip, a control, a count.
//
// The companion to § 13 of `tests/frames.b`, which does the same for
// `builder.b`'s 24 sites. Three files, three tallies, one rule — RULES.md,
// "The refusal that never runs":
//
//   * a refusal test that still passes when the refusal is deleted is
//     worthless, and
//   * a refusal that cannot be made to fail is unreachable, and neither shows
//     up in a green run.
//
// `apply.b`'s 12 sites arrived here asserted EMPTY by the 10,000-case sweep in
// `tests/apply.b` § 4. A sweep that asserts "no fault was raised" over ten
// thousand cases says nothing at all about whether a fault CAN be raised, which
// is the opposite of exercising the site. `serialize.b`'s 4 had nothing.
//
// Each entry is four facts and not one:
//
//   1. an input that trips THAT site, with the EXACT fault text and count —
//      not "a fault happened". A count and a message are what tell a coarser
//      refusal standing in front of a finer one from the finer one firing.
//   2. what the refusal LEFT BEHIND. A refusal that reports and then does the
//      thing anyway is not a refusal, and three of these deliberately do part
//      of it: an out-of-range `insert` appends, an out-of-range `relocate` to
//      appends, a bad `step_in` descends into a placeholder so the matching
//      `step_out` still balances.
//   3. a POSITIVE CONTROL beside it, and every one of them is the NEAREST
//      LEGAL NEIGHBOUR — the index one past the refused one, the same name at
//      the seq that exists, the same two updates in the other order. A control
//      of "some valid batch" would pass just as well against a rule that
//      refused everything, and would be worth nothing.
//   4. the control CHANGED something. Asserted for every case, because an
//      applier that silently discarded a legal edit and one that applied it
//      both raise no fault, and only the state afterwards tells them apart.
//      `tests/frames.b` § 13 found the same trap one level down: three of its
//      controls render no HTML at all, so their acceptance had to be asserted
//      on the frames instead.
//
// The other half of the audit does not live in a suite and cannot: each site
// was deleted, one at a time, and the case naming it was watched to FAIL.
// `probes/delete_faults.sh` re-runs that pass over all three files.
//
// This is its own suite rather than a section of `tests/apply.b` for one
// measured reason: that suite's sweep takes 184 s, and the deletion pass runs
// the whole suite once per site. Sixteen sites there would be 37 minutes and
// nobody would run it; here it is a few seconds. `tests/apply.b` and
// `tests/html.b` both point at this file.
package main

import std.io
import {Applier, Batch, Builder, Component, ComponentUpdate, Differ, Edit,
        Frame, Frames, MouseEvent, Reference, Serializer} from latte

pub class Report {
    pub checks: int = 0
    pub bad: int = 0
    pub fn init() {}

    pub fn eq(name: string, got: string, want: string) {
        self.checks += 1
        if got == want {
            io.println("ok {name}")
        } else {
            self.bad += 1
            io.println("FAIL {name}: got {got}, want {want}")
        }
    }

    pub fn eqi(name: string, got: int, want: int) { self.eq(name, "{got}", "{want}") }
    pub fn yes(name: string, got: bool) { self.eq(name, "{got}", "true") }
    pub fn no(name: string, got: bool) { self.eq(name, "{got}", "false") }
}

// ---------------------------------------------------------------- helpers

fn joined(faults: List<string>) -> string {
    var out: string = ""
    var first: bool = true
    for fault: string in faults {
        if !first { out = "{out} | " }
        out = "{out}{fault}"
        first = false
    }
    return out
}

fn ints_to_text(values: List<int>) -> string {
    var out: string = ""
    for value: int in values { out = "{out} {value}" }
    return out
}

const KIND_ATTR: int = 0
const KIND_BIND: int = 1

/// Attribute or handler frames in a whole builder tree, nested buffers
/// included. A handler writes NO HTML (D7), so a control that removes one — or
/// fails to — looks identical in the page. This is what makes that visible.
fn count_kind(b: Builder, which: int) -> int {
    var total: int = 0
    var index: int = 0
    for index < b.frames.len() {
        match b.frames.at(index) {
            attribute(_, _, _) => { if which == KIND_ATTR { total += 1 } }
            flag(_, _, _) => { if which == KIND_ATTR { total += 1 } }
            handler(_, _, _) => { if which == KIND_BIND { total += 1 } }
            _ => {}
        }
        index += 1
    }
    var slots: List<int> = b.nested.keys()
    slots.sort()
    for slot: int in slots {
        match b.nested.get(slot) {
            some(child) => { total += count_kind(child, which) }
            none => {}
        }
    }
    return total
}

/// Everything an applier holds, on one line. The HTML alone cannot see three
/// of the things these cases are about: a root allocated for a component that
/// never mounted, a handler slot, and whether the applier's own serializer
/// complained on the way out.
fn applier_state(a: Applier) -> string {
    let html: string = a.html()
    let tree: Builder = a.to_builder()
    var ids: List<int> = a.roots.keys()
    ids.sort()
    return "{html} roots={ints_to_text(ids)} attrs={count_kind(tree, KIND_ATTR)} binds={count_kind(tree, KIND_BIND)} sfaults={a.serializer_faults.len()}"
}

fn html_of(b: Builder) -> string {
    let writer: Serializer = new Serializer()
    return writer.page(b)
}

fn at_component(batch: Batch, component: int, list: List<Edit>) {
    let update: ComponentUpdate = new ComponentUpdate(component)
    for edit: Edit in list { update.edits.push(edit) }
    batch.updates.push(update)
}

/// `<b>new</b>`, staged at offset 0 of a batch's reference pool.
fn stage_b(pool: Frames) {
    pool.push(Frame.open(9, "b"))
    pool.push(Frame.text(0, "new"))
    pool.push(Frame.close)
}

// ---------------------------------------------------------------- fixtures

pub class Sheet extends Component {
    pub body: fn(Builder) = fn(b: Builder) {}
    pub fn init() {}
    pub override fn render(b: Builder) { self.body(b) }
}

pub class Badge extends Component {
    pub fn init() {}
    pub override fn render(b: Builder) {
        b.open(0, "span")
        b.text(1, "badge")
        b.close()
    }
}

/// A Component whose `init` takes an argument, so reflection can find the
/// descriptor and the call fails. This is the REAL route into the serializer's
/// "no frame buffer" site: `fill_slot` writes the `child` frame on the path
/// where the mount failed, and that path never called `buffer_for`.
pub class NeedsSeed extends Component {
    pub seed: int = 0
    pub fn init(seed: int) { self.seed = seed }
    pub override fn render(b: Builder) { b.text(0, "seeded") }
}

fn render_body(b: Builder, body: fn(Builder)) {
    let sheet: Sheet = new Sheet()
    sheet.body = body
    b.render_root(sheet)
}

/// The tree every applier case starts from:
///
///     <div id="root">head<p class="row">one</p>tail<em>raw</em></div>
///
/// FOUR children under the div, not one and not two. Every index bound in
/// `apply.b` is `< 0 || >= len` or `< 0 || > len`, and a tree with one child
/// cannot tell those two apart — the boundary controls below are `len - 1` and
/// `len`, and they need room. One `<p>` carries an attribute and a handler so
/// the two "nothing to remove" sites have something that IS there to serve as
/// their control.
///
/// The four are deliberately four DIFFERENT kinds — text, element, text,
/// markup — and the first is a text node on purpose: the nearest legal
/// neighbour of `set_text(-1, …)` is `set_text(0, …)`, and a control that
/// landed on an element there is accepted, does nothing, and reads as a pass.
/// `edits_the_applier_takes_silently` below is what that measurement became.
fn seed(a: Applier) {
    let b: Builder = new Builder()
    render_body(b, fn(inner: Builder) {
        inner.open(0, "div")
        inner.attr(1, "id", "root")
        inner.text(2, "head")
        inner.open(3, "p")
        inner.attr(1, "class", "row")
        inner.on_click(2, fn(e: MouseEvent) {})
        inner.text(0, "one")
        inner.close()
        inner.text(4, "tail")
        inner.raw(5, "<em>raw</em>")
        inner.close()
    })
    let d: Differ = new Differ()
    a.apply(d.batch(b))
    a.faults.clear()
}

fn seeded() -> Applier {
    let a: Applier = new Applier()
    seed(a)
    return a
}

// ------------------------------------------- 1 every fault site in apply.b

/// One report site in `apply.b`, one trip, one control.
pub class ASite {
    /// The site, named by the method it lives in and its message — a name and
    /// not a line number, because a line number in a golden goes stale the
    /// first time anything above it moves.
    pub site: string = ""
    /// This case's own name. One site is reached by several shapes.
    pub name: string = ""
    /// The batch that must be refused.
    pub trip: fn(Batch) = fn(batch: Batch) {}
    /// The exact faults it must raise, joined with " | ".
    pub want: string = ""
    /// What the applier holds afterwards.
    pub left: string = ""
    /// The nearest legal batch, which must be accepted.
    pub control: fn(Batch) = fn(batch: Batch) {}
    /// What the applier holds after the control. Asserted to DIFFER from the
    /// seed: a legal edit that was quietly discarded raises no fault either.
    pub accepted: string = ""

    pub fn init(site: string, name: string, trip: fn(Batch), want: string,
                left: string, control: fn(Batch), accepted: string) {
        self.site = site
        self.name = name
        self.trip = trip
        self.want = want
        self.left = left
        self.control = control
        self.accepted = accepted
    }
}

const A_ROOT_FOR: string = "root_for / update for component N arrived before its mount"
const A_STEP_IN: string = "step_in / step_in N of M"
const A_STEP_OUT: string = "step_out / step_out at the root"
const A_INSERT_AT: string = "insert / insert at N of M"
const A_INSERT_STAGED: string = "insert / no staged subtree at N"
const A_REMOVE: string = "remove / remove N of M"
const A_MOVE_FROM: string = "relocate / move from N of M"
const A_MOVE_TO: string = "relocate / move to N of M"
const A_REMOVE_ATTR: string = "remove_attr / no attribute S:N to remove"
const A_REMOVE_HANDLER: string = "remove_handler / no handler S:E to remove"
const A_DEEP: string = "run / the edit stream ended N level(s) deep"
const A_KID: string = "kid / WHAT N of M"

fn apply_sites() -> List<ASite> {
    var out: List<ASite> = []

    // -- root_for ---------------------------------------------------------
    //
    // Two shapes, and the second is the one that actually happens: a batch out
    // of pre-order. The applier allocates a synthetic root so the edits have
    // somewhere to land, and when the mount frame arrives afterwards
    // `Applier.build` finds that root and REUSES it — so the content survives
    // and the fault is the only trace. Without the count asserted, this shape
    // is indistinguishable from a correct batch.
    out.push(new ASite(A_ROOT_FOR, "update-for-a-component-that-never-mounts",
        fn(batch: Batch) {
            batch.reference.push(Frame.text(0, "stray"))
            at_component(batch, 7, [Edit.insert(0, 0)])
        },
        "update for component 7 arrived before its mount",
        "<div id=\"root\">head<p class=\"row\">one</p>tail<em>raw</em></div> roots= 0 7 attrs=2 binds=1 sfaults=0",
        fn(batch: Batch) {
            batch.reference.push(Frame.text(0, "stray"))
            at_component(batch, 0, [Edit.step_in(0), Edit.insert(4, 0), Edit.step_out])
        }, "<div id=\"root\">head<p class=\"row\">one</p>tail<em>raw</em>stray</div> roots= 0 attrs=2 binds=1 sfaults=0"))

    out.push(new ASite(A_ROOT_FOR, "a-childs-update-before-its-own-mount",
        fn(batch: Batch) {
            batch.reference.push(Frame.child(6, "Badge", 3))
            batch.reference.push(Frame.text(0, "from the child"))
            at_component(batch, 3, [Edit.insert(0, 1)])
            at_component(batch, 0, [Edit.step_in(0), Edit.insert(4, 0), Edit.step_out])
        },
        "update for component 3 arrived before its mount", "<div id=\"root\">head<p class=\"row\">one</p>tail<em>raw</em>from the child</div> roots= 0 3 attrs=2 binds=1 sfaults=0",
        fn(batch: Batch) {
            batch.reference.push(Frame.child(6, "Badge", 3))
            batch.reference.push(Frame.text(0, "from the child"))
            at_component(batch, 0, [Edit.step_in(0), Edit.insert(4, 0), Edit.step_out])
            at_component(batch, 3, [Edit.insert(0, 1)])
        }, "<div id=\"root\">head<p class=\"row\">one</p>tail<em>raw</em>from the child</div> roots= 0 3 attrs=2 binds=1 sfaults=0"))

    // -- step_in ----------------------------------------------------------
    out.push(new ASite(A_STEP_IN, "step-in-past-the-last-child",
        fn(batch: Batch) {
            at_component(batch, 0, [Edit.step_in(0), Edit.step_in(4),
                                    Edit.step_out, Edit.step_out])
        },
        "component 0: step_in 4 of 4", "<div id=\"root\">head<p class=\"row\">one</p>tail<em>raw</em></div> roots= 0 attrs=2 binds=1 sfaults=0",
        // The boundary: `index >= len` refuses, so `len - 1` must be accepted.
        // The edit after it is what proves the descent was real rather than
        // silently swallowed.
        fn(batch: Batch) {
            at_component(batch, 0, [Edit.step_in(0), Edit.step_in(3), Edit.step_out,
                                    Edit.set_text(2, "TAIL"), Edit.step_out])
        }, "<div id=\"root\">head<p class=\"row\">one</p>TAIL<em>raw</em></div> roots= 0 attrs=2 binds=1 sfaults=0"))

    out.push(new ASite(A_STEP_IN, "step-in-a-negative-index",
        fn(batch: Batch) {
            at_component(batch, 0, [Edit.step_in(0), Edit.step_in(-1),
                                    Edit.step_out, Edit.step_out])
        },
        "component 0: step_in -1 of 4", "<div id=\"root\">head<p class=\"row\">one</p>tail<em>raw</em></div> roots= 0 attrs=2 binds=1 sfaults=0",
        fn(batch: Batch) {
            at_component(batch, 0, [Edit.step_in(0), Edit.step_in(0), Edit.step_out,
                                    Edit.step_in(1), Edit.set_text(0, "ONE"),
                                    Edit.step_out, Edit.step_out])
        }, "<div id=\"root\">head<p class=\"row\">ONE</p>tail<em>raw</em></div> roots= 0 attrs=2 binds=1 sfaults=0"))

    // -- step_out ---------------------------------------------------------
    out.push(new ASite(A_STEP_OUT, "step-out-at-the-root",
        fn(batch: Batch) { at_component(batch, 0, [Edit.step_out]) },
        "component 0: step_out at the root", "<div id=\"root\">head<p class=\"row\">one</p>tail<em>raw</em></div> roots= 0 attrs=2 binds=1 sfaults=0",
        fn(batch: Batch) {
            at_component(batch, 0, [Edit.step_in(0), Edit.set_text(2, "TAIL"),
                                    Edit.step_out])
        }, "<div id=\"root\">head<p class=\"row\">one</p>TAIL<em>raw</em></div> roots= 0 attrs=2 binds=1 sfaults=0"))

    out.push(new ASite(A_STEP_OUT, "one-step-out-too-many",
        fn(batch: Batch) {
            at_component(batch, 0, [Edit.step_in(0), Edit.step_out, Edit.step_out])
        },
        "component 0: step_out at the root", "<div id=\"root\">head<p class=\"row\">one</p>tail<em>raw</em></div> roots= 0 attrs=2 binds=1 sfaults=0",
        // Two legal step_outs, so "the second one is refused" cannot pass for
        // "one per stream".
        fn(batch: Batch) {
            at_component(batch, 0, [Edit.step_in(0), Edit.step_out, Edit.step_in(0),
                                    Edit.set_text(2, "TAIL"), Edit.step_out])
        }, "<div id=\"root\">head<p class=\"row\">one</p>TAIL<em>raw</em></div> roots= 0 attrs=2 binds=1 sfaults=0"))

    // -- insert, index ----------------------------------------------------
    out.push(new ASite(A_INSERT_AT, "insert-past-the-end",
        fn(batch: Batch) {
            stage_b(batch.reference)
            at_component(batch, 0, [Edit.step_in(0), Edit.insert(5, 0), Edit.step_out])
        },
        "component 0: insert at 5 of 4", "<div id=\"root\">head<p class=\"row\">one</p>tail<em>raw</em><b>new</b></div> roots= 0 attrs=2 binds=1 sfaults=0",
        // `index > len` refuses, so `index == len` — an append — is legal, and
        // this is the control that would catch that bound written `>=`.
        fn(batch: Batch) {
            stage_b(batch.reference)
            at_component(batch, 0, [Edit.step_in(0), Edit.insert(4, 0), Edit.step_out])
        }, "<div id=\"root\">head<p class=\"row\">one</p>tail<em>raw</em><b>new</b></div> roots= 0 attrs=2 binds=1 sfaults=0"))

    out.push(new ASite(A_INSERT_AT, "insert-at-a-negative-index",
        fn(batch: Batch) {
            stage_b(batch.reference)
            at_component(batch, 0, [Edit.step_in(0), Edit.insert(-1, 0), Edit.step_out])
        },
        "component 0: insert at -1 of 4", "<div id=\"root\">head<p class=\"row\">one</p>tail<em>raw</em><b>new</b></div> roots= 0 attrs=2 binds=1 sfaults=0",
        fn(batch: Batch) {
            stage_b(batch.reference)
            at_component(batch, 0, [Edit.step_in(0), Edit.insert(0, 0), Edit.step_out])
        }, "<div id=\"root\"><b>new</b>head<p class=\"row\">one</p>tail<em>raw</em></div> roots= 0 attrs=2 binds=1 sfaults=0"))

    // -- insert, the staged subtree ---------------------------------------
    //
    // `span_at` answers `none` for four different offsets, and all four reach
    // this one site: past the pool, negative, a frame that CLOSES a scope, and
    // a frame from inside an attribute run. The last two are the ones a real
    // staging bug produces — an offset off by one lands on exactly those.
    out.push(new ASite(A_INSERT_STAGED, "insert-from-past-the-end-of-the-pool",
        fn(batch: Batch) {
            stage_b(batch.reference)
            at_component(batch, 0, [Edit.step_in(0), Edit.insert(0, 7), Edit.step_out])
        },
        "component 0: no staged subtree at 7", "<div id=\"root\">head<p class=\"row\">one</p>tail<em>raw</em></div> roots= 0 attrs=2 binds=1 sfaults=0",
        fn(batch: Batch) {
            stage_b(batch.reference)
            at_component(batch, 0, [Edit.step_in(0), Edit.insert(0, 0), Edit.step_out])
        }, "<div id=\"root\"><b>new</b>head<p class=\"row\">one</p>tail<em>raw</em></div> roots= 0 attrs=2 binds=1 sfaults=0"))

    out.push(new ASite(A_INSERT_STAGED, "insert-from-a-negative-offset",
        fn(batch: Batch) {
            stage_b(batch.reference)
            at_component(batch, 0, [Edit.step_in(0), Edit.insert(0, -1), Edit.step_out])
        },
        "component 0: no staged subtree at -1", "<div id=\"root\">head<p class=\"row\">one</p>tail<em>raw</em></div> roots= 0 attrs=2 binds=1 sfaults=0",
        fn(batch: Batch) {
            stage_b(batch.reference)
            at_component(batch, 0, [Edit.step_in(0), Edit.insert(0, 0), Edit.step_out])
        }, "<div id=\"root\"><b>new</b>head<p class=\"row\">one</p>tail<em>raw</em></div> roots= 0 attrs=2 binds=1 sfaults=0"))

    out.push(new ASite(A_INSERT_STAGED, "insert-from-the-close-frame-of-a-staged-subtree",
        fn(batch: Batch) {
            stage_b(batch.reference)
            at_component(batch, 0, [Edit.step_in(0), Edit.insert(0, 2), Edit.step_out])
        },
        "component 0: no staged subtree at 2", "<div id=\"root\">head<p class=\"row\">one</p>tail<em>raw</em></div> roots= 0 attrs=2 binds=1 sfaults=0",
        // Two subtrees staged, inserting from the SECOND: a non-zero offset
        // must resolve, or "no staged subtree at N" would read as "only offset
        // 0 works" and every case above would pass for the wrong reason.
        fn(batch: Batch) {
            stage_b(batch.reference)
            batch.reference.push(Frame.text(0, "second"))
            at_component(batch, 0, [Edit.step_in(0), Edit.insert(0, 3), Edit.step_out])
        }, "<div id=\"root\">secondhead<p class=\"row\">one</p>tail<em>raw</em></div> roots= 0 attrs=2 binds=1 sfaults=0"))

    out.push(new ASite(A_INSERT_STAGED, "insert-from-inside-an-attribute-run",
        fn(batch: Batch) {
            batch.reference.push(Frame.open(9, "b"))
            batch.reference.push(Frame.attribute(0, "class", "x"))
            batch.reference.push(Frame.text(0, "new"))
            batch.reference.push(Frame.close)
            at_component(batch, 0, [Edit.step_in(0), Edit.insert(0, 1), Edit.step_out])
        },
        "component 0: no staged subtree at 1", "<div id=\"root\">head<p class=\"row\">one</p>tail<em>raw</em></div> roots= 0 attrs=2 binds=1 sfaults=0",
        fn(batch: Batch) {
            batch.reference.push(Frame.open(9, "b"))
            batch.reference.push(Frame.attribute(0, "class", "x"))
            batch.reference.push(Frame.text(0, "new"))
            batch.reference.push(Frame.close)
            at_component(batch, 0, [Edit.step_in(0), Edit.insert(0, 0), Edit.step_out])
        }, "<div id=\"root\"><b class=\"x\">new</b>head<p class=\"row\">one</p>tail<em>raw</em></div> roots= 0 attrs=3 binds=1 sfaults=0"))

    // -- remove -----------------------------------------------------------
    out.push(new ASite(A_REMOVE, "remove-past-the-last-child",
        fn(batch: Batch) {
            at_component(batch, 0, [Edit.step_in(0), Edit.remove(4), Edit.step_out])
        },
        "component 0: remove 4 of 4", "<div id=\"root\">head<p class=\"row\">one</p>tail<em>raw</em></div> roots= 0 attrs=2 binds=1 sfaults=0",
        fn(batch: Batch) {
            at_component(batch, 0, [Edit.step_in(0), Edit.remove(3), Edit.step_out])
        }, "<div id=\"root\">head<p class=\"row\">one</p>tail</div> roots= 0 attrs=2 binds=1 sfaults=0"))

    out.push(new ASite(A_REMOVE, "remove-a-negative-index",
        fn(batch: Batch) {
            at_component(batch, 0, [Edit.step_in(0), Edit.remove(-1), Edit.step_out])
        },
        "component 0: remove -1 of 4", "<div id=\"root\">head<p class=\"row\">one</p>tail<em>raw</em></div> roots= 0 attrs=2 binds=1 sfaults=0",
        fn(batch: Batch) {
            at_component(batch, 0, [Edit.step_in(0), Edit.remove(0), Edit.step_out])
        }, "<div id=\"root\"><p class=\"row\">one</p>tail<em>raw</em></div> roots= 0 attrs=2 binds=1 sfaults=0"))

    // -- relocate, from ---------------------------------------------------
    out.push(new ASite(A_MOVE_FROM, "move-from-past-the-last-child",
        fn(batch: Batch) {
            at_component(batch, 0, [Edit.step_in(0), Edit.relocate(4, 0), Edit.step_out])
        },
        "component 0: move from 4 of 4", "<div id=\"root\">head<p class=\"row\">one</p>tail<em>raw</em></div> roots= 0 attrs=2 binds=1 sfaults=0",
        fn(batch: Batch) {
            at_component(batch, 0, [Edit.step_in(0), Edit.relocate(3, 0), Edit.step_out])
        }, "<div id=\"root\"><em>raw</em>head<p class=\"row\">one</p>tail</div> roots= 0 attrs=2 binds=1 sfaults=0"))

    out.push(new ASite(A_MOVE_FROM, "move-from-a-negative-index",
        fn(batch: Batch) {
            at_component(batch, 0, [Edit.step_in(0), Edit.relocate(-1, 0), Edit.step_out])
        },
        "component 0: move from -1 of 4", "<div id=\"root\">head<p class=\"row\">one</p>tail<em>raw</em></div> roots= 0 attrs=2 binds=1 sfaults=0",
        fn(batch: Batch) {
            at_component(batch, 0, [Edit.step_in(0), Edit.relocate(0, 3), Edit.step_out])
        }, "<div id=\"root\"><p class=\"row\">one</p>tail<em>raw</em>head</div> roots= 0 attrs=2 binds=1 sfaults=0"))

    // -- relocate, to -----------------------------------------------------
    //
    // The bound is measured AFTER the node has been taken out, which is why
    // the message says "of 3" against a four-child element. `to == len` is a
    // legal append, and the control sits exactly there: the trip and the
    // control leave the SAME tree, and only the fault list separates them.
    out.push(new ASite(A_MOVE_TO, "move-to-past-the-end",
        fn(batch: Batch) {
            at_component(batch, 0, [Edit.step_in(0), Edit.relocate(0, 4), Edit.step_out])
        },
        "component 0: move to 4 of 3", "<div id=\"root\"><p class=\"row\">one</p>tail<em>raw</em>head</div> roots= 0 attrs=2 binds=1 sfaults=0",
        fn(batch: Batch) {
            at_component(batch, 0, [Edit.step_in(0), Edit.relocate(0, 3), Edit.step_out])
        }, "<div id=\"root\"><p class=\"row\">one</p>tail<em>raw</em>head</div> roots= 0 attrs=2 binds=1 sfaults=0"))

    out.push(new ASite(A_MOVE_TO, "move-to-a-negative-index",
        fn(batch: Batch) {
            at_component(batch, 0, [Edit.step_in(0), Edit.relocate(0, -1), Edit.step_out])
        },
        "component 0: move to -1 of 3", "<div id=\"root\"><p class=\"row\">one</p>tail<em>raw</em>head</div> roots= 0 attrs=2 binds=1 sfaults=0",
        fn(batch: Batch) {
            at_component(batch, 0, [Edit.step_in(0), Edit.relocate(3, 0), Edit.step_out])
        }, "<div id=\"root\"><em>raw</em>head<p class=\"row\">one</p>tail</div> roots= 0 attrs=2 binds=1 sfaults=0"))

    // -- remove_attr ------------------------------------------------------
    //
    // The key is `(seq, name)`, so both halves need a shape: the right name at
    // a seq that has none, and the wrong name at a seq that has one. Its
    // control removes the slot that IS there, which is the only thing that can
    // tell "no such slot" from "removal is broken".
    out.push(new ASite(A_REMOVE_ATTR, "remove-an-attribute-at-a-seq-that-has-none",
        fn(batch: Batch) {
            at_component(batch, 0, [Edit.step_in(0), Edit.step_in(1),
                                    Edit.remove_attr(9, "class"),
                                    Edit.step_out, Edit.step_out])
        },
        "component 0: no attribute 9:class to remove", "<div id=\"root\">head<p class=\"row\">one</p>tail<em>raw</em></div> roots= 0 attrs=2 binds=1 sfaults=0",
        fn(batch: Batch) {
            at_component(batch, 0, [Edit.step_in(0), Edit.step_in(1),
                                    Edit.remove_attr(1, "class"),
                                    Edit.step_out, Edit.step_out])
        }, "<div id=\"root\">head<p>one</p>tail<em>raw</em></div> roots= 0 attrs=1 binds=1 sfaults=0"))

    out.push(new ASite(A_REMOVE_ATTR, "remove-an-attribute-by-a-name-that-is-not-there",
        fn(batch: Batch) {
            at_component(batch, 0, [Edit.step_in(0), Edit.step_in(1),
                                    Edit.remove_attr(1, "id"),
                                    Edit.step_out, Edit.step_out])
        },
        "component 0: no attribute 1:id to remove", "<div id=\"root\">head<p class=\"row\">one</p>tail<em>raw</em></div> roots= 0 attrs=2 binds=1 sfaults=0",
        // `id` IS a slot on the div, at the same seq 1 — one level up. So the
        // control removes it there, which proves the miss was about the node
        // and not about the name.
        fn(batch: Batch) {
            at_component(batch, 0, [Edit.step_in(0), Edit.remove_attr(1, "id"),
                                    Edit.step_out])
        }, "<div>head<p class=\"row\">one</p>tail<em>raw</em></div> roots= 0 attrs=1 binds=1 sfaults=0"))

    // -- remove_handler ---------------------------------------------------
    out.push(new ASite(A_REMOVE_HANDLER, "remove-a-handler-at-a-seq-that-has-none",
        fn(batch: Batch) {
            at_component(batch, 0, [Edit.step_in(0), Edit.step_in(1),
                                    Edit.remove_handler(9, "click"),
                                    Edit.step_out, Edit.step_out])
        },
        "component 0: no handler 9:click to remove", "<div id=\"root\">head<p class=\"row\">one</p>tail<em>raw</em></div> roots= 0 attrs=2 binds=1 sfaults=0",
        fn(batch: Batch) {
            at_component(batch, 0, [Edit.step_in(0), Edit.step_in(1),
                                    Edit.remove_handler(2, "click"),
                                    Edit.step_out, Edit.step_out])
        }, "<div id=\"root\">head<p class=\"row\">one</p>tail<em>raw</em></div> roots= 0 attrs=2 binds=0 sfaults=0"))

    out.push(new ASite(A_REMOVE_HANDLER, "remove-a-handler-for-an-event-that-is-not-bound",
        fn(batch: Batch) {
            at_component(batch, 0, [Edit.step_in(0), Edit.step_in(1),
                                    Edit.remove_handler(2, "dblclick"),
                                    Edit.step_out, Edit.step_out])
        },
        "component 0: no handler 2:dblclick to remove", "<div id=\"root\">head<p class=\"row\">one</p>tail<em>raw</em></div> roots= 0 attrs=2 binds=1 sfaults=0",
        // Bind dblclick at the SAME seq, remove it, then remove click. The
        // first two halves prove the event name is part of the key rather than
        // decoration — the removal that just failed succeeds once the name is
        // bound — and the third is what leaves the tree measurably different,
        // because binding and unbinding dblclick alone lands back on the seed
        // and would read exactly like a control that was quietly discarded.
        fn(batch: Batch) {
            at_component(batch, 0, [Edit.step_in(0), Edit.step_in(1),
                                    Edit.set_handler(2, "dblclick", 41),
                                    Edit.remove_handler(2, "dblclick"),
                                    Edit.remove_handler(2, "click"),
                                    Edit.step_out, Edit.step_out])
        }, "<div id=\"root\">head<p class=\"row\">one</p>tail<em>raw</em></div> roots= 0 attrs=2 binds=0 sfaults=0"))

    // -- the stream's depth -----------------------------------------------
    out.push(new ASite(A_DEEP, "the-stream-ended-one-level-deep",
        fn(batch: Batch) { at_component(batch, 0, [Edit.step_in(0)]) },
        "component 0: the edit stream ended 1 level(s) deep", "<div id=\"root\">head<p class=\"row\">one</p>tail<em>raw</em></div> roots= 0 attrs=2 binds=1 sfaults=0",
        fn(batch: Batch) {
            at_component(batch, 0, [Edit.step_in(0), Edit.set_text(2, "TAIL"),
                                    Edit.step_out])
        }, "<div id=\"root\">head<p class=\"row\">one</p>TAIL<em>raw</em></div> roots= 0 attrs=2 binds=1 sfaults=0"))

    out.push(new ASite(A_DEEP, "the-stream-ended-two-levels-deep",
        fn(batch: Batch) {
            at_component(batch, 0, [Edit.step_in(0), Edit.step_in(0)])
        },
        "component 0: the edit stream ended 2 level(s) deep", "<div id=\"root\">head<p class=\"row\">one</p>tail<em>raw</em></div> roots= 0 attrs=2 binds=1 sfaults=0",
        fn(batch: Batch) {
            at_component(batch, 0, [Edit.step_in(0), Edit.step_in(1),
                                    Edit.set_text(0, "ONE"),
                                    Edit.step_out, Edit.step_out])
        }, "<div id=\"root\">head<p class=\"row\">ONE</p>tail<em>raw</em></div> roots= 0 attrs=2 binds=1 sfaults=0"))

    // -- kid, reached by set_text and set_markup --------------------------
    //
    // One site, two callers, and `what` is the caller's own name — so a shape
    // for each, or a site that answered "set_text" for a set_markup would look
    // covered.
    out.push(new ASite(A_KID, "set-text-past-the-last-child",
        fn(batch: Batch) {
            at_component(batch, 0, [Edit.step_in(0), Edit.set_text(4, "x"), Edit.step_out])
        },
        "component 0: set_text 4 of 4", "<div id=\"root\">head<p class=\"row\">one</p>tail<em>raw</em></div> roots= 0 attrs=2 binds=1 sfaults=0",
        fn(batch: Batch) {
            at_component(batch, 0, [Edit.step_in(0), Edit.set_text(2, "TAIL"), Edit.step_out])
        }, "<div id=\"root\">head<p class=\"row\">one</p>TAIL<em>raw</em></div> roots= 0 attrs=2 binds=1 sfaults=0"))

    out.push(new ASite(A_KID, "set-text-at-a-negative-index",
        fn(batch: Batch) {
            at_component(batch, 0, [Edit.step_in(0), Edit.set_text(-1, "x"), Edit.step_out])
        },
        "component 0: set_text -1 of 4", "<div id=\"root\">head<p class=\"row\">one</p>tail<em>raw</em></div> roots= 0 attrs=2 binds=1 sfaults=0",
        fn(batch: Batch) {
            at_component(batch, 0, [Edit.step_in(0), Edit.set_text(0, "HEAD"),
                                    Edit.step_out])
        }, "<div id=\"root\">HEAD<p class=\"row\">one</p>tail<em>raw</em></div> roots= 0 attrs=2 binds=1 sfaults=0"))

    out.push(new ASite(A_KID, "set-markup-past-the-last-child",
        fn(batch: Batch) {
            at_component(batch, 0, [Edit.step_in(0), Edit.set_markup(4, "<i>x</i>"),
                                    Edit.step_out])
        },
        "component 0: set_markup 4 of 4", "<div id=\"root\">head<p class=\"row\">one</p>tail<em>raw</em></div> roots= 0 attrs=2 binds=1 sfaults=0",
        // Index 3 is the `raw` node, so the control's html changes UNESCAPED —
        // which also proves set_markup landed on a markup node rather than
        // being read as text.
        fn(batch: Batch) {
            at_component(batch, 0, [Edit.step_in(0), Edit.set_markup(3, "<b>mk</b>"),
                                    Edit.step_out])
        }, "<div id=\"root\">head<p class=\"row\">one</p>tail<b>mk</b></div> roots= 0 attrs=2 binds=1 sfaults=0"))

    out.push(new ASite(A_KID, "set-markup-at-a-negative-index",
        fn(batch: Batch) {
            at_component(batch, 0, [Edit.step_in(0), Edit.set_markup(-1, "<i>x</i>"),
                                    Edit.step_out])
        },
        "component 0: set_markup -1 of 4", "<div id=\"root\">head<p class=\"row\">one</p>tail<em>raw</em></div> roots= 0 attrs=2 binds=1 sfaults=0",
        fn(batch: Batch) {
            at_component(batch, 0, [Edit.step_in(0), Edit.set_markup(3, "<b>mk</b>"),
                                    Edit.step_out])
        }, "<div id=\"root\">head<p class=\"row\">one</p>tail<b>mk</b></div> roots= 0 attrs=2 binds=1 sfaults=0"))

    return move out
}

fn apply_fault_sites(r: Report) {
    io.println("== 1 every fault site in apply.b")
    let base: Applier = seeded()
    let start: string = applier_state(base)
    io.println("seed: {start}")
    r.eq("the seed is the tree every case starts from", start,
        "<div id=\"root\">head<p class=\"row\">one</p>tail<em>raw</em></div> roots= 0 attrs=2 binds=1 sfaults=0")
    r.eqi("the seed raises nothing", base.faults.len(), 0)

    var reached: Map<string, int> = {}
    for probe: ASite in apply_sites() {
        let bad: Applier = seeded()
        let trip_batch: Batch = new Batch()
        probe.trip(trip_batch)
        bad.apply(trip_batch)

        let good: Applier = seeded()
        let control_batch: Batch = new Batch()
        probe.control(control_batch)
        good.apply(control_batch)

        let after: string = applier_state(bad)
        let accepted: string = applier_state(good)
        io.println("-- {probe.name}")
        io.println("   site:    {probe.site}")
        io.println("   faults:  {joined(bad.faults)}")
        io.println("   left:    {after}")
        io.println("   control: {accepted}")

        r.eq("{probe.name}: the exact faults", joined(bad.faults), probe.want)
        r.eq("{probe.name}: what the refusal left", after, probe.left)
        r.eq("{probe.name}: the control raises nothing", joined(good.faults), "")
        r.eq("{probe.name}: and the control applied", accepted, probe.accepted)
        // The half a fault list cannot see: an applier that dropped the legal
        // edit on the floor raises nothing either.
        r.no("{probe.name}: and the control changed the tree", accepted == start)

        match reached.get(probe.site) {
            some(n) => { reached[probe.site] = n + 1 }
            none => { reached[probe.site] = 1 }
        }
    }

    var names: List<string> = reached.keys()
    names.sort()
    io.println("-- the sites in apply.b, and how many shapes reach each")
    for name: string in names {
        match reached.get(name) {
            some(n) => { io.println("   {n}x {name}") }
            none => {}
        }
    }
    r.eqi("every fault site in apply.b has a case", names.len(), 12)
}

/// What the applier takes WITHOUT a fault, and what it does with it.
///
/// `Applier.kid` checks the index and hands back whatever node is there — it
/// never asks what KIND of node it is. So `set_text` addressed at an element,
/// a markup node or a mounted child is accepted, silently, and changes
/// nothing; `set_markup` addressed at a text node is accepted and lands
/// ESCAPED; and `set_attr` / `set_handler` addressed while the cursor is on a
/// text node are stored on that node and dropped again by `Applier.emit`.
///
/// Six shapes, all pinned rather than refused, and that is a decision:
///
///   * NO WELL-FORMED BATCH CONTAINS ONE. `Differ.pair` reaches `set_text`
///     only under `o.kind == SPAN_TEXT` and `set_markup` only under
///     `o.kind == SPAN_MARKUP`, and attribute and handler edits are pushed
///     only from `diff_element`, after a `step_in` onto an element. So this is
///     reachable from a differ bug or a hand-built batch and from nothing else,
///     which is why the 10,000-case sweep has never produced one.
///   * IT IS STILL A DIVERGENCE, and that is why it is measured here rather
///     than left unwritten. `latte.js` applies the same edit stream to a real
///     DOM, where `node.textContent = body` on an element WIPES its children.
///     Beans does nothing; the browser destroys a subtree. Gate 3 cannot see
///     it, because gate 3 only ever feeds the applier batches the differ made.
///
/// What would remove it: a kind check inside `Applier.kid`, refusing with the
/// node's kind in the message — and the SAME refusal in `latte.js`, or the two
/// halves disagree in the other direction. That is a wire-contract change and
/// belongs to whoever owns both halves, so this section states the behaviour
/// exactly and W5 can decide. Until then, a change to it is a diff here.
fn edits_the_applier_takes_silently(r: Report) {
    io.println("== 2 what the applier takes without a fault")
    let start: string = applier_state(seeded())

    var names: List<string> = []
    var bodies: List<fn(Batch)> = []
    // What each one actually does, recorded rather than argued. An empty
    // entry would mean nobody looked.
    var wants: List<string> = []

    names.push("set_text at an element node")
    wants.push("<div id=\"root\">head<p class=\"row\">one</p>tail<em>raw</em></div> roots= 0 attrs=2 binds=1 sfaults=0")
    bodies.push(fn(batch: Batch) {
        at_component(batch, 0, [Edit.step_in(0), Edit.set_text(1, "wiped"), Edit.step_out])
    })
    // The sharp one: a `raw` node keeps `raw = true`, so `Applier.emit` writes
    // whatever `set_text` put there through `Frame.raw` — UNESCAPED. A DOM
    // applier setting `textContent` would escape the same bytes. So this is not
    // "does nothing"; it is the escaping context changing under the value.
    names.push("set_text at a markup node")
    wants.push("<div id=\"root\">head<p class=\"row\">one</p>tail<img src=x onerror=alert(1)></div> roots= 0 attrs=2 binds=1 sfaults=0")
    bodies.push(fn(batch: Batch) {
        at_component(batch, 0, [Edit.step_in(0), Edit.set_text(3, "<img src=x onerror=alert(1)>"), Edit.step_out])
    })
    names.push("set_markup at a text node")
    wants.push("<div id=\"root\">&lt;b&gt;x&lt;/b&gt;<p class=\"row\">one</p>tail<em>raw</em></div> roots= 0 attrs=2 binds=1 sfaults=0")
    bodies.push(fn(batch: Batch) {
        at_component(batch, 0, [Edit.step_in(0), Edit.set_markup(0, "<b>x</b>"),
                                Edit.step_out])
    })
    names.push("set_attr with the cursor on a text node")
    wants.push("<div id=\"root\">head<p class=\"row\">one</p>tail<em>raw</em></div> roots= 0 attrs=2 binds=1 sfaults=0")
    bodies.push(fn(batch: Batch) {
        at_component(batch, 0, [Edit.step_in(0), Edit.step_in(0),
                                Edit.set_attr(1, "class", "x"),
                                Edit.step_out, Edit.step_out])
    })
    names.push("set_handler with the cursor on a text node")
    wants.push("<div id=\"root\">head<p class=\"row\">one</p>tail<em>raw</em></div> roots= 0 attrs=2 binds=1 sfaults=0")
    bodies.push(fn(batch: Batch) {
        at_component(batch, 0, [Edit.step_in(0), Edit.step_in(0),
                                Edit.set_handler(1, "click", 99),
                                Edit.step_out, Edit.step_out])
    })
    names.push("remove_attr with the cursor on a text node")
    wants.push("<div id=\"root\">head<p class=\"row\">one</p>tail<em>raw</em></div> roots= 0 attrs=2 binds=1 sfaults=0")
    bodies.push(fn(batch: Batch) {
        at_component(batch, 0, [Edit.step_in(0), Edit.step_in(0),
                                Edit.set_attr(1, "class", "x"),
                                Edit.remove_attr(1, "class"),
                                Edit.step_out, Edit.step_out])
    })

    var index: int = 0
    for index < names.len() {
        let a: Applier = seeded()
        let batch: Batch = new Batch()
        bodies[index](batch)
        a.apply(batch)
        let after: string = applier_state(a)
        io.println("-- {names[index]}")
        io.println("   faults: {joined(a.faults)}")
        io.println("   after:  {after}")
        r.eq("{names[index]}: raises nothing", joined(a.faults), "")
        r.eq("{names[index]}: and this is what it did", after, wants[index])
        index += 1
    }

    // The mount is the one that would cost the most in a browser: `textContent`
    // on the element a component is mounted into removes everything the child
    // rendered, and the child's next update carries only what CHANGED, so the
    // page never recovers.
    let a: Applier = seeded()
    let mount: Batch = new Batch()
    mount.reference.push(Frame.child(6, "Badge", 3))
    mount.reference.push(Frame.text(0, "from the child"))
    at_component(mount, 0, [Edit.step_in(0), Edit.insert(4, 0), Edit.step_out])
    at_component(mount, 3, [Edit.insert(0, 1)])
    a.apply(mount)
    let mounted: string = applier_state(a)
    io.println("-- a mounted child, before")
    io.println("   after:  {mounted}")
    r.eq("the mount landed and raised nothing", joined(a.faults), "")

    let wipe: Batch = new Batch()
    at_component(wipe, 0, [Edit.step_in(0), Edit.set_text(4, "wiped"), Edit.step_out])
    a.apply(wipe)
    io.println("-- set_text at a mounted child")
    io.println("   faults: {joined(a.faults)}")
    io.println("   after:  {applier_state(a)}")
    r.eq("set_text at a mount raises nothing", joined(a.faults), "")
    r.eq("and the child's subtree is untouched here", applier_state(a), mounted)
    r.no("the seed is not what any of this produced", mounted == start)
}

// --------------------------------------- 3 every fault site in serialize.b

/// One report site in `serialize.b`. The trip fills a Builder — by rendering,
/// or by pushing frames straight onto `Builder.frames`, which is public and is
/// the only way to reach one of the four.
pub class SSite {
    pub site: string = ""
    pub name: string = ""
    pub trip: fn(Builder) = fn(b: Builder) {}
    /// The exact SERIALIZER faults, joined with " | ".
    pub want: string = ""
    /// The exact BUILDER faults beside them. Two of these sites are the second
    /// half of a builder refusal, and a case that asserted only one half would
    /// not show that the pair is what happens.
    pub builder_want: string = ""
    pub left: string = ""
    pub control: fn(Builder) = fn(b: Builder) {}
    pub accepted: string = ""

    pub fn init(site: string, name: string, trip: fn(Builder), want: string,
                builder_want: string, left: string, control: fn(Builder),
                accepted: string) {
        self.site = site
        self.name = name
        self.trip = trip
        self.want = want
        self.builder_want = builder_want
        self.left = left
        self.control = control
        self.accepted = accepted
    }
}

const S_NO_BUFFER: string = "one / no frame buffer for the T mounted at slot N"
const S_NOT_CHILD: string = "one / F is not a child position"
const S_VOID: string = "element / void element <T> was given children"
const S_RAW_TEXT: string = "content / WHAT inside <T> could close it"

fn serializer_sites() -> List<SSite> {
    var out: List<SSite> = []

    // -- a mount with no buffer -------------------------------------------
    //
    // This site is REACHABLE FROM AN ORDINARY RENDER, which is not obvious and
    // is the reason it is first. `fill_slot` writes the `child` frame on BOTH
    // paths, including the one where `mount` failed and nothing was ever
    // activated — and only `render_child` creates the buffer. So every mount
    // failure in builder.b produces a builder fault AND this serializer fault,
    // as a pair. Nothing asserted the second half before this case.
    out.push(new SSite(S_NO_BUFFER, "a-mount-whose-activation-failed",
        fn(b: Builder) {
            render_body(b, fn(inner: Builder) {
                inner.open(0, "div")
                inner.component<NeedsSeed>(1, fn(c: NeedsSeed) {})
                inner.close()
            })
        },
        "no frame buffer for the NeedsSeed mounted at slot 1",
        "0: cannot activate NeedsSeed: wrong reflected argument count",
        "<div></div>",
        fn(b: Builder) {
            render_body(b, fn(inner: Builder) {
                inner.open(0, "div")
                inner.component<Badge>(1, fn(c: Badge) {})
                inner.close()
            })
        }, "<div><span>badge</span></div>"))

    out.push(new SSite(S_NO_BUFFER, "a-child-frame-with-no-buffer-at-all",
        fn(b: Builder) { b.frames.push(Frame.child(0, "Ghost", 4)) },
        "no frame buffer for the Ghost mounted at slot 4", "", "",
        // The same frame WITH its buffer. Without this the case reads as
        // "a hand-built child frame is always refused".
        fn(b: Builder) {
            b.frames.push(Frame.child(0, "Ghost", 4))
            let child: Builder = new Builder()
            child.frames.push(Frame.text(0, "ghost body"))
            b.nested[4] = child
        }, "ghost body"))

    // -- an attribute-run frame in a child position -----------------------
    //
    // SWALLOWED UPSTREAM by an ordinary render, and this is the shape RULES.md
    // is about. Every one of the six frames below is written by a Builder
    // method that first calls `take_attribute_slot`, which refuses with "is
    // outside an element's attribute run" and DROPS the frame — so no render
    // can put one here, and `Applier.emit` writes them only immediately after
    // an `open`. The site guards a hand-assembled frame list, which is what
    // `Builder.frames` being public makes possible, and that is how it is
    // reached here. `swallowed_upstream` below asserts the upstream refusal so
    // the day it stops swallowing, this stops being the whole story.
    out.push(new SSite(S_NOT_CHILD, "an-attribute-frame-in-a-child-position",
        fn(b: Builder) { b.frames.push(Frame.attribute(3, "class", "x")) },
        "3 attr class=x is not a child position", "", "",
        fn(b: Builder) {
            b.frames.push(Frame.open(0, "div"))
            b.frames.push(Frame.attribute(3, "class", "x"))
            b.frames.push(Frame.close)
        }, "<div class=\"x\"></div>"))

    out.push(new SSite(S_NOT_CHILD, "a-flag-frame-in-a-child-position",
        fn(b: Builder) { b.frames.push(Frame.flag(3, "hidden", true)) },
        "3 flag hidden=true is not a child position", "", "",
        fn(b: Builder) {
            b.frames.push(Frame.open(0, "div"))
            b.frames.push(Frame.flag(3, "hidden", true))
            b.frames.push(Frame.close)
        }, "<div hidden=\"\"></div>"))

    out.push(new SSite(S_NOT_CHILD, "a-splat-marker-in-a-child-position",
        fn(b: Builder) { b.frames.push(Frame.splat(3, 2)) },
        "3 splat 2 is not a child position", "", "",
        fn(b: Builder) {
            b.frames.push(Frame.open(0, "div"))
            b.frames.push(Frame.splat(3, 1))
            b.frames.push(Frame.attribute(3, "data-a", "1"))
            b.frames.push(Frame.close)
        }, "<div data-a=\"1\"></div>"))

    out.push(new SSite(S_NOT_CHILD, "a-handler-frame-in-a-child-position",
        fn(b: Builder) { b.frames.push(Frame.handler(3, "click", 8)) },
        "3 on:click -> 8 is not a child position", "", "",
        // A handler writes no HTML, so the control's acceptance is asserted on
        // the frame count rather than on the page: `<div></div>` looks exactly
        // the same whether the frame landed or was dropped.
        fn(b: Builder) {
            b.frames.push(Frame.open(0, "div"))
            b.frames.push(Frame.handler(3, "click", 8))
            b.frames.push(Frame.close)
        }, "<div></div>"))

    out.push(new SSite(S_NOT_CHILD, "a-ref-frame-in-a-child-position",
        fn(b: Builder) { b.frames.push(Frame.reference(3)) },
        "3 ref is not a child position", "", "",
        fn(b: Builder) {
            b.frames.push(Frame.open(0, "div"))
            b.frames.push(Frame.reference(3))
            b.frames.push(Frame.close)
        }, "<div></div>"))

    out.push(new SSite(S_NOT_CHILD, "a-preserve-frame-in-a-child-position",
        fn(b: Builder) { b.frames.push(Frame.preserve(3)) },
        "3 preserve is not a child position", "", "",
        fn(b: Builder) {
            b.frames.push(Frame.open(0, "div"))
            b.frames.push(Frame.preserve(3))
            b.frames.push(Frame.close)
        }, "<div></div>"))

    // -- a void element with children -------------------------------------
    out.push(new SSite(S_VOID, "a-void-element-given-text",
        fn(b: Builder) {
            render_body(b, fn(inner: Builder) {
                inner.open(0, "br")
                inner.text(1, "inside a void element")
                inner.close()
            })
        },
        "void element <br> was given children", "", "<br>",
        // Attributes are NOT children: the scan starts past the attribute run,
        // and a rule that started at the open frame would refuse this.
        fn(b: Builder) {
            render_body(b, fn(inner: Builder) {
                inner.open(0, "br")
                inner.attr(1, "class", "rule")
                inner.close()
            })
        }, "<br class=\"rule\">"))

    out.push(new SSite(S_VOID, "a-void-element-given-an-element",
        fn(b: Builder) {
            render_body(b, fn(inner: Builder) {
                inner.open(0, "img")
                inner.attr(1, "src", "/a.png")
                inner.open(2, "span")
                inner.text(0, "x")
                inner.close()
                inner.close()
            })
        },
        "void element <img> was given children", "", "<img src=\"/a.png\">",
        fn(b: Builder) {
            render_body(b, fn(inner: Builder) {
                inner.open(0, "img")
                inner.attr(1, "src", "/a.png")
                inner.close()
                inner.open(2, "span")
                inner.text(0, "x")
                inner.close()
            })
        }, "<img src=\"/a.png\"><span>x</span>"))

    out.push(new SSite(S_VOID, "a-void-element-given-a-transparent-container",
        fn(b: Builder) {
            render_body(b, fn(inner: Builder) {
                inner.open(0, "input")
                inner.fragment(1, fn(slot: Builder) { slot.text(0, "slotted") })
                inner.close()
            })
        },
        "void element <input> was given children", "", "<input>",
        fn(b: Builder) {
            render_body(b, fn(inner: Builder) {
                inner.open(0, "input")
                inner.close()
                inner.fragment(1, fn(slot: Builder) { slot.text(0, "slotted") })
            })
        }, "<input>slotted"))

    // -- content that could close a raw-text element ----------------------
    //
    // Two rules in one site — a closing tag for the element itself, and a
    // comment opener — and three callers, because `what` is the caller's name.
    out.push(new SSite(S_RAW_TEXT, "text-that-closes-its-script",
        fn(b: Builder) {
            render_body(b, fn(inner: Builder) {
                inner.open(0, "script")
                inner.text(1, "var a = \"</script>\"")
                inner.close()
            })
        },
        "text inside <script> could close it", "", "<script></script>",
        // `<` and `/` are not escaped inside a script — they cannot be — so
        // the control has to carry both and still be accepted, or the rule
        // reads as "a script may not contain a less-than sign".
        fn(b: Builder) {
            render_body(b, fn(inner: Builder) {
                inner.open(0, "script")
                inner.text(1, "if (a < b && c > d) go(\"</p>\")")
                inner.close()
            })
        }, "<script>if (a < b && c > d) go(\"</p>\")</script>"))

    out.push(new SSite(S_RAW_TEXT, "raw-that-closes-its-script",
        fn(b: Builder) {
            render_body(b, fn(inner: Builder) {
                inner.open(0, "script")
                inner.raw(1, "</SCRIPT >")
                inner.close()
            })
        },
        "raw inside <script> could close it", "", "<script></script>",
        fn(b: Builder) {
            render_body(b, fn(inner: Builder) {
                inner.open(0, "script")
                inner.raw(1, "var a = 1")
                inner.close()
            })
        }, "<script>var a = 1</script>"))

    out.push(new SSite(S_RAW_TEXT, "a-constant-that-closes-its-style",
        fn(b: Builder) {
            render_body(b, fn(inner: Builder) {
                inner.open(0, "style")
                inner.constant(1, "</style>")
                inner.close()
            })
        },
        "constant inside <style> could close it", "", "<style></style>",
        fn(b: Builder) {
            render_body(b, fn(inner: Builder) {
                inner.open(0, "style")
                inner.constant(1, r"p { color: red }")
                inner.close()
            })
        }, r"<style>p { color: red }</style>"))

    out.push(new SSite(S_RAW_TEXT, "a-comment-opener-inside-a-script",
        fn(b: Builder) {
            render_body(b, fn(inner: Builder) {
                inner.open(0, "script")
                inner.text(1, "<!-- hide from old browsers")
                inner.close()
            })
        },
        "text inside <script> could close it", "", "<script></script>",
        fn(b: Builder) {
            render_body(b, fn(inner: Builder) {
                inner.open(0, "script")
                inner.text(1, "// -- not a comment opener --")
                inner.close()
            })
        }, "<script>// -- not a comment opener --</script>"))

    out.push(new SSite(S_RAW_TEXT, "an-uppercase-script-tag-still-refuses",
        fn(b: Builder) {
            render_body(b, fn(inner: Builder) {
                inner.open(0, "SCRIPT")
                inner.text(1, "</script>")
                inner.close()
            })
        },
        "text inside <script> could close it", "", "<SCRIPT></SCRIPT>",
        // RCDATA is the near miss: `<textarea>` also holds text a tag could
        // end, and it is ESCAPED rather than refused. A control here is what
        // keeps "raw text" from spreading to every text-holding element.
        fn(b: Builder) {
            render_body(b, fn(inner: Builder) {
                inner.open(0, "textarea")
                inner.text(1, "</textarea>")
                inner.close()
            })
        }, "<textarea>&lt;/textarea&gt;</textarea>"))

    return move out
}

fn serializer_fault_sites(r: Report) {
    io.println("== 3 every fault site in serialize.b")
    var reached: Map<string, int> = {}
    for probe: SSite in serializer_sites() {
        let b: Builder = new Builder()
        probe.trip(b)
        let writer: Serializer = new Serializer()
        let left: string = writer.page(b)

        let good: Builder = new Builder()
        probe.control(good)
        let control_writer: Serializer = new Serializer()
        let accepted: string = control_writer.page(good)

        io.println("-- {probe.name}")
        io.println("   site:    {probe.site}")
        io.println("   faults:  {joined(writer.faults)}")
        io.println("   builder: {joined(b.all_faults())}")
        io.println("   left:    {left}")
        io.println("   control: {accepted}")

        r.eq("{probe.name}: the exact serializer faults", joined(writer.faults), probe.want)
        r.eq("{probe.name}: the builder faults beside them",
            joined(b.all_faults()), probe.builder_want)
        r.eq("{probe.name}: what the refusal left", left, probe.left)
        r.eq("{probe.name}: the control raises nothing",
            joined(control_writer.faults), "")
        r.eq("{probe.name}: the control raises no builder fault either",
            joined(good.all_faults()), "")
        r.eq("{probe.name}: and the control renders", accepted, probe.accepted)

        match reached.get(probe.site) {
            some(n) => { reached[probe.site] = n + 1 }
            none => { reached[probe.site] = 1 }
        }
    }

    var names: List<string> = reached.keys()
    names.sort()
    io.println("-- the sites in serialize.b, and how many shapes reach each")
    for name: string in names {
        match reached.get(name) {
            some(n) => { io.println("   {n}x {name}") }
            none => {}
        }
    }
    r.eqi("every fault site in serialize.b has a case", names.len(), 4)
}

// ------------------------------------------------------------------ § 4

/// The evidence behind the comment in `serialize.b` that says its
/// "is not a child position" site has no producer in this repo.
///
/// Every Builder method that writes an attribute-run frame goes through
/// `take_attribute_slot` first, which refuses when the run is closed and
/// returns without writing. So the coarser builder rule stands in front of the
/// finer serializer one, exactly the way `xlink:href`'s namespace rule stood
/// in front of its scheme check in W2's lane — and the day one of these six
/// stops being refused upstream, this section goes red rather than the site
/// quietly becoming reachable.
fn swallowed_upstream(r: Report) {
    io.println("== 4 the builder refuses in front of \"is not a child position\"")
    let b: Builder = new Builder()
    render_body(b, fn(inner: Builder) {
        inner.open(0, "div")
        inner.text(1, "a child closes the attribute run")
        inner.attr(2, "class", "x")
        inner.flag(3, "hidden", true)
        var extra: Map<string, string> = {}
        extra["data-a"] = "1"
        inner.attrs(4, extra)
        inner.on_click(5, fn(e: MouseEvent) {})
        inner.reference(6, fn(handle: Reference) {})
        inner.preserve(7)
        inner.close()
    })
    let writer: Serializer = new Serializer()
    let html: string = writer.page(b)
    for fault: string in b.all_faults() { io.println("   builder: {fault}") }
    io.println("   html:    {html}")
    io.println("   frames:  {b.frames.len()}")

    r.eq("all six frames are refused by the builder", joined(b.all_faults()),
        "0: attribute 2:\"class\" is outside an element's attribute run | 0: flag 3:\"hidden\" is outside an element's attribute run | 0: attrs 4:\"\" is outside an element's attribute run | 0: on:click 5:\"\" is outside an element's attribute run | 0: ref 6:\"\" is outside an element's attribute run | 0: preserve 7:\"\" is outside an element's attribute run")
    r.eqi("and none of them was written: open, text, close and nothing else",
        b.frames.len(), 3)
    r.eq("so the serializer never sees one", joined(writer.faults), "")
    r.eq("and the page is what the legal half of the body asked for", html,
        "<div>a child closes the attribute run</div>")
}

fn main() {
    let r: Report = new Report()
    apply_fault_sites(r)
    edits_the_applier_takes_silently(r)
    serializer_fault_sites(r)
    swallowed_upstream(r)
    io.println("== summary")
    io.println("checks: {r.checks}, failed: {r.bad}")
}
