// Generated from examples/cafe/site/order_page.bx by latte-bx. Do not edit.
//
// The <beans> block below is order_page.bx's, copied through byte for byte; its
// own package line is blanked so every line after it keeps its number. The
// render method under it is the markup, as Builder calls with fixed
// sequence numbers. Change order_page.bx and regenerate:
//
//     latte-bx build examples/cafe/site/order_page.bx
package site

import {Builder, Callback, Component, FocusEvent, InputEvent, KeyboardEvent, MouseEvent, Reference, SubmitEvent} from latte


// `examples/cafe/site/order_page.bx` — the order form.
//
// It works **with JavaScript switched off**. The form has a `method`, an
// `action` and a real submit button, so the browser posts it; `PageHost` binds
// the body to the model, validates it, and re-renders the page with whatever
// the user typed still in the boxes. Nothing here is a circuit, and that is
// the point: forms are the half of latte that needs no socket.
//
// `Order` is hand-written in this block because it has no markup — it is a
// model, not a component, and a `.bx` file compiles the markup of exactly one
// class: the one it is named after.
//          

import std.reflect
import {FieldError, FormComponent, TOKEN_FIELD, page, layout, param,
        form, field, required, length, range} from latte

/// What a POST is allowed to write.
///
/// `table` is NOT a `@field`: it comes from the route, and a `@field` on it
/// would let a body move an order to another table. A property with no
/// `@field` is a property no body can reach — that is the rule, and this is
/// the property that shows why it matters.
@form
pub class Order {
    @field @required @length(min: 2, max: 24) pub name: string = ""
    @field @required @range(min: 1, max: 6) pub cups: int = 0
    @field pub decaf: bool = false
    pub table: int = 0
    pub fn init() {}
}

@page(route: r"/order/{table}", methods: ["GET", "POST"])
@layout(name: "Shell")
pub partial class OrderPage extends FormComponent {
    /// Required, and the route carries it. A `@param(required: true)` whose
    /// name is not a placeholder in the route is refused at startup, by name.
    @param(required: true) pub table: int = 0
    pub model: Order = new Order()
    pub placed: int = 0
    pub fn init() { super.init() }

    pub override fn form_id() -> string { return "order" }
    pub override fn form_model() -> reflect.Value { return reflect.value(self.model) }

    /// Runs only when every field bound and every rule passed.
    pub override fn on_submit() {
        self.model.table = self.table
        self.placed += 1
    }

    pub fn action() -> string { return "/order/{self.table}" }
    pub fn heading() -> string { return "Order for table {self.table}" }

    /// What the boxes show on the way back: the text this post carried, and
    /// the model for a GET or a field the body never named. A failed post that
    /// gave the boxes back the model would erase what the user typed.
    pub fn typed_name() -> string {
        return self.state.value_for("name", self.model.name)
    }
    pub fn typed_cups() -> string {
        return self.state.value_for("cups", "{self.model.cups}")
    }

    pub fn receipt() -> string {
        if self.placed == 0 { return "no order placed" }
        let kind: string = if self.model.decaf { "decaf" } else { "regular" }
        return "{self.model.cups} {kind} for {self.model.name} at table {self.model.table}"
    }
}

partial class OrderPage {
    pub override fn render(b: Builder) {
        b.open(0, "section")  // order_page.bx:73
        b.attr(1, "class", "order")
        b.open(2, "h2")  // order_page.bx:74
        b.text(3, "{self.heading()}")
        b.close()
        b.open(4, "form")  // order_page.bx:76
        b.attr(5, "method", "post")
        b.attr(6, "action", "{self.action()}")
        b.open(7, "input")  // order_page.bx:77
        b.attr(8, "type", "hidden")
        b.attr(9, "name", "{TOKEN_FIELD}")
        b.attr(10, "value", "{self.state.token}")
        b.close()
        b.open(11, "label")  // order_page.bx:79
        b.text(12, "name ")
        b.open(13, "input")  // order_page.bx:80
        b.attr(14, "name", "name")
        b.attr(15, "id", "name")
        b.attr(16, "value", "{self.typed_name()}")
        b.close()
        b.close()
        b.open(17, "label")  // order_page.bx:83
        b.text(18, "cups ")
        b.open(19, "input")  // order_page.bx:84
        b.attr(20, "name", "cups")
        b.attr(21, "id", "cups")
        b.attr(22, "value", "{self.typed_cups()}")
        b.close()
        b.close()
        b.open(23, "label")  // order_page.bx:87
        b.text(24, "decaf ")
        b.open(25, "input")  // order_page.bx:88
        b.attr(26, "type", "checkbox")
        b.attr(27, "name", "decaf")
        b.attr(28, "id", "decaf")
        b.flag(29, "checked", self.model.decaf)
        b.close()
        b.close()
        if b.fold { b.constant(30, "<button type=\"submit\" id=\"place\">place the order</button>") }  // order_page.bx:91
        else {
            b.open(30, "button")  // order_page.bx:91
            b.attr(31, "type", "submit")
            b.attr(32, "id", "place")
            b.text(33, "place the order")
            b.close()
        }
        b.close()
        b.open(34, "ul")  // order_page.bx:94
        b.attr(35, "id", "problems")
        for problem: FieldError in self.state.result.errors {  // order_page.bx:95
            b.region(36, "{problem.field}")
            b.open(0, "li")  // order_page.bx:96
            b.text(1, "{problem.field}: {problem.message}")
            b.close()
            b.end_region()
        }
        b.close()
        b.open(37, "p")  // order_page.bx:100
        b.attr(38, "id", "placed")
        b.text(39, "{self.receipt()}")
        b.close()
        b.close()
    }
}
