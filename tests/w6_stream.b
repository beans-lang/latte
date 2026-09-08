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

/// The smallest well-formed streaming page. Every page probe's control.
@stream
pub class Small extends Component {
    pub fn init() {}
    pub override fn render(b: Builder) {
        b.open(0, "div")
        b.component<StreamRegion>(1, fn(r: StreamRegion) {
            r.sid = "one"
            r.body = fn(inner: Builder) { inner.text(0, "hello") }
        })
        b.close()
    }
}

/// A region an author named something that cannot be a slot id.
@stream
pub class BadName extends Component {
    pub fn init() {}
    pub override fn render(b: Builder) {
        b.open(0, "div")
        b.component<StreamRegion>(1, fn(r: StreamRegion) {
            r.sid = "a b"
            r.body = fn(inner: Builder) { inner.text(0, "x") }
        })
        b.close()
    }
}

/// A region whose body writes raw text into a `<style>` that could close it.
/// The serializer refuses that content, and this is the only shape that gets a
/// serializer fault out of a region and into the streamed page's fault list.
@stream
pub class RawStyle extends Component {
    pub closer: bool = true
    pub fn init() {}
    pub override fn render(b: Builder) {
        b.open(0, "div")
        b.component<StreamRegion>(1, fn(r: StreamRegion) {
            let closing: bool = self.closer
            r.body = fn(inner: Builder) {
                inner.open(0, "style")
                if closing { inner.raw(1, ".a\{\}</style>") }
                else { inner.raw(1, ".a\{color:red\}") }
                inner.close()
            }
        })
        b.close()
    }
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

// The three shapes that exist to be near-misses of the framing without being
// the framing. Each one is text a page could legitimately hold.
fn near_miss_html() -> string {
    return "<code>&lt;latte-chunk for=&quot;x&quot;&gt;</code><em>latte-chunk for=</em><b>&lt;/latte-chun</b>"
}


// ---------------------------------------------------------------- the report

/// A check that prints its own verdict. `probes/delete_faults.sh` reads the
/// `FAIL <case>` lines, so a case that only writes a value into a golden
/// cannot be mapped back to the site it guards.
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

// ------------------------------------------- the fault-site probe

/// One report site in `stream.b`, one trip, one control.
///
/// `trip` answers the faults the bad input raised; `control` answers the
/// faults of the NEAREST LEGAL input, which must be none; and `made` answers
/// what the control produced, which must be exactly `produced` and must not be
/// empty. Without the last one a control that was quietly dropped on the floor
/// reads identically to a control that worked (RULES.md, "The refusal that
/// never runs").
pub class SSite {
    pub site: string = ""
    pub name: string = ""
    pub trip: fn() -> string = fn() -> string { return "" }
    pub want: string = ""
    pub control: fn() -> string = fn() -> string { return "" }
    pub made: fn() -> string = fn() -> string { return "" }
    pub produced: string = ""

