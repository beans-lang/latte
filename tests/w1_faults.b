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
// `apply.b`'s 14 sites arrived here asserted EMPTY by the 10,000-case sweep in
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
        Frame, Frames, MouseEvent, Node, Reference, Serializer,
        SPAN_TEXT} from latte

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

// One subtree per NODE KIND, each staged at offset 0. The kind cases in § 1
// are all "the same edit at the same index with a node of the right kind
// there", so what varies between a trip and its control is which of these was
// staged — and the kind rule's whole subject is the difference between them.

fn stage_b_with_class(pool: Frames) {
    pool.push(Frame.open(9, "b"))
    pool.push(Frame.attribute(1, "class", "x"))
    pool.push(Frame.text(0, "new"))
    pool.push(Frame.close)
}

fn stage_b_with_handler(pool: Frames) {
    pool.push(Frame.open(9, "b"))
    pool.push(Frame.handler(2, "click", 7))
    pool.push(Frame.text(0, "new"))
    pool.push(Frame.close)
}

/// A text node — the kind `set_text` needs.
fn stage_text(pool: Frames) { pool.push(Frame.text(9, "INS")) }

/// An element with TWO children, so `relocate` has something to reorder.
fn stage_b_two_kids(pool: Frames) {
    pool.push(Frame.open(9, "b"))
    pool.push(Frame.text(0, "one"))
    pool.push(Frame.text(1, "two"))
    pool.push(Frame.close)
}

/// A markup node — the kind `set_markup` needs. `constant` rather than `raw`
/// so the control does not also depend on the author-bypass flag.
fn stage_markup(pool: Frames) { pool.push(Frame.constant(9, "<i>mk</i>")) }

fn stage_region(pool: Frames) {
    pool.push(Frame.region_open(9, "k"))
    pool.push(Frame.text(0, "row"))
    pool.push(Frame.region_close)
}

fn stage_fragment(pool: Frames) {
    pool.push(Frame.fragment_open(9))
    pool.push(Frame.text(0, "slot"))
    pool.push(Frame.fragment_close)
}

