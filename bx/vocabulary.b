// vocabulary.b — latte's `.bx` surface, as data an editor can read.
//
// An editor cannot ask latte-bx what a `.bx` file may contain: the extension
// is a TypeScript bundle and latte-bx is a Beans binary. So the vocabulary is
// **printed** from here and checked in on the editor side, exactly the way
// crema printed its own. `tests/w2_editor_data.b` is the printer, its golden
// is the JSON byte for byte, and `latte-bx vocabulary` prints the same string
// for a person regenerating it by hand.
//
// **Why the lists are written out here and not derived.** `is_void_element`
// and its neighbours in `html.b` are chains of `==`, and a chain cannot be
// enumerated — the same problem `event_names()` has, and it is solved the same
// way. `tests/markup.b` §1b asks the predicate about **every name in each list
// here** and about **a control corpus of names that must not be in it**, so a
// row added to `html.b` and forgotten here fails the gate rather than shipping
// an editor that has never heard of it. Adding a name to a list here without
// adding it to `html.b` fails too, from the other side.
//
// Nothing under the latte module root imports this file, and neither does the
// emitter. It is data about the language, for a reader outside it.

package bx

/// One named thing in the surface, with the form to write and why.
///
/// Three strings rather than a shape per section: an editor renders `name` in
/// the list, `detail` beside it and `note` in the hover, and every section
/// answers those three.
pub class VocabRow {
    pub name: string = ""
    pub detail: string = ""
    pub note: string = ""
    pub fn init(name: string, detail: string, note: string) {
        self.name = name
        self.detail = detail
        self.note = note
    }
}

