// `latte.uploads` — the half of an upload that touches espresso.
//
// A package under `latte/`, so it may never name a module-root type (no
// `Upload`, `Component`, `Builder`), and the module root never imports
// espresso either — that is what keeps the module root buildable for wasm.
// It takes bytes and returns strings and records; the application that
// imports both this and the module root is where the two meet. It owns the
// store: espresso calls a sink per part, and the store decides where those
// bytes go and what happens to them if the request never finishes.
package uploads

import github.com/beans-lang/espresso
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

/// The bytes of one part, and the release that must happen no matter what
/// else does.
///
/// Destroying this object IS the release, which is why it holds the log and
/// the id rather than the sink doing it: a sink is finished or discarded by
/// the parser's own accounting, and this handle exists for what happens when
/// that accounting never runs — a panic mid-parse.
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
        // A file-backed store would remove the file here (`fs.remove(self.path)`);
        // this store is in-memory, so there is no file and it drops the
        // payload instead. Everything else a file-backed release needs is
        // already true: it runs on the unwind, it runs once, and it is keyed
        // by the id this package generated, never by anything the client sent.
        self.payload = new Bytes(0)
        self.log.release(self.storage_id)
    }

    /// `deinit` may not park, so this only frees memory, never
    /// a file or network wait. It still has to be the release point: a panic
    /// halfway through a handler unwinds the fiber and runs drops
    /// newest-first, which is exactly the moment an explicit `release()`
    /// call at the end of the handler would be skipped.
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

/// The same, but the body is fed as two writes split at byte `at` instead of
/// one. A caller that sweeps `at` from 0 to `body.len()` can confirm the
/// parser gives the same answer no matter where the network happened to cut
/// the stream.
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
        // The storage id is random, so it cannot appear in an expected output. What can
        // is that the file's id was one the store opened, which is the same
        // statement without the entropy.
        out.push("file {file.field} \"{file.submitted_filename}\" {file.declared_type} form={file.size} stored={stored}")
    }
    return out.join(" | ")
}
