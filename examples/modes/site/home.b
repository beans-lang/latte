// Generated from examples/modes/site/home.bx by latte-bx. Do not edit.
//
// The <beans> block below is home.bx's, copied through byte for byte; its
// own package line is blanked so every line after it keeps its number. The
// render method under it is the markup, as Builder calls with fixed
// sequence numbers. Change home.bx and regenerate:
//
//     latte-bx build examples/modes/site/home.bx
package site

import {Builder, Callback, Component, FocusEvent, InputEvent, KeyboardEvent, MouseEvent, Reference, SubmitEvent} from latte


// The page every mode appears on, once each.
//
// Read it top to bottom and the whole feature is there:
//
//   * static markup and a normal form, which work with no script at all;
//   * a SERVER counter — the page's own mode, so no boundary and no element;
//   * a CLIENT counter — the same class, one attribute different;
//   * a client `<RenderBlock>`, whose body becomes a component of its own;
//   * a client editor calling a typed server action;
//   * a STATIC region inside the client one, which is the nesting latte has;
//   * an AUTO counter, server until the browser has a bundle.
//          

import std.reflect
import {FormComponent, form, field, layout, page, param, render_mode,
        required} from latte

/// What the form posts. A model of its own, because a `@form` binds onto a
/// value and not onto the page.
@form
pub class NoteForm {
    @field(name: "note") @required(message: "say something")
    pub note: string = ""
    pub fn init() {}
}

@page(route: r"/", methods: ["GET", "POST"])
@layout(name: "Shell")
pub partial class Home extends FormComponent {
    pub model: NoteForm = new NoteForm()
    /// What the posted form left behind, so the page shows its own answer
    /// with JavaScript switched off.
    pub receipt: string = ""

    pub fn init() { super.init() }

    pub override fn form_id() -> string { return "note" }
    pub override fn form_model() -> reflect.Value { return reflect.value(self.model) }

    pub override fn on_submit() {
        self.receipt = "posted: {self.model.note}"
    }
}

// Every component tag in home.bx, checked by beansc rather than by latte-bx:
// a tag whose type is not a Component is a type error naming the type,
// instead of a blank subtree and a fault at run time. Unused, and an
// unused free function is not an error.
fn _latte_component_home_Counter(value: Counter) -> Component { return value }
fn _latte_component_home_Home_block0(value: Home_block0) -> Component { return value }
fn _latte_component_home_Editor(value: Editor) -> Component { return value }

// One class per <RenderBlock> in home.bx: a block's body is a
// component of its own, because an execution boundary needs its own
// instance and its own lifecycle rather than a flag on this one.
/// Generated from the <RenderBlock> at home.bx:64.
/// Its props are the only thing that crosses; `props` is this instance.
class Home_block0 extends Component {
    @param pub title: string = ""
    @param pub rows: int = 0
    pub fn init() {}
    pub override fn render(b: Builder) {
        let props: Home_block0 = self
        b.open(0, "p")  // home.bx:65
        b.attr(1, "id", "block")
        b.text(2, "{props.title} has {props.rows} rows")
        b.close()
        b.open(3, "button")  // home.bx:66
        b.attr(4, "id", "block-add")
        b.on_click(5, fn(e: MouseEvent) { props.rows += 1 })
        b.text(6, "more")
        b.close()
    }
}

partial class Home {
    pub override fn render(b: Builder) {
        if b.fold { b.constant(0, "<p id=\"static\">This paragraph is static markup. No instance renders it twice.</p>") }  // home.bx:47
        else {
            b.open(0, "p")  // home.bx:47
            b.attr(1, "id", "static")
            b.text(2, "This paragraph is static markup. No instance renders it twice.")
            b.close()
        }
        b.open(3, "form")  // home.bx:49
        b.attr(4, "method", "post")
        b.attr(5, "id", "plain")
        b.open(6, "input")  // home.bx:50
        b.attr(7, "name", "note")
        b.attr(8, "value", "{self.model.note}")
        b.on_input(9, fn(e: InputEvent) { self.model.note = e.value })
        b.attr(10, "id", "note")
        b.close()
        if b.fold { b.constant(11, "<button type=\"submit\" id=\"post\">post</button>") }  // home.bx:51
        else {
            b.open(11, "button")  // home.bx:51
            b.attr(12, "type", "submit")
            b.attr(13, "id", "post")
            b.text(14, "post")
            b.close()
        }
        b.close()
        if self.receipt != "" {  // home.bx:53
            b.open(15, "p")  // home.bx:54
            b.attr(16, "id", "receipt")
            b.text(17, "{self.receipt}")
            b.close()
        }
        if b.fold { b.constant(18, "<h2>server</h2>") }  // home.bx:57
        else {
            b.open(18, "h2")  // home.bx:57
            b.text(19, "server")
            b.close()
        }
        b.component<Counter>(20, fn(_latte_c: Counter) {  // home.bx:58
            _latte_c.label = "server"
            _latte_c.start = 1
        })
        if b.fold { b.constant(21, "<h2>client</h2>") }  // home.bx:60
        else {
            b.open(21, "h2")  // home.bx:60
            b.text(22, "client")
            b.close()
        }
        b.component_in<Counter>(23, "client", fn(_latte_c: Counter) {  // home.bx:61
            _latte_c.label = "client"
            _latte_c.start = 10
        })
        if b.fold { b.constant(24, "<h2>a client block</h2>") }  // home.bx:63
        else {
            b.open(24, "h2")  // home.bx:63
            b.text(25, "a client block")
            b.close()
        }
        b.component_in<Home_block0>(26, "client", fn(_latte_c: Home_block0) {  // home.bx:64
            _latte_c.title = self.model.note
            _latte_c.rows = 3
        })
        if b.fold { b.constant(27, "<h2>an action</h2>") }  // home.bx:69
        else {
            b.open(27, "h2")  // home.bx:69
            b.text(28, "an action")
            b.close()
        }
        b.component<Editor>(29, fn(_latte_c: Editor) {  // home.bx:70
            _latte_c.title = "write a note"
        })
        if b.fold { b.constant(30, "<h2>auto</h2>") }  // home.bx:72
        else {
            b.open(30, "h2")  // home.bx:72
            b.text(31, "auto")
            b.close()
        }
        b.component_in<Counter>(32, "auto", fn(_latte_c: Counter) {  // home.bx:73
            _latte_c.label = "auto"
            _latte_c.start = 100
        })
    }
}
