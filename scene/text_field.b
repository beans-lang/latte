package scene

import latte.paint
import latte.geometry
import latte.input
import latte.platform

pub class TextFieldRender extends TextRender {
    editor_value: TextEditor
    hint: string = ""
    editable: bool = true
    secure_value: bool = false
    multiline_value: bool = false
    text_offset: f64 = 0.0
    vertical_offset: f64 = 0.0
    selecting: bool = false
    pub fn init(renderer: paint.Renderer, theme: Theme, dirty: Invalidation) {
        self.editor_value = new TextEditor(renderer)
        super.init(renderer, theme, dirty)
        self.focusable = true
    }
    /// The editor behind this field.
    ///
    /// Public because a caret, a selection and an undo are the field's
    /// behaviour rather than its appearance, and both a test and an
    /// application have reason to drive them directly — a "select all" command
    /// in a menu is exactly that. The field stays the only thing that paints.
    pub fn editor() -> TextEditor { return self.editor_value }

    pub fn selection_anchor() -> int { return self.editor_value.anchor() }
    pub fn selection_caret() -> int { return self.editor_value.caret() }
    pub fn editing_text() -> string { return self.editor_value.text() }
    pub fn is_secure() -> bool { return self.secure_value }
    pub fn is_multiline() -> bool { return self.multiline_value }
    /// The one content box every part of this field reads: the text, the caret,
    /// the selection and the hit test. They cannot drift apart because there is
    /// no second copy of these numbers.
    pub fn text_inset() -> f64 { return self.theme.field_padding() }
    /// Where the first line's baseline lands, down from the frame's top. It is
    /// the field's own baseline, not a centred line box: AppKit puts a 13 point
    /// run's baseline 17 points down a 24 point field whatever the line height.
    fn field_top(paragraph: paint.Paragraph) -> f64 {
        return self.theme.field_baseline() - paragraph.metrics().baseline
    }
    fn paragraph_width() -> f64 {
        return if self.multiline_value { self.bounds.width - self.text_inset() * 2.0 } else { -1.0 }
    }
    fn display_offset(offset: int) -> int {
        if !self.secure_value { return offset }
        var count: int = 0
        match self.renderer.graphemes(self.words) {
            ok(boundaries) => { for at: int in boundaries { if at > 0 && at <= offset { count += 1 } } }
            err(_) => {}
        }
        return count * 3 // one UTF-8 bullet per grapheme
    }
    fn source_offset(offset: int) -> int {
        if !self.secure_value { return offset }
        let index: int = offset / 3
        match self.renderer.graphemes(self.words) {
            ok(boundaries) => { if index >= 0 && index < boundaries.len() { return boundaries[index] } }
            err(_) => {}
        }
        return self.words.len()
    }
    /// The grapheme boundary a paragraph-space point lands on, in source bytes.
    fn snapped(paragraph: paint.Paragraph, x: f64, y: f64) -> Result<int> {
        let hit: int = self.source_offset(paragraph.hit_test(x, y))
        let boundaries: List<int> = self.renderer.graphemes(self.words)?
        var at: int = 0
        for boundary: int in boundaries {
            if boundary > hit { break }
            at = boundary
        }
        return ok(at)
    }
    fn offset_at(position: geometry.Point) -> Result<int> {
        let paragraph: paint.Paragraph = self.shaped(self.paragraph_width())?
        return self.snapped(paragraph, position.x - self.text_inset() + self.text_offset,
                            position.y - self.field_top(paragraph) + self.vertical_offset)
    }
    /// A caret command in line terms: one line box down or up, or the far edge
    /// of the line the caret sits on. One line is the whole text in a field.
    fn caret_by_line(down: bool, whole: bool, extend: bool) -> Result<bool> {
        if !self.multiline_value {
            let edge: int = if down { self.words.len() } else { 0 }
            return self.editor_value.select(if extend { self.editor_value.anchor() } else { edge }, edge)
        }
        let paragraph: paint.Paragraph = self.shaped(self.paragraph_width())?
        let caret: geometry.Rect = paragraph.caret(self.display_offset(self.editor_value.caret()))
        let middle: f64 = caret.y + caret.height * 0.5
        let at: int = if whole { self.snapped(paragraph, if down { 1000000.0 } else { -1000000.0 }, middle)? }
                      else { self.snapped(paragraph, caret.x, middle + (if down { caret.height } else { -caret.height }))? }
        return self.editor_value.select(if extend { self.editor_value.anchor() } else { at }, at)
    }
    /// The modifier that turns a caret or a delete from a character into a
    /// word: Option on macOS, Control everywhere else.
    fn by_word(event: input.UiEvent) -> bool {
        return event.has_modifier(platform.MOD_ALT) || event.has_modifier(platform.MOD_CONTROL)
    }
    /// One arrow press: a character, a word, or the line's edge — whichever
    /// modifier this platform puts on it.
    fn caret_horizontal(forward: bool, extend: bool, event: input.UiEvent) -> Result<bool> {
        if event.has_modifier(platform.MOD_COMMAND) { return self.caret_by_line(forward, true, extend) }
        if self.by_word(event) { return self.editor_value.move_word(forward, extend) }
        return self.editor_value.move_cursor(forward, extend)
    }
    /// A delete takes the unit its modifier names: one character, one word, or
    /// everything back to the line's edge.
    fn erase_unit(backward: bool, event: input.UiEvent) -> Result<bool> {
        if event.has_modifier(platform.MOD_COMMAND) {
            if self.editor_value.anchor() == self.editor_value.caret() {
                self.caret_by_line(!backward, true, true)?
            }
            return self.editor_value.erase(backward)
        }
        if self.by_word(event) { return self.editor_value.erase_word(backward) }
        return self.editor_value.erase(backward)
    }
    pub fn caret_rect() -> Result<geometry.Rect> {
        self.demand_alive()?
        let paragraph: paint.Paragraph = self.shaped(self.paragraph_width())?
        let caret: geometry.Rect = paragraph.caret(self.display_offset(self.editor_value.caret()))
        return ok(geometry.Rect.of(caret.x + self.text_inset() - self.text_offset,
                   caret.y + self.field_top(paragraph) - self.vertical_offset, caret.width, caret.height))
    }
    pub override fn needs_template() -> bool { return true }
    pub override fn role() -> string { return "textbox" }
    pub override fn semantics() -> SemanticsNode {
        return new SemanticsNode(self.identity, if self.secure_value { "securetext" } else { "textbox" },
            if self.a11y_name == "" { self.hint } else { self.a11y_name },
            if self.secure_value { "" } else { self.words }, self.bounds, self.enabled)
    }
    pub override fn set_text(text: string) -> Result<bool> {
        self.demand_alive()?
        if self.words == text { return ok(false) }
        self.editor_value.set_text(text)?
        return super.set_text(text)
    }
    pub override fn set_string(key: int, value: string) -> Result<bool> {
        self.demand_alive()?
        if key == platform.S_HINT { self.hint = value; self.dirty.paint(); return ok(true) }
        return super.set_string(key, value)
    }
    pub override fn string_at(key: int) -> Result<string> {
        self.demand_alive()?
        if key == platform.S_HINT { return ok(self.hint) }
        return super.string_at(key)
    }
    pub override fn set_integer(key: int, value: int) -> Result<bool> {
        self.demand_alive()?
        if key == platform.P_EDITABLE { self.editable = value != 0; return ok(true) }
        return super.set_integer(key, value)
    }
    pub override fn integer(key: int) -> Result<int> {
        self.demand_alive()?
        if key == platform.P_EDITABLE { return ok(if self.editable { 1 } else { 0 }) }
        return super.integer(key)
    }
    pub override fn visible_text() -> string {
        if self.words == "" { return self.hint }
        if !self.secure_value { return self.words }
        var masked: string = ""
        match self.renderer.graphemes(self.words) {
            ok(boundaries) => { for at: int in boundaries { if at > 0 { masked = "{masked}•" } } }
            err(_) => {}
        }
        return masked
    }
    pub override fn measure(available: geometry.Size) -> Result<geometry.Size> {
        self.demand_alive()?
        let measured: geometry.Size = self.shaped(if self.multiline_value { 180.0 } else { -1.0 })?.size()
        return ok(geometry.Size.of(180.0, if self.multiline_value { 100.0 } else { self.theme.field_height() }))
    }
    pub override fn paint_self(canvas: paint.Canvas) -> Result<bool> {
        self.paint_template(canvas)?
        let inset: f64 = self.text_inset()
        if self.bounds.width <= inset * 2.0 || self.bounds.height <= 4.0 { return ok(true) }
        let paragraph: paint.Paragraph = self.shaped(self.paragraph_width())?
        let top: f64 = self.field_top(paragraph)
        canvas.save()?
        // The clip is the content box, which is the frame less the same inset
        // the text is drawn at — never a second set of numbers.
        canvas.clip(geometry.Rect.of(inset, 0.0, self.bounds.width - inset * 2.0, self.bounds.height), 0.0)?
        var caret: geometry.Rect = paragraph.caret(self.display_offset(self.editor_value.caret()))
        if self.has_focus {
            let available: f64 = self.bounds.width - inset * 2.0 - 1.0
            if !self.multiline_value {
                if caret.x < self.text_offset { self.text_offset = caret.x }
                if caret.x > self.text_offset + available { self.text_offset = caret.x - available }
            } else {
                self.text_offset = 0.0
                let height: f64 = self.bounds.height - top * 2.0
                if caret.y < self.vertical_offset { self.vertical_offset = caret.y }
                if caret.y + caret.height > self.vertical_offset + height {
                    self.vertical_offset = caret.y + caret.height - height
                }
            }
        } else { self.text_offset = 0.0; self.vertical_offset = 0.0 }
        if self.has_focus && self.editor_value.anchor() != self.editor_value.caret() {
            var first: int = self.editor_value.anchor(); var last: int = self.editor_value.caret()
            if first > last { let swap: int = first; first = last; last = swap }
            let rectangles: List<geometry.Rect> = paragraph.selection(self.display_offset(first), self.display_offset(last))?
            for rect: geometry.Rect in rectangles {
                canvas.rectangle(geometry.Rect.of(rect.x + inset - self.text_offset,
                    rect.y + top - self.vertical_offset, rect.width, rect.height),
                    0.0, (self.theme.accent() & 0xffffff00) | 0x44, 0.0)?
            }
        }
        canvas.paragraph(paragraph, inset - self.text_offset, top - self.vertical_offset)?
        if self.has_focus {
            caret.x += inset - self.text_offset; caret.y += top - self.vertical_offset
            canvas.rectangle(caret, 0.0, self.theme.accent(), 0.0)?
        }
        canvas.restore()?
        return ok(true)
    }
    pub override fn handle_event(event: input.UiEvent) -> Option<input.UiEvent> {
        if !self.editable || !self.enabled || !self.alive { return none }
        if event.kind == input.EventKind.composition_cancel {
            self.editor_value.cancel_composition()
            self.words = self.editor_value.text()
            self.dirty.layout()
            return none
        }
        if event.kind == input.EventKind.composition_update || event.kind == input.EventKind.text_input {
            let was_composing: bool = self.editor_value.composing()
            let typed: string = if self.multiline_value { event.text.replace("\r", "\n") }
                                else { event.text.replace("\n", "").replace("\r", "") }
            var operation: Result<bool> = ok(false)
            if event.kind == input.EventKind.text_input {
                if event.index >= 0 && event.token >= event.index {
                    self.editor_value.cancel_composition()
                    match self.editor_value.select(event.index, event.token) {
                        ok(_) => { operation = self.editor_value.replace(typed) }
                        err(_) => { return none }
                    }
                } else { operation = self.editor_value.commit_composition(typed) }
            } else { operation = self.editor_value.update_composition(typed) }
            match operation { err(_) => { return none } ok(_) => {} }
            if event.kind == input.EventKind.composition_update {
                let start: int = self.editor_value.caret() - typed.len()
                let anchor: int = start + event.index
                let caret: int = start + event.token
                // The IME's offsets are UTF-8 bytes. Grapheme validation in
                // TextEditor keeps the native selection out of split clusters.
                if start >= 0 { self.editor_value.select(anchor, caret) }
            }
            self.dirty.layout()
            self.dirty.semantics()
            let report: bool = event.kind == input.EventKind.text_input &&
                               (was_composing || self.words != self.editor_value.text())
            if self.words != self.editor_value.text() {
                self.words = self.editor_value.text()
            }
            if report {
                let changed: input.UiEvent = input.UiEvent.of(input.EventKind.value_changed, platform.Handle.of(self.identity))
                changed.text = self.words
                return some(changed)
            }
            return none
        }
        if event.kind == input.EventKind.pointer_down && event.index == platform.BTN_LEFT {
            match self.offset_at(event.position) {
                ok(at) => {
                    self.selecting = true
                    if event.click_count() >= 3 { self.editor_value.select(0, self.words.len()) }
                    else if event.click_count() == 2 { self.editor_value.select_word(at) }
                    else { self.editor_value.select(if event.has_modifier(platform.MOD_SHIFT) { self.editor_value.anchor() } else { at }, at) }
                    self.dirty.paint()
                }
                err(_) => {}
            }
            return none
        }
        // A drag holds the anchor where the press landed and takes the caret
        // with the pointer, which is how a pointer selects text anywhere.
        if event.kind == input.EventKind.pointer_move && self.selecting {
            match self.offset_at(event.position) {
                ok(at) => {
                    if at != self.editor_value.caret() {
                        self.editor_value.select(self.editor_value.anchor(), at)
                        self.dirty.paint()
                    }
                }
                err(_) => {}
            }
            return none
        }
        if event.kind == input.EventKind.pointer_up { self.selecting = false; return none }
        if event.kind != input.EventKind.key_down { return none }
        var operation: Result<bool> = ok(false)
        let extend: bool = event.has_modifier(platform.MOD_SHIFT)
        let shortcut: bool = event.has_modifier(platform.MOD_COMMAND) || event.has_modifier(platform.MOD_CONTROL)
        if shortcut && event.key() == input.Key.character {
            if event.text == "a" || event.text == "A" { operation = self.editor_value.select(0, self.words.len()) }
            else if (event.text == "c" || event.text == "C") && !self.secure_value {
                var first: int = self.editor_value.anchor(); var last: int = self.editor_value.caret()
                if first > last { let swap: int = first; first = last; last = swap }
                if first < last { platform.HostDesk.instance.host().clipboard_write(self.words.slice(first, last)) }
                return none
            }
            else if (event.text == "x" || event.text == "X") && !self.secure_value {
                var first: int = self.editor_value.anchor(); var last: int = self.editor_value.caret()
                if first > last { let swap: int = first; first = last; last = swap }
                if first < last {
                    match platform.HostDesk.instance.host().clipboard_write(self.words.slice(first, last)) {
                        ok(_) => { operation = self.editor_value.replace("") }
                        err(_) => { return none }
                    }
                }
            }
            else if event.text == "v" || event.text == "V" {
                match platform.HostDesk.instance.host().clipboard_read() {
                    ok(text) => { operation = self.editor_value.replace(if self.multiline_value { text.replace("\r", "\n") }
                                                                 else { text.replace("\n", "").replace("\r", "") }) }
                    err(_) => { return none }
                }
            }
            else if event.text == "z" || event.text == "Z" {
                operation = ok(if extend { self.editor_value.redo() } else { self.editor_value.undo() })
            }
            else if event.text == "y" || event.text == "Y" { operation = ok(self.editor_value.redo()) }
        } else { match event.key() {
            character => { operation = self.editor_value.replace(if self.multiline_value { event.text.replace("\r", "\n") }
                                                                   else { event.text.replace("\n", "").replace("\r", "") }) }
            space => { operation = self.editor_value.replace(" ") }
            backspace => { operation = self.erase_unit(true, event) }
            delete => { operation = self.erase_unit(false, event) }
            left => { operation = self.caret_horizontal(false, extend, event) }
            right => { operation = self.caret_horizontal(true, extend, event) }
            up => { operation = self.caret_by_line(false, false, extend) }
            down => { operation = self.caret_by_line(true, false, extend) }
            home => { operation = self.caret_by_line(false, true, extend) }
            end => { operation = self.caret_by_line(true, true, extend) }
            ret => {
                if self.multiline_value { operation = self.editor_value.replace("\n") }
                else {
                    let commit: input.UiEvent = input.UiEvent.of(input.EventKind.text_commit, platform.Handle.of(self.identity))
                    commit.text = self.words
                    return some(commit)
                }
            }
            _ => {}
        } }
        match operation { err(_) => { return none } ok(_) => {} }
        self.dirty.paint()
        self.dirty.semantics()
        if self.words != self.editor_value.text() {
            self.words = self.editor_value.text()
            self.dirty.layout()
            let changed: input.UiEvent = input.UiEvent.of(input.EventKind.value_changed, platform.Handle.of(self.identity))
            changed.text = self.words
            return some(changed)
        }
        return none
    }
}

pub class SecureFieldRender extends TextFieldRender {
    pub fn init(renderer: paint.Renderer, theme: Theme, dirty: Invalidation) {
        super.init(renderer, theme, dirty)
        self.secure_value = true
    }
}

pub class SearchFieldRender extends TextFieldRender {
    pub fn init(renderer: paint.Renderer, theme: Theme, dirty: Invalidation) {
        super.init(renderer, theme, dirty)
    }
}

pub class TextAreaRender extends TextFieldRender {
    pub fn init(renderer: paint.Renderer, theme: Theme, dirty: Invalidation) {
        super.init(renderer, theme, dirty)
        self.multiline_value = true
    }
}
