// A reusable child component, hand-written by a library author. Its
// parameters are ordinary fields, and its child content is a `fn(Builder)`.
package pages

import {Builder, Callback, Component} from p8_builder.core

pub partial class Hint extends Component {
    pub label: string = ""
    pub on_dismiss: Callback<int> = new Callback<int>()
    pub body: fn(Builder) = fn(b: Builder) {}
    pub fn init() {}
}
