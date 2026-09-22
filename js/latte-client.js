// The page half of a `client` execution boundary.
//
// It owns the WebAssembly module and nothing else. Every DOM decision —
// building nodes, applying edits, reading a handler off the node under the
// pointer — belongs to `latte.Applier` and `latte.Region` in `latte.js`, the
// same code a server circuit drives. That split is deliberate and it is the
// difference between this and a second framework: there is one applier in
// this repository, one event walk and one payload serializer, and a client
// region reaches them through the same public surface a circuit does.
//
// What this file adds is four calls and a watcher:
//
//   mount    a boundary element the server rendered -> a region in the module
//   props    the server changed a prop -> the same instance, new parameters
//   event    a DOM event inside the region -> the module, and edits back
//   unmount  the boundary left the page -> the region goes with it
//
// The watcher is a MutationObserver, because a boundary can arrive after the
// first paint: a server region that re-renders may insert one, and enhanced
// navigation replaces the whole root.

import { LatteRuntime } from "./latte-runtime.js";

const BOUNDARY = "latte-boundary";
const ACTION_PREFIX = "/_latte/action/";
const ACTION_HEADER = "X-Latte-Action";
/// What tells the SERVER that this browser can run a bundle.
///
/// A cookie, because the server decides `auto` before a script has run: it
/// is what renders the first byte. So the question the server can actually
/// ask is "did this browser manage it last time", and this is the answer.
/// It is written when a bundle boots and cleared when one fails, so a
/// browser that cannot run WebAssembly, or a bundle that 404s, falls back to
/// server interactivity on the next load rather than staying broken.
const BUNDLE_COOKIE = "latte_bundle";
const ATTR_ID = "data-latte-boundary";
const ATTR_MODE = "data-latte-mode";
const ATTR_TYPE = "data-latte-component";
const ATTR_PROPS = "data-latte-props";

/// Remember, or forget, that this browser has a working bundle.
///
/// `SameSite=Lax` and no `Secure`: it is read on a top-level navigation and
/// it carries nothing worth protecting — a browser that lies about it gets
/// client mode and downloads the bundle, which is what it said it wanted.
function rememberBundle(doc, ready) {
    try {
        const age = ready ? 60 * 60 * 24 * 30 : 0;
        doc.cookie = `${BUNDLE_COOKIE}=${ready ? "1" : ""}; Path=/; Max-Age=${age}; SameSite=Lax`;
    } catch (problem) {
        // A document with no cookie access — a sandboxed frame, a file: page
        // — simply never reports readiness, and `auto` stays on the server.
    }
}

/// One loaded browser bundle, and every region it is running.
export class LatteClient {
    constructor(options) {
        this.runtime = options.runtime;
        this.document = options.document;
        this.root = options.root || options.document;
        this.dom = options.dom;                 // the `latte` global from latte.js
        this.onError = options.onError || ((text) => console.error(text));
        this.regions = new Map();               // boundary id -> { handle, element, region }
        this.observer = null;
        this.ready = false;
        // The antiforgery token the document carries, and the calls in
        // flight. A call is abandoned by its AbortController; the module has
        // already forgotten its callback by then.
        this.token = options.token || "";
        this.prefix = options.prefix || ACTION_PREFIX;
        this.calls = new Map();
        this.fetch = options.fetch ||
            ((url, init) => globalThis.fetch(url, init));
    }

    // ---- server actions ---------------------------------------------------

    /// The imports the module needs for a server action. Merged into `env`
    /// beside the runtime's own; `tools/wasm_abi.sh` pairs them with
    /// `client/actions.b`.
    actionImports() {
        const self = this;
        return {
            latte_js_action(call, namePtr, nameLen, bodyPtr, bodyLen) {
                const name = self.runtime.text(namePtr, nameLen);
                const body = self.runtime.text(bodyPtr, bodyLen);
                return self.startCall(call, name, body);
            },
            latte_js_action_cancel(call) {
                const held = self.calls.get(call);
                if (!held) { return 0; }
                self.calls.delete(call);
                if (held.abort) { held.abort.abort(); }
                return 1;
            },
        };
    }

