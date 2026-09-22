// The whole feature, in a real browser, against the real application.
//
// `tools/client_check.mjs` drives one boundary on a static page — no server,
// no circuit, no action. This one starts `examples/modes` and asks the
// questions only a running application can answer:
//
//   * a SERVER counter goes up over the circuit, and a CLIENT one goes up
//     with no request at all — on one page, at the same time;
//   * a typed server action makes exactly one POST, and the reply reaches
//     the component that asked;
//   * that action is refused without a valid antiforgery token, and refused
//     again for a role the caller does not have;
//   * the browser bundle does not contain the server's code;
//   * the page adopts what the server rendered instead of replacing it, so
//     text typed before the script attached is still there;
//   * `auto` is server on the first visit and client on the second.
//
// It is the slowest check in the repository and the only one that can see
// any of that.
import { spawn } from "node:child_process";
import { createServer } from "node:http";
import { existsSync } from "node:fs";
import { resolve } from "node:path";
import { chromium, firefox, webkit } from "playwright";

const ENGINES = { chromium, firefox, webkit };
const wanted = (process.env.LATTE_ENGINES || "chromium").split(",");
const root = resolve(process.env.LATTE_ROOT || ".");
const beansc = process.env.BEANSC ||
    resolve(root, "../../beans/build/beansc");

function check(results, name, got, want) {
    results.push({ name, got: String(got), want: String(want),
                   ok: String(got) === String(want) });
}

/// A port nothing is listening on. Asked of the OS rather than guessed: two
/// checks at once collided once, and a check that fails that way cannot be
/// trusted.
async function freePort() {
    const probe = createServer();
    await new Promise((done) => probe.listen(0, "127.0.0.1", done));
    const port = probe.address().port;
    await new Promise((done) => probe.close(done));
    return port;
}

async function startServer(port) {
    const child = spawn(beansc,
        ["run", "examples/modes/main.b", "--", "serve", String(port)],
        { cwd: root, stdio: ["ignore", "pipe", "pipe"] });
    let noise = "";
    child.stdout.on("data", (b) => { noise += b.toString(); });
    child.stderr.on("data", (b) => { noise += b.toString(); });

    const until = Date.now() + 90000;
    while (Date.now() < until) {
        if (child.exitCode !== null) {
            throw new Error(`the server exited with ${child.exitCode}: ${noise}`);
        }
        try {
            const answer = await fetch(`http://127.0.0.1:${port}/`);
            if (answer.ok) { return { child, noise: () => noise }; }
        } catch (problem) { /* not up yet */ }
        await new Promise((done) => setTimeout(done, 250));
    }
    child.kill();
    throw new Error(`the server never answered on ${port}: ${noise}`);
}

