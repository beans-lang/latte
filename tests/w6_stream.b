// Gate 8, first row: chunk boundaries at EVERY byte split.
//
// The three claims this suite makes, in the order they matter:
//
//   1. **A streamed page and a buffered page are the same page.** The head
//      with its placeholders, plus every chunk, reassembles byte for byte into
//      the HTML the same page produces when nothing is deferred. If that is not
//      true then streaming is a second renderer, and a second renderer is a
//      second set of bugs.
//   2. **The framing is unambiguous under any split.** Every two-way split of
//      every document shape, every uniform feed size, and every three-way
//      split of the shortest shape, all through the same reader, all landing on
//      the same events. A test that split a body in three places would prove
//      nothing here — this is the seam, so the seam is swept.
//   3. **The reader is incremental, and the test can tell.** A reader that
//      buffered the whole document and parsed it at `finish()` would pass claim
//      2 without proving anything at all, so § 3 asserts that feeding one byte
//      at a time produces MORE events than one feed does, and that the
//      undecided hold never exceeds its bound. Delete the hold and § 3 goes red
//      before § 2 does.
//
// Sections:
//   1  the page          — streamed and buffered land on the same HTML
//   2  the sweep         — every split of every shape
//   3  incremental       — the reader holds a bounded tail, not the document
//   4  reader refusals   — each with a positive control beside it
//   5  writer refusals   — each with a positive control beside it
//   6  the annotation    — @stream is load-bearing in both directions
package main

import std.io
import std.reflect
import {Builder, Component, Renderer, Serializer,
        StreamRegion, StreamPage, StreamDocument, ChunkReader, ChunkEvent,
        MAX_STREAM_ID, describe_chunk_events, assemble_chunks, slot_placeholder,
        stream_id_is_safe, html_forges_framing, stream_scan, type_streams,
        stream} from latte

// ---------------------------------------------------------------- the pages

/// Three deferred regions, markup around and between them, and one region
/// nested inside another element so a placeholder is not always a body child.
@stream
pub class Dashboard extends Component {
    pub title: string = "Sales"
    pub fn init() {}
    pub override fn render(b: Builder) {
        b.open(0, "main")
        b.attr(1, "id", "app")
        b.open(2, "h1")
        b.text(3, self.title)
        b.close()
        b.component<StreamRegion>(4, fn(r: StreamRegion) {
            r.body = fn(inner: Builder) {
                inner.open(0, "section")
                inner.attr(1, "class", "totals")
                inner.text(2, "revenue 41 & rising")
                inner.close()
            }
        })
        b.open(5, "aside")
        b.component<StreamRegion>(0, fn(r: StreamRegion) {
            r.body = fn(inner: Builder) {
                inner.open(0, "p")
                inner.text(1, "a slow note")
                inner.close()
            }
        })
        b.close()
        b.component<StreamRegion>(6, fn(r: StreamRegion) {
            r.sid = "footer"
            r.body = fn(inner: Builder) {
                inner.open(0, "footer")
                inner.text(1, "done")
                inner.close()
            }
        })
        b.close()
    }
}

/// The same shape with no `@stream`. § 6's negative half.
pub class Unmarked extends Component {
    pub fn init() {}
    pub override fn render(b: Builder) {
        b.open(0, "div")
        b.component<StreamRegion>(1, fn(r: StreamRegion) {
            r.body = fn(inner: Builder) { inner.text(0, "x") }
        })
        b.close()
    }
}

/// `@stream` and nothing to defer. § 6's other negative half.
@stream
pub class Barren extends Component {
    pub fn init() {}
    pub override fn render(b: Builder) {
        b.open(0, "div")
        b.text(1, "nothing is deferred here")
        b.close()
    }
}