    /// Send one action. The module is told the answer through
    /// `latte_client_action_result`, never through a return value: a fetch
    /// is not synchronous and pretending otherwise is how a runtime deadlocks
    /// itself.
    startCall(call, name, body) {
        if (!/^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/.test(name)) {
            this.onError(`"${name}" is not an action name`);
            return -1;
        }
        const abort = typeof AbortController === "function"
            ? new AbortController() : null;
        this.calls.set(call, { abort: abort });
        const headers = { "content-type": "application/json" };
        if (this.token) { headers[ACTION_HEADER] = this.token; }
        const self = this;
        this.fetch(this.prefix + name, {
            method: "POST",
            headers: headers,
            body: body,
            credentials: "same-origin",
            signal: abort ? abort.signal : undefined,
        }).then(function (response) {
            return response.text().then(function (text) {
                return { ok: true, text: text };
            });
        }).catch(function (problem) {
            // A transport failure, which is NOT the same as an action that
            // ran and said no. It is handed over with its own kind so a
            // caller can tell them apart, and nothing here retries.
            return { ok: false, text: JSON.stringify({
                ok: false, k: "offline", v: null,
                e: "the call did not reach the server: " + String(problem),
            }) };
        }).then(function (answer) {
            // A call the module cancelled is one it has already forgotten;
            // handing it an answer would resurrect a callback that is gone.
            if (!self.calls.has(call)) { return; }
            self.calls.delete(call);
            self.finishCall(call, answer.text);
        });
        return call;
    }

    finishCall(call, text) {
        const region = this.withText(text, (pointer, length) =>
            this.exports.latte_client_action_result(call, 1, pointer, length));
        if (region <= 0) { return; }
        for (const held of this.regions.values()) {
            if (held.handle !== region) { continue; }
            held.region.pump(this.takeBatch(region));
            return;
        }
    }

    // ---- the module -------------------------------------------------------

    get exports() { return this.runtime.exports; }

    /// The module's last failure. Every export answers an integer, so this is
    /// how a -1 gets a reason.
    lastError() {
        const take = this.exports.latte_scratch_take;
        const needed = this.exports.latte_client_last_error(0, 0);
        if (needed <= 0) { return ""; }
        const scratch = take(needed);
        try {
            this.exports.latte_client_last_error(scratch, needed);
            return this.runtime.text(scratch, needed);
        } finally {
            this.exports.latte_scratch_drop(scratch);
        }
    }

    /// Writes a string into the module's scratch buffer and hands the body
    /// its (pointer, length). The buffer is given back on every path.
    withText(text, body) {
        const bytes = new TextEncoder().encode(text);
        if (bytes.length === 0) { return body(0, 0); }
        const pointer = this.exports.latte_scratch_take(bytes.length);
        try {
            new Uint8Array(this.runtime.memory.buffer, pointer, bytes.length).set(bytes);
            return body(pointer, bytes.length);
        } finally {
            this.exports.latte_scratch_drop(pointer);
        }
    }

    /// The batch a region owes, as text, read with the two-call shape. The
    /// module drops it only once the bytes are really written.
    takeBatch(handle) {
        const needed = this.exports.latte_client_take(handle, 0, 0);
        if (needed <= 0) { return ""; }
        const scratch = this.exports.latte_scratch_take(needed);
        try {
            const wrote = this.exports.latte_client_take(handle, scratch, needed);
            if (wrote !== needed) { return ""; }
            return this.runtime.text(scratch, needed);
        } finally {
            this.exports.latte_scratch_drop(scratch);
        }
    }

    /// Every component type this bundle can build. The inspector reads it,
    /// and so does the check that a client component really shipped.
    catalogue() {
        const needed = this.exports.latte_client_catalogue(0, 0);
        if (needed <= 0) { return []; }
        const scratch = this.exports.latte_scratch_take(needed);
        try {
            this.exports.latte_client_catalogue(scratch, needed);
            return this.runtime.text(scratch, needed).split("\n").filter(Boolean);
        } finally {
            this.exports.latte_scratch_drop(scratch);
        }
    }

