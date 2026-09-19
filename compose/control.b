package compose

import latte.geometry
import latte.scene

/// Base for .bx visual templates. These values describe the owning control;
/// the template does not own its input, focus, or accessibility identity.
///
/// Every field below is a resolved theme resource — a colour as markup spells
/// it, or a measurement in points. A template reads them and never reaches for
/// a literal, so one theme change moves every control at once.
pub abstract class ControlTemplate extends Component {
    pub title: string = ""
    pub enabled: bool = true
    pub focused: bool = false
    pub hovered: bool = false
    pub pressed: bool = false
    /// The leading button on a screen, filled with the accent colour.
    pub prominent: bool = false
    /// Whether the window this control sits in has the keyboard.
    pub active: bool = true
    /// The control's own frame. A template that paints something a different
    /// size from its box — a switch, a level indicator — centres against these.
    pub width: f64 = 0.0
    pub height: f64 = 0.0

    // ---- the bezel this control paints, already resolved for its state
    pub fill: string = "#ebebebff"
    pub ink: string = "#000000d8"
    pub accent: string = "#007affff"
    /// What a filled control paints: switch on, selected segment, slider fill.
    pub accent_fill: string = "#0077f9ff"
    pub on_accent: string = "#ffffffff"

    // ---- colours a template may reach for by role
    pub muted: string = "#0000007f"
    pub faint: string = "#00000042"
    pub surface: string = "#ebebebff"
    pub separator: string = "#00000019"
    pub hairline: string = "#e6e6e6ff"
    pub track_off: string = "#e6e6e6ff"
    pub bar_track: string = "#f0f0f0ff"
    pub bar_border: string = "#dfdfdfff"
    pub background: string = "#ffffffff"
    pub grouped: string = "#f5f5f5ff"
    pub card: string = "#ffffffff"
    pub knob: string = "#ffffffff"
    pub knob_on: string = "#ffffffff"
    pub knob_shadow: string = "#00000026"
    pub selection: string = "#0064e1ff"
    /// The fill a selected segment takes when the window is not key.
    pub selection_fill: string = "#0077f9ff"
    pub stripe: string = "#f4f5f5ff"
    pub field: string = "#ffffffff"
    pub field_border: string = "#00000017"
    pub placeholder: string = "#0000007f"
    pub focus_ring: string = "#0067f47f"
    pub success: string = "#34c759ff"
    pub warning: string = "#ff8d28ff"
    pub destructive: string = "#ff383cff"
    pub clear: string = "#00000000"

    // ---- metrics for this control size
    pub radius: f64 = 5.5
    pub radius_small: f64 = 4.5
    pub radius_large: f64 = 8.0
    pub capsule: f64 = 1000.0
    pub control_height: f64 = 24.0
    pub control_padding: f64 = 12.0
    pub chevron_width: f64 = 7.25
    pub chevron_block: f64 = 10.5
    pub chevron_height: f64 = 4.2
    pub chevron_gap: f64 = 2.1
    pub chevron_stroke: f64 = 1.75
    pub chevron_inset: f64 = 10.25
    pub chevron_column: f64 = 36.0
    pub baseline: f64 = 17.0
    pub field_baseline: f64 = 17.0
    pub field_height: f64 = 24.0
    pub field_radius: f64 = 6.0
    pub field_padding: f64 = 6.0
    pub field_overhang: f64 = 1.0
    pub field_border_width: f64 = 1.0
    pub toggle_size: f64 = 16.0
    pub toggle_radius: f64 = 4.5
    pub toggle_gap: f64 = 6.0
    pub toggle_baseline: f64 = 13.0
    pub radio_dot: f64 = 5.0
    pub mark_stroke: f64 = 2.0
    pub dash_width: f64 = 6.5
    pub dash_thickness: f64 = 2.0
    pub switch_width: f64 = 54.0
    pub switch_height: f64 = 24.0
    pub switch_inset: f64 = 2.0
    pub switch_knob_width: f64 = 32.0
    pub switch_knob_height: f64 = 20.0
    pub switch_travel: f64 = 18.0
    pub slider_height: f64 = 16.0
    pub slider_overhang: f64 = 0.5
    pub slider_track: f64 = 6.0
    pub slider_knob: f64 = 19.5
    pub slider_knob_height: f64 = 14.5
    pub bar_control_height: f64 = 20.0
    pub bar_height: f64 = 8.0
    pub bar_radius: f64 = 3.0
    pub level_height: f64 = 18.0
    pub level_content: f64 = 16.25
    pub level_cells: int = 10
    pub level_cell_width: f64 = 11.0
    pub level_cell_height: f64 = 14.5
    pub level_cell_gap: f64 = 1.0
    pub level_cell_radius: f64 = 2.0
    pub level_empty: string = "#edededff"
    pub level_border: string = "#cececeff"
    pub level_fill: string = "#34c759ff"
    pub level_fill_border: string = "#2dad4dff"
    pub stepper_width: f64 = 20.0
    pub stepper_height: f64 = 26.0
    pub stepper_glyph_width: f64 = 11.5
    pub stepper_glyph_height: f64 = 19.5
    pub stepper_glyph_top: f64 = 3.25
    pub stepper_glyph_bottom: f64 = 3.0
    pub stepper_stroke: f64 = 2.0
    pub stepper_divider: string = "#d4d4d4ff"
    pub stepper_divider_inset: f64 = 3.0
    pub stepper_divider_height: f64 = 1.0
    pub row_height: f64 = 24.0
    pub header_height: f64 = 28.0
    pub focus_width: f64 = 3.0
    pub hairline_width: f64 = 1.0
    pub spacing: f64 = 8.0
    pub segment_padding: f64 = 21.0

