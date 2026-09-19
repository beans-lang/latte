// What sort of control a widget is.
package controls

import latte.platform

/// The kinds of control latte can build.
///
/// One list, and every platform host answers all of it. A kind that some
/// platform cannot provide does not belong here — it belongs behind
/// `platform.Capability`, where a program can ask before it tries.
pub enum WidgetKind {
    container
    label
    button
    text_field
    check_box
    image_view
    slider
    progress_bar
    separator
    text_area
    combo_box
    scroll_view
    radio_button
    /// Somewhere a program draws for itself, with a shader.
    ///
    /// A control on every host — laid out by the solver, in the tree, with an
    /// accessibility role — and on the hosts with no GPU it is simply an empty
    /// area rather than a missing one. `gpu.Device` is what fills it.
    canvas
    /// On or off — and **the first kind that is not on every platform**.
    ///
    /// `NSSwitch`, `UISwitch`, `GtkSwitch`; the Win32 common controls have
    /// none, and `available()` says so rather than latte drawing one or
    /// quietly handing back a check box.
    switch
    /// A line of text the platform shows as dots, and keeps out of the
    /// pasteboard, out of dictation and off a screen recording.
    secure_field
    /// Two little arrows that step a number.
    stepper
    /// How full something is, drawn rather than typed into — and **not on
    /// every platform**: `NSLevelIndicator` and `GtkLevelBar` exist, UIKit
    /// and the Win32 common controls have nothing that means it.
    level_indicator
    /// Rows and columns, filled by asking rather than by building.
    table
    /// A text field that says what it is for.
    search_field
    /// Something is happening and nobody knows for how long — and **not on
    /// every platform**: the Win32 common controls have no spinner.
    spinner
    /// Words that go somewhere.
    link
    /// A few choices, all of them on screen — and **not on every platform**:
    /// GTK and the Win32 common controls have none.
    segmented
    /// A titled box around a group of controls, and **not on every
    /// platform**: UIKit has nothing that means it.
    group_box
    /// A day, picked from a calendar.
    ///
    /// A *day* and not an instant, which is latte's decision rather than any
    /// platform's: `NSDatePicker`, `UIDatePicker` and `SysDateTimePick32` can
    /// all show a time and `GtkCalendar` is a grid of squares with nowhere to
    /// put one. A kind whose value round-trips an afternoon on three platforms
    /// and loses it on the fourth is found by a user rather than by a gate.
    date_picker
    /// A colour, and a way to pick another — and **not on every platform**:
    /// the Win32 common controls have no colour well. `ChooseColor` is a
    /// dialog, which is a different control.
    color_well
    /// A title you press to show or hide what is under it — and **not on every
    /// platform**: the Win32 common controls have no disclosure triangle.
    disclosure
    /// One page at a time, with a strip of labels to choose it — and **not on
    /// every platform**: UIKit has no tab view, only a tab bar *controller*
    /// that owns the whole screen.
    tab_view
    /// Two panes with a handle between them — and **not on every platform**:
    /// the Win32 common controls have no splitter, and UIKit's is a view
    /// controller rather than a control.
    split_view
    /// A browser engine in a rectangle — and **the widest platform gap latte
    /// has**: WKWebView is part of the system on macOS and iOS, GTK's engine
    /// is a separate library and Windows' is a redistributable.
    web_view
    /// A table whose rows are a tree: it asks for a node's *children* rather
    /// than for row *n*. Every desktop platform has one; UIKit does not, and
    /// says so rather than substituting an indented list.
    outline_view

    /// The number this kind travels as.
    ///
    /// Public because `compose.Vocabulary.carries` asks the host about a
    /// kind, and the host speaks numbers.
    pub fn code() -> int {
        return match self {
            container => platform.W_CONTAINER,
            label => platform.W_LABEL,
            button => platform.W_BUTTON,
            text_field => platform.W_TEXT_FIELD,
            check_box => platform.W_CHECK_BOX,
            image_view => platform.W_IMAGE_VIEW,
            slider => platform.W_SLIDER,
            progress_bar => platform.W_PROGRESS_BAR,
            separator => platform.W_SEPARATOR,
            text_area => platform.W_TEXT_AREA,
            combo_box => platform.W_COMBO_BOX,
            scroll_view => platform.W_SCROLL_VIEW,
            radio_button => platform.W_RADIO_BUTTON,
            canvas => platform.W_CANVAS,
            switch => platform.W_SWITCH,
            secure_field => platform.W_SECURE_FIELD,
            stepper => platform.W_STEPPER,
            level_indicator => platform.W_LEVEL_INDICATOR,
            table => platform.W_TABLE,
            search_field => platform.W_SEARCH_FIELD,
            spinner => platform.W_SPINNER,
            link => platform.W_LINK,
            segmented => platform.W_SEGMENTED,
            group_box => platform.W_GROUP_BOX,
            date_picker => platform.W_DATE_PICKER,
            color_well => platform.W_COLOR_WELL,
            disclosure => platform.W_DISCLOSURE,
            tab_view => platform.W_TAB_VIEW,
            split_view => platform.W_SPLIT_VIEW,
            web_view => platform.W_WEB_VIEW,
            outline_view => platform.W_OUTLINE_VIEW,
        }
    }