/// Two regions an author named the same thing. § 6.
@stream
pub class Twins extends Component {
    pub fn init() {}
    pub override fn render(b: Builder) {
        b.open(0, "div")
        b.component<StreamRegion>(1, fn(r: StreamRegion) {
            r.sid = "same"
            r.body = fn(inner: Builder) { inner.text(0, "a") }
        })
        b.component<StreamRegion>(2, fn(r: StreamRegion) {
            r.sid = "same"
            r.body = fn(inner: Builder) { inner.text(0, "b") }
        })
        b.close()
    }
}

/// An author's name that a generated one would have collided with, and an
/// unnamed region on either side of it. One-pass numbering hands `s0` to the
/// first region and then meets the author's `s0`; this page is what makes that
/// a red line instead of a silent double-fill.
@stream
pub class Collide extends Component {
    pub fn init() {}
    pub override fn render(b: Builder) {
        b.open(0, "div")
        b.component<StreamRegion>(1, fn(r: StreamRegion) {
            r.body = fn(inner: Builder) { inner.text(0, "first") }
        })
        b.component<StreamRegion>(2, fn(r: StreamRegion) {
            r.sid = "s0"
            r.body = fn(inner: Builder) { inner.text(0, "named s0") }
        })
        b.component<StreamRegion>(3, fn(r: StreamRegion) {
            r.body = fn(inner: Builder) { inner.text(0, "third") }
        })
        b.close()
    }
}

/// A `@stream` on something that is not a component at all. `stream_scan`
/// must name it; nothing else in the program would.
@stream
pub class NotAComponent {
    pub fn init() {}
}

// ---------------------------------------------------------------- helpers

/// Feed `text` to a reader in pieces of `size` bytes, and answer the events
/// normalised. `size` of 0 means one feed.
fn read_in(text: string, size: int) -> string {
    var reader: ChunkReader = new ChunkReader()
    let step: int = if size <= 0 { text.len() + 1 } else { size }
    var at: int = 0
    for at < text.len() {
        var end: int = at + step
        if end > text.len() { end = text.len() }
        reader.feed(text.slice(at, end))
        at = end
    }
    reader.finish()
    if reader.faults.len() > 0 { return "refused: {reader.faults[0]}" }
    return describe_chunk_events(reader.events)
}

/// Feed `text` as exactly two pieces split at `at`.
fn read_split(text: string, at: int) -> string {
    var reader: ChunkReader = new ChunkReader()
    reader.feed(text.slice(0, at))
    reader.feed(text.slice(at, text.len()))
    reader.finish()
    if reader.faults.len() > 0 { return "refused: {reader.faults[0]}" }
    return describe_chunk_events(reader.events)
}

/// Feed `text` as exactly three pieces, split at `first` and `second`.
fn read_split3(text: string, first: int, second: int) -> string {
    var reader: ChunkReader = new ChunkReader()
    reader.feed(text.slice(0, first))
    reader.feed(text.slice(first, second))
    reader.feed(text.slice(second, text.len()))
    reader.finish()
    if reader.faults.len() > 0 { return "refused: {reader.faults[0]}" }
    return describe_chunk_events(reader.events)
}

/// Every two-way split and every uniform feed size. Answers the number of
/// splits exercised and how many disagreed with the single-feed answer.
fn sweep(label: string, text: string) -> int {
    let whole: string = read_in(text, 0)
    var splits: int = 0
    var wrong: int = 0
    for at: int in 0..text.len() + 1 {
        splits += 1
        if read_split(text, at) != whole { wrong += 1 }
    }
    for size: int in 1..text.len() + 1 {
        splits += 1
        if read_in(text, size) != whole { wrong += 1 }
    }
    io.println("{label}: {text.len()} bytes, {splits} splits, {wrong} wrong")
    return wrong
}

fn events_of(text: string, size: int) -> int {
    var reader: ChunkReader = new ChunkReader()
    let step: int = if size <= 0 { text.len() + 1 } else { size }
    var at: int = 0
    for at < text.len() {
        var end: int = at + step
        if end > text.len() { end = text.len() }
        reader.feed(text.slice(at, end))
        at = end
    }
    reader.finish()
    return reader.events.len()
}

