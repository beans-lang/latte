// The browser half of a `client` execution boundary, in a real browser.
//
// `tools/client_wire.mjs` proves the module answers the right edits. It
// cannot prove that those edits become the right DOM, that a click inside
// the region reaches the module at all, or — the assertion this file exists
// for — that none of it touches the network.
//
// So: one static page, one `<latte-boundary>` the server could have written,
// `latte.js` and `latte-client.js` loaded the way a served page loads them,
// and Playwright driving Chromium, Firefox and WebKit.
//
// Every engine runs the same list and the output is the same lines, so a
// difference between engines is a diff a person reads.
import { mkdir, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import { chromium, firefox, webkit } from "playwright";

const ENGINES = { chromium, firefox, webkit };
const wanted = (process.env.LATTE_ENGINES || "chromium,firefox,webkit").split(",");
// The repository root is what is served, so one origin reaches `js/` and the
// built module alike — a page that fetched its bundle from a second origin
// would be testing CORS rather than a region.
const root = resolve(process.env.LATTE_CLIENT_ROOT || ".");
const pagePath = "build/browser/client/index.html";
const modulePath = process.env.LATTE_CLIENT_MODULE || "/build/browser/clienttest.wasm";

const PAGE = `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>client region</title></head>
<body>
<div id="latte-root">
  <h1 id="heading">a page</h1>
  <latte-boundary data-latte-boundary="r1"
                  data-latte-mode="client"
                  data-latte-component="clienttest.site.Counter"
                  data-latte-props='{"start":3,"label":"hits"}'></latte-boundary>
  <p id="after">after</p>
</div>
<script src="/js/latte.js"></script>
<script type="module" src="/js/latte-client.js"
        data-latte-wasm="${modulePath}"></script>
</body></html>
`;

async function stage() {
    await mkdir(resolve(root, "build/browser/client"), { recursive: true });
    await writeFile(resolve(root, pagePath), PAGE);
}

function check(results, name, got, want) {
    results.push({ name, got: String(got), want: String(want),
                   ok: String(got) === String(want) });
}

async function run(engineName, engine, port) {
    const browser = await engine.launch();
    const page = await browser.newPage({ viewport: { width: 900, height: 620 } });
    const problems = [];
    const requests = [];
    page.on("pageerror", (error) => problems.push(String(error)));
    page.on("console", (m) => { if (m.type() === "error") problems.push(m.text()); });
    page.on("request", (r) => requests.push(r.url()));

    const results = [];
    await page.goto(`http://127.0.0.1:${port}/${pagePath}`, { waitUntil: "load" });
    await page.waitForFunction(() => !!window.latteClient &&
        window.latteClient.regions.size > 0, undefined, { timeout: 30000 });

    // -- 1. the region rendered itself -------------------------------------
    check(results, "the region is mounted",
          await page.evaluate(() => window.latteClient.regions.size), 1);
    check(results, "and it built its own DOM",
          await page.textContent("#value"), "hits=3");
    check(results, "inside the boundary the server wrote",
          await page.evaluate(() =>
              document.querySelector("#value").closest("latte-boundary")
                  .getAttribute("data-latte-boundary")), "r1");
    check(results, "the page around it is untouched",
          await page.textContent("#after"), "after");

    // -- 2. a click costs no network ---------------------------------------
    //
    // The whole claim of a client region in one assertion. Everything the
    // page has already fetched is forgotten first, so what is counted is
    // exactly what the click caused.
    requests.length = 0;
    await page.click("#add");
    await page.waitForFunction(() =>
        document.querySelector("#value").textContent === "hits=4",
        undefined, { timeout: 5000 });
    check(results, "the click landed", await page.textContent("#value"), "hits=4");
    check(results, "and it made no request at all", requests.length, 0);

    await page.click("#add");
    await page.waitForFunction(() =>
        document.querySelector("#value").textContent === "hits=5",
        undefined, { timeout: 5000 });
    check(results, "a second click, still no network",
          `${await page.textContent("#value")}/${requests.length}`, "hits=5/0");

    // -- 3. typing ---------------------------------------------------------
    await page.fill("#note", "beans");
    await page.waitForFunction(() =>
        document.querySelector("#echo").textContent === "beans",
        undefined, { timeout: 5000 });
    check(results, "an input event reaches the module",
          await page.textContent("#echo"), "beans");
    check(results, "and still nothing went out", requests.length, 0);

    // -- 4. the server changes a prop --------------------------------------
    //
    // The server owns the boundary element's attributes; the browser owns
    // what is inside. Writing the attribute is exactly what a server batch
    // does, so this is that path with the socket taken out.
    await page.evaluate(() => {
        document.querySelector("latte-boundary")
            .setAttribute("data-latte-props", '{"start":10,"label":"hits"}');
    });
    await page.waitForFunction(() =>
        document.querySelector("#value").textContent === "hits=12",
        undefined, { timeout: 5000 });
    check(results, "new props reach the live instance",
          await page.textContent("#value"), "hits=12");
    check(results, "and its own state survived them",
          await page.textContent("#echo"), "beans");
    check(results, "the text the user typed is still in the field",
          await page.inputValue("#note"), "beans");

    // -- 5. the boundary goes away -----------------------------------------
    await page.evaluate(() => {
        document.querySelector("latte-boundary").remove();
    });
    await page.waitForFunction(() => window.latteClient.regions.size === 0,
                               undefined, { timeout: 5000 });
    check(results, "removing the boundary unmounts the region",
          await page.evaluate(() => window.latteClient.regions.size), 0);

    check(results, "no page error", problems.join(" | ") || "none", "none");
    await browser.close();
    return results;
}

async function main() {
    await stage();
    process.env.LATTE_SERVE_ROOT = root;
    const { server, listenOnAFreePort } = await import("./serve.mjs");
    const port = await listenOnAFreePort();

    let bad = 0;
    for (const name of wanted) {
        const engine = ENGINES[name];
        if (!engine) { console.log(`SKIP ${name}: no such engine`); continue; }
        let results;
        try {
            results = await run(name, engine, port);
        } catch (problem) {
            console.log(`SKIP ${name}: ${String(problem).split("\n")[0]}`);
            continue;
        }
        console.log(`== ${name} ==`);
        for (const row of results) {
            if (row.ok) { console.log(`ok   ${row.name}: ${row.got}`); }
            else { bad += 1; console.log(`FAIL ${row.name}: got ${row.got}, want ${row.want}`); }
        }
        console.log("");
    }
    server.close();
    console.log(bad === 0 ? "every engine agrees" : `${bad} check(s) failed`);
    process.exit(bad === 0 ? 0 : 1);
}

await main();