    // ---- the popup menu
    pub menu_font_size: f64 = 13.0
    pub menu_row_height: f64 = 24.0
    pub menu_baseline: f64 = 17.0
    pub menu_padding: f64 = 5.0
    pub menu_mark_inset: f64 = 11.3
    pub menu_mark_width: f64 = 8.7
    pub menu_mark_height: f64 = 8.6
    pub menu_mark_stroke: f64 = 1.3
    pub menu_text_inset: f64 = 21.2
    pub menu_trailing: f64 = 19.0
    pub menu_check_column: f64 = 8.0
    pub menu_radius: f64 = 10.0
    pub menu_row_radius: f64 = 4.0
    pub menu_row_inset: f64 = 5.0
    pub menu_fill: string = "#ffffffff"
    pub menu_border: string = "#00000019"
    pub menu_shadow: string = "#0000004c"
    pub menu_shadow_blur: f64 = 12.0
    pub menu_shadow_dy: f64 = 4.0

    // ---- motion, in seconds. Zero is the honest value for a control macOS
    // does not animate, and for every control when reduced motion is on.
    pub motion_switch: f64 = 0.15
    pub motion_slider: f64 = 0.23
    pub motion_selection: f64 = 0.15
    pub motion_curve: int = 1

    // ---- typography
    pub font_size: f64 = 13.0
    pub font_weight: int = 0
    pub selected_weight: int = 3
    pub headline: f64 = 13.0
    pub subheadline: f64 = 11.0
    pub footnote: f64 = 10.0
    pub caption: f64 = 10.0
    theme_revision: int = -1

    pub fn init() { super.init() }
    pub fn bind_actions(actions: scene.ControlActions) {}
    pub fn decorate_popup(root: scene.RenderObject) -> Result<bool> { return ok(false) }

    pub fn update(control: scene.RenderObject, theme: scene.Theme) {
        let down: bool = control.is_pressed()
        let live: bool = control.is_enabled()
        // AppKit gives a push button no hover fill, so hover is carried for a
        // template that wants it and changes nothing on its own.
        let bezel: int = if !live { theme.surface_disabled() }
                         else if down { theme.surface_pressed() }
                         else { theme.surface() }
        let fill: string = ControlTemplate.color(bezel)
        let ink: string = ControlTemplate.color(if live { control.text_color() } else { theme.disabled_label() })
        let accent: string = ControlTemplate.color(theme.accent())
        var prominent: bool = false
        match control as? scene.ButtonRender { some(button) => { prominent = button.prominent() } none => {} }
        let active: bool = theme.is_window_active()
        // A filled button paints controlAccentColor exactly; a switch, slider
        // and selected segment paint it under the wash AppKit puts over them.
        // A window that is not key drains the accent out of all of them.
        // A filled control that is off for good keeps a faded accent; only a
        // prominent button goes grey, because a grey switch reads as off.
        let filled: int = if !live { if prominent { theme.surface_disabled() } else { theme.accent_disabled() } }
                          else if !active { if prominent { theme.surface() } else { theme.accent_inactive() } }
                          else if down { if prominent { theme.accent_pressed() } else { theme.accent_control_pressed() } }
                          else if prominent { theme.accent() }
                          else { theme.accent_control() }
        let accent_fill: string = ControlTemplate.color(filled)
        let box: geometry.Rect = control.frame()
        if self.title == control.text() && self.enabled == live &&
           self.focused == control.focused() && self.hovered == control.hovered() &&
           self.pressed == down && self.fill == fill && self.ink == ink &&
           self.accent == accent && self.accent_fill == accent_fill &&
           self.font_size == control.font_size() && self.prominent == prominent &&
           self.active == active && self.width == box.width && self.height == box.height &&
           self.theme_revision == theme.version() { return }
        self.width = box.width; self.height = box.height
        self.title = control.text(); self.enabled = live; self.focused = control.focused()
        self.hovered = control.hovered()
        self.pressed = down; self.fill = fill; self.ink = ink; self.accent = accent
        self.accent_fill = accent_fill
        self.prominent = prominent
        self.active = active
        self.font_size = control.font_size()
        self.adopt(theme)
        self.request_render()
    }

