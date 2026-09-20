// The channel between a Latte canvas application and a server.
//
// **What is on which side, and why.** The browser owns the interface: the
// state a control is in, where the caret is, what is selected, what is
// scrolled, what is mid-animation. None of that is the server's business and
// none of it waits for a network — a keystroke that needed a round trip would
// be a keystroke you can feel.
//
// The server owns everything that has to be true: who the user is, what they
// may do, what the data actually says, and every secret. A message from here
// is a *request* and never a permission — a browser is the user's machine,
// its code can be edited in the devtools, and nothing it sends is evidence of
// anything. The server authenticates and authorizes each one again.
//
// ## Shape
//
// Two verbs, both one-way. `send(action, payload)` asks the server to do
// something; whatever comes back arrives later as a message with a topic the
// server chose. A WebAssembly call cannot wait for a promise, so there is no
// third verb that returns an answer — and that constraint is the useful part,
// because it makes a blocking round trip inside a click impossible to write.

/// A link over `fetch`. One POST per action, and replies queued for the
/// module to collect at its next frame.
export class FetchLink {
    /// `url` takes a POST of `{action, payload}` and may answer with
    /// `{topic, payload}` or with a list of them.
    constructor(url, options = {}) {
        this.url = url;
        this.queue = [];
        this.inflight = 0;
        this.online = true;
        this.headers = options.headers || {};
        this.onError = options.onError || ((message) => console.error(message));
        // Credentials are the browser's to attach — a cookie or an
        // Authorization header the page already has. Nothing here mints one,
        // and no secret is ever compiled into a module: a WebAssembly module
        // is a file anybody can download and read.
        this.credentials = options.credentials || "same-origin";
    }

    ready() { return this.online; }

    send(action, payload) {
        this.inflight++;
        fetch(this.url, {
            method: "POST",
            credentials: this.credentials,
            headers: { "content-type": "application/json", ...this.headers },
            body: JSON.stringify({ action, payload }),
        })
            .then((response) => {
                if (!response.ok) throw new Error(`${response.status} ${response.statusText}`);
                return response.json();
            })
            .then((answer) => {
                for (const message of Array.isArray(answer) ? answer : [answer]) {
                    if (message && message.topic) this.deliver(message.topic, message.payload);
                }
            })
            .catch((error) => {
                // A failure is a message too. A component that asked for
                // something and heard nothing at all cannot tell a slow
                // network from a broken one.
                this.deliver("error", JSON.stringify({ action, reason: String(error) }));
                this.onError(`${action}: ${error}`);
            })
            .finally(() => { this.inflight--; });
        return true;
    }

    deliver(topic, payload) {
        this.queue.push(`${topic}\n${payload ?? ""}`);
    }

    /// The next message, or "". Taken off the queue as it is read, so a module
    /// that polls once a frame sees each one once.
    take() {
        return this.queue.length ? this.queue.shift() : "";
    }

    close() { this.online = false; this.queue.length = 0; }
}

/// A link over a WebSocket. What a screen that receives pushes wants: the
/// server can speak first.
export class SocketLink {
    constructor(url, options = {}) {
        this.queue = [];
        this.online = false;
        this.pending = [];
        this.onError = options.onError || ((message) => console.error(message));
        this.socket = new WebSocket(url);
        this.socket.addEventListener("open", () => {
            this.online = true;
            // Anything sent while it was connecting goes now, in order.
            for (const frame of this.pending) this.socket.send(frame);
            this.pending.length = 0;
        });
        this.socket.addEventListener("message", (event) => {
            try {
                const message = JSON.parse(event.data);
                if (message && message.topic) {
                    this.queue.push(`${message.topic}\n${message.payload ?? ""}`);
                }
            } catch (error) {
                this.onError(`a message that is not JSON: ${error}`);
            }
        });
        this.socket.addEventListener("close", () => {
            this.online = false;
            this.queue.push("error\n{\"reason\":\"the connection closed\"}");
        });
        this.socket.addEventListener("error", () => {
            this.queue.push("error\n{\"reason\":\"the connection failed\"}");
        });
    }

    ready() { return this.online; }

    send(action, payload) {
        const frame = JSON.stringify({ action, payload });
        if (this.online) this.socket.send(frame); else this.pending.push(frame);
        return true;
    }

    take() { return this.queue.length ? this.queue.shift() : ""; }

    close() { this.online = false; this.socket.close(); }
}

/// The three imports a module's link half needs, bound to one runtime.
export function linkImports(runtime, link) {
    return {
        latte_js_link_send(actionPtr, actionLen, payloadPtr, payloadLen) {
            if (!link) return -1;
            const action = runtime.text(actionPtr, actionLen);
            const payload = runtime.text(payloadPtr, payloadLen);
            return link.send(action, payload) ? 0 : -1;
        },
        latte_js_link_ready() {
            return link && link.ready() ? 1 : 0;
        },
        latte_js_link_receive(out, cap) {
            if (!link) return 0;
            // The two-call shape, and the queue is only popped on the second.
            // Popping on the first would lose a message whose buffer the
            // module then failed to allocate.
            const next = link.queue.length ? link.queue[0] : "";
            if (!next) return 0;
            const bytes = new TextEncoder().encode(next);
            if (!out || cap <= 0) return bytes.length;
            if (cap < bytes.length) return bytes.length;
            new Uint8Array(runtime.memory.buffer, out, bytes.length).set(bytes);
            link.take();
            return bytes.length;
        },
    };
}
