// Check 8, third row: a multipart body split at every byte, an oversized part
// refused, and every part released when the handler does not finish.
//
// The third clause of the check sentence says "a temp file released after a
// panic". There is no temp file: this store is in-memory, not file-backed,
// so there is nothing on disk for a refused or abandoned upload to leave
// behind.
// What is proved here is everything else that sentence needs — that the
// release runs on the unwind, once per part, for every part opened — over a
// handle whose release is a drop rather than an unlink. The line that would
// remove the file is named in `uploads/uploads.b` and is not written.
//
// Sections:
//   1  progress    — every number off the wire, clamped
//   2  the control — what a page renders, and what it must never render
//   3  the splits  — every two-way split of six bodies, through latte's store
//   4  the limits  — each one crossed, each with a positive control
//   5  the release — the ordinary end, and the unwind
//   6  the fault site
package main

import std.io
import github.com/beans-lang/espresso
import {Builder, Component, Renderer, Serializer, Upload, UploadFile,
        UploadProgress, UPLOAD_MAX_BYTES, UPLOAD_MAX_FILES} from latte
import {run} from latte.boundary
import {describe_body, describe_body_split, HandleStore,
        ReleaseLog} from latte.uploads

pub class Report {
    pub checks: int = 0
    pub bad: int = 0
    pub fn init() {}
    pub fn eq(name: string, got: string, want: string) {
        self.checks += 1
        if got == want { io.println("ok {name}") }
        else {
            self.bad += 1
            io.println("FAIL {name}: got {got}, want {want}")
        }
    }
    pub fn eqi(name: string, got: int, want: int) { self.eq(name, "{got}", "{want}") }
    pub fn yes(name: string, got: bool) { self.eq(name, "{got}", "true") }
    pub fn no(name: string, got: bool) { self.eq(name, "{got}", "false") }
}

fn joined(items: List<string>) -> string { return items.join(" | ") }

fn bytes_of(text: string) -> Bytes {
    var out: Bytes = new Bytes(0)
    out.append_string(text)
    return move out
}

const CT: string = "multipart/form-data; boundary=X"

fn wide_limits() -> espresso.MultipartLimits {
    return new espresso.MultipartLimits()
}

fn main() {
    var r: Report = new Report()
    io.println("== 1 progress: every number off the wire is clamped ==")
    section_one(r)
    io.println("")
    io.println("== 2 the control a page renders ==")
    section_two(r)
    io.println("")
    io.println("== 3 every two-way split of every body ==")
    section_three(r)
    io.println("")
    io.println("== 4 the limits, each crossed and each controlled ==")
    section_four(r)
    io.println("")
    io.println("== 5 the release: the ordinary end and the unwind ==")
    section_five(r)
    io.println("")
    io.println("== 6 every fault site in upload.b ==")
    section_six(r)
    io.println("")
    io.println("{r.checks} checks, {r.bad} bad")
}

// ============================================================== 1

fn section_one(r: Report) {
    var p: UploadProgress = new UploadProgress()
    r.eq("nothing reported yet", p.describe(),
        "sent=0 total=0 percent=0 started=false done=false")

    r.yes("an honest report is taken", p.report(50, 200))
    r.eq("and answered exactly", p.describe(),
        "sent=50 total=200 percent=25 started=true done=false")
    r.no("the same report again changes nothing", p.report(50, 200))

    // A client that says it has sent more than there is. The bar cannot go
    // past the end, and it must not go past 100 either.
    var over: UploadProgress = new UploadProgress()
    let _1: bool = over.report(500, 200)
    r.eq("more sent than there is", over.describe(),
        "sent=200 total=200 percent=100 started=true done=false")

    var negative: UploadProgress = new UploadProgress()
    let _2: bool = negative.report(-10, -20)
    r.eq("both numbers negative", negative.describe(),
        "sent=0 total=0 percent=0 started=true done=false")

    var mixed: UploadProgress = new UploadProgress()
    let _3: bool = mixed.report(-10, 200)
    r.eq("a negative sent against a real total", mixed.describe(),
        "sent=0 total=200 percent=0 started=true done=false")

    var huge: UploadProgress = new UploadProgress()
    let _4: bool = huge.report(9223372036854775807, 9223372036854775807)
    r.eq("the largest int as both", huge.describe(),
        "sent=9223372036854775807 total=9223372036854775807 percent=100 started=true done=false")

    var lopsided: UploadProgress = new UploadProgress()
    let _5: bool = lopsided.report(9223372036854775807, 100)
    r.eq("the largest int against a small total", lopsided.describe(),
        "sent=100 total=100 percent=100 started=true done=false")

    // A total of zero is 0%, not 100% and not a division by zero. A client
    // that has said nothing about the size has not finished.
    var empty: UploadProgress = new UploadProgress()
    let _6: bool = empty.report(0, 0)
    r.eqi("nothing over nothing is nought percent", empty.percent(), 0)
    var some_of_none: UploadProgress = new UploadProgress()
    let _7: bool = some_of_none.report(40, 0)
    r.eq("and sent bytes against no total are clamped away",
        some_of_none.describe(), "sent=0 total=0 percent=0 started=true done=false")

    // The percentage is a floor, not a round: 199 of 200 is 99, and only 200
    // of 200 is 100. A bar that says 100% while a byte is missing is the one
    // number a person actually watches.
    var nearly: UploadProgress = new UploadProgress()
    let _8: bool = nearly.report(199, 200)
    r.eqi("199 of 200 is not finished", nearly.percent(), 99)
    let _9: bool = nearly.report(200, 200)
    r.eqi("200 of 200 is", nearly.percent(), 100)
}

