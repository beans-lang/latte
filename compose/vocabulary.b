// The names markup uses, and what they mean.
package compose

import latte.controls
import latte.input
import latte.platform
import latte.layout
import latte.geometry
import latte.visual

/// Translates the names an author writes into the integers everything below
/// uses.
///
/// One table, in one place, consulted once per attribute per render. Markup
/// says `<Button title="Buy" on:click=… />`; the differ and the applier see
/// widget kind 3, property 0 and event 1. Keeping the translation here rather
/// than spreading it through the builder means adding a widget or a property
/// is one edit, and means the whole layer below is comparing integers.
///
/// Unknown names are refused rather than ignored. A misspelled attribute that
/// silently does nothing is the single most common way a user interface ends
/// up not matching the markup that describes it.
pub class Vocabulary {
    /// The widget behind a tag, or `none` for a tag latte does not know.
    pub static fn kind_of(tag: string) -> Option<controls.WidgetKind> {
        if visual.is_tag(tag) { return some(controls.WidgetKind.canvas) }
        if tag == "VStack" || tag == "HStack" ||
           tag == "Grid" || tag == "Box" || tag == "Container" {
            return some(controls.WidgetKind.container)
        }
        if tag == "Label" { return some(controls.WidgetKind.label) }
        if tag == "Button" { return some(controls.WidgetKind.button) }
        if tag == "TextField" { return some(controls.WidgetKind.text_field) }
        if tag == "CheckBox" { return some(controls.WidgetKind.check_box) }
        if tag == "Image" { return some(controls.WidgetKind.image_view) }
        if tag == "Slider" { return some(controls.WidgetKind.slider) }
        if tag == "ProgressBar" { return some(controls.WidgetKind.progress_bar) }
        if tag == "Separator" { return some(controls.WidgetKind.separator) }
        if tag == "TextArea" { return some(controls.WidgetKind.text_area) }
        if tag == "ComboBox" { return some(controls.WidgetKind.combo_box) }
        if tag == "ScrollView" { return some(controls.WidgetKind.scroll_view) }
        if tag == "RadioButton" { return some(controls.WidgetKind.radio_button) }
        if tag == "Canvas" { return some(controls.WidgetKind.canvas) }
        if tag == "Switch" { return some(controls.WidgetKind.switch) }
        if tag == "SecureField" { return some(controls.WidgetKind.secure_field) }
        if tag == "Stepper" { return some(controls.WidgetKind.stepper) }
        if tag == "LevelIndicator" { return some(controls.WidgetKind.level_indicator) }
        if tag == "Table" { return some(controls.WidgetKind.table) }
        if tag == "SearchField" { return some(controls.WidgetKind.search_field) }
        if tag == "Spinner" { return some(controls.WidgetKind.spinner) }
        if tag == "Link" { return some(controls.WidgetKind.link) }
        if tag == "Segmented" { return some(controls.WidgetKind.segmented) }
        if tag == "GroupBox" { return some(controls.WidgetKind.group_box) }
        if tag == "DatePicker" { return some(controls.WidgetKind.date_picker) }
        if tag == "ColorWell" { return some(controls.WidgetKind.color_well) }
        if tag == "Disclosure" { return some(controls.WidgetKind.disclosure) }
        if tag == "TabView" { return some(controls.WidgetKind.tab_view) }
        if tag == "SplitView" { return some(controls.WidgetKind.split_view) }
        if tag == "WebView" { return some(controls.WidgetKind.web_view) }
        if tag == "OutlineView" { return some(controls.WidgetKind.outline_view) }
        return none
    }

