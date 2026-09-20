// canvas_widgets.b — the closed set of tags and attributes canvas markup has.
// The runtime's copy is `compose.Vocabulary`; `tests/w3_vocabulary.b` pairs them.

package bx

import latte.visual

/// Whether `tag` names a control latte knows: the closed set. Anything else
/// capitalised is a component; anything else is refused by name.
pub fn canvas_is_widget_tag(tag: string) -> bool {
    if visual.is_tag(tag) { return true }
    if tag == "VStack" { return true }
    if tag == "HStack" { return true }
    if tag == "Grid" { return true }
    if tag == "Box" { return true }
    if tag == "Container" { return true }
    if tag == "Label" { return true }
    if tag == "Button" { return true }
    if tag == "TextField" { return true }
    if tag == "CheckBox" { return true }
    if tag == "Image" { return true }
    if tag == "Slider" { return true }
    if tag == "ProgressBar" { return true }
    if tag == "Separator" { return true }
    if tag == "TextArea" { return true }
    if tag == "ComboBox" { return true }
    if tag == "ScrollView" { return true }
    if tag == "RadioButton" { return true }
    if tag == "Canvas" { return true }
    if tag == "Switch" { return true }
    if tag == "SecureField" { return true }
    if tag == "Stepper" { return true }
    if tag == "LevelIndicator" { return true }
    if tag == "Table" { return true }
    if tag == "SearchField" { return true }
    if tag == "Spinner" { return true }
    if tag == "Link" { return true }
    if tag == "Segmented" { return true }
    if tag == "GroupBox" { return true }
    if tag == "DatePicker" { return true }
    if tag == "ColorWell" { return true }
    if tag == "Disclosure" { return true }
    if tag == "TabView" { return true }
    if tag == "SplitView" { return true }
    if tag == "WebView" { return true }
    if tag == "OutlineView" { return true }
    return false
}

/// Whether `tag` names a component rather than a control: membership of the
/// closed set, not case. `<Buton>` becomes one, and beansc names the type.
pub fn canvas_names_a_component(tag: string) -> bool {
    if tag.len() == 0 { return false }
    if canvas_is_widget_tag(tag) { return false }
    // A retired container is not a component either; it is refused by name.
    if canvas_retired_tag(tag) != "" { return false }
    let first: int = tag.byte_at(0) as int
    return first >= 65 && first <= 90
}

/// The sentence for a container tag that no longer exists, or `""`. Every
/// stack flexes and wraps on request now, so the three families are one.
pub fn canvas_retired_tag(tag: string) -> string {
    if tag == "VFlex" { return "<VFlex> is retired: every <VStack> shares out its leftover by grow and shrink now — write <VStack>" }
    if tag == "HFlex" { return "<HFlex> is retired: every <HStack> shares out its leftover by grow and shrink now — write <HStack>" }
    if tag == "VWrap" { return "<VWrap> is retired: wrapping is an attribute of a stack now — write <VStack wrap>" }
    if tag == "HWrap" { return "<HWrap> is retired: wrapping is an attribute of a stack now — write <HStack wrap>" }
    return ""
}

/// An attribute that is true by being there: `<CheckBox checked />`.
pub fn canvas_is_boolean_attribute(name: string) -> bool {
    if name == "stacked" { return true }
    if name == "enabled" { return true }
    if name == "hidden" { return true }
    if name == "borderless" || name == "compact" { return true }
    if name == "wrap" { return true }
    if name == "checked" { return true }
    if name == "editable" { return true }
    if name == "indeterminate" { return true }
    if name == "open" { return true }
    if name == "animating" { return true }
    if name == "prominent" { return true }
    return false
}

/// The two prefixes an attribute may carry: `on:` subscribes, `bind:` binds
/// both ways. An unknown one is refused, so `onclick=` says what is wrong.
pub fn canvas_is_xml_namespace(prefix: string) -> bool {
    return prefix == "on" || prefix == "bind"
}

/// An attribute the framework reads rather than one the control carries. The
/// cost: a component field called `key` or `ref` cannot be set from markup.
pub fn canvas_is_reserved_attribute(name: string) -> bool {
    return name == "key" || name == "ref"
}