async function run(engineName, engine, port) {
    const browser = await engine.launch();
    const context = await browser.newContext();
    const page = await context.newPage();
    const problems = [];
    let posts = [];
    page.on("pageerror", (error) => problems.push(String(error)));
    page.on("console", (m) => { if (m.type() === "error") problems.push(m.text()); });
    page.on("request", (r) => { if (r.method() === "POST") { posts.push(r.url()); } });

    const results = [];
    const home = `http://127.0.0.1:${port}/`;

    // -- 1. the first visit: auto is on the server ------------------------
    await page.goto(home, { waitUntil: "load" });
    await page.waitForFunction(() => !!window.latteClient &&
        window.latteClient.regions.size >= 3, undefined, { timeout: 30000 });

    check(results, "the client counter mounted",
          await page.textContent("#page > latte-boundary output"), "client = 10");
    check(results, "and auto did not, on a first visit",
          await page.evaluate(() =>
              [...document.querySelectorAll("latte-boundary")]
                  .map((e) => e.getAttribute("data-latte-component"))
                  .filter((n) => n && n.endsWith("Counter")).length), 1);

    // -- 2. the two counters, side by side --------------------------------
    const counters = await page.evaluate(() =>
        [...document.querySelectorAll("section.counter output")].map((e) => e.textContent));
    check(results, "both counters rendered", counters.join(" | "),
          "server = 1 | client = 10 | auto = 100");

    posts = [];
    const requests = [];
    page.on("request", (r) => requests.push(r.url()));
    // The client one first: nothing may leave the page.
    await page.click("#page > latte-boundary button");
    await page.waitForFunction(() =>
        document.querySelector("#page > latte-boundary output").textContent === "client = 11",
        undefined, { timeout: 5000 });
    check(results, "a client click needs no request", requests.length, 0);

    // And the server one, which must reach the circuit and come back.
    const serverButton = await page.evaluateHandle(() =>
        [...document.querySelectorAll("section.counter")]
            .find((s) => s.querySelector("output").textContent.startsWith("server"))
            .querySelector("button"));
    await serverButton.asElement().click();
    await page.waitForFunction(() =>
        [...document.querySelectorAll("section.counter output")]
            .some((e) => e.textContent === "server = 2"),
        undefined, { timeout: 10000 });
    check(results, "a server click goes round the circuit",
          await page.evaluate(() =>
              [...document.querySelectorAll("section.counter output")]
                  .map((e) => e.textContent).join(" | ")),
          "server = 2 | client = 11 | auto = 100");

    // -- 3. the client block ----------------------------------------------
    await page.click("#block-add");
    await page.waitForFunction(() =>
        document.querySelector("#block").textContent === " has 4 rows",
        undefined, { timeout: 5000 });
    check(results, "a RenderBlock body is its own component",
          await page.textContent("#block"), " has 4 rows");

    // -- 4. the server action ---------------------------------------------
    posts = [];
    await page.fill("#draft", "a note from the browser");
    await page.click("#save");
    await page.waitForFunction(() =>
        document.querySelector("#answer").textContent !== "",
        undefined, { timeout: 10000 });
    check(results, "the action answered", await page.textContent("#answer"),
          "saved as note 1");
    check(results, "with exactly one POST", posts.length, 1);
    check(results, "to the action's own path",
          posts[0].endsWith("/_latte/action/notes.save"), "true");

    // A second save counts up on the server, which is where the store is.
    await page.fill("#draft", "and another");
    await page.click("#save");
    await page.waitForFunction(() =>
        document.querySelector("#answer").textContent === "saved as note 2",
        undefined, { timeout: 10000 });
    check(results, "and the server kept the count",
          await page.textContent("#answer"), "saved as note 2");

    // An empty note is the action's own refusal, which is an answer and not
    // an error: it ran, and it said no.
    await page.fill("#draft", "");
    await page.click("#save");
    await page.waitForFunction(() =>
        document.querySelector("#answer").textContent.startsWith("failed"),
        undefined, { timeout: 10000 });
    check(results, "an action that says no says why",
          await page.textContent("#answer"), "failed: a note needs a body");

    // -- 5. what the server will not accept -------------------------------
    //
    // Both calls below are MEANT to be refused, and a browser logs a refused
    // fetch to the console. So the page's error list is closed here: what it
    // holds now is everything that went wrong while the page was working.
    const beforeRefusals = problems.slice();
    const forbidden = await page.evaluate(async () => {
        const answer = await fetch("/_latte/action/notes.purge", {
            method: "POST", credentials: "same-origin",
            headers: { "content-type": "application/json",
                       "X-Latte-Action": document
                           .querySelector("script[data-latte-action]")
                           .dataset.latteAction },
            body: "{}",
        });
        return `${answer.status} ${(await answer.json()).k}`;
    });
    check(results, "a role the caller does not have", forbidden, "403 forbidden");

    const untokened = await page.evaluate(async () => {
        const answer = await fetch("/_latte/action/notes.save", {
            method: "POST", credentials: "same-origin",
            headers: { "content-type": "application/json" },
            body: JSON.stringify({ body: "x" }),
        });
        return `${answer.status} ${(await answer.json()).k}`;
    });
    check(results, "and a call with no antiforgery token", untokened, "403 stale");

    // -- 6. the bundle holds no server code -------------------------------
    const catalogue = await page.evaluate(() => window.latteClient.catalogue());
    check(results, "the browser bundle can build the components",
          catalogue.filter((n) => n.startsWith("modes.site.")).length >= 3, "true");
    check(results, "and holds nothing from the server package",
          catalogue.filter((n) => n.startsWith("modes.server.")).join(","), "");

    // -- 6a. a dead circuit does not take the client regions with it -------
    //
    // The two runtimes are independent by construction — separate appliers,
    // separate event walks, separate state — and this is the assertion that
    // says so out loud. The socket is closed from the page and the client
    // counter must keep counting.
    await page.evaluate(() => { window.latte.current.socket.close(); });
    await page.waitForFunction(() => !window.latte.current.connected,
                               undefined, { timeout: 10000 });
    const before = await page.textContent("#page > latte-boundary output");
    await page.click("#page > latte-boundary button");
    await page.waitForFunction((was) =>
        document.querySelector("#page > latte-boundary output").textContent !== was,
        before, { timeout: 5000 });
    check(results, "a client region keeps working with the circuit down",
          await page.textContent("#page > latte-boundary output"), "client = 12");

    // -- 6b. the inspector -------------------------------------------------
    //
    // It reads the DOM, so it lists a boundary the runtime never reached as
    // well as the ones it did — which is the case a person debugging a
    // half-working bundle is actually looking at.
    const inspected = await page.evaluate(() => window.latteClient.inspect());
    check(results, "the inspector lists every boundary", inspected.length, 3);
    check(results, "with its mode, its owner and whether it is alive",
          inspected.map((r) => `${r.mode}/${r.owner}/${r.ready}`).join(" "),
          "client/browser/true client/browser/true client/browser/true");
    check(results, "and which of them the server prerendered",
          inspected.every((r) => r.prerendered), true);

    // -- 7. the second visit: auto is in the browser ----------------------
    //
    // The cookie the loader set on the first visit is what the server reads.
    await page.goto(home, { waitUntil: "load" });
    await page.waitForFunction(() => !!window.latteClient &&
        window.latteClient.regions.size >= 4, undefined, { timeout: 30000 });
    check(results, "auto became a client region once the bundle was known",
          await page.evaluate(() =>
              [...document.querySelectorAll("latte-boundary")]
                  .map((e) => e.getAttribute("data-latte-component"))
                  .filter((n) => n && n.endsWith("Counter")).length), 2);

    check(results, "no page error", beforeRefusals.join(" | ") || "none", "none");
    await browser.close();
    return results;
}

