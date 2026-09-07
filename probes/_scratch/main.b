package main

import std.io
import std.net
import std.thread
import std.time

fn quiet_client(port: int) -> int {
    match net.TcpStream.connect_timeout("127.0.0.1", port, 4000) {
        ok(stream) => {
            // Never reads. Holds the socket open for 6 seconds.
            time.sleep_millis(6000)
            return 1
        }
        err(e) => { return 0 }
    }
}

fn pump(listener: net.TcpListener) -> int {
    match listener.accept_timeout(4000) {
        ok(stream) => {
            let tuned: Result<bool> = stream.set_timeouts(2000, 2000)
            let chunk: Bytes = Bytes.filled(4096, 65)
            var total: int = 0
            var rounds: int = 0
            for rounds < 100000 {
                rounds += 1
                match stream.write_all(chunk) {
                    ok(n) => { total += n }
                    err(e) => {
                        io.println("blocked after {total} bytes, kind {e.kind}")
                        return total
                    }
                }
            }
            io.println("never blocked after {total} bytes")
            return total
        }
        err(e) => { io.println("accept failed {e.kind}"); return -1 }
    }
}

fn main() {
    match net.TcpListener.bind("127.0.0.1", 0) {
        ok(listener) => {
            let port: int = listener.port().expect("port")
            let visitor: Thread<int> = thread.spawn(fn() -> int {
                return quiet_client(port)
            })
            let t0: int = time.monotonic_millis()
            let total: int = pump(listener)
            io.println("pump took {time.monotonic_millis() - t0} ms")
            let done: int = visitor.join()
        }
        err(e) => { io.println("bind failed: {e.kind}") }
    }
}
