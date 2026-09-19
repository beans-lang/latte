// A window onto something bigger.
package controls

import latte.scene

/// A control that shows part of a larger subtree and scrolls the rest into
/// view.
///
/// It holds children the way a `Container` does, and the platform puts them
/// somewhere a caller never names: AppKit inside a document view, GTK inside a
/// viewport. Asking a caller to know which would be asking them to write
/// platform code in Beans, so the child calls reach through whatever the
/// platform wrapped and the tree above sees one control with children.
///
/// It holds **one** child, the way every toolkit here does: an AppKit document
/// view, a GTK viewport's child, a UIScrollView's content. More is refused.
///
/// That child is laid out at its own height and the scroll view keeps the one
/// it was given — see `layout.ScrollLayout`, and give the scroll view a
/// `height` or a `grow`, or it takes its content's height and scrolls nothing.
///
/// **It extends `ChildHolder` like every other box.** It used to carry its own
/// copy of the list, the ordering, the platform calls and the lifetime — sixty
/// lines that said the same thing — and the copy is how it ended up outside
/// the one downcast the component applier does: `<ScrollView>` with children
/// in markup was refused as a control that holds none. Two implementations of
/// one idea is how one of them gets left behind.
pub class ScrollView extends ChildHolder {
    pub fn init(context: scene.UiContext) {
        super.init(WidgetKind.scroll_view, context)
    }
}