/// The largest hold the reader ever took while `text` went in one byte at a
/// time. A reader that buffered the document would report its whole length.
fn peak_hold(text: string) -> int {
    var reader: ChunkReader = new ChunkReader()
    var peak: int = 0
    for at: int in 0..text.len() {
        reader.feed(text.slice(at, at + 1))
        if reader.held() > peak { peak = reader.held() }
    }
    reader.finish()
    return peak
}

/// One reader run, reported as its refusal or as `ok`. The positive control
/// for every refusal in § 4.
fn verdict(text: string) -> string {
    var reader: ChunkReader = new ChunkReader()
    reader.feed(text)
    reader.finish()
    if reader.faults.len() > 0 { return "refused: {reader.faults[0]}" }
    return "ok: {describe_chunk_events(reader.events)}"
}

// The three shapes that exist to be near-misses of the framing without being
// the framing. Each one is text a page could legitimately hold.
fn near_miss_html() -> string {
    return "<code>&lt;latte-chunk for=&quot;x&quot;&gt;</code><em>latte-chunk for=</em><b>&lt;/latte-chun</b>"
}

fn main() {
    io.println("== 1. a streamed page and a buffered page ==")
    section_one()
    io.println("")
    io.println("== 2. every split of every shape ==")
    section_two()
    io.println("")
    io.println("== 3. the reader is incremental ==")
    section_three()
    io.println("")
    io.println("== 4. reader refusals, each with a control ==")
    section_four()
    io.println("")
    io.println("== 5. writer refusals, each with a control ==")
    section_five()
    io.println("")
    io.println("== 6. @stream is load-bearing ==")
    section_six()
}

// ============================================================== 1

/// The streamed document of a `Dashboard`, and what it reassembles to.
fn streamed_dashboard() -> string {
    let page: Dashboard = new Dashboard()
    let r: Renderer = new Renderer()
    r.mount(page)
    var stream_page: StreamPage = new StreamPage(r)
    let described: reflect.Type = type_of(Dashboard)
    let head: string = stream_page.open(described, "</body></html>")
    var out: string = head
    for id: string in stream_page.pending() { out = "{out}{stream_page.resolve(id)}" }
    out = "{out}{stream_page.close()}"
    if !stream_page.ok() {
        for fault: string in stream_page.faults { io.println("  page fault: {fault}") }
    }
    return out
}

/// The same page with nothing deferred: every region ready before a byte is
/// serialized. This is the answer streaming has to match.
fn buffered_dashboard() -> string {
    let page: Dashboard = new Dashboard()
    let r: Renderer = new Renderer()
    r.mount(page)
    for id: int in r.ids() {
        match r.component(id) {
            some(component) => {
                match component as? StreamRegion {
                    some(region) => {
                        region.ready = true
                        region.notify()
                    }
                    none => {}
                }
            }
            none => {}
        }
    }
    let _: int = r.flush()
    return "{r.html()}</body></html>"
}

fn section_one() {
    let page: Dashboard = new Dashboard()
    let r: Renderer = new Renderer()
    r.mount(page)
    var stream_page: StreamPage = new StreamPage(r)
    let described: reflect.Type = type_of(Dashboard)
    let head: string = stream_page.open(described, "</body></html>")
    let ids: List<string> = stream_page.slots()
    let listed: string = ids.join(", ")
    io.println("slots: {ids.len()} [{listed}]")
    io.println("head: {head}")
    var pieces: List<string> = []
    for id: string in ids {
        let piece: string = stream_page.resolve(id)
        pieces.push(piece)
        io.println("chunk {id}: {piece}")
    }
    io.println("tail: {stream_page.close()}")
    io.println("page ok: {stream_page.ok()}")

    // Render counts: resolving one region renders one component, not the page.
    var counts: string = ""
    for id: int in r.ids() { counts = "{counts}{r.render_count(id)} " }
    io.println("render counts by mount order: {counts.trim()}")

    let document: string = streamed_dashboard()
    var faults: List<string> = []
    var reader: ChunkReader = new ChunkReader()
    reader.feed(document)
    reader.finish()
    let rebuilt: string = assemble_chunks(reader.events, faults)
    let buffered: string = buffered_dashboard()
    io.println("assembly faults: {faults.len()}")
    io.println("streamed == buffered: {rebuilt == buffered}")
    if rebuilt != buffered {
        io.println("  streamed: {rebuilt}")
        io.println("  buffered: {buffered}")
    }
}

