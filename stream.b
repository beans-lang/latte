// Streaming rendering: a page whose slow regions arrive after the rest of it.
//
// A page opts in with `@stream`, per page rather than per component, so
// "this page must work without JavaScript" is a choice an author makes once.
// A region that is not ready renders as a placeholder,
// `<latte-slot id="s3"></latte-slot>`; its content follows later, at the end
// of the body, as `<latte-chunk for="s3">…</latte-chunk>`. A chunk is a
// custom element, never a script — `latte.js` holds a MutationObserver that
// moves the content into the placeholder and removes the wrapper, so the
// strict CSP (`script-src 'self'`, no `unsafe-inline`) needs nothing loosened
// for streaming.
//
// ## The seal, and why it exists
//
// A MutationObserver watching the body sees `<latte-chunk>` the moment the
// parser opens it — long before its content is complete, since the bytes
// after it are still arriving. Moving the content then would move a fragment
// of it and silently lose the rest, for exactly the chunks that straddled a
// network boundary. So each chunk is followed by
// `<latte-seal for="s3"></latte-seal>`: the HTML parser cannot insert the
// seal until it has read `</latte-chunk>`, so a seal in the DOM is the
// parser's own proof that the chunk before it is whole. It costs 30 bytes per
// chunk and is the only such signal available without an inline script.
//
// Nothing here does I/O. `StreamDocument` produces bytes and `ChunkReader`
// consumes them; writing them to a socket is the host's business (espresso's
// `context.begin_stream()`), which keeps this file inside the module root
// and the wasm leg green.
package latte

import std.fmt
import std.reflect

// ============================================================== the annotation

/// This page is delivered as chunks: its `StreamRegion`s render as
/// placeholders and their content follows.
///
/// `@target` and `@retention` for the reason the four in `pages.b` carry them:
/// a scan that cannot see an annotation at runtime is not a scan, and `@stream`
/// on a function should be a compile error in the author's own file rather than
/// a page that quietly never streams.
@target(value: ["type"])
@retention(value: "runtime")
pub annotation stream {}

// ============================================================== the vocabulary

/// The placeholder a region leaves behind on the first pass.
pub const SLOT_TAG: string = "latte-slot"
/// The wrapper a region's content arrives in.
pub const CHUNK_TAG: string = "latte-chunk"
/// The element whose presence proves the chunk before it is complete.
pub const SEAL_TAG: string = "latte-seal"

/// The longest slot id the framing will carry.
///
/// It bounds what a reader must hold before it can decide, which is the same
/// reason espresso's multipart parser bounds its boundary padding: a reader
/// with no bound on an unterminated header is a reader that buffers the
/// internet.
pub const MAX_STREAM_ID: int = 64

const OPEN_HEAD: string = "<latte-chunk for=\""
const OPEN_TAIL: string = "\">"
const CLOSE_MARK: string = "</latte-chunk>"
const SEAL_HEAD: string = "<latte-seal for=\""
const SEAL_TAIL: string = "\"></latte-seal>"

/// Whether `id` may be written into the framing.
///
/// Letters, digits, `-` and `_`, one to `MAX_STREAM_ID` bytes. The set is
/// narrow on purpose: an id is written into an attribute value on the way out
/// and read back out of one on the way in, and a set that excluded nothing
/// would make the two halves disagree about where the id ends. Latte generates
/// these itself (`s0`, `s1`, …), so nothing legitimate is refused here — it is
/// the guard for an id a host chose.
pub fn stream_id_is_safe(id: string) -> bool {
    if id.len() == 0 || id.len() > MAX_STREAM_ID { return false }
    for index: int in 0..id.len() {
        let byte: int = id.byte_at(index)
        let digit: bool = byte >= 48 && byte <= 57
        let lower: bool = byte >= 97 && byte <= 122
        let upper: bool = byte >= 65 && byte <= 90
        let punct: bool = byte == 45 || byte == 95
        if !digit && !lower && !upper && !punct { return false }
    }
    return true
}

