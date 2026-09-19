package scene

/// Per-window design resources. No process-wide mutable theme.
///
/// Every number and colour here was read off real AppKit controls on
/// macOS 26.5 (25F71) by `tools/reference/capture.sh`, in sRGB, at 4x, in both
/// appearances. `build/reference/` holds the captures and the measurements;
/// `tools/reference/README.md` says what is pinned. Nothing here was eyeballed,
/// and nothing here is a guess about a different macOS release.
pub class Theme {
    dark_mode: bool = false
    accent_value: int = -1
    background_value: int = -1
    foreground_value: int = -1
    surface_value: int = -1
    /// 0 mini, 1 small, 2 regular, 3 large. macOS calls these control sizes;
    /// they change height, radius, padding and font together, never one alone.
    size_value: int = 2
    /// macOS drains the accent out of every filled control when its window
    /// stops being the key one. Windows carry this; a standalone scene is key.
    active_value: bool = true
    /// The OS accessibility setting. Every motion token answers zero while it
    /// is on, so a template that reads one animates or does not without asking.
    reduced_motion: bool = false
    font_value: f64 = -1.0
    revision: int = 0
    pub fn init() {}

    fn pick(light: int, dark: int) -> int { return if self.dark_mode { dark } else { light } }

    pub fn is_dark() -> bool { return self.dark_mode }
    pub fn is_window_active() -> bool { return self.active_value }
    pub fn set_window_active(active: bool) {
        if self.active_value == active { return }
        self.active_value = active
        self.revision += 1
    }
    pub fn set_dark(dark: bool) {
        if self.dark_mode == dark { return }
        self.dark_mode = dark
        self.revision += 1
    }

    // ------------------------------------------------------- control size
    pub fn control_size() -> int { return self.size_value }
    pub fn set_control_size(size: int) -> Result<bool> {
        if size < 0 || size > 3 { return err("control size is mini, small, regular or large", "out_of_range") }
        if self.size_value == size { return ok(true) }
        self.size_value = size
        self.revision += 1
        return ok(true)
    }
    /// One value per control size, read in the order mini, small, regular, large.
    fn by_size(mini: f64, small: f64, regular: f64, large: f64) -> f64 {
        if self.size_value == 0 { return mini }
        if self.size_value == 1 { return small }
        if self.size_value == 3 { return large }
        return regular
    }

    // ----------------------------------------------------------- backgrounds
    /// NSColor.windowBackgroundColor.
    pub fn background() -> int {
        if self.background_value >= 0 { return self.background_value }
        return self.pick(0xffffffff, 0x1e1e1eff)
    }
    /// NSColor.controlBackgroundColor: what a list or a card sits on.
    pub fn card() -> int { return self.pick(0xffffffff, 0x1e1e1eff) }
    /// NSColor.underPageBackgroundColor, opaque over the window.
    pub fn sunken() -> int { return self.pick(0xf5f5f5ff, 0x282828ff) }
    /// The push-button, popup, segmented and stepper bezel, sampled off a real
    /// control rather than taken from NSColor.control, which is translucent.
    pub fn surface() -> int {
        if self.surface_value >= 0 { return self.surface_value }
        return self.pick(0xebebebff, 0x303030ff)
    }
    pub fn surface_pressed() -> int { return self.pick(0xd4d4d4ff, 0x444444ff) }
    /// AppKit gives a push button no hover fill. Keeping the bezel steady is
    /// what makes a latte window read as a macOS window.
    pub fn surface_hovered() -> int { return self.surface() }
    pub fn surface_disabled() -> int { return self.pick(0xf5f5f5ff, 0x262626ff) }
    /// NSColor.textBackgroundColor: where text is typed.
    pub fn field() -> int { return self.pick(0xffffffff, 0x1e1e1eff) }
    /// A disabled field keeps its background; AppKit dims the text, not the
    /// paper. Measured: a disabled NSTextField is still white.
    pub fn field_disabled() -> int { return self.field() }
    /// The hairline around a text field. Translucent, so it composites the same
    /// way AppKit's does over whatever is behind it.
    pub fn field_border() -> int { return self.pick(0x00000017, 0xffffff0a) }

