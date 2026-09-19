// Turning a description into a real control.
package compose

import latte.controls
import latte.platform
import latte.scene
import latte.visual

/// Builds the control an `Element` describes, and everything under it.
///
/// The one place in latte that maps a `WidgetKind` onto a constructor.
/// Adding a widget means adding a case here and a tag to `Vocabulary`, and
/// `tests/roles.out` then carries it on every platform.
///
/// Children are built and attached depth first, so a container is complete
/// before it is handed to its own parent. That ordering is not free: a
/// platform that lays out on every `addSubview` would otherwise do it once per
/// child per level.
pub class WidgetMaker {
    /// The control for one element, with its properties set and its children
    /// built.
    pub static fn make(element: Element, context: scene.UiContext) -> Result<controls.Widget> {
        var control: controls.Widget = WidgetMaker.bare(element, context)?
        control.render_object()?
        WidgetMaker.write_all(control, element)?
        match control.render_object()? as? scene.VisualRender {
            some(drawing) => { drawing.arm_transitions() }
            none => {}
        }
        if element.count() == 0 {
            return ok(control)
        }
        match control as? controls.ChildHolder {
            some(box) => {
                for child: Element in element.children() {
                    let built: controls.Widget = WidgetMaker.make(child, context)?
                    box.add(built)?
                }
                match control as? controls.TabView { some(tabs) => { tabs.validate_pages()? } none => {} }
                return ok(control)
            }
            none => {}
        }
        match control as? controls.ScrollView {
            some(scroller) => {
                for child: Element in element.children() {
                    let built: controls.Widget = WidgetMaker.make(child, context)?
                    scroller.add(built)?
                }
                return ok(control)
            }
            none => {}
        }
        return err("<{element.tag}> was given {element.count()} children but a {element.kind.name()} cannot hold any",
                   "not_a_container")
    }

    /// An empty control of the right kind.
    pub static fn bare(element: Element, context: scene.UiContext) -> Result<controls.Widget> {
        match visual.kind_of(element.tag) {
            some(shape) => { return ok(new controls.VisualWidget(shape, context)) }
            none => {}
        }
        return WidgetMaker.of_kind(element.kind, context)
    }

    /// An empty control of one kind, with no element behind it.
    ///
    /// The one exhaustive `match` over `WidgetKind` in Latte, and the reason
    /// it is public: a kind added to the enum is a **compile error here**, not
    /// a missing line in a golden somewhere. `tests/enabled.b` walks
    /// `WidgetKind.all()` through this, so the suite grows a row for a new
    /// kind whether or not anybody remembered to add one.
    ///
    /// A kind with no renderer is refused by name here, before anything is
    /// built, so `<Spinner />` in markup is a message about the control rather
    /// than a dead widget whose first attribute write complains about a node.
    pub static fn of_kind(kind: controls.WidgetKind,
                          context: scene.UiContext) -> Result<controls.Widget> {
        match kind {
            container => { return ok(new controls.Container(context)) }
            label => { return ok(new controls.Label(context)) }
            button => { return ok(new controls.Button(context)) }
            text_field => { return ok(new controls.TextField(context)) }
            secure_field => { return ok(new controls.SecureField(context)) }
            search_field => { return ok(new controls.SearchField(context)) }
            text_area => { return ok(new controls.TextArea(context)) }
            scroll_view => { return ok(new controls.ScrollView(context)) }
            check_box => { return ok(new controls.CheckBox(context)) }
            radio_button => { return ok(new controls.RadioButton(context)) }
            switch => { return ok(new controls.Switch(context)) }
            slider => { return ok(new controls.Slider(context)) }
            stepper => { return ok(new controls.Stepper(context)) }
            progress_bar => { return ok(new controls.ProgressBar(context)) }
            level_indicator => { return ok(new controls.LevelIndicator(context)) }
            separator => { return ok(new controls.Separator(context)) }
            group_box => { return ok(new controls.GroupBox(context)) }
            disclosure => { return ok(new controls.Disclosure(context)) }
            combo_box => { return ok(new controls.ComboBox(context)) }
            segmented => { return ok(new controls.Segmented(context)) }
            tab_view => { return ok(new controls.TabView(context)) }
            split_view => { return ok(new controls.SplitView(context)) }
            table => { return ok(new controls.Table(context)) }
            canvas => {
                return err("<Canvas /> draws nothing on its own — give it a shape, as in <Rectangle /> or <Path />",
                           "needs_a_shape")
            }
            _ => {
                return err("Latte has no renderer for a {kind.name()} yet", "not_implemented")
            }
        }
    }

