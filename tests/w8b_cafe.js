// tests/w8b_cafe.js — the shipped example, driven in real Chromium.
//
// Run by `w8b_cafe.sh`, which starts `examples/cafe/main.b -- serve 0` on a
// port the kernel chose and passes it in `W8B_CAFE_URL`.
//
// **What this asserts, and what it deliberately leaves to the example's own
// gate.** `examples/cafe/main.b -- check` already drives every route, the
// binding, the antiforgery and the circuit seam through espresso's `TestHost`,
// on both backends, against a golden. None of that is repeated here. What a
// `TestHost` cannot do is be a browser, so every check below is one of:
//
//   * the bytes on the wire — a real document, not a page body: a doctype, a
//     head, a stylesheet link and a `<script src>` that boots a circuit;
//   * the headers a browser ENFORCES — latte's own CSP, `nosniff`, `DENY`,
//     and the session cookie the circuit endpoint is about to require;
//   * the client script fetched from the asset route and actually RUN;
//   * a WebSocket leaving Chrome for `/_latte/ws`;
//   * a click on a child component reaching the server through a `Callback`
//     and coming back as markup in a real DOM;
//   * a form POST through the real antiforgery path, from a real form.
//
// Before this leg the cafe app had never been opened in a browser.

'use strict';

const { chromium } = require('playwright-core');

const url = process.env.W8B_CAFE_URL;
const executablePath = process.env.W8B_CAFE_CHROME || undefined;
if (!url) {
    console.error('W8B_CAFE_URL is not set');
    process.exit(2);
}
const base = url.replace(/\/$/, '');

let checks = 0;
let bad = 0;

function eq(name, got, want) {
    checks += 1;
    if (got === want) {
        console.log('ok ' + name);
    } else {
        bad += 1;
        console.log('FAIL ' + name);
        console.log('   got  ' + JSON.stringify(got));
        console.log('   want ' + JSON.stringify(want));
    }
}
function yes(name, got) { eq(name, got === true, true); }

/// Poll a page expression until it equals `want`, or give up. Never a fixed
/// sleep: one long enough to be safe on a loaded machine is a slow suite, one
/// short enough to be quick is a flake.
async function settle(page, fn, want, deadline = 15000) {
    const until = Date.now() + deadline;
    let last;
    for (;;) {
        last = await page.evaluate(fn);
        if (last === want) { return last; }
        if (Date.now() > until) { return last; }
        await page.waitForTimeout(25);
    }
}