    pub fn init(site: string, name: string, trip: fn() -> string, want: string,
                control: fn() -> string, made: fn() -> string, produced: string) {
        self.site = site
        self.name = name
        self.trip = trip
        self.want = want
        self.control = control
        self.made = made
        self.produced = produced
    }
}

const S_HEAD_TWICE: string = "head / a streamed document has one head"
const S_HEAD_ID: string = "head / ID is not a usable slot id"
const S_HEAD_DUP: string = "head / the slot ID is promised twice by one page"
const S_HEAD_FORGE: string = "head / the page's head carries chunk framing of its own"
const S_CHUNK_EARLY: string = "chunk / the chunk for ID was written before the page's head"
const S_CHUNK_LATE: string = "chunk / the chunk for ID was written after the document ended"
const S_CHUNK_UNKNOWN: string = "chunk / ID is not a slot this page left open"
const S_CHUNK_TWICE: string = "chunk / the slot ID was filled twice"
const S_CHUNK_FORGE: string = "chunk / the chunk for ID carries chunk framing of its own"
const S_TAIL_EARLY: string = "tail / a streamed document ended before it had a head"
const S_TAIL_TWICE: string = "tail / a streamed document ends once"
const S_TAIL_FORGE: string = "tail / the page's tail carries chunk framing of its own"
const S_TAIL_UNFILLED: string = "tail / the document ended with N slot(s) never filled"
const S_READER: string = "ChunkReader.refuse / the one funnel every reader refusal goes through"
const S_OPEN_TWICE: string = "open / a streamed page is opened once"
const S_OPEN_BADNAME: string = "open / the region named X cannot be a slot id"
const S_OPEN_DUPNAME: string = "open / two regions on this page are both named X"
const S_OPEN_NOMARK: string = "open / N streamed region(s) but no @stream"
const S_OPEN_NOREGION: string = "open / @stream but no StreamRegion"
const S_RESOLVE_UNKNOWN: string = "resolve / ID is not a region of this page"
const S_GONE: string = "gone / the region ID is no longer mounted"
const S_NOT_REGION: string = "emit / the region ID is no longer a StreamRegion"
const S_SERIALIZER: string = "emit / a fault the serializer raised on the region's frames"
const S_CLOSE_EARLY: string = "close / a streamed page was closed before it was opened"

// ------------------------------------------- the machinery a probe drives

fn doc_faults(steps: fn(StreamDocument)) -> string {
    var d: StreamDocument = new StreamDocument()
    steps(d)
    return joined(d.faults)
}

fn doc_text(steps: fn(StreamDocument)) -> string {
    var d: StreamDocument = new StreamDocument()
    steps(d)
    return d.text()
}

fn reader_faults(text: string) -> string {
    var reader: ChunkReader = new ChunkReader()
    reader.feed(text)
    reader.finish()
    return joined(reader.faults)
}

fn reader_events(text: string) -> string {
    var reader: ChunkReader = new ChunkReader()
    reader.feed(text)
    reader.finish()
    return describe_chunk_events(reader.events)
}

/// A page mounted and opened for streaming. Every page probe starts here.
fn opened(page: Component, described: reflect.Type) -> StreamPage {
    let r: Renderer = new Renderer()
    r.mount(page)
    var sp: StreamPage = new StreamPage(r)
    let _: string = sp.open(described, "")
    return sp
}

/// A whole streamed page, as one string, with every region resolved.
fn whole_page(page: Component, described: reflect.Type) -> string {
    var sp: StreamPage = opened(page, described)
    var out: string = ""
    for id: string in sp.pending() { out = "{out}{sp.resolve(id)}" }
    return "{sp.doc.text()}{sp.close()}"
}

/// A sound one-slot document, the control every writer probe compares against.
fn sound_document() -> string {
    return doc_text(fn(d: StreamDocument) {
        let _1: bool = d.head(slot_placeholder("s0"), ["s0"])
        let _2: bool = d.chunk("s0", "<b>ok</b>")
        let _3: bool = d.tail("!")
    })
}

fn page_faults(page: Component, described: reflect.Type, act: fn(StreamPage)) -> string {
    let r: Renderer = new Renderer()
    r.mount(page)
    var sp: StreamPage = new StreamPage(r)
    act(sp)
    return joined(sp.faults)
}

fn small_control() -> string {
    let page: Small = new Small()
    let described: reflect.Type = type_of(Small)
    return page_faults(page, described, fn(sp: StreamPage) {
        let described2: reflect.Type = type_of(Small)
        let _: string = sp.open(described2, "")
        for id: string in sp.pending() { let _2: string = sp.resolve(id) }
        let _3: string = sp.close()
    })
}

fn small_made() -> string {
    let page: Small = new Small()
    let described: reflect.Type = type_of(Small)
    return whole_page(page, described)
}

const SMALL_HTML: string = "<div><latte-slot id=\"one\"></latte-slot></div><latte-chunk for=\"one\">hello</latte-chunk><latte-seal for=\"one\"></latte-seal>"

// ------------------------------------------- the table

fn reader_probe(name: string, bad: string, want: string) -> SSite {
    return new SSite(S_READER, name,
        fn() -> string { return reader_faults(bad) }, want,
        fn() -> string { return reader_faults(sound_document()) },
        fn() -> string { return reader_events(sound_document()) },
        "markup[<latte-slot id=\"s0\"></latte-slot>] open[s0] body[<b>ok</b>] sealed[s0 9] markup[!] done[1]")
}

fn stream_sites() -> List<SSite> {
    var out: List<SSite> = []

    out.push(new SSite(S_HEAD_TWICE, "two heads",
        fn() -> string { return doc_faults(fn(d: StreamDocument) {
            let _1: bool = d.head("<p>a</p>", [])
            let _2: bool = d.head("<p>b</p>", [])
        }) },
        "a streamed document has one head, and this is the second",
        fn() -> string { return doc_faults(fn(d: StreamDocument) {
            let _1: bool = d.head("<p>a</p>", [])
        }) },
        fn() -> string { return doc_text(fn(d: StreamDocument) {
            let _1: bool = d.head("<p>a</p>", [])
        }) },
        "<p>a</p>"))

    out.push(new SSite(S_HEAD_ID, "a slot id with a space",
        fn() -> string { return doc_faults(fn(d: StreamDocument) {
            let _1: bool = d.head("x", ["a b"])
        }) },
        "\"a b\" is not a usable slot id: one to 64 bytes of letters, digits, '-' and '_'",
        fn() -> string { return doc_faults(fn(d: StreamDocument) {
            let _1: bool = d.head("x", ["a-b"])
        }) },
        fn() -> string { return doc_text(fn(d: StreamDocument) {
            let _1: bool = d.head("x", ["a-b"])
        }) },
        "x"))

    out.push(new SSite(S_HEAD_ID, "a slot id one byte over the limit",
        fn() -> string { return doc_faults(fn(d: StreamDocument) {
            let over: string = "a".repeat(MAX_STREAM_ID + 1)
            let _1: bool = d.head("x", [over])
        }) },
        "\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\" is not a usable slot id: one to 64 bytes of letters, digits, '-' and '_'",
        fn() -> string { return doc_faults(fn(d: StreamDocument) {
            let at_limit: string = "a".repeat(MAX_STREAM_ID)
            let _1: bool = d.head("x", [at_limit])
        }) },
        fn() -> string { return doc_text(fn(d: StreamDocument) {
            let at_limit: string = "a".repeat(MAX_STREAM_ID)
            let _1: bool = d.head("x", [at_limit])
        }) },
        "x"))

    out.push(new SSite(S_HEAD_DUP, "one slot promised twice",
        fn() -> string { return doc_faults(fn(d: StreamDocument) {
            let _1: bool = d.head("x", ["s0", "s0"])
        }) },
        "the slot \"s0\" is promised twice by one page",
        fn() -> string { return doc_faults(fn(d: StreamDocument) {
            let _1: bool = d.head("x", ["s0", "s1"])
        }) },
        fn() -> string { return doc_text(fn(d: StreamDocument) {
            let _1: bool = d.head("x", ["s0", "s1"])
        }) },
        "x"))

    out.push(new SSite(S_HEAD_FORGE, "a head that opens a chunk of its own",
        fn() -> string { return doc_faults(fn(d: StreamDocument) {
            let _1: bool = d.head("<latte-chunk for=\"s0\">", [])
        }) },
        "the page's head carries chunk framing of its own, so a reader could not tell it from a real chunk",
        fn() -> string { return doc_faults(fn(d: StreamDocument) {
            let _1: bool = d.head(near_miss_html(), [])
        }) },
        fn() -> string { return doc_text(fn(d: StreamDocument) {
            let _1: bool = d.head(near_miss_html(), [])
        }) },
        near_miss_html()))

    out.push(new SSite(S_CHUNK_EARLY, "a chunk before the head",
        fn() -> string { return doc_faults(fn(d: StreamDocument) {
            let _1: bool = d.chunk("s0", "x")
        }) },
        "the chunk for \"s0\" was written before the page's head",
        fn() -> string { return doc_faults(fn(d: StreamDocument) {
            let _1: bool = d.head(slot_placeholder("s0"), ["s0"])
            let _2: bool = d.chunk("s0", "x")
        }) },
        fn() -> string { return doc_text(fn(d: StreamDocument) {
            let _1: bool = d.head(slot_placeholder("s0"), ["s0"])
            let _2: bool = d.chunk("s0", "x")
        }) },
        "<latte-slot id=\"s0\"></latte-slot><latte-chunk for=\"s0\">x</latte-chunk><latte-seal for=\"s0\"></latte-seal>"))

    out.push(new SSite(S_CHUNK_LATE, "a chunk after the tail",
        fn() -> string { return doc_faults(fn(d: StreamDocument) {
            let _1: bool = d.head("", [])
            let _2: bool = d.tail("")
            let _3: bool = d.chunk("s0", "x")
        }) },
        "the chunk for \"s0\" was written after the document ended",
        fn() -> string { return doc_faults(fn(d: StreamDocument) {
            let _1: bool = d.head(slot_placeholder("s0"), ["s0"])
            let _2: bool = d.chunk("s0", "x")
            let _3: bool = d.tail("")
        }) },
        fn() -> string { return doc_text(fn(d: StreamDocument) {
            let _1: bool = d.head(slot_placeholder("s0"), ["s0"])
            let _2: bool = d.chunk("s0", "x")
            let _3: bool = d.tail("")
        }) },
        "<latte-slot id=\"s0\"></latte-slot><latte-chunk for=\"s0\">x</latte-chunk><latte-seal for=\"s0\"></latte-seal>"))

    out.push(new SSite(S_CHUNK_UNKNOWN, "a chunk for a slot nobody opened",
        fn() -> string { return doc_faults(fn(d: StreamDocument) {
            let _1: bool = d.head("", [])
            let _2: bool = d.chunk("nope", "x")
        }) },
        "\"nope\" is not a slot this page left open",
        fn() -> string { return doc_faults(fn(d: StreamDocument) {
            let _1: bool = d.head(slot_placeholder("nope"), ["nope"])
            let _2: bool = d.chunk("nope", "x")
        }) },
        fn() -> string { return doc_text(fn(d: StreamDocument) {
            let _1: bool = d.head(slot_placeholder("nope"), ["nope"])
            let _2: bool = d.chunk("nope", "x")
        }) },
        "<latte-slot id=\"nope\"></latte-slot><latte-chunk for=\"nope\">x</latte-chunk><latte-seal for=\"nope\"></latte-seal>"))

    out.push(new SSite(S_CHUNK_TWICE, "one slot filled twice",
        fn() -> string { return doc_faults(fn(d: StreamDocument) {
            let _1: bool = d.head(slot_placeholder("s0"), ["s0"])
            let _2: bool = d.chunk("s0", "a")
            let _3: bool = d.chunk("s0", "b")
        }) },
        "the slot \"s0\" was filled twice",
        fn() -> string { return doc_faults(fn(d: StreamDocument) {
            let _1: bool = d.head("{slot_placeholder("s0")}{slot_placeholder("s1")}", ["s0", "s1"])
            let _2: bool = d.chunk("s0", "a")
            let _3: bool = d.chunk("s1", "b")
        }) },
        fn() -> string { return doc_text(fn(d: StreamDocument) {
            let _1: bool = d.head("{slot_placeholder("s0")}{slot_placeholder("s1")}", ["s0", "s1"])
            let _2: bool = d.chunk("s0", "a")
            let _3: bool = d.chunk("s1", "b")
        }) },
        "<latte-slot id=\"s0\"></latte-slot><latte-slot id=\"s1\"></latte-slot><latte-chunk for=\"s0\">a</latte-chunk><latte-seal for=\"s0\"></latte-seal><latte-chunk for=\"s1\">b</latte-chunk><latte-seal for=\"s1\"></latte-seal>"))

    out.push(new SSite(S_CHUNK_FORGE, "a chunk that closes itself",
        fn() -> string { return doc_faults(fn(d: StreamDocument) {
            let _1: bool = d.head(slot_placeholder("s0"), ["s0"])
            let _2: bool = d.chunk("s0", "a</LATTE-CHUNK>b")
        }) },
        "the chunk for \"s0\" carries chunk framing of its own, which would end it early and hand the rest of the page to the reader as document text",
        fn() -> string { return doc_faults(fn(d: StreamDocument) {
            let _1: bool = d.head(slot_placeholder("s0"), ["s0"])
            let _2: bool = d.chunk("s0", near_miss_html())
        }) },
        fn() -> string { return doc_text(fn(d: StreamDocument) {
            let _1: bool = d.head(slot_placeholder("s0"), ["s0"])
            let _2: bool = d.chunk("s0", near_miss_html())
        }) },
        "<latte-slot id=\"s0\"></latte-slot><latte-chunk for=\"s0\">{near_miss_html()}</latte-chunk><latte-seal for=\"s0\"></latte-seal>"))

    out.push(new SSite(S_TAIL_EARLY, "a tail before the head",
        fn() -> string { return doc_faults(fn(d: StreamDocument) {
            let _1: bool = d.tail("</body>")
        }) },
        "a streamed document ended before it had a head",
        fn() -> string { return doc_faults(fn(d: StreamDocument) {
            let _1: bool = d.head("<p>a</p>", [])
            let _2: bool = d.tail("</body>")
        }) },
        fn() -> string { return doc_text(fn(d: StreamDocument) {
            let _1: bool = d.head("<p>a</p>", [])
            let _2: bool = d.tail("</body>")
        }) },
        "<p>a</p></body>"))

    out.push(new SSite(S_TAIL_TWICE, "two tails",
        fn() -> string { return doc_faults(fn(d: StreamDocument) {
            let _1: bool = d.head("", [])
            let _2: bool = d.tail("a")
            let _3: bool = d.tail("b")
        }) },
        "a streamed document ends once, and this is the second end",
        fn() -> string { return doc_faults(fn(d: StreamDocument) {
            let _1: bool = d.head("", [])
            let _2: bool = d.tail("a")
        }) },
        fn() -> string { return doc_text(fn(d: StreamDocument) {
            let _1: bool = d.head("", [])
            let _2: bool = d.tail("a")
        }) },
        "a"))

    out.push(new SSite(S_TAIL_FORGE, "a tail that seals a chunk of its own",
        fn() -> string { return doc_faults(fn(d: StreamDocument) {
            let _1: bool = d.head(slot_placeholder("s0"), ["s0"])
            let _2: bool = d.chunk("s0", "a")
            let _3: bool = d.tail("<latte-seal for=\"s0\"></latte-seal>")
        }) },
        "the page's tail carries chunk framing of its own, so a reader could not tell it from a real chunk",
        fn() -> string { return doc_faults(fn(d: StreamDocument) {
            let _1: bool = d.head(slot_placeholder("s0"), ["s0"])
            let _2: bool = d.chunk("s0", "a")
            let _3: bool = d.tail(near_miss_html())
        }) },
        fn() -> string { return doc_text(fn(d: StreamDocument) {
            let _1: bool = d.head(slot_placeholder("s0"), ["s0"])
            let _2: bool = d.chunk("s0", "a")
            let _3: bool = d.tail(near_miss_html())
        }) },
        "<latte-slot id=\"s0\"></latte-slot><latte-chunk for=\"s0\">a</latte-chunk><latte-seal for=\"s0\"></latte-seal>{near_miss_html()}"))

    out.push(new SSite(S_TAIL_UNFILLED, "a tail with two slots unfilled",
        fn() -> string { return doc_faults(fn(d: StreamDocument) {
            let _1: bool = d.head("{slot_placeholder("s0")}{slot_placeholder("s1")}", ["s0", "s1"])
            let _2: bool = d.tail("")
        }) },
        "the document ended with 2 slot(s) never filled: s0, s1",
        fn() -> string { return doc_faults(fn(d: StreamDocument) {
            let _1: bool = d.head("{slot_placeholder("s0")}{slot_placeholder("s1")}", ["s0", "s1"])
            let _2: bool = d.chunk("s0", "a")
            let _3: bool = d.chunk("s1", "b")
            let _4: bool = d.tail("")
        }) },
        fn() -> string { return doc_text(fn(d: StreamDocument) {
            let _1: bool = d.head("{slot_placeholder("s0")}{slot_placeholder("s1")}", ["s0", "s1"])
            let _2: bool = d.chunk("s0", "a")
            let _3: bool = d.chunk("s1", "b")
            let _4: bool = d.tail("")
        }) },
        "<latte-slot id=\"s0\"></latte-slot><latte-slot id=\"s1\"></latte-slot><latte-chunk for=\"s0\">a</latte-chunk><latte-seal for=\"s0\"></latte-seal><latte-chunk for=\"s1\">b</latte-chunk><latte-seal for=\"s1\"></latte-seal>"))

    // Every reader refusal funnels through one site. Ten shapes reach it, and
    // deleting that one push must turn all ten red.
    let sound: string = sound_document()
    out.push(reader_probe("cut before the seal", sound.slice(0, sound.len() - 6),
        "the chunk \"s0\" was never sealed, so a reader could never know it was whole"))
    out.push(reader_probe("cut inside the body", "<latte-chunk for=\"s0\">ab",
        "the stream ended inside the chunk \"s0\""))
    out.push(reader_probe("cut inside the opening tag", "<latte-chunk for=\"s0",
        "the stream ended inside a chunk's opening tag"))
    out.push(reader_probe("a seal for another slot",
        "<latte-chunk for=\"s0\">a</latte-chunk><latte-seal for=\"s9\"></latte-seal>",
        "the chunk \"s0\" is sealed as \"s9\""))
    out.push(reader_probe("no seal at all",
        "<latte-chunk for=\"s0\">a</latte-chunk><p>next</p>",
        "the chunk \"s0\" is not followed by its seal"))
    out.push(reader_probe("the same slot twice", "{sound}{sound}",
        "the chunk \"s0\" arrived twice"))
    out.push(reader_probe("an id with a space",
        "<latte-chunk for=\"a b\">x</latte-chunk><latte-seal for=\"a b\"></latte-seal>",
        "a chunk names \"a b\", which is not a usable slot id"))
    out.push(reader_probe("an empty id",
        "<latte-chunk for=\"\">x</latte-chunk><latte-seal for=\"\"></latte-seal>",
        "a chunk names \"\", which is not a usable slot id"))
    out.push(reader_probe("an opening tag that never names a slot",
        "<latte-chunk for=\"{"a".repeat(MAX_STREAM_ID + 8)}",
        "a chunk's opening tag runs past 64 bytes without naming a slot"))
    out.push(reader_probe("an id one byte too long",
        "<latte-chunk for=\"{"a".repeat(MAX_STREAM_ID + 1)}\">x</latte-chunk>",
        "a chunk names \"{"a".repeat(MAX_STREAM_ID + 1)}\", which is not a usable slot id"))

    out.push(new SSite(S_OPEN_TWICE, "a page opened twice",
        fn() -> string {
            let page: Small = new Small()
            let described: reflect.Type = type_of(Small)
            return page_faults(page, described, fn(sp: StreamPage) {
                let inner: reflect.Type = type_of(Small)
                let _1: string = sp.open(inner, "")
                let _2: string = sp.open(inner, "")
            })
        },
        "a streamed page is opened once, and this is the second",
        small_control, small_made, SMALL_HTML))

    out.push(new SSite(S_OPEN_BADNAME, "a region the author named \"a b\"",
        fn() -> string {
            let page: BadName = new BadName()
            let described: reflect.Type = type_of(BadName)
            return joined(opened(page, described).faults)
        },
        "the region named \"a b\" cannot be a slot id: one to 64 bytes of letters, digits, '-' and '_'",
        small_control, small_made, SMALL_HTML))

    out.push(new SSite(S_OPEN_DUPNAME, "two regions with one name",
        fn() -> string {
            let page: Twins = new Twins()
            let described: reflect.Type = type_of(Twins)
            return joined(opened(page, described).faults)
        },
        "two regions on this page are both named \"same\"",
        small_control, small_made, SMALL_HTML))

    out.push(new SSite(S_OPEN_NOMARK, "regions with no @stream",
        fn() -> string {
            let page: Unmarked = new Unmarked()
            let described: reflect.Type = type_of(Unmarked)
            return joined(opened(page, described).faults)
        },
        "latte$entry.Unmarked holds 1 streamed region(s) but is not annotated @stream, so nothing would ever fill them",
        small_control, small_made, SMALL_HTML))

    out.push(new SSite(S_OPEN_NOREGION, "@stream with nothing to defer",
        fn() -> string {
            let page: Barren = new Barren()
            let described: reflect.Type = type_of(Barren)
            return joined(opened(page, described).faults)
        },
        "latte$entry.Barren is annotated @stream but holds no StreamRegion, so it would be delivered in chunks that carry nothing",
        small_control, small_made, SMALL_HTML))

    out.push(new SSite(S_RESOLVE_UNKNOWN, "a slot this page never had",
        fn() -> string {
            let page: Small = new Small()
            let described: reflect.Type = type_of(Small)
            var sp: StreamPage = opened(page, described)
            let _: string = sp.resolve("not-a-slot")
            return joined(sp.faults)
        },
        "\"not-a-slot\" is not a region of this page",
        small_control, small_made, SMALL_HTML))

    out.push(new SSite(S_GONE, "a slot pointing at a mount that does not exist",
        fn() -> string {
            let page: Small = new Small()
            let described: reflect.Type = type_of(Small)
            var sp: StreamPage = opened(page, described)
            sp.regions["ghost"] = 99999
            let _: string = sp.resolve("ghost")
            return joined(sp.faults)
        },
        "the region \"ghost\" is no longer mounted",
        small_control, small_made, SMALL_HTML))

    out.push(new SSite(S_NOT_REGION, "a slot pointing at the page itself",
        fn() -> string {
            let page: Small = new Small()
            let described: reflect.Type = type_of(Small)
            var sp: StreamPage = opened(page, described)
            sp.regions["fake"] = 0
            let _: string = sp.resolve("fake")
            return joined(sp.faults)
        },
        "the region \"fake\" is no longer a StreamRegion",
        small_control, small_made, SMALL_HTML))

    out.push(new SSite(S_SERIALIZER, "a region whose raw text could close its <style>",
        fn() -> string {
            var page: RawStyle = new RawStyle()
            page.closer = true
            let described: reflect.Type = type_of(RawStyle)
            var sp: StreamPage = opened(page, described)
            for id: string in sp.pending() { let _: string = sp.resolve(id) }
            return joined(sp.faults)
        },
        "raw inside <style> could close it",
        fn() -> string {
            var page: RawStyle = new RawStyle()
            page.closer = false
            let described: reflect.Type = type_of(RawStyle)
            var sp: StreamPage = opened(page, described)
            for id: string in sp.pending() { let _: string = sp.resolve(id) }
            let _2: string = sp.close()
            return joined(sp.faults)
        },
        fn() -> string {
            var page: RawStyle = new RawStyle()
            page.closer = false
            let described: reflect.Type = type_of(RawStyle)
            return whole_page(page, described)
        },
        "<div><latte-slot id=\"s0\"></latte-slot></div><latte-chunk for=\"s0\"><style>.a\{color:red\}</style></latte-chunk><latte-seal for=\"s0\"></latte-seal>"))

    out.push(new SSite(S_CLOSE_EARLY, "a page closed before it was opened",
        fn() -> string {
            let page: Small = new Small()
            let r: Renderer = new Renderer()
            r.mount(page)
            var sp: StreamPage = new StreamPage(r)
            let _: string = sp.close()
            return joined(sp.faults)
        },
        "a streamed page was closed before it was opened",
        small_control, small_made, SMALL_HTML))

    return move out
}

// ================================================================== the run

fn main() {
    var r: Report = new Report()
    io.println("== 1 a streamed page and a buffered page ==")
    section_one(r)
    io.println("")
    io.println("== 2 every split of every shape ==")
    section_two(r)
    io.println("")
    io.println("== 3 the reader is incremental ==")
    section_three(r)
    io.println("")
    io.println("== 4 every fault site in stream.b ==")
    section_four(r)
    io.println("")
    io.println("== 5 the annotation, the scan and the assembler ==")
    section_five(r)
    io.println("")
    io.println("{r.checks} checks, {r.bad} bad")
}

// ============================================================== 1

fn streamed_dashboard() -> string {
    let page: Dashboard = new Dashboard()
    let described: reflect.Type = type_of(Dashboard)
    let r: Renderer = new Renderer()
    r.mount(page)
    var sp: StreamPage = new StreamPage(r)
    var out: string = sp.open(described, "</body></html>")
    for id: string in sp.pending() { out = "{out}{sp.resolve(id)}" }
    return "{out}{sp.close()}"
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

fn section_one(r: Report) {
    let page: Dashboard = new Dashboard()
    let described: reflect.Type = type_of(Dashboard)
    let renderer: Renderer = new Renderer()
    renderer.mount(page)
    var sp: StreamPage = new StreamPage(renderer)
    let head: string = sp.open(described, "</body></html>")
    let ids: List<string> = sp.slots()
    let listed: string = ids.join(", ")
    io.println("slots: {ids.len()} [{listed}]")
    io.println("head: {head}")
    r.eq("the slots, in mount order", listed, "s0, s1, footer")
    r.eq("the head carries a placeholder per slot", head,
        "<main id=\"app\"><h1>Sales</h1><latte-slot id=\"s0\"></latte-slot><aside><latte-slot id=\"s1\"></latte-slot></aside><latte-slot id=\"footer\"></latte-slot></main>")

    for id: string in ids {
        let piece: string = sp.resolve(id)
        io.println("chunk {id}: {piece}")
    }
    let tail: string = sp.close()
    io.println("tail: {tail}")
    r.eq("the tail is what the host handed in", tail, "</body></html>")
    r.yes("the page raised nothing", sp.ok())

    // The render counts. Resolving one region renders one component, and the
    // page itself renders ONCE for the whole stream — a framework that
    // re-rendered the page per chunk would still produce the right HTML.
    var counts: string = ""
    for id: int in renderer.ids() { counts = "{counts}{renderer.render_count(id)} " }
    io.println("render counts by mount order: {counts.trim()}")
    r.eq("one page render, and no extra pass for an author-named region",
        counts.trim(), "1 3 3 2")

    var faults: List<string> = []
    var reader: ChunkReader = new ChunkReader()
    reader.feed(streamed_dashboard())
    reader.finish()
    let rebuilt: string = assemble_chunks(reader.events, faults)
    let buffered: string = buffered_dashboard()
    io.println("assembly faults: {faults.len()}")
    r.eqi("the assembly raised nothing", faults.len(), 0)
    r.eq("a streamed page and a buffered page are the same page", rebuilt, buffered)
    io.println("streamed == buffered: {rebuilt == buffered}")
}

// ============================================================== 2

fn section_two(r: Report) {
    var total: int = 0
    let document: string = streamed_dashboard()
    total += sweep(r, "a real page, three chunks", document)

    var one: StreamDocument = new StreamDocument()
    let _1: bool = one.head("<p>a</p>{slot_placeholder("z")}", ["z"])
    let _2: bool = one.chunk("z", "<b>Z</b>")
    let _3: bool = one.tail("")
    total += sweep(r, "one chunk, no tail", one.text())

    var empty: StreamDocument = new StreamDocument()
    let _4: bool = empty.head(slot_placeholder("e"), ["e"])
    let _5: bool = empty.chunk("e", "")
    let _6: bool = empty.tail("<hr>")
    total += sweep(r, "an empty chunk", empty.text())

    var miss: StreamDocument = new StreamDocument()
    let _7: bool = miss.head("{near_miss_html()}{slot_placeholder("m")}", ["m"])
    let _8: bool = miss.chunk("m", near_miss_html())
    let _9: bool = miss.tail(near_miss_html())
    total += sweep(r, "near misses either side", miss.text())

    let long_id: string = "a".repeat(MAX_STREAM_ID)
    var edges: StreamDocument = new StreamDocument()
    let _10: bool = edges.head("{slot_placeholder("x")}|{slot_placeholder(long_id)}", ["x", long_id])
    let _11: bool = edges.chunk("x", "1")
    let _12: bool = edges.chunk(long_id, "2")
    let _13: bool = edges.tail("")
    total += sweep(r, "a 1-byte id and a 64-byte id", edges.text())

    var nested: StreamDocument = new StreamDocument()
    let _14: bool = nested.head("{slot_placeholder("p")}{slot_placeholder("q")}", ["p", "q"])
    let _15: bool = nested.chunk("p", slot_placeholder("q"))
    let _16: bool = nested.chunk("q", "<i>q</i>")
    let _17: bool = nested.tail("")
    total += sweep(r, "a chunk that contains another slot's placeholder", nested.text())

    io.println("two-way and uniform splits exercised: {total}")

    // Every THREE-way split of the shortest shape. Two cuts, not one, because
    // a reader can hold state across exactly one boundary by accident and
    // still be wrong across two.
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
    io.println("three-way splits of the {short.len()}-byte shape: {triples}")
    r.eqi("every three-way split agrees", triple_wrong, 0)
    r.yes("the three-way sweep is exhaustive", triples == (short.len() + 1) * (short.len() + 2) / 2)
}

/// Every two-way split and every uniform feed size. Answers how many splits
/// were exercised, and asserts none disagreed.
fn sweep(r: Report, label: string, text: string) -> int {
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
    io.println("{label}: {text.len()} bytes, {splits} splits")
    r.eqi("{label}: every split agrees", wrong, 0)
    r.yes("{label}: the sweep is exhaustive", splits == text.len() * 2 + 1)
    return splits
}

// ============================================================== 3

fn section_three(r: Report) {
    let document: string = streamed_dashboard()
    let one_feed: int = events_of(document, 0)
    let byte_feed: int = events_of(document, 1)
    io.println("events in one feed: {one_feed}, byte at a time: {byte_feed}")
    r.yes("a byte-at-a-time read is more events, so the reader is not a buffer",
        byte_feed > one_feed)
    let bound: int = MAX_STREAM_ID + 32
    let peak: int = peak_hold(document)
    io.println("peak hold {peak} bytes over a {document.len()}-byte document, bound {bound}")
    r.yes("the undecided hold stays inside its bound", peak <= bound)
    r.yes("and it is far short of the document", peak * 4 < document.len())
}

// ============================================================== 4

fn section_four(r: Report) {
    var reached: Map<string, int> = {}
    for probe: SSite in stream_sites() {
        let raised: string = probe.trip()
        let control: string = probe.control()
        let made: string = probe.made()
        io.println("-- {probe.name}")
        io.println("   site:    {probe.site}")
        io.println("   faults:  {raised}")
        r.eq("{probe.name}: the exact fault", raised, probe.want)
        r.eq("{probe.name}: the control raises nothing", control, "")
        r.eq("{probe.name}: and the control produced its document", made, probe.produced)
        r.no("{probe.name}: and what it produced is not empty", made == "")

        match reached.get(probe.site) {
            some(n) => { reached[probe.site] = n + 1 }
            none => { reached[probe.site] = 1 }
        }
    }

    var names: List<string> = reached.keys()
    names.sort()
    io.println("-- the sites in stream.b, and how many shapes reach each")
    for name: string in names {
        match reached.get(name) {
            some(n) => { io.println("   {n}x {name}") }
            none => {}
        }
    }
    r.eqi("every fault site in stream.b has a case", names.len(), 24)
}

// ============================================================== 5

fn section_five(r: Report) {
    let dashboard: reflect.Type = type_of(Dashboard)
    let unmarked: reflect.Type = type_of(Unmarked)
    let barren: reflect.Type = type_of(Barren)
    io.println("type_streams Dashboard {type_streams(dashboard)} Unmarked {type_streams(unmarked)} Barren {type_streams(barren)}")
    r.yes("@stream is visible on a page that carries it", type_streams(dashboard))
    r.no("and absent on one that does not", type_streams(unmarked))
    r.yes("and visible on a page with nothing to defer", type_streams(barren))

    let over_id: string = "a".repeat(MAX_STREAM_ID + 1)
    let limit_id: string = "a".repeat(MAX_STREAM_ID)
    io.println("stream_id_is_safe: empty {stream_id_is_safe("")} one {stream_id_is_safe("a")} limit {stream_id_is_safe(limit_id)} over {stream_id_is_safe(over_id)} space {stream_id_is_safe("a b")} quote {stream_id_is_safe("a\"b")} dash {stream_id_is_safe("a-b_0")}")
    r.no("an empty id", stream_id_is_safe(""))
    r.yes("one byte", stream_id_is_safe("a"))
    r.yes("exactly the limit", stream_id_is_safe(limit_id))
    r.no("one byte over", stream_id_is_safe(over_id))
    r.no("a space", stream_id_is_safe("a b"))
    r.no("a quote", stream_id_is_safe("a\"b"))
    r.yes("a dash, an underscore and a digit", stream_id_is_safe("a-b_0"))

    io.println("html_forges_framing: plain {html_forges_framing("<p>x</p>")} open {html_forges_framing("<latte-chunk for=\"a\">")} close {html_forges_framing("</latte-chunk>")} seal {html_forges_framing("<latte-seal for=\"a\">")} upper {html_forges_framing("</LATTE-CHUNK>")} near {html_forges_framing(near_miss_html())}")
    r.no("plain html forges nothing", html_forges_framing("<p>x</p>"))
    r.yes("an opening tag does", html_forges_framing("<latte-chunk for=\"a\">"))
    r.yes("a closing tag does", html_forges_framing("</latte-chunk>"))
    r.yes("a seal does", html_forges_framing("<latte-seal for=\"a\">"))
    r.yes("and case does not save it", html_forges_framing("</LATTE-CHUNK>"))
    r.no("escaped near-misses do not", html_forges_framing(near_miss_html()))