    /// Writes every attribute an element carries onto a control.
    ///
    /// Every refusal stops the render. There is one renderer, so a property a
    /// control does not take is a fact about the markup, not about the
    /// machine, and stepping over it would hide a typo forever.
    pub static fn write_all(control: controls.Widget, element: Element) -> Result<bool> {
        // Items establish the legal selection range. Markup attribute order
        // does not decide whether selected= may be applied.
        for index: int in 0..element.attribute_count() {
            let attribute: Attribute = element.attribute_at(index)
            if attribute.kind == AttributeKind.items { WidgetMaker.write(control, attribute)? }
        }
        for index: int in 0..element.attribute_count() {
            let attribute: Attribute = element.attribute_at(index)
            if attribute.kind == AttributeKind.numbers { WidgetMaker.write(control, attribute)? }
        }
        for index: int in 0..element.attribute_count() {
            let attribute: Attribute = element.attribute_at(index)
            if attribute.kind == AttributeKind.table_source { WidgetMaker.write(control, attribute)? }
        }
        var index: int = 0
        for index: int in 0..element.attribute_count() {
            if element.attribute_at(index).kind == AttributeKind.items ||
               element.attribute_at(index).kind == AttributeKind.numbers ||
               element.attribute_at(index).kind == AttributeKind.table_source { continue }
            WidgetMaker.write(control, element.attribute_at(index))?
        }
        return ok(true)
    }

    /// Writes one attribute.
    pub static fn write(control: controls.Widget, attribute: Attribute) -> Result<bool> {
        if attribute.reset &&
           (attribute.property == visual.GRADIENT_START || attribute.property == visual.GRADIENT_END) {
            match control.render_object()? as? scene.VisualRender {
                some(drawing) => { return drawing.reset_gradient(attribute.property) }
                none => {}
            }
        }
        if attribute.reset && attribute.property == platform.P_FG_COLOR {
            return control.render_object()?.clear_text_color()
        }
        match attribute.kind {
            text => {
                if attribute.property == platform.S_A11Y_LABEL { return control.set_a11y_label(attribute.text) }
                return control.set_display_text(attribute.text)
            }
            real => { return control.set_property_real(attribute.property, attribute.number) }
            whole => {
                if attribute.property == platform.P_SELECTED {
                    match control as? controls.TabView { some(tabs) => { return tabs.set_page_from_markup(attribute.whole) } none => {} }
                }
                return control.set_property(attribute.property, attribute.whole)
            }
            flag => { return control.set_property(attribute.property, attribute.whole) }
            items => {
                match attribute.items_value {
                    none => { return err("items attribute has no list", "invalid") }
                    some(values) => {
                        if attribute.property == TAB_LABELS_PROPERTY {
                            match control as? controls.TabView { some(tabs) => { return tabs.set_labels(values.to_list()) } none => {} }
                            return err("labels belongs on TabView", "unsupported")
                        }
                        if attribute.property == TABLE_COLUMNS_PROPERTY {
                            match control as? controls.Table { some(table) => { return table.set_titles(values.to_list()) } none => {} }
                            return err("columns belongs on Table", "unsupported")
                        }
                        match control as? controls.ComboBox { some(choice) => { return choice.set_items(values.to_list()) } none => {} }
                        match control as? controls.Segmented { some(choice) => { return choice.set_items(values.to_list()) } none => {} }
                    }
                }
                return err("items belongs on ComboBox or Segmented", "unsupported")
            }
            numbers => {
                if attribute.property != TABLE_WIDTHS_PROPERTY { return err("unknown number list", "unsupported") }
                match control as? controls.Table {
                    some(table) => {
                        if attribute.reset { return table.reset_widths() }
                        match attribute.numbers_value {
                            some(values) => { return table.set_widths(values.to_list()) }
                            none => { return err("column widths attribute has no list", "invalid") }
                        }
                    }
                    none => { return err("column widths belongs on Table", "unsupported") }
                }
            }
            table_source => {
                if attribute.property != TABLE_SOURCE_PROPERTY { return err("unknown table source", "unsupported") }
                match control as? controls.Table {
                    some(table) => {
                        match attribute.source_value { some(rows) => { return table.set_source(rows) } none => { return table.clear_source() } }
                    }
                    none => { return err("source belongs on Table", "unsupported") }
                }
            }
            table_edit_policy => {
                if attribute.property != TABLE_EDIT_POLICY_PROPERTY { return err("unknown table edit policy", "unsupported") }
                match control as? controls.Table {
                    some(table) => {
                        match attribute.edit_policy_value {
                            some(rule) => { return table.set_editable_when(rule.callback()) }
                            none => { return table.clear_editable() }
                        }
                    }
                    none => { return err("editable_when belongs on Table", "unsupported") }
                }
            }
        }
    }
}
