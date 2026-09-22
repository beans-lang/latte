// Generated from examples/modes/site/editor.bx by latte-bx. Do not edit.
//
// The <beans> block below is editor.bx's, copied through byte for byte; its
// own package line is blanked so every line after it keeps its number. The
// render method under it is the markup, as Builder calls with fixed
// sequence numbers. Change editor.bx and regenerate:
//
//     latte-bx build examples/modes/site/editor.bx
package site

import {Builder, Callback, Component, FocusEvent, InputEvent, KeyboardEvent, MouseEvent, Reference, SubmitEvent} from latte


// A browser component that calls a typed server action.
//
// The action's implementation is in `modes.server`, which nothing here
// imports and nothing in the browser bundle contains. What crosses is the
// NAME and the arguments; `call_action` encodes them, the page performs the
// request with the antiforgery token the document carries, and the reply is
// decoded into a `string` before this file sees it.
//          

import {ActionError, param, render_mode} from latte
import {ActionArgs, call_action} from latte_client

@render_mode(value: "client")
pub partial class Editor extends Component {
    @param pub title: string = "a note"
    pub draft: string = ""
    pub answer: string = ""
    pub sending: bool = false
    call: int = 0

    fn save() {
        if self.sending { return }
        self.sending = true
        self.answer = ""
        var args: ActionArgs = new ActionArgs()
        args.text("body", self.draft)
        self.call = call_action<string>("notes.save", args,
            fn(reply: Result<string, ActionError>) {
                self.sending = false
                match reply {
                    ok(stamp) => { self.answer = "saved as {stamp}" }
                    err(problem) => { self.answer = "{problem.kind}: {problem.message}" }
                }
                self.notify()
            })
    }
}

partial class Editor {
    pub override fn render(b: Builder) {
        b.open(0, "section")  // editor.bx:41
        b.attr(1, "class", "editor")
        b.open(2, "h3")  // editor.bx:42
        b.text(3, "{self.title}")
        b.close()
        b.open(4, "input")  // editor.bx:43
        b.attr(5, "id", "draft")
        b.attr(6, "value", "{self.draft}")
        b.on_input(7, fn(e: InputEvent) { self.draft = e.value })
        b.attr(8, "placeholder", "a note")
        b.close()
        b.open(9, "button")  // editor.bx:44
        b.attr(10, "id", "save")
        b.on_click(11, fn(e: MouseEvent) { self.save() })
        b.text(12, "save")
        b.close()
        b.open(13, "p")  // editor.bx:45
        b.attr(14, "id", "answer")
        b.text(15, "{self.answer}")
        b.close()
        if self.sending {  // editor.bx:46
            if b.fold { b.constant(16, "<p id=\"sending\">sending…</p>") }  // editor.bx:47
            else {
                b.open(16, "p")  // editor.bx:47
                b.attr(17, "id", "sending")
                b.text(18, "sending…")
                b.close()
            }
        }
        b.close()
    }
}