/// Whether `html` could be mistaken for the framing itself.
///
/// A chunk's content is serialized latte HTML, so a text node's `<` is already
/// `&lt;` by the time it gets here. What can still carry a raw `<` is `raw`
/// (`$html`, the named, greppable bypass) and `constant`. A `$html` expression
/// that returned `</latte-chunk>` would end its own chunk early and hand the
/// rest of the page to the reader as document text — so the emitter refuses it
/// rather than the reader guessing.
///
/// Case-insensitive, because an HTML parser closes `<LATTE-CHUNK>` with
/// `</LATTE-CHUNK>` and a case-sensitive test would be a hole the size of one
/// shift key.
pub fn html_forges_framing(html: string) -> bool {
    let lowered: string = html.to_lower()
    return lowered.contains("</{CHUNK_TAG}") || lowered.contains("<{SEAL_TAG}") ||
           lowered.contains("<{CHUNK_TAG}")
}

// ============================================================ the region

/// A region whose content arrives in a later chunk.
///
/// Its first render writes the placeholder; once `ready` is true it renders
/// its body instead. Streaming a region is therefore an ordinary component
/// with a branch in `render`, so it needs no special case anywhere in the
/// builder, the serializer, the differ or the applier — a chunk arriving is
/// a branch flip, and a branch flip is something all four already do.
///
/// The two arms carry DIFFERENT sequence numbers, which is what the markup
/// compiler emits for an `if` (see the generated `examples/counter.b`). The
/// same number on both arms would ask the differ to turn an element into a
/// fragment in place, and a kind-mismatched edit is refused.
pub class StreamRegion extends Component {
    /// The slot id. `StreamPage` assigns these; an author never writes one.
    pub sid: string = ""
    /// The content, as the markup compiler's child-content closure.
    pub body: fn(Builder) = fn(b: Builder) {}
    /// False until the chunk carrying this region has been produced.
    pub ready: bool = false

    pub fn init() {}

    pub override fn render(b: Builder) {
        if self.ready {
            b.fragment(1, self.body)
            return
        }
        b.open(0, SLOT_TAG)
        b.attr(1, "id", self.sid)
        b.close()
    }
}

// ============================================================ the document

/// The bytes of a streamed page, assembled in the order they go on the wire.
///
/// It is a text producer and nothing else: no socket, no fiber, no espresso.
/// A host writes `head()`, then each `chunk()`, then `tail()`, through whatever
/// chunked writer it has.
pub class StreamDocument {
    /// Everything refused. A document with faults is not a document to send.
    pub faults: List<string> = []
    /// The slot ids, in the order the page's first pass reached them.
    pub slots: List<string> = []

    filled: Map<string, bool> = {}
    opened: bool = false
    closed: bool = false
    out: fmt.StringBuilder = new fmt.StringBuilder()

    pub fn init() {}

    pub fn ok() -> bool { return self.faults.len() == 0 }

    /// The page's first pass, with a placeholder wherever a region was not
    /// ready. `ids` is every slot this document promises to fill.
    pub fn head(html: string, ids: List<string>) -> bool {
        if self.opened {
            self.faults.push("a streamed document has one head, and this is the second")
            return false
        }
        self.opened = true
        for id: string in ids {
            if !stream_id_is_safe(id) {
                self.faults.push("\"{id}\" is not a usable slot id: one to {MAX_STREAM_ID} bytes of letters, digits, '-' and '_'")
                return false
            }
            if self.filled.contains_key(id) {
                self.faults.push("the slot \"{id}\" is promised twice by one page")
                return false
            }
            self.filled[id] = false
            self.slots.push(id)
        }
        if html_forges_framing(html) {
            self.faults.push("the page's head carries chunk framing of its own, so a reader could not tell it from a real chunk")
            return false
        }
        self.out.push(html)
        return true
    }

    /// One region's content, wrapped and sealed.
    pub fn chunk(id: string, html: string) -> bool {
        if !self.opened {
            self.faults.push("the chunk for \"{id}\" was written before the page's head")
            return false
        }
        if self.closed {
            self.faults.push("the chunk for \"{id}\" was written after the document ended")
            return false
        }
        match self.filled.get(id) {
            none => {
                self.faults.push("\"{id}\" is not a slot this page left open")
                return false
            }
            some(already) => {
                if already {
                    self.faults.push("the slot \"{id}\" was filled twice")
                    return false
                }
            }
        }
        if html_forges_framing(html) {
            self.faults.push("the chunk for \"{id}\" carries chunk framing of its own, which would end it early and hand the rest of the page to the reader as document text")
            return false
        }
        self.filled[id] = true
        self.out.push(OPEN_HEAD)
        self.out.push(id)
        self.out.push(OPEN_TAIL)
        self.out.push(html)
        self.out.push(CLOSE_MARK)
        self.out.push(SEAL_HEAD)
        self.out.push(id)
        self.out.push(SEAL_TAIL)
        return true
    }

