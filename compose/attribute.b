// One named value on a described widget.
package compose

import latte.platform
import latte.controls
import latte.visual

/// Beans-only key for a typed choice list; never sent through the host ABI.
pub const CHOICES_PROPERTY: int = 1001
pub const TAB_LABELS_PROPERTY: int = 1002
pub const TABLE_COLUMNS_PROPERTY: int = 1003
pub const TABLE_WIDTHS_PROPERTY: int = 1004
pub const TABLE_SOURCE_PROPERTY: int = 1005
pub const TABLE_EDIT_POLICY_PROPERTY: int = 1006

pub class TableEditRule {
    policy: fn(int, int) -> bool
    pub fn init(policy: fn(int, int) -> bool) { self.policy = policy }
    pub fn callback() -> fn(int, int) -> bool { return self.policy }
}

/// Copyable, immutable choice list inside an Attribute value.
pub class StringItems {
    entries: List<string> = []
    pub fn init(values: List<string>) {
        for value: string in values { self.entries.push(value) }
    }
    pub fn count() -> int { return self.entries.len() }
    pub fn at(index: int) -> string { return self.entries[index] }
    pub fn same_as(other: StringItems) -> bool {
        if self.entries.len() != other.entries.len() { return false }
        for index: int in 0..self.entries.len() { if self.entries[index] != other.entries[index] { return false } }
        return true
    }
    pub fn to_list() -> List<string> {
        var copy: List<string> = []
        for value: string in self.entries { copy.push(value) }
        return move copy
    }
    pub fn show() -> string { return self.entries.join(", ") }
}

pub class NumberItems {
    entries: List<f64> = []
    pub fn init(values: List<f64>) {
        for value: f64 in values { self.entries.push(value) }
    }
    pub fn same_as(other: NumberItems) -> bool {
        if self.entries.len() != other.entries.len() { return false }
        for index: int in 0..self.entries.len() { if self.entries[index] != other.entries[index] { return false } }
        return true
    }
    pub fn to_list() -> List<f64> {
        var copy: List<f64> = []
        for value: f64 in self.entries { copy.push(value) }
        return move copy
    }
    pub fn show() -> string {
        var output: string = ""
        for index: int in 0..self.entries.len() {
            if index > 0 { output = "{output}, " }
            output = "{output}{self.entries[index]}"
        }
        return output
    }
}

/// A property a component asked for, as a value that can be compared.
///
/// The whole point of this type is the comparison. A render produces a
/// description of what the interface should look like; the differ compares it
/// with the last description and asks the platform to change only what
/// actually changed. That comparison has to be exact and cheap, which is why
/// an attribute is a struct of plain fields keyed by the host's own property
/// id rather than a name looked up in a map.
///
/// `property` is a `platform.P_*` constant, so the applier is a three-way switch
/// over `ctd_set_int`, `ctd_set_real` and `ctd_set_text` and not a table of
/// strings. Markup speaks names; `Builder` translates them once, here, and
/// everything downstream is integers.
pub struct Attribute {
    pub property: int = 0
    pub kind: AttributeKind = AttributeKind.flag
    pub text: string = ""
    pub number: f64 = 0.0
    pub whole: int = 0
    /// A removed attribute restores framework defaults, which can differ
    /// from explicitly setting the numeric value zero (transparent ink).
    pub reset: bool = false
    pub items_value: Option<StringItems> = none
    pub numbers_value: Option<NumberItems> = none
    pub source_value: Option<controls.TableRows> = none
    pub edit_policy_value: Option<TableEditRule> = none

    /// A widget's text. It carries no property id because the ABI gives text
    /// its own pair of entry points rather than a slot in the property table.
    pub static fn of_text(value: string) -> Attribute {
        return Attribute { property: 0, kind: AttributeKind.text, text: value }
    }
    pub static fn of_a11y_label(value: string) -> Attribute {
        return Attribute { property: platform.S_A11Y_LABEL, kind: AttributeKind.text, text: value }
    }

    pub static fn of_whole(property: int, value: int) -> Attribute {
        return Attribute { property: property, kind: AttributeKind.whole, whole: value }
    }

    pub static fn of_real(property: int, value: f64) -> Attribute {
        return Attribute { property: property, kind: AttributeKind.real, number: value }
    }

    pub static fn of_flag(property: int, value: bool) -> Attribute {
        return Attribute { property: property, kind: AttributeKind.flag,
                           whole: if value { 1 } else { 0 } }
    }

