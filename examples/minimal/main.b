// The smallest latte application: one page, one title, one line to run it.
//
//     beansc run examples/minimal/main.b -- serve 8080
//     beansc run examples/minimal/main.b -- check
//
// This file exists to keep an honest number on the README. `examples/cafe` is
// the one that shows what latte can do — a form, a circuit, a layout, a CSP,
// and 500 lines of its own self-test. This one shows what an application has
// to write, which is the four lines in `main` and nothing else.
package main

import {Builder, Component, page} from latte
import {LatteOptions, run_main} from latte_app

@page(route: r"/")
pub class Home extends Component {
    pub fn init() {}

    pub override fn render(b: Builder) {
        b.open(0, "h1")
        b.text(1, "hello from latte")
        b.close()
    }
}

fn main() {
    var options: LatteOptions = new LatteOptions()
    options.title = "Minimal"
    run_main(options)
}