    /// The end of the body.
    ///
    /// A slot with no chunk is REFUSED here rather than shipped. A forgotten
    /// chunk is a placeholder that stays on the page for ever — an empty box
    /// where the report was, with a 200 already on the wire and nothing in any
    /// log. It is the streaming twin of espresso's forgotten terminator.
    pub fn tail(html: string) -> bool {
        if !self.opened {
            self.faults.push("a streamed document ended before it had a head")
            return false
        }
        if self.closed {
            self.faults.push("a streamed document ends once, and this is the second end")
            return false
        }
        self.closed = true
        if html_forges_framing(html) {
            self.faults.push("the page's tail carries chunk framing of its own, so a reader could not tell it from a real chunk")
            return false
        }
        var missing: List<string> = []
        for id: string in self.slots {
            match self.filled.get(id) {
                some(done) => { if !done { missing.push(id) } }
                none => {}
            }
        }
        if missing.len() > 0 {
            let listed: string = missing.join(", ")
            self.faults.push("the document ended with {missing.len()} slot(s) never filled: {listed}")
            return false
        }
        self.out.push(html)
        return true
    }

    /// Everything written so far.
    pub fn text() -> string { return self.out.to_string() }
}

// ============================================================ the reader

/// What a reader hands back, in order: any number of `markup` pieces, then per
/// chunk a `chunk_open`, any number of `chunk_body` pieces and one
/// `chunk_sealed`, then more `markup`, and exactly one `done`.
///
/// How the text divides into `markup` and `chunk_body` events depends on how
/// the bytes arrived. What those events CONCATENATE to does not — checked
/// the same way espresso's multipart parser is: feed the same bytes split at
/// different points and compare.
pub enum ChunkEvent {
    markup(text: string)
    chunk_open(id: string)
    chunk_body(html: string)
    chunk_sealed(id: string, bytes: int)
    done(chunks: int)
}

const READ_TEXT: int = 0
const READ_ID: int = 1
const READ_BODY: int = 2
const READ_SEAL: int = 3
const READ_FAILED: int = 4

/// The model of what `latte.js`'s MutationObserver does, as a push parser.
///
/// It is the SERVER's statement that its own framing is unambiguous under any
/// split: a reader that has seen only a prefix can always say whether a chunk
/// is complete, and can never be talked into a different answer by where the
/// bytes were cut.
///
/// It holds an UNDECIDED TAIL and nothing else — at most one marker's length
/// minus one byte of text, plus the id it is reading. A reader that buffered
/// the whole document and parsed it at the end would pass a byte-split test
/// without proving anything at all, which is why the hold is bounded and
/// `held()` is public so a test can assert it.
pub class ChunkReader {
    pub faults: List<string> = []
    pub events: List<ChunkEvent> = []

    state: int = READ_TEXT
    hold: string = ""
    current: string = ""
    current_bytes: int = 0
    chunks: int = 0
    seen: Map<string, bool> = {}
    finished: bool = false

    pub fn init() {}

    pub fn ok() -> bool { return self.faults.len() == 0 }

    /// How many undecided bytes are held right now.
    pub fn held() -> int { return self.hold.len() }

    /// Push bytes. Any split of the same input must produce the same events.
    pub fn feed(data: string) {
        if self.state == READ_FAILED { return }
        if self.finished {
            self.refuse("bytes arrived after the stream was finished")
            return
        }
        self.hold = "{self.hold}{data}"
        for self.step() {}
    }

