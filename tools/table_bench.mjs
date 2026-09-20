// What a frame of table scrolling costs, phase by phase, in a real browser.
//
// It drives the showcase — the shipping build, GPU surface, accessibility on —
// rather than a headless renderer, because the two costs this is chasing (the
// drawing calls that cross into JavaScript, and the DOM the semantics tree
// becomes) do not exist outside a page.
//
//   node tools/table_bench.mjs                       # every shape, every move
//   node tools/table_bench.mjs --columns 200 --rows 416000
//   node tools/table_bench.mjs --frames 400 --out build/bench/after.json
//   node tools/table_bench.mjs --compare build/bench/before.json
import { chromium, firefox, webkit } from "playwright";
import { mkdir, writeFile, readFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { server, listenOnAFreePort } from "./serve.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(HERE, "..");
const ENGINES = { chromium, firefox, webkit };

// The phase names, in the order `platform.Probe` writes them. Kept here rather
// than read across the boundary: two lists that must agree is why
// tools/check_constants.sh exists, and this one is checked the same way.
const PHASES = [
    "input", "hit", "source", "compose", "diff",
    "layout", "shape", "record", "draw", "a11y", "a11y publish",
];
const TALLIES = ["cell_reads", "live_cells", "shaped", "a11y_nodes", "elements", "changes"];

const VIEWPORT = { width: 1200, height: 820 };
const SCALE = 1;

function flag(name, fallback) {
    const at = process.argv.indexOf(`--${name}`);
    if (at < 0) return fallback;
    const next = process.argv[at + 1];
    if (next === undefined || next.startsWith("--")) return true;
    return next;
}

const FRAMES = Number(flag("frames", 240));
const ENGINE = String(flag("engine", "chromium"));
// Which build to drive. The showcase page names one module, so the chosen one
// is copied into place: comparing two builds has to be two builds, not two
// trees a week apart.
const MODULE = flag("module", null);
/// Keep a cell editor open for the whole run, and skip the warm-up.
const EDITING = flag("editing", false) !== false;
const COLD = flag("cold", false) !== false;

/// The shapes the acceptance tests name. `--columns`/`--rows` narrow it.
function cases() {
    const columnsWanted = flag("columns", null);
    const rowsWanted = flag("rows", null);
    let columns = columnsWanted ? [Number(columnsWanted)] : [2, 24, 200, 1000];
    let rows = rowsWanted ? [Number(rowsWanted)] : [10000, 1000000, 10000000];
    const out = [];
    for (const c of columns) for (const r of rows) out.push({ columns: c, rows: r });
    return out;
}

/// One wheel gesture, as (dx, dy) per frame. A fling is not a slow scroll with
/// a bigger number: it crosses a row boundary every frame and a slow one does
/// not, and those are the two different costs.
const MOVES = {
    slow:      (i) => [0, 3],
    fast:      (i) => [0, 120],
    horizontal:(i) => [40, 0],
    diagonal:  (i) => [18, 18],
    reversal:  (i) => [0, (Math.floor(i / 20) % 2 === 0) ? 90 : -90],
    // What a scrollbar drag is, as far as the table is concerned: a delta far
    // longer than the viewport, so nothing on screen is reused.
    jump:      (i) => [0, (i % 2 === 0) ? 2000000 : -1999880],
    // A wheel that moves nothing. The frame is still asked for and delivered,
    // so this is what a frame costs when there is nothing at all to do.
    still:     (i) => [0, 0],
};

function quantile(sorted, q) {
    if (sorted.length === 0) return 0;
    const at = (sorted.length - 1) * q;
    const low = Math.floor(at), high = Math.ceil(at);
    if (low === high) return sorted[low];
    return sorted[low] + (sorted[high] - sorted[low]) * (at - low);
}

function stats(values) {
    const sorted = [...values].sort((a, b) => a - b);
    const sum = sorted.reduce((a, b) => a + b, 0);
    return {
        n: sorted.length,
        mean: sorted.length ? sum / sorted.length : 0,
        p50: quantile(sorted, 0.5),
        p95: quantile(sorted, 0.95),
        p99: quantile(sorted, 0.99),
        max: sorted.length ? sorted[sorted.length - 1] : 0,
    };
}

const ms = (v) => (v === undefined ? "  --  " : v.toFixed(2).padStart(6));

/// Mounts the showcase's table screen at one shape and runs one gesture.
async function measure(page, shape, move, frames) {
    await page.evaluate(({ rows, columns, width, height, scale }) => {
        const app = window.__lattePage;
        app.call("latte_unmount");
        app.call("latte_shape", rows, columns, 2);
        app.call("latte_mount", width, height, scale);
    }, { ...shape, width: VIEWPORT.width, height: VIEWPORT.height - 0, scale: SCALE });

    // Two frames to settle the first layout, then a warm-up gesture so the
    // numbers are not the cost of the very first paragraph of every column.
    await page.evaluate(() => new Promise((done) =>
        requestAnimationFrame(() => requestAnimationFrame(done))));

    return page.evaluate(async ({ moveName, frames, editing, cold, PHASE_COUNT, TALLY_COUNT }) => {
        const app = window.__lattePage;
        const element = app.element;
        const box = element.getBoundingClientRect();
        // Over the table body, not the header and not the page chrome.
        const at = { x: box.left + box.width / 2, y: box.top + box.height * 0.6 };
        const shapes = {
            slow: (i) => [0, 3],
            fast: (i) => [0, 120],
            horizontal: (i) => [40, 0],
            diagonal: (i) => [18, 18],
            reversal: (i) => [0, (Math.floor(i / 20) % 2 === 0) ? 90 : -90],
            jump: (i) => [0, (i % 2 === 0) ? 2000000 : -1999880],
            still: (i) => [0, 0],
        };
        const step = shapes[moveName];

        const click = (x, y, clicks) => {
            for (const type of ["pointerdown", "pointerup"]) {
                element.dispatchEvent(new PointerEvent(type, {
                    clientX: x, clientY: y, button: 0, detail: clicks,
                    bubbles: true, pointerId: 1,
                }));
            }
        };
        // A cell editor open for the whole run: the second column is the one
        // the showcase's policy allows, and a double click is what opens it.
        if (editing) {
            click(box.left + 200, box.top + 250, 1);
            click(box.left + 200, box.top + 250, 2);
            await new Promise((done) => requestAnimationFrame(done));
        }

        const wheel = (dx, dy) => {
            const started = performance.now();
            element.dispatchEvent(new WheelEvent("wheel", {
                clientX: at.x, clientY: at.y,
                deltaX: dx, deltaY: dy, deltaMode: 0,
                bubbles: true, cancelable: true,
            }));
            return performance.now() - started;
        };

        // Warm up: ten frames of the same gesture, not recorded. `--cold`
        // leaves them out, so the first frames after a mount are measured with
        // no paragraph, no layout node and no free block reused.
        if (!cold) {
            for (let i = 0; i < 10; i++) {
                wheel(...step(i));
                await new Promise((done) => requestAnimationFrame(done));
            }
        }

        const loaf = [];
        let observer = null;
        if (typeof PerformanceObserver === "function" &&
            PerformanceObserver.supportedEntryTypes?.includes("long-animation-frame")) {
            observer = new PerformanceObserver((list) => {
                for (const entry of list.getEntries()) {
                    loaf.push({
                        duration: entry.duration,
                        blocking: entry.blockingDuration,
                        renderStart: entry.renderStart - entry.startTime,
                        styleAndLayout: entry.styleAndLayoutStart
                            ? entry.styleAndLayoutStart - entry.startTime : 0,
                    });
                }
            });
            observer.observe({ type: "long-animation-frame", buffered: false });
        }

        const wasmLive = () => {
            const read = app.runtime.exports.latte_heap_live;
            return read ? Number(read()) : 0;
        };
        const wasmPages = () => {
            const read = app.runtime.exports.latte_heap_pages;
            return read ? Number(read()) : 0;
        };
        const heapBefore = performance.memory ? performance.memory.usedJSHeapSize : 0;
        const liveBefore = wasmLive();
        const pagesBefore = wasmPages();
        app.call("latte_probe_enable", 1);

        const wheelCost = [];
        const spacing = [];
        let last = 0;
        for (let i = 0; i < frames; i++) {
            wheelCost.push(wheel(...step(i)));
            const stamp = await new Promise((done) => requestAnimationFrame(done));
            if (last) spacing.push(stamp - last);
            last = stamp;
        }
        // One more frame so the last wheel's frame is delivered and marked.
        await new Promise((done) => requestAnimationFrame(done));
        app.call("latte_probe_enable", 0);
        if (observer) observer.disconnect();

        const heapAfter = performance.memory ? performance.memory.usedJSHeapSize : 0;

        const width = app.runtime.exports.latte_probe_width();
        const marked = app.runtime.exports.latte_probe_frames();
        // The module writes a row of this shape and this file reads it back by
        // index. A module built against a different phase list would line up
        // wrongly and read plausible nonsense, which is the one failure a
        // benchmark must not have.
        const expected = PHASE_COUNT + TALLY_COUNT;
        if (width !== expected) {
            throw new Error(`the module records ${width} numbers a frame and this ` +
                            `benchmark reads ${expected} — rebuild it`);
        }
        const rows = [];
        for (let f = 0; f < marked; f++) {
            const row = [];
            for (let s = 0; s < width; s++) {
                row.push(app.runtime.exports.latte_probe_value(f, s));
            }
            rows.push(row);
        }
        // The tape is given back before the heap is read. It is seventeen
        // numbers a frame, so a long run measures the recorder rather than the
        // program: 3600 frames of a table that did nothing "grew" by 688 KB,
        // and all of it was this.
        app.call("latte_probe_reset");
        return {
            rows, wheelCost, spacing, loaf,
            heapBefore, heapAfter,
            liveBefore, liveAfter: wasmLive(),
            pagesBefore, pagesAfter: wasmPages(),
            a11yDom: app.semantics ? app.semantics.count() : 0,
            editing: app.editing ? !!app.editing.active : false,
            skiaObjects: app.surface.resourceCount(),
            frames: app.runtime.exports.latte_frames(),
            painted: app.runtime.exports.latte_painted(),
            error: app.lastError(),
        };
    }, { moveName: move, frames, editing: EDITING, cold: COLD,
         PHASE_COUNT: PHASES.length, TALLY_COUNT: TALLIES.length });
}

function summarise(raw) {
    const width = PHASES.length + TALLIES.length;
    const phase = {};
    PHASES.forEach((name, index) => {
        phase[name] = stats(raw.rows.map((r) => r[index]));
    });
    const totals = raw.rows.map((r) => {
        let sum = 0;
        for (let i = 0; i < PHASES.length; i++) sum += r[i];
        return sum;
    });
    const tally = {};
    TALLIES.forEach((name, index) => {
        const column = raw.rows.map((r) => r[PHASES.length + index]);
        tally[name] = {
            max: column.length ? Math.max(...column) : 0,
            total: column.reduce((a, b) => a + b, 0),
        };
    });
    // Probe timing is read from performance.now(), which Chrome quantises to
    // 5 microseconds. Ten phases means the sum of a frame's phases can be out
    // by as much as 50us — well under the budget being measured, and said here
    // rather than left for somebody to rediscover.
    return {
        survived: true,
        cpu: stats(totals),
        phase,
        tally,
        wheel: stats(raw.wheelCost),
        spacing: stats(raw.spacing),
        loaf: raw.loaf.length ? stats(raw.loaf.map((l) => l.duration)) : null,
        missed: raw.spacing.filter((s) => s > 20).length,
        heapGrowthMb: (raw.heapAfter - raw.heapBefore) / (1024 * 1024),
        wasmLiveKb: raw.liveAfter / 1024,
        wasmGrowthKb: (raw.liveAfter - raw.liveBefore) / 1024,
        wasmPages: raw.pagesAfter,
        wasmPagesGrown: raw.pagesAfter - raw.pagesBefore,
        a11yDom: raw.a11yDom,
        editorOpen: raw.editing,
        skiaObjects: raw.skiaObjects,
        markedFrames: raw.rows.length,
        error: raw.error,
    };
}

function printCase(label, s) {
    console.log(`\n--- ${label} ---`);
    if (s.error) console.log(`  module error: ${s.error}`);
    console.log(`  frames measured ${s.markedFrames}   missed (>20ms rAF gap) ${s.missed}` +
                `${s.editorOpen ? "   cell editor open" : ""}`);
    console.log(`  live cells ${s.tally.live_cells.max}   cell reads ${s.tally.cell_reads.total}` +
                `   shaped ${s.tally.shaped.total}   changes ${s.tally.changes.total}` +
                `   a11y DOM ${s.a11yDom}   Skia objects ${s.skiaObjects}`);
    console.log(`  JS heap growth ${s.heapGrowthMb.toFixed(2)} MB` +
                `   module heap ${s.wasmLiveKb.toFixed(0)} KB live` +
                ` (${s.wasmGrowthKb >= 0 ? "+" : ""}${s.wasmGrowthKb.toFixed(0)} KB over the run)` +
                `   ${s.wasmPages} pages (+${s.wasmPagesGrown})`);
    console.log("                    p50     p95     p99     max");
    const line = (name, v) =>
        console.log(`  ${name.padEnd(16)}${ms(v.p50)}  ${ms(v.p95)}  ${ms(v.p99)}  ${ms(v.max)}`);
    line("wheel handler", s.wheel);
    for (const name of PHASES) line(name, s.phase[name]);
    line("CPU total", s.cpu);
    line("rAF spacing", s.spacing);
    if (s.loaf) line("LoAF duration", s.loaf);
}

async function main() {
    if (MODULE) {
        const from = resolve(ROOT, `build/browser/showcase-${MODULE}.wasm`);
        await writeFile(join(ROOT, "build/browser/showcase.wasm"), await readFile(from));
        console.log(`module: showcase-${MODULE}.wasm`);
    }
    const PORT = await listenOnAFreePort();
    const engine = ENGINES[ENGINE];
    if (!engine) { console.error(`no engine "${ENGINE}"`); process.exit(1); }
    const problems = [];
    let browser = null;
    let page = null;
    // A shape heavy enough to kill the renderer is a result, not a crash of
    // this file: the case is recorded as one the page did not survive and the
    // sweep opens a fresh one and carries on.
    const openPage = async () => {
        if (browser) await browser.close().catch(() => {});
        browser = await engine.launch();
        page = await browser.newPage({
            viewport: VIEWPORT,
            deviceScaleFactor: SCALE,
            locale: "en-US",
            timezoneId: "UTC",
        });
        page.on("pageerror", (e) => problems.push(String(e)));
        await page.goto(`http://127.0.0.1:${PORT}/examples/showcase/index.html`, { waitUntil: "load" });
        await page.waitForFunction(() => window.__latteReady === true, undefined, { timeout: 120000 });
        const failed = await page.evaluate(() => window.__latteFailed || "");
        if (failed) throw new Error(`the showcase never booted: ${failed}`);
    };
    await openPage();

    const moves = String(flag("moves", "slow,fast,horizontal,diagonal,reversal")).split(",");
    const machine = await page.evaluate(() => ({
        agent: navigator.userAgent,
        cores: navigator.hardwareConcurrency,
        dpr: window.devicePixelRatio,
        software: window.__lattePage.surface.isSoftware,
    }));

    console.log(`latte table benchmark`);
    console.log(`  engine ${ENGINE}   viewport ${VIEWPORT.width}x${VIEWPORT.height}` +
                `   scale ${SCALE}   frames/gesture ${FRAMES}`);
    console.log(`  ${machine.agent}`);
    console.log(`  cores ${machine.cores}   devicePixelRatio ${machine.dpr}` +
                `   renderer ${machine.software ? "software (CPU)" : "GPU"}`);

    const report = { machine, viewport: VIEWPORT, scale: SCALE, frames: FRAMES, cases: {} };
    for (const shape of cases()) {
        for (const move of moves) {
            const label = `${shape.columns} col x ${shape.rows} rows — ${move}`;
            let summary = null;
            try {
                summary = summarise(await measure(page, shape, move, FRAMES));
            } catch (error) {
                const why = String(error).split("\n")[0];
                summary = { survived: false, why };
                console.log(`\n--- ${label} ---\n  the page did not survive it: ${why}`);
                await openPage();
            }
            report.cases[label] = summary;
            if (summary.survived !== false) printCase(label, summary);
        }
    }

    const out = flag("out", null);
    if (out) {
        await mkdir(dirname(resolve(ROOT, out)), { recursive: true });
        await writeFile(resolve(ROOT, out), JSON.stringify(report, null, 2));
        console.log(`\nwrote ${out}`);
    }

    const before = flag("compare", null);
    if (before) {
        const old = JSON.parse(await readFile(resolve(ROOT, before), "utf8"));
        console.log(`\n=== against ${before} ===`);
        console.log("case                                        CPU p95      wheel p95    live cells");
        for (const label of Object.keys(report.cases)) {
            const now = report.cases[label];
            const was = old.cases[label];
            if (!was) continue;
            if (was.survived === false || now.survived === false) {
                console.log(`${label.padEnd(44)}` +
                    `${was.survived === false ? "  the page did not survive it" : "  was measured"} -> ` +
                    `${now.survived === false ? "the page did not survive it" : `${ms(now.cpu.p95)} ms p95`}`);
                continue;
            }
            console.log(`${label.padEnd(44)}` +
                `${ms(was.cpu.p95)} -> ${ms(now.cpu.p95)}  ` +
                `${ms(was.wheel.p95)} -> ${ms(now.wheel.p95)}  ` +
                `${String(was.tally.live_cells.max).padStart(6)} -> ${String(now.tally.live_cells.max).padStart(6)}`);
        }
    }

    if (problems.length) {
        console.error("\npage errors:");
        for (const p of problems) console.error(`  ${p}`);
    }
    await browser.close();
    server.close();
}

main().catch((error) => { console.error(error); process.exit(1); });