// ============================================================== 2

fn section_two() {
    var wrong: int = 0
    let document: string = streamed_dashboard()
    wrong += sweep("a real page, three chunks", document)

    // A one-chunk document, so the sweep has a shape with nothing between the
    // head and the chunk.
    var one: StreamDocument = new StreamDocument()
    let _1: bool = one.head("<p>a</p>{slot_placeholder("z")}", ["z"])
    let _2: bool = one.chunk("z", "<b>Z</b>")
    let _3: bool = one.tail("")
    wrong += sweep("one chunk, no tail", one.text())

    // An EMPTY chunk. The content is legal and the body state must still find
    // its close marker with no bytes in front of it.
    var empty: StreamDocument = new StreamDocument()
    let _4: bool = empty.head(slot_placeholder("e"), ["e"])
    let _5: bool = empty.chunk("e", "")
    let _6: bool = empty.tail("<hr>")
    wrong += sweep("an empty chunk", empty.text())

    // Near-miss text: things that look like the framing and are not. A reader
    // that scanned for "<latte-" would cut these in half.
    var miss: StreamDocument = new StreamDocument()
    let _7: bool = miss.head("{near_miss_html()}{slot_placeholder("m")}", ["m"])
    let _8: bool = miss.chunk("m", near_miss_html())
    let _9: bool = miss.tail(near_miss_html())
    wrong += sweep("near misses either side", miss.text())

    // Ids at both length boundaries.
    let long_id: string = "a".repeat(MAX_STREAM_ID)
    var edges: StreamDocument = new StreamDocument()
    let _10: bool = edges.head("{slot_placeholder("x")}|{slot_placeholder(long_id)}", ["x", long_id])
    let _11: bool = edges.chunk("x", "1")
    let _12: bool = edges.chunk(long_id, "2")
    let _13: bool = edges.tail("")
    wrong += sweep("a 1-byte id and a {MAX_STREAM_ID}-byte id", edges.text())

    // Chunks whose content is itself a placeholder-looking string, so the
    // assembler cannot rely on order.
    var nested: StreamDocument = new StreamDocument()
    let _14: bool = nested.head("{slot_placeholder("p")}{slot_placeholder("q")}", ["p", "q"])
    let _15: bool = nested.chunk("p", slot_placeholder("q"))
    let _16: bool = nested.chunk("q", "<i>q</i>")
    let _17: bool = nested.tail("")
    wrong += sweep("a chunk that contains another slot's placeholder", nested.text())

    io.println("two-way and uniform sweeps disagreeing: {wrong}")

    // Every THREE-way split of the shortest shape. Two cuts, not one, because a
    // reader can hold state across exactly one boundary by accident and still
    // be wrong across two.
    let short: string = empty.text()
    let whole: string = read_in(short, 0)
    var triples: int = 0
    var triple_wrong: int = 0
    for first: int in 0..short.len() + 1 {
        for second: int in first..short.len() + 1 {
            triples += 1
            if read_split3(short, first, second) != whole { triple_wrong += 1 }
        }
    }
    io.println("three-way splits of the {short.len()}-byte shape: {triples}, wrong {triple_wrong}")
}

// ============================================================== 3