    /// No more bytes are coming.
    pub fn finish() {
        if self.state == READ_FAILED { return }
        if self.finished {
            self.refuse("a stream is finished once, and this is the second")
            return
        }
        self.finished = true
        for self.step() {}
        if self.state == READ_TEXT {
            if self.hold.len() > 0 {
                self.events.push(ChunkEvent.markup(self.hold))
                self.hold = ""
            }
            self.events.push(ChunkEvent.done(self.chunks))
            return
        }
        if self.state == READ_ID {
            self.refuse("the stream ended inside a chunk's opening tag")
            return
        }
        if self.state == READ_BODY {
            self.refuse("the stream ended inside the chunk \"{self.current}\"")
            return
        }
        self.refuse("the chunk \"{self.current}\" was never sealed, so a reader could never know it was whole")
    }

    fn refuse(problem: string) {
        self.faults.push(problem)
        self.state = READ_FAILED
        self.hold = ""
    }

    // One decision. Answers whether it made progress, so `feed` can run it to
    // a standstill.
    fn step() -> bool {
        if self.state == READ_TEXT { return self.step_text() }
        if self.state == READ_ID { return self.step_id() }
        if self.state == READ_BODY { return self.step_body() }
        if self.state == READ_SEAL { return self.step_seal() }
        return false
    }

    fn step_text() -> bool {
        match self.hold.find(OPEN_HEAD) {
            some(at) => {
                if at > 0 { self.events.push(ChunkEvent.markup(self.hold.slice(0, at))) }
                self.hold = self.hold.slice(at + OPEN_HEAD.len(), self.hold.len())
                self.state = READ_ID
                return true
            }
            none => {}
        }
        // No marker. Everything but a possible partial marker at the end is
        // decided text, and holding exactly `OPEN_HEAD.len() - 1` bytes is the
        // smallest hold that cannot cut one in half.
        let keep: int = OPEN_HEAD.len() - 1
        if self.hold.len() <= keep { return false }
        let cut: int = self.hold.len() - keep
        self.events.push(ChunkEvent.markup(self.hold.slice(0, cut)))
        self.hold = self.hold.slice(cut, self.hold.len())
        return false
    }

    fn step_id() -> bool {
        match self.hold.find(OPEN_TAIL) {
            some(at) => {
                let id: string = self.hold.slice(0, at)
                if !stream_id_is_safe(id) {
                    self.refuse("a chunk names \"{id}\", which is not a usable slot id")
                    return false
                }
                if self.seen.contains_key(id) {
                    self.refuse("the chunk \"{id}\" arrived twice")
                    return false
                }
                self.seen[id] = true
                self.hold = self.hold.slice(at + OPEN_TAIL.len(), self.hold.len())
                self.current = id
                self.current_bytes = 0
                self.state = READ_BODY
                self.events.push(ChunkEvent.chunk_open(id))
                return true
            }
            none => {}
        }
        if self.hold.len() > MAX_STREAM_ID + OPEN_TAIL.len() {
            self.refuse("a chunk's opening tag runs past {MAX_STREAM_ID} bytes without naming a slot")
            return false
        }
        return false
    }

    fn step_body() -> bool {
        match self.hold.find(CLOSE_MARK) {
            some(at) => {
                if at > 0 {
                    self.events.push(ChunkEvent.chunk_body(self.hold.slice(0, at)))
                    self.current_bytes += at
                }
                self.hold = self.hold.slice(at + CLOSE_MARK.len(), self.hold.len())
                self.state = READ_SEAL
                return true
            }
            none => {}
        }
        let keep: int = CLOSE_MARK.len() - 1
        if self.hold.len() <= keep { return false }
        let cut: int = self.hold.len() - keep
        self.events.push(ChunkEvent.chunk_body(self.hold.slice(0, cut)))
        self.current_bytes += cut
        self.hold = self.hold.slice(cut, self.hold.len())
        return false
    }

    fn step_seal() -> bool {
        let want: string = "{SEAL_HEAD}{self.current}{SEAL_TAIL}"
        if self.hold.len() < want.len() {
            // Still a prefix of the seal: wait. Already diverged: refuse now,
            // at the first byte that decided it, so the answer cannot depend
            // on where the input was cut.
            if want.starts_with(self.hold) { return false }
            self.refuse_seal()
            return false
        }
        if !self.hold.starts_with(want) {
            self.refuse_seal()
            return false
        }
        self.hold = self.hold.slice(want.len(), self.hold.len())
        self.chunks += 1
        self.events.push(ChunkEvent.chunk_sealed(self.current, self.current_bytes))
        self.state = READ_TEXT
        return true
    }