/// Why an attribute that only means something in an HTML document is refused.
/// By name, so the author is not sent looking for a spelling mistake.
pub fn canvas_html_only_attribute(name: string) -> string {
    if name == "attrs" {
        return "attrs= spreads a bag of pass-through attributes onto an element, which means something only where an element carries arbitrary attributes. A latte control has a closed set of typed properties and a component takes its parameters by their Beans names, so there is no bag here and nothing to spread into — write the parameters you mean"
    }
    if name == "preserve" {
        return "preserve keeps a subtree out of the diff, which a page needs because something outside the framework can write into its DOM. Nothing outside latte writes into a control tree, and the differ only ever touches what the markup describes — so a control's rows, pages or contents, set through Stage.widget(key) in on_mount, are already left alone"
    }
    return ""
}

/// Which `Builder` method an attribute becomes: `text`, `flag`, `number` for
/// anything measured, and `word` for a choice out of a fixed set.
pub fn canvas_attribute_call(name: string) -> string {
    if name == "items" { return "items" }
    if name == "labels" { return "labels" }
    if name == "column_widths" { return "column_widths" }
    if name == "editable_when" { return "editable_when" }
    if name == "source" { return "text" }
    let drawing: string = visual.attribute_call(name)
    if drawing != "" { return drawing }
    if name == "text" { return "text" }
    if name == "a11y_label" { return "a11y_label" }
    if canvas_is_boolean_attribute(name) { return "flag" }
    if name == "min" || name == "max" || name == "value" ||
       name == "font_size" || name == "step" || name == "opacity" ||
       name == "day" || name == "corner_radius" || name == "border_width" ||
       name == "baseline" || name == "overhang" || name == "divider" {
        return "number"
    }
    if name == "alignment" || name == "selected" || name == "lines" ||
       name == "font_weight" { return "number" }
    if name == "spacing" || name == "line_spacing" || name == "padding" || name == "margin" ||
       name == "grow" || name == "shrink" || name == "basis" || name == "flex" ||
       name == "width" || name == "height" ||
       name == "x" || name == "y" {
        return "number"
    }
    // The per-edge and per-axis forms of `padding` and `margin`. Each writes
    // only the edges it names, in source order — see `Builder.layout_number`.
    if name == "padding_x" || name == "padding_y" ||
       name == "padding_top" || name == "padding_right" ||
       name == "padding_bottom" || name == "padding_left" ||
       name == "margin_x" || name == "margin_y" ||
       name == "margin_top" || name == "margin_right" ||
       name == "margin_bottom" || name == "margin_left" {
        return "number"
    }
    // A bound on one side. `width` is `min_width` and `max_width` at once.
    if name == "min_width" || name == "max_width" ||
       name == "min_height" || name == "max_height" {
        return "number"
    }
    // A grid's own. `min_column` is the narrowest a column may be before the
    // grid uses one fewer of them, which is what makes a shelf reflow.
    if name == "min_column" || name == "max_column" ||
       name == "column_gap" || name == "row_gap" {
        return "number"
    }
    // A share of the room, 0 to 100, and a width-over-height shape.
    if name == "width_percent" || name == "height_percent" || name == "aspect_ratio" {
        return "number"
    }
    // Shown only while the box around it is at least, or under, a width.
    if name == "hide_below" || name == "hide_above" {
        return "number"
    }
    // The far edges of a <Box>; `x` and `y` are the near ones.
    if name == "right" || name == "bottom" {
        return "number"
    }
    // An element's own cross-axis place, whatever it arranges itself.
    if name == "align_self" { return "word" }
    // A colour is a word here and a whole number by the time it reaches the
    // ABI, parsed once in `Builder.word` so `#abc` means one thing everywhere.
    if name == "align" || name == "justify" || name == "font_role" ||
       name == "columns" || canvas_is_colour_attribute(name) { return "word" }
    return ""
}

/// A word this attribute would accept, for a refusal that shows the shape
/// rather than a word from some other attribute's set.
pub fn canvas_word_example(name: string) -> string {
    if name == "transition_easing" { return "ease_in_out" }
    if name == "font_role" { return "body" }
    if name == "columns" { return "160 1fr auto" }
    return "center"
}

/// Whether `name` on a component tag places the component rather than setting
/// a field: what its root asks of the run around it. Mirrors `Vocabulary`.
pub fn canvas_is_placement_attribute(name: string) -> bool {
    return name == "margin" || name == "margin_x" || name == "margin_y" ||
           name == "margin_top" || name == "margin_right" ||
           name == "margin_bottom" || name == "margin_left" ||
           name == "grow" || name == "shrink" || name == "basis" || name == "flex" ||
           name == "width" || name == "height" ||
           name == "min_width" || name == "max_width" ||
           name == "min_height" || name == "max_height" ||
           name == "width_percent" || name == "height_percent" ||
           name == "aspect_ratio" ||
           name == "hide_below" || name == "hide_above" ||
           name == "x" || name == "y" || name == "right" || name == "bottom" ||
           name == "align" || name == "align_self"
}