    // ---------------------------------------------------------------- labels
    pub fn foreground() -> int {
        if self.foreground_value >= 0 { return self.foreground_value }
        return self.pick(0x000000d8, 0xffffffd8)
    }
    pub fn secondary_label() -> int { return self.pick(0x0000007f, 0xffffff8c) }
    pub fn tertiary_label() -> int { return self.pick(0x00000042, 0xffffff3f) }
    pub fn quaternary_label() -> int { return self.pick(0x00000019, 0xffffff19) }
    pub fn placeholder() -> int { return self.pick(0x0000007f, 0xffffff8c) }
    pub fn disabled_label() -> int { return self.pick(0x0000003f, 0xffffff3f) }
    pub fn header_label() -> int { return self.pick(0x000000d8, 0xffffffff) }
    /// Text and glyphs drawn on top of a filled accent control.
    pub fn on_accent() -> int { return 0xffffffff }
    pub fn on_accent_disabled() -> int { return self.pick(0x0000003f, 0xffffff3f) }

    // ---------------------------------------------------------------- accent
    /// NSColor.controlAccentColor. A default button and a progress fill use it
    /// exactly; the controls below use accent_control().
    pub fn accent() -> int {
        if self.accent_value >= 0 { return self.accent_value }
        return 0x007affff
    }
    /// What a switch, a slider fill and a selected segment actually paint: the
    /// accent under a 2.4% dark wash. Measured, not derived from taste.
    pub fn accent_control() -> int {
        if self.accent_value >= 0 { return Theme.shade(self.accent_value, 0.976) }
        return self.pick(0x0077f9ff, 0x067dffff)
    }
    /// A prominent button held down: the accent itself, one step darker.
    pub fn accent_pressed() -> int {
        if self.accent_value >= 0 { return Theme.shade(self.accent_value, if self.dark_mode { 1.09 } else { 0.9 }) }
        return self.pick(0x006ee6ff, 0x1987ffff)
    }
    /// A switch, a selected segment or a slider fill held down. It starts from
    /// accent_control rather than the accent, so it is not the same colour a
    /// pressed default button reaches.
    pub fn accent_control_pressed() -> int {
        if self.accent_value >= 0 { return Theme.shade(self.accent_value, if self.dark_mode { 1.11 } else { 0.88 }) }
        return self.pick(0x006be1ff, 0x1e8affff)
    }
    /// A filled toggle that is off for good. AppKit fades the accent rather
    /// than replacing it with grey, which is what tells a disabled switch that
    /// is on from a disabled switch that is off.
    pub fn accent_disabled() -> int {
        if self.accent_value >= 0 { return Theme.shade(self.accent_value, if self.dark_mode { 0.45 } else { 1.0 }) }
        return self.pick(0x8fc2fbff, 0x154981ff)
    }
    /// What a switch or slider fill becomes in a window that is not key.
    pub fn accent_inactive() -> int { return self.pick(0xdbdbdbff, 0x3e3e3eff) }
    /// The same for a selected segment that is also disabled.
    pub fn selection_disabled() -> int { return self.pick(0x83b7efff, 0x1f528cff) }
    /// The same for a selected segment, which AppKit drains one step further.
    pub fn selection_inactive() -> int { return self.pick(0xcdcdcdff, 0x4a4a4aff) }
    pub fn destructive() -> int { return self.pick(0xff383cff, 0xff4245ff) }
    pub fn success() -> int { return self.pick(0x34c759ff, 0x30d158ff) }
    pub fn warning() -> int { return self.pick(0xff8d28ff, 0xff9230ff) }
    pub fn link() -> int { return self.pick(0x0068daff, 0x419cffff) }