    /// Copies every theme resource a template can read. One revision guards them
    /// all, so a template never mixes values from two appearances.
    fn adopt(theme: scene.Theme) {
        self.theme_revision = theme.version()
        self.on_accent = ControlTemplate.color(if self.enabled { theme.on_accent() } else { theme.on_accent_disabled() })
        self.muted = ControlTemplate.color(theme.secondary_label())
        self.faint = ControlTemplate.color(theme.tertiary_label())
        self.surface = ControlTemplate.color(theme.surface())
        self.separator = ControlTemplate.color(theme.separator())
        self.hairline = ControlTemplate.color(theme.grid())
        self.track_off = ControlTemplate.color(
            if !self.enabled { theme.track_disabled() }
            else if self.pressed { theme.track_pressed() }
            else { theme.track() })
        self.bar_track = ControlTemplate.color(theme.bar_track())
        self.bar_border = ControlTemplate.color(theme.bar_track_border())
        self.background = ControlTemplate.color(theme.background())
        self.grouped = ControlTemplate.color(theme.sunken())
        self.card = ControlTemplate.color(theme.card())
        self.knob = ControlTemplate.color(theme.knob())
        self.knob_on = ControlTemplate.color(theme.knob_on())
        self.knob_shadow = ControlTemplate.color(theme.knob_shadow())
        self.selection = ControlTemplate.color(theme.selection())
        self.selection_fill = ControlTemplate.color(
            if !self.enabled { theme.selection_disabled() }
            else if !self.active { theme.selection_inactive() }
            else { theme.accent_control() })
        self.stripe = ControlTemplate.color(theme.stripe())
        self.field = ControlTemplate.color(if self.enabled { theme.field() } else { theme.field_disabled() })
        self.field_border = ControlTemplate.color(theme.field_border())
        self.placeholder = ControlTemplate.color(theme.placeholder())
        self.focus_ring = ControlTemplate.color(theme.focus_ring())
        self.success = ControlTemplate.color(theme.success())
        self.warning = ControlTemplate.color(theme.warning())
        self.destructive = ControlTemplate.color(theme.destructive())

        self.radius = theme.control_radius()
        self.radius_small = theme.radius_small()
        self.radius_large = theme.radius_large()
        self.capsule = theme.capsule()
        self.control_height = theme.control_height()
        self.control_padding = theme.control_padding()
        self.chevron_width = theme.chevron_width()
        self.chevron_block = theme.chevron_block()
        self.chevron_height = theme.chevron_height()
        self.chevron_gap = theme.chevron_gap()
        self.chevron_stroke = theme.chevron_stroke()
        self.chevron_inset = theme.chevron_inset()
        self.chevron_column = theme.chevron_column()
        self.baseline = theme.control_baseline()
        self.field_baseline = theme.field_baseline()
        self.field_height = theme.field_height()
        self.field_radius = theme.field_radius()
        self.field_padding = theme.field_padding()
        self.field_overhang = theme.field_overhang()
        self.field_border_width = theme.field_border_width()
        self.toggle_size = theme.toggle_size()
        self.toggle_radius = theme.toggle_radius()
        self.toggle_gap = theme.toggle_gap()
        self.toggle_baseline = theme.toggle_baseline()
        self.radio_dot = theme.radio_dot()
        self.mark_stroke = theme.toggle_mark_stroke()
        self.dash_width = theme.toggle_dash_width()
        self.dash_thickness = theme.toggle_dash_thickness()
        self.switch_width = theme.switch_width()
        self.switch_height = theme.switch_height()
        self.switch_inset = theme.switch_knob_inset()
        self.switch_knob_width = theme.switch_knob_width()
        self.switch_knob_height = theme.switch_knob_height()
        self.switch_travel = theme.switch_travel()
        self.slider_height = theme.slider_height()
        self.slider_overhang = theme.slider_overhang()
        self.slider_track = theme.slider_track_thickness()
        self.slider_knob = theme.slider_knob_width()
        self.slider_knob_height = theme.slider_knob_height()
        self.bar_control_height = theme.bar_control_height()
        self.bar_height = theme.bar_height()
        self.bar_radius = theme.bar_radius()
        self.level_height = theme.level_height()
        self.level_content = theme.level_content_height()
        self.level_cells = theme.level_cells()
        self.level_cell_width = theme.level_cell_width()
        self.level_cell_height = theme.level_cell_height()
        self.level_cell_gap = theme.level_cell_gap()
        self.level_cell_radius = theme.level_cell_radius()
        self.level_empty = ControlTemplate.color(theme.level_cell_empty())
        self.level_border = ControlTemplate.color(theme.level_cell_border())
        self.level_fill = ControlTemplate.color(theme.level_cell_fill())
        self.level_fill_border = ControlTemplate.color(theme.level_cell_fill_border())
        self.stepper_width = theme.stepper_width()
        self.stepper_height = theme.stepper_height()
        self.stepper_glyph_width = theme.stepper_glyph_width()
        self.stepper_glyph_height = theme.stepper_glyph_height()
        self.stepper_glyph_top = theme.stepper_glyph_top()
        self.stepper_glyph_bottom = theme.stepper_glyph_bottom()
        self.stepper_stroke = theme.stepper_stroke()
        self.stepper_divider = ControlTemplate.color(theme.stepper_divider())
        self.stepper_divider_inset = theme.stepper_divider_inset()
        self.stepper_divider_height = theme.stepper_divider_height()
        self.row_height = theme.row_height()
        self.header_height = theme.header_height()
        self.focus_width = theme.focus_ring_width()
        self.hairline_width = theme.hairline()
        self.spacing = theme.spacing()
        self.segment_padding = theme.segment_padding()

        self.menu_font_size = theme.menu_font_size()
        self.menu_row_height = theme.menu_row_height()
        self.menu_baseline = theme.menu_baseline()
        self.menu_padding = theme.menu_padding()
        self.menu_mark_inset = theme.menu_mark_inset()
        self.menu_mark_width = theme.menu_mark_width()
        self.menu_mark_height = theme.menu_mark_height()
        self.menu_mark_stroke = theme.menu_mark_stroke()
        self.menu_text_inset = theme.menu_text_inset()
        self.menu_trailing = theme.menu_trailing()
        self.menu_check_column = theme.menu_check_column()
        self.menu_radius = theme.menu_radius()
        self.menu_row_radius = theme.menu_row_radius()
        self.menu_row_inset = theme.menu_row_inset()
        self.menu_fill = ControlTemplate.color(theme.menu_background())
        self.menu_border = ControlTemplate.color(theme.menu_border())
        self.menu_shadow = ControlTemplate.color(theme.menu_shadow())
        self.menu_shadow_blur = theme.menu_shadow_blur()
        self.menu_shadow_dy = theme.menu_shadow_dy()

        self.motion_switch = theme.motion_switch()
        self.motion_slider = theme.motion_slider()
        self.motion_selection = theme.motion_selection()
        self.motion_curve = theme.motion_curve()

        self.selected_weight = theme.selected_weight()
        self.headline = theme.headline()
        self.subheadline = theme.subheadline()
        self.footnote = theme.footnote()
        self.caption = theme.caption1()
    }

    static fn color(value: int) -> string { return scene.Theme.hex(value) }
}

pub interface TemplateFactory {
    fn create(control: scene.RenderObject) -> Option<ControlTemplate>
}

/// An optional extension: existing theme factories remain source compatible.
pub interface PopupTemplateFactory extends TemplateFactory {
    fn create_popup(control: scene.RenderObject) -> Option<ControlTemplate>
}

/// A theme that also dresses what is *inside* an open popup — a button in a
/// menu is a menu row, not a push button. Its own interface for the same
/// reason the one above is: a theme that does not answer keeps working, and
/// its controls keep the look they have outside a popup.
pub interface PopupRowTemplateFactory extends PopupTemplateFactory {
    fn create_in_popup(control: scene.RenderObject) -> Option<ControlTemplate>
}
