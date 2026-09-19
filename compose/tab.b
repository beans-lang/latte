package compose

import latte.scene

pub abstract class TabControlTemplate extends ControlTemplate {
    pub labels: List<string> = []
    pub selected: int = 0
    pub borderless: bool = false
    /// Where each tab starts and how wide it is, and the box the pill slides
    /// to. A tab is its own title plus padding, the way a segment is.
    pub item_x: List<f64> = []
    pub item_width: List<f64> = []
    pub row_width: f64 = 0.0
    pub selection_x: f64 = 0.0
    pub selection_width: f64 = 0.0
    version: int = -1
    pub fn init() { super.init() }
    pub override fn update(control: scene.RenderObject, theme: scene.Theme) {
        super.update(control, theme)
        match control as? scene.TabViewRender {
            some(tabs) => {
                let widths: List<f64> = tabs.tab_widths()
                var starts: List<f64> = []
                var total: f64 = 0.0
                for index: int in 0..widths.len() { starts.push(total); total += widths[index] }
                var pill_x: f64 = 0.0
                var pill_width: f64 = 0.0
                if tabs.selected() >= 0 && tabs.selected() < widths.len() {
                    pill_x = starts[tabs.selected()]
                    pill_width = widths[tabs.selected()]
                }
                if self.version == tabs.labels_version() && self.selected == tabs.selected() &&
                   self.borderless == tabs.borderless() && self.selection_x == pill_x &&
                   self.selection_width == pill_width && self.row_width == total { return }
                self.version = tabs.labels_version()
                self.selected = tabs.selected()
                self.borderless = tabs.borderless()
                self.labels = tabs.labels()
                self.item_x = move starts
                self.item_width = move widths
                self.row_width = total
                self.selection_x = pill_x
                self.selection_width = pill_width
                self.request_render()
            }
            none => {}
        }
    }
}
