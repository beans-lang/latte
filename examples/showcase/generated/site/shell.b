// Generated from examples/showcase/site/shell.bx by latte-bx. Do not edit.
//
// The <beans> block below is shell.bx's, copied through byte for byte; its
// own package line is blanked so every line after it keeps its number. The
// render method under it is the markup, as Builder calls with fixed
// sequence numbers. Change shell.bx and regenerate:
//
//     latte-bx build examples/showcase/site/shell.bx
package site

import {Builder, Component} from latte.compose
import {UiEvent} from latte.input


//          

import latte.compose
import {view} from latte.annotations

/// What opens, and how big the table on it is.
///
/// Set before `latte_mount`, which is the only moment it is read: the showcase
/// is the thing the table benchmark drives, and a benchmark that had to click
/// its way to a screen would be timing the click.
pub singleton class ShowcaseShape {
    pub page: int = 0
    pub rows: int = 1000000
    pub columns: int = 200
    fn init() {}
    pub fn set(rows: int, columns: int, page: int) {
        self.rows = rows
        self.columns = columns
        self.page = page
    }
}

/// The showcase's frame: a row of buttons, and whichever screen they chose.
///
/// The `$if` chain rather than five screens with four hidden: a hidden control
/// is still measured, still laid out and still in the accessibility tree, and
/// a showcase that kept five of them would be measuring five screens on every
/// frame to draw one.
@view
pub partial class Shell extends compose.Component {
    pub page: int = 0
    pub status: string = "ready"

    pub fn init() {
        self.page = ShowcaseShape.instance.page
        super.init()
    }

    pub fn show(index: int) {
        if self.page == index { return }
        self.page = index
        self.status = "ready"
        self.request_render()
    }

    /// Which screen is showing, for a check that drives the shell rather than
    /// reaching inside it.
    pub fn showing() -> int { return self.page }
}

// Every component tag in shell.bx, checked by beansc rather than by latte-bx:
// a tag whose type is not a Component is a type error naming the type,
// instead of a blank subtree and a fault at run time. Unused, and an
// unused free function is not an error.
fn _latte_component_shell_ControlsPage(value: ControlsPage) -> Component { return value }
fn _latte_component_shell_EditingPage(value: EditingPage) -> Component { return value }
fn _latte_component_shell_TablePage(value: TablePage) -> Component { return value }
fn _latte_component_shell_DrawingPage(value: DrawingPage) -> Component { return value }
fn _latte_component_shell_PanesPage(value: PanesPage) -> Component { return value }
fn _latte_component_shell_GalleryPage(value: GalleryPage) -> Component { return value }

partial class Shell {
    pub override fn render(b: Builder) {
        b.open("VStack")  // shell.bx:1
        b.number("padding", (0) as f64)
        b.number("spacing", (0) as f64)
        b.word("align", "stretch")
        b.open("HStack")  // shell.bx:2
        b.number("padding", (12) as f64)
        b.number("spacing", (8) as f64)
        b.word("align", "center")
        b.word("background", "#f2f2f5")
        b.number("height", (48) as f64)
        b.open("Label")  // shell.bx:3
        b.text("Latte")
        b.number("font_size", (17) as f64)
        b.number("font_weight", (5) as f64)
        b.close()
        b.open("Button")  // shell.bx:4
        b.key("{"nav-controls"}")
        b.text("Controls")
        b.flag("prominent", self.page == 0)
        b.on("click", fn(e: UiEvent) { self.show(0) })
        b.close()
        b.open("Button")  // shell.bx:6
        b.key("{"nav-editing"}")
        b.text("Editing")
        b.flag("prominent", self.page == 1)
        b.on("click", fn(e: UiEvent) { self.show(1) })
        b.close()
        b.open("Button")  // shell.bx:8
        b.key("{"nav-table"}")
        b.text("Table")
        b.flag("prominent", self.page == 2)
        b.on("click", fn(e: UiEvent) { self.show(2) })
        b.close()
        b.open("Button")  // shell.bx:10
        b.key("{"nav-drawing"}")
        b.text("Drawing")
        b.flag("prominent", self.page == 3)
        b.on("click", fn(e: UiEvent) { self.show(3) })
        b.close()
        b.open("Button")  // shell.bx:12
        b.key("{"nav-panes"}")
        b.text("Panes")
        b.flag("prominent", self.page == 4)
        b.on("click", fn(e: UiEvent) { self.show(4) })
        b.close()
        b.open("Button")  // shell.bx:14
        b.key("{"nav-gallery"}")
        b.text("Gallery")
        b.flag("prominent", self.page == 5)
        b.on("click", fn(e: UiEvent) { self.show(5) })
        b.close()
        b.open("Label")  // shell.bx:16
        b.text("")
        b.number("grow", (1) as f64)
        b.close()
        b.open("Label")  // shell.bx:17
        b.key("{"status"}")
        b.text("{self.status}")
        b.word("text_color", "#555b6b")
        b.close()
        b.close()
        b.open("Separator")  // shell.bx:19
        b.number("height", (1) as f64)
        b.close()
        if self.page == 0 {  // shell.bx:20
            b.child<ControlsPage>("c0", fn(_latte_c: ControlsPage) {  // shell.bx:21
            }).number("grow", (1) as f64)
        } else if self.page == 1 {  // shell.bx:22
            b.child<EditingPage>("c1", fn(_latte_c: EditingPage) {  // shell.bx:23
            }).number("grow", (1) as f64)
        } else if self.page == 2 {  // shell.bx:24
            b.child<TablePage>("c2", fn(_latte_c: TablePage) {  // shell.bx:25
            }).number("grow", (1) as f64)
        } else if self.page == 3 {  // shell.bx:26
            b.child<DrawingPage>("c3", fn(_latte_c: DrawingPage) {  // shell.bx:27
            }).number("grow", (1) as f64)
        } else if self.page == 4 {  // shell.bx:28
            b.child<PanesPage>("c4", fn(_latte_c: PanesPage) {  // shell.bx:29
            }).number("grow", (1) as f64)
        } else {  // shell.bx:30
            b.child<GalleryPage>("c5", fn(_latte_c: GalleryPage) {  // shell.bx:31
            }).number("grow", (1) as f64)
        }
        b.close()
    }
}
