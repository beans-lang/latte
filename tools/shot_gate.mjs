// Screenshot comparison, against references that are committed.
//
// **What a picture can and cannot say.** It cannot say a control behaves; the
// Beans suites and `tools/ui_gate.mjs` say that. What it says is the thing no
// other gate can: that a change to the layout solver, the theme, a template or
// the renderer moved something on screen that nobody meant to move.
//
// So everything that could make one run differ from the next is pinned: the
// viewport, the device pixel ratio, the locale, the timezone, reduced motion,
// and the font — the last one especially, because the same text in a fallback
// face is a different width and every box around it is a different size.
//
// ## The tolerance, and why it is not zero
//
// It is not zero because a GPU is allowed to round a blend differently and two
// machines are allowed to disagree about the last bit of an anti-aliased edge.
// It is **per pixel** rather than an average: an average lets one control move
// a long way as long as the rest of the screen holds still, which is exactly
// the change worth catching. A pixel is different when a channel differs by
// more than `CHANNEL`, and the gate fails when more than `SHARE` of the
// picture is different.
//
//     node tools/shot_gate.mjs            compare
//     node tools/shot_gate.mjs --record   write the references
//
// A recorded reference is committed. Recording to make a red gate go green is
// the one thing this must not be used for, which is why recording is a
// separate word rather than a fallback.
import { chromium, firefox, webkit } from "playwright";
import { readFileSync, writeFileSync, mkdirSync, existsSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { server, listenOnAFreePort } from "./serve.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(HERE, "..");
let PORT = 0;
const ENGINES = { chromium, firefox, webkit };

/// One channel may differ by this much before a pixel counts as different.
const CHANNEL = 8;
/// And this share of the picture may be different before the shot fails.
const SHARE = 0.002;

/// The screens, and how to get to each one. A page is navigated once and each
/// screen reached by clicking the nav button named — the same road a reader
/// takes, so a screen that cannot be reached is a failure too.
const SHOTS = [
    { name: "controls", go: null },
    { name: "editing", go: "Editing" },
    { name: "table", go: "Table" },
    { name: "drawing", go: "Drawing" },
    { name: "panes", go: "Panes" },
];

/// Only chromium by default. Three engines rasterize text differently enough
/// that one reference cannot serve all three, and three sets of references is
/// three things to re-record for every intentional change. The other two are
/// covered by `tools/ui_gate.mjs`, which asks about behaviour.
const engineName = process.env.LATTE_SHOT_ENGINE || "chromium";
const recording = process.argv.includes("--record");

/// A raw RGBA comparison. PNGs come back from Playwright encoded, so both are
/// decoded in the page — the browser has a decoder and node does not.
async function compare(page, a, b) {
    return page.evaluate(async ([first, second]) => {
        const decode = async (bytes) => {
            const blob = new Blob([new Uint8Array(bytes)], { type: "image/png" });
            const bitmap = await createImageBitmap(blob);
            const canvas = new OffscreenCanvas(bitmap.width, bitmap.height);
            const context = canvas.getContext("2d");
            context.drawImage(bitmap, 0, 0);
            return context.getImageData(0, 0, bitmap.width, bitmap.height);
        };
        const left = await decode(first);
        const right = await decode(second);
        if (left.width !== right.width || left.height !== right.height) {
            return { sized: false, left: [left.width, left.height], right: [right.width, right.height] };
        }
        let different = 0;
        let worst = 0;
        for (let at = 0; at < left.data.length; at += 4) {
            let delta = 0;
            for (let channel = 0; channel < 4; channel++) {
                const one = Math.abs(left.data[at + channel] - right.data[at + channel]);
                if (one > delta) delta = one;
            }
            if (delta > worst) worst = delta;
            if (delta > 8) different++;
        }
        return {
            sized: true,
            different,
            total: left.width * left.height,
            worst,
        };
    }, [Array.from(a), Array.from(b)]);
}

async function main() {
    const engine = ENGINES[engineName];
    if (!engine) {
        console.error(`${engineName} is not an engine`);
        process.exit(2);
    }
    if (!existsSync(resolve(ROOT, "build/fonts/latte-regular.ttf"))) {
        console.log("SKIP shots: the fonts are not prepared — run 'node tools/font_prepare.mjs'");
        console.log("            this gate proved nothing");
        process.exit(1);
    }

    PORT = await listenOnAFreePort();
    let browser;
    try {
        browser = await engine.launch();
    } catch (error) {
        console.log(`SKIP shots: ${engineName} is not installed — this gate proved nothing`);
        server.close();
        process.exit(1);
    }

    const page = await browser.newPage({
        viewport: { width: 900, height: 620 },
        deviceScaleFactor: 1,
        locale: "en-US",
        timezoneId: "UTC",
        reducedMotion: "reduce",
    });
    const problems = [];
    page.on("pageerror", (error) => problems.push(String(error)));

    await page.goto(`http://127.0.0.1:${PORT}/examples/showcase/index.html`, { waitUntil: "load" });
    await page.waitForFunction(() => window.__latteReady === true, undefined, { timeout: 30000 });

    mkdirSync(resolve(ROOT, "tests/canvas/shots"), { recursive: true });
    mkdirSync(resolve(ROOT, "build/shots"), { recursive: true });

    let failures = 0;
    for (const shot of SHOTS) {
        if (shot.go) {
            const found = await page.evaluate((label) => {
                const p = window.__lattePage;
                const element = [...p.semantics.root.children]
                    .find((e) => e.getAttribute("aria-label") === label);
                if (!element) return false;
                const rect = p.element.getBoundingClientRect();
                const x = parseFloat(element.style.left) + parseFloat(element.style.width) / 2;
                const y = parseFloat(element.style.top) + parseFloat(element.style.height) / 2;
                for (const type of ["pointerdown", "pointerup"]) {
                    p.element.dispatchEvent(new PointerEvent(type, {
                        clientX: rect.left + x, clientY: rect.top + y,
                        button: 0, detail: 1, bubbles: true, pointerId: 1,
                    }));
                }
                return true;
            }, shot.go);
            if (!found) {
                console.error(`FAIL ${shot.name}: no way to reach it — no nav button called ${shot.go}`);
                failures++;
                continue;
            }
            // Two frames: the click's render, and the paint that follows it.
            await page.evaluate(() => new Promise((done) =>
                requestAnimationFrame(() => requestAnimationFrame(done))));
        }

        const taken = await page.screenshot({ scale: "device" });
        const reference = resolve(ROOT, `tests/canvas/shots/${shot.name}.png`);

        if (recording) {
            writeFileSync(reference, taken);
            console.log(`recorded tests/canvas/shots/${shot.name}.png (${taken.length} bytes)`);
            continue;
        }

        if (!existsSync(reference)) {
            console.error(`FAIL ${shot.name}: no reference. Record one: node tools/shot_gate.mjs --record`);
            failures++;
            continue;
        }

        const result = await compare(page, readFileSync(reference), taken);
        if (!result.sized) {
            console.error(`FAIL ${shot.name}: the picture is ${result.right.join("x")}, the reference is ${result.left.join("x")}`);
            failures++;
            continue;
        }
        const share = result.different / result.total;
        if (share > SHARE) {
            writeFileSync(resolve(ROOT, `build/shots/${shot.name}.now.png`), taken);
            console.error(`FAIL ${shot.name}: ${result.different} of ${result.total} pixels differ (${(share * 100).toFixed(3)}%, worst channel ${result.worst})`);
            console.error(`     what it looks like now: build/shots/${shot.name}.now.png`);
            failures++;
        } else {
            console.log(`ok shots/${shot.name} — ${result.different} of ${result.total} pixels differ (${(share * 100).toFixed(3)}%)`);
        }
    }

    for (const problem of problems) {
        console.error(`FAIL: the page reported ${problem}`);
        failures++;
    }

    await browser.close();
    server.close();
    if (recording) { console.log("recorded. Commit these, and never record to make a red gate green."); return; }
    if (failures) { console.error(`${failures} failure(s)`); process.exit(1); }
    console.log(`shot gate green: ${SHOTS.length} screens in ${engineName}`);
}

main().catch((error) => { console.error(error); process.exit(1); });
