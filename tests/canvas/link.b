// What a canvas application says to a server, and what it may assume.
//
// The split this file exists to pin down: **the browser owns the interface and
// the server owns the truth.** A control's state, the caret, the selection,
// the scroll offset and anything mid-animation are local and never wait for a
// network. What crosses is a request for data or an action, and an action is
// never a permission — the server decides again, because a browser is the
// user's machine and nothing it sends is evidence of anything.
//
// Nothing here talks to a network. `link.LocalLink` is the whole point: a
// component's behaviour is testable without one, which is only true because
// the boundary is messages rather than calls.
package main

import std.io
import latte.compose
import latte.geometry
import latte.headless
import latte.input
import latte.link
import latte.stage

/// A screen that asks a server for rows and sends an action when one is
/// edited. It holds no connection, no URL and no credential: it holds a
/// `Link`, and what that is behind is the page's business.
pub class Orders extends compose.Component {
    pub rows: List<string> = []
    pub status: string = "nothing asked for yet"
    pub draft: string = ""

    pub fn init() { super.init() }

    /// Asks. It does not wait: the answer arrives at a later frame through
    /// `settle`, and the screen says so in the meantime.
    pub fn refresh() {
        match link.LinkDesk.instance.link().send("orders.list", r#"{"page":1}"#) {
            ok(_) => { self.status = "asked" }
            err(problem) => { self.status = "could not ask: {problem.msg}" }
        }
        self.request_render()
    }

    pub fn save(row: int, text: string) {
        // The payload says what the reader did. It does not say whether they
        // were allowed to — the server has that, and re-checks it.
        let body: string = "\{\"row\": {row}, \"text\": \"{text}\"\}"
        match link.LinkDesk.instance.link().send("orders.save", body) {
            ok(_) => { self.status = "saving row {row}" }
            err(problem) => { self.status = "could not save: {problem.msg}" }
        }
        self.request_render()
    }

    /// Whether there is more to take. A named condition rather than `true`,
    /// so the loop says what ends it.
    fn draining() -> bool { return true }

    /// Takes whatever the server said. Called once a frame by the host.
    pub fn drain_inbox() {
        for self.draining() {
            match link.LinkDesk.instance.link().receive() {
                none => { return }
                some(message) => { self.accept(message) }
            }
        }
    }

    fn accept(message: link.Message) {
        if message.topic == "orders" {
            self.rows = []
            for piece: string in message.payload.split(",") { self.rows.push(piece) }
            self.status = "{self.rows.len()} rows"
            self.request_render()
            return
        }
        if message.topic == "error" {
            self.status = "the server refused: {message.payload}"
            self.request_render()
            return
        }
        self.status = "an unexpected topic: {message.topic}"
        self.request_render()
    }

    pub override fn render(b: compose.Builder) {
        b.open("VStack")
        b.number("padding", 12.0)
        b.number("spacing", 6.0)
        b.open("Label")
        b.text(self.status)
        b.close()
        for row: string in self.rows {
            b.open("Label")
            b.key(row)
            b.text(row)
            b.close()
        }
        b.open("Button")
        b.text("Refresh")
        b.on("click", fn(e: input.UiEvent) { self.refresh() })
        b.close()
        b.close()
    }
}

fn rule(title: string) {
    io.println("")
    io.println("== {title} ==")
}

pub extern "C" fn run() -> i32 as "latte_link_run" {
    let channel: link.LocalLink = new link.LocalLink()
    link.LinkDesk.instance.install(channel)

    let page: stage.Scene = new stage.Scene(new headless.MetricRenderer(),
                                            geometry.Size.of(320.0, 240.0))
    let screen: Orders = new Orders()
    page.show(screen).expect("show")

    rule("1 — a screen with no link gets a named refusal, not silence")

    link.LinkDesk.instance.reset()
    screen.refresh()
    io.println(screen.status)
    link.LinkDesk.instance.install(channel)

    rule("2 — asking is one message, and the screen does not wait")

    screen.refresh()
    io.println("status while waiting: {screen.status}")
    io.println("messages sent: {channel.sent.len()}")
    io.println("the last one: {channel.sent[channel.sent.len() - 1].show()}")
    io.println("rows so far: {screen.rows.len()}")

    rule("3 — the answer arrives later and the screen takes it")

    channel.deliver("orders", "Order 1,Order 2,Order 3")
    screen.drain_inbox()
    page.refresh().expect("draw")
    io.println("status: {screen.status}")
    io.println("rows: {screen.rows.join(" | ")}")

    rule("4 — an action is a request, and a refusal is a message too")

    screen.save(2, "Espresso")
    io.println("the action sent: {channel.sent[channel.sent.len() - 1].show()}")
    channel.deliver("error", "not allowed")
    screen.drain_inbox()
    io.println("status: {screen.status}")

    rule("5 — the interface keeps working with the link closed")

    channel.close()
    io.println("link ready: {channel.ready()}")
    // Scrolling, typing and drawing are local. A closed link changes none of
    // them — which is the property that makes a canvas application usable on a
    // train.
    page.pointer(input.EventKind.pointer_down, geometry.Point.at(40.0, 100.0), 1, 1, 0)
        .expect("press")
    page.pointer(input.EventKind.pointer_up, geometry.Point.at(40.0, 100.0), 1, 1, 0)
        .expect("release")
    io.println("still drawing: {page.refresh().expect("draw") || true}")
    io.println("status after a click with no server: {screen.status}")

    page.close()
    link.LinkDesk.instance.reset()
    return 0
}

fn main() { run() }