    // ------------------------------------------------- lines and selection
    pub fn separator() -> int { return self.pick(0x00000019, 0xffffff19) }
    pub fn grid() -> int { return self.pick(0xe6e6e6ff, 0x1a1a1aff) }
    pub fn selection() -> int { return self.pick(0x0064e1ff, 0x0059d1ff) }
    /// A selected row in a list that does not have focus.
    pub fn quiet_selection() -> int { return self.pick(0xdcdcdcff, 0x464646ff) }
    pub fn text_selection() -> int { return self.pick(0xb3d7ffff, 0x3f638bff) }
    /// NSColor.keyboardFocusIndicatorColor, the focus ring's own colour.
    pub fn focus_ring() -> int { return self.pick(0x0067f47f, 0x1aa9ff7f) }
    /// How far the ring sits outside the control it belongs to.
    pub fn focus_ring_width() -> f64 { return 3.0 }
    /// The unfilled half of a switch, slider or check box.
    pub fn track() -> int { return self.pick(0xe6e6e6ff, 0x343434ff) }
    pub fn track_disabled() -> int { return self.pick(0xf2f2f2ff, 0x292929ff) }
    /// A toggle held down. A push button's bezel darkens to a different grey,
    /// so the two cannot share one token.
    pub fn track_pressed() -> int { return self.pick(0xcfcfcfff, 0x484848ff) }

    /// NSSwitch draws its capsule with its own set of these, close to a check
    /// box's but not the same: a pressed switch is d3d3d3 where a pressed
    /// check box is cfcfcf. They are separate because the captures say so.
    pub fn switch_track_pressed() -> int { return self.pick(0xd3d3d3ff, 0x444444ff) }
    pub fn switch_accent_pressed() -> int {
        if self.accent_value >= 0 { return self.accent_control_pressed() }
        return self.pick(0x056ee3ff, 0x1e8affff)
    }
    pub fn switch_accent_disabled() -> int {
        if self.accent_value >= 0 { return self.accent_disabled() }
        return self.pick(0x95c5fbff, 0x16467cff)
    }
    pub fn switch_accent_inactive() -> int { return self.pick(0xdededeff, 0x3b3b3bff) }
    /// A progress or level track, which is lighter than a switch track.
    pub fn bar_track() -> int { return self.pick(0xf0f0f0ff, 0x303030ff) }
    pub fn bar_track_border() -> int { return self.pick(0xdfdfdfff, 0x3a3a3aff) }
    /// A switch or slider knob. Dark mode dims it rather than going white.
    pub fn knob() -> int { return self.pick(0xffffffff, 0xe1e1e1ff) }
    /// The knob of a switch that is on, in dark mode a cool tint.
    pub fn knob_on() -> int { return self.pick(0xffffffff, 0xdaecffff) }
    /// A knob over a drained track picks up a little of it. Four more measured
    /// colours rather than one rule: white over the track fits the pale states
    /// and not the blue one, and a rule that fits three cases out of four is
    /// a guess wearing arithmetic.
    pub fn knob_disabled() -> int { return self.pick(0xffffffff, 0xdfdfdfff) }
    pub fn knob_disabled_on() -> int { return self.pick(0xf7fafeff, 0xdae2ebff) }
    pub fn knob_inactive() -> int { return self.pick(0xffffffff, 0xe1e1e1ff) }
    pub fn knob_inactive_on() -> int { return self.pick(0xfcfcfcff, 0xe1e1e1ff) }
    pub fn knob_shadow() -> int { return self.pick(0x00000026, 0x00000040) }
    /// Every other row of a table, so long rows stay trackable.
    pub fn stripe() -> int { return self.pick(0xf4f5f5ff, 0x2a2a2aff) }