    // The generated ids step over the author's. Without the second pass the
    // first region takes "s0", the author's "s0" is refused as a duplicate,
    // and a page that is perfectly well formed does not render.
    let collide: Collide = new Collide()
    let collide_type: reflect.Type = type_of(Collide)
    var cpage: StreamPage = opened(collide, collide_type)
    let cids: List<string> = cpage.slots()
    let clisted: string = cids.join(", ")
    io.println("author's name and generated ones: [{clisted}]")
    r.eq("a generated id steps over the author's", clisted, "s1, s0, s2")
    var cdoc: string = cpage.doc.text()
    for id: string in cpage.pending() { cdoc = "{cdoc}{cpage.resolve(id)}" }
    cdoc = "{cdoc}{cpage.close()}"
    var cfaults: List<string> = []
    var creader: ChunkReader = new ChunkReader()
    creader.feed(cdoc)
    creader.finish()
    let assembled: string = assemble_chunks(creader.events, cfaults)
    io.println("  assembled {assembled}")
    r.eq("and it still assembles in place", assembled, "<div>firstnamed s0third</div>")
    r.eqi("with nothing raised", cfaults.len(), 0)
    r.yes("and the page is clean", cpage.ok())

    // `stream_scan` is the only thing in this program that would ever mention
    // NotAComponent.
    let scanned: List<string> = stream_scan()
    io.println("stream_scan found {scanned.len()}:")
    for fault: string in scanned { io.println("  {fault}") }
    r.eqi("one @stream in this program can never stream", scanned.len(), 1)
    r.eq("and the scan names it", scanned[0],
        "latte$entry.NotAComponent is annotated @stream but does not extend latte.Component, so it has nothing to stream")