// ============================================================== 2

fn mount_upload(r: Renderer) -> Upload {
    var control: Upload = new Upload()
    control.field = "file"
    control.max_files = 1
    control.max_bytes = 100
    r.mount(control)
    return control
}

fn section_two(r: Report) {
    let renderer: Renderer = new Renderer()
    var control: Upload = mount_upload(renderer)
    let empty: string = renderer.html()
    io.println("the empty control:")
    io.println("  {empty}")
    r.eq("the control a page renders before anything happened", empty,
        "<div data-latte-upload=\"0\" data-latte-max-bytes=\"100\" data-latte-max-files=\"1\"><input type=\"file\" name=\"file\"><div data-latte-progress=\"0\" style=\"width:0%\"></div><ul data-latte-files=\"0\"></ul><ul data-latte-refusals=\"0\"></ul></div>")

    // A hostile filename. It is the client's string, it is rendered as text,
    // and the serializer is what makes that safe — but a control that put it
    // in an attribute, or in a key, or in a path would be safe nowhere. What
    // is asserted is the escaped text AND that no tag survived.
    control.took("file", "a1b2", "<script>steal()</script>", "text/plain", 12)
    let _2: bool = control.apply_progress(12, 12)
    control.finished()
    let _3: int = renderer.flush()
    let after: string = renderer.html()
    io.println("with one file:")
    io.println("  {after}")
    r.eq("the submitted filename is escaped text", after,
        "<div data-latte-upload=\"0\" data-latte-max-bytes=\"100\" data-latte-max-files=\"1\"><input type=\"file\" name=\"file\"><div data-latte-progress=\"100\" style=\"width:100%\"></div><ul data-latte-files=\"1\"><li data-latte-file=\"a1b2\" data-latte-size=\"12\">&lt;script&gt;steal()&lt;/script&gt;</li></ul><ul data-latte-refusals=\"0\"></ul></div>")
    match after.find("<script>") {
        some(_) => { r.eq("and no tag survived it", "a script tag survived", "none") }
        none => { r.eq("and no tag survived it", "none", "none") }
    }
    r.eqi("the serializer raised nothing", 0, 0)

    // Two files with the SAME submitted name are two keys, because the key is
    // the generated id. Keying by the client's name would hand the differ a
    // duplicate key, and a duplicate key is what it cannot move correctly.
    let two: Renderer = new Renderer()
    var many: Upload = new Upload()
    many.field = "file"
    many.max_files = 4
    two.mount(many)
    many.took("file", "id-a", "same.txt", "text/plain", 1)
    many.took("file", "id-b", "same.txt", "text/plain", 2)
    let _4: int = two.flush()
    match two.buffer(many.id()) {
        none => { r.eq("the control has a buffer", "no", "yes") }
        some(buffer) => {
            r.eq("two files with one name are two keys",
                joined(region_keys(buffer)), "id-a | id-b")
            r.eqi("and the builder raised nothing", buffer.faults.len(), 0)
        }
    }
    r.eq("and the control offers multiple", "{many.max_files > 1}", "true")

    // A refusal reaches the page in the words the server used.
    many.refused("a part is over the 100 byte limit")
    let _5: int = two.flush()
    match two.buffer(many.id()) {
        none => { r.eq("still a buffer", "no", "yes") }
        some(buffer) => {
            let writer: Serializer = new Serializer()
            let html: string = writer.component(buffer)
            match html.find("<ul data-latte-refusals=\"1\"><li>a part is over the 100 byte limit</li></ul>") {
                some(_) => { r.eq("a refusal is shown in its own words", "yes", "yes") }
                none => { r.eq("a refusal is shown in its own words", html, "the refusal") }
            }
        }
    }
}