    // ------------------------------------------------------------ typography
    /// The control font: NSFont.systemFontSize(for:) — 9, 11, 13, 13.
    pub fn font_size() -> f64 {
        if self.font_value > 0.0 { return self.font_value }
        return self.by_size(9.0, 11.0, 13.0, 13.0)
    }
    /// What AppKit's layout manager gives a line at each size, so a shared line
    /// box is the same height as a native one.
    pub static fn line_height(size: f64) -> f64 {
        if size <= 9.0 { return 11.0 }
        if size <= 10.0 { return 12.0 }
        if size <= 11.0 { return 13.0 }
        if size <= 12.0 { return 15.0 }
        if size <= 13.0 { return 16.0 }
        if size <= 14.0 { return 17.0 }
        if size <= 15.0 { return 18.0 }
        if size <= 16.0 { return 18.0 }
        if size <= 17.0 { return 20.0 }
        if size <= 20.0 { return 23.0 }
        if size <= 22.0 { return 26.0 }
        if size <= 26.0 { return 30.0 }
        return size * 1.18
    }
    /// The ascent `paint()` rounds to. Apple's UI face measured 0.9668 of the
    /// point size at every optical cut in build/reference/fonts.json.
    pub static fn ascent(size: f64) -> f64 {
        let exact: f64 = size * 0.9668
        let down: f64 = (exact as int) as f64
        return if exact - down >= 0.5 { down + 1.0 } else { down }
    }
    /// A run centred in a box: its line box is centred, and the first baseline
    /// sits a rounded ascent below that line box's top.
    pub static fn centred_baseline(box: f64, size: f64) -> f64 {
        return (box - Theme.line_height(size)) / 2.0 + Theme.ascent(size)
    }
    /// The named text styles, at the sizes NSFont.preferredFont reports.
    pub fn large_title() -> f64 { return 26.0 }
    pub fn title1() -> f64 { return 22.0 }
    pub fn title2() -> f64 { return 17.0 }
    pub fn title3() -> f64 { return 15.0 }
    pub fn headline() -> f64 { return 13.0 }
    pub fn body() -> f64 { return 13.0 }
    pub fn callout() -> f64 { return 12.0 }
    pub fn subheadline() -> f64 { return 11.0 }
    pub fn footnote() -> f64 { return 10.0 }
    pub fn caption1() -> f64 { return 10.0 }
    pub fn caption2() -> f64 { return 10.0 }
    /// Weights, as the renderer numbers them: 2 regular, 3 medium, 5 bold.
    pub fn headline_weight() -> int { return 5 }
    pub fn caption2_weight() -> int { return 3 }
    /// A selected segment draws its label at medium, the unselected ones regular.
    pub fn selected_weight() -> int { return 3 }
    pub fn regular_weight() -> int { return 2 }
    /// Apple bakes tracking into the optical size, so a UI run adds none.
    pub fn tracking() -> f64 { return 0.0 }

    // ---------------------------------------------------------------- metrics
    /// A push button, popup, segmented or text field: 16, 20, 24, 28.
    pub fn control_height() -> f64 { return self.by_size(16.0, 20.0, 24.0, 28.0) }
    /// Every bezel in the push-button family follows height/4 - 0.5, which is
    /// what the 4x captures give at all four sizes.
    pub fn control_radius() -> f64 { return Theme.radius_for(self.control_height()) }
    pub static fn radius_for(height: f64) -> f64 {
        let radius: f64 = height / 4.0 - 0.5
        return if radius < 1.0 { 1.0 } else { radius }
    }
    /// Left and right of a button title: 8, 10, 12, 14.
    pub fn control_padding() -> f64 { return self.by_size(8.0, 10.0, 12.0, 14.0) }
    /// Where a control's text baseline sits, measured down from its top.
    pub fn control_baseline() -> f64 { return self.by_size(12.0, 14.0, 17.0, 19.0) }
    /// A text field's bezel is drawn one point outside its frame on every edge.
    pub fn field_overhang() -> f64 { return 1.0 }
    /// NSTextField sizes to 19, 22, 24, 24 — it stops growing at regular.
    pub fn field_height() -> f64 { return self.by_size(19.0, 22.0, 24.0, 24.0) }
    pub fn field_radius() -> f64 { return Theme.radius_for(self.field_height() + 2.0) }
    /// Text inset inside a field. The cell's drawing rect starts 4 points in and
    /// its text another 2, at every control size — this one does not scale.
    pub fn field_padding() -> f64 { return 6.0 }
    /// Where a field's own text baseline sits, measured down from its frame.
    /// It is not the button baseline: a 24-point field and a 24-point button
    /// put their text in different places.
    pub fn field_baseline() -> f64 { return self.by_size(13.0, 15.0, 17.0, 17.0) }
    pub fn field_border_width() -> f64 { return 1.0 }