    /// The name the test dumps print.
    pub fn name() -> string {
        return match self {
            container => "Container",
            label => "Label",
            button => "Button",
            text_field => "TextField",
            check_box => "CheckBox",
            image_view => "ImageView",
            slider => "Slider",
            progress_bar => "ProgressBar",
            separator => "Separator",
            text_area => "TextArea",
            combo_box => "ComboBox",
            scroll_view => "ScrollView",
            radio_button => "RadioButton",
            canvas => "Canvas",
            switch => "Switch",
            secure_field => "SecureField",
            stepper => "Stepper",
            level_indicator => "LevelIndicator",
            table => "Table",
            search_field => "SearchField",
            spinner => "Spinner",
            link => "Link",
            segmented => "Segmented",
            group_box => "GroupBox",
            date_picker => "DatePicker",
            color_well => "ColorWell",
            disclosure => "Disclosure",
            tab_view => "TabView",
            split_view => "SplitView",
            web_view => "WebView",
            outline_view => "OutlineView",
        }
    }

    /// Whether Latte has a renderer for this kind.
    ///
    /// Most kinds answer yes and this is a question nobody needs to ask. The
    /// ones that do not are the controls still to be drawn — Latte will not
    /// hand back a different control that looks close, so a program that would
    /// rather show something else asks first.
    pub fn available() -> bool {
        return match self {
            image_view => false,
            spinner => false,
            link => false,
            date_picker => false,
            color_well => false,
            web_view => false,
            outline_view => false,
            _ => true,
        }
    }

    /// Whether being checked is what this control *is*.
    ///
    /// Latte's rule, stated once, in Beans. A test that asked the renderer
    /// which kinds carry the property and then checked those kinds would agree
    /// with any answer at all, so the rule is written here and the renderer is
    /// checked against it.
    pub fn has_state() -> bool {
        match self {
            check_box => { return true }
            radio_button => { return true }
            switch => { return true }
            container => { return false }
            label => { return false }
            button => { return false }
            text_field => { return false }
            image_view => { return false }
            slider => { return false }
            progress_bar => { return false }
            separator => { return false }
            text_area => { return false }
            combo_box => { return false }
            scroll_view => { return false }
            canvas => { return false }
            secure_field => { return false }
            stepper => { return false }
            level_indicator => { return false }
            table => { return false }
            search_field => { return false }
            spinner => { return false }
            link => { return false }
            segmented => { return false }
            group_box => { return false }
            date_picker => { return false }
            color_well => { return false }
            disclosure => { return false }
            tab_view => { return false }
            split_view => { return false }
            web_view => { return false }
            outline_view => { return false }
        }
    }

    /// Whether a raw kind number names a kind at all.
    ///
    /// `available()` asks about a kind Latte has a name for, so it can only
    /// ever be answered yes or no. This asks about a *number*, and the two
    /// have to stay apart: a code that is not a kind is out of range, not a
    /// control Latte happens not to draw. A caller that cannot tell those
    /// apart reads a typo as a missing feature.
    pub static fn is_a_kind(code: int) -> bool {
        return WidgetKind.of(code) != none
    }

    /// The same question as a refusal, for a constructor to lead with.
    ///
    /// Without it the first property write on a control that was never built
    /// fails with `stale_handle` — a message about a handle, for a problem
    /// about a platform, arriving one call after the one that could have
    /// explained it.
    pub fn demand() -> Result<bool> {
        if self.available() { return ok(true) }
        return err("this platform has no {self.name()} control", "no_such_control")
    }