fn stage_boundary(pool: Frames) {
    pool.push(Frame.boundary_open(9, false))
    pool.push(Frame.text(0, "body"))
    pool.push(Frame.boundary_close)
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
const A_KIND_AT: string = "wrong_kind_at / OP N needs a WANT node, not a GOT node"
const A_KIND: string = "wrong_kind / OP needs a WANT node, not a GOT node"

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
        // The boundary: `index >= len` refuses, so the SAME index must be
        // accepted the moment a child is there. It appends `<b>new</b>` first
        // and steps into index 4 — legal now because `len` grew, not because
        // the number changed, which is a tighter neighbour than `len - 1`
        // would have been. It also has to be: the div's last child is a markup
        // node and the kind rule refuses a descent into one, so the old
        // `step_in(3)` control is no longer legal at all.
        //
        // The edit inside is what proves the descent was real. A swallowed
        // step_in would leave `set_text(0, …)` on the div's own child 0 and
        // rewrite "head" instead, which is a different tree.
        fn(batch: Batch) {
            stage_b(batch.reference)
            at_component(batch, 0, [Edit.step_in(0), Edit.insert(4, 0),
                                    Edit.step_in(4), Edit.set_text(0, "NEW"),
                                    Edit.step_out, Edit.step_out])
        }, "<div id=\"root\">head<p class=\"row\">one</p>tail<em>raw</em><b>NEW</b></div> roots= 0 attrs=2 binds=1 sfaults=0"))

    out.push(new ASite(A_STEP_IN, "step-in-a-negative-index",
        fn(batch: Batch) {
            at_component(batch, 0, [Edit.step_in(0), Edit.step_in(-1),
                                    Edit.step_out, Edit.step_out])
        },
        "component 0: step_in -1 of 4", "<div id=\"root\">head<p class=\"row\">one</p>tail<em>raw</em></div> roots= 0 attrs=2 binds=1 sfaults=0",
        // `index < 0` refuses, so index 0 — the smallest legal one — must be
        // accepted. It is a text node in the seed and the kind rule refuses a
        // descent into one, so the control puts a container there first and
        // steps into the same index. A swallowed step_in leaves
        // `set_text(0, …)` on the `<b>` element and raises the kind fault this
        // control asserts is absent, so the descent cannot be faked.
        fn(batch: Batch) {
            stage_b(batch.reference)
            at_component(batch, 0, [Edit.step_in(0), Edit.insert(0, 0),
                                    Edit.step_in(0), Edit.set_text(0, "NEW"),
                                    Edit.step_out, Edit.step_out])
        }, "<div id=\"root\"><b>NEW</b>head<p class=\"row\">one</p>tail<em>raw</em></div> roots= 0 attrs=2 binds=1 sfaults=0"))

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

    // Two LEGAL descents, div then `<p>`. `step_in(0)` twice would land on the
    // div's text child, which the kind rule refuses, and the case would then
    // assert two faults and stop isolating this one.
    out.push(new ASite(A_DEEP, "the-stream-ended-two-levels-deep",
        fn(batch: Batch) {
            at_component(batch, 0, [Edit.step_in(0), Edit.step_in(1)])
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

    // -- wrong_kind_at, reached by set_text, set_markup and step_in --------
    //
    // THE KIND RULE, for the three edits that name a CHILD. Every control here
    // is the same edit at the SAME index with a node of the right kind put
    // there first, so the only thing that moved between the refusal and the
    // acceptance is the kind — which is the rule being measured. A control at
    // a different index would also be testing the index.
    out.push(new ASite(A_KIND_AT, "set-text-at-an-element",
        fn(batch: Batch) {
            at_component(batch, 0, [Edit.step_in(0), Edit.set_text(1, "wiped"),
                                    Edit.step_out])
        },
        "component 0: set_text 1 needs a text node, not a element node",
        "<div id=\"root\">head<p class=\"row\">one</p>tail<em>raw</em></div> roots= 0 attrs=2 binds=1 sfaults=0",
        fn(batch: Batch) {
            stage_text(batch.reference)
            at_component(batch, 0, [Edit.step_in(0), Edit.insert(1, 0),
                                    Edit.set_text(1, "INS"), Edit.step_out])
        }, "<div id=\"root\">headINS<p class=\"row\">one</p>tail<em>raw</em></div> roots= 0 attrs=2 binds=1 sfaults=0"))

    // The sharp one, and the reason this rule exists. A `raw` markup node
    // keeps `raw = true`, so before the check `Applier.emit` wrote whatever
    // `set_text` had put there back out through `Frame.raw` — UNESCAPED, and
    // `<img src=x onerror=alert(1)>` landed in the page with nothing raised.
    // The control sends the SAME bytes to the SAME index with a text node
    // there, and they come out escaped: the refusal is about the escaping
    // context changing under the value, not about a no-op.
    out.push(new ASite(A_KIND_AT, "set-text-at-a-markup-node",
        fn(batch: Batch) {
            at_component(batch, 0, [Edit.step_in(0),
                                    Edit.set_text(3, "<img src=x onerror=alert(1)>"),
                                    Edit.step_out])
        },
        "component 0: set_text 3 needs a text node, not a markup node",
        "<div id=\"root\">head<p class=\"row\">one</p>tail<em>raw</em></div> roots= 0 attrs=2 binds=1 sfaults=0",
        fn(batch: Batch) {
            stage_text(batch.reference)
            at_component(batch, 0, [Edit.step_in(0), Edit.insert(3, 0),
                                    Edit.set_text(3, "<img src=x onerror=alert(1)>"),
                                    Edit.step_out])
        }, "<div id=\"root\">head<p class=\"row\">one</p>tail&lt;img src=x onerror=alert(1)&gt;<em>raw</em></div> roots= 0 attrs=2 binds=1 sfaults=0"))

    // The one that would cost the most in a browser: `textContent` on the
    // element a component is mounted into removes everything that child
    // rendered, and the child's next update carries only what CHANGED, so the
    // page never comes back. Two updates in ONE batch — the applier runs them
    // in order, so the second addresses the mount the first put there.
    out.push(new ASite(A_KIND_AT, "set-text-at-a-mounted-child",
        fn(batch: Batch) {
            batch.reference.push(Frame.child(6, "Badge", 3))
            at_component(batch, 0, [Edit.step_in(0), Edit.insert(4, 0), Edit.step_out])
            at_component(batch, 0, [Edit.step_in(0), Edit.set_text(4, "wiped"),
                                    Edit.step_out])
        },
        "component 0: set_text 4 needs a text node, not a mount node",
        "<div id=\"root\">head<p class=\"row\">one</p>tail<em>raw</em></div> roots= 0 3 attrs=2 binds=1 sfaults=0",
        fn(batch: Batch) {
            stage_text(batch.reference)
            at_component(batch, 0, [Edit.step_in(0), Edit.insert(4, 0),
                                    Edit.set_text(4, "INS"), Edit.step_out])
        }, "<div id=\"root\">head<p class=\"row\">one</p>tail<em>raw</em>INS</div> roots= 0 attrs=2 binds=1 sfaults=0"))

    out.push(new ASite(A_KIND_AT, "set-markup-at-a-text-node",
        fn(batch: Batch) {
            at_component(batch, 0, [Edit.step_in(0), Edit.set_markup(0, "<b>x</b>"),
                                    Edit.step_out])
        },
        "component 0: set_markup 0 needs a markup node, not a text node",
        "<div id=\"root\">head<p class=\"row\">one</p>tail<em>raw</em></div> roots= 0 attrs=2 binds=1 sfaults=0",
        // The mirror of the case above: the same bytes at a markup node are
        // written verbatim. Before the rule this landed on the text node and
        // came out escaped — accepted, and silently meaning something else.
        fn(batch: Batch) {
            stage_markup(batch.reference)
            at_component(batch, 0, [Edit.step_in(0), Edit.insert(0, 0),
                                    Edit.set_markup(0, "<b>x</b>"), Edit.step_out])
        }, "<div id=\"root\"><b>x</b>head<p class=\"row\">one</p>tail<em>raw</em></div> roots= 0 attrs=2 binds=1 sfaults=0"))

    out.push(new ASite(A_KIND_AT, "set-markup-at-an-element",
        fn(batch: Batch) {
            at_component(batch, 0, [Edit.step_in(0), Edit.set_markup(1, "<b>x</b>"),
                                    Edit.step_out])
        },
        "component 0: set_markup 1 needs a markup node, not a element node",
        "<div id=\"root\">head<p class=\"row\">one</p>tail<em>raw</em></div> roots= 0 attrs=2 binds=1 sfaults=0",
        fn(batch: Batch) {
            stage_markup(batch.reference)
            at_component(batch, 0, [Edit.step_in(0), Edit.insert(1, 0),
                                    Edit.set_markup(1, "<b>x</b>"), Edit.step_out])
        }, "<div id=\"root\">head<b>x</b><p class=\"row\">one</p>tail<em>raw</em></div> roots= 0 attrs=2 binds=1 sfaults=0"))

    // `step_in` refuses the descent and pushes the same placeholder the
    // out-of-range case does, so the matching `step_out` still balances.
    //
    // Both trips carry an edit BELOW the refused descent, and the second fault
    // — `set_text 0 of 0` — is the positive evidence that the placeholder is
    // what caught it: an empty node has no child 0. Drop the placeholder and
    // the `step_out` pops the DIV instead, so `set_text(0, …)` rewrites the
    // div's "head" to "wiped", the html changes, the second fault becomes
    // "step_out at the root", and both of those are asserted here. One
    // refused descent must not reinterpret the rest of the stream.
    out.push(new ASite(A_KIND_AT, "step-into-a-text-node",
        fn(batch: Batch) {
            at_component(batch, 0, [Edit.step_in(0), Edit.step_in(0),
                                    Edit.set_text(0, "wiped"),
                                    Edit.step_out, Edit.step_out])
        },
        "component 0: step_in 0 needs a container node, not a text node | component 0: set_text 0 of 0",
        "<div id=\"root\">head<p class=\"row\">one</p>tail<em>raw</em></div> roots= 0 attrs=2 binds=1 sfaults=0",
        fn(batch: Batch) {
            stage_b(batch.reference)
            at_component(batch, 0, [Edit.step_in(0), Edit.insert(0, 0),
                                    Edit.step_in(0), Edit.set_text(0, "NEW"),
                                    Edit.step_out, Edit.step_out])
        }, "<div id=\"root\"><b>NEW</b>head<p class=\"row\">one</p>tail<em>raw</em></div> roots= 0 attrs=2 binds=1 sfaults=0"))

    out.push(new ASite(A_KIND_AT, "step-into-a-markup-node",
        fn(batch: Batch) {
            at_component(batch, 0, [Edit.step_in(0), Edit.step_in(3),
                                    Edit.set_text(0, "wiped"),
                                    Edit.step_out, Edit.step_out])
        },
        "component 0: step_in 3 needs a container node, not a markup node | component 0: set_text 0 of 0",
        "<div id=\"root\">head<p class=\"row\">one</p>tail<em>raw</em></div> roots= 0 attrs=2 binds=1 sfaults=0",
        fn(batch: Batch) {
            stage_b(batch.reference)
            at_component(batch, 0, [Edit.step_in(0), Edit.insert(3, 0),
                                    Edit.step_in(3), Edit.set_text(0, "NEW"),
                                    Edit.step_out, Edit.step_out])
        }, "<div id=\"root\">head<p class=\"row\">one</p>tail<b>NEW</b><em>raw</em></div> roots= 0 attrs=2 binds=1 sfaults=0"))

    // -- wrong_kind, reached by the five attribute and handler edits -------
    //
    // These act on the CURRENT node, which has to be an element: `Applier.emit`
    // writes an attribute run for `SPAN_ELEMENT` and for nothing else, so a
    // slot stored anywhere else was written and then dropped. One shape per
    // op, and one per container kind that is not an element — a mount, a
    // region, a fragment and a boundary — because the message names the kind
    // and a site that answered "mount" for a region would look covered.
    //
    // The first is the shape a stream reaches with no `step_in` at all: the
    // cursor at the top of a component's edits is that component's root, and a
    // root is always a mount.
    out.push(new ASite(A_KIND, "set-attr-at-the-component-root",
        fn(batch: Batch) {
            at_component(batch, 0, [Edit.set_attr(1, "class", "x")])
        },
        "component 0: set_attr needs a element node, not a mount node",
        "<div id=\"root\">head<p class=\"row\">one</p>tail<em>raw</em></div> roots= 0 attrs=2 binds=1 sfaults=0",
        fn(batch: Batch) {
            at_component(batch, 0, [Edit.step_in(0), Edit.set_attr(9, "lang", "en"),
                                    Edit.step_out])
        }, "<div id=\"root\" lang=\"en\">head<p class=\"row\">one</p>tail<em>raw</em></div> roots= 0 attrs=3 binds=1 sfaults=0"))

    out.push(new ASite(A_KIND, "set-flag-with-the-cursor-on-a-region",
        fn(batch: Batch) {
            stage_region(batch.reference)
            at_component(batch, 0, [Edit.step_in(0), Edit.insert(4, 0),
                                    Edit.step_in(4), Edit.set_flag(1, "hidden", true),
                                    Edit.step_out, Edit.step_out])
        },
        "component 0: set_flag needs a element node, not a region node",
        "<div id=\"root\">head<p class=\"row\">one</p>tail<em>raw</em>row</div> roots= 0 attrs=2 binds=1 sfaults=0",
        // The same edit at the same place with an ELEMENT there instead of a
        // region: only the kind moved.
        fn(batch: Batch) {
            stage_b(batch.reference)
            at_component(batch, 0, [Edit.step_in(0), Edit.insert(4, 0),
                                    Edit.step_in(4), Edit.set_flag(1, "hidden", true),
                                    Edit.step_out, Edit.step_out])
        }, "<div id=\"root\">head<p class=\"row\">one</p>tail<em>raw</em><b hidden=\"\">new</b></div> roots= 0 attrs=3 binds=1 sfaults=0"))

    out.push(new ASite(A_KIND, "remove-attr-with-the-cursor-on-a-fragment",
        fn(batch: Batch) {
            stage_fragment(batch.reference)
            at_component(batch, 0, [Edit.step_in(0), Edit.insert(4, 0),
                                    Edit.step_in(4), Edit.remove_attr(1, "class"),
                                    Edit.step_out, Edit.step_out])
        },
        "component 0: remove_attr needs a element node, not a fragment node",
        "<div id=\"root\">head<p class=\"row\">one</p>tail<em>raw</em>slot</div> roots= 0 attrs=2 binds=1 sfaults=0",
        // The control removes a slot that IS there. `remove_attr` on an
        // element with no such slot raises the OTHER refusal, so a control
        // that skipped the attribute would fail for a second reason and prove
        // nothing about this one.
        fn(batch: Batch) {
            stage_b_with_class(batch.reference)
            at_component(batch, 0, [Edit.step_in(0), Edit.insert(4, 0),
                                    Edit.step_in(4), Edit.remove_attr(1, "class"),
                                    Edit.step_out, Edit.step_out])
        }, "<div id=\"root\">head<p class=\"row\">one</p>tail<em>raw</em><b>new</b></div> roots= 0 attrs=2 binds=1 sfaults=0"))

    out.push(new ASite(A_KIND, "set-handler-with-the-cursor-on-a-boundary",
        fn(batch: Batch) {
            stage_boundary(batch.reference)
            at_component(batch, 0, [Edit.step_in(0), Edit.insert(4, 0),
                                    Edit.step_in(4), Edit.set_handler(2, "click", 41),
                                    Edit.step_out, Edit.step_out])
        },
        "component 0: set_handler needs a element node, not a boundary node",
        "<div id=\"root\">head<p class=\"row\">one</p>tail<em>raw</em>body</div> roots= 0 attrs=2 binds=1 sfaults=0",
        // A handler writes no HTML, so `binds=` is the only thing that can
        // tell the control's acceptance from a quiet discard.
        fn(batch: Batch) {
            stage_b(batch.reference)
            at_component(batch, 0, [Edit.step_in(0), Edit.insert(4, 0),
                                    Edit.step_in(4), Edit.set_handler(2, "click", 41),
                                    Edit.step_out, Edit.step_out])
        }, "<div id=\"root\">head<p class=\"row\">one</p>tail<em>raw</em><b>new</b></div> roots= 0 attrs=2 binds=2 sfaults=0"))

    out.push(new ASite(A_KIND, "remove-handler-with-the-cursor-on-a-mount",
        fn(batch: Batch) {
            batch.reference.push(Frame.child(6, "Badge", 3))
            at_component(batch, 0, [Edit.step_in(0), Edit.insert(4, 0),
                                    Edit.step_in(4), Edit.remove_handler(2, "click"),
                                    Edit.step_out, Edit.step_out])
        },
        "component 0: remove_handler needs a element node, not a mount node",
        "<div id=\"root\">head<p class=\"row\">one</p>tail<em>raw</em></div> roots= 0 3 attrs=2 binds=1 sfaults=0",
        fn(batch: Batch) {
            stage_b_with_handler(batch.reference)
            at_component(batch, 0, [Edit.step_in(0), Edit.insert(4, 0),
                                    Edit.step_in(4), Edit.remove_handler(2, "click"),
                                    Edit.step_out, Edit.step_out])
        }, "<div id=\"root\">head<p class=\"row\">one</p>tail<em>raw</em><b>new</b></div> roots= 0 attrs=2 binds=1 sfaults=0"))

    // The three that reach `WANT_CONTAINER` on the cursor from an ORDINARY
    // edit stream, and they exist because a refused `step_in` descends into
    // the leaf rather than a placeholder. A fresh node is a container, so
    // substituting one would make the cursor a container on every reachable
    // path and these three refusals would be dead code — the shape RULES.md
    // calls "the refusal that never runs", built by hand.
    //
    // TWO faults each: the descent, and the edit that had no business below
    // it. Each control is the same pair of edits with a CONTAINER at the index
    // the descent was refused at, so only the kind moved.
    out.push(new ASite(A_KIND, "insert-with-the-cursor-on-a-text-node",
        fn(batch: Batch) {
            stage_text(batch.reference)
            at_component(batch, 0, [Edit.step_in(0), Edit.step_in(0),
                                    Edit.insert(0, 0),
                                    Edit.step_out, Edit.step_out])
        },
        "component 0: step_in 0 needs a container node, not a text node | component 0: insert needs a container node, not a text node",
        "<div id=\"root\">head<p class=\"row\">one</p>tail<em>raw</em></div> roots= 0 attrs=2 binds=1 sfaults=0",
        fn(batch: Batch) {
            stage_b(batch.reference)
            stage_text(batch.reference)
            at_component(batch, 0, [Edit.step_in(0), Edit.insert(0, 0),
                                    Edit.step_in(0), Edit.insert(0, 3),
                                    Edit.step_out, Edit.step_out])
        }, "<div id=\"root\"><b>INSnew</b>head<p class=\"row\">one</p>tail<em>raw</em></div> roots= 0 attrs=2 binds=1 sfaults=0"))

    out.push(new ASite(A_KIND, "remove-with-the-cursor-on-a-text-node",
        fn(batch: Batch) {
            at_component(batch, 0, [Edit.step_in(0), Edit.step_in(2),
                                    Edit.remove(0),
                                    Edit.step_out, Edit.step_out])
        },
        "component 0: step_in 2 needs a container node, not a text node | component 0: remove needs a container node, not a text node",
        "<div id=\"root\">head<p class=\"row\">one</p>tail<em>raw</em></div> roots= 0 attrs=2 binds=1 sfaults=0",
        fn(batch: Batch) {
            stage_b(batch.reference)
            at_component(batch, 0, [Edit.step_in(0), Edit.insert(2, 0),
                                    Edit.step_in(2), Edit.remove(0),
                                    Edit.step_out, Edit.step_out])
        }, "<div id=\"root\">head<p class=\"row\">one</p><b></b>tail<em>raw</em></div> roots= 0 attrs=2 binds=1 sfaults=0"))

    out.push(new ASite(A_KIND, "relocate-with-the-cursor-on-a-markup-node",
        fn(batch: Batch) {
            at_component(batch, 0, [Edit.step_in(0), Edit.step_in(3),
                                    Edit.relocate(0, 1),
                                    Edit.step_out, Edit.step_out])
        },
        "component 0: step_in 3 needs a container node, not a markup node | component 0: relocate needs a container node, not a markup node",
        "<div id=\"root\">head<p class=\"row\">one</p>tail<em>raw</em></div> roots= 0 attrs=2 binds=1 sfaults=0",
        fn(batch: Batch) {
            stage_b_two_kids(batch.reference)
            at_component(batch, 0, [Edit.step_in(0), Edit.insert(3, 0),
                                    Edit.step_in(3), Edit.relocate(0, 1),
                                    Edit.step_out, Edit.step_out])
        }, "<div id=\"root\">head<p class=\"row\">one</p>tail<b>twoone</b><em>raw</em></div> roots= 0 attrs=2 binds=1 sfaults=0"))

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
    r.eqi("every fault site in apply.b has a case", names.len(), 14)
}

/// A planted root's shape. `applier_state` serializes component 0 and nothing
/// else, so a root planted at another id is invisible to it — and "the insert
/// was refused" and "the insert landed somewhere the html cannot show" read
/// identically without this.
fn root_shape(a: Applier, id: int) -> string {
    match a.roots.get(id) {
        some(node) => {
            var kids: string = ""
            for kid: Node in node.kids { kids = "{kids} {kid.html}" }
            return "kind={node.kind} kids={node.kids.len()}{kids}"
        }
        none => { return "no root" }
    }
}

/// THE KIND RULE, shape by shape — the seven edits this applier used to TAKE.
///
/// This section was the record of a divergence and is now the record of its
/// closing. `Applier.kid` checked the INDEX and never the KIND, so `set_text`
/// addressed at an element, a markup node or a mounted child was accepted
/// silently, `set_markup` addressed at a text node landed escaped, and an
/// attribute or handler edit with the cursor on a text node was stored on that
/// node and dropped again by `Applier.emit`. `latte.js` applies the same
/// stream to a real DOM, where `node.textContent = body` on an element WIPES
/// its children — two appliers, two answers to one batch, and gate 3 blind to
/// it because gate 3 only ever feeds the applier batches the differ made.
///
/// Every one of the seven is refused now, in both halves, with the same
/// sentence byte for byte (lanes/W5.md, THE APPLIER CONTRACT). What is pinned
/// here is the sentence and the state afterwards, and the state is the seed
/// every time — a refusal that reports and then does the thing anyway is not a
/// refusal.
///
/// The sharpest one is the second: `set_text` at a `raw` markup node rewrote
/// `node.html` while `node.raw` stayed true, so `Applier.emit` wrote the new
/// bytes back out through `Frame.raw` — UNESCAPED — and
/// `<img src=x onerror=alert(1)>` reached the page with nothing raised. The
/// expected html below is the seed, `<em>raw</em>` intact. The escaping
/// context changing under a value is what this rule is for; § 1's control for
/// the same shape sends those same bytes to a text node at the same index and
/// they come out escaped.
///
/// Three of the seven now answer with the `step_in` refusal rather than the
/// attribute one, and that is the rule working rather than a gap. The cursor
/// can only BE a text node if a `step_in` descended into one, and that descent
/// is the earlier refusal — RULES.md's "a coarser refusal standing in front of
/// a finer one", seen from the side where the coarser one is the correct
/// answer. The element rule is reached instead through the four container
/// kinds that are not elements, and § 1 carries a shape for each: a mount, a
/// region, a fragment and a boundary.
fn the_kind_rule(r: Report) {
    io.println("== 2 the kind rule, shape by shape")
    let start: string = applier_state(seeded())

    var names: List<string> = []
    var bodies: List<fn(Batch)> = []
    // The sentence each shape must produce, and the tree it must leave. Both
    // are asserted: a refusal that still rewrote the node would pass on the
    // first alone.
    var faults: List<string> = []
    var wants: List<string> = []

    let seed_state: string = "<div id=\"root\">head<p class=\"row\">one</p>tail<em>raw</em></div> roots= 0 attrs=2 binds=1 sfaults=0"

    names.push("set_text at an element node")
    faults.push("component 0: set_text 1 needs a text node, not a element node")
    wants.push(seed_state)
    bodies.push(fn(batch: Batch) {
        at_component(batch, 0, [Edit.step_in(0), Edit.set_text(1, "wiped"), Edit.step_out])
    })
    // The one that shipped an XSS. It is dead: the html below is the seed.
    names.push("set_text at a markup node")
    faults.push("component 0: set_text 3 needs a text node, not a markup node")
    wants.push(seed_state)
    bodies.push(fn(batch: Batch) {
        at_component(batch, 0, [Edit.step_in(0), Edit.set_text(3, "<img src=x onerror=alert(1)>"), Edit.step_out])
    })
    names.push("set_markup at a text node")
    faults.push("component 0: set_markup 0 needs a markup node, not a text node")
    wants.push(seed_state)
    bodies.push(fn(batch: Batch) {
        at_component(batch, 0, [Edit.step_in(0), Edit.set_markup(0, "<b>x</b>"),
                                Edit.step_out])
    })
    // The three that a `step_in` refusal now answers FIRST — and then answers
    // again, because the refused descent goes into the text node itself rather
    // than a placeholder. Two faults, not one, and the second is the attribute
    // rule these three were written for. Substituting a fresh node would make
    // the cursor a container on every path and the second fault would never
    // appear: the edit would land on a throwaway and be discarded in silence.
    // The batches are unchanged from when this section recorded them as
    // ACCEPTED; only the answers moved.
    names.push("set_attr with the cursor on a text node")
    faults.push("component 0: step_in 0 needs a container node, not a text node | component 0: set_attr needs a element node, not a text node")
    wants.push(seed_state)
    bodies.push(fn(batch: Batch) {
        at_component(batch, 0, [Edit.step_in(0), Edit.step_in(0),
                                Edit.set_attr(1, "class", "x"),
                                Edit.step_out, Edit.step_out])
    })
    names.push("set_handler with the cursor on a text node")
    faults.push("component 0: step_in 0 needs a container node, not a text node | component 0: set_handler needs a element node, not a text node")
    wants.push(seed_state)
    bodies.push(fn(batch: Batch) {
        at_component(batch, 0, [Edit.step_in(0), Edit.step_in(0),
                                Edit.set_handler(1, "click", 99),
                                Edit.step_out, Edit.step_out])
    })
    // Three: the descent, the set_attr that could not land, and the
    // remove_attr that could not either.
    names.push("remove_attr with the cursor on a text node")
    faults.push("component 0: step_in 0 needs a container node, not a text node | component 0: set_attr needs a element node, not a text node | component 0: remove_attr needs a element node, not a text node")
    wants.push(seed_state)
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
        r.eq("{names[index]}: the exact refusal", joined(a.faults), faults[index])
        r.eq("{names[index]}: and the tree is untouched", after, wants[index])
        index += 1
    }

    // The seventh, and the one that would cost the most in a browser:
    // `textContent` on the element a component is mounted into removes
    // everything that child rendered, and the child's next update carries only
    // what CHANGED, so the page never comes back.
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
    r.eq("set_text at a mount is refused", joined(a.faults),
        "component 0: set_text 4 needs a text node, not a mount node")
    r.eq("and the child's subtree is untouched", applier_state(a), mounted)
    r.no("the seed is not what any of this produced", mounted == start)

    // ---- the CURSOR rule, by the second route --------------------------
    //
    // `insert`, `remove` and `relocate` need a node that can hold children.
    // The FIRST route to a leaf cursor is an ordinary edit stream — a `step_in`
    // that was refused descends into the leaf anyway — and § 1 carries a shape
    // for each of the three ops that way. This is the second route: a leaf
    // planted directly in `Applier.roots`, which is `pub`, as is every field of
    // `Node`. Both are here because the rule is ONE rule: a node that cannot
    // hold children never gains any, however the applier got there.
    //
    // It matters that the first route exists. If a refused `step_in` pushed a
    // fresh placeholder instead, the cursor would be a container on every
    // reachable path, these three refusals would be dead code, and an edit
    // below a mis-stepped scope would land on a throwaway with nothing raised.
    // That is why the placeholder is only for an INDEX that is out of range.
    //
    // Before the rule, an `insert` at a leaf appended a child that
    // `Applier.emit` then dropped on the way out — content accepted, silently
    // lost.
    io.println("-- a leaf planted as a component root")
    var ops: List<string> = ["insert", "remove", "relocate"]
    var trips: List<fn(Batch)> = [
        fn(batch: Batch) {
            batch.reference.push(Frame.text(0, "one"))
            at_component(batch, 7, [Edit.insert(0, 0)])
        },
        fn(batch: Batch) { at_component(batch, 7, [Edit.remove(0)]) },
        fn(batch: Batch) { at_component(batch, 7, [Edit.relocate(0, 1)]) }]
    // The nearest legal neighbour: the same edits at a root that CAN hold
    // children. `remove` and `relocate` need something to act on, so each
    // control fills the node first — and the shape afterwards is what tells
    // an accepted edit from a quietly discarded one.
    var controls: List<fn(Batch)> = [
        fn(batch: Batch) {
            batch.reference.push(Frame.text(0, "one"))
            at_component(batch, 8, [Edit.insert(0, 0)])
        },
        fn(batch: Batch) {
            batch.reference.push(Frame.text(0, "one"))
            batch.reference.push(Frame.text(1, "two"))
            at_component(batch, 8, [Edit.insert(0, 0), Edit.insert(1, 1),
                                    Edit.remove(0)])
        },
        fn(batch: Batch) {
            batch.reference.push(Frame.text(0, "one"))
            batch.reference.push(Frame.text(1, "two"))
            at_component(batch, 8, [Edit.insert(0, 0), Edit.insert(1, 1),
                                    Edit.relocate(0, 1)])
        }]
    var shapes: List<string> = ["kind=0 kids=1 one", "kind=0 kids=1 two",
                                "kind=0 kids=2 two one"]

    var op: int = 0
    for op < ops.len() {
        let bad: Applier = seeded()
        let leaf: Node = new Node()
        leaf.kind = SPAN_TEXT
        leaf.html = "leaf"
        bad.roots[7] = leaf
        let trip: Batch = new Batch()
        trips[op](trip)
        bad.apply(trip)
        io.println("   {ops[op]} at a text root: {joined(bad.faults)} / {root_shape(bad, 7)}")
        r.eq("{ops[op]} at a leaf cursor is refused", joined(bad.faults),
            "component 7: {ops[op]} needs a container node, not a text node")
        // The leaf gained nothing. `emit` writes a text node's html and never
        // its children, so a child that landed here would be invisible in the
        // page and present in the tree — which is what "silently lost" was.
        r.eq("{ops[op]} at a leaf cursor left it alone", root_shape(bad, 7),
            "kind=1 kids=0")
        // Component 0's page is untouched; the only difference from the seed
        // is the planted root itself, which this test put there.
        r.eq("{ops[op]} at a leaf cursor touched nothing else", applier_state(bad),
            "<div id=\"root\">head<p class=\"row\">one</p>tail<em>raw</em></div> roots= 0 7 attrs=2 binds=1 sfaults=0")

        let good: Applier = seeded()
        good.roots[8] = new Node()
        let control: Batch = new Batch()
        controls[op](control)
        good.apply(control)
        io.println("   {ops[op]} at an element root: {joined(good.faults)} / {root_shape(good, 8)}")
        r.eq("{ops[op]} at a container cursor raises nothing", joined(good.faults), "")
        r.eq("{ops[op]} at a container cursor applied", root_shape(good, 8), shapes[op])
        op += 1
    }
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

// ------------------------------------------------------------------ § 5

/// The other half of § 4: what the two walkers do when the frame ISN'T
/// swallowed upstream.
///
/// `Builder.frames` is public, so a hand-assembled list puts an attribute-run
/// frame in a child position and both walkers meet it. `serialize.b` reports it
/// by name and writes the children after it anyway; `scan_spans` — which is
/// what `Applier.build` and the whole differ read siblings with — used to
/// BREAK on it, so every sibling past the stray was silently dropped.
///
/// The two answers were `<b>one</b>` and `<b>onetwo</b>` for one frame list,
/// with zero faults on the applier's side. That is gate 3's entire comparison
/// — "the applier must land on the serializer's HTML of the new tree" —
/// disagreeing with itself over a shape neither walker refuses. `scan_spans`
/// steps over the stray now, which is what the serializer does, and this
/// section is the assertion that they cannot drift apart again.
///
/// All SIX frames that `frame_is_attribute` names, not the one the probe
/// found: `attribute`, `flag`, `splat`, `handler`, `reference` and `preserve`
/// each reach the same branch, and a fix measured on one of them says nothing
/// about the other five.
///
/// It is deliberately NOT a refusal on the applier's side. The Beans applier
/// could raise a fault here, but `latte.js` applies the same stream with no
/// serializer beside it to report anything, and a sentence invented in one
/// half is a sentence the other half does not have — the exact drift THE
/// APPLIER CONTRACT exists to stop. What both halves must do first is agree on
/// the CONTENT, and that is what is pinned here; whether a stray frame also
/// earns a sentence is a contract question and belongs to whoever owns both
/// halves. lanes/W1.md, SEVENTH AGENT, says so and names the cost.
fn strays_read_the_same_way(r: Report) {
    io.println("== 5 a stray attribute frame reads the same to both walkers")

    var names: List<string> = ["attribute", "flag", "splat", "handler",
                              "reference", "preserve"]
    var strays: List<Frame> = [Frame.attribute(1, "class", "x"),
                               Frame.flag(1, "hidden", true),
                               Frame.splat(1, 0),
                               Frame.handler(1, "click", 7),
                               Frame.reference(1),
                               Frame.preserve(1)]
    var reports: List<string> = ["1 attr class=x is not a child position",
                                 "1 flag hidden=true is not a child position",
                                 "1 splat 0 is not a child position",
                                 "1 on:click -> 7 is not a child position",
                                 "1 ref is not a child position",
                                 "1 preserve is not a child position"]

    var index: int = 0
    for index < names.len() {
        // `<b>one<stray>two</b>`, staged in a batch's reference pool and
        // handed to the serializer as a frame list. Two children around the
        // stray, because a subtree with nothing after it cannot tell "stepped
        // over" from "stopped here".
        let a: Applier = new Applier()
        let batch: Batch = new Batch()
        batch.reference.push(Frame.open(9, "b"))
        batch.reference.push(Frame.text(0, "one"))
        batch.reference.push(strays[index])
        batch.reference.push(Frame.text(2, "two"))
        batch.reference.push(Frame.close)
        at_component(batch, 0, [Edit.insert(0, 0)])
        a.apply(batch)

        let b: Builder = new Builder()
        b.frames.push(Frame.open(9, "b"))
        b.frames.push(Frame.text(0, "one"))
        b.frames.push(strays[index])
        b.frames.push(Frame.text(2, "two"))
        b.frames.push(Frame.close)
        let writer: Serializer = new Serializer()
        let html: string = writer.page(b)
        let applied: string = a.html()

        io.println("-- a stray {names[index]} frame in a child position")
        io.println("   applier:    {applied}")
        io.println("   serializer: {html}  {joined(writer.faults)}")

        r.eq("a stray {names[index]}: the serializer reports it",
            joined(writer.faults), reports[index])
        r.eq("a stray {names[index]}: and writes the children after it", html,
            "<b>onetwo</b>")
        // The one that was red before the fix: it read `<b>one</b>`.
        r.eq("a stray {names[index]}: the applier reads the same children",
            applied, html)
        r.eq("a stray {names[index]}: and the applier says nothing about it",
            joined(a.faults), "")
        index += 1
    }

    // The control: the same subtree with no stray. Without it, "both walkers
    // say <b>onetwo</b>" would pass just as well against a walker that ignored
    // the middle frame slot entirely.
    let clean: Applier = new Applier()
    let batch: Batch = new Batch()
    batch.reference.push(Frame.open(9, "b"))
    batch.reference.push(Frame.text(0, "one"))
    batch.reference.push(Frame.text(2, "two"))
    batch.reference.push(Frame.close)
    at_component(batch, 0, [Edit.insert(0, 0)])
    clean.apply(batch)

    let b: Builder = new Builder()
    b.frames.push(Frame.open(9, "b"))
    b.frames.push(Frame.text(0, "one"))
    b.frames.push(Frame.text(2, "two"))
    b.frames.push(Frame.close)
    let writer: Serializer = new Serializer()
    let html: string = writer.page(b)
    io.println("-- the control: no stray frame")
    io.println("   applier:    {clean.html()}")
    io.println("   serializer: {html}  {joined(writer.faults)}")
    r.eq("with no stray the serializer raises nothing", joined(writer.faults), "")
    r.eq("and both walkers read the same two children", clean.html(), html)
    r.eq("which is the same page the stray cases produced", clean.html(),
        "<b>onetwo</b>")
}

fn main() {
    let r: Report = new Report()
    apply_fault_sites(r)
    the_kind_rule(r)
    serializer_fault_sites(r)
    swallowed_upstream(r)
    strays_read_the_same_way(r)
    io.println("== summary")
    io.println("checks: {r.checks}, failed: {r.bad}")
}
