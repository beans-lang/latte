// tests/w8b_smoke.js — a Playwright smoke test over a real browser.
//
// Driven by `w8b_smoke.sh`, which starts `tests/_w8b_smoke_server.b` on a port
// the kernel chose and passes it in `W8B_SMOKE_URL`.
//
// **What this is for, and what it deliberately does not repeat.** The
// `browser-apply` leg already runs `js/latte.js` in headless Chrome against
// fixtures a Beans program printed into a file — 469 checks, and the strongest
// applier test in the repo. `tests/circuit_live.b` already runs a real espresso
// server on port 0 and drives it with a `std.websocket` client. Neither of them
// has a browser open a socket: `browser-apply` calls `applier.apply(batch)`
// with `batch` read out of a `<script>` tag, and `circuit_live` never loads a
// page. So everything BETWEEN the two is unproven — and it is not a small gap:
//
//   * the handshake a real browser sends, including the `Sec-WebSocket-Key`
//     dance and the `permessage-deflate` offer Chrome makes on its own;
//   * the `Origin` header, which only a browser sets and which
//     `EndpointOptions.origins` refuses by default — no test in this repo has
//     ever sent one;
//   * `latte.js`'s own boot path: reading `document.currentScript.dataset`,
//     building the socket URL from `location`, and mounting on `#latte-root`;
//   * a real `click` on a real button producing a real event message, rather
//     than a hand-built `{"t":"ev",…}` string;
//   * and the batch coming back through a real `WebSocket.onmessage` into the
//     real applier against a real DOM.
//
// Every assertion below is on one of those. Nothing here re-checks an edit
// kind, because `browser-apply` does that better and against an expected output.
//
// The checks print `ok`/`FAIL` lines and the process exits non-zero on the
// first failure with the count, so the shell leg can quote it.

'use strict';

const { chromium } = require('playwright-core');