fn section_three() {
    let document: string = streamed_dashboard()
    let one_feed: int = events_of(document, 0)
    let byte_feed: int = events_of(document, 1)
    io.println("events in one feed: {one_feed}, byte at a time: {byte_feed}")
    io.println("a byte-at-a-time read is more events: {byte_feed > one_feed}")
    // The bound: the longest marker the reader looks for, minus one, plus the
    // longest id it may be part way through. A reader that buffered the
    // document would report {document.len()} here.
    let bound: int = MAX_STREAM_ID + 32
    let peak: int = peak_hold(document)
    io.println("peak hold {peak} bytes over a {document.len()}-byte document, bound {bound}: {peak <= bound}")
}

// ============================================================== 4

fn section_four() {
    // Every refusal, and beside each the input that must be ACCEPTED. Without
    // the control there is no way to tell "refused for this reason" from
    // "refused earlier, for another one" (RULES.md, "The refusal that never
    // runs").
    var good: StreamDocument = new StreamDocument()
    let _1: bool = good.head(slot_placeholder("s0"), ["s0"])
    let _2: bool = good.chunk("s0", "<b>ok</b>")
    let _3: bool = good.tail("")
    let sound: string = good.text()

    io.println("control, a whole document          {verdict(sound)}")
    io.println("cut before the seal                {verdict(sound.slice(0, sound.len() - 5))}")
    io.println("cut inside the body                {verdict("<latte-chunk for=\"s0\">ab")}")
    io.println("cut inside the opening tag         {verdict("<latte-chunk for=\"s0")}")
    io.println("a seal for another slot            {verdict("<latte-chunk for=\"s0\">a</latte-chunk><latte-seal for=\"s9\"></latte-seal>")}")
    io.println("no seal at all                     {verdict("<latte-chunk for=\"s0\">a</latte-chunk><p>next</p>")}")
    io.println("the same slot twice                {verdict("{sound}{sound}")}")
    io.println("an id with a space                 {verdict("<latte-chunk for=\"a b\">x</latte-chunk><latte-seal for=\"a b\"></latte-seal>")}")
    io.println("an empty id                        {verdict("<latte-chunk for=\"\">x</latte-chunk><latte-seal for=\"\"></latte-seal>")}")
    let over: string = "a".repeat(MAX_STREAM_ID + 1)
    io.println("an id one byte too long            {verdict("<latte-chunk for=\"{over}\">x</latte-chunk>")}")
    let at_limit: string = "a".repeat(MAX_STREAM_ID)
    io.println("an id exactly at the limit         {verdict("<latte-chunk for=\"{at_limit}\">x</latte-chunk><latte-seal for=\"{at_limit}\"></latte-seal>")}")
    io.println("bytes after finish                 {feed_after_finish()}")
    io.println("finish twice                       {finish_twice()}")
}

fn feed_after_finish() -> string {
    var reader: ChunkReader = new ChunkReader()
    reader.feed("<p>a</p>")
    reader.finish()
    reader.feed("<p>b</p>")
    if reader.faults.len() > 0 { return "refused: {reader.faults[0]}" }
    return "accepted, which it should not have"
}

fn finish_twice() -> string {
    var reader: ChunkReader = new ChunkReader()
    reader.feed("<p>a</p>")
    reader.finish()
    reader.finish()
    if reader.faults.len() > 0 { return "refused: {reader.faults[0]}" }
    return "accepted, which it should not have"
}

// ============================================================== 5

fn writer(steps: fn(StreamDocument)) -> string {
    var doc: StreamDocument = new StreamDocument()
    steps(doc)
    if doc.faults.len() > 0 { return "refused: {doc.faults[0]}" }
    return "ok: {doc.text()}"
}

fn show(label: string, steps: fn(StreamDocument)) {
    io.println("{label}{writer(steps)}")
}