    // ---- regions ----------------------------------------------------------

    /// Adopt every client boundary in the tree, and keep watching for more.
    start() {
        if (this.exports.latte_client_boot() < 0) {
            this.onError(this.lastError() || "the browser bundle would not boot");
            return this;
        }
        this.ready = true;
        this.sweep();
        this.watch();
        return this;
    }

    /// Mount what is there and drop what is gone. Idempotent by boundary id,
    /// so a sweep triggered by an unrelated mutation costs a walk and no
    /// remount.
    sweep() {
        if (!this.ready) { return; }
        const seen = new Set();
        const found = this.root.querySelectorAll
            ? this.root.querySelectorAll(BOUNDARY)
            : [];
        for (const element of found) {
            const mode = element.getAttribute(ATTR_MODE);
            if (mode !== "client") { continue; }
            const id = element.getAttribute(ATTR_ID) || "";
            if (!id) {
                this.onError(`a ${BOUNDARY} carries no ${ATTR_ID}`);
                continue;
            }
            seen.add(id);
            const held = this.regions.get(id);
            if (held) {
                // The element is the same one: only the props can have moved.
                if (held.element === element) { this.refresh(held); continue; }
                // A different element under the same id is a remount — the
                // server replaced the region rather than updating it.
                this.drop(id);
            }
            this.mount(element, id);
        }
        for (const id of Array.from(this.regions.keys())) {
            if (!seen.has(id)) { this.drop(id); }
        }
    }

    mount(element, id) {
        const type = element.getAttribute(ATTR_TYPE) || "";
        const props = element.getAttribute(ATTR_PROPS) || "";
        const handle = this.withText(id, (idPtr, idLen) =>
            this.withText(type, (typePtr, typeLen) =>
                this.withText(props, (propsPtr, propsLen) =>
                    this.exports.latte_client_mount(idPtr, idLen, typePtr, typeLen,
                                                    propsPtr, propsLen))));
        if (handle < 0) {
            this.onError(this.lastError() || `could not mount ${type}`);
            element.setAttribute("data-latte-error", "1");
            return;
        }
        const self = this;
        const region = this.dom.region({
            document: this.document,
            host: element,
            // Everything the region sends goes through here and comes back as
            // the edits the module produced, or "".
            send: function (message) {
                const text = JSON.stringify(message);
                const answer = self.withText(text, (pointer, length) =>
                    self.exports.latte_client_event(handle, pointer, length));
                if (answer < 0) {
                    self.onError(self.lastError() || "the region refused an event");
                    return "";
                }
                return self.takeBatch(handle);
            },
        });
        const held = { handle: handle, element: element, region: region,
                       props: props };
        this.regions.set(id, held);
        region.attach(this.takeBatch(handle));
    }

    /// The server changed a prop on a live region.
    refresh(held) {
        const props = held.element.getAttribute(ATTR_PROPS) || "";
        if (props === held.props) { return; }
        held.props = props;
        const answer = this.withText(props, (pointer, length) =>
            this.exports.latte_client_props(held.handle, pointer, length));
        if (answer < 0) {
            this.onError(this.lastError() || "the region refused its new props");
            return;
        }
        held.region.pump(this.takeBatch(held.handle));
    }

    drop(id) {
        const held = this.regions.get(id);
        if (!held) { return; }
        this.regions.delete(id);
        held.region.stop();
        this.exports.latte_client_unmount(held.handle);
    }

    watch() {
        if (typeof MutationObserver !== "function") { return; }
        const self = this;
        this.observer = new MutationObserver(() => self.sweep());
        this.observer.observe(this.document.body || this.document, {
            childList: true,
            subtree: true,
            attributes: true,
            attributeFilter: [ATTR_PROPS, ATTR_MODE],
        });
    }