    // Two different mistakes, and a reader that reported one message for both
    // would send the author looking in the wrong place: a seal for the wrong
    // slot is a bookkeeping bug in the host, and no seal at all is a writer
    // that forgot it.
    fn refuse_seal() {
        if self.hold.starts_with(SEAL_HEAD) {
            let rest: string = self.hold.slice(SEAL_HEAD.len(), self.hold.len())
            match rest.find("\"") {
                some(at) => {
                    self.refuse("the chunk \"{self.current}\" is sealed as \"{rest.slice(0, at)}\"")
                    return
                }
                none => {}
            }
        }
        self.refuse("the chunk \"{self.current}\" is not followed by its seal")
    }
}

/// The events, normalised: what they concatenate to, which is the part that
/// must not depend on how the bytes arrived.
pub fn describe_chunk_events(events: List<ChunkEvent>) -> string {
    var out: fmt.StringBuilder = new fmt.StringBuilder()
    var text: string = ""
    var body: string = ""
    for event: ChunkEvent in events {
        match event {
            markup(piece) => { text = "{text}{piece}" }
            chunk_open(id) => {
                if text != "" { out.push("markup[{text}] ") }
                text = ""
                body = ""
                out.push("open[{id}] ")
            }
            chunk_body(piece) => { body = "{body}{piece}" }
            chunk_sealed(id, bytes) => {
                out.push("body[{body}] sealed[{id} {bytes}] ")
                body = ""
            }
            done(chunks) => {
                if text != "" { out.push("markup[{text}] ") }
                text = ""
                out.push("done[{chunks}]")
            }
        }
    }
    return out.to_string()
}

/// The placeholder a not-yet-ready region serializes to, byte for byte.
///
/// Written here rather than spelled twice, because the assembler below has to
/// find exactly what `StreamRegion.render` produced and two hand-written copies
/// of one string is how a framework loses a chunk in production and nowhere
/// else.
pub fn slot_placeholder(id: string) -> string {
    return "<{SLOT_TAG} id=\"{id}\"></{SLOT_TAG}>"
}

/// What a browser is left holding: the document text with each placeholder
/// replaced by its chunk's content, and the wrappers gone.
///
/// This is the Beans model of what `latte.js`'s MutationObserver does, and it
/// exists so the two halves can be judged against ONE answer — the browser leg
/// diffs Chrome's DOM against this, exactly the way the two appliers are
/// judged against one HTML string.
///
/// A chunk whose placeholder is not in the document is a fault and not a
/// silent drop: it means the head and the chunks disagree about a name, which
/// is a page with a hole in it.
pub fn assemble_chunks(events: List<ChunkEvent>, faults: List<string>) -> string {
    var text: string = ""
    var ids: List<string> = []
    var bodies: Map<string, string> = {}
    var current: string = ""
    var body: string = ""
    for event: ChunkEvent in events {
        match event {
            markup(piece) => { text = "{text}{piece}" }
            chunk_open(id) => {
                current = id
                body = ""
            }
            chunk_body(piece) => { body = "{body}{piece}" }
            chunk_sealed(id, _) => {
                ids.push(id)
                bodies[id] = body
                body = ""
                current = ""
            }
            done(_) => {}
        }
    }
    if current != "" { faults.push("the chunk \"{current}\" was never sealed") }
    for id: string in ids {
        let hole: string = slot_placeholder(id)
        if !text.contains(hole) {
            faults.push("the chunk \"{id}\" has no placeholder to fill")
            continue
        }
        match bodies.get(id) {
            some(html) => { text = text.replace(hole, html) }
            none => {}
        }
    }
    return text
}

// ============================================================ the scan

/// Whether a type is annotated `@stream`.
///
/// It takes a `reflect.Type` and not a `Component` on purpose. `reflect.value`
/// boxes the STATIC type of what it is handed (BLOCKERS.md B6), so a
/// `Component` binding would report `latte.Component` — which carries no
/// `@stream` — and every page would quietly answer "no". The host already
/// holds the type: `PagePlan.type_name` names it, and a program that mounts a
/// page directly writes `type_of(MyPage)` on a line of its own (B10: a type
/// name inside a string interpolation resolves without the file's imports).
pub fn type_streams(described: reflect.Type) -> bool {
    return annotations_named(described.annotations(), "stream").len() > 0
}

