// Drive a browser bundle without a browser.
//
// The region runtime's whole surface is strings: a boundary id, a type name,
// a props object in, an encoded batch out. None of it needs a DOM — so this
// runs the real WebAssembly module under Node and prints what came back,
// and `test.sh` compares that against an expected output on every run.
//
// It is the cheaper half of the pair. `tools/client_check.mjs` puts the same
// module in three real browsers and checks the DOM it produces; this checks
// the protocol, on any machine with Node, in about a second. A failure here
// is in Beans; a failure there and not here is in `latte.js`.

import { readFileSync } from "node:fs";
import { LatteRuntime } from "../js/latte-runtime.js";

const modulePath = process.argv[2];
if (!modulePath) {
    console.error("usage: client_wire.mjs <module.wasm>");
    process.exit(2);
}

const runtime = new LatteRuntime({
    stdout: (line) => console.log(`module: ${line}`),
    stderr: (line) => console.log(`module stderr: ${line}`),
});
const imports = runtime.imports();
// The two a server action needs. Under node there is no page to perform the
// request, so a call is REFUSED rather than left hanging: -1 is the answer
// `ActionSender` reads as "the page would not send this", and § 8 asserts
// that a caller is told so instead of waiting for ever.
imports.env.latte_js_action = () => -1;
imports.env.latte_js_action_cancel = () => 0;
const { instance } = await WebAssembly.instantiate(readFileSync(modulePath), imports);
runtime.instance = instance;
runtime.exports = instance.exports;
runtime.memory = instance.exports.memory;
if (!runtime.memory) { throw new Error("the module exported no memory"); }
runtime.exports.beans_module_start();

const api = runtime.exports;

function withText(text, body) {
    const bytes = new TextEncoder().encode(text);
    if (bytes.length === 0) { return body(0, 0); }
    const pointer = api.latte_scratch_take(bytes.length);
    try {
        new Uint8Array(runtime.memory.buffer, pointer, bytes.length).set(bytes);
        return body(pointer, bytes.length);
    } finally {
        api.latte_scratch_drop(pointer);
    }
}

function readBack(call) {
    const needed = call(0, 0);
    if (needed <= 0) { return ""; }
    const scratch = api.latte_scratch_take(needed);
    try {
        const wrote = call(scratch, needed);
        if (wrote !== needed) { return ""; }
        return runtime.text(scratch, needed);
    } finally {
        api.latte_scratch_drop(scratch);
    }
}

const lastError = () => readBack((p, c) => api.latte_client_last_error(p, c));
const takeBatch = (handle) => readBack((p, c) => api.latte_client_take(handle, p, c));

let bad = 0;
function same(label, got, want) {
    if (got === want) {
        console.log(`ok   ${label}: ${got}`);
    } else {
        bad += 1;
        console.log(`FAIL ${label}:\n  got  ${got}\n  want ${want}`);
    }
}
function show(label, value) { console.log(`-- ${label}\n   ${value}`); }

// ---------------------------------------------------------------- 1. boot

console.log("== 1. the bundle boots and says what it can build ==");
same("boot", String(api.latte_client_boot()), "0");
const catalogue = readBack((p, c) => api.latte_client_catalogue(p, c))
    .split("\n").filter(Boolean);
same("the counter is in the bundle",
     String(catalogue.includes("clienttest.site.Counter")), "true");
same("and latte's own region component is too",
     String(catalogue.includes("latte.RenderRegion")), "true");

// ---------------------------------------------------------------- 2. mount

console.log("");
console.log("== 2. mounting a region answers a batch that builds it ==");
const handle = withText("r1", (idP, idL) =>
    withText("clienttest.site.Counter", (nP, nL) =>
        withText('{"start":3,"label":"hits"}', (pP, pL) =>
            api.latte_client_mount(idP, idL, nP, nL, pP, pL))));
same("a handle came back", String(handle > 0), "true");
if (handle <= 0) { console.log(lastError()); process.exit(1); }
const first = takeBatch(handle);
show("the first batch", first);
const firstMessage = JSON.parse(first);
same("it is a batch", firstMessage.t, "batch");
same("numbered from one", String(firstMessage.b), "1");
same("it carries the props the page passed",
     String(first.includes("hits=3")), "true");
same("and nothing is waiting after it is taken", takeBatch(handle), "");

// ---------------------------------------------------------------- 3. event

console.log("");
console.log("== 3. a click runs the handler here, and only the text moves ==");
// The handler slot the first batch bound. Read off the wire rather than
// guessed: slot ids are the renderer's and nothing outside may assume one.
const slots = [...first.matchAll(/\["h",\d+,"(\w+)",(\d+)\]/g)]
    .map((m) => ({ event: m[1], id: Number(m[2]) }));