fn section_five() {
    show("control, head chunk tail           ", fn(d: StreamDocument) {
        let _1: bool = d.head(slot_placeholder("s0"), ["s0"])
        let _2: bool = d.chunk("s0", "<b>x</b>")
        let _3: bool = d.tail("!")
    })
    show("a chunk for a slot nobody opened   ", fn(d: StreamDocument) {
        let _1: bool = d.head("", [])
        let _2: bool = d.chunk("nope", "x")
    })
    show("the same slot filled twice         ", fn(d: StreamDocument) {
        let _1: bool = d.head(slot_placeholder("s0"), ["s0"])
        let _2: bool = d.chunk("s0", "a")
        let _3: bool = d.chunk("s0", "b")
    })
    show("a slot promised twice              ", fn(d: StreamDocument) {
        let _1: bool = d.head("", ["s0", "s0"])
    })
    show("an unusable slot id                ", fn(d: StreamDocument) {
        let _1: bool = d.head("", ["a b"])
    })
    show("a chunk before the head            ", fn(d: StreamDocument) {
        let _1: bool = d.chunk("s0", "x")
    })
    show("two heads                          ", fn(d: StreamDocument) {
        let _1: bool = d.head("", [])
        let _2: bool = d.head("", [])
    })
    show("a tail with a slot unfilled        ", fn(d: StreamDocument) {
        let _1: bool = d.head(slot_placeholder("s0"), ["s0"])
        let _2: bool = d.tail("")
    })
    show("two tails                          ", fn(d: StreamDocument) {
        let _1: bool = d.head("", [])
        let _2: bool = d.tail("")
        let _3: bool = d.tail("")
    })
    show("a chunk after the tail             ", fn(d: StreamDocument) {
        let _1: bool = d.head("", [])
        let _2: bool = d.tail("")
        let _3: bool = d.chunk("s0", "x")
    })
    show("a head that forges the framing     ", fn(d: StreamDocument) {
        let _1: bool = d.head("<latte-chunk for=\"s0\">", [])
    })
    show("a chunk whose content forges it    ", fn(d: StreamDocument) {
        let _1: bool = d.head(slot_placeholder("s0"), ["s0"])
        let _2: bool = d.chunk("s0", "a</LATTE-CHUNK>b")
    })
    show("a tail that forges the framing     ", fn(d: StreamDocument) {
        let _1: bool = d.head(slot_placeholder("s0"), ["s0"])
        let _2: bool = d.chunk("s0", "a")
        let _3: bool = d.tail("<latte-seal for=\"s0\"></latte-seal>")
    })
    show("near-miss text passes through      ", fn(d: StreamDocument) {
        let _1: bool = d.head(slot_placeholder("s0"), ["s0"])
        let _2: bool = d.chunk("s0", near_miss_html())
        let _3: bool = d.tail("")
    })

    let over_id: string = "a".repeat(MAX_STREAM_ID + 1)
    let limit_id: string = "a".repeat(MAX_STREAM_ID)
    io.println("stream_id_is_safe: empty {stream_id_is_safe("")} one {stream_id_is_safe("a")} limit {stream_id_is_safe(limit_id)} over {stream_id_is_safe(over_id)} space {stream_id_is_safe("a b")} quote {stream_id_is_safe("a\"b")} dash {stream_id_is_safe("a-b_0")}")
    io.println("html_forges_framing: plain {html_forges_framing("<p>x</p>")} open {html_forges_framing("<latte-chunk for=\"a\">")} close {html_forges_framing("</latte-chunk>")} seal {html_forges_framing("<latte-seal for=\"a\">")} upper {html_forges_framing("</LATTE-CHUNK>")} near {html_forges_framing(near_miss_html())}")
}

// ============================================================== 6

fn open_of(page: Component, described: reflect.Type) -> string {
    let r: Renderer = new Renderer()
    r.mount(page)
    var stream_page: StreamPage = new StreamPage(r)
    let head: string = stream_page.open(described, "")
    if stream_page.faults.len() > 0 { return "refused: {stream_page.faults[0]}" }
    return "ok: {head}"
}

