// The browser half a Beans suite cannot reach: pointers, input methods,
// resizes, a lost context, teardown. It asserts state, never pixels.
import { chromium, firefox, webkit } from "playwright";
import { server, listenOnAFreePort } from "./serve.mjs";

const ENGINES = { chromium, firefox, webkit };
let PORT = 0;
const wanted = (process.env.LATTE_ENGINES || "chromium,firefox,webkit").split(",");

/// Where a node with this accessible name is, in canvas coordinates: a control
/// this test cannot find is a control a screen reader cannot find either.
function nodeAt(label) {
    const page = window.__lattePage;
    const element = [...page.semantics.root.children]
        .find((e) => (e.getAttribute("aria-label") || "").startsWith(label));
    if (!element) return null;
    return {
        x: parseFloat(element.style.left) + parseFloat(element.style.width) / 2,
        y: parseFloat(element.style.top) + parseFloat(element.style.height) / 2,
        label: element.getAttribute("aria-label"),
        role: element.getAttribute("role"),
    };
}

async function click(page, label) {
    const box = await page.evaluate(nodeAt, label);
    if (!box) throw new Error(`no node whose name starts "${label}"`);
    await page.evaluate(({ x, y }) => {
        const element = window.__lattePage.element;
        const rect = element.getBoundingClientRect();
        for (const type of ["pointerdown", "pointerup"]) {
            element.dispatchEvent(new PointerEvent(type, {
                clientX: rect.left + x, clientY: rect.top + y,
                button: 0, detail: 1, bubbles: true, pointerId: 1,
            }));
        }
    }, box);
    await page.waitForTimeout(80);
    return box;
}

async function labels(page) {
    return page.evaluate(() => [...window.__lattePage.semantics.root.children]
        .filter((e) => e.getAttribute("aria-hidden") !== "true")
        .map((e) => e.getAttribute("aria-label") || ""));
}

async function facts(page) {
    return page.evaluate(() => window.__latteFacts());
}

function check(results, name, condition, detail) {
    results.push({ name, ok: !!condition, detail: detail ?? "" });
}

