// Generated from pages/hint.bx by latte-bx. Do not edit.
package pages

import {Builder, MouseEvent} from p8_builder.core

partial class Hint {
    pub override fn render(b: Builder) {
        b.open(0, "aside")                      // hint.bx:1
        b.constant(1, "<span class=\"icon\"><svg width=\"12\"></svg></span>")
        b.text(2, "{self.label}")
        b.fragment(3, self.body)                // hint.bx:4  $slot
        b.open(4, "button")                     // hint.bx:5
        b.on_click(5, fn(e: MouseEvent) { self.dismiss(1) })
        b.text(6, "dismiss")
        b.close()
        b.close()
    }
}