const url = process.env.W8B_SMOKE_URL;
const executablePath = process.env.W8B_SMOKE_CHROME || undefined;
if (!url) {
    console.error('W8B_SMOKE_URL is not set');
    process.exit(2);
}

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
/// sleep: a sleep long enough to be safe on a loaded machine is a slow suite,
/// and one short enough to be quick is a flake. `deadline` is generous because
/// three other lanes may be compiling on this machine.
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

    // Everything the page tells the console, kept. A `latte.js` that threw is
    // otherwise a page that simply never changes, which reads like a server
    // that never answered.
    const console_lines = [];
    page.on('console', m => console_lines.push(m.type() + ': ' + m.text()));
    page.on('pageerror', e => console_lines.push('pageerror: ' + e.message));

    // The sockets, as the browser saw them. This is the whole point of the
    // suite: a URL here is proof that a WebSocket left Chrome.
    const sockets = [];
    page.on('websocket', ws => {
        const seen = { url: ws.url(), sent: [], got: [], closed: false };
        ws.on('framesent', f => seen.sent.push(f.payload));
        ws.on('framereceived', f => seen.got.push(f.payload));
        ws.on('close', () => { seen.closed = true; });
        sockets.push(seen);
    });

    // ---- 1. the shell, before any of it runs ----------------------------
    //
    // Fetched as bytes, not as a rendered page, so what is asserted is what
    // the server sent — the applier has not run yet and cannot have.
    const shell = await (await fetch(url)).text();
    yes('1.1 the shell carries a circuit id',
        /data-latte-circuit="[0-9a-f]{64}"/.test(shell));
    yes('1.2 the shell loads the real applier',
        shell.includes('<script src="/latte.js"'));
    yes('1.3 #latte-root is EMPTY in the served HTML, so anything in it later came off the socket',
        shell.includes('<div id="latte-root"></div>'));
    yes('1.4 the shell contains no board markup at all',
        !shell.includes('id="board"'));

    // ---- 2. the socket -------------------------------------------------
    await page.goto(url, { waitUntil: 'domcontentloaded' });
    const built = await settle(page, () => !!document.getElementById('board'), true);
    yes('2.1 the page mounted a board that was not in the HTML', built === true);
    eq('2.2 exactly one WebSocket was opened', sockets.length, 1);
    yes('2.3 and it went to the circuit endpoint on this server',
        sockets.length === 1 &&
        sockets[0].url === url.replace(/^http:/, 'ws:').replace(/\/$/, '') + '/_latte/ws');
    yes('2.4 the server spoke first, with a hello',
        sockets.length === 1 && sockets[0].got.length > 0 &&
        String(sockets[0].got[0]).indexOf('"t":"hello"') >= 0);
    yes('2.5 the browser answered with an attach carrying the shell id',
        sockets.length === 1 &&
        sockets[0].sent.some(f => String(f).indexOf('"t":"attach"') >= 0));

    // ---- 3. the first batch built the page ------------------------------
    eq('3.1 the count paragraph came off the wire',
       await page.textContent('#count'), 'count 0');
    eq('3.2 so did the greeting', await page.textContent('#greeting'), 'hello ');
    eq('3.3 and all five rows',
       (await page.$$eval('#rows li', ns => ns.map(n => n.textContent))).join(','),
       'alpha,bravo,charlie,delta,echo');

    // ---- 4. a real click round-trips ------------------------------------
    await page.click('#bump');
    eq('4.1 one click, one increment',
       await settle(page, () => document.getElementById('count').textContent, 'count 1'),
       'count 1');
    await page.click('#bump');
    await page.click('#bump');
    eq('4.2 three clicks, three increments',
       await settle(page, () => document.getElementById('count').textContent, 'count 3'),
       'count 3');
    yes('4.3 the click left as an ev message',
        sockets[0].sent.filter(f => String(f).indexOf('"t":"ev"') >= 0).length >= 3);

    // ---- 5. a real keystroke binds --------------------------------------
    await page.fill('#name', 'chai');
    eq('5.1 the bound input reached the server and came back',
       await settle(page, () => document.getElementById('greeting').textContent, 'hello chai'),
       'hello chai');

    // ---- 6. a keyed reorder MOVES the DOM nodes -------------------------
    //
    // The claim under test is the one HTML alone cannot tell you: a differ
    // that rebuilt the list would serialize the same five rows. So each `li`
    // is stamped with an expando before the reorder and read back after — an
    // expando does not survive `createElement`, so a stamp that is still on
    // the node in its new position is proof the node itself moved.
    await page.evaluate(() => {
        const rows = document.querySelectorAll('#rows li');
        for (let i = 0; i < rows.length; i++) { rows[i].__w8b = 'stamp' + i; }
    });
    await page.click('#rotate');
    eq('6.1 the rows rotated',
       await settle(page,
           () => Array.from(document.querySelectorAll('#rows li'))
                      .map(n => n.textContent).join(','),
           'bravo,charlie,delta,echo,alpha'),
       'bravo,charlie,delta,echo,alpha');
    const stamps = await page.evaluate(() =>
        Array.from(document.querySelectorAll('#rows li'))
             .map(n => (n.__w8b === undefined ? 'REBUILT' : n.__w8b)));
    eq('6.2 every node is the SAME node, moved, not a rebuilt one',
       stamps.join(','), 'stamp1,stamp2,stamp3,stamp4,stamp0');

    // ---- 7. the state is the server's, not the page's -------------------
    //
    // A reload throws the DOM away. The counter is a field on a component the
    // server owns, and the page it serves is a new circuit — so the count MUST
    // come back at zero. If it came back at 3, the number was living in the
    // browser and the whole update model is a lie.
    await page.reload({ waitUntil: 'domcontentloaded' });
    eq('7.1 a reload gets a fresh circuit and a fresh page',
       await settle(page,
           () => { const n = document.getElementById('count');
                   return n ? n.textContent : ''; },
           'count 0'),
       'count 0');
    eq('7.2 the browser opened a second socket', sockets.length, 2);

    // ---- 8. the timer, and why a fake one hid it for so long ------------
    //
    // This leg found the bug this check now guards. `latte.js` used to keep
    // the browser's timer as a bare reference —
    //
    //     this.setTimeout = options.setTimeout ||
    //         (typeof setTimeout !== 'undefined' ? setTimeout : null);
    //
    // — and then call it as `this.setTimeout(fn, ms)`, which hands `window`'s
    // own method a `Circuit` as its receiver; every browser refuses that with
    // `TypeError: Illegal invocation`. `tests/js_apply.js` injects a fake
    // timer, so the only way to reach the real one is a real page in a real
    // browser, which is this leg and nothing else in the repo.
    //
    // What it cost, exactly, while it stood: `armFence` and `retry` are the
    // two callers. The seen fence never armed — `outstanding` grew and a
    // stalled server was never noticed — and `retry` never ran, so a dropped
    // socket was never reconnected. Both threw out of an event handler, so
    // 8.2 counted seven uncaught pageerrors in one run. It is fixed on main
    // (`js/latte.js` now wraps both in a function of its own); if 8.1 goes
    // red again with `Illegal invocation`, that fix has been reverted.
    const timer = await page.evaluate(() => {
        if (!window.latte || !window.latte.current) { return 'no circuit'; }
        try {
            const id = window.latte.current.setTimeout(function () {}, 0);
            window.latte.current.clearTimeout(id);
            return 'ok';
        } catch (err) { return String(err && err.message ? err.message : err); }
    });
    eq('8.1 the circuit can arm its own timer (a bare window.setTimeout called ' +
       'with the Circuit as receiver is Illegal invocation)', timer, 'ok');
    eq('8.2 the page logged nothing at all', console_lines.join(' | '), '');

    // ---- 9. a dropped socket comes back ---------------------------------
    //
    // `circuit_live.b` § 8 proves reconnect-and-replay for a Beans client.
    // A browser is the case that ships. The drop
    // is done the way a real one happens — the socket goes, nothing else — and
    // then the page must reconnect on its own and still be live.
    const before = sockets.length;
    await page.evaluate(() => { window.latte.current.socket.close(); });
    let reconnected = false;
    {
        // `latte.js`'s own backoff starts at a few hundred ms and grows; this
        // waits well past the first several attempts before calling it dead.
        const until = Date.now() + 12000;
        while (Date.now() < until) {
            if (sockets.length > before) { reconnected = true; break; }
            await page.waitForTimeout(50);
        }
    }
    yes('9.1 the page opened a new socket after the old one closed', reconnected);
    if (reconnected) {
        await page.click('#bump');
        eq('9.2 and the page is live again on the circuit it resumed',
           await settle(page, () => document.getElementById('count').textContent,
                        'count 1'),
           'count 1');
    } else {
        eq('9.2 and the page is live again on the circuit it resumed',
           'no reconnect was attempted', 'count 1');
    }

    // ---- 10. the session the handshake carried, and the refusal ---------
    //
    // W4 bound a circuit to a session: `CircuitEndpoint.upgrade` answers 403
    // to a handshake with no `latte_session` cookie, because a circuit id is
    // only worth binding if it is bound to something, and `""` shared by
    // everyone is not something. Every check above depends on that having
    // gone the other way — the browser carried the cookie the page route set
    // through a WebSocket handshake, which nothing else in this repo does;
    // `tests/w4_upgrade.b` asserts the same rule with a hand-built client.
    //
    // So this is the negative half of the pair, from a real browser. A fresh
    // context has no cookie jar; it loads `/no-session`, which is served from
    // this same origin and deliberately sets nothing, and opens the socket
    // from there. Same origin, same endpoint, one difference: no session.
    //
    // Without it, `anonymous_circuits = true` could be set on the smoke
    // server one day to make something else go green and every other check
    // here would stay green with the binding gone.
    //
    // A browser cannot read the 403 or its body — the WebSocket API gives an
    // error event and nothing else — so WHERE it was refused is pinned by the
    // server's own arithmetic instead, in `w8b_smoke.sh`: espresso counts an
    // upgrade the moment the route matches, so `upgrades` must be one MORE
    // than the sockets the browser opened, `circuits` must equal them, and
    // `faults` must be 0. Route matched, no circuit opened, nothing broke.
    const naked = await browser.newContext();
    const nakedPage = await naked.newPage();
    const nakedSockets = [];
    nakedPage.on('websocket', ws => nakedSockets.push(ws));
    await nakedPage.goto(url + 'no-session', { waitUntil: 'domcontentloaded' });
    const refusal = await nakedPage.evaluate((wsUrl) => new Promise((resolve) => {
        let sock;
        try { sock = new WebSocket(wsUrl); }
        catch (err) { resolve('threw: ' + err); return; }
        const done = setTimeout(() => resolve('neither opened nor closed'), 10000);
        sock.onopen = () => { clearTimeout(done); resolve('opened'); };
        sock.onerror = () => { clearTimeout(done); resolve('refused'); };
        sock.onclose = () => { clearTimeout(done); resolve('refused'); };
    }), url.replace(/^http:/, 'ws:').replace(/\/$/, '') + '/_latte/ws');
    eq('10.1 a browser on this origin with no session cookie is refused the circuit',
       refusal, 'refused');
    eq('10.2 and the browser really did put a handshake on the wire for it',
       nakedSockets.length, 1);
    await naked.close();

    // Two counts, not one. espresso increments `upgrades` when the route
    // matches, BEFORE the handler decides — so the refused handshake in § 10
    // is an upgrade that never became a circuit, and the shell leg needs both
    // numbers to cross-check the server's totals against the browser's.
    console.log('W8B-SMOKE-JS-SOCKETS ' + sockets.length);
    console.log('W8B-SMOKE-JS-REFUSED ' + nakedSockets.length);
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
    console.error('the smoke threw: ' + (err && err.stack ? err.stack : err));
    process.exit(3);
});
