// Uploads, the half that has no I/O: the control a page renders, the progress
// a client reports, and the record of what came back.
//
// A page's POST handler drives this file's `Upload` component directly —
// `took`, `refused`, `finished` — after running the body through espresso's
// multipart parser and `latte.uploads`' store. There is no automatic field
// binding for a file part the way `@form`/`@field` binds scalar fields.
//
// Limits live in espresso (`MultipartLimits`): max parts, max part size, max
// total, max filename length, an allowed content-type list, each with a
// refusal that names what was crossed. The client's `Content-Type` is never
// trusted; a file is stored under a generated id, and the submitted filename
// is metadata, never a path.
//
// `apply_progress` exists so a circuit could report client-side send
// progress, but wire v1 has no message kind that carries it yet: nothing
// calls `apply_progress` outside a test today.
//
// This file stays free of I/O so the module root keeps building for wasm;
// the two halves meet in `latte.uploads`, which may import espresso but,
// being a package under `latte/`, may never name a type in this file.
package latte

/// The largest upload a page offers by default, in bytes.
///
/// It is the number the CONTROL advertises, not a bound anything enforces: the
/// server's `MultipartLimits` is what refuses an oversized body, and a client
/// that ignores this attribute simply gets refused there instead. Two numbers
/// for two jobs, exactly like the two window caps in `virtual.b`.
pub const UPLOAD_MAX_BYTES: int = 4194304

/// How many files one control offers to take.
pub const UPLOAD_MAX_FILES: int = 8

// ============================================================== progress

/// How far an upload has got, as the CLIENT reports it.
///
/// Every number here came off the wire, so none of it is believed: a client
/// that says it has sent more bytes than the file holds, or a negative total,
/// or nine quintillion of either, must produce a progress bar between 0 and
/// 100 and nothing else. The clamps are the whole class.
pub class UploadProgress {
    /// Bytes the client says it has sent.
    pub sent: int = 0
    /// Bytes the client says there are.
    pub total: int = 0
    /// Whether a client has reported anything at all.
    pub started: bool = false
    /// Whether the server has seen the body and finished with it.
    pub done: bool = false

    pub fn init() {}

    /// Take a report. Answers whether anything changed, so a client reporting
    /// once per animation frame does not re-render a page sixty times a second
    /// for the same two numbers.
    pub fn report(sent: int, total: int) -> bool {
        var size: int = total
        if size < 0 { size = 0 }
        var done: int = sent
        if done < 0 { done = 0 }
        // Clamped to the total AFTER the total is clamped, because the total
        // is the ceiling and a hostile pair is two hostile numbers, not one.
        if done > size { done = size }
        if self.started && done == self.sent && size == self.total { return false }
        self.sent = done
        self.total = size
        self.started = true
        return true
    }

    /// 0..100. A total of zero is 0%, not a division by zero and not 100%: a
    /// client that has said nothing about the size has not finished.
    ///
    /// `sent * 100` OVERFLOWS. `report` clamps the pair into `0 <= sent <=
    /// total`, but it does not make them small, and a client is free to say it
    /// has sent 9,223,372,036,854,775,807 of 9,223,372,036,854,775,807 bytes —
    /// at which point the multiply is undefined, the interpreter wrapped to a
    /// negative and answered 0%, and the native backend was free to answer
    /// anything at all. So both sides are halved until the multiply fits.
    /// Halving loses at most one unit out of more than 9e16, which cannot move
    /// an integer percentage.
    pub fn percent() -> int {
        if self.total <= 0 { return 0 }
        var top: int = self.sent
        var bottom: int = self.total
        // The largest value for which `top * 100` is representable.
        for top > 92233720368547758 {
            top = top / 2
            bottom = bottom / 2
        }
        if bottom <= 0 { return 100 }
        let out: int = top * 100 / bottom
        if out < 0 { return 0 }
        if out > 100 { return 100 }
        return out
    }

    pub fn describe() -> string {
        return "sent={self.sent} total={self.total} percent={self.percent()} started={self.started} done={self.done}"
    }
}

// ============================================================== the record

/// One file that arrived, as the page sees it.
///
/// `storage_id` is the generated name and the only one anything should use to
/// address the bytes. `submitted_filename` is the client's and is metadata: it
/// is rendered as TEXT, through the serializer's escaping, and it is never a
/// path, never a key, and never a name latte looks anything up by.
pub class UploadFile {
    pub field: string = ""
    pub storage_id: string = ""
    pub submitted_filename: string = ""
    pub declared_type: string = ""
    pub size: int = 0

    pub fn init(field: string, storage_id: string, submitted_filename: string,
                declared_type: string, size: int) {
        self.field = field
        self.storage_id = storage_id
        self.submitted_filename = submitted_filename
        self.declared_type = declared_type
        self.size = size
    }

    pub fn describe() -> string {
        return "{self.field}/{self.storage_id} \"{self.submitted_filename}\" {self.declared_type} {self.size}B"
    }
}

// ============================================================== the component

/// A file control, its progress, and what came back.
///
/// It holds no bytes. The bytes went to a store on the POST path and this
/// component knows only their generated id and size — which is what keeps a
/// re-render of a page with a 4 MB upload on it the same cost as a re-render
/// of a page without one.
pub class Upload extends Component {
    /// The form field the control posts under.
    pub field: string = "file"
    /// Where the browser posts. Empty means the page's own url.
    pub action: string = ""
    /// How many files this control takes.
    pub max_files: int = UPLOAD_MAX_FILES
    /// The largest file the control advertises, in bytes.
    pub max_bytes: int = UPLOAD_MAX_BYTES
    /// Media types the control advertises. Empty offers every one.
    ///
    /// It is a HINT to the browser's file picker and nothing more. What a file
    /// is decided from is never what the client called it, so this list can
    /// only narrow a dialog — it can never authorize a part.
    pub accept: List<string> = []
    /// A class for the control, so an application can size it.
    pub class_name: string = ""

