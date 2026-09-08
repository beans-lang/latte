// `latte.uploads` — the half of an upload that touches espresso.
//
// Like `latte.web`, this is a package under `latte/` and therefore may never
// name a type in the module root: no `Upload`, no `Component`, no `Builder`.
// It takes bytes and answers strings and records, and the application that
// imports both is where the two halves meet. That is also what keeps the
// module root free of espresso, and therefore still buildable for wasm.
//
// What it owns is the STORE. espresso parses the body and calls a sink per
// part; latte's store is what decides where those bytes go and, more
// importantly, what happens to them when the request does not finish.
//
// **The release is a `deinit`, and that is a decision.** `RULES.md` says
// anything that closes a socket is explicit teardown and never a destructor,
// because `deinit` may not park. Releasing a part does not park — it is a
// free, and one day a `remove`. The reason it MUST be a destructor is the
// third sentence of gate 8: a panic halfway through a handler unwinds the
// fiber, running its drops newest-first, and an explicit `release()` at the
// end of the handler is exactly the line a panic skips.
//
// **What is missing, and it is the point of `BLOCKERS.md` B12.** `std.fs` in
// 0.1.40 has read, write, append and copy, and no way to delete a file. So
// `PartHandle` holds its bytes in memory and its release is a drop rather than
// an unlink. Everything else — the generated id, the sink protocol, the
// release on the unwind, the accounting a test can read — is what a file-backed
// store needs, and the one line that would remove the file is marked below.
package uploads

import espresso
import std.io

/// Every open and every release, in order, for a test or a log to read.
///
/// It is a class rather than a counter because "two opened, two released" is
/// not the claim — the claim is that the SAME parts were released, and a
/// counter cannot tell that from one part released twice.
pub class ReleaseLog {
    pub lines: List<string> = []
    pub opened: int = 0
    pub released: int = 0

    pub fn init() {}

    pub fn open(id: string) {
        self.opened += 1
        self.lines.push("open {id}")
    }

    pub fn release(id: string) {
        self.released += 1
        self.lines.push("release {id}")
    }

    /// Every id opened and not released, in open order.
    pub fn leaked() -> List<string> {
        var live: List<string> = []
        for line: string in self.lines {
            if line.len() > 5 && line.slice(0, 5) == "open " {
                live.push(line.slice(5, line.len()))
            } else if line.len() > 8 && line.slice(0, 8) == "release " {
                let id: string = line.slice(8, line.len())
                var index: int = 0
                for index < live.len() {
                    if live[index] == id {
                        let _: string = live.remove(index)
                        break
                    }
                    index += 1
                }
            }
        }
        return move live
    }

    pub fn describe() -> string {
        return "opened={self.opened} released={self.released} leaked={self.leaked().len()}"
    }
}

/// The bytes of one part, and the release that must happen whatever else does.
///
/// It is the object whose destruction IS the release, which is why it holds
/// the log and the id rather than the sink doing it: a sink is finished or
/// discarded by the parser's own accounting, and gate 8's sentence is about
/// what happens when that accounting never gets to run.
pub class PartHandle {
    pub storage_id: string = ""
    log: ReleaseLog = new ReleaseLog()
    payload: Bytes = new Bytes(0)
    released: bool = false

    pub fn init(storage_id: string, log: ReleaseLog) {
        self.storage_id = storage_id
        self.log = log
        log.open(storage_id)
    }

    pub fn write(data: Bytes) {
        if self.released { return }
        self.payload.append(data)
    }

    pub fn size() -> int { return self.payload.len() }
    pub fn text() -> string { return self.payload.to_string() }

    /// Idempotent, because both the ordinary path and the unwind reach it and
    /// a release counted twice would read exactly like a release that leaked
    /// somewhere else.
    pub fn release() {
        if self.released { return }
        self.released = true
        // The file-backed line: `fs.remove(self.path)`. It is not written
        // because `std.fs` has no `remove` — BLOCKERS.md B12. Everything that
        // has to be true for it to be correct is true here already: it runs on
        // the unwind, it runs once, and it names the file by the id this
        // package generated and never by anything the client sent.
        self.payload = new Bytes(0)
        self.log.release(self.storage_id)
    }

    pub fn deinit() { self.release() }
}

/// espresso's sink, over a `PartHandle`.
pub class HandleSink implements espresso.PartSink {
    handle: PartHandle
    open: bool = true

    pub fn init(handle: PartHandle) { self.handle = handle }

    pub fn write(data: Bytes) -> Result<bool> {
        if !self.open { return err("this sink is already finished", "state") }
        self.handle.write(data)
        return ok(true)
    }