    /// What every execution boundary on this page resolved to.
    ///
    /// The development inspector, and the answer to the question a page with
    /// a half-working bundle raises: which regions are alive, which runtime
    /// owns each one, and what the ones that are not alive said. It reads
    /// the DOM rather than this object's own map, so a boundary the runtime
    /// never reached is still in the list — which is the case worth seeing.
    inspect() {
        const rows = [];
        const found = this.document.querySelectorAll
            ? this.document.querySelectorAll(BOUNDARY) : [];
        for (const element of found) {
            const id = element.getAttribute(ATTR_ID) || "";
            const mode = element.getAttribute(ATTR_MODE) || "";
            const held = this.regions.get(id);
            rows.push({
                boundary: id,
                component: element.getAttribute(ATTR_TYPE) || "",
                mode: mode,
                owner: mode === "client" ? "browser" : "server",
                prerendered: element.hasAttribute("data-latte-prerendered"),
                ready: !!held,
                props: element.getAttribute(ATTR_PROPS) || "",
                error: element.getAttribute("data-latte-error") ? this.lastError() : "",
            });
        }
        return rows;
    }

    /// The same list as one block of text, for a console or a log.
    report() {
        const rows = this.inspect();
        if (rows.length === 0) { return "no execution boundary on this page"; }
        return rows.map((r) =>
            `${r.boundary}  ${r.mode.padEnd(6)} owner=${r.owner}` +
            ` ready=${r.ready} prerendered=${r.prerendered}` +
            `  ${r.component}${r.error ? "  ERROR " + r.error : ""}`).join("\n");
    }

    stop() {
        if (this.observer) { this.observer.disconnect(); this.observer = null; }
        for (const id of Array.from(this.regions.keys())) { this.drop(id); }
    }

    /// Load a bundle and adopt the page's client boundaries.
    static async start(options) {
        // The client object exists before the module does, because the
        // action imports close over it and the runtime needs them at
        // instantiation.
        const client = new LatteClient({
            runtime: null,
            document: options.document || document,
            root: options.root || null,
            dom: options.dom || globalThis.latte,
            onError: options.onError,
            token: options.token,
            fetch: options.fetch,
        });
        client.runtime = await LatteRuntime.load(options.module, {
            stdout: options.stdout || ((line) => console.log(line)),
            stderr: options.stderr || ((line) => console.error(line)),
            imports: () => client.actionImports(),
        });
        if (!client.dom || typeof client.dom.region !== "function") {
            throw new Error("latte.js is not loaded, or is older than this file: a client region needs latte.region()");
        }
        const started = client.start();
        // Only once the module has booted: a bundle that instantiates and
        // then refuses to boot is a bundle this browser cannot use.
        rememberBundle(client.document, started.ready);
        return started;
    }
}

// Auto-start from the script tag that loaded this file, the way latte.js
// boots a circuit. A page with no `data-latte-wasm` loads nothing.
if (typeof document !== "undefined" && typeof window !== "undefined") {
    const tag = document.currentScript ||
        document.querySelector("script[data-latte-wasm]");
    const url = tag && tag.dataset ? tag.dataset.latteWasm : null;
    // The antiforgery token rides on the boot script, which is the tag
    // `latte.js` reads too. A page with no server action carries none.
    const boot = document.querySelector("script[data-latte-action]");
    const token = boot && boot.dataset ? boot.dataset.latteAction : "";
    if (url) {
        const begin = () => {
            LatteClient.start({ module: url, document: document, token: token })
                .then((client) => { window.latteClient = client; })
                .catch((problem) => {
                    // The bundle did not load, or would not instantiate. The
                    // prerendered HTML stays on screen — it is a real page,
                    // just not an interactive one — and the cookie is
                    // cleared so the next load is decided the other way.
                    rememberBundle(document, false);
                    console.error(String(problem));
                });
        };
        if (document.readyState === "loading") {
            document.addEventListener("DOMContentLoaded", begin);
        } else {
            begin();
        }
    }
}