    pub static fn of_items(values: List<string>) -> Attribute {
        return Attribute { property: CHOICES_PROPERTY, kind: AttributeKind.items, items_value: some(new StringItems(values)) }
    }
    pub static fn of_labels(values: List<string>) -> Attribute {
        return Attribute { property: TAB_LABELS_PROPERTY, kind: AttributeKind.items, items_value: some(new StringItems(values)) }
    }
    pub static fn of_columns(values: List<string>) -> Attribute {
        return Attribute { property: TABLE_COLUMNS_PROPERTY, kind: AttributeKind.items, items_value: some(new StringItems(values)) }
    }
    pub static fn of_column_widths(values: List<f64>) -> Attribute {
        return Attribute { property: TABLE_WIDTHS_PROPERTY, kind: AttributeKind.numbers, numbers_value: some(new NumberItems(values)) }
    }
    pub static fn of_table_source(value: controls.TableRows) -> Attribute {
        return Attribute { property: TABLE_SOURCE_PROPERTY, kind: AttributeKind.table_source, source_value: some(value) }
    }
    pub static fn of_table_edit_policy(value: TableEditRule) -> Attribute {
        return Attribute { property: TABLE_EDIT_POLICY_PROPERTY, kind: AttributeKind.table_edit_policy,
                           edit_policy_value: some(value) }
    }

    pub fn is_on() -> bool {
        return self.whole != 0
    }

    /// Whether two attributes describe the same property with the same value.
    ///
    /// Only the field the kind actually uses is compared. An attribute built
    /// as a flag carries a zero `number`, and comparing that too would make
    /// every attribute unequal to itself the moment a constructor changed.
    pub fn same_as(other: Attribute) -> bool {
        if self.property != other.property || self.kind != other.kind {
            return false
        }
        match self.kind {
            text => { return self.text == other.text }
            real => { return self.number == other.number }
            whole => { return self.whole == other.whole }
            flag => { return self.whole == other.whole }
            items => {
                match self.items_value {
                    none => { return other.items_value == none }
                    some(left) => {
                        match other.items_value { some(right) => { return left.same_as(right) } none => { return false } }
                    }
                }
            }
            numbers => {
                match self.numbers_value {
                    none => { return other.numbers_value == none }
                    some(left) => {
                        match other.numbers_value { some(right) => { return left.same_as(right) } none => { return false } }
                    }
                }
            }
            table_source => { return self.source_value == other.source_value }
            table_edit_policy => { return self.edit_policy_value == other.edit_policy_value }
        }
    }

    /// What to write when a property the last render set is gone from this
    /// one.
    ///
    /// A property that disappears has to be *reset*, not left alone. An author
    /// who deletes `disabled` from their markup means the control should be
    /// enabled again, and a framework that only ever set properties would
    /// leave it disabled for the life of the window with nothing to explain
    /// why. The defaults below are the platform's, which is what a freshly
    /// created widget of that kind already has.
    pub static fn default_for(property: int, kind: AttributeKind) -> Attribute {
        var value: Attribute = Attribute.default_value(property, kind)
        value.reset = true
        return value
    }
    static fn default_value(property: int, kind: AttributeKind) -> Attribute {
        if kind == AttributeKind.text {
            if property == platform.S_A11Y_LABEL { return Attribute.of_a11y_label("") }
            return Attribute.of_text("")
        }
        if kind == AttributeKind.items {
            if property == TAB_LABELS_PROPERTY { return Attribute.of_labels([]) }
            if property == TABLE_COLUMNS_PROPERTY { return Attribute.of_columns([]) }
            return Attribute.of_items([])
        }
        if kind == AttributeKind.numbers { return Attribute.of_column_widths([]) }
        if kind == AttributeKind.table_source { return Attribute { property: TABLE_SOURCE_PROPERTY, kind: AttributeKind.table_source } }
        if kind == AttributeKind.table_edit_policy { return Attribute { property: TABLE_EDIT_POLICY_PROPERTY, kind: AttributeKind.table_edit_policy } }
        if property == platform.P_ENABLED || property == platform.P_EDITABLE {
            return Attribute.of_flag(property, true)
        }
        if kind == AttributeKind.flag {
            return Attribute.of_flag(property, false)
        }
        if kind == AttributeKind.real {
            if property == visual.SCALE_X || property == visual.SCALE_Y { return Attribute.of_real(property, 1.0) }
            return Attribute.of_real(property, 0.0)
        }
        return Attribute.of_whole(property, 0)
    }

    /// The attribute as an expected output prints it: `enabled=false`, `text="Buy"`.
    pub fn show() -> string {
        match self.kind {
            text => {
                let name: string = if self.property == platform.S_A11Y_LABEL { "a11y_label" } else { "text" }
                return "{name}=\"{self.text}\""
            }
            real => { return "{property_name(self.property)}={self.number}" }
            whole => {
                // A packed colour is the one whole number a reader cannot
                // read. These expected outputs exist to be read by people, and
                // `color=4278190335` says nothing that `rgba(255,0,0,255)`
                // does not say better. Three keys are one now that a control
                // can be dressed, which is why it asks a function rather than
                // naming CTD_P_COLOR: the fourth would have been added to the
                // header and not here, and printed as a number nobody reads.
                if is_packed_colour(self.property) {
                    let name: string = property_name(self.property)
                    return "{name}={controls.Rgba.of_packed(self.whole).show()}"
                }
                return "{property_name(self.property)}={self.whole}"
            }
            flag => { return "{property_name(self.property)}={self.is_on()}" }
            items => {
                let name: string = property_name(self.property)
                match self.items_value { some(values) => { return "{name}=[{values.show()}]" } none => { return "{name}=[]" } }
            }
            numbers => {
                match self.numbers_value { some(values) => { return "{property_name(self.property)}=[{values.show()}]" } none => { return "{property_name(self.property)}=[]" } }
            }
            table_source => { return "{property_name(self.property)}=<TableRows>" }
            table_edit_policy => { return "{property_name(self.property)}=<policy>" }
        }
    }
}