    pub fn finish() -> Result<Bytes> {
        if !self.open { return err("this sink is already finished", "state") }
        self.open = false
        // The bytes stay with the handle, so the record answers empty and
        // `size` on the part is authoritative — the shape espresso documents
        // for a sink that wrote them somewhere else.
        return ok(new Bytes(0))
    }

    pub fn discard() {
        self.open = false
        self.handle.release()
    }
}

/// A store that keeps a handle per part, and keeps them all so a caller can
/// still find the bytes after the parse.
pub class HandleStore implements espresso.PartStore {
    pub log: ReleaseLog = new ReleaseLog()
    pub handles: List<PartHandle> = []

    pub fn init(log: ReleaseLog) { self.log = log }

    pub fn open(part: espresso.PartInfo, storage_id: string) ->
        Result<espresso.PartSink> {
        let handle: PartHandle = new PartHandle(storage_id, self.log)
        self.handles.push(handle)
        return ok(new HandleSink(handle))
    }

    /// Release every handle this store opened, in reverse order. The ordinary
    /// end of a request; the unwind reaches the same `release` through
    /// `deinit`, which is why both are idempotent.
    pub fn release_all() {
        var index: int = self.handles.len() - 1
        for index >= 0 {
            self.handles[index].release()
            index -= 1
        }
    }
}

// ---------------------------------------------------------------- reading

/// What one body came to, as one line per part plus a verdict.
///
/// A STRING, deliberately. The two halves of latte cannot share a type, and a
/// canonical description is also the only shape a byte-split sweep can compare
/// cheaply: "the same body split anywhere yields the same events" becomes
/// "the same body split anywhere yields the same line".
pub fn describe_body(body: Bytes, content_type: string,
                     limits: espresso.MultipartLimits,
                     store: HandleStore, fields: List<string>) -> string {
    match espresso.MultipartParser.for_content_type(content_type, limits) {
        err(problem) => { return "refused: {problem.msg}" }
        ok(parser) => {
            var events: List<espresso.PartEvent> = []
            match parser.feed(body, events) {
                err(problem) => { return "refused: {problem.msg}" }
                ok(_) => {}
            }
            match parser.finish_into(events) {
                err(problem) => { return "refused: {problem.msg}" }
                ok(_) => {}
            }
            match espresso.collect_multipart(events, store) {
                err(problem) => { return "refused: {problem.msg}" }
                ok(form) => { return describe_form(form, store, fields) }
            }
        }
    }
}

/// The same, fed one byte at a time. Same answer or the parser is wrong.
pub fn describe_body_split(body: Bytes, content_type: string,
                           limits: espresso.MultipartLimits,
                           store: HandleStore, fields: List<string>,
                           at: int) -> string {
    match espresso.MultipartParser.for_content_type(content_type, limits) {
        err(problem) => { return "refused: {problem.msg}" }
        ok(parser) => {
            var events: List<espresso.PartEvent> = []
            var cut: int = at
            if cut < 0 { cut = 0 }
            if cut > body.len() { cut = body.len() }
            match parser.feed_into(body, 0, cut, events) {
                err(problem) => { return "refused: {problem.msg}" }
                ok(_) => {}
            }
            match parser.feed_into(body, cut, body.len(), events) {
                err(problem) => { return "refused: {problem.msg}" }
                ok(_) => {}
            }
            match parser.finish_into(events) {
                err(problem) => { return "refused: {problem.msg}" }
                ok(_) => {}
            }
            match espresso.collect_multipart(events, store) {
                err(problem) => { return "refused: {problem.msg}" }
                ok(form) => { return describe_form(form, store, fields) }
            }
        }
    }
}

/// Every scalar field and every file, in arrival order, with the sizes the
/// store recorded rather than the ones the form reports — so a store that
/// dropped bytes on a boundary shows up here as a different line.
//
// `fields` is the names the CALLER expects, because `QueryValues` keeps its
// name list private and offers no iteration — a page knows its own form, so
// this asks by name and also asserts the total count, which is what catches a
// part that arrived under a name nobody asked for.
fn describe_form(form: espresso.MultipartForm, store: HandleStore,
                 fields: List<string>) -> string {
    var out: List<string> = []
    out.push("fields={form.fields.count()}")
    for name: string in fields {
        for value: string in form.fields.all(name) {
            out.push("field {name}={value}")
        }
    }
    for file: espresso.UploadedFile in form.files {
        var stored: int = -1
        for handle: PartHandle in store.handles {
            if handle.storage_id == file.storage_id { stored = handle.size() }
        }
        // The storage id is random, so it cannot appear in a golden. What can
        // is that the file's id was one the store opened, which is the same
        // statement without the entropy.
        out.push("file {file.field} \"{file.submitted_filename}\" {file.declared_type} form={file.size} stored={stored}")
    }
    return out.join(" | ")
}