    /// A check box or radio button is a square as tall as its row: 12, 14, 16.
    pub fn toggle_size() -> f64 { return self.by_size(12.0, 14.0, 16.0, 18.0) }
    pub fn toggle_radius() -> f64 { return self.by_size(3.0, 3.5, 4.5, 5.0) }
    /// Gap between a check box and its title: title x minus the box.
    pub fn toggle_gap() -> f64 { return self.by_size(4.0, 4.0, 6.0, 6.0) }
    pub fn toggle_row_height() -> f64 { return self.by_size(12.0, 14.0, 16.0, 18.0) }
    pub fn toggle_baseline() -> f64 { return self.by_size(9.5, 11.0, 13.0, 14.0) }
    /// The white dot inside a selected radio button: 4 points at mini, 5 at
    /// every other size. It does not scale with the circle.
    pub fn radio_dot() -> f64 { return self.by_size(4.0, 5.0, 5.0, 5.0) }
    /// The check mark's stroke, and the mixed state's dash, both measured off
    /// the 4x captures rather than derived from the box.
    pub fn toggle_mark_stroke() -> f64 { return self.by_size(1.5, 1.75, 2.0, 2.0) }
    pub fn toggle_dash_width() -> f64 { return self.by_size(5.5, 6.5, 6.5, 8.0) }
    pub fn toggle_dash_thickness() -> f64 { return 2.0 }

    /// NSSwitch keeps one frame at every control size and paints a different
    /// switch inside it. Layout gets the frame; the template gets the drawing.
    pub fn switch_frame_width() -> f64 { return 54.0 }
    pub fn switch_frame_height() -> f64 { return 24.0 }
    /// NSSwitch paints 36x16, 44x20, 54x24, 64x28 — at large it reaches five
    /// points past its own frame on each side, and two above and below.
    pub fn switch_width() -> f64 { return self.by_size(36.0, 44.0, 54.0, 64.0) }
    pub fn switch_height() -> f64 { return self.by_size(16.0, 20.0, 24.0, 28.0) }
    pub fn switch_knob_inset() -> f64 { return self.by_size(1.5, 2.0, 2.0, 2.0) }
    /// The knob is a wide capsule, not a circle: 21, 26, 32 and 38 across.
    pub fn switch_knob_width() -> f64 { return self.by_size(21.0, 26.0, 32.0, 38.0) }
    pub fn switch_knob_height() -> f64 { return self.switch_height() - self.switch_knob_inset() * 2.0 }
    /// How far the knob slides between off and on.
    pub fn switch_travel() -> f64 {
        return self.switch_width() - self.switch_knob_inset() * 2.0 - self.switch_knob_width()
    }

    /// A slider's knob is a capsule, not a circle: 19.5 by 14.5 at the regular
    /// size, which is what the 4x capture measures. Only its shadow reaches
    /// past the frame, by half a point.
    pub fn slider_height() -> f64 { return self.by_size(12.0, 14.0, 16.0, 20.0) }
    pub fn slider_track_thickness() -> f64 { return self.by_size(4.0, 4.0, 6.0, 6.0) }
    pub fn slider_knob_width() -> f64 { return self.by_size(15.5, 17.5, 19.5, 23.25) }
    pub fn slider_knob_height() -> f64 { return self.by_size(10.25, 12.25, 14.5, 17.5) }
    pub fn slider_overhang() -> f64 { return 0.5 }

