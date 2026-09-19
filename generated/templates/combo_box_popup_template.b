// Generated from templates/combo_box_popup_template.bx by latte-bx. Do not edit.
//
// The <beans> block below is combo_box_popup_template.bx's, copied through byte for byte; its
// own package line is blanked so every line after it keeps its number. The
// render method under it is the markup, as Builder calls with fixed
// sequence numbers. Change combo_box_popup_template.bx and regenerate:
//
//     latte-bx build templates/combo_box_popup_template.bx
package templates

import {Builder, Component} from latte.compose
import {UiEvent} from latte.input


//               
import latte.compose
import latte.scene
import {view} from latte.annotations

@view
pub partial class ComboBoxPopupTemplate extends compose.ChoiceControlTemplate {
    actions: Option<scene.ControlActions> = none
    pub fn init() { super.init() }
    pub override fn bind_actions(actions: scene.ControlActions) { self.actions = some(actions) }
    pub fn choose(index: int) {
        match self.actions {
            some(actions) => {
                actions.choose(index, index as f64).expect("choose a combo box option")
                actions.dismiss()
            }
            none => { panic("combo box popup has no actions") }
        }
    }
    pub override fn decorate_popup(root: scene.RenderObject) -> Result<bool> {
        let found: int = self.decorate_rows(root, 0)?
        if found != self.choices.len() { return err("combo popup rows do not match choices", "tree_drift") }
        return ok(true)
    }
    fn decorate_rows(node: scene.RenderObject, start: int) -> Result<int> {
        var index: int = start
        match node as? scene.ButtonRender {
            some(button) => {
                if index >= self.choices.len() { return err("combo popup has an extra option", "tree_drift") }
                button.set_semantics("option", self.choices[index],
                    if index == self.selected { "selected" } else if index == self.highlighted { "highlighted" } else { "" })?
                index += 1
            }
            none => {}
        }
        for child_index: int in 0..node.child_count() {
            match node.child_at(child_index) {
                some(child) => { index = self.decorate_rows(child, index)? }
                none => {}
            }
        }
        return ok(index)
    }
}

partial class ComboBoxPopupTemplate {
    pub override fn render(b: Builder) {
        b.open("Box")  // combo_box_popup_template.bx:1
        b.number("width_percent", (100.0) as f64)
        b.number("height_percent", (100.0) as f64)
        b.open("Rectangle")  // combo_box_popup_template.bx:4
        b.number("x", (0) as f64)
        b.number("y", (0) as f64)
        b.number("width_percent", (100.0) as f64)
        b.number("height_percent", (100.0) as f64)
        b.number("corner_radius", (self.menu_radius) as f64)
        b.word("fill", self.menu_fill)
        b.word("stroke", self.menu_border)
        b.number("stroke_width", (self.hairline_width) as f64)
        b.word("shadow_color", self.menu_shadow)
        b.number("shadow_blur", (self.menu_shadow_blur) as f64)
        b.number("shadow_dy", (self.menu_shadow_dy) as f64)
        b.close()
        b.open("ScrollView")  // combo_box_popup_template.bx:9
        b.number("x", (0) as f64)
        b.number("y", (self.menu_padding) as f64)
        b.number("width_percent", (100.0) as f64)
        b.number("bottom", (self.menu_padding) as f64)
        b.word("background", self.clear)
        b.open("VStack")  // combo_box_popup_template.bx:11
        b.number("spacing", (0) as f64)
        b.word("align", "stretch")
        b.number("padding_x", (self.menu_row_inset) as f64)
        var _latte_row_0: int = 0
        for index in 0..self.choices.len() {  // combo_box_popup_template.bx:12
            b.open("Button")  // combo_box_popup_template.bx:13
            b.key("{"option-{index}"}")
            b.text("{self.choices[index]}")
            b.number("height", (self.menu_row_height) as f64)
            b.flag("checked", index == self.selected)
            b.flag("prominent", index == self.highlighted)
            b.on("click", fn(e: UiEvent) { self.choose(index) })
            b.close()
            _latte_row_0 += 1
        }
        b.close()
        b.close()
        b.close()
    }
}