/// The `$` blocks. `else` is in the list and carries no `$`, because that is
/// how it is written: `$if c { } else { }` (`parse_if`).
pub fn blocks() -> List<VocabRow> {
    return [
        new VocabRow("$if", r#"$if <expr> { ... }"#,
                     "A branch. Its arms take disjoint sequence ranges out of the enclosing counter, so a flip renumbers nothing."),
        new VocabRow("else", r#"$if <expr> { ... } else if <expr> { ... } else { ... }"#,
                     "Written without a $, because it continues the $if that opened the block."),
        new VocabRow("$for", r#"$for <name> in <expr> { ... }"#,
                     r#"A region. Its body restarts sequence numbering at 0, and a direct child may carry key={ } to name a row's identity."#),
        new VocabRow("$match", r#"$match <expr> { <pattern> => { ... } }"#,
                     "A branch with more than two arms. At least one arm is required."),
        new VocabRow("$slot", r#"$slot | $slot(<expr>) | $slot:<name> | $slot:<name> as <expr> | $slot:<name> as <p>: <Type> { ... }"#,
                     "Places or defines a fragment. A body makes it a definition and only reads that way inside a component tag."),
        new VocabRow("$html", r#"$html(<expr>)"#,
                     "Unescaped HTML — the only bypass latte has, named so it greps."),
    ]
}

/// The three interpolation forms, and the escape.
pub fn interpolations() -> List<VocabRow> {
    return [
        new VocabRow("$<chain>", "$self.count, $row.title, $self.rows[0]",
                     "An implicit chain. It ends where the chain ends, so $5.00 and US$ are ordinary text."),
        new VocabRow(r#"$( )"#, "$(a + b)",
                     "A parenthesised expression. One line: a newline inside it is refused."),
        new VocabRow(r#"${ }"#, r#"${self.name}"#,
                     r#"A braced expression. One line, and a } in running text closes an enclosing block, so write \} for a literal one."#),
        new VocabRow("$$", "$$",
                     r#"A literal $ in front of a word. Everywhere else a $ that is not followed by an identifier, ( or { is already text."#),
    ]
}

/// Every attribute-name prefix that means something.
///
/// An allowlist, not "any prefix that is not ours": a mistyped `bnd:value`
/// stays an error instead of becoming an attribute literally called
/// `bnd:value` in the page (`html.b`, `is_xml_namespace`).
pub fn namespaces() -> List<VocabRow> {
    return [
        new VocabRow("on:", r#"on:<event>={fn(e: <EventType>) { ... }}"#,
                     "A DOM event handler. The event must be one latte's table has; see events."),
        new VocabRow("bind:", r#"bind:value={<place>} | bind:checked={<place>}"#,
                     "A two-way binding. It emits an attribute and a handler, so it takes two sequence numbers."),
        new VocabRow("xlink:", r#"xlink:href="...""#,
                     r#"An ordinary XML attribute. xlink:href carries a URL and passes the scheme allowlist, because an SVG <a xlink:href="javascript:"> runs script."#),
        new VocabRow("xml:", r#"xml:lang="...""#,
                     "An ordinary XML attribute."),
        new VocabRow("xmlns:", r#"xmlns:xlink="...""#,
                     "An ordinary XML attribute."),
    ]
}

/// `bind:` targets and the conversions `bind:value` accepts.
pub fn bindings() -> List<VocabRow> {
    return [
        new VocabRow("bind:value", "<input> and <textarea>",
                     "On an input it is value= plus on_input; on a textarea it is on_input plus the text child, and the element may then have no other children. On a <select> it is refused: a select's value is which option carries selected."),
        new VocabRow("bind:checked", "<input>",
                     "flag(checked) plus on_change. It takes no conversion."),
    ]
}

/// The `.suffix` conversions on `bind:value`.
///
/// An unparseable value leaves the field alone rather than writing a zero,
/// which is why they are a closed list and not an expression.
pub fn conversions() -> List<string> {
    return ["int", "float", "bool"]
}

/// Attribute names that are latte's own. None of them reaches the wire.
pub fn reserved_attributes() -> List<VocabRow> {
    return [
        new VocabRow("key", r#"key={<expr>}"#,
                     r#"The identity of one row. It belongs on a tag directly inside a $for body and nowhere else."#),
        new VocabRow("ref", r#"ref={<place>}"#,
                     "On an element, a Reference to the node. On a component tag, an assignment of the child into an Option<T> place, written after every parameter and taking no sequence number."),
        new VocabRow("attrs", r#"attrs={<expr>}"#,
                     "A map of attributes splatted onto the element. Each still passes the name and URL checks at run time."),
        new VocabRow("preserve", "preserve",
                     "The subtree is left alone by the differ."),
        new VocabRow("live", "live",
                     "Every interpolated text run in this subtree is signal-bound: it compiles to live_text, the signals it reads subscribe to it, and a write patches that one text node with no render and no diff. An expression under it that reads no signal is a fault, not a value that renders once and never moves again."),
    ]
}

// ---------------------------------------------------------------- HTML facts
//
// Each list below mirrors a predicate in html.b, and tests/markup.b §1b asks
// the predicate about every name here and about a control corpus of names that
// must answer no. Neither list may grow without the other.

/// `html.b: is_void_element` — the HTML5 void elements.
pub fn void_elements() -> List<string> {
    return ["area", "base", "br", "col", "embed", "hr", "img", "input",
            "link", "meta", "source", "track", "wbr"]
}

/// `html.b: is_raw_text_element` — content is not parsed, and interpolation
/// into it is refused.
pub fn raw_text_elements() -> List<string> {
    return ["script", "style"]
}

/// `html.b: is_rcdata_element`.
pub fn rcdata_elements() -> List<string> {
    return ["textarea", "title"]
}

/// `html.b: eats_leading_newline` — the parser drops one newline after the
/// start tag, so a serializer that means to keep it writes two.
pub fn newline_eating_elements() -> List<string> {
    return ["pre", "textarea", "listing"]
}

/// `html.b: is_boolean_attribute` — present or absent, never a string.
///
/// `disabled="false"` is a *disabled* control in every browser, so the string
/// form is refused and these become `flag`, not `attr`.
pub fn boolean_attributes() -> List<string> {
    return ["allowfullscreen", "async", "autofocus", "autoplay", "checked",
            "controls", "default", "defer", "disabled", "formnovalidate",
            "inert", "ismap", "itemscope", "loop", "multiple", "muted",
            "nomodule", "novalidate", "open", "playsinline", "readonly",
            "required", "reversed", "selected"]
}

/// `html.b: is_url_attribute` — the values that pass the scheme allowlist.
pub fn url_attributes() -> List<string> {
    return ["href", "src", "action", "formaction", "poster", "data",
            "xlink:href"]
}

/// `html.b: scheme_is_allowed` — everything else in a literal is refused at
/// compile time and substituted with `about:blank` at run time.
pub fn allowed_schemes() -> List<string> {
    return ["http", "https", "mailto", "tel"]
}

// ------------------------------------------------------------------ printing

/// One JSON string, with the four escapes JSON requires and a `\u00XX` for
/// every other control byte.
pub fn json_string(value: string) -> string {
    let parts: List<string> = []
    parts.push("\"")
    var i: int = 0
    for i < value.len() {
        let b: int = value.byte_at(i) as int
        if b == 34 { parts.push("\\\"") }
        else if b == 92 { parts.push("\\\\") }
        else if b == 10 { parts.push("\\n") }
        else if b == 13 { parts.push("\\r") }
        else if b == 9 { parts.push("\\t") }
        else if b < 32 { parts.push("\\u00{hex_byte(b)}") }
        else { parts.push(value.slice(i, i + 1)) }
        i = i + 1
    }
    parts.push("\"")
    return parts.join("")
}

fn json_strings(values: List<string>) -> string {
    let parts: List<string> = []
    for value: string in values { parts.push(json_string(value)) }
    return "[{parts.join(", ")}]"
}

fn json_rows(rows: List<VocabRow>) -> List<string> {
    let out: List<string> = []
    for row: VocabRow in rows {
        out.push("\{\"name\": {json_string(row.name)}, \"detail\": {json_string(row.detail)}, \"note\": {json_string(row.note)}\}")
    }
    return move out
}

/// Every event, with the class its handler takes and the Builder method it
/// becomes — read out of `events.b`, not restated.
fn json_events() -> List<string> {
    let out: List<string> = []
    for name: string in event_names() {
        out.push("\{\"event\": {json_string(name)}, \"family\": {json_string(event_family(name))}, \"method\": {json_string(event_method(name))}\}")
    }
    return move out
}

fn block_of(name: string, rows: List<string>) -> string {
    if rows.is_empty() { return "  {json_string(name)}: []" }
    return "  {json_string(name)}: [\n    {rows.join(",\n    ")}\n  ]"
}

fn line_of(name: string, value: string) -> string {
    return "  {json_string(name)}: {value}"
}

/// The whole vocabulary as JSON, ending in a newline.
///
/// Shaped by hand rather than by a generic writer: an array of names reads on
/// one line and an array of objects reads one per line, which is what the file
/// this replaces did and what a reviewer of a diff needs.
/// The html target's surface. What `latte-bx vocabulary` prints by default,
/// and what `editors/shared/bx.json` carries.
pub fn vocabulary_json() -> string {
    let lines: List<string> = []
    lines.push(line_of("$generated",
        json_string("Written by community-libs/latte/tests/w2_editor_data.b, out of latte's own tables. Do not edit by hand.")))
    lines.push(line_of("$source", json_string("latte bx/vocabulary.b, bx/events.b, bx/html.b, bx/parse.b")))
    lines.push(line_of("$language", json_string("latte markup — a whole-file document, not Beans with tags in it: outside <beans> every < opens a tag")))
    lines.push(block_of("blocks", json_rows(blocks())))
    lines.push(block_of("interpolations", json_rows(interpolations())))
    lines.push(block_of("namespaces", json_rows(namespaces())))
    lines.push(block_of("events", json_events()))
    lines.push(block_of("bindings", json_rows(bindings())))
    lines.push(line_of("conversions", json_strings(conversions())))
    lines.push(block_of("reservedAttributes", json_rows(reserved_attributes())))
    lines.push(line_of("voidElements", json_strings(void_elements())))
    lines.push(line_of("rawTextElements", json_strings(raw_text_elements())))
    lines.push(line_of("rcdataElements", json_strings(rcdata_elements())))
    lines.push(line_of("newlineEatingElements", json_strings(newline_eating_elements())))
    lines.push(line_of("booleanAttributes", json_strings(boolean_attributes())))
    lines.push(line_of("urlAttributes", json_strings(url_attributes())))
    lines.push(line_of("allowedSchemes", json_strings(allowed_schemes())))
    return "\{\n{lines.join(",\n")}\n\}\n"
}

/// The surface for one target.
///
/// An editor offers what the file it is editing can contain, and that is not
/// the same list for a page and for a screen: `<!DOCTYPE>`, `attrs=` and a
/// void element are HTML's, and a closed set of control tags with typed
/// properties is the canvas's. One printer with a target rather than two
/// printers, so a section added to the language appears in both.
pub fn vocabulary_json_for(target: Target) -> string {
    match target {
        html => { return vocabulary_json() }
        canvas => { return canvas_vocabulary_json() }
    }
}

/// The canvas target's surface.
pub fn canvas_vocabulary_json() -> string {
    let lines: List<string> = []
    lines.push(line_of("$generated",
        json_string("Written by community-libs/latte/tests/w3_editor_data.b, out of latte's own tables. Do not edit by hand.")))
    lines.push(line_of("$source", json_string("latte bx/vocabulary.b, bx/canvas_events.b, bx/canvas_widgets.b, bx/parse.b")))
    lines.push(line_of("$target", json_string("canvas")))
    lines.push(line_of("$language", json_string("latte markup for the browser runtime — a whole-file document whose tags are Latte controls, not HTML elements")))
    // The forms are the language's and are the same in both targets, which is
    // the whole point of one front end — minus `$html`, which has nothing to
    // write into here and is refused by name.
    lines.push(block_of("blocks", json_rows(canvas_blocks())))
    lines.push(block_of("interpolations", json_rows(interpolations())))
    lines.push(block_of("events", json_canvas_events()))
    lines.push(block_of("bindings", json_rows(canvas_bindings())))
    lines.push(block_of("reservedAttributes", json_rows(canvas_reserved_attributes())))
    lines.push(line_of("controls", json_strings(canvas_drawn_tags())))
    lines.push(line_of("controlsNotYetDrawn", json_strings(canvas_undrawn_tags())))
    lines.push(line_of("attributes", json_strings(canvas_attribute_names())))
    return "\{\n{lines.join(",\n")}\n\}\n"
}

/// The framework's own attributes, for the canvas target.
///
/// `attrs`, `preserve` and `live` are HTML's: a bag of string attributes, a
/// subtree a third-party script owns, and a text node a signal patches. None
/// of the three has anything to mean here, all three are refused by name in
/// `CanvasRules`, and an editor that offered them would be offering three
/// completions whose only outcome is a diagnostic.
fn canvas_reserved_attributes() -> List<VocabRow> {
    let out: List<VocabRow> = []
    for row: VocabRow in reserved_attributes() {
        if row.name == "attrs" || row.name == "preserve" || row.name == "live" { continue }
        out.push(row)
    }
    return move out
}

/// The control tags a canvas file may use today.
pub fn canvas_drawn_tags() -> List<string> {
    var out: List<string> = []
    for tag: string in canvas_widget_tags() {
        if canvas_tag_is_drawn(tag) { out.push(tag) }
    }
    return move out
}

/// The ones the markup language knows and the renderer has not got yet. An
/// editor offers them greyed rather than not at all, because a reader looking
/// for `<Spinner>` should find out that it exists and is not ready — not that
/// latte has never heard of it.
pub fn canvas_undrawn_tags() -> List<string> {
    var out: List<string> = []
    for tag: string in canvas_widget_tags() {
        if !canvas_tag_is_drawn(tag) { out.push(tag) }
    }
    return move out
}

/// The `$` blocks a canvas file may contain: every one the language has,
/// except the raw-HTML bypass, which has nothing here to bypass.
fn canvas_blocks() -> List<VocabRow> {
    let out: List<VocabRow> = []
    for row: VocabRow in blocks() {
        if row.name == "$html" { continue }
        out.push(row)
    }
    return move out
}

fn json_canvas_events() -> List<string> {
    let out: List<string> = []
    for name: string in canvas_event_names() {
        out.push("    \{\"name\": {json_string(name)}, \"detail\": {json_string("on:{name}=\{fn(e: UiEvent) \{ … \}\}")}, \"note\": {json_string("every canvas handler receives one UiEvent")}\}")
    }
    return move out
}

fn canvas_bindings() -> List<VocabRow> {
    return [
        new VocabRow("bind:value",
            r#"bind:value={self.name}"#,
            "two-way on the controls that hold text a user edits — TextField, SecureField, SearchField and TextArea"),
        new VocabRow("bind:checked",
            r#"bind:checked={self.on}"#,
            "two-way on CheckBox, RadioButton and Switch"),
    ]
}