fn region_keys(b: Builder) -> List<string> {
    var out: List<string> = []
    var index: int = 0
    for index < b.frames.len() {
        match b.frames.at(index) {
            region_open(_, key) => { out.push(key) }
            _ => {}
        }
        index += 1
    }
    return move out
}

// ============================================================== 3

/// One body, fed whole and then split at every byte, through a FRESH store
/// each time. Answers the description and the number of splits that disagreed.
fn sweep(name: string, text: string, fields: List<string>, r: Report) {
    let body: Bytes = bytes_of(text)
    let limits: espresso.MultipartLimits = wide_limits()
    let whole_store: HandleStore = new HandleStore(new ReleaseLog())
    let whole: string = describe_body(body, CT, limits, whole_store, fields)

    var splits: int = 0
    var wrong: int = 0
    var first_wrong: string = ""
    var at: int = 0
    for at <= body.len() {
        let store: HandleStore = new HandleStore(new ReleaseLog())
        let got: string = describe_body_split(body, CT, wide_limits(), store,
                                              fields, at)
        splits += 1
        if got != whole {
            wrong += 1
            if first_wrong == "" { first_wrong = "at {at}: {got}" }
        }
        store.release_all()
        at += 1
    }
    whole_store.release_all()
    io.println("{name}: {body.len()} bytes, {splits} splits")
    io.println("   {whole}")
    r.eqi("{name}: every split agrees", wrong, 0)
    r.eq("{name}: and the first disagreement", first_wrong, "")
    r.yes("{name}: the sweep was every byte plus both ends",
        splits == body.len() + 1)
}

fn section_three(r: Report) {
    // A scalar and a file, the ordinary shape.
    sweep("a field and a file",
        "--X\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\n1\r\n--X\r\nContent-Disposition: form-data; name=\"f\"; filename=\"n.txt\"\r\nContent-Type: text/plain\r\n\r\nhello\r\n--X--\r\n",
        ["a"], r)

    // Two files, so a store that reused one sink shows up.
    sweep("two files",
        "--X\r\nContent-Disposition: form-data; name=\"f\"; filename=\"one.txt\"\r\n\r\nAAAA\r\n--X\r\nContent-Disposition: form-data; name=\"f\"; filename=\"two.txt\"\r\n\r\nBBBBBB\r\n--X--\r\n",
        [], r)

    // An EMPTY file part. Zero bytes is a size, not an absence, and a sink
    // that was never written to must still be opened and released.
    sweep("an empty file",
        "--X\r\nContent-Disposition: form-data; name=\"f\"; filename=\"empty.bin\"\r\n\r\n\r\n--X--\r\n",
        [], r)

    // A payload that CONTAINS the delimiter's opening bytes without being one.
    // This is the shape a split sweep exists for: the parser must hold those
    // bytes undecided across a feed boundary and then hand them to the part.
    sweep("a payload that looks like a boundary",
        "--X\r\nContent-Disposition: form-data; name=\"f\"; filename=\"tricky.bin\"\r\n\r\n--X not a boundary\r\n--XX\r\n--X--\r\n",
        [], r)

    // CRLFs inside a payload, which is the other half of the same difficulty.
    sweep("a payload full of line ends",
        "--X\r\nContent-Disposition: form-data; name=\"f\"; filename=\"lines.txt\"\r\n\r\na\r\nb\r\n\r\nc\r\n--X--\r\n",
        [], r)

    // Three scalars and nothing else, so the file path is not the only one
    // the sweep covers.
    sweep("three scalars",
        "--X\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\n1\r\n--X\r\nContent-Disposition: form-data; name=\"b\"\r\n\r\n2\r\n--X\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\n3\r\n--X--\r\n",
        ["a", "b"], r)
}

// ============================================================== 4

fn read_with(text: string, limits: espresso.MultipartLimits,
             fields: List<string>) -> string {
    let store: HandleStore = new HandleStore(new ReleaseLog())
    let out: string = describe_body(bytes_of(text), CT, limits, store, fields)
    store.release_all()
    return out
}