    /// A progress bar's frame is taller than its bar, which sits in the middle.
    pub fn bar_control_height() -> f64 { return self.by_size(12.0, 12.0, 20.0, 20.0) }
    pub fn bar_height() -> f64 { return self.by_size(6.0, 6.0, 8.0, 8.0) }
    pub fn bar_radius() -> f64 { return self.by_size(2.9, 2.9, 3.0, 3.0) }
    /// NSLevelIndicator is ten touching cells, 12 by 16, each with a hairline
    /// round it; the filled ones lose the line. The frame is two points taller
    /// than the cells, which sit at its top.
    /// Ten cells 12 by 16 across the top of an 18 point frame, each with a
    /// hairline rule. Every colour here is a flat interior pixel of the 2x
    /// capture: the 4x one blends its edges, and a colour read off a blended
    /// pixel is a colour nothing on screen is.
    pub fn level_height() -> f64 { return 18.0 }
    pub fn level_content_height() -> f64 { return 16.0 }
    pub fn level_cells() -> int { return 10 }
    pub fn level_cell_width() -> f64 { return 12.0 }
    pub fn level_cell_height() -> f64 { return 16.0 }
    pub fn level_cell_gap() -> f64 { return 0.0 }
    pub fn level_cell_radius() -> f64 { return 2.0 }
    pub fn level_cell_empty() -> int { return self.pick(0xedededff, 0x353535ff) }
    pub fn level_cell_border() -> int { return self.pick(0xcececeff, 0x2e2e2eff) }
    pub fn level_cell_fill() -> int { return self.pick(0x34c759ff, 0x30d158ff) }
    pub fn level_cell_fill_border() -> int { return self.pick(0x2dad4dff, 0x2ab64dff) }

    pub fn stepper_width() -> f64 { return self.by_size(13.0, 17.0, 20.0, 23.0) }
    pub fn stepper_height() -> f64 { return self.by_size(20.0, 22.0, 26.0, 30.0) }
    /// One chevron, measured off the 4x capture. There is no rule between the
    /// two halves: the native stepper draws the bezel and two arrows, nothing else.
    pub fn stepper_glyph_width() -> f64 { return self.by_size(7.75, 9.0, 11.5, 11.5) }
    pub fn stepper_glyph_height() -> f64 { return self.by_size(4.5, 5.25, 6.75, 6.75) }
    pub fn stepper_glyph_top() -> f64 { return self.by_size(3.0, 3.25, 3.25, 4.25) }
    /// Clear space under the lower chevron, which is not the same as above the upper one.
    pub fn stepper_glyph_bottom() -> f64 { return self.by_size(2.5, 2.5, 3.0, 4.0) }
    pub fn stepper_stroke() -> f64 { return self.by_size(1.5, 1.7, 2.0, 2.0) }
    /// The rule between the two halves. It is nearly the bezel's own colour,
    /// which is why a first pass at this looked like there was no rule at all.
    pub fn stepper_divider() -> int { return self.pick(0xd4d4d4ff, 0x444444ff) }
    pub fn stepper_divider_inset() -> f64 { return self.by_size(2.0, 3.0, 3.0, 4.0) }
    pub fn stepper_divider_height() -> f64 { return 1.0 }
    /// The two-chevron glyph on a popup button's trailing edge. The block holds
    /// both arrows and the gap: each arrow is four tenths of it, the gap two.
    pub fn chevron_width() -> f64 { return self.by_size(6.25, 6.25, 7.25, 9.25) }
    pub fn chevron_block() -> f64 { return self.by_size(8.75, 8.75, 10.5, 13.25) }
    pub fn chevron_height() -> f64 { return self.chevron_block() * 0.4 }
    pub fn chevron_gap() -> f64 { return self.chevron_block() * 0.2 }
    pub fn chevron_stroke() -> f64 { return self.by_size(1.5, 1.5, 1.75, 2.0) }
    /// Clear space between the chevrons and the control's trailing edge.
    pub fn chevron_inset() -> f64 { return self.by_size(6.25, 8.25, 10.25, 10.75) }
    /// Everything a popup button keeps past its title: the blank, the chevrons
    /// and the trailing inset. NSPopUpButton sizes to title plus this.
    pub fn chevron_column() -> f64 { return self.by_size(24.0, 30.0, 36.0, 42.0) }
    /// One NSSegmentedControl segment is its title plus this much, shared
    /// between its two sides — not an equal share of the whole control.
    pub fn segment_padding() -> f64 { return self.by_size(15.0, 19.0, 21.0, 25.0) }

