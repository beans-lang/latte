// The browser leg: every suite, in every engine that is installed.
//
// What it is for. A Beans suite that passes under the interpreter and the
// native backend says the *runtime* is right; it says nothing about whether
// the same bytes work through a browser's WebAssembly engine, its
// `requestAnimationFrame`, its pointer events or its text decoding. Those have
// been where the surprises are, so this runs the same programs there and
// compares the output with the same golden files.
//
// **A missing engine is reported as a missing engine, loudly.** It does not
// pass. A gate that goes green because it found nothing to run is the failure
// this workspace has been bitten by before, so the summary names every engine
// that was skipped and the process exits non-zero unless at least one ran.
import { chromium, firefox, webkit } from "playwright";
import { readFile, readdir } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, join, resolve } from "node:path";
import { server } from "./serve.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(HERE, "..");
const PORT = Number(process.env.LATTE_GATE_PORT || 8732);
const ENGINES = { chromium, firefox, webkit };

const only = process.argv.slice(2).filter((a) => !a.startsWith("--"));
const wantEngines = (process.env.LATTE_ENGINES || "chromium,firefox,webkit").split(",");

/// Every `<name>.wasm` in build/browser that has a golden beside it.
///
/// A suite whose name starts `browser_` is built from `_browser_<name>.b` and
/// runs here and nowhere else: it imports the drawing half, whose entries are
/// undefined symbols outside a WebAssembly module. Its golden is its own, and
/// deliberately not the measuring renderer's — the difference between the two
/// is what those suites are for.
async function suites() {
    const built = await readdir(join(ROOT, "build/browser")).catch(() => []);
    const golden = await readdir(join(ROOT, "tests/canvas/golden")).catch(() => []);
    const found = [];
    for (const file of built) {
        if (!file.endsWith(".wasm")) continue;
        const name = file.slice(0, -5);
        if (!golden.includes(`${name}.out`)) continue;
        if (only.length && !only.includes(name)) continue;
        found.push(name);
    }
    return found.sort();
}

/// Runs one module in one page and collects what it printed.
async function runSuite(page, name) {
    const url = `http://127.0.0.1:${PORT}/tools/runner.html?module=${encodeURIComponent(name)}`;
    await page.goto(url, { waitUntil: "load" });
    // The page sets `__latteRun` when the module has finished. A timeout here
    // is a real failure — a module that hangs is a module that would hang in
    // somebody's tab — so it is not caught and turned into a skip.
    await page.waitForFunction(() => window.__latteRun !== undefined, null, { timeout: 30000 });
    return page.evaluate(() => window.__latteRun);
}

async function main() {
    const names = await suites();
    if (names.length === 0) {
        console.error("no browser suites found. Build them first:");
        console.error("  bash tools/wasm_build.sh tests/canvas/lifecycle.b build/browser/lifecycle.wasm");
        process.exit(1);
    }

    await new Promise((done) => server.listen(PORT, "127.0.0.1", done));

    let failures = 0;
    let ran = 0;
    const skipped = [];

    for (const engineName of wantEngines) {
        const engine = ENGINES[engineName];
        if (!engine) { skipped.push(`${engineName} (no such engine)`); continue; }
        let browser;
        try {
            browser = await engine.launch();
        } catch (error) {
            // The one honest skip: the engine is not installed on this
            // machine. It is printed as a skip and counted as one.
            skipped.push(`${engineName} (not installed: ${String(error).split("\n")[0]})`);
            continue;
        }
        const page = await browser.newPage();
        const consoleErrors = [];
        page.on("pageerror", (error) => consoleErrors.push(String(error)));

        for (const name of names) {
            const want = await readFile(join(ROOT, `tests/canvas/golden/${name}.out`), "utf8");
            let result;
            try {
                result = await runSuite(page, name);
            } catch (error) {
                console.error(`FAIL ${engineName}/${name}: ${String(error).split("\n")[0]}`);
                failures++;
                continue;
            }
            ran++;
            const got = result.output;
            if (got !== want) {
                console.error(`FAIL ${engineName}/${name}: output differs from the golden`);
                const gotLines = got.split("\n");
                const wantLines = want.split("\n");
                for (let i = 0; i < Math.max(gotLines.length, wantLines.length); i++) {
                    if (gotLines[i] !== wantLines[i]) {
                        console.error(`  line ${i + 1}`);
                        console.error(`    want: ${JSON.stringify(wantLines[i])}`);
                        console.error(`    got:  ${JSON.stringify(gotLines[i])}`);
                    }
                }
                failures++;
            } else if (result.code !== 0) {
                console.error(`FAIL ${engineName}/${name}: the module answered ${result.code}`);
                failures++;
            } else {
                console.log(`ok ${engineName}/${name} — matches the golden (${result.pages} pages, ${result.live} bytes live)`);
            }
        }
        if (consoleErrors.length) {
            console.error(`FAIL ${engineName}: the page reported ${consoleErrors.length} error(s)`);
            for (const error of consoleErrors) console.error(`  ${error}`);
            failures++;
        }
        await browser.close();
    }

    server.close();

    for (const reason of skipped) console.log(`SKIP ${reason} — this engine proved nothing`);
    if (ran === 0) {
        console.error("no engine ran: every one was skipped, so this gate proved nothing");
        process.exit(1);
    }
    if (failures) {
        console.error(`${failures} failure(s)`);
        process.exit(1);
    }
    console.log(`browser gate green: ${ran} run(s) across ${wantEngines.length - skipped.length} engine(s)`);
}

main().catch((error) => { console.error(error); process.exit(1); });
