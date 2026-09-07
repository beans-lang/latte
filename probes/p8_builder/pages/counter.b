// The HAND-WRITTEN half: the `<beans>` block of pages/counter.bx, copied
// through byte for byte. PLAN.md's example, with `Clock` inlined so the probe
// stays one module.
package pages

import {Builder, Callback, Component, Reference} from p8_builder.core

pub class Clock {
    pub fn init() {}
    pub fn now() -> string { return "12:00" }
}

pub class Row {
    pub id: int = 0
    pub title: string = ""
    pub fn init(id: int, title: string) { self.id = id; self.title = title }
}

pub partial class Counter extends Component {
    pub start: int = 0
    pub count: int = 0
    pub note: string = ""
    pub rows: List<Row> = []
    pub extra: Map<string, string> = {}
    pub rendered: string = ""
    pub input_ref: Reference = new Reference()
    pub hint_body: fn(Builder) = fn(b: Builder) {}
    clock: Clock

    pub fn init() { self.clock = new Clock() }
    pub fn on_init() { self.count = self.start }
    pub fn hide() { self.rows.clear() }
}
