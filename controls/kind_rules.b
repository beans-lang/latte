// Which control carries which property, decided once, in Beans.
package controls

import latte.platform

/// What a kind carries, and what it refuses.
///
/// These are Latte's decisions, not a renderer's. The renderer *implements*
/// them; this states them. Keeping the two apart is the point: a test that
/// asked the render object which keys it accepted and then checked exactly
/// those would agree with any answer at all. Stated here, compared there.
///
/// Every key in `latte.platform` appears below. One that does not falls to
/// `out_of_range`, so a property number nobody wrote a rule for is a refusal
/// rather than a quiet yes.
pub class KindRules {
    /// Whether a kind carries `key` in `space`.
    ///
    /// `some(true)` it has it, `some(false)` it has not, `none` the key is not
    /// a key at all — three answers, because a caller that cannot tell a typo
    /// from a control that lacks a property reads the first as the second.
    pub static fn carries(kind: WidgetKind, space: int, key: int) -> Option<bool> {
        if space == platform.KEY_TEXT {
            if key == platform.S_A11Y_LABEL { return some(true) }
            if key == platform.S_HINT { return some(KindRules.has_hint(kind)) }
            if key == platform.S_URL { return some(KindRules.has_url(kind)) }
            return none
        }
        if space != platform.KEY_PROPERTY { return none }

        // Every control: a node is a node, and these are the node's own.
        if key == platform.P_HIDDEN { return some(true) }
        if key == platform.P_OPACITY { return some(true) }
        if key == platform.P_CORNER_RADIUS { return some(true) }
        if key == platform.P_OVERHANG { return some(true) }
        if key == platform.P_BORDER_WIDTH { return some(true) }
        if key == platform.P_BORDER_COLOR { return some(true) }

        if key == platform.P_ENABLED { return some(KindRules.has_enabled(kind)) }
        if key == platform.P_CHECKED { return some(KindRules.has_checked(kind)) }
        if key == platform.P_MIN || key == platform.P_MAX || key == platform.P_VALUE {
            return some(KindRules.has_range(kind))
        }
        if key == platform.P_EDITABLE { return some(KindRules.has_editable(kind)) }
        if key == platform.P_ALIGNMENT { return some(KindRules.has_alignment(kind)) }
        // Weight and baseline ride with the size: the three together are one
        // text style, and a control told one can be told all.
        if key == platform.P_FONT_SIZE || key == platform.P_FONT_WEIGHT ||
           key == platform.P_BASELINE {
            return some(KindRules.has_font_size(kind))
        }
        if key == platform.P_STEP { return some(KindRules.has_step(kind)) }
        if key == platform.P_SELECTED { return some(KindRules.has_selected(kind)) }
        if key == platform.P_INDETERMINATE { return some(KindRules.has_indeterminate(kind)) }
        if key == platform.P_ANIMATING { return some(kind == WidgetKind.spinner) }
        if key == platform.P_DATE { return some(kind == WidgetKind.date_picker) }
        if key == platform.P_COLOR { return some(kind == WidgetKind.color_well) }
        if key == platform.P_EXPANDED { return some(kind == WidgetKind.disclosure) }
        if key == platform.P_AXIS || key == platform.P_DIVIDER {
            return some(kind == WidgetKind.split_view)
        }
        if key == platform.P_ICON { return some(KindRules.has_icon(kind)) }
        if key == platform.P_BG_COLOR { return some(KindRules.has_background(kind)) }
        if key == platform.P_FG_COLOR { return some(KindRules.has_fg_color(kind)) }
        if key == platform.P_LINES { return some(kind == WidgetKind.label) }
        if key == platform.P_CODE_MODE { return some(kind == WidgetKind.text_area) }
        if key == platform.P_BORDERLESS { return some(kind == WidgetKind.tab_view) }
        if key == platform.P_COMPACT {
            return some(kind == WidgetKind.table || kind == WidgetKind.outline_view)
        }
        if key == platform.P_PROMINENT { return some(kind == WidgetKind.button) }
        // The two keys that belong to a control the program draws itself: can
        // it take the keyboard, and what does it call itself. A canvas is the
        // one kind whose contents Latte did not author, so it is the one kind
        // that has to be told.
        if key == platform.P_FOCUSABLE || key == platform.P_A11Y_ROLE {
            return some(kind == WidgetKind.canvas)
        }
        return none
    }

    /// A control has an enabled state exactly when it accepts input.
    /// Containers are out, the pressable ones included: what a disabled
    /// container means — dim the header, or dim everything inside — has no one
    /// answer, and a screen that wants a shut section disables the controls in
    /// it, which means the same thing everywhere.
    pub static fn has_enabled(kind: WidgetKind) -> bool {
        return match kind {
            button => true, text_field => true, secure_field => true,
            search_field => true, check_box => true, radio_button => true,
            switch => true, slider => true, stepper => true, combo_box => true,
            segmented => true, date_picker => true, color_well => true,
            _ => false,
        }
    }

