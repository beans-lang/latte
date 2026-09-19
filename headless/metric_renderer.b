// A renderer that measures and records, and paints nothing.
package headless

import latte.geometry
import latte.paint

/// The renderer a scene gets when there is no surface to draw on.
///
/// It is not a stub that answers zero. It shapes text with a monospaced metric
/// — one advance per grapheme, scaled by the point size — so layout runs, a
/// caret lands somewhere defensible, and a golden of the tree is the same on
/// every machine. Nothing here is a guess about what a real font will do; it
/// is a *stated* font, which is what makes a layout test a test rather than a
/// screenshot of whichever face was installed.
///
/// Two jobs, and they are the same object on purpose. A gate needs measurement
/// with no browser, and a browser that has lost its GPU context needs
/// measurement for it rebuilds one. A second implementation for the second
/// case would be a second set of line breaks.
pub class MetricRenderer implements paint.Renderer {
    /// Width of one grapheme as a fraction of the point size. 0.6 is a
    /// typical monospaced advance and is the number every golden in this repo
    /// was recorded against; changing it re-records all of them.
    advance: f64 = 0.6
    ascent_ratio: f64 = 0.8
    descent_ratio: f64 = 0.2
    line_gap: f64 = 1.2

    pub recorded: List<paint.DisplayList> = []
    open_list: Option<paint.DisplayList> = none
    font_path: string = ""

    pub fn init() {}

    pub fn use_font(path: string) -> Result<bool> {
        self.font_path = path
        return ok(true)
    }

    /// Which font file was pinned, so a gate can assert a run used the face it
    /// meant to.
    pub fn font() -> string { return self.font_path }

    pub fn paragraph(text: string, size: f64, width: f64, color: int) -> Result<paint.Paragraph> {
        return self.styled_paragraph(text, paint.TextStyle.of(size), width, color)
    }

    pub fn styled_paragraph(text: string, style: paint.TextStyle, width: f64,
                            color: int) -> Result<paint.Paragraph> {
        if style.size <= 0.0 {
            return err("could not shape text: a point size is a positive number, and {style.size} is not",
                       "out_of_range")
        }
        return ok(new MetricParagraph(text, style, width,
                                      style.size * self.advance + style.tracking,
                                      style.size * self.ascent_ratio,
                                      style.size * self.descent_ratio,
                                      style.size * self.line_gap))
    }

    pub fn begin(size: geometry.Size, scale: f64, background: int) -> Result<paint.Canvas> {
        if self.open_list != none {
            return err("could not start a frame: the previous one was never ended",
                       "wrong_moment")
        }
        var list: paint.DisplayList = new paint.DisplayList()
        self.open_list = some(list)
        return ok(list)
    }

    pub fn end() -> Result<bool> {
        match self.open_list {
            none => {
                return err("could not end a frame: none was started", "wrong_moment")
            }
            some(list) => {
                self.recorded.push(list)
                self.open_list = none
                return ok(true)
            }
        }
    }

    /// Grapheme boundaries, as byte offsets, first and last included.
    ///
    /// UTF-8 lead bytes, plus the two joins a caret must never land inside: a
    /// combining mark and a zero-width joiner. It is not the full Unicode
    /// segmentation table — a real renderer's is — and the cases it gets wrong
    /// are recorded in `tests/text_boundaries.b` rather than assumed away.
    pub fn graphemes(text: string) -> Result<List<int>> {
        var out: List<int> = [0]
        var index: int = 1
        for index < text.len() {
            let byte: int = text.byte_at(index)
            // A continuation byte is inside a code point, never a boundary.
            if (byte & 192) == 128 { index = index + 1; continue }
            if MetricRenderer.joins(text, index) { index = index + 1; continue }
            out.push(index)
            index = index + 1
        }
        out.push(text.len())
        return ok(move out)
    }