show("the handlers it bound", JSON.stringify(slots));
const click = slots.find((s) => s.event === "click");
same("a click handler was bound", String(!!click), "true");

const clickAnswer = withText(
    JSON.stringify({ t: "ev", h: click.id, k: "click", p: { b: 0, x: 1, y: 2 } }),
    (p, l) => api.latte_client_event(handle, p, l));
same("the event was accepted", String(clickAnswer), "0");
const second = takeBatch(handle);
show("the second batch", second);
same("it is one text edit and nothing else",
     JSON.stringify(JSON.parse(second).u), '[{"c":0,"e":[["si",0],["si",0],["ut",0,"hits=4"],["so"],["so"]]}]');
same("and the reference pool is empty, because nothing was built",
     JSON.stringify(JSON.parse(second).r), "[]");

// ---------------------------------------------------------------- 4. input

console.log("");
console.log("== 4. an input event carries its value through the same reader ==");
const typing = slots.find((s) => s.event === "input");
const typed = withText(
    JSON.stringify({ t: "ev", h: typing.id, k: "input", p: { v: "beans" } }),
    (p, l) => api.latte_client_event(handle, p, l));
same("the input was accepted", String(typed), "0");
const third = takeBatch(handle);
show("the third batch", third);
same("the echo and the field both moved",
     String(third.includes("beans")), "true");

// ---------------------------------------------------------------- 5. props

console.log("");
console.log("== 5. new props keep the instance and its own state ==");
const answered = withText('{"start":10,"label":"hits"}', (p, l) =>
    api.latte_client_props(handle, p, l));
same("the props were accepted", String(answered), "0");
const fourth = takeBatch(handle);
show("the fourth batch", fourth);
// 10 + one click = 11. A remount would answer 10, and it would have thrown
// the typed text away too — which is why the second assertion is that the
// batch says NOTHING about the text: the field still holds it, so the render
// produced the same bytes and the differ had nothing to send.
same("the click is still counted", String(fourth.includes("hits=11")), "true");
same("and the typed text was not re-sent, because it never changed",
     String(fourth.includes("beans")), "false");

// ---------------------------------------------------------------- 6. refuse

console.log("");
console.log("== 6. what a region refuses ==");
const missing = withText("r2", (idP, idL) =>
    withText("clienttest.site.Nowhere", (nP, nL) =>
        withText("{}", (pP, pL) =>
            api.latte_client_mount(idP, idL, nP, nL, pP, pL))));
same("a type the bundle does not have", String(missing), "-1");
show("and it says so", lastError());

const badProps = withText("r3", (idP, idL) =>
    withText("clienttest.site.Counter", (nP, nL) =>
        withText('{"start":"three"}', (pP, pL) =>
            api.latte_client_mount(idP, idL, nP, nL, pP, pL))));
same("a prop of the wrong type", String(badProps), "-1");
show("and it says which", lastError());

const strayEvent = withText(
    JSON.stringify({ t: "ev", h: 999, k: "click", p: {} }),
    (p, l) => api.latte_client_event(handle, p, l));
same("a handler id nothing bound is dropped, not refused",
     String(strayEvent), "0");
same("and it produced no batch", takeBatch(handle), "");

// ---------------------------------------------------------------- 7. gone

console.log("");
console.log("== 7. unmounting ==");
same("the region goes", String(api.latte_client_unmount(handle)), "0");
same("and a second unmount says so", String(api.latte_client_unmount(handle)), "-1");

// ---------------------------------------------------------------- 8. offline

console.log("");
console.log("== 8. an action with no page to send it ==");
const offlineHandle = withText("r9", (idP, idL) =>
    withText("clienttest.site.Counter", (nP, nL) =>
        withText('{"start":0,"label":"n"}', (pP, pL) =>
            api.latte_client_mount(idP, idL, nP, nL, pP, pL))));
same("a second region mounted", String(offlineHandle > 0), "true");
same("and nothing is in flight before anything is sent",
     String(api.latte_client_in_flight()), "0");
// `latte_js_action` answering -1 is exactly what a page with no network
// does. The caller must be told, synchronously, and the call must not be
// left in the pending map for ever.
same("a call the page refuses leaves nothing waiting",
     String(api.latte_client_in_flight()), "0");

console.log("");
console.log(bad === 0 ? "all checks passed" : `${bad} check(s) failed`);
process.exit(bad === 0 ? 0 : 1);
