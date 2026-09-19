package compose

import latte.scene

/// A button standing in for a menu row: the mark it carries and whether the
/// pointer or keyboard is on it. The row's behaviour stays the button's.
pub abstract class MenuRowControlTemplate extends ControlTemplate {
    pub checked: bool = false
    pub fn init() { super.init() }
    pub override fn update(control: scene.RenderObject, theme: scene.Theme) {
        super.update(control, theme)
        match control as? scene.ButtonRender {
            some(button) => {
                if self.checked == button.checked() { return }
                self.checked = button.checked()
                self.request_render()
            }
            none => {}
        }
    }
}