    /// How far the current upload has got.
    pub progress: UploadProgress = new UploadProgress()
    /// The files that arrived, in order.
    pub files: List<UploadFile> = []
    /// What the server refused, in the words it refused it with.
    pub refusals: List<string> = []
    /// Configuration refused at render time, by name.
    pub faults: List<string> = []

    pub fn init() {}

    /// Everything wrong with this control's configuration, by name.
    ///
    /// These are the AUTHOR's numbers. They are refused rather than clamped
    /// for the reason `VirtualGeometry.problems()` gives: quietly substituting
    /// a default hides a mistake behind a control that half works.
    pub fn problems() -> List<string> {
        var out: List<string> = []
        if self.field == "" {
            out.push("an upload control needs a field name")
        }
        if self.max_files <= 0 {
            out.push("an upload control needs to take at least one file, not {self.max_files}")
        }
        if self.max_bytes <= 0 {
            out.push("an upload control needs a positive size limit, not {self.max_bytes}")
        }
        for wanted: string in self.accept {
            if wanted == "" {
                out.push("an upload control cannot accept an empty media type")
            }
        }
        return move out
    }

    pub fn ok() -> bool { return self.problems().len() == 0 }

    /// A progress report from the client. Untrusted, clamped, and it marks
    /// this component and only this component.
    pub fn apply_progress(sent: int, total: int) -> bool {
        if !self.ok() { return false }
        if !self.progress.report(sent, total) { return false }
        self.notify()
        return true
    }

    /// The server's own word that the body is in and the client's numbers no
    /// longer decide anything. A report arriving after this is ignored, so a
    /// client cannot walk a finished bar backwards.
    pub fn finished() {
        self.progress.done = true
        self.notify()
    }

    /// A file the POST path stored. `storage_id` is the generated name; the
    /// submitted filename is metadata and arrives with it, never instead.
    pub fn took(field: string, storage_id: string, submitted_filename: string,
                declared_type: string, size: int) {
        self.files.push(new UploadFile(field, storage_id, submitted_filename,
                                       declared_type, size))
        self.notify()
    }

    /// A refusal the POST path raised, in the words it used. It is shown to
    /// the person who tried to upload, so it must name what was crossed.
    pub fn refused(reason: string) {
        self.refusals.push(reason)
        self.notify()
    }

    /// Forget the last body. The files are NOT dropped from the store here —
    /// this component never held the bytes, and a component that pretended to
    /// release them would be a release nobody performed.
    pub fn reset() {
        self.progress = new UploadProgress()
        self.files.clear()
        self.refusals.clear()
        self.notify()
    }

    pub override fn render(b: Builder) {
        self.faults.clear()
        let problems: List<string> = self.problems()
        if problems.len() > 0 {
            for problem: string in problems { self.faults.push(problem) }
            // A misconfigured control renders NOTHING that can be posted to.
            // An input with no field name posts a part with no name, which the
            // parser then refuses on the far side, in a message about the
            // BODY — and the author's mistake would arrive as a client error.
            b.open(0, "div")
            b.attr(1, "class", "latte-upload latte-upload-refused")
            b.close()
            return
        }

        b.open(0, "div")
        if self.class_name != "" { b.attr(1, "class", self.class_name) }
        // Data, never a name: the client hands the number back and latte looks
        // it up, exactly as the virtual list's range does.
        b.attr(2, "data-latte-upload", "{self.id()}")
        b.attr(3, "data-latte-max-bytes", "{self.max_bytes}")
        b.attr(4, "data-latte-max-files", "{self.max_files}")
        if self.action != "" { b.attr(5, "data-latte-action", self.action) }

        b.open(6, "input")
        b.attr(7, "type", "file")
        b.attr(8, "name", self.field)
        if self.max_files > 1 { b.attr(9, "multiple", "") }
        if self.accept.len() > 0 { b.attr(10, "accept", self.accept.join(",")) }
        b.close()

        b.open(11, "div")
        b.attr(12, "data-latte-progress", "{self.progress.percent()}")
        b.attr(13, "style", "width:{self.progress.percent()}%")
        b.close()

        b.open(14, "ul")
        b.attr(15, "data-latte-files", "{self.files.len()}")
        for file: UploadFile in self.files {
            // Keyed by the GENERATED id. Keying by the submitted filename
            // would let a client send two parts with the same name and hand
            // the differ a duplicate key.
            b.region(16, file.storage_id)
            b.open(0, "li")
            b.attr(1, "data-latte-file", file.storage_id)
            b.attr(2, "data-latte-size", "{file.size}")
            // The client's filename, as TEXT. Everything hostile about it is
            // the serializer's problem and the serializer already solves it;
            // what matters here is that it goes nowhere else.
            b.text(3, file.submitted_filename)
            b.close()
            b.end_region()
        }
        b.close()

        b.open(17, "ul")
        b.attr(18, "data-latte-refusals", "{self.refusals.len()}")
        var index: int = 0
        for index < self.refusals.len() {
            b.region(19, "{index}")
            b.open(0, "li")
            b.text(1, self.refusals[index])
            b.close()
            b.end_region()
            index += 1
        }
        b.close()
        b.close()
    }
}
