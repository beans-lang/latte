// Scratch: does the circuit state machine actually run? Not a suite yet — no
// golden, leading underscore, not gated. It exists so the handover can say
// "yes, a click round-trips" or "no" with evidence rather than a guess.
package main

import {Builder, Component, MouseEvent, Circuit, CircuitOptions, ErrorBoundary,
        Push} from latte
import {run} from latte.boundary
import std.io
import std.thread

pub class Counter extends Component {
    pub count: int = 0
    pub boom: bool = false
    pub fn init() {}
    pub override fn render(b: Builder) {
        b.open(0, "button")
        b.on_click(1, fn(e: MouseEvent) {
            if self.boom { panic("the handler blew up") }
            self.count += 1
        })
        b.text(2, "Count: {self.count}")
        b.close()
    }
}

pub class Shell extends ErrorBoundary {
    pub inner: Counter = new Counter()
    pub fn init() {
        super.init()
        self.body = fn(b: Builder) {
            b.component_made<Counter>(0, fn() -> Counter { return self.inner },
                                      fn(c: Counter) {})
        }
    }
}

fn main() {
    let options: CircuitOptions = new CircuitOptions()
    options.idle_ms = 1000000
    let shell: Shell = new Shell()
    let circuit: Circuit = new Circuit("0123456789abcdef0123", options,
        fn(url: string) -> Option<Component> { return some(shell) })
    circuit.guard = run

    circuit.open(0)
    circuit.accept(r#"{"t":"attach","c":"0123456789abcdef0123","u":"/"}"#, 1)
    for frame: string in circuit.take_outbox() { io.println("<< {frame}") }
    io.println("html: {circuit.html()}")

    // A click.
    circuit.accept(r#"{"t":"ev","h":2,"k":"click","p":{"b":0,"x":1,"y":2}}"#, 2)
    for frame: string in circuit.take_outbox() { io.println("<< {frame}") }
    io.println("count now {shell.inner.count}")

    // A stale id.
    circuit.accept(r#"{"t":"ev","h":999,"k":"click","p":{}}"#, 3)
    io.println("stale frames {circuit.take_outbox().len()} ending={circuit.ending()}")

    // A cross-thread push.
    let handle: Push = circuit.push_handle()
    let poster: Thread<bool> = thread.spawn(fn() move(handle) -> bool {
        return handle.post(fn(c: Circuit) { c.log.push("pushed") })
    })
    let posted: bool = poster.join()
    let ran: int = circuit.drain(4)
    io.println("push posted={posted} ran={ran} depth={circuit.inbox_depth()}")
    for frame: string in circuit.take_outbox() { io.println("<< {frame}") }

    // A contained panic, into the boundary above it.
    shell.inner.boom = true
    circuit.accept(r#"{"t":"ev","h":2,"k":"click","p":{"b":0,"x":1,"y":2}}"#, 5)
    for frame: string in circuit.take_outbox() { io.println("<< {frame}") }
    io.println("still alive: {!circuit.ending()} boundary={shell.failure} log={circuit.log.len()}")
    io.println("html after: {circuit.html()}")

    // The circuit keeps working after the panic.
    shell.inner.boom = false
    shell.recover()
    circuit.accept(r#"{"t":"ev","h":2,"k":"click","p":{"b":0,"x":1,"y":2}}"#, 6)
    for frame: string in circuit.take_outbox() { io.println("<< {frame}") }
    io.println("count after recover {shell.inner.count} ending={circuit.ending()}")

    // Acks and replay.
    io.println("retained={circuit.retained()} acked={circuit.acked()} batches={circuit.batch_count()}")
    circuit.accept(r#"{"t":"ack","b":1}"#, 7)
    io.println("after ack retained={circuit.retained()} acked={circuit.acked()}")
    circuit.disconnected(8)
    io.println("expired at 9: {circuit.expired(9)} at 100000: {circuit.expired(100000)}")
    circuit.accept(r#"{"t":"resume","c":"0123456789abcdef0123","a":1}"#, 9)
    io.println("replayed {circuit.take_outbox().len()} frames")

    // A limit.
    circuit.accept(r#"{"t":"ev","h":2,"k":"nope"}"#, 10)
    for frame: string in circuit.take_outbox() { io.println("<< {frame}") }
    io.println("ended={circuit.ending()} kind={circuit.end_reason()}")
}