/// Every `@stream` in the program that could never do anything, by name.
///
/// One walk of `reflect.types()`, the same registry `scan_pages` uses. A
/// `@stream` on a type that is not a `Component` is a typo with no effect, and
/// silence is how an author ends up believing a page streams when it cannot.
pub fn stream_scan() -> List<string> {
    var faults: List<string> = []
    let component_name: string = type_of(Component).qualified_name()
    for described: reflect.Type in reflect.types() {
        if !type_streams(described) { continue }
        if !extends_named(described, component_name) {
            faults.push(
                "{described.qualified_name()} is annotated @stream but does not extend {component_name}, so it has nothing to stream")
        }
    }
    return move faults
}

// ============================================================ the page

/// A page delivered as chunks.
///
/// It owns the order — head, then one chunk per region, then the tail — and
/// nothing about how the bytes travel. A host writes each piece as it comes
/// back; in a test they go into a string, and the bytes are identical either
/// way, which is why this file can be gated at all.
pub class StreamPage {
    pub renderer: Renderer
    pub doc: StreamDocument = new StreamDocument()
    /// Slot id -> component id, for every region on this page.
    pub regions: Map<string, int> = {}
    /// Anything refused before a byte was produced.
    pub faults: List<string> = []

    order: List<string> = []
    /// The ids latte generated, as opposed to the ones an author wrote.
    made: Map<string, bool> = {}
    sent: Map<string, bool> = {}
    tail_text: string = ""
    started: bool = false

    pub fn init(renderer: Renderer) { self.renderer = renderer }

    pub fn ok() -> bool { return self.faults.len() == 0 && self.doc.ok() }

    /// Every slot id this page holds, in mount order.
    pub fn slots() -> List<string> { return self.order.clone() }

    /// The slots whose chunk has not been produced.
    pub fn pending() -> List<string> {
        var out: List<string> = []
        for id: string in self.order {
            if !self.sent.contains_key(id) { out.push(id) }
        }
        return move out
    }

    /// The first pass: every region is a placeholder, and the page's HTML is
    /// the head. `tail` is whatever closes the body, held until `close()`.
    ///
    /// Two refusals, and they are opposite halves of one rule — the annotation
    /// and the regions must agree:
    ///
    ///   * regions and no `@stream`: the placeholders would never be filled,
    ///     and with JavaScript off that is a blank box with a 200 on it;
    ///   * `@stream` and no regions: the author asked for streaming and the
    ///     page has nothing to defer, so the annotation is a belief nothing
    ///     holds up.
    pub fn open(page_type: reflect.Type, tail: string) -> string {
        if self.started {
            self.faults.push("a streamed page is opened once, and this is the second")
            return ""
        }
        self.started = true
        self.tail_text = tail

        // Two passes, and the second one is why. An author may name a region
        // (`<StreamRegion sid="footer">`); latte names the rest. Numbering the
        // unnamed ones in ONE pass would let a generated `s1` collide with an
        // author's `s1` that had not been reached yet, and the collision would
        // be reported as the author's mistake — or, worse, silently give two
        // regions one placeholder. So the author's names are collected first
        // and the generator steps over every one of them.
        var found: List<int> = []
        var taken: Map<string, bool> = {}
        for id: int in self.renderer.ids() {
            match self.renderer.component(id) {
                none => {}
                some(component) => {
                    match component as? StreamRegion {
                        none => {}
                        some(region) => {
                            found.push(id)
                            if region.sid != "" { taken[region.sid] = true }
                        }
                    }
                }
            }
        }

        var generated: int = 0
        for id: int in found {
            match self.renderer.component(id) {
                none => {}
                some(component) => {
                    match component as? StreamRegion {
                        none => {}
                        some(region) => {
                            if region.sid == "" {
                                var candidate: string = "s{generated}"
                                for taken.contains_key(candidate) {
                                    generated += 1
                                    candidate = "s{generated}"
                                }
                                region.sid = candidate
                                taken[candidate] = true
                                self.made[candidate] = true
                                generated += 1
                            }
                            if !stream_id_is_safe(region.sid) {
                                self.faults.push(
                                    "the region named \"{region.sid}\" cannot be a slot id: one to {MAX_STREAM_ID} bytes of letters, digits, '-' and '_'")
                                return ""
                            }
                            if self.regions.contains_key(region.sid) {
                                self.faults.push(
                                    "two regions on this page are both named \"{region.sid}\"")
                                return ""
                            }
                            region.ready = false
                            self.regions[region.sid] = id
                            self.order.push(region.sid)
                        }
                    }
                }
            }
        }

        let streams: bool = type_streams(page_type)
        let named: string = page_type.qualified_name()
        if self.order.len() > 0 && !streams {
            self.faults.push(
                "{named} holds {self.order.len()} streamed region(s) but is not annotated @stream, so nothing would ever fill them")
            return ""
        }
        if self.order.len() == 0 && streams {
            self.faults.push(
                "{named} is annotated @stream but holds no StreamRegion, so it would be delivered in chunks that carry nothing")
            return ""
        }

        // A GENERATED id was assigned after the mount, so the placeholder that
        // mount wrote still carries the empty string. Render those regions
        // again with the id in place — and only those: a region the author
        // named already wrote the right placeholder, and re-rendering it would
        // be a render pass this page does not need. `tests/w6_stream.b` prints
        // the per-component render counts, so the difference is a number in a
        // golden rather than a claim here.
        for id: string in self.order {
            if self.made.contains_key(id) { self.mark(id) }
        }
        let _: int = self.renderer.flush()

        let head: string = self.renderer.html()
        let _: bool = self.doc.head(head, self.order)
        return head
    }

