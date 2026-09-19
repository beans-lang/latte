package compose

import latte.scene

pub abstract class SplitControlTemplate extends ControlTemplate {
    pub stacked: bool = false
    pub divider: f64 = 160.0
    pub divider_half: f64 = 157.0
    pub fn init() { super.init() }
    pub override fn update(control: scene.RenderObject, theme: scene.Theme) {
        super.update(control, theme)
        match control as? scene.SplitViewRender {
            some(split) => {
                if self.stacked == split.stacked() && self.divider == split.divider() { return }
                self.stacked = split.stacked()
                self.divider = split.divider()
                self.divider_half = if self.divider >= 3.0 { self.divider - 3.0 } else { 0.0 }
                self.request_render()
            }
            none => {}
        }
    }
}