    /// Whether the code point starting at `at` attaches to the one before it.
    static fn joins(text: string, at: int) -> bool {
        let byte: int = text.byte_at(at)
        // U+0300..U+036F, the combining diacritics: 0xCC 0x80 .. 0xCD 0xAF.
        if byte == 204 || byte == 205 { return true }
        // U+200D, the zero-width joiner: 0xE2 0x80 0x8D.
        if byte == 226 && at + 2 < text.len() &&
           text.byte_at(at + 1) == 128 && text.byte_at(at + 2) == 141 { return true }
        // A code point straight after a joiner is part of the same cluster.
        if at >= 3 && text.byte_at(at - 3) == 226 &&
           text.byte_at(at - 2) == 128 && text.byte_at(at - 1) == 141 { return true }
        // U+FE0F, the emoji presentation selector: 0xEF 0xB8 0x8F.
        if byte == 239 && at + 2 < text.len() &&
           text.byte_at(at + 1) == 184 && text.byte_at(at + 2) == 143 { return true }
        return false
    }

    /// Word boundaries, as byte offsets. A word ends where a run of spaces or
    /// punctuation begins, which is what a double-click selects.
    pub fn words(text: string) -> Result<List<int>> {
        var out: List<int> = [0]
        var index: int = 0
        var previous: bool = false
        for index < text.len() {
            let byte: int = text.byte_at(index)
            let wordy: bool = MetricRenderer.word_byte(byte)
            if index > 0 && wordy != previous { out.push(index) }
            previous = wordy
            index = index + 1
        }
        if text.len() > 0 { out.push(text.len()) }
        return ok(move out)
    }

    /// The wider of two numbers, so a measurement pass needs no std.math.
    pub static fn wider(a: f64, b: f64) -> f64 { return if a > b { a } else { b } }

    static fn word_byte(byte: int) -> bool {
        if byte >= 48 && byte <= 57 { return true }
        if byte >= 65 && byte <= 90 { return true }
        if byte >= 97 && byte <= 122 { return true }
        if byte == 95 { return true }
        // Every byte of a multi-byte code point counts as part of a word: this
        // renderer does not carry the Unicode word table, and treating a
        // Japanese run as one word is the honest approximation.
        if byte >= 128 { return true }
        return false
    }

    pub fn image(source: string) -> Result<paint.ImageResource> {
        return err("could not load the image {source}: this renderer draws nothing, so it decodes nothing",
                   "unsupported")
    }
}

/// A paragraph measured from a stated advance, not from a font file.
pub class MetricParagraph implements paint.Paragraph {
    text: string
    style: paint.TextStyle
    wrap_width: f64
    advance: f64
    ascent: f64
    descent: f64
    line_height: f64
    lines: List<int> = []
    measured: geometry.Size = geometry.Size.zero()

    pub fn init(text: string, style: paint.TextStyle, wrap_width: f64,
                advance: f64, ascent: f64, descent: f64, line_height: f64) {
        self.text = text
        self.style = style
        self.wrap_width = wrap_width
        self.advance = advance
        self.ascent = ascent
        self.descent = descent
        self.line_height = line_height
        self.lay_out()
    }

    /// Breaks the text into lines, at the wrap width when there is one.
    ///
    /// Breaks at a space when one is available inside the line, and mid-word
    /// when none is — the same two rules every shaper has, which is what keeps
    /// a golden recorded here close to what a real one produces.
    fn lay_out() {
        var starts: List<int> = [0]
        var widest: f64 = 0.0
        var line_start: int = 0
        var last_space: int = -1
        var index: int = 0
        var columns: int = 0
        for index < self.text.len() {
            let byte: int = self.text.byte_at(index)
            if byte == 10 {
                widest = MetricRenderer.wider(widest, columns as f64 * self.advance)
                index = index + 1
                starts.push(index)
                line_start = index
                last_space = -1
                columns = 0
                continue
            }
            if (byte & 192) != 128 { columns = columns + 1 }
            if byte == 32 { last_space = index }
            if self.wrap_width > 0.0 &&
               columns as f64 * self.advance > self.wrap_width && index > line_start {
                var at: int = index
                if last_space > line_start { at = last_space + 1 }
                widest = MetricRenderer.wider(widest, (at - line_start) as f64 * self.advance)
                starts.push(at)
                line_start = at
                last_space = -1
                index = at
                columns = 0
                continue
            }
            index = index + 1
        }
        widest = MetricRenderer.wider(widest, columns as f64 * self.advance)
        self.lines = move starts
        self.measured = geometry.Size.of(widest, self.lines.len() as f64 * self.line_height)
    }