    // --------------------------------------------------------------- the menu
    /// An NSMenu row, and the padding above the first and below the last.
    /// Read off NSMenu.size: one item is 34 high and each further item adds 24.
    pub fn menu_row_height() -> f64 { return 24.0 }
    pub fn menu_padding() -> f64 { return 5.0 }
    pub fn menu_separator_height() -> f64 { return 11.0 }
    /// A menu is its widest title plus this much, and eight more when any item
    /// carries a mark — which is the width of the mark column.
    pub fn menu_width_over_text() -> f64 { return 32.0 }
    /// The mark column is what the measurement says an item's mark costs: a
    /// menu with one checked item is eight points wider than the same menu
    /// without one.

    pub fn menu_check_column() -> f64 { return 8.0 }
    pub fn menu_indent_step() -> f64 { return 12.0 }
    /// Where the mark column starts, and where the title starts after it.
    ///
    /// AppKit gives the sum — a menu is its title plus 32, and 8 more once any
    /// item carries a mark — but not the split between the two sides. These
    /// three add up to that sum and are the only numbers in this file that are
    /// not read off a capture: a menu window is drawn outside the process, so
    /// it cannot be captured offscreen. See tools/reference/README.md.
    /// The mark's own advance is 11.18 points at 13, with 8.72 of ink in it —
    /// CTLineGetImageBounds on the menu font's check. A leading margin of ten
    /// plus that advance puts the title at 21, which is where the measured
    /// width says it goes.
    pub fn menu_mark_inset() -> f64 { return 10.0 + self.menu_font_size() * 0.098 }
    pub fn menu_mark_width() -> f64 { return self.menu_font_size() * 0.671 }
    pub fn menu_mark_height() -> f64 { return self.menu_font_size() * 0.661 }
    pub fn menu_mark_stroke() -> f64 { return self.menu_font_size() * 0.1 }
    pub fn menu_text_inset() -> f64 { return 10.0 + self.menu_font_size() * 0.86 }
    pub fn menu_trailing() -> f64 { return 19.0 }
    /// A popup button's menu takes the button's font, not a fixed one.
    pub fn menu_font_size() -> f64 { return self.font_size() }
    pub fn menu_radius() -> f64 { return 10.0 }
    /// A menu row is 24 points at every control size — NSMenu.size says so even
    /// when the menu carries a mini font — so its text is centred in the row and
    /// not on the owning control's baseline. On a large popup that difference
    /// was two points, and the row read as bottom-heavy.
    pub fn menu_baseline() -> f64 {
        return Theme.centred_baseline(self.menu_row_height(), self.menu_font_size())
    }
    pub fn menu_row_radius() -> f64 { return 4.0 }
    /// The rows are inset from the menu's own edges by its padding.
    pub fn menu_row_inset() -> f64 { return 5.0 }
    pub fn menu_background() -> int { return self.pick(0xffffffff, 0x1e1e1eff) }
    pub fn menu_border() -> int { return self.pick(0x00000019, 0xffffff19) }
    pub fn menu_shadow() -> int { return self.pick(0x0000004c, 0x00000099) }
    pub fn menu_shadow_blur() -> f64 { return 12.0 }
    pub fn menu_shadow_dy() -> f64 { return 4.0 }
    /// A menu opens with its chosen row over the control it belongs to.
    pub fn menu_gap() -> f64 { return 0.0 }