    // The assembler's own two refusals. Neither is a `self.faults.push` site —
    // `assemble_chunks` reports into a caller's list — so they have no row in
    // the site table, and they still need a case.
    var orphan: List<ChunkEvent> = []
    orphan.push(ChunkEvent.markup("<p>no slot here</p>"))
    orphan.push(ChunkEvent.chunk_open("s0"))
    orphan.push(ChunkEvent.chunk_body("x"))
    orphan.push(ChunkEvent.chunk_sealed("s0", 1))
    orphan.push(ChunkEvent.done(1))
    var of: List<string> = []
    let orphan_text: string = assemble_chunks(orphan, of)
    r.eqi("a chunk with no placeholder is reported", of.len(), 1)
    r.eq("and named", joined(of), "the chunk \"s0\" has no placeholder to fill")
    r.eq("and the markup is left as it was", orphan_text, "<p>no slot here</p>")

    var unsealed: List<ChunkEvent> = []
    unsealed.push(ChunkEvent.markup(slot_placeholder("s0")))
    unsealed.push(ChunkEvent.chunk_open("s0"))
    unsealed.push(ChunkEvent.chunk_body("x"))
    unsealed.push(ChunkEvent.done(0))
    var uf: List<string> = []
    let unsealed_text: string = assemble_chunks(unsealed, uf)
    r.eqi("an unsealed chunk is reported", uf.len(), 1)
    r.eq("and named", joined(uf), "the chunk \"s0\" was never sealed")
    r.eq("and its placeholder is left standing", unsealed_text, slot_placeholder("s0"))

    // The control: a well-formed event list assembles and reports nothing.
    var good: List<ChunkEvent> = []
    good.push(ChunkEvent.markup(slot_placeholder("s0")))
    good.push(ChunkEvent.chunk_open("s0"))
    good.push(ChunkEvent.chunk_body("<b>x</b>"))
    good.push(ChunkEvent.chunk_sealed("s0", 8))
    good.push(ChunkEvent.done(1))
    var gf: List<string> = []
    r.eq("the control assembles", assemble_chunks(good, gf), "<b>x</b>")
    r.eqi("and reports nothing", gf.len(), 0)
}