/// The attributes whose value is a colour, written `#rgb`, `#rrggbb` or
/// `#rrggbbaa`. One list, so the spelling is parsed in exactly one place.
pub fn canvas_is_colour_attribute(name: string) -> bool {
    if visual.is_colour(name) { return true }
    return name == "color" || name == "background" ||
           name == "border_color" || name == "text_color"
}

/// Every attribute name latte knows, for a diagnostic that can suggest one.
pub fn canvas_attribute_names() -> List<string> {
    var names: List<string> = ["a11y_label", "borderless", "compact", "align", "align_self", "alignment", "animating", "aspect_ratio", "background", "basis",
            "border_color", "border_width", "bottom", "checked", "color", "column_gap", "columns", "column_widths",
            "corner_radius",
            "day", "divider", "editable", "editable_when", "enabled", "flex",
            "baseline", "font_role", "font_size", "font_weight", "grow", "height", "height_percent", "hidden",
            "hide_above", "hide_below", "indeterminate", "items",
            "justify", "labels", "line_spacing", "lines", "margin", "margin_bottom", "margin_left", "margin_right",
            "margin_top", "margin_x", "margin_y", "max", "max_height",
            "max_column", "max_width", "min", "min_column", "min_height", "min_width", "opacity", "overhang",
            "open", "padding", "prominent", "padding_bottom", "padding_left",
            "padding_right", "padding_top", "padding_x", "padding_y",
            "right", "row_gap", "selected", "shrink", "source", "spacing", "stacked", "step", "text", "text_color",
            "value", "width", "width_percent", "wrap", "x", "y"]
    for name: string in visual.attribute_names() { if name != "source" { names.push(name) } }
    return move names
}

/// Every control tag, for the same reason.
pub fn canvas_widget_tags() -> List<string> {
    var tags: List<string> = ["Box", "Button", "Canvas", "CheckBox", "ColorWell", "ComboBox",
            "Container", "DatePicker", "Disclosure",
            "Grid", "GroupBox", "HStack", "Image", "Label",
            "LevelIndicator", "Link",
            "ProgressBar", "RadioButton", "ScrollView", "SecureField",
            "SearchField", "Segmented", "Separator", "Slider", "Spinner", "SplitView", "Stepper",
            "Switch", "TabView", "Table", "TextArea", "TextField", "VStack",
            "OutlineView", "WebView"]
    for tag: string in visual.tags() { tags.push(tag) }
    return move tags
}

/// Whether a tag names a drawing shape rather than a control: `<Rectangle>`
/// and its siblings are a `visual.Kind`, so the kind table steps over them.
pub fn canvas_is_drawing_tag(tag: string) -> bool {
    return visual.kind_of(tag) != none
}

/// Whether Latte has a renderer for this tag. Refused here, at compile time,
/// where it names the line; `tests/w3_vocabulary.b` § 3 pairs it with the kinds.
pub fn canvas_tag_is_drawn(tag: string) -> bool {
    if tag == "ColorWell" { return false }
    if tag == "DatePicker" { return false }
    if tag == "Image" { return false }
    if tag == "Link" { return false }
    if tag == "OutlineView" { return false }
    if tag == "Spinner" { return false }
    if tag == "WebView" { return false }
    return canvas_is_widget_tag(tag)
}

/// The tags a canvas component can really be built from, comma-separated.
pub fn canvas_drawn_list() -> string {
    var drawn: List<string> = []
    for tag: string in canvas_widget_tags() {
        if canvas_tag_is_drawn(tag) { drawn.push(tag) }
    }
    return drawn.join(", ")
}

