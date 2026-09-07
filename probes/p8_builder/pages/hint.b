// A reusable child component, hand-written by a library author. Its
// parameters are ordinary fields, and its child content is a `fn(Builder)`.
package pages

import {Builder, Callback, Component} from p8_builder.core

pub partial class Hint extends Component {
    pub label: string = ""
    // A `@param` with no default is what `@param(required: true)` means; the
    // Option keeps an unset callback distinguishable from a set one without a
    // Callback that points at nothing.
    pub on_dismiss: Option<Callback<int>> = none
    pub body: fn(Builder) = fn(b: Builder) {}
    pub fn init() {}
    pub fn dismiss(id: int) {
        match self.on_dismiss {
            some(callback) => { callback.call(id) }
            none => {}
        }
    }
}
