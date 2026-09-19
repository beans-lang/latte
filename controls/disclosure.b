// A title you press to show or hide what is under it.
package controls

import latte.platform
import latte.scene

/// A disclosure.
///
/// GTK has a real one — `GtkExpander` holds a child, draws its own arrow and
/// hides the child when it is shut. AppKit and UIKit have the *glyph* and no
/// container: an `NSButton` with `NSBezelStyleDisclosure`, drawn and rotated
/// and reported to assistive technology by AppKit, and UIKit's `chevron.right`
/// and `chevron.down` symbols. Putting one beside a title with a body under it
/// is what an application does, and it is what those two hosts do. **Not on
/// every platform**: the Win32 common controls have no such glyph at all, so
/// this refuses with `no_such_control` there rather than drawing one.
///
/// It holds children like a `Container` does, and its text is the title.
///
/// **A shut disclosure still takes up the room its children asked for**,
/// unless the program stops describing them. The host hides the body and
/// reports the header through `content_inset`; what it cannot do is re-run the
/// caller's layout. A screen that wants the column to close up renders no
/// children while it is shut — in markup that is an `$if`, and in code it is
/// not adding them. Saying it plainly here because the alternative is a
/// framework that quietly re-solves a layout the caller did not ask it to.
pub class Disclosure extends ChildHolder {
    pub fn init(context: scene.UiContext) {
        super.init(WidgetKind.disclosure, context)
    }

    /// A disclosure with a title, open or shut.
    pub static fn of(context: scene.UiContext, title: string, open: bool) -> Result<Disclosure> {
        WidgetKind.disclosure.demand()?
        var twisty: Disclosure = new Disclosure(context)
        twisty.set_title(title)?
        twisty.set_open(open)?
        return ok(twisty)
    }

    pub fn set_title(title: string) -> Result<bool> {
        return self.set_text_raw(title)
    }

    pub fn title() -> Result<string> {
        return self.text_raw()
    }

    pub override fn display_text() -> Result<string> {
        return self.title()
    }

    pub fn set_open(open: bool) -> Result<bool> {
        return self.set_flag(platform.P_EXPANDED, open, "open or shut a disclosure")
    }

    pub fn is_open() -> Result<bool> {
        return self.read_flag(platform.P_EXPANDED, "read whether a disclosure is open")
    }
}
