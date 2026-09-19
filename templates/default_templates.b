package templates

import latte.compose
import latte.scene
import {ButtonTemplate, TextFieldTemplate, CheckBoxTemplate, RadioButtonTemplate, SwitchTemplate,
        SliderTemplate, StepperTemplate, ProgressBarTemplate, LevelIndicatorTemplate,
        SeparatorTemplate, GroupBoxTemplate, DisclosureTemplate, ComboBoxTemplate,
        ComboBoxPopupTemplate, MenuRowTemplate, SegmentedTemplate, TabViewTemplate,
        SplitViewTemplate, TableTemplate} from latte.generated.templates

pub class DefaultTemplates implements compose.PopupRowTemplateFactory {
    pub fn init() {}
    pub fn create(control: scene.RenderObject) -> Option<compose.ControlTemplate> {
        match control as? scene.ButtonRender {
            some(_) => { return some(new ButtonTemplate()) }
            none => {}
        }
        match control as? scene.TextFieldRender {
            some(_) => { return some(new TextFieldTemplate()) }
            none => {}
        }
        match control as? scene.CheckBoxRender { some(_) => { return some(new CheckBoxTemplate()) } none => {} }
        match control as? scene.RadioButtonRender { some(_) => { return some(new RadioButtonTemplate()) } none => {} }
        match control as? scene.SwitchRender { some(_) => { return some(new SwitchTemplate()) } none => {} }
        match control as? scene.SliderRender { some(_) => { return some(new SliderTemplate()) } none => {} }
        match control as? scene.StepperRender { some(_) => { return some(new StepperTemplate()) } none => {} }
        match control as? scene.ProgressBarRender { some(_) => { return some(new ProgressBarTemplate()) } none => {} }
        match control as? scene.LevelIndicatorRender { some(_) => { return some(new LevelIndicatorTemplate()) } none => {} }
        match control as? scene.SeparatorRender { some(_) => { return some(new SeparatorTemplate()) } none => {} }
        match control as? scene.GroupBoxRender { some(_) => { return some(new GroupBoxTemplate()) } none => {} }
        match control as? scene.DisclosureRender { some(_) => { return some(new DisclosureTemplate()) } none => {} }
        match control as? scene.ComboBoxRender { some(_) => { return some(new ComboBoxTemplate()) } none => {} }
        match control as? scene.SegmentedRender { some(_) => { return some(new SegmentedTemplate()) } none => {} }
        match control as? scene.TabViewRender { some(_) => { return some(new TabViewTemplate()) } none => {} }
        match control as? scene.SplitViewRender { some(_) => { return some(new SplitViewTemplate()) } none => {} }
        match control as? scene.TableRender { some(_) => { return some(new TableTemplate()) } none => {} }
        return none
    }
    pub fn create_popup(control: scene.RenderObject) -> Option<compose.ControlTemplate> {
        match control as? scene.ComboBoxRender { some(_) => { return some(new ComboBoxPopupTemplate()) } none => {} }
        return none
    }
    /// A button inside an open menu is a menu row. Everything else keeps the
    /// look it has outside one.
    pub fn create_in_popup(control: scene.RenderObject) -> Option<compose.ControlTemplate> {
        match control as? scene.ButtonRender { some(_) => { return some(new MenuRowTemplate()) } none => {} }
        return none
    }
}