async function main() {
    const browser = await chromium.launch({
        executablePath,
        args: ['--no-sandbox', '--disable-gpu'],
    });
    const context = await browser.newContext();
    const page = await context.newPage();

    const console_lines = [];
    page.on('console', m => console_lines.push(m.type() + ': ' + m.text()));
    page.on('pageerror', e => console_lines.push('pageerror: ' + e.message));

    const sockets = [];
    page.on('websocket', ws => {
        const seen = { url: ws.url(), sent: [], got: [], closed: false };
        ws.on('framesent', f => seen.sent.push(f.payload));
        ws.on('framereceived', f => seen.got.push(f.payload));
        ws.on('close', () => { seen.closed = true; });
        sockets.push(seen);
    });

    // How many page RENDERS the server will report. Counted here so the shell
    // leg can cross-check the app's own `CAFE-PAGES` against what the browser
    // asked for, rather than against a constant that would need editing every
    // time a navigation is added.
    let pageLoads = 0;

    // ---- 1. the document, as bytes ---------------------------------------
    //
    // Fetched with `fetch`, not rendered, so what is asserted is what the
    // server sent. The applier has not run and cannot have.
    const answer = await fetch(url);
    const shell = await answer.text();
    pageLoads += 1;
    eq('1.1 the menu page answers 200', answer.status, 200);
    yes('1.2 it is a DOCUMENT, not a page body',
        /^<!doctype html>/i.test(shell.trim()));
    yes('1.3 with a head and a title', shell.includes('<head>') && shell.includes('<title>'));
    yes('1.4 and a stylesheet link, because the CSP forbids an inline style',
        /<link[^>]+rel="stylesheet"/.test(shell));
    yes('1.5 the script tag boots a circuit off the asset route',
        shell.includes('src="/_latte/latte.js"') &&
        shell.includes('data-latte-boot') &&
        shell.includes('data-latte-ws="/_latte/ws"') &&
        shell.includes('data-latte-root="latte-root"'));
    yes('1.6 there is a #latte-root for it to mount into',
        shell.includes('id="latte-root"'));
    yes('1.7 no inline <script> block anywhere — the policy has no unsafe-inline',
        !/<script(?![^>]*\ssrc=)[^>]*>/i.test(shell));

    // ---- 2. the headers a browser enforces -------------------------------
    const csp = answer.headers.get('content-security-policy') || '';
    yes('2.1 a Content-Security-Policy is sent at all', csp.length > 0);
    yes('2.2 default-src is none, so anything unnamed is refused',
        csp.includes("default-src 'none'"));
    yes('2.3 script-src self, which is what makes /_latte/latte.js loadable',
        csp.includes("script-src 'self'"));
    yes('2.4 connect-src self, which is what makes the WebSocket openable',
        csp.includes("connect-src 'self'"));
    yes('2.5 and neither unsafe-inline nor unsafe-eval',
        !csp.includes('unsafe-inline') && !csp.includes('unsafe-eval'));
    eq('2.6 nosniff', answer.headers.get('x-content-type-options'), 'nosniff');
    eq('2.7 framing denied', answer.headers.get('x-frame-options'), 'DENY');
    const cookie = answer.headers.get('set-cookie') || '';
    yes('2.8 a session cookie is minted, HttpOnly',
        cookie.includes('latte_session=') && /httponly/i.test(cookie));

    // ---- 3. the asset route ----------------------------------------------
    //
    // `script-src 'self'` pointed at nothing until this route existed. A 404
    // here is a page whose client never runs, and the only symptom is a
    // console line nobody on the server ever sees.
    const client = await fetch(base + '/_latte/latte.js');
    eq('3.1 the client script is served', client.status, 200);
    yes('3.2 as JavaScript',
        (client.headers.get('content-type') || '').includes('javascript'));
    const clientText = await client.text();
    yes('3.3 and it is the real applier, not a placeholder',
        clientText.includes('latte') && clientText.length > 10000);

    // ---- 4. the page comes alive -----------------------------------------
    await page.goto(url, { waitUntil: 'domcontentloaded' });
    pageLoads += 1;
    const drinks = await settle(page,
        () => document.querySelectorAll('#drinks li.drink').length, 3);
    yes('4.1 the menu rendered its keyed list of drinks', drinks > 0);
    eq('4.2 exactly one WebSocket was opened', sockets.length, 1);
    yes('4.3 and it went to the circuit endpoint on this server',
        sockets.length === 1 && sockets[0].url === base.replace(/^http:/, 'ws:') + '/_latte/ws');
    yes('4.4 the server spoke first, with a hello',
        sockets.length === 1 && sockets[0].got.length > 0 &&
        String(sockets[0].got[0]).indexOf('"t":"hello"') >= 0);
    eq('4.5 nothing is picked yet',
       await page.textContent('#picked'), 'nothing picked yet');
    // The shell SERVER-RENDERS the page into `#latte-root`, so `#drinks` is in
    // the document before any socket opens. That means 4.1 does not prove the
    // circuit did anything — these two do. The applier keeps an
    // element -> logical-node WeakMap built as IT creates nodes, and the
    // delegated click listener walks up from `event.target` into that map; a
    // node the applier did not create carries no binds. So "the batch arrived
    // AND the applier replaced the server's markup with its own" is the whole
    // precondition for a click doing anything at all.
    yes('4.6 the browser answered the hello with an attach',
        sockets.length === 1 &&
        sockets[0].sent.some(f => String(f).indexOf('"t":"attach"') >= 0));
    yes('4.7 and the server sent a batch back',
        sockets.length === 1 &&
        sockets[0].got.some(f => String(f).indexOf('"t":"batch"') >= 0));
    // D5 is "replace on attach for v1": the batch carries the whole page, so
    // the server-rendered markup in `#latte-root` must be REPLACED by what the
    // applier builds, not joined by it. If both survive, the document holds two
    // copies of every element — and `#drinks` is an id selector, so it matches
    // the FIRST, which is the server's inert copy. A user clicks that one.
    const copies = await page.evaluate(() => ({
        roots: document.querySelectorAll('#latte-root').length,
        allDrinks: document.querySelectorAll('li.drink').length,
        firstDrinks: document.querySelectorAll('#drinks li.drink').length,
        pickedNodes: document.querySelectorAll('#picked').length,
    }));
    eq('4.8 the page appears ONCE in the document, not once from the shell and ' +
       'once from the applier', copies.allDrinks, copies.firstDrinks);
    eq('4.9 and there is one #picked, not two', copies.pickedNodes, 1);
    yes('4.10 the applier OWNS the drink buttons it is about to be clicked on ' +
        '(a server-rendered node it did not create carries no binds)',
        await page.evaluate(() => {
            var api = window.latte;
            if (!api || !api.current || !api.current.applier) { return false; }
            var map = api.current.applier.nodes;
            if (!map) { return false; }
            var buttons = document.querySelectorAll('#drinks li.drink button');
            if (buttons.length === 0) { return false; }
            for (var i = 0; i < buttons.length; i++) {
                if (!map.has(buttons[i])) { return false; }
            }
            return true;
        }));

    // ---- 5. a click on a CHILD component ---------------------------------
    //
    // The button lives in `Drink`, a child component, and its handler calls a
    // `Callback` the parent `Menu` handed down. So this is the whole chain:
    // a real click, an `ev` message on a real socket, a callback across a
    // component boundary, `notify()` marking the PARENT dirty, a re-render and
    // a diff, and markup back into a real DOM.
    console.log('   (nodes in the document: ' + JSON.stringify(copies) + ')');
    const firstDrink = await page.getAttribute('#drinks li.drink button', 'data-drink');
    yes('5.1 the drink buttons carry the key they were rendered with',
        typeof firstDrink === 'string' && firstDrink.length > 0);
    await page.click('#drinks li.drink button');
    eq('5.2 one click on a child component reached the server and came back',
       await settle(page, () => document.getElementById('picked').textContent,
                    'picked ' + firstDrink + ' (1)'),
       'picked ' + firstDrink + ' (1)');
    yes('5.3 the click left as an ev message',
        sockets[0].sent.some(f => String(f).indexOf('"t":"ev"') >= 0));

    // A SECOND drink, because one click proves the handler fired and two
    // prove the key reached it: a differ that ignored keys would show the
    // first drink's name again.
    const drinkKeys = await page.$$eval('#drinks li.drink button',
        ns => ns.map(n => n.getAttribute('data-drink')));
    if (drinkKeys.length > 1) {
        await page.click('#drinks li.drink:nth-child(2) button');
        eq('5.4 a different drink picks a DIFFERENT name, and the count moves',
           await settle(page, () => document.getElementById('picked').textContent,
                        'picked ' + drinkKeys[1] + ' (2)'),
           'picked ' + drinkKeys[1] + ' (2)');
    } else {
        eq('5.4 a different drink picks a DIFFERENT name, and the count moves',
           'the menu served fewer than two drinks', 'two drinks');
    }

    // ---- 6. the state is the server's ------------------------------------
    await page.reload({ waitUntil: 'domcontentloaded' });
    pageLoads += 1;
    eq('6.1 a reload gets a fresh circuit and a fresh page',
       await settle(page,
           () => { const n = document.getElementById('picked');
                   return n ? n.textContent : ''; },
           'nothing picked yet'),
       'nothing picked yet');
    eq('6.2 the browser opened a second socket', sockets.length, 2);

    // ---- 7. a real form POST through the real antiforgery path -----------
    //
    // A `<form method="post">` submitted by the browser, with the hidden token
    // the page rendered. `check` mode drives this through `TestHost`; nothing
    // has ever submitted it FROM a browser, where the cookie, the token field
    // and the origin all come from the browser's own machinery.
    await page.goto(base + '/order/4', { waitUntil: 'domcontentloaded' });
    pageLoads += 1;
    const token = await page.getAttribute('form input[type="hidden"]', 'value');
    yes('7.1 the order form carries an antiforgery token',
        typeof token === 'string' && token.length > 0);
    await page.fill('#name', '');
    await page.fill('#cups', '0');
    await page.click('#place');
    await page.waitForLoadState('domcontentloaded');
    pageLoads += 1;
    const problems = await page.$$eval('#problems li', ns => ns.map(n => n.textContent));
    yes('7.2 an empty order is REFUSED with problems, not accepted',
        problems.length > 0);
    await page.fill('#name', 'ada');
    await page.fill('#cups', '2');
    await page.click('#place');
    await page.waitForLoadState('domcontentloaded');
    pageLoads += 1;
    const placed = await page.textContent('#placed').catch(() => '');
    yes('7.3 and a good one is placed', typeof placed === 'string' && placed.length > 0 &&
        placed.indexOf('ada') >= 0);

    // ---- 8. nothing threw ------------------------------------------------
    //
    // A CSP violation, a script that failed to load, an applier that threw:
    // all three are a page that simply never changes, which reads exactly like
    // a server that never answered.
    eq('8.1 the page logged nothing at all', console_lines.join(' | '), '');

    if (bad > 0 && sockets.length > 0) {
        console.log('--- socket 1, as the browser saw it ---');
        console.log('   sent: ' + JSON.stringify(sockets[0].sent.slice(0, 4)));
        console.log('   got:  ' + JSON.stringify(
            sockets[0].got.slice(0, 3).map(f => String(f).slice(0, 2400))));
    }

    console.log('W8B-CAFE-JS-SOCKETS ' + sockets.length);
    console.log('W8B-CAFE-JS-PAGES ' + pageLoads);
    await browser.close();

    console.log('');
    console.log(checks + ' checks, ' + bad + ' bad');
    if (console_lines.length) {
        console.log('--- console ---');
        for (const line of console_lines) { console.log('   ' + line); }
    }
    process.exit(bad === 0 ? 0 : 1);
}

main().catch(err => {
    console.error('the cafe smoke threw: ' + (err && err.stack ? err.stack : err));
    process.exit(3);
});