    /// A fresh layout for a container tag. Fresh and not shared, because a
    /// layout holds the spacing and padding of the one container it belongs
    /// to; sharing one would make every `VStack` in an application take the
    /// spacing of whichever was configured last.
    pub static fn arranger_of(tag: string) -> Option<layout.Layout> {
        // Every stack flexes: grow and shrink share the leftover, and `wrap`
        // breaks it into lines. `StackLayout` stays for hand-built trees.
        if tag == "VStack" { return some(layout.FlexLayout.column(0.0)) }
        if tag == "HStack" { return some(layout.FlexLayout.row(0.0)) }
        if tag == "Box" { return some(new layout.AbsoluteLayout()) }
        // No columns declared: `columns` or `min_column` says what they are,
        // and a grid that is told neither is the one column it always was.
        if tag == "Grid" { return some(new layout.GridLayout()) }
        // The containers that hold a subtree and have nothing to say about
        // where it goes. Without an arranger a node is a leaf, and a leaf
        // places none of its children — so before this line every control
        // inside a `<GroupBox>` in markup came out at 0,0,0,0, laid out
        // correctly by a layout that had decided there was nothing to lay out.
        //
        // `Container` and `Canvas` are deliberately not here. A bare
        // `<Container />` is a box a program fills itself, and a canvas is
        // drawn rather than filled; giving either one children that fill it
        // would change what those two tags have always meant.
        // A scroll view fills like the rest, except on the axis it scrolls:
        // its content is measured with no ceiling, or nothing ever scrolls.
        if tag == "ScrollView" { return some(new layout.ScrollLayout()) }
        if tag == "GroupBox" || tag == "Disclosure" ||
           tag == "TabView" || tag == "SplitView" {
            return some(new layout.FillLayout())
        }
        return none
    }

    /// The sentence for a container tag that no longer exists, or `""`.
    /// Mirrors `bx.canvas_retired_tag`; `tools/check_vocabulary.sh` pairs them.
    pub static fn retired(tag: string) -> string {
        if tag == "VFlex" { return "<VFlex> is retired: every <VStack> shares out its leftover by grow and shrink now — write <VStack>" }
        if tag == "HFlex" { return "<HFlex> is retired: every <HStack> shares out its leftover by grow and shrink now — write <HStack>" }
        if tag == "VWrap" { return "<VWrap> is retired: wrapping is an attribute of a stack now — write <VStack wrap>" }
        if tag == "HWrap" { return "<HWrap> is retired: wrapping is an attribute of a stack now — write <HStack wrap>" }
        return ""
    }

    /// The host property an attribute name sets, or -1.
    pub static fn property_of(name: string) -> int { return NameMemo.instance.property_of(name) }

    static fn compute_property_of(name: string) -> int {
        if name == "a11y_label" { return platform.S_A11Y_LABEL }
        if name == "items" { return CHOICES_PROPERTY }
        if name == "labels" { return TAB_LABELS_PROPERTY }
        if name == "columns" { return TABLE_COLUMNS_PROPERTY }
        if name == "column_widths" { return TABLE_WIDTHS_PROPERTY }
        if name == "source" { return TABLE_SOURCE_PROPERTY }
        if name == "editable_when" { return TABLE_EDIT_POLICY_PROPERTY }
        if name == "stacked" { return platform.P_AXIS }
        if name == "divider" { return platform.P_DIVIDER }
        let drawing: int = visual.property_of(name)
        if drawing >= 0 { return drawing }
        if name == "checked" { return platform.P_CHECKED }
        if name == "enabled" { return platform.P_ENABLED }
        if name == "hidden" { return platform.P_HIDDEN }
        if name == "min" { return platform.P_MIN }
        if name == "max" { return platform.P_MAX }
        if name == "value" { return platform.P_VALUE }
        if name == "editable" { return platform.P_EDITABLE }
        if name == "alignment" { return platform.P_ALIGNMENT }
        if name == "font_size" { return platform.P_FONT_SIZE }
        if name == "font_weight" { return platform.P_FONT_WEIGHT }
        if name == "baseline" { return platform.P_BASELINE }
        if name == "overhang" { return platform.P_OVERHANG }
        if name == "prominent" { return platform.P_PROMINENT }
        // A role is a size, so it lands on the same property — and two
        // names on one property is what makes the last one written win.
        if name == "font_role" { return platform.P_FONT_SIZE }
        if name == "step" { return platform.P_STEP }
        if name == "selected" { return platform.P_SELECTED }
        if name == "indeterminate" { return platform.P_INDETERMINATE }
        if name == "opacity" { return platform.P_OPACITY }
        if name == "lines" { return platform.P_LINES }
        if name == "borderless" { return platform.P_BORDERLESS }
        if name == "compact" { return platform.P_COMPACT }
        if name == "day" { return platform.P_DATE }
        if name == "color" { return platform.P_COLOR }
        if name == "open" { return platform.P_EXPANDED }
        if name == "animating" { return platform.P_ANIMATING }
        if name == "background" { return platform.P_BG_COLOR }
        if name == "corner_radius" { return platform.P_CORNER_RADIUS }
        if name == "border_width" { return platform.P_BORDER_WIDTH }
        if name == "border_color" { return platform.P_BORDER_COLOR }
        if name == "text_color" { return platform.P_FG_COLOR }
        return -1
    }