    /// Release one region: render it for real, and answer the bytes of its
    /// chunk.
    pub fn resolve(id: string) -> string {
        match self.regions.get(id) {
            none => {
                self.faults.push("\"{id}\" is not a region of this page")
                return ""
            }
            some(component_id) => { return self.emit(id, component_id) }
        }
    }

    // A region the renderer no longer holds, reported once for both lookups
    // that can find it gone.
    //
    // ONE site and not two, because `Renderer.component` and `Renderer.buffer`
    // read the same mount map: a "component is gone" and a "buffer is gone"
    // that could differ would be two answers to one question. Two sites here
    // would also mean one of them could never be reached, and an unreachable
    // refusal is a message nobody ever reads.
    fn gone(id: string) -> string {
        self.faults.push("the region \"{id}\" is no longer mounted")
        return ""
    }

    fn emit(id: string, component_id: int) -> string {
        var region: Option<StreamRegion> = none
        match self.renderer.component(component_id) {
            none => { return self.gone(id) }
            some(component) => { region = component as? StreamRegion }
        }
        match region {
            none => {
                // Reachable, and only through `regions`, which is public: a
                // host that writes its own slot table can point a slot at a
                // component that is not a region. It is checked rather than
                // downcast-and-hope because the alternative is a page that
                // silently never fills that slot.
                self.faults.push("the region \"{id}\" is no longer a StreamRegion")
                return ""
            }
            some(live) => {
                live.ready = true
                live.notify()
            }
        }
        let _: int = self.renderer.flush()
        match self.renderer.buffer(component_id) {
            none => { return self.gone(id) }
            some(buffer) => {
                let writer: Serializer = new Serializer()
                let html: string = writer.component(buffer)
                for fault: string in writer.faults { self.faults.push(fault) }
                let before: int = self.doc.text().len()
                if !self.doc.chunk(id, html) { return "" }
                self.sent[id] = true
                let whole: string = self.doc.text()
                return whole.slice(before, whole.len())
            }
        }
    }

    /// The end of the body. Refuses a page with a region nobody resolved.
    pub fn close() -> string {
        if !self.started {
            self.faults.push("a streamed page was closed before it was opened")
            return ""
        }
        let before: int = self.doc.text().len()
        if !self.doc.tail(self.tail_text) { return "" }
        let whole: string = self.doc.text()
        return whole.slice(before, whole.len())
    }

    fn mark(id: string) {
        match self.regions.get(id) {
            some(component_id) => {
                match self.renderer.component(component_id) {
                    some(component) => { component.notify() }
                    none => {}
                }
            }
            none => {}
        }
    }
}