    /// Every kind, in the order they are declared above.
    ///
    /// Hand-written, because Beans has no way to enumerate an enum's cases —
    /// and hand-written lists drift, so `tools/check_vocabulary.sh` holds this
    /// one to the declarations above. That gate is not decoration: before it
    /// existed, `canvas` was added to this enum and never reached
    /// `tests/enabled.b`, which walks the kinds by hand. The golden lost a
    /// line and stayed green, because a list that is one short looks exactly
    /// like a list.
    pub static fn all() -> List<WidgetKind> {
        var every: List<WidgetKind> = []
        every.push(WidgetKind.container)
        every.push(WidgetKind.label)
        every.push(WidgetKind.button)
        every.push(WidgetKind.text_field)
        every.push(WidgetKind.check_box)
        every.push(WidgetKind.image_view)
        every.push(WidgetKind.slider)
        every.push(WidgetKind.progress_bar)
        every.push(WidgetKind.separator)
        every.push(WidgetKind.text_area)
        every.push(WidgetKind.combo_box)
        every.push(WidgetKind.scroll_view)
        every.push(WidgetKind.radio_button)
        every.push(WidgetKind.canvas)
        every.push(WidgetKind.switch)
        every.push(WidgetKind.secure_field)
        every.push(WidgetKind.stepper)
        every.push(WidgetKind.level_indicator)
        every.push(WidgetKind.table)
        every.push(WidgetKind.search_field)
        every.push(WidgetKind.spinner)
        every.push(WidgetKind.link)
        every.push(WidgetKind.segmented)
        every.push(WidgetKind.group_box)
        every.push(WidgetKind.date_picker)
        every.push(WidgetKind.color_well)
        every.push(WidgetKind.disclosure)
        every.push(WidgetKind.tab_view)
        every.push(WidgetKind.split_view)
        every.push(WidgetKind.web_view)
        every.push(WidgetKind.outline_view)
        return move every
    }

    pub static fn of(code: int) -> Option<WidgetKind> {
        if code == platform.W_CONTAINER { return some(WidgetKind.container) }
        if code == platform.W_LABEL { return some(WidgetKind.label) }
        if code == platform.W_BUTTON { return some(WidgetKind.button) }
        if code == platform.W_TEXT_FIELD { return some(WidgetKind.text_field) }
        if code == platform.W_CHECK_BOX { return some(WidgetKind.check_box) }
        if code == platform.W_IMAGE_VIEW { return some(WidgetKind.image_view) }
        if code == platform.W_SLIDER { return some(WidgetKind.slider) }
        if code == platform.W_PROGRESS_BAR { return some(WidgetKind.progress_bar) }
        if code == platform.W_SEPARATOR { return some(WidgetKind.separator) }
        if code == platform.W_TEXT_AREA { return some(WidgetKind.text_area) }
        if code == platform.W_COMBO_BOX { return some(WidgetKind.combo_box) }
        if code == platform.W_SCROLL_VIEW { return some(WidgetKind.scroll_view) }
        if code == platform.W_RADIO_BUTTON { return some(WidgetKind.radio_button) }
        if code == platform.W_CANVAS { return some(WidgetKind.canvas) }
        if code == platform.W_SWITCH { return some(WidgetKind.switch) }
        if code == platform.W_SECURE_FIELD { return some(WidgetKind.secure_field) }
        if code == platform.W_STEPPER { return some(WidgetKind.stepper) }
        if code == platform.W_LEVEL_INDICATOR { return some(WidgetKind.level_indicator) }
        if code == platform.W_TABLE { return some(WidgetKind.table) }
        if code == platform.W_SEARCH_FIELD { return some(WidgetKind.search_field) }
        if code == platform.W_SPINNER { return some(WidgetKind.spinner) }
        if code == platform.W_LINK { return some(WidgetKind.link) }
        if code == platform.W_SEGMENTED { return some(WidgetKind.segmented) }
        if code == platform.W_GROUP_BOX { return some(WidgetKind.group_box) }
        if code == platform.W_DATE_PICKER { return some(WidgetKind.date_picker) }
        if code == platform.W_COLOR_WELL { return some(WidgetKind.color_well) }
        if code == platform.W_DISCLOSURE { return some(WidgetKind.disclosure) }
        if code == platform.W_TAB_VIEW { return some(WidgetKind.tab_view) }
        if code == platform.W_SPLIT_VIEW { return some(WidgetKind.split_view) }
        if code == platform.W_WEB_VIEW { return some(WidgetKind.web_view) }
        if code == platform.W_OUTLINE_VIEW { return some(WidgetKind.outline_view) }
        return none
    }
}
