package controls

import latte.scene
import latte.visual

/// The migration boundary. A kind is either implemented in shared Beans code
/// or refused; it never quietly allocates a native control inside the surface.
pub class SharedFactory {
    pub static fn make(kind: WidgetKind, context: scene.UiContext,
                       drawing: Option<visual.Kind> = none) -> Result<scene.RenderObject> {
        match drawing {
            some(shape) => {
                if kind != WidgetKind.canvas { return err("drawing kind requires a canvas node", "wrong_kind") }
                return ok(new scene.VisualRender(context.renderer(), context.theme(), context.invalidation(), shape))
            }
            none => {}
        }
        match kind {
            container => { return ok(new scene.BoxRender(context.renderer(), context.theme(), context.invalidation())) }
            label => { return ok(new scene.TextRender(context.renderer(), context.theme(), context.invalidation())) }
            button => { return ok(new scene.ButtonRender(context.renderer(), context.theme(), context.invalidation())) }
            text_field => { return ok(new scene.TextFieldRender(context.renderer(), context.theme(), context.invalidation())) }
            secure_field => { return ok(new scene.SecureFieldRender(context.renderer(), context.theme(), context.invalidation())) }
            search_field => { return ok(new scene.SearchFieldRender(context.renderer(), context.theme(), context.invalidation())) }
            text_area => { return ok(new scene.TextAreaRender(context.renderer(), context.theme(), context.invalidation())) }
            scroll_view => { return ok(new scene.ScrollRender(context.renderer(), context.theme(), context.invalidation())) }
            check_box => { return ok(new scene.CheckBoxRender(context.renderer(), context.theme(), context.invalidation())) }
            radio_button => { return ok(new scene.RadioButtonRender(context.renderer(), context.theme(), context.invalidation())) }
            switch => { return ok(new scene.SwitchRender(context.renderer(), context.theme(), context.invalidation())) }
            slider => { return ok(new scene.SliderRender(context.renderer(), context.theme(), context.invalidation())) }
            stepper => { return ok(new scene.StepperRender(context.renderer(), context.theme(), context.invalidation())) }
            progress_bar => { return ok(new scene.ProgressBarRender(context.renderer(), context.theme(), context.invalidation())) }
            level_indicator => { return ok(new scene.LevelIndicatorRender(context.renderer(), context.theme(), context.invalidation())) }
            separator => { return ok(new scene.SeparatorRender(context.renderer(), context.theme(), context.invalidation())) }
            group_box => { return ok(new scene.GroupBoxRender(context.renderer(), context.theme(), context.invalidation())) }
            disclosure => { return ok(new scene.DisclosureRender(context.renderer(), context.theme(), context.invalidation())) }
            combo_box => { return ok(new scene.ComboBoxRender(context.renderer(), context.theme(), context.invalidation())) }
            segmented => { return ok(new scene.SegmentedRender(context.renderer(), context.theme(), context.invalidation())) }
            tab_view => { return ok(new scene.TabViewRender(context.renderer(), context.theme(), context.invalidation())) }
            split_view => { return ok(new scene.SplitViewRender(context.renderer(), context.theme(), context.invalidation())) }
            table => { return ok(new scene.TableRender(context.renderer(), context.theme(), context.invalidation())) }
            _ => { return err("{kind.name()} has not migrated to the shared renderer", "not_migrated") }
        }
    }
}
