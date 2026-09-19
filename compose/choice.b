package compose

import latte.scene

pub abstract class ChoiceControlTemplate extends ControlTemplate {
    pub choices: List<string> = []
    pub selected: int = -1
    pub highlighted: int = -1
    pub selected_text: string = ""
    /// Where each segment starts and how wide it is, from the control itself.
    /// A segment is its own title plus padding, so a template cannot work
    /// these out by dividing its width by the number of choices.
    pub item_x: List<f64> = []
    pub item_width: List<f64> = []
    /// The selected segment's own box, which is what the pill slides to.
    pub selection_x: f64 = 0.0
    pub selection_width: f64 = 0.0
    version: int = -1
    pub fn init() { super.init() }
    pub override fn update(control: scene.RenderObject, theme: scene.Theme) {
        super.update(control, theme)
        match control as? scene.ChoiceRender {
            some(choice) => {
                var starts: List<f64> = []
                var widths: List<f64> = []
                match choice as? scene.SegmentedRender {
                    some(segmented) => {
                        widths = segmented.segment_widths()
                        var x: f64 = 0.0
                        for index: int in 0..widths.len() { starts.push(x); x += widths[index] }
                    }
                    none => {}
                }
                var pill_x: f64 = 0.0
                var pill_width: f64 = 0.0
                if choice.selected() >= 0 && choice.selected() < starts.len() {
                    pill_x = starts[choice.selected()]
                    pill_width = widths[choice.selected()]
                }
                if self.version == choice.version() && self.selected == choice.selected() &&
                   self.highlighted == choice.highlighted() &&
                   self.selection_x == pill_x && self.selection_width == pill_width { return }
                self.version = choice.version()
                self.selected = choice.selected()
                self.highlighted = choice.highlighted()
                self.selected_text = choice.selected_text()
                self.choices = choice.choices()
                self.item_x = move starts
                self.item_width = move widths
                self.selection_x = pill_x
                self.selection_width = pill_width
                self.request_render()
            }
            none => {}
        }
    }
}