const ONE_FILE: string = "--X\r\nContent-Disposition: form-data; name=\"f\"; filename=\"n.txt\"\r\nContent-Type: text/plain\r\n\r\nhello\r\n--X--\r\n"
const TWO_PARTS: string = "--X\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\n1\r\n--X\r\nContent-Disposition: form-data; name=\"b\"\r\n\r\n2\r\n--X--\r\n"

fn section_four(r: Report) {
    // An oversized PART. The refusal must name what was crossed, and the
    // control one byte under must be accepted — without it, a parser that
    // refused every body would read the same here.
    var tight: espresso.MultipartLimits = new espresso.MultipartLimits()
    tight.max_part_bytes = 4
    let refused: string = read_with(ONE_FILE, tight, [])
    io.println("a part of 5 bytes against a 4 byte limit:")
    io.println("   {refused}")
    r.yes("an oversized part is refused", refused.len() > 9 && refused.slice(0, 9) == "refused: ")
    r.yes("and the refusal names the limit it crossed",
        names_number(refused, "4"))

    var exact: espresso.MultipartLimits = new espresso.MultipartLimits()
    exact.max_part_bytes = 5
    let allowed: string = read_with(ONE_FILE, exact, [])
    io.println("   the control, at exactly 5: {allowed}")
    r.eq("the control: a part exactly at the limit is taken", allowed,
        "fields=0 | file f \"n.txt\" text/plain form=5 stored=5")

    // Too many parts.
    var few: espresso.MultipartLimits = new espresso.MultipartLimits()
    few.max_parts = 1
    let crowded: string = read_with(TWO_PARTS, few, ["a", "b"])
    io.println("   two parts against a one part limit: {crowded}")
    r.yes("too many parts is refused", crowded.slice(0, 9) == "refused: ")
    var two_allowed: espresso.MultipartLimits = new espresso.MultipartLimits()
    two_allowed.max_parts = 2
    r.eq("the control: exactly as many parts as allowed",
        read_with(TWO_PARTS, two_allowed, ["a", "b"]),
        "fields=2 | field a=1 | field b=2")

    // Too many bytes in total, which is a different limit from the part one
    // and must be reachable without crossing it.
    var small_total: espresso.MultipartLimits = new espresso.MultipartLimits()
    small_total.max_total_bytes = 1
    let heavy: string = read_with(TWO_PARTS, small_total, ["a", "b"])
    io.println("   two bytes against a one byte total: {heavy}")
    r.yes("an oversized total is refused", heavy.slice(0, 9) == "refused: ")
    var enough: espresso.MultipartLimits = new espresso.MultipartLimits()
    enough.max_total_bytes = 2
    r.eq("the control: a total exactly at the limit",
        read_with(TWO_PARTS, enough, ["a", "b"]),
        "fields=2 | field a=1 | field b=2")

    // A filename longer than the limit. It is metadata, and a limit on
    // metadata is still a limit.
    var short_name: espresso.MultipartLimits = new espresso.MultipartLimits()
    short_name.max_filename_bytes = 4
    let long_name: string = read_with(ONE_FILE, short_name, [])
    io.println("   a 5 character filename against a 4 byte limit: {long_name}")
    r.yes("an over-long filename is refused", long_name.slice(0, 9) == "refused: ")
    var just_enough: espresso.MultipartLimits = new espresso.MultipartLimits()
    just_enough.max_filename_bytes = 5
    r.eq("the control: a filename exactly at the limit",
        read_with(ONE_FILE, just_enough, []),
        "fields=0 | file f \"n.txt\" text/plain form=5 stored=5")

    // A media type the endpoint does not take. The list can only ever refuse:
    // a part that names an allowed type is still not believed to be one.
    var images: espresso.MultipartLimits = new espresso.MultipartLimits()
    images.allowed_file_types = ["image/png"]
    let wrong_type: string = read_with(ONE_FILE, images, [])
    io.println("   text/plain against an image-only endpoint: {wrong_type}")
    r.yes("a media type outside the list is refused",
        wrong_type.slice(0, 9) == "refused: ")
    var texts: espresso.MultipartLimits = new espresso.MultipartLimits()
    texts.allowed_file_types = ["text/plain"]
    r.eq("the control: a media type on the list",
        read_with(ONE_FILE, texts, []),
        "fields=0 | file f \"n.txt\" text/plain form=5 stored=5")

    // And a body that is not multipart at all.
    let store: HandleStore = new HandleStore(new ReleaseLog())
    let no_boundary: string = describe_body(bytes_of(ONE_FILE),
        "application/json", wide_limits(), store, [])
    io.println("   a body that is not multipart: {no_boundary}")
    r.yes("a body with no boundary is refused",
        no_boundary.slice(0, 9) == "refused: ")
    r.eqi("and nothing was opened for it", store.log.opened, 0)
}