    pub fn size() -> geometry.Size { return self.measured }

    pub fn metrics() -> paint.LineMetrics {
        return paint.LineMetrics {
            ascent: self.ascent, descent: self.descent,
            height: self.line_height,
            baseline: (self.line_height - self.ascent - self.descent) / 2.0 + self.ascent,
        }
    }

    /// The byte offset nearest a point, which is where a click puts the caret.
    pub fn hit_test(x: f64, y: f64) -> int {
        let line: int = self.line_at(y)
        let start: int = self.lines[line]
        let stop: int = self.line_end(line)
        var column: int = 0
        if self.advance > 0.0 { column = ((x / self.advance) + 0.5) as int }
        var at: int = start
        var seen: int = 0
        for at < stop && seen < column {
            at = at + 1
            for at < stop && (self.text.byte_at(at) & 192) == 128 { at = at + 1 }
            seen = seen + 1
        }
        return at
    }

    pub fn caret(byte_offset: int) -> geometry.Rect {
        var offset: int = byte_offset
        if offset < 0 { offset = 0 }
        if offset > self.text.len() { offset = self.text.len() }
        var line: int = 0
        var index: int = 0
        for index < self.lines.len() && self.lines[index] <= offset {
            line = index
            index = index + 1
        }
        let start: int = self.lines[line]
        var columns: int = 0
        var at: int = start
        for at < offset {
            if (self.text.byte_at(at) & 192) != 128 { columns = columns + 1 }
            at = at + 1
        }
        return geometry.Rect.of(columns as f64 * self.advance,
                                line as f64 * self.line_height,
                                1.0, self.line_height)
    }

    pub fn selection(first_byte: int, last_byte: int) -> Result<List<geometry.Rect>> {
        var first: int = first_byte
        var last: int = last_byte
        if first > last { let swap: int = first; first = last; last = swap }
        if first < 0 || last > self.text.len() {
            return err("could not measure a selection: {first_byte}..{last_byte} is outside text of {self.text.len()} bytes",
                       "out_of_range")
        }
        var boxes: List<geometry.Rect> = []
        var line: int = 0
        for line < self.lines.len() {
            let start: int = self.lines[line]
            let stop: int = self.line_end(line)
            let from: int = if first > start { first } else { start }
            let to: int = if last < stop { last } else { stop }
            if from < to {
                let head: geometry.Rect = self.caret(from)
                let tail: geometry.Rect = self.caret(to)
                boxes.push(geometry.Rect.of(head.x, head.y, tail.x - head.x, self.line_height))
            }
            line = line + 1
        }
        return ok(move boxes)
    }

    fn line_at(y: f64) -> int {
        if self.line_height <= 0.0 { return 0 }
        var line: int = (y / self.line_height) as int
        if line < 0 { line = 0 }
        if line >= self.lines.len() { line = self.lines.len() - 1 }
        return line
    }

    fn line_end(line: int) -> int {
        if line + 1 < self.lines.len() {
            var stop: int = self.lines[line + 1]
            // The newline that ended the line is not part of it.
            if stop > 0 && stop <= self.text.len() && self.text.byte_at(stop - 1) == 10 {
                stop = stop - 1
            }
            return stop
        }
        return self.text.len()
    }
}