/// Hydration: text typed into the prerendered document BEFORE the scripts
/// run must survive the attach. A context of its own, because it needs the
/// page loaded with JavaScript off and then switched on.
async function runHydration(engine, port) {
    const browser = await engine.launch();
    const results = [];
    // Scripts blocked: what the browser shows is exactly what the server
    // wrote, which is the state a reader can already type into.
    const context = await browser.newContext({ javaScriptEnabled: false });
    const page = await context.newPage();
    await page.goto(`http://127.0.0.1:${port}/`, { waitUntil: "load" });
    check(results, "the page renders with no script at all",
          await page.textContent("#static"),
          "This paragraph is static markup. No instance renders it twice.");
    check(results, "including every region's prerender",
          (await page.evaluate(() =>
              [...document.querySelectorAll("section.counter output")]
                  .map((e) => e.textContent).join(" | "))),
          "server = 1 | client = 10 | auto = 100");
    await context.close();

    // And with scripts on, typing before the attach survives it. The field
    // is filled the instant the DOM is parsed, which is before the deferred
    // scripts have run.
    const live = await browser.newContext();
    const page2 = await live.newPage();
    await page2.addInitScript(() => {
        document.addEventListener("readystatechange", () => {
            if (document.readyState !== "interactive") { return; }
            const field = document.querySelector("#note");
            if (field) { field.value = "typed before the script"; }
        });
    });
    await page2.goto(`http://127.0.0.1:${port}/`, { waitUntil: "load" });
    await page2.waitForFunction(() => !!window.latte && !!window.latte.current &&
        window.latte.current.attached, undefined, { timeout: 30000 });
    check(results, "text typed before the circuit attached survives it",
          await page2.inputValue("#note"), "typed before the script");
    await browser.close();
    return results;
}

async function main() {
    if (!existsSync(resolve(root, "build/browser/modes.wasm"))) {
        console.log("SKIP modes: build/browser/modes.wasm is not built");
        process.exit(0);
    }
    const port = await freePort();
    const server = await startServer(port);
    let bad = 0;
    try {
        for (const name of wanted) {
            const engine = ENGINES[name];
            if (!engine) { console.log(`SKIP ${name}: no such engine`); continue; }
            const rows = [...await run(name, engine, port),
                          ...await runHydration(engine, port)];
            console.log(`== ${name} ==`);
            for (const row of rows) {
                if (row.ok) { console.log(`ok   ${row.name}: ${row.got}`); }
                else {
                    bad += 1;
                    console.log(`FAIL ${row.name}: got ${row.got}, want ${row.want}`);
                }
            }
            console.log("");
        }
    } finally {
        server.child.kill();
    }
    console.log(bad === 0 ? "the application behaves" : `${bad} check(s) failed`);
    process.exit(bad === 0 ? 0 : 1);
}

await main();