fn section_six() {
    let dashboard: reflect.Type = type_of(Dashboard)
    let unmarked: reflect.Type = type_of(Unmarked)
    let barren: reflect.Type = type_of(Barren)
    let twins: reflect.Type = type_of(Twins)
    let not_a_component: reflect.Type = type_of(NotAComponent)

    io.println("type_streams Dashboard {type_streams(dashboard)} Unmarked {type_streams(unmarked)} Barren {type_streams(barren)}")

    let ok_page: Dashboard = new Dashboard()
    io.println("control, @stream with regions      {open_of(ok_page, dashboard).len() > 0}")
    let no_annotation: Unmarked = new Unmarked()
    io.println("regions with no @stream            {open_of(no_annotation, unmarked)}")
    let no_regions: Barren = new Barren()
    io.println("@stream with no regions            {open_of(no_regions, barren)}")
    let same_name: Twins = new Twins()
    io.println("two regions with one name          {open_of(same_name, twins)}")

    // A page opened twice, and one closed before it was opened.
    let twice: Dashboard = new Dashboard()
    let r: Renderer = new Renderer()
    r.mount(twice)
    var page: StreamPage = new StreamPage(r)
    let _1: string = page.open(dashboard, "")
    let _2: string = page.open(dashboard, "")
    io.println("opened twice                       refused: {page.faults[0]}")

    let early: Renderer = new Renderer()
    let barren_page: Barren = new Barren()
    early.mount(barren_page)
    var unopened: StreamPage = new StreamPage(early)
    let _3: string = unopened.close()
    io.println("closed before it was opened        refused: {unopened.faults[0]}")

    let missed: Dashboard = new Dashboard()
    let r2: Renderer = new Renderer()
    r2.mount(missed)
    var forgot: StreamPage = new StreamPage(r2)
    let _4: string = forgot.open(dashboard, "")
    let first: List<string> = forgot.pending()
    let _5: string = forgot.resolve(first[0])
    let _6: string = forgot.close()
    io.println("a region nobody resolved           refused: {forgot.doc.faults[0]}")

    let stray: Dashboard = new Dashboard()
    let r3: Renderer = new Renderer()
    r3.mount(stray)
    var wrong_id: StreamPage = new StreamPage(r3)
    let _7: string = wrong_id.open(dashboard, "")
    let _8: string = wrong_id.resolve("not-a-slot")
    io.println("a slot this page never had         refused: {wrong_id.faults[0]}")

    // The generated ids step over the author's. Without the second pass the
    // first region takes "s0", the author's "s0" is refused as a duplicate,
    // and a page that is perfectly well formed does not render.
    let collide: Collide = new Collide()
    let collide_type: reflect.Type = type_of(Collide)
    let cr: Renderer = new Renderer()
    cr.mount(collide)
    var cpage: StreamPage = new StreamPage(cr)
    let chead: string = cpage.open(collide_type, "")
    let cids: List<string> = cpage.slots()
    let clisted: string = cids.join(", ")
    io.println("author's name and generated ones   [{clisted}]")
    io.println("  head {chead}")
    var cdoc: string = chead
    for id: string in cpage.pending() { cdoc = "{cdoc}{cpage.resolve(id)}" }
    cdoc = "{cdoc}{cpage.close()}"
    var cfaults: List<string> = []
    var creader: ChunkReader = new ChunkReader()
    creader.feed(cdoc)
    creader.finish()
    io.println("  assembled {assemble_chunks(creader.events, cfaults)}")
    io.println("  faults {cfaults.len()} page ok {cpage.ok()}")

    // The scan. `NotAComponent` is the only type in this program annotated
    // @stream that cannot stream, and nothing else would ever mention it.
    let scanned: List<string> = stream_scan()
    io.println("stream_scan found {scanned.len()}:")
    for fault: string in scanned { io.println("  {fault}") }
    io.println("NotAComponent is a type {not_a_component.name()}")
}
