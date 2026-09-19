package compose

import latte.scene

pub abstract class ToggleControlTemplate extends ControlTemplate {
    pub checked: bool = false
    pub mixed: bool = false
    pub mark: string = ""
    pub track: string = "#e9e9eaff"

    pub fn init() { super.init() }

    pub override fn update(control: scene.RenderObject, theme: scene.Theme) {
        super.update(control, theme)
        match control as? scene.ToggleRender {
            some(toggle) => {
                let checked: bool = toggle.checked() == 1
                let mixed: bool = toggle.checked() == 2
                let mark: string = if mixed { "−" } else if checked { "✓" } else { "" }
                // A switch's capsule has its own state colours; a check box and
                // a radio share theirs. Resolving here rather than in the
                // template keeps one colour per state in one place.
                match control as? scene.SwitchRender {
                    some(_) => {
                        if self.pressed { self.track_off = ControlTemplate.color(theme.switch_track_pressed()) }
                        self.accent_fill = ControlTemplate.color(
                            if !self.enabled { theme.switch_accent_disabled() }
                            else if !self.active { theme.switch_accent_inactive() }
                            else if self.pressed { theme.switch_accent_pressed() }
                            else { theme.accent_control() })
                    }
                    none => {}
                }
                let track: string = if checked || mixed { self.accent } else { self.track_off }
                // A switch held down paints one flat capsule: the knob takes
                // the track's own colour and disappears. Every other state
                // tints the knob by how far the track has been drained.
                let knob: string = if self.pressed {
                                       if checked { self.accent_fill } else { self.track_off }
                                   } else if !self.enabled {
                                       ControlTemplate.color(if checked { theme.knob_disabled_on() } else { theme.knob_disabled() })
                                   } else if !self.active {
                                       ControlTemplate.color(if checked { theme.knob_inactive_on() } else { theme.knob_inactive() })
                                   } else {
                                       ControlTemplate.color(if checked { theme.knob_on() } else { theme.knob() })
                                   }
                if self.checked == checked && self.mixed == mixed && self.mark == mark &&
                   self.track == track && self.knob == knob { return }
                self.checked = checked; self.mixed = mixed; self.mark = mark; self.track = track
                self.knob = knob
                self.request_render()
            }
            none => {}
        }
    }
}
