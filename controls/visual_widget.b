package controls

import latte.scene
import latte.visual

/// A declarative drawing node inside a shared Canvas render.
pub class VisualWidget extends Widget {
    pub fn init(kind: visual.Kind, context: scene.UiContext) {
        super.init(WidgetKind.canvas, context, some(kind))
    }
}