async function run(engineName, engine) {
    const browser = await engine.launch();
    const page = await browser.newPage({
        viewport: { width: 900, height: 620 },
        deviceScaleFactor: 1,
        locale: "en-US",
        timezoneId: "UTC",
    });
    const problems = [];
    page.on("pageerror", (error) => problems.push(String(error)));
    page.on("console", (m) => { if (m.type() === "error") problems.push(m.text()); });

    const results = [];
    await page.goto(`http://127.0.0.1:${PORT}/examples/showcase/index.html`, { waitUntil: "load" });
    await page.waitForFunction(() => window.__latteReady === true, undefined, { timeout: 30000 });
    // __latteReady is set on the failure path too, so the page can be "ready"
    // and dead. Say which, rather than tripping over a missing global later.
    const booted = await page.evaluate(() => window.__latteFailed || "");
    if (booted) throw new Error(`the showcase never booted: ${booted}`);

    const opened = await facts(page);
    check(results, "the module mounted", opened.error === "", opened.error);
    check(results, "it published an accessibility tree", opened.a11yNodes > 10, `${opened.a11yNodes} nodes`);

    // --- pointer ---------------------------------------------------------
    await click(page, "Editing");
    check(results, "a click changed the screen",
        (await labels(page)).some((l) => l.startsWith("Editing")), "");

    // --- text input, through the editing element ------------------------
    const typed = await page.evaluate(async () => {
        const page_ = window.__lattePage;
        // Focus the first text field the way a click does, then type into the
        // editing element — which is where a browser really delivers text.
        const field = [...page_.semantics.root.children]
            .find((e) => e.getAttribute("role") === "textbox");
        if (!field) return { error: "no text field" };
        const rect = page_.element.getBoundingClientRect();
        const x = parseFloat(field.style.left) + 10;
        const y = parseFloat(field.style.top) + parseFloat(field.style.height) / 2;
        for (const type of ["pointerdown", "pointerup"]) {
            page_.element.dispatchEvent(new PointerEvent(type, {
                clientX: rect.left + x, clientY: rect.top + y,
                button: 0, detail: 1, bubbles: true, pointerId: 1,
            }));
        }
        const editor = page_.editing.element;
        for (const letter of "Zoe") {
            editor.dispatchEvent(new InputEvent("beforeinput", {
                inputType: "insertText", data: letter, bubbles: true, cancelable: true,
            }));
        }
        await new Promise((done) => requestAnimationFrame(done));
        return {
            value: [...page_.semantics.root.children]
                .filter((e) => e.getAttribute("role") === "textbox")
                .map((e) => e.getAttribute("aria-valuetext"))[0] || "",
        };
    });
    check(results, "typing reached the field", typed.value === "Zoe", JSON.stringify(typed));

    // --- an input method -------------------------------------------------
    const composed = await page.evaluate(async () => {
        const page_ = window.__lattePage;
        const editor = page_.editing.element;
        editor.dispatchEvent(new CompositionEvent("compositionstart", { bubbles: true }));
        editor.dispatchEvent(new CompositionEvent("compositionupdate", { data: "に", bubbles: true }));
        editor.dispatchEvent(new CompositionEvent("compositionupdate", { data: "にほ", bubbles: true }));
        editor.dispatchEvent(new CompositionEvent("compositionend", { data: "日本", bubbles: true }));
        await new Promise((done) => requestAnimationFrame(done));
        return [...page_.semantics.root.children]
            .filter((e) => e.getAttribute("role") === "textbox")
            .map((e) => e.getAttribute("aria-valuetext"))[0] || "";
    });
    // The composition commits its final text and no intermediate state
    // survives, which is why `beforeinput` is ignored while it composes.
    check(results, "a composition commits once", composed === "Zoe日本", JSON.stringify(composed));

    // --- a REAL mouse and a REAL keyboard ---------------------------------
    //
    // Everything above dispatches events at the editing element, which skips
    // the click, the focus and the hit test. All of that was broken while
    // these checks were green: the accessibility proxies covered the canvas,
    // so no click ever reached latte, and nothing focused the editor.
    // The gallery's search box, because nothing above types into it.
    await click(page, "Gallery");
    await page.waitForTimeout(150);
    const field = await page.evaluate(() => {
        const p = window.__lattePage;
        const e = [...p.semantics.root.children]
            .find((n) => (n.getAttribute("aria-label") || "").startsWith("Search orders"));
        const r = p.element.getBoundingClientRect();
        return { left: r.left, top: r.top, x: parseFloat(e.style.left), y: parseFloat(e.style.top),
                 w: parseFloat(e.style.width), h: parseFloat(e.style.height) };
    });
    const valueNow = () => page.evaluate(() => {
        const e = [...window.__lattePage.semantics.root.children]
            .find((n) => (n.getAttribute("aria-label") || "").startsWith("Search orders"));
        return e ? (e.getAttribute("aria-valuetext") || "") : "<gone>";
    });

    await page.mouse.click(field.left + field.x + field.w / 2, field.top + field.y + field.h / 2);
    await page.keyboard.type("mno", { delay: 20 });
    await page.waitForTimeout(150);
    const realTyped = await valueNow();
    check(results, "a real click and real keys reach the field",
        realTyped === "mno", JSON.stringify(realTyped));

    // And the caret goes where the pointer went, not to the end. Clicking the
    // left edge and typing puts the letter first.
    await page.mouse.click(field.left + field.x + 2, field.top + field.y + field.h / 2);
    await page.keyboard.type("A", { delay: 20 });
    await page.waitForTimeout(150);
    const placed = await valueNow();
    check(results, "the caret lands where the click did",
        placed === "Amno", JSON.stringify(placed));

    // Backspace and the arrows are KEYS, not text, and they arrive at
    // whichever element has focus. While editing that is the editing element,
    // so a page that bound keys to the canvas alone could type but never erase.
    // The caret is after the "A" the click placed, so this erases that.
    await page.keyboard.press("Backspace");
    await page.waitForTimeout(120);
    const erased = await valueNow();
    check(results, "backspace erases", erased === "mno", JSON.stringify(erased));

    // Caret is at the start now; one step right puts the letter after "m".
    await page.keyboard.press("ArrowRight");
    await page.keyboard.type("Z", { delay: 20 });
    await page.waitForTimeout(120);
    const arrowed = await valueNow();
    check(results, "an arrow key moves the caret", arrowed === "mZno", JSON.stringify(arrowed));

    // An empty field's caret must sit where a full one's does. Skia reports no
    // lines for empty text, and taking those zeros as metrics dropped the
    // caret to the bottom of the box.
    const caretY = async () => page.evaluate(() => {
        const p = window.__lattePage, r = p.element.getBoundingClientRect();
        return Math.round(p.editing.element.getBoundingClientRect().top - r.top);
    });
    const withText = await caretY();
    await page.keyboard.press("Control+a");
    await page.keyboard.press("Meta+a");
    await page.keyboard.press("Backspace");
    await page.keyboard.press("Backspace");
    await page.keyboard.press("Backspace");
    await page.keyboard.press("Backspace");
    await page.waitForTimeout(150);
    const emptied = await valueNow();
    const whenEmpty = await caretY();
    check(results, "the field empties", emptied === "", JSON.stringify(emptied));
    check(results, "an empty field's caret sits where a full one's does",
        Math.abs(whenEmpty - withText) <= 1, `full ${withText}, empty ${whenEmpty}`);

    // --- every control latte draws, on one screen ------------------------
    // The gallery is the only page that has all of them, so this is where a
    // control that stopped publishing a role would show up.
    await click(page, "Gallery");
    await page.waitForFunction(
        () => window.__lattePage.surface.imagesPending() === 0,
        undefined, { timeout: 15000 });
    const roles = await page.evaluate(() => [...new Set(
        [...window.__lattePage.semantics.root.children]
            .map((e) => e.getAttribute("role")).filter(Boolean))].sort());
    const WANTED = ["button", "checkbox", "combobox", "group", "image", "meter",
                    "progressbar", "radio", "radiogroup", "scrollarea", "securetext",
                    "separator", "slider", "spinbutton", "switch", "table",
                    "tablist", "text", "textbox"];
    const absent = WANTED.filter((r) => !roles.includes(r));
    // Roles, not controls: every shape publishes "image", so this catches a
    // whole role going missing, not one control. tools/check_gallery.sh does that.
    check(results, "the gallery publishes every role latte has",
        absent.length === 0, absent.length ? `missing ${absent.join(", ")}` : `${roles.length} roles`);

    // --- an accessibility action -----------------------------------------
    await click(page, "Controls");
    const activated = await page.evaluate(async () => {
        const page_ = window.__lattePage;
        const box = [...page_.semantics.root.children]
            .find((e) => e.getAttribute("role") === "checkbox");
        if (!box) return { error: "no check box" };
        const before = box.getAttribute("aria-valuetext");
        box.click();                       // what a screen reader does
        await new Promise((done) => requestAnimationFrame(done));
        const after = [...page_.semantics.root.children]
            .find((e) => e.getAttribute("role") === "checkbox")
            .getAttribute("aria-valuetext");
        return { before, after };
    });
    check(results, "a screen reader's activate reaches the control",
        activated.before !== activated.after, JSON.stringify(activated));

    // Nothing is copied back: the surface Skia draws into is the one the
    // browser composites, so a frame costs no CPU copy.
    const drawn = await page.evaluate(() => ({
        frames: window.__lattePage.surface.frames,
        readbacks: window.__lattePage.surface.readbacks,
    }));
    check(results, "no frame was copied back through the CPU",
        drawn.frames > 0 && drawn.readbacks === 0, JSON.stringify(drawn));

    // --- resize and scale -------------------------------------------------
    // Both ways, and against the box the page gives the canvas rather than the
    // canvas's own: a canvas pinned at its first size agrees with itself
    // forever, which is how a frozen one read as correct here for a long time.
    const box = () => page.evaluate(() => {
        const element = window.__lattePage.element;
        const holder = element.parentElement;
        const seen = element.getBoundingClientRect();
        return {
            css: [Math.round(seen.width), Math.round(seen.height)],
            room: [holder.clientWidth, holder.clientHeight],
            backing: [element.width, element.height],
            scale: window.__lattePage.surface.scale,
        };
    });
    for (const [width, height, going] of [[600, 500, "smaller"], [1200, 900, "larger"]]) {
        await page.setViewportSize({ width, height });
        await page.waitForTimeout(160);
        const resized = await facts(page);
        check(results, `a resize ${going} did not break anything`, resized.error === "", resized.error);
        const seen = await box();
        check(results, `the canvas fills its box when the page gets ${going}`,
            Math.abs(seen.css[0] - seen.room[0]) <= 1 && Math.abs(seen.css[1] - seen.room[1]) <= 1,
            JSON.stringify(seen));
        check(results, `the backing store follows it ${going}`,
            Math.abs(seen.backing[0] - seen.css[0] * seen.scale) <= 1 &&
            Math.abs(seen.backing[1] - seen.css[1] * seen.scale) <= 1, JSON.stringify(seen));
    }

    // --- a lost GPU context ------------------------------------------------
    const recovered = await page.evaluate(async () => {
        const page_ = window.__lattePage;
        const was = page_.surface.revision;
        page_.contextLost();
        await new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done)));
        return {
            moved: page_.surface.revision > was,
            drawing: page_.surface.surface !== null,
            software: page_.surface.isSoftware,
            error: page_.lastError(),
        };
    });
    check(results, "a lost context is replaced and the scene repaints",
        recovered.moved && recovered.drawing, JSON.stringify(recovered));

    // --- teardown ----------------------------------------------------------
    const closed = await page.evaluate(() => {
        const page_ = window.__lattePage;
        page_.unmount();
        return {
            resources: page_.surface.resourceCount(),
            a11y: page_.semantics ? page_.semantics.count() : 0,
            editor: document.body.contains(page_.editing.element),
        };
    });
    check(results, "unmount released every graphics handle", closed.resources === 0, `${closed.resources} left`);
    check(results, "and every accessibility element", closed.a11y === 0, `${closed.a11y} left`);
    check(results, "and the editing element", closed.editor === false, "");

    await browser.close();
    return { results, problems };
}

