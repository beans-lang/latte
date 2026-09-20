// Takes a picture of a Latte page, by hand or for `tools/shot_check.mjs`. The
// viewport, the ratio and the font are pinned: a fallback face is a relayout.
import { chromium, firefox, webkit } from "playwright";
import { server, listenOnAFreePort } from "./serve.mjs";
import { resolve } from "node:path";

const ENGINES = { chromium, firefox, webkit };

export async function shoot(options) {
    const {
        url,
        out,
        engine = "chromium",
        width = 900,
        height = 620,
        scale = 1,
        wait = () => window.__latteReady === true,
        port = 0,
        settle = 0,
    } = options;

    let listening = false;
    let bound = port;
    if (!server.listening) {
        bound = await listenOnAFreePort(port);
        listening = true;
    } else {
        bound = server.address().port;
    }

    const browser = await ENGINES[engine].launch();
    const page = await browser.newPage({
        viewport: { width, height },
        deviceScaleFactor: scale,
        // A fixed locale: Intl.Segmenter's word boundaries and any date a
        // control formats both follow it.
        locale: "en-US",
        timezoneId: "UTC",
        reducedMotion: "no-preference",
    });
    const problems = [];
    page.on("console", (m) => { if (process.env.LATTE_SHOOT_DEBUG) console.log("[page]", m.type(), m.text()); });
    page.on("pageerror", (error) => problems.push(String(error)));
    page.on("console", (message) => {
        if (message.type() === "error") problems.push(message.text());
    });

    await page.goto(`http://127.0.0.1:${bound}/${url.replace(/^\//, "")}`, { waitUntil: "load" });
    await page.waitForFunction(wait, undefined, { timeout: 30000 });
    if (settle) await page.waitForTimeout(settle);
    await page.screenshot({ path: resolve(out), scale: "device" });
    const facts = await page.evaluate(() => (window.__latteFacts ? window.__latteFacts() : null));
    await browser.close();
    if (listening) server.close();
    return { problems, facts };
}

if (process.argv[1] && import.meta.url === `file://${resolve(process.argv[1])}`) {
    const [url, out, engine] = process.argv.slice(2);
    if (!url || !out) {
        console.error("usage: node tools/shoot.mjs <url> <out.png> [engine]");
        process.exit(2);
    }
    const result = await shoot({ url, out, engine: engine || "chromium" });
    for (const problem of result.problems) console.error(`  page error: ${problem}`);
    console.log(`wrote ${out}`);
    if (result.facts) console.log(JSON.stringify(result.facts));
    process.exit(result.problems.length ? 1 : 0);
}