    // -------------------------------------------------------------- the motion
    /// Recorded off real clicks on real controls; see tools/reference/motion.sh.
    /// A switch slides and fades over about a sixth of a second. A segmented
    /// control, a tab, a check box and a button press do not animate at all,
    /// so there is no token for them: instant is the native answer.
    pub fn motion_switch() -> f64 { return if self.reduced_motion { 0.0 } else { 0.15 } }
    /// Clicking a slider's track walks the knob to the click; dragging does not.
    pub fn motion_slider() -> f64 { return if self.reduced_motion { 0.0 } else { 0.23 } }
    /// A segmented control's pill sliding between segments.
    ///
    /// **Not measured.** Three attempts at recording AppKit's own segmented
    /// control produced a grey layer render, an appearance-less draw and a
    /// control stuck in its pressed state; none of them is evidence. The
    /// duration is the switch's, which was recorded, and the fact that it
    /// moves at all is an observation of a real Mac rather than a capture.
    /// See tools/reference/README.md.
    pub fn motion_selection() -> f64 { return if self.reduced_motion { 0.0 } else { 0.15 } }
    /// 0 linear, 1 ease-in-out. The recorded switch curve is a smoothstep.
    pub fn motion_curve() -> int { return 1 }
    pub fn is_reduced_motion() -> bool { return self.reduced_motion }
    pub fn set_reduced_motion(on: bool) {
        if self.reduced_motion == on { return }
        self.reduced_motion = on
        self.revision += 1
    }

    /// NSTableView's own row height and header, and NSScroller's width.
    pub fn row_height() -> f64 { return self.by_size(18.0, 20.0, 24.0, 28.0) }
    pub fn header_height() -> f64 { return self.by_size(20.0, 24.0, 28.0, 28.0) }
    pub fn scroller_width() -> f64 { return self.by_size(15.0, 15.0, 17.0, 17.0) }

    /// SkRRect scales a corner down to half the box, so an oversized radius is
    /// a capsule at any height.
    pub fn capsule() -> f64 { return 1000.0 }
    pub fn radius_small() -> f64 { return self.by_size(3.0, 3.5, 4.5, 5.0) }
    pub fn radius_medium() -> f64 { return self.control_radius() }
    pub fn radius_large() -> f64 { return self.by_size(5.0, 6.0, 8.0, 9.0) }
    pub fn spacing() -> f64 { return self.by_size(4.0, 6.0, 8.0, 8.0) }
    pub fn margin() -> f64 { return self.by_size(10.0, 14.0, 20.0, 20.0) }
    pub fn hairline() -> f64 { return 1.0 }

    /// The colour as .bx markup spells it, so a view can paint itself with
    /// the same tokens its controls use: #rrggbbaa.
    pub static fn hex(value: int) -> string {
        let digits: string = "0123456789abcdef"
        var result: string = "#"
        for index: int in 0..8 {
            let shift: int = (7 - index) * 4
            let digit: int = (value >> shift) & 15
            result = "{result}{digits.slice(digit, digit + 1)}"
        }
        return result
    }

    /// Scales the three colour channels and keeps the alpha, for the one place
    /// a custom accent has to stand in for a measured pair.
    pub static fn shade(value: int, factor: f64) -> int {
        var out: int = value & 255
        for index: int in 0..3 {
            let shift: int = 8 + index * 8
            let channel: f64 = ((value >> shift) & 255) as f64 * factor
            var scaled: int = (channel + 0.5) as int
            if scaled > 255 { scaled = 255 }
            if scaled < 0 { scaled = 0 }
            out = out | (scaled << shift)
        }
        return out
    }

    pub fn version() -> int { return self.revision }
    /// Tints one role. set_colors would pin the other three to today's
    /// appearance, so an accent change alone goes through here.
    pub fn set_accent(color: int) {
        if self.accent_value == color { return }
        self.accent_value = color
        self.revision += 1
    }
    pub fn clear_accent() {
        if self.accent_value < 0 { return }
        self.accent_value = -1
        self.revision += 1
    }
    pub fn set_colors(background: int, foreground: int, accent: int, surface: int) {
        self.background_value = background
        self.foreground_value = foreground
        self.accent_value = accent
        self.surface_value = surface
        self.revision += 1
    }
    pub fn set_font_size(size: f64) -> Result<bool> {
        if !(size > 0.0 && size < 4096.0) { return err("invalid theme font size", "out_of_range") }
        self.font_value = size
        self.revision += 1
        return ok(true)
    }
}