/// Whether a control tag carries an attribute; a layout name answers `true`,
/// because it belongs to the parent. `tests/w3_vocabulary.b` § 5 pairs it.
pub fn canvas_tag_carries(tag: string, name: string) -> bool {
    if name == "a11y_label" { return canvas_is_widget_tag(tag) }
    match visual.kind_of(tag) {
        some(kind) => {
            if visual.attribute_call(name) != "" { return visual.carries(kind, name) }
            // A drawing's painted box can reach past its layout box too.
            return canvas_is_placement_attribute(name) || name == "hidden" ||
                   name == "overhang" || name == "corner_radius"
        }
        none => {}
    }
    if name == "items" { return tag == "ComboBox" || tag == "Segmented" }
    if name == "labels" { return tag == "TabView" }
    if name == "columns" { return tag == "Grid" || tag == "Table" }
    if name == "column_widths" || name == "source" { return tag == "Table" }
    if name == "editable_when" { return tag == "Table" }
    if name == "stacked" || name == "divider" { return tag == "SplitView" }
    // Drawing names belong to drawing tags, apart from Table's own source.
    // Without this guard the legacy final default makes Box.fill look valid.
    if visual.attribute_call(name) != "" { return false }
    if name == "enabled" { return canvas_one_of(tag, ["Button", "TextField", "SecureField",
                                               "SearchField", "CheckBox", "RadioButton",
                                               "Switch", "Slider", "Stepper", "ComboBox",
                                               "Segmented", "DatePicker", "ColorWell"]) }
    if name == "checked" { return canvas_one_of(tag, ["Button", "CheckBox", "RadioButton", "Switch"]) }
    if name == "min" || name == "max" || name == "value" {
        return canvas_one_of(tag, ["Slider", "Stepper", "ProgressBar", "LevelIndicator"])
    }
    if name == "editable" { return canvas_is_typed_into(tag) }
    // A label lays text out and is not typed into, which is the one difference
    // between these two lists.
    if name == "alignment" { return canvas_is_typed_into(tag) || tag == "Label" }
    // The same five as `alignment`, and for the same reason: each is a plain
    // text view on all four hosts, so one name means one thing.
    if name == "text_color" { return canvas_is_typed_into(tag) || tag == "Label" }
    // A table, an outline, a group box, a disclosure and a tab view show words
    // that are a title or a cell, not the control's own text.
    if name == "font_size" || name == "font_role" || name == "font_weight" ||
       name == "baseline" {
        return canvas_one_of(tag, ["Label", "Button", "TextField",
                            "SecureField", "SearchField", "TextArea",
                            "CheckBox", "RadioButton", "ComboBox",
                            "Link", "Segmented", "DatePicker"])
    }
    if name == "step" { return canvas_one_of(tag, ["Slider", "Stepper"]) }
    // Only a label wraps; every other control draws its words on one line.
    if name == "lines" { return tag == "Label" }
    if name == "prominent" { return tag == "Button" }
    if name == "borderless" { return tag == "TabView" }
    if name == "compact" { return tag == "Table" || tag == "OutlineView" }
    // The four bezelled text controls draw an opaque bezel over anything set
    // behind them. Corners and borders have no such rule.
    if name == "background" { return !canvas_is_typed_into(tag) }
    if name == "selected" { return canvas_one_of(tag, ["ComboBox", "TabView", "Segmented"]) }
    // Not a spinner: a spinner is always indeterminate, which is the whole
    // difference between the two controls.
    if name == "indeterminate" { return tag == "ProgressBar" }
    if name == "animating" { return tag == "Spinner" }
    if name == "day" { return tag == "DatePicker" }
    if name == "color" { return tag == "ColorWell" }
    if name == "open" { return tag == "Disclosure" }
    // `hidden` and `opacity` are the view's own and every control is a view.
    return true
}

/// Which control tags carry `name`, for a refusal that says where it belongs.
/// Computed from `tag_carries`, so a changed rule changes the sentence.
pub fn canvas_tags_carrying(name: string) -> string {
    var carried: List<string> = []
    for tag: string in canvas_widget_tags() {
        if canvas_tag_carries(tag, name) { carried.push(tag) }
    }
    if carried.len() == 0 { return "no control carries it" }
    return carried.join(", ")
}

/// The four a person types into — the same four that refuse a background,
/// because a control has a bezel because you type into it.
fn canvas_is_typed_into(tag: string) -> bool {
    return canvas_one_of(tag, ["TextField", "SecureField", "SearchField", "TextArea"])
}

fn canvas_one_of(tag: string, tags: List<string>) -> bool {
    for candidate: string in tags {
        if candidate == tag { return true }
    }
    return false
}

/// Whether a tag is spelled like an identifier. A correctness question, not a
/// security one: a bad one makes a generated file that does not parse.
pub fn canvas_tag_name_is_safe(tag: string) -> bool {
    return canvas_is_identifier(tag)
}