    /// Whether a control of `kind` carries the attribute `name`.
    ///
    /// Asked of the host, so there is one answer rather than a copy above the
    /// ABI. A name that is not a property answers `true`: layout names belong
    /// to no control, and an unknown name is refused before this is reached.
    pub static fn carries(kind: controls.WidgetKind, name: string) -> bool {
        if name == "a11y_label" { return true }
        if name == "items" { return kind == controls.WidgetKind.combo_box || kind == controls.WidgetKind.segmented }
        if name == "labels" { return kind == controls.WidgetKind.tab_view }
        if name == "columns" || name == "column_widths" || name == "source" || name == "editable_when" { return kind == controls.WidgetKind.table }
        if name == "stacked" || name == "divider" { return kind == controls.WidgetKind.split_view }
        if name == "overhang" { return true }
        if visual.attribute_call(name) != "" { return false }
        let property: int = Vocabulary.property_of(name)
        if property < 0 { return true }
        return controls.KindRules.carries(kind, platform.KEY_PROPERTY, property).or(false)
    }

    /// One column of a track list: `160` points, `1fr` a share of what is
    /// left, `auto` the widest child in it.
    pub static fn track_of(word: string) -> Option<layout.Track> {
        if word == "auto" { return some(layout.Track.auto()) }
        if word.ends_with("fr") {
            match word.slice(0, word.len() - 2).to_float() {
                err(problem) => { return none }
                ok(weight) => {
                    if weight <= 0.0 { return none }
                    return some(layout.Track.fraction(weight))
                }
            }
        }
        match word.to_float() {
            err(problem) => { return none }
            ok(points) => {
                if points < 0.0 { return none }
                return some(layout.Track.fixed(points))
            }
        }
    }

    /// The system font role a word names, or `none`. `mono` is deliberately
    /// absent: it is body's size in another family, and a family is not a
    /// property a control carries.
    pub static fn font_role_of(word: string) -> Option<platform.SystemFont> {
        if word == "body" { return some(platform.SystemFont.body) }
        if word == "heading" { return some(platform.SystemFont.heading) }
        if word == "caption" { return some(platform.SystemFont.caption) }
        return none
    }

    /// Whether this attribute's value is a colour, written `#rgb`, `#rrggbb`
    /// or `#rrggbbaa`. Mirrors `bx.is_colour_attribute`.
    pub static fn is_colour(name: string) -> bool {
        if visual.is_colour(name) { return true }
        return name == "color" || name == "background" ||
               name == "border_color" || name == "text_color"
    }

    /// Which controls carry `name`, for a refusal that says where it belongs.
    pub static fn who_carries(name: string) -> string {
        var carried: List<string> = []
        for kind: controls.WidgetKind in controls.WidgetKind.all() {
            if Vocabulary.carries(kind, name) { carried.push(kind.name()) }
        }
        if carried.len() == 0 { return "no control carries it" }
        return "{name} is carried by {carried.join(", ")}"
    }

    /// How a property's value travels.
    pub static fn kind_of_property(name: string) -> AttributeKind { return NameMemo.instance.kind_of(name) }