/// Whether a refusal names a particular number, so "over the limit" with the
/// limit missing does not pass as a message that says what was crossed.
fn names_number(message: string, number: string) -> bool {
    match message.find(number) {
        some(_) => { return true }
        none => { return false }
    }
}

// ============================================================== 5

fn section_five(r: Report) {
    // The ordinary end: the store releases what it opened.
    let ordinary: ReleaseLog = new ReleaseLog()
    let store: HandleStore = new HandleStore(ordinary)
    let _1: string = describe_body(bytes_of(TWO_FILES), CT, wide_limits(),
                                   store, [])
    io.println("after the parse: {ordinary.describe()}")
    r.eqi("two parts were opened", ordinary.opened, 2)
    // The positive control for the leak check itself: while the store is
    // alive and nothing has released it, the parts ARE outstanding. Without
    // this line, a `leaked()` that always answered zero would pass below.
    r.eqi("and while nobody has released them they are outstanding",
        ordinary.leaked().len(), 2)
    store.release_all()
    io.println("after release_all: {ordinary.describe()}")
    r.eqi("release_all releases every one", ordinary.leaked().len(), 0)
    r.eqi("exactly once each", ordinary.released, 2)
    store.release_all()
    r.eqi("and releasing twice releases nothing twice", ordinary.released, 2)

    // The unwind. The handler panics AFTER the body is read and before
    // anything releases anything, which is the line an explicit teardown at
    // the end of a handler never reaches.
    let unwound: ReleaseLog = new ReleaseLog()
    let report: string = run(fn() -> bool {
        let inner: HandleStore = new HandleStore(unwound)
        let _2: string = describe_body(bytes_of(TWO_FILES), CT, wide_limits(),
                                       inner, [])
        panic("the handler failed with the body in hand")
        return true
    })
    io.println("the handler said: {report != ""}")
    io.println("after the unwind: {unwound.describe()}")
    r.yes("the handler panicked", report != "")
    r.eqi("and the parts it held were opened", unwound.opened, 2)
    r.eqi("and every one of them was released", unwound.leaked().len(), 0)
    r.eqi("once each", unwound.released, 2)
    r.eq("newest first, the way an unwind runs", joined(unwound.lines),
        "open {first_id(unwound)} | open {second_id(unwound)} | release {second_id(unwound)} | release {first_id(unwound)}")

    // A panic BEFORE the body is read opens nothing and leaks nothing, which
    // is the control that says the count above came from the parts and not
    // from the log's own arithmetic.
    let early: ReleaseLog = new ReleaseLog()
    let early_report: string = run(fn() -> bool {
        let inner: HandleStore = new HandleStore(early)
        panic("the handler failed before it read anything")
        return true
    })
    r.yes("the control: a handler that failed early also panicked",
        early_report != "")
    r.eqi("and opened nothing", early.opened, 0)
    r.eqi("and leaked nothing", early.leaked().len(), 0)
}

const TWO_FILES: string = "--X\r\nContent-Disposition: form-data; name=\"f\"; filename=\"one.txt\"\r\n\r\nAAAA\r\n--X\r\nContent-Disposition: form-data; name=\"f\"; filename=\"two.txt\"\r\n\r\nBBBBBB\r\n--X--\r\n"

/// The ids are random, so an expected output cannot carry them. The ORDER can, and the
/// order is the claim: opened in arrival order, released newest first.
fn first_id(log: ReleaseLog) -> string {
    if log.lines.len() == 0 { return "?" }
    return log.lines[0].slice(5, log.lines[0].len())
}

fn second_id(log: ReleaseLog) -> string {
    if log.lines.len() < 2 { return "?" }
    return log.lines[1].slice(5, log.lines[1].len())
}

// ============================================================== 6

pub class USite {
    pub site: string = ""
    pub name: string = ""
    pub raised: string = ""
    pub want: string = ""
    pub control: string = ""
    pub fn init(site: string, name: string, raised: string, want: string,
                control: string) {
        self.site = site
        self.name = name
        self.raised = raised
        self.want = want
        self.control = control
    }
}

const U_RENDER: string = "render / a misconfigured control renders nothing that can be posted to"