/// The same, for an attribute name, after any `on:` or `bind:` prefix.
pub fn canvas_attribute_name_is_safe(name: string) -> bool {
    return canvas_is_identifier(name)
}

fn canvas_is_identifier(text: string) -> bool {
    if text.len() == 0 { return false }
    var index: int = 0
    for index < text.len() {
        let b: int = text.byte_at(index) as int
        let letter: bool = (b >= 65 && b <= 90) || (b >= 97 && b <= 122)
        let digit: bool = b >= 48 && b <= 57
        if index == 0 {
            if !letter && b != 95 { return false }
        } else {
            if !letter && !digit && b != 95 { return false }
        }
        index = index + 1
    }
    return true
}

// --------------------------------------------------- embedding in Beans source

/// Escape `value` for a Beans double-quoted string. Braces too, not only
/// quotes and backslashes, because a Beans string interpolates.
pub fn canvas_escape_beans_string(value: string) -> string {
    let parts: List<string> = []
    var run: int = 0
    var i: int = 0
    for i < value.len() {
        let b: int = value.byte_at(i) as int
        var replacement: string = ""
        if b == 92 { replacement = "\\\\" }
        if b == 34 { replacement = "\\\"" }
        if b == 123 { replacement = "\\\{" }
        if b == 125 { replacement = "\\\}" }
        if b == 10 { replacement = "\\n" }
        if b == 9 { replacement = "\\t" }
        if b == 13 { replacement = "\\r" }
        if b == 0 { replacement = "\\0" }
        if replacement == "" && b < 32 {
            replacement = "\\x{canvas_hex_byte(b)}"
        }
        if b == 127 { replacement = "\\x7f" }
        if replacement != "" {
            parts.push(value.slice(run, i))
            parts.push(replacement)
            run = i + 1
        }
        i = i + 1
    }
    if run == 0 { return value }
    parts.push(value.slice(run, value.len()))
    return parts.join("")
}

/// Two lowercase hex digits for a byte.
pub fn canvas_hex_byte(value: int) -> string {
    let digits: string = "0123456789abcdef"
    let hi: int = (value / 16) % 16
    let lo: int = value % 16
    return "{digits.slice(hi, hi + 1)}{digits.slice(lo, lo + 1)}"
}

// ------------------------------------------------------------- did you mean?

/// The attribute names, comma-separated, for the body of a diagnostic.
pub fn canvas_attribute_list() -> string {
    return canvas_attribute_names().join(", ")
}

/// The tag names, comma-separated.
pub fn canvas_widget_list() -> string {
    return canvas_widget_tags().join(", ")
}

/// The nearest attribute name to `name`, or `""` when nothing is close enough
/// to suggest.
pub fn canvas_nearest_attribute(name: string) -> string {
    return canvas_nearest_of(name, canvas_attribute_names())
}

/// The nearest of `candidates` within two edits, and not more: a wrong
/// suggestion sends the reader to fix the wrong thing.
pub fn canvas_nearest_of(name: string, candidates: List<string>) -> string {
    var best: string = ""
    var best_distance: int = 3
    for candidate: string in candidates {
        let distance: int = canvas_edit_distance(name, candidate)
        if distance < best_distance {
            best_distance = distance
            best = candidate
        }
    }
    return best
}

/// Levenshtein distance between two short ASCII names, two rows rather than a
/// matrix: it runs once per bad name and never on a measured path.
pub fn canvas_edit_distance(from: string, to: string) -> int {
    let width: int = to.len() + 1
    var previous: List<int> = []
    var current: List<int> = []
    var i: int = 0
    for i < width {
        previous.push(i)
        current.push(0)
        i = i + 1
    }
    var row: int = 1
    for row <= from.len() {
        current[0] = row
        var column: int = 1
        for column < width {
            var cost: int = 1
            if from.byte_at(row - 1) == to.byte_at(column - 1) { cost = 0 }
            var best: int = previous[column] + 1
            if current[column - 1] + 1 < best { best = current[column - 1] + 1 }
            if previous[column - 1] + cost < best { best = previous[column - 1] + cost }
            current[column] = best
            column = column + 1
        }
        var copy: int = 0
        for copy < width {
            previous[copy] = current[copy]
            copy = copy + 1
        }
        row = row + 1
    }
    return previous[width - 1]
}