    static fn compute_kind_of_property(name: string) -> AttributeKind {
        if name == "a11y_label" { return AttributeKind.text }
        if name == "items" { return AttributeKind.items }
        if name == "labels" { return AttributeKind.items }
        if name == "columns" { return AttributeKind.items }
        if name == "column_widths" { return AttributeKind.numbers }
        if name == "source" { return AttributeKind.table_source }
        if name == "editable_when" { return AttributeKind.table_edit_policy }
        if name == "divider" { return AttributeKind.real }
        if name == "stroke_width" || name == "rotation" || name == "scale_x" || name == "scale_y" ||
           name == "shadow_blur" || name == "shadow_dx" || name == "shadow_dy" ||
           name == "clip_radius" || name == "transition_seconds" ||
           name == "offset_x" || name == "offset_y" {
            return AttributeKind.real
        }
        if name == "min" || name == "max" || name == "value" ||
           name == "font_size" || name == "step" || name == "opacity" ||
           name == "day" || name == "corner_radius" || name == "border_width" ||
           name == "baseline" || name == "overhang" {
            return AttributeKind.real
        }
        // A colour travels as a whole number, packed 0xRRGGBBAA — the same
        // integer the ABI carries and the same one a value_changed event
        // hands back. It is written in markup as `#rrggbbaa`, and `Builder`
        // is what turns the one into the other.
        if name == "checked" || name == "alignment" || name == "selected" ||
           name == "transition_easing" || name == "font_weight" ||
           name == "lines" || Vocabulary.is_colour(name) {
            return AttributeKind.whole
        }
        if name == "open" || name == "animating" || name == "prominent" { return AttributeKind.flag }
        return AttributeKind.flag
    }

    /// The event an `on:` name subscribes to, or `none`.
    ///
    /// The names are the ones a web author already knows, mapped onto
    /// latte's kinds. `click` is `activate` because a button is activated by
    /// a click, by the space bar, by a keyboard shortcut and by an
    /// accessibility client — a framework that named it `click` all the way
    /// down would tempt a handler into reading a mouse position that is not
    /// there.
    pub static fn event_of(name: string) -> Option<input.EventKind> {
        if name == "click" || name == "activate" { return some(input.EventKind.activate) }
        if name == "change" { return some(input.EventKind.value_changed) }
        if name == "commit" { return some(input.EventKind.text_commit) }
        if name == "select" { return some(input.EventKind.selection) }
        if name == "focus" { return some(input.EventKind.focus) }
        if name == "blur" { return some(input.EventKind.blur) }
        if name == "pointer_down" { return some(input.EventKind.pointer_down) }
        if name == "pointer_up" { return some(input.EventKind.pointer_up) }
        if name == "pointer_move" { return some(input.EventKind.pointer_move) }
        if name == "key_down" { return some(input.EventKind.key_down) }
        if name == "key_up" { return some(input.EventKind.key_up) }
        return none
    }

    /// Whether a name configures the layout rather than the control.
    ///
    /// `spacing`, `padding`, `justify` and `align` belong to the container's
    /// arrangement; `grow`, `shrink`, `basis`, `margin`, `width` and `height`
    /// belong to what this element asks of the run it sits in. Neither ever
    /// reaches the platform as a property, which is why they are separated
    /// here and not discovered by the applier finding no property id.
    ///
    /// `bx.canvas_is_placement_attribute` is the compiler's copy of the
    /// placement half, and `tests/w3_vocabulary.b` § 6 pairs the two.
    pub static fn is_layout_name(name: string) -> bool { return NameMemo.instance.is_layout(name) }