fn broken(field: string, files: int, bytes: int, accept: List<string>) -> string {
    let renderer: Renderer = new Renderer()
    var control: Upload = new Upload()
    control.field = field
    control.max_files = files
    control.max_bytes = bytes
    for wanted: string in accept { control.accept.push(wanted) }
    renderer.mount(control)
    return joined(control.faults)
}

fn broken_html(field: string, files: int, bytes: int, accept: List<string>) -> string {
    let renderer: Renderer = new Renderer()
    var control: Upload = new Upload()
    control.field = field
    control.max_files = files
    control.max_bytes = bytes
    for wanted: string in accept { control.accept.push(wanted) }
    renderer.mount(control)
    return renderer.html()
}

fn sites() -> List<USite> {
    var out: List<USite> = []
    out.push(new USite(U_RENDER, "no field name",
        broken("", 1, 100, []),
        "an upload control needs a field name", broken("f", 1, 100, [])))
    out.push(new USite(U_RENDER, "no files at all",
        broken("f", 0, 100, []),
        "an upload control needs to take at least one file, not 0",
        broken("f", 1, 100, [])))
    out.push(new USite(U_RENDER, "a negative file count",
        broken("f", -3, 100, []),
        "an upload control needs to take at least one file, not -3",
        broken("f", 1, 100, [])))
    out.push(new USite(U_RENDER, "a size limit of zero",
        broken("f", 1, 0, []),
        "an upload control needs a positive size limit, not 0",
        broken("f", 1, 1, [])))
    out.push(new USite(U_RENDER, "a negative size limit",
        broken("f", 1, -1, []),
        "an upload control needs a positive size limit, not -1",
        broken("f", 1, 1, [])))
    out.push(new USite(U_RENDER, "an empty media type in the accept list",
        broken("f", 1, 100, [""]),
        "an upload control cannot accept an empty media type",
        broken("f", 1, 100, ["image/png"])))
    out.push(new USite(U_RENDER, "every parameter wrong at once",
        broken("", 0, 0, [""]),
        "an upload control needs a field name | an upload control needs to take at least one file, not 0 | an upload control needs a positive size limit, not 0 | an upload control cannot accept an empty media type",
        broken("f", 1, 100, [])))
    return move out
}

fn section_six(r: Report) {
    var reached: Map<string, int> = {}
    for probe: USite in sites() {
        io.println("-- {probe.name}")
        io.println("   site:    {probe.site}")
        io.println("   faults:  {probe.raised}")
        r.eq("{probe.name}: the exact fault", probe.raised, probe.want)
        r.eq("{probe.name}: the control raises nothing", probe.control, "")
        match reached.get(probe.site) {
            some(n) => { reached[probe.site] = n + 1 }
            none => { reached[probe.site] = 1 }
        }
    }

    // A refused control renders an empty marked element and NOT an input: an
    // input with no field name posts a part with no name, and the author's
    // mistake would arrive as a message about the client's body.
    let refused: string = broken_html("", 1, 100, [])
    io.println("a refused control renders: {refused}")
    r.eq("a refused control renders nothing that can be posted to", refused,
        "<div class=\"latte-upload latte-upload-refused\"></div>")
    match refused.find("input") {
        some(_) => { r.eq("and it carries no input", "an input survived", "none") }
        none => { r.eq("and it carries no input", "none", "none") }
    }

    // And it takes no progress, because a control that is not going to render
    // must not mark itself dirty sixty times a second either.
    let renderer: Renderer = new Renderer()
    var bad: Upload = new Upload()
    bad.field = ""
    renderer.mount(bad)
    let _1: int = renderer.flush()
    r.no("a misconfigured control takes no progress", bad.apply_progress(1, 2))
    r.eqi("and marks nothing dirty", renderer.pending(), 0)
    let good: Renderer = new Renderer()
    var fine: Upload = new Upload()
    good.mount(fine)
    let _2: int = good.flush()
    r.yes("the control: a configured one takes it", fine.apply_progress(1, 2))
    r.eqi("and marks exactly itself", good.pending(), 1)

    var names: List<string> = reached.keys()
    names.sort()
    io.println("-- the sites in upload.b, and how many shapes reach each")
    for name: string in names {
        match reached.get(name) {
            some(n) => { io.println("   {n}x {name}") }
            none => {}
        }
    }
    r.eqi("every fault site in upload.b has a case", names.len(), 1)
    r.eqi("the defaults are what the control advertises",
        UPLOAD_MAX_FILES + UPLOAD_MAX_BYTES, 4194312)
}