/// Whether a property's whole number is a packed `0xRRGGBBAA` colour.
///
/// Four keys are. Stated once so that an expected output printing a colour as
/// `4278190335` is a missing row here rather than a number a reader decodes.
pub fn is_packed_colour(property: int) -> bool {
    return property == platform.P_COLOR ||
           property == platform.P_BG_COLOR ||
           property == platform.P_BORDER_COLOR ||
           property == platform.P_FG_COLOR ||
           property == visual.FILL || property == visual.STROKE ||
           property == visual.GRADIENT_START || property == visual.GRADIENT_END ||
           property == visual.SHADOW_COLOR
}

/// The readable name of a host property id.
///
/// Expected outputs are read by people. An unknown id prints as a number rather than as
/// a guess, so adding a property to the header and forgetting this function
/// shows up as `p12=3` in a test rather than as the wrong name.
pub fn property_name(property: int) -> string {
    if property == CHOICES_PROPERTY { return "items" }
    if property == TAB_LABELS_PROPERTY { return "labels" }
    if property == TABLE_COLUMNS_PROPERTY { return "columns" }
    if property == TABLE_WIDTHS_PROPERTY { return "column_widths" }
    if property == TABLE_SOURCE_PROPERTY { return "source" }
    if property == TABLE_EDIT_POLICY_PROPERTY { return "editable_when" }
    if property == visual.FILL { return "fill" }
    if property == visual.STROKE { return "stroke" }
    if property == visual.STROKE_WIDTH { return "stroke_width" }
    if property == visual.ROTATION { return "rotation" }
    if property == visual.SCALE_X { return "scale_x" }
    if property == visual.SCALE_Y { return "scale_y" }
    if property == visual.GRADIENT_START { return "gradient_start" }
    if property == visual.GRADIENT_END { return "gradient_end" }
    if property == visual.SHADOW_COLOR { return "shadow_color" }
    if property == visual.SHADOW_BLUR { return "shadow_blur" }
    if property == visual.SHADOW_DX { return "shadow_dx" }
    if property == visual.SHADOW_DY { return "shadow_dy" }
    if property == visual.CLIP_RADIUS { return "clip_radius" }
    if property == visual.OFFSET_X { return "offset_x" }
    if property == visual.OFFSET_Y { return "offset_y" }
    if property == visual.TRANSITION_SECONDS { return "transition_seconds" }
    if property == visual.TRANSITION_EASING { return "transition_easing" }
    if property == platform.P_FONT_WEIGHT { return "font_weight" }
    if property == platform.P_BASELINE { return "baseline" }
    if property == platform.P_OVERHANG { return "overhang" }
    if property == platform.P_PROMINENT { return "prominent" }
    if property == platform.P_CHECKED { return "checked" }
    if property == platform.P_ENABLED { return "enabled" }
    if property == platform.P_HIDDEN { return "hidden" }
    if property == platform.P_MIN { return "min" }
    if property == platform.P_MAX { return "max" }
    if property == platform.P_VALUE { return "value" }
    if property == platform.P_EDITABLE { return "editable" }
    if property == platform.P_ALIGNMENT { return "alignment" }
    if property == platform.P_FONT_SIZE { return "font_size" }
    if property == platform.P_STEP { return "step" }
    if property == platform.P_SELECTED { return "selected" }
    if property == platform.P_INDETERMINATE { return "indeterminate" }
    if property == platform.P_OPACITY { return "opacity" }
    if property == platform.P_LINES { return "lines" }
    if property == platform.P_BORDERLESS { return "borderless" }
    if property == platform.P_COMPACT { return "compact" }
    if property == platform.P_CODE_MODE { return "code_mode" }
    if property == platform.P_ANIMATING { return "animating" }
    if property == platform.P_DATE { return "day" }
    if property == platform.P_COLOR { return "color" }
    if property == platform.P_EXPANDED { return "open" }
    if property == platform.P_ICON { return "icon" }
    if property == platform.P_AXIS { return "stacked" }
    if property == platform.P_DIVIDER { return "divider" }
    if property == platform.P_BG_COLOR { return "background" }
    if property == platform.P_CORNER_RADIUS { return "corner_radius" }
    if property == platform.P_BORDER_WIDTH { return "border_width" }
    if property == platform.P_BORDER_COLOR { return "border_color" }
    if property == platform.P_FG_COLOR { return "text_color" }
    if property == platform.P_FOCUSABLE { return "focusable" }
    if property == platform.P_A11Y_ROLE { return "a11y_role" }
    return "p{property}"
}