async function main() {
    PORT = await listenOnAFreePort();
    let failures = 0;
    let ran = 0;
    const skipped = [];

    for (const name of wanted) {
        const engine = ENGINES[name];
        if (!engine) { skipped.push(`${name} (no such engine)`); continue; }
        let outcome;
        try {
            outcome = await run(name, engine);
        } catch (error) {
            if (/executable doesn't exist/i.test(String(error))) {
                skipped.push(`${name} (not installed)`);
                continue;
            }
            // A throw is a failure, not a skip: counting it as one is how a
            // check reports a crash as an absence.
            console.error(`FAIL ${name}: ${String(error).split("\n")[0]}`);
            failures++;
            ran++;
            continue;
        }
        ran++;
        for (const item of outcome.results) {
            if (item.ok) console.log(`ok ${name}/${item.name}`);
            else { console.error(`FAIL ${name}/${item.name}: ${item.detail}`); failures++; }
        }
        for (const problem of outcome.problems) {
            console.error(`FAIL ${name}: the page reported ${problem}`);
            failures++;
        }
    }

    server.close();
    for (const reason of skipped) console.log(`SKIP ${reason} — this engine proved nothing`);
    if (ran === 0) {
        console.error("no engine ran: every one was skipped, so this check proved nothing");
        process.exit(1);
    }
    if (failures) { console.error(`${failures} failure(s)`); process.exit(1); }
    console.log(`ui check passed across ${ran} engine(s)`);
}

main().catch((error) => { console.error(error); process.exit(1); });
