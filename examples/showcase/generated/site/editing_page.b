// Generated from examples/showcase/site/editing_page.bx by latte-bx. Do not edit.
//
// The <beans> block below is editing_page.bx's, copied through byte for byte; its
// own package line is blanked so every line after it keeps its number. The
// render method under it is the markup, as Builder calls with fixed
// sequence numbers. Change editing_page.bx and regenerate:
//
//     latte-bx build examples/showcase/site/editing_page.bx
package site

import {Builder, Component} from latte.compose
import {UiEvent} from latte.input


//          

import latte.compose
import {view} from latte.annotations

@view
pub partial class EditingPage extends compose.Component {
    pub name: string = ""
    pub password: string = ""
    pub search: string = ""
    pub notes: string = ""

    pub fn init() { super.init() }

    pub fn clear() {
        self.name = ""
        self.password = ""
        self.search = ""
        self.notes = ""
        self.request_render()
    }

    /// Text that breaks a naive editor: a family emoji is one grapheme made of
    /// seven code points, an Arabic run is right to left, and a combining
    /// accent attaches to the letter before it.
    pub fn fill() {
        self.name = "Zoë 👩‍👩‍👧‍👦"
        self.search = "مرحبا bonjour"
        self.notes = "café\nrésumé\n👋🏽 naïve"
        self.request_render()
    }

    /// Byte lengths, which is what a caret counts in. A test reads this rather
    /// than the field, so a change to selection cannot be hidden by a change
    /// to what is displayed.
    pub fn lengths() -> string {
        return "name {self.name.len()} bytes, search {self.search.len()}, notes {self.notes.len()}"
    }
}

partial class EditingPage {
    pub override fn render(b: Builder) {
        b.open("ScrollView")  // editing_page.bx:1
        b.number("height", (520) as f64)
        b.open("VStack")  // editing_page.bx:2
        b.number("padding", (20) as f64)
        b.number("spacing", (10) as f64)
        b.word("align", "stretch")
        b.open("Label")  // editing_page.bx:3
        b.text("Editing")
        b.number("font_size", (23) as f64)
        b.close()
        b.open("Label")  // editing_page.bx:4
        b.text("Type, select, paste, and try your keyboard's input method. Double-click selects a word; option and arrow move by one.")
        b.word("text_color", "#555b6b")
        b.close()
        b.open("Label")  // editing_page.bx:6
        b.text("Name")
        b.close()
        b.open("TextField")  // editing_page.bx:7
        b.key("{"name"}")
        b.on("commit", fn(_e: UiEvent) { self.name = _e.text })
        b.a11y_label("Your name")
        b.text("{self.name}")
        b.close()
        b.open("Label")  // editing_page.bx:8
        b.key("{"echo"}")
        b.text("Value: {self.name}")
        b.word("text_color", "#555b6b")
        b.close()
        b.open("Label")  // editing_page.bx:10
        b.text("Password")
        b.close()
        b.open("SecureField")  // editing_page.bx:11
        b.key("{"password"}")
        b.on("commit", fn(_e: UiEvent) { self.password = _e.text })
        b.a11y_label("Password")
        b.text("{self.password}")
        b.close()
        b.open("Label")  // editing_page.bx:13
        b.text("Search")
        b.close()
        b.open("SearchField")  // editing_page.bx:14
        b.key("{"search"}")
        b.on("commit", fn(_e: UiEvent) { self.search = _e.text })
        b.a11y_label("Search orders")
        b.text("{self.search}")
        b.close()
        b.open("Label")  // editing_page.bx:16
        b.text("Notes")
        b.close()
        b.open("TextArea")  // editing_page.bx:17
        b.key("{"notes"}")
        b.number("height", (120) as f64)
        b.on("commit", fn(_e: UiEvent) { self.notes = _e.text })
        b.a11y_label("Order notes")
        b.text("{self.notes}")
        b.close()
        b.open("HStack")  // editing_page.bx:19
        b.number("spacing", (10) as f64)
        b.open("Button")  // editing_page.bx:20
        b.key("{"clear"}")
        b.text("Clear")
        b.on("click", fn(e: UiEvent) { self.clear() })
        b.close()
        b.open("Button")  // editing_page.bx:21
        b.key("{"fill"}")
        b.text("Fill with emoji and RTL")
        b.on("click", fn(e: UiEvent) { self.fill() })
        b.close()
        b.close()
        b.open("Label")  // editing_page.bx:25
        b.key("{"lengths"}")
        b.text("{self.lengths()}")
        b.word("text_color", "#555b6b")
        b.close()
        b.close()
        b.close()
    }
}