    static fn compute_is_layout_name(name: string) -> bool {
        return name == "spacing" || name == "line_spacing" || name == "padding" || name == "justify" ||
               name == "align" || name == "grow" || name == "shrink" ||
               name == "basis" || name == "flex" || name == "wrap" ||
               name == "margin" || name == "width" ||
               name == "height" || name == "x" || name == "y" ||
               name == "padding_x" || name == "padding_y" ||
               name == "padding_top" || name == "padding_right" ||
               name == "padding_bottom" || name == "padding_left" ||
               name == "margin_x" || name == "margin_y" ||
               name == "margin_top" || name == "margin_right" ||
               name == "margin_bottom" || name == "margin_left" ||
               name == "min_width" || name == "max_width" ||
               name == "min_height" || name == "max_height" ||
               name == "width_percent" || name == "height_percent" ||
               name == "aspect_ratio" ||
               name == "hide_below" || name == "hide_above" ||
               name == "right" || name == "bottom" || name == "align_self" ||
               name == "columns" || name == "min_column" || name == "max_column" ||
               name == "column_gap" || name == "row_gap"
    }

    /// Whether a component tag may carry `name`: what the component's root asks
    /// of the run around it, written by the parent that places it.
    pub static fn is_placement_name(name: string) -> bool {
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

    /// The edge a padding name writes: `top`, `right`, `bottom`, `left`, `x` for
    /// both sides or `y` for top and bottom. `""` for anything else, `padding` included.
    pub static fn padding_edge(name: string) -> string {
        if name == "padding_x" { return "x" }
        if name == "padding_y" { return "y" }
        if name == "padding_top" { return "top" }
        if name == "padding_right" { return "right" }
        if name == "padding_bottom" { return "bottom" }
        if name == "padding_left" { return "left" }
        return ""
    }

    /// The same for margin: `margin_left` writes `left`, `margin_y` writes
    /// top and bottom, and `margin` itself answers `""`.
    pub static fn margin_edge(name: string) -> string {
        if name == "margin_x" { return "x" }
        if name == "margin_y" { return "y" }
        if name == "margin_top" { return "top" }
        if name == "margin_right" { return "right" }
        if name == "margin_bottom" { return "bottom" }
        if name == "margin_left" { return "left" }
        return ""
    }

    pub static fn align_of(name: string) -> Option<geometry.Align> {
        if name == "start" { return some(geometry.Align.start) }
        if name == "center" { return some(geometry.Align.center) }
        if name == "end" { return some(geometry.Align.end) }
        if name == "stretch" { return some(geometry.Align.stretch) }
        return none
    }

    pub static fn justify_of(name: string) -> Option<layout.Justify> {
        if name == "start" { return some(layout.Justify.start) }
        if name == "center" { return some(layout.Justify.center) }
        if name == "end" { return some(layout.Justify.end) }
        if name == "space_between" { return some(layout.Justify.space_between) }
        if name == "space_around" { return some(layout.Justify.space_around) }
        if name == "space_evenly" { return some(layout.Justify.space_evenly) }
        return none
    }
}

/// What a name means, worked out once.
///
/// Every table in `Vocabulary` is a walk down a list of string comparisons,
/// and the builder asks three of them for every attribute of every element.
/// A table of two hundred visible cells asked about a hundred thousand times
/// for one frame, which was most of what a scroll that crossed a row cost.
/// The tables are fixed for the life of the process, so each answer is kept.
pub singleton class NameMemo {
    properties: Map<string, int> = {}
    kinds: Map<string, AttributeKind> = {}
    layouts: Map<string, bool> = {}
    fn init() {}
    pub fn property_of(name: string) -> int {
        match self.properties.get(name) { some(found) => { return found } none => {} }
        let answer: int = Vocabulary.compute_property_of(name)
        self.properties[name] = answer
        return answer
    }
    pub fn kind_of(name: string) -> AttributeKind {
        match self.kinds.get(name) { some(found) => { return found } none => {} }
        let answer: AttributeKind = Vocabulary.compute_kind_of_property(name)
        self.kinds[name] = answer
        return answer
    }
    pub fn is_layout(name: string) -> bool {
        match self.layouts.get(name) { some(found) => { return found } none => {} }
        let answer: bool = Vocabulary.compute_is_layout_name(name)
        self.layouts[name] = answer
        return answer
    }
}