    /// Words shown while a field is empty. Every single-line field, and
    /// nothing else: a text area's placeholder cannot be read back, and a
    /// string that goes in and does not come out is worse than one refused.
    pub static fn has_hint(kind: WidgetKind) -> bool {
        return match kind {
            text_field => true, secure_field => true, search_field => true,
            _ => false,
        }
    }

    pub static fn has_url(kind: WidgetKind) -> bool { return kind == WidgetKind.link }

    /// A number in a range. A slider and a stepper are numbers the user moves;
    /// a progress bar and a level indicator are numbers the program shows. A
    /// spinner makes no claim about how much is left — that is the whole
    /// difference between it and a bar.
    pub static fn has_range(kind: WidgetKind) -> bool {
        return match kind {
            slider => true, stepper => true, progress_bar => true,
            level_indicator => true,
            _ => false,
        }
    }

    /// Being checked has to be what the control *is*. A button is on or off
    /// too — a menu row is a button that carries a mark. Mixed is still only a
    /// check box.
    pub static fn has_checked(kind: WidgetKind) -> bool {
        return match kind {
            check_box => true, radio_button => true, switch => true,
            button => true,
            _ => false,
        }
    }

    /// The third, mixed state. Only a check box: a radio is one of a set and a
    /// switch is one thing, so 2 is out of range for them rather than
    /// unsupported.
    pub static fn has_mixed(kind: WidgetKind) -> bool { return kind == WidgetKind.check_box }

    /// A control a person types into, and so can be told not to be.
    pub static fn has_editable(kind: WidgetKind) -> bool {
        return match kind {
            text_field => true, secure_field => true, search_field => true,
            text_area => true,
            _ => false,
        }
    }

    /// Text whose alignment the program chooses: the four you type into, plus
    /// a label.
    pub static fn has_alignment(kind: WidgetKind) -> bool {
        return KindRules.has_editable(kind) || kind == WidgetKind.label
    }

    /// Text whose colour the program chooses — the same five.
    ///
    /// A button, a check box and a radio button are deliberately out: their
    /// words are a title drawn inside the theme's own bezel, so one name would
    /// mean three different things. A link's colour is the theme's.
    pub static fn has_fg_color(kind: WidgetKind) -> bool {
        return KindRules.has_alignment(kind)
    }

    /// Text whose size the program chooses: everything whose content is words.
    ///
    /// A table, an outline, a group box, a disclosure and a tab view are out:
    /// their words are a title or a cell, and one name cannot mean both.
    pub static fn has_font_size(kind: WidgetKind) -> bool {
        return match kind {
            label => true, button => true, text_field => true,
            secure_field => true, search_field => true, text_area => true,
            check_box => true, radio_button => true, combo_box => true,
            link => true, segmented => true, date_picker => true,
            _ => false,
        }
    }

    /// A background colour behind the control's own drawing.
    ///
    /// The four bezelled text controls refuse: the only way to show a colour
    /// there is to take away the bezel, and then it is not that control any
    /// more. Corner radius and border are deliberately not here — every
    /// control takes both, so there is nothing to refuse.
    pub static fn has_background(kind: WidgetKind) -> bool {
        return !KindRules.has_editable(kind)
    }

    /// An increment. A stepper and a slider.
    pub static fn has_step(kind: WidgetKind) -> bool {
        return kind == WidgetKind.slider || kind == WidgetKind.stepper
    }

    /// A chosen index: three lists with one item current.
    pub static fn has_selected(kind: WidgetKind) -> bool {
        return match kind {
            combo_box => true, tab_view => true, segmented => true,
            _ => false,
        }
    }

    /// A bar with no known total. A progress bar alone: a spinner is always
    /// indeterminate, so the key would have nothing to say.
    pub static fn has_indeterminate(kind: WidgetKind) -> bool {
        return kind == WidgetKind.progress_bar
    }

    /// A picture beside the words. A button and an image view, and nothing
    /// else: a label is text, and calling a label with a picture beside it "a
    /// label with an icon" would make one word mean two things.
    pub static fn has_icon(kind: WidgetKind) -> bool {
        return kind == WidgetKind.button || kind == WidgetKind.image_view
    }

    pub static fn holds_children(kind: WidgetKind) -> bool {
        return match kind {
            container => true, scroll_view => true, group_box => true,
            disclosure => true, split_view => true, tab_view => true,
            _ => false,
        }
    }

    pub static fn holds_pages(kind: WidgetKind) -> bool { return kind == WidgetKind.tab_view }
}
