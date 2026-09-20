// Somewhere a program draws for itself.
package controls

import latte.scene

/// A control whose contents a program paints on the GPU.
///
/// Every other widget in latte is the platform's: a `Button` is an
/// `NSButton`, and what it looks like is the operating system's business. A
/// canvas is the opposite — an area the platform lays out and shows, and
/// nothing else. A chart with fifty thousand points, a waveform, a map, a
/// game: none of those is a tree of controls, and a canvas is where they go.
///
/// A control like any other, laid out by the same solver. With no renderer
/// behind it, it is an empty area rather than a missing one.
///
/// A `VisualWidget` is what fills it: a canvas with no shape draws nothing,
/// which is why `WidgetMaker` refuses a bare `<Canvas />` and names the
/// shapes instead.
pub class Canvas extends Widget {
    pub fn init(context: scene.UiContext) {
        super.init(WidgetKind.canvas, context)
    }
}
