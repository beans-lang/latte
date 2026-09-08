// tests/js_apply.js — gate 3's browser half, and the only place latte.js runs.
//
// PLAN.md gate 3: "a reference applier in Beans over thousands of random trees
// and mutations, **and** the real `latte.js` applier over a small DOM, both
// required to land on the serializer's HTML of the new tree. A text test proves
// the encoder consistent with itself; this proves it means the same thing in a
// browser."
//
// It runs under headless Chrome, loaded as a `<script src>` beside
// `js/latte.js` and the fixtures `tests/js_cases.b` printed — no inline script,
// because the CSP latte ships forbids one and a harness that needs a weaker
// rule than the product is not testing the product. `test.sh` extracts what it
// prints between the two markers and diffs it against `tests/js_apply.out`.
//
// Four parts, in this order:
//
//   § 1  every generated batch, COMPARED against the Beans applier: the frame
//        dump byte for byte, and the DOM against the serializer's HTML.
//   § 2  the applier contract — a kind-mismatched edit is dropped, one fault is
//        recorded, the rest of the stream applies. Each with a positive control.
//   § 3  the two tables latte.js reimplements from Beans: the event families
//        and the navigation rule.
//   § 4  the circuit against a stub socket: hello, attach, batch, ack, real
//        DOM events through the delegated listeners, JS interop, nav, bye.
(function () {
    'use strict';

    var lines = [];
    var checks = 0;
    var bad = 0;

    function say(text) { lines.push(text); }

    // A throw anywhere below would otherwise leave the page with no verdict
    // block at all, and `test.sh` would report "the harness printed nothing",
    // which is true and useless. This turns it into a line that names the
    // throw and the check it died on.
    var emitted = false;
    function emit() {
        if (emitted) { return; }
        emitted = true;
        var pre = document.createElement('pre');
        pre.id = 'latte-verdict';
        pre.textContent = '@@LATTE-BEGIN@@\n' + lines.join('\n') + '\n@@LATTE-END@@';
        document.body.appendChild(pre);
    }
    window.addEventListener('error', function (event) {
        say('FAIL the harness threw: ' + (event.message || event.error));
        say((checks + 1) + ' checks, ' + (bad + 1) + ' bad');
        emit();
    });

    // Nothing in this harness may navigate. A link latte.js DECLINES to
    // intercept is left to the browser, which is the correct behaviour and
    // which, in a test page, replaces the document before the verdict is
    // printed — headless Chrome followed `//evil.example/x` and every check
    // above it was lost. This listener sits on `document`, so it runs AFTER
    // latte's listener on the host in the bubble phase: it records whether
    // latte prevented the default and then prevents it regardless.
    var lastClickPrevented = null;
    document.addEventListener('click', function (event) {
        lastClickPrevented = event.defaultPrevented;
        event.preventDefault();
    }, false);

    function eq(name, got, want) {
        checks += 1;
        if (got === want) {
            say('ok ' + name);
            return true;
        }
        bad += 1;
        say('FAIL ' + name);
        say('   got  ' + JSON.stringify(got));
        say('   want ' + JSON.stringify(want));
        return false;
    }

    function eqJson(name, got, want) {
        return eq(name, JSON.stringify(got), JSON.stringify(want));
    }

    // Chrome's HTML serializer and frames.b's escaper disagree about `'` and
    // U+00A0 in an attribute value, and about `<` in one. Those are escaping
    // dialects, not trees, and gate 3 asks whether the two mean the same thing
    // to a browser — so both sides are round-tripped through the browser's own
    // parser and the two normal forms are compared. A `<template>` is used
    // because it is the one element whose innerHTML parses in a context that
    // accepts anything, so a `<tr>` survives.
    function normalize(html) {
        var holder = document.createElement('template');
        holder.innerHTML = html;
        return holder.innerHTML;
    }

    var hosts = 0;
    function freshHost() {
        hosts += 1;
        var host = document.createElement('div');
        host.id = 'host' + hosts;
        document.body.appendChild(host);
        return host;
    }

    function caseNamed(name) {
        for (var i = 0; i < LATTE_CASES.length; i++) {
            if (LATTE_CASES[i].name === name) { return LATTE_CASES[i]; }
        }
        return null;
    }

    // =================================================== § 1 generated cases

    say('=== 1. every generated batch, against the Beans applier');
    for (var c = 0; c < LATTE_CASES.length; c++) {
        var kase = LATTE_CASES[c];
        var host = freshHost();
        var applier = new latte.Applier({ document: document, host: host });
        for (var s = 0; s < kase.steps.length; s++) {
            var step = kase.steps[s];
            var label = kase.name + ' ' + (s + 1);
            applier.apply(step.b);
            // The strongest of the three: the logical TREE the applier
            // reconstructed, byte for byte, not a string that looks right.
            eq(label + ' dump', applier.dump(), step.d);
            eq(label + ' html', normalize(host.innerHTML), normalize(step.h));
            // The Beans applier's own HTML against the serializer's, so a
            // mismatch above says WHICH of the two the browser disagrees with.
            eq(label + ' beans-self', normalize(step.a), normalize(step.h));
            eq(label + ' faults', applier.faults.join('\n'), step.f.join('\n'));
        }
        host.parentNode.removeChild(host);
    }

    // =================================================== § 2 the contract
    //
    // lanes/W5.md § "THE APPLIER CONTRACT". The base tree holds one child of
    // every kind — 0 element, 1 text, 2 markup, 3 region, 4 fragment,
    // 5 boundary, 6 mount — and it is taken from the fixtures rather than
    // written here, so the two halves cannot drift on the shape either.

    var BASE_CASE = caseNamed('control-good-edits');
    var BASE_BATCH = BASE_CASE.steps[0].b;
    var BASE_HTML = BASE_CASE.steps[0].h;

    function probeBatch(edits) {
        return { t: 'batch', b: 2, r: BASE_BATCH.r, u: [{ c: 0, e: edits }], d: [] };
    }

    // name, the edits, the faults the contract fixes, and whether the DOM must
    // be untouched. Every refusal is followed by a good edit in the SAME
    // stream, whose effect proves the rest of the stream applied.
    var CONTRACT = [
        { name: 'set_text-at-element',
          edits: [['ut', 0, 'X'], ['ut', 1, 'after']],
          faults: ['component 0: set_text 0 needs a text node, not a element node'] },
        { name: 'set_text-at-markup',
          edits: [['ut', 2, '<img src=x onerror=alert(1)>'], ['ut', 1, 'after']],
          faults: ['component 0: set_text 2 needs a text node, not a markup node'] },
        { name: 'set_text-at-region',
          edits: [['ut', 3, 'X'], ['ut', 1, 'after']],
          faults: ['component 0: set_text 3 needs a text node, not a region node'] },
        { name: 'set_text-at-fragment',
          edits: [['ut', 4, 'X'], ['ut', 1, 'after']],
          faults: ['component 0: set_text 4 needs a text node, not a fragment node'] },
        { name: 'set_text-at-boundary',
          edits: [['ut', 5, 'X'], ['ut', 1, 'after']],
          faults: ['component 0: set_text 5 needs a text node, not a boundary node'] },
        { name: 'set_text-at-mount',
          edits: [['ut', 6, 'X'], ['ut', 1, 'after']],
          faults: ['component 0: set_text 6 needs a text node, not a mount node'] },

        { name: 'set_markup-at-text',
          edits: [['um', 1, '<img src=x onerror=alert(1)>'], ['ut', 1, 'after']],
          faults: ['component 0: set_markup 1 needs a markup node, not a text node'] },
        { name: 'set_markup-at-element',
          edits: [['um', 0, '<i>x</i>'], ['ut', 1, 'after']],
          faults: ['component 0: set_markup 0 needs a markup node, not a element node'] },
        { name: 'set_markup-at-mount',
          edits: [['um', 6, '<i>x</i>'], ['ut', 1, 'after']],
          faults: ['component 0: set_markup 6 needs a markup node, not a mount node'] },

        { name: 'step_in-at-text',
          edits: [['si', 1], ['so'], ['ut', 1, 'after']],
          faults: ['component 0: step_in 1 needs a container node, not a text node'] },
        { name: 'step_in-at-markup',
          edits: [['si', 2], ['so'], ['ut', 1, 'after']],
          faults: ['component 0: step_in 2 needs a container node, not a markup node'] },

        // The three list edits, reached by stepping into a leaf. That descent
        // is refused too, so each of these carries two faults — which is the
        // whole reason `step_in` descends into the node rather than into a
        // placeholder: with a placeholder these three refusals could never
        // fire at all.
        { name: 'insert-at-text',
          edits: [['si', 1], ['in', 0, 4], ['so'], ['ut', 1, 'after']],
          faults: ['component 0: step_in 1 needs a container node, not a text node',
                   'component 0: insert needs a container node, not a text node'] },
        { name: 'remove-at-text',
          edits: [['si', 1], ['rm', 0], ['so'], ['ut', 1, 'after']],
          faults: ['component 0: step_in 1 needs a container node, not a text node',
                   'component 0: remove needs a container node, not a text node'] },
        { name: 'relocate-at-markup',
          edits: [['si', 2], ['mv', 0, 0], ['so'], ['ut', 1, 'after']],
          faults: ['component 0: step_in 2 needs a container node, not a markup node',
                   'component 0: relocate needs a container node, not a markup node'] },

        // The five attribute and handler edits, which need an element. The
        // root is a mount, so the first of these needs no `step_in` at all.
        { name: 'set_attr-at-mount-root',
          edits: [['sa', 9, 'class', 'x'], ['ut', 1, 'after']],
          faults: ['component 0: set_attr needs a element node, not a mount node'] },
        { name: 'set_flag-at-region',
          edits: [['si', 3], ['sf', 9, 'hidden', true], ['so'], ['ut', 1, 'after']],
          faults: ['component 0: set_flag needs a element node, not a region node'] },
        { name: 'remove_attr-at-fragment',
          edits: [['si', 4], ['ra', 9, 'id'], ['so'], ['ut', 1, 'after']],
          faults: ['component 0: remove_attr needs a element node, not a fragment node'] },
        { name: 'set_handler-at-boundary',
          edits: [['si', 5], ['sh', 9, 'click', 3], ['so'], ['ut', 1, 'after']],
          faults: ['component 0: set_handler needs a element node, not a boundary node'] },
        { name: 'remove_handler-at-mount',
          edits: [['si', 6], ['rh', 9, 'click'], ['so'], ['ut', 1, 'after']],
          faults: ['component 0: remove_handler needs a element node, not a mount node'] },

        // Two faults latte.js has that apply.b cannot need: `setAttribute`
        // throws on an illegal name, and the JSON edit array is untyped.
        { name: 'refused-attribute-name',
          edits: [['si', 0], ['sa', 9, '__proto__', 'x'], ['so'], ['ut', 1, 'after']],
          faults: ['component 0: "__proto__" is not a usable attribute name'] },
        { name: 'unsafe-attribute-name',
          edits: [['si', 0], ['sa', 9, 'a b', 'x'], ['so'], ['ut', 1, 'after']],
          faults: ['component 0: "a b" is not a usable attribute name'] },
        { name: 'unknown-opcode',
          edits: [['zz', 1], ['ut', 1, 'after']],
          faults: ['component 0: unknown edit "zz"'] }
    ];

    say('');
    say('=== 2. the applier contract: a kind-mismatched edit is dropped');
    for (var p = 0; p < CONTRACT.length; p++) {
        var probe = CONTRACT[p];
        var phost = freshHost();
        var papplier = new latte.Applier({ document: document, host: phost });
        papplier.apply(BASE_BATCH);
        eq(probe.name + ' base clean', papplier.faults.join('\n'), '');
        papplier.apply(probeBatch(probe.edits));
        eq(probe.name + ' fault', papplier.faults.join('\n'), probe.faults.join('\n'));
        // The rest of the stream applied: the good edit after the refused one
        // is the last edit of every probe and it changes text node 1.
        eq(probe.name + ' stream continued',
           phost.innerHTML, normalize(BASE_HTML).replace('plain', 'after'));
        phost.parentNode.removeChild(phost);
    }

    // The security half, stated as itself rather than left to be inferred from
    // a fault count. `set_markup` at a text node is raw HTML written where
    // escaped text was — the XSS in THIS half — and `set_text` at a raw node
    // is the one W1 found in the Beans half.
    say('');
    say('=== 2b. the two shapes that are XSS if the kind check is not there');
    var xhost = freshHost();
    var xapplier = new latte.Applier({ document: document, host: xhost });
    xapplier.apply(BASE_BATCH);
    xapplier.apply(probeBatch([['um', 1, '<img src=x onerror=window.LATTE_PWNED=1>']]));
    eq('set_markup at a text node injected no element',
       xhost.getElementsByTagName('img').length, 0);
    eq('set_markup at a text node left the text alone',
       xhost.innerHTML.indexOf('plain') >= 0, true);
    xapplier.apply(probeBatch([['ut', 2, '<img src=x onerror=window.LATTE_PWNED=1>']]));
    eq('set_text at a raw node injected no element',
       xhost.getElementsByTagName('img').length, 0);
    eq('set_text at a raw node left the markup alone',
       xhost.innerHTML.indexOf('<b>raw</b>') >= 0, true);
    eq('nothing ran', typeof window.LATTE_PWNED, 'undefined');
    xhost.parentNode.removeChild(xhost);

    // The positive controls: the same five opcodes, aimed at the right kind,
    // must be ACCEPTED and must do something. Without these, "refused" cannot
    // be told from "refused earlier, for a different reason" (RULES.md).
    say('');
    say('=== 2c. the positive controls: the same opcodes aimed at the right kind');
    var chost = freshHost();
    var capplier = new latte.Applier({ document: document, host: chost });
    capplier.apply(BASE_BATCH);
    capplier.apply(probeBatch([
        ['ut', 1, 'TEXT'],
        ['um', 2, '<i>MARKUP</i>'],
        ['si', 0], ['sa', 9, 'class', 'ELEM'], ['sf', 10, 'hidden', true],
        ['sh', 11, 'click', 5], ['so'],
        ['si', 3], ['in', 1, 4], ['mv', 1, 0], ['rm', 1], ['so']
    ]));
    eq('controls raised no fault', capplier.faults.join('\n'), '');
    say('   html ' + chost.innerHTML);
    chost.parentNode.removeChild(chost);

    // =================================================== § 3 the two tables

    say('');
    say('=== 3. the tables latte.js reimplements from Beans');
    eqJson('event names', latte.eventNames, LATTE_EVENTS.names);
    var captures = [];
    for (var e = 0; e < latte.eventNames.length; e++) {
        if (latte.eventCaptures(latte.eventNames[e])) { captures.push(latte.eventNames[e]); }
    }
    eqJson('capture-phase events', captures, LATTE_EVENTS.captures);
    eqJson('the capture list latte.js registers from', latte.captureEvents,
           LATTE_EVENTS.captures);
    var navBad = 0;
    for (var n = 0; n < LATTE_NAV.length; n++) {
        var url = LATTE_NAV[n][0];
        var want = LATTE_NAV[n][1];
        if (latte.navTargetIsLocal(url) !== want) {
            navBad += 1;
            say('FAIL nav ' + JSON.stringify(url) + ': js says ' +
                latte.navTargetIsLocal(url) + ', beans says ' + want);
        }
    }
    eq('the navigation rule agrees on all ' + LATTE_NAV.length + ' targets', navBad, 0);

    // The two wire coercions. Pure functions, and the reason they exist is
    // that wire.b REFUSES what they prevent: a fraction or an exponent, and a
    // lone surrogate. Either one ends the circuit with a `bye protocol`.
    eq('wireInt truncates a fractional coordinate', latte.wireInt(12.7), 12);
    eq('wireInt truncates a negative one', latte.wireInt(-12.7), -12);
    eq('wireInt clamps past the exactly-representable range',
       latte.wireInt(1e21), 9007199254740991);
    eq('wireInt answers 0 for NaN', latte.wireInt(NaN), 0);
    eq('wireInt answers 0 for Infinity', latte.wireInt(Infinity), 0);
    eq('wireText keeps a well-formed pair', latte.wireText('a😀b'),
       'a😀b');
    eq('wireText repairs a high surrogate with no low',
       latte.wireText('a\uD800b'), 'a�b');
    eq('wireText repairs a low surrogate with no high',
       latte.wireText('a\uDC00b'), 'a�b');
    eq('wireText repairs a high surrogate at the end',
       latte.wireText('a\uD800'), 'a�');

    // =================================================== § 4 the circuit

    say('');
    say('=== 4. the circuit, against a stub socket');

    function FakeSocket() {
        this.readyState = 1;
        this.sent = [];
        this.closed = false;
        this.onmessage = null;
        this.onclose = null;
        this.onerror = null;
    }
    FakeSocket.prototype.send = function (text) { this.sent.push(JSON.parse(text)); };
    FakeSocket.prototype.close = function () { this.closed = true; this.readyState = 3; };

    var CIRCUIT_ID = '0123456789abcdef0123';

    // The clock and the timer queue are FAKE, and that is the point: the
    // fence deadline (§ 5) is a property of elapsed time, and a gate that
    // asserted it by really waiting would be slow, flaky, and unable to say
    // which millisecond mattered. `advance` is the only thing that moves time
    // here, so every timer that fires does so because a check asked it to.
    function newCircuit(options) {
        options = options || {};
        var host = options.host || freshHost();
        var sockets = [];
        var clock = { t: 1000, next: 1 };
        var timers = [];
        var errors = [];
        var stalls = [];
        var circuit = new latte.Circuit({
            url: 'ws://localhost/_latte/ws',
            id: CIRCUIT_ID,
            document: document,
            host: host,
            enhanceNav: options.enhanceNav,
            answerMs: options.answerMs,
            // The animation frame, injected for the same reason the clock is:
            // the scroll reporter coalesces to one message per frame, and a
            // gate that waited for a real frame could not say which frame it
            // was waiting for.
            schedule: options.schedule,
            open: function () {
                var made = new FakeSocket();
                sockets.push(made);
                return made;
            },
            now: function () { return clock.t; },
            setTimeout: function (fn, ms) {
                var id = clock.next;
                clock.next += 1;
                timers.push({ id: id, at: clock.t + ms, fn: fn });
                return id;
            },
            clearTimeout: function (id) {
                for (var i = 0; i < timers.length; i++) {
                    if (timers[i].id === id) { timers.splice(i, 1); return; }
                }
            },
            onstall: function (head) { stalls.push(head); },
            log: { error: function (text) { errors.push(text); },
                   warn: function () {} }
        });
        circuit.start();
        var rig = { circuit: circuit, host: host, sockets: sockets,
                    socket: sockets[sockets.length - 1],
                    clock: clock, timers: timers, errors: errors, stalls: stalls };
        rig.advance = function (ms) {
            clock.t += ms;
            // Fire in due order, and take each one off the queue BEFORE
            // calling it, because a handler may arm another.
            for (var guard = 0; guard < 100; guard++) {
                var due = -1;
                for (var i = 0; i < timers.length; i++) {
                    if (timers[i].at <= clock.t &&
                        (due < 0 || timers[i].at < timers[due].at)) { due = i; }
                }
                if (due < 0) { return; }
                var timer = timers[due];
                timers.splice(due, 1);
                timer.fn();
            }
        };
        rig.current = function () { return sockets[sockets.length - 1]; };
        return rig;
    }

    function hello(rig, version) {
        rig.socket.onmessage({ data: JSON.stringify({
            t: 'hello', v: version === undefined ? 1 : version,
            c: CIRCUIT_ID, mx: 65536 }) });
    }

    function feed(rig, message) {
        rig.socket.onmessage({ data: JSON.stringify(message) });
    }

    // --- the handshake ---
    var rig = newCircuit();
    eq('the socket is open before hello', rig.socket.sent.length, 0);
    hello(rig);
    eqJson('hello is answered with attach', rig.socket.sent[0],
           { t: 'attach', c: CIRCUIT_ID, u: location.pathname + location.search,
             n: 1 });

    // --- a batch, applied and acked ---
    var pageBatch = caseNamed('page').steps[0].b;
    feed(rig, pageBatch);
    eqJson('a batch is acked', rig.socket.sent[1], { t: 'ack', b: 1 });
    eq('the batch reached the DOM',
       normalize(rig.host.innerHTML), normalize(caseNamed('page').steps[0].h));

    // --- a click, through the delegated listener ---
    var wrap = rig.host.querySelector('#wrap');
    wrap.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true,
                                                 clientX: 5, clientY: 7, button: 0 }));
    eqJson('a click sends the slot id the batch bound',
           rig.socket.sent[2],
           { t: 'ev', h: 1, k: 'click', p: { b: 0, x: 5, y: 7 }, n: 2 });

    // --- a click on a descendant with no handler walks up to the one that has ---
    var inner = rig.host.querySelector('p');
    inner.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true,
                                                  clientX: 1, clientY: 2, button: 0 }));
    eqJson('a click inside walks up to the nearest bound element',
           rig.socket.sent[3],
           { t: 'ev', h: 1, k: 'click', p: { b: 0, x: 1, y: 2 }, n: 3 });

    // --- an input event reads the control's live value ---
    var field = rig.host.querySelector('input[name=q]');
    field.value = 'edited';
    field.dispatchEvent(new InputEvent('input', { bubbles: true }));
    eqJson('an input event carries the value and the checked flag',
           rig.socket.sent[4],
           { t: 'ev', h: 2, k: 'input', p: { v: 'edited', c: false }, n: 4 });

    // --- THE NO-CACHE RULE. The same element, a new handler id. ---
    feed(rig, { t: 'batch', b: 2, r: [], d: [],
                u: [{ c: 0, e: [['si', 0], ['sh', 5, 'click', 99], ['so']] }] });
    wrap.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true,
                                                 clientX: 0, clientY: 0, button: 0 }));
    eqJson('a rebound handler sends the NEW id, not the one from the first batch',
           rig.socket.sent[6],
           { t: 'ev', h: 99, k: 'click', p: { b: 0, x: 0, y: 0 }, n: 5 });

    // --- a removed handler sends nothing at all ---
    var before = rig.socket.sent.length;
    feed(rig, { t: 'batch', b: 3, r: [], d: [],
                u: [{ c: 0, e: [['si', 0], ['rh', 5, 'click'], ['so']] }] });
    wrap.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }));
    eq('a click with no handler bound sends nothing',
       rig.socket.sent.length, before + 1);
    eqJson('and the only thing sent was the ack', rig.socket.sent[before],
           { t: 'ack', b: 3 });

    // --- the four events that do not bubble, through the capture phase ---
    var caphost = newCircuit();
    hello(caphost);
    feed(caphost, {
        t: 'batch', b: 1, d: [],
        r: [['o', 0, 'div'], ['h', 1, 'focus', 4], ['h', 2, 'mouseenter', 5],
            ['h', 3, 'keydown', 6], ['o', 4, 'input'], ['z'], ['z']],
        u: [{ c: 0, e: [['in', 0, 0]] }]
    });
    var box = caphost.host.querySelector('div');
    var inp = caphost.host.querySelector('input');
    inp.dispatchEvent(new FocusEvent('focus', { bubbles: false }));
    eqJson('focus does not bubble and is still delivered', last(caphost.socket.sent),
           { t: 'ev', h: 4, k: 'focus', p: {}, n: 2 });
    box.dispatchEvent(new MouseEvent('mouseenter', { bubbles: false, clientX: 3, clientY: 4 }));
    eqJson('mouseenter does not bubble and is still delivered', last(caphost.socket.sent),
           { t: 'ev', h: 5, k: 'mouseenter', p: { b: 0, x: 3, y: 4 }, n: 3 });
    box.dispatchEvent(new KeyboardEvent('keydown', { bubbles: true, key: 'Enter', repeat: true }));
    eqJson('a keyboard event carries the key and the repeat flag', last(caphost.socket.sent),
           { t: 'ev', h: 6, k: 'keydown', p: { k: 'Enter', r: true }, n: 4 });

    function last(list) { return list[list.length - 1]; }

    // --- a form submit: the fields, and the navigation that must not happen ---
    var formrig = newCircuit();
    hello(formrig);
    feed(formrig, {
        t: 'batch', b: 1, d: [],
        r: [['o', 0, 'form'], ['h', 1, 'submit', 7],
            ['o', 2, 'input'], ['a', 0, 'name', 'who'], ['a', 1, 'value', 'ada'], ['z'],
            ['o', 3, 'input'], ['a', 0, 'name', 'ok'], ['a', 1, 'type', 'checkbox'], ['z'],
            ['o', 4, 'input'], ['a', 0, 'name', 'send'], ['a', 1, 'type', 'submit'], ['z'],
            ['z']],
        u: [{ c: 0, e: [['in', 0, 0]] }]
    });
    var form = formrig.host.querySelector('form');
    var submit = new Event('submit', { bubbles: true, cancelable: true });
    form.dispatchEvent(submit);
    eqJson('a submit carries the successful controls only', last(formrig.socket.sent),
           { t: 'ev', h: 7, k: 'submit', p: { f: { who: 'ada' } }, n: 2 });
    eq('and the form post was prevented', submit.defaultPrevented, true);
    form.querySelector('input[name=ok]').checked = true;
    form.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }));
    eqJson('a checked box is submitted, an unchecked one is not',
           last(formrig.socket.sent),
           { t: 'ev', h: 7, k: 'submit', p: { f: { who: 'ada', ok: 'on' } }, n: 3 });

    // --- enhanced navigation ---
    var navrig = newCircuit();
    hello(navrig);
    feed(navrig, {
        t: 'batch', b: 1, d: [],
        r: [['o', 0, 'nav'],
            ['o', 1, 'a'], ['a', 0, 'href', '/next'], ['t', 1, 'go'], ['z'],
            ['o', 2, 'a'], ['a', 0, 'href', '//evil.example/x'], ['t', 1, 'no'], ['z'],
            ['z']],
        u: [{ c: 0, e: [['in', 0, 0]] }]
    });
    var links = navrig.host.getElementsByTagName('a');
    links[0].dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, button: 0 }));
    eqJson('a same-origin link becomes a nav message', last(navrig.socket.sent),
           { t: 'nav', u: '/next', n: 2 });
    eq('and the browser navigation was prevented', lastClickPrevented, true);
    var beforeNav = navrig.socket.sent.length;
    links[1].dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, button: 0 }));
    eq('a scheme-relative link is left to the browser',
       navrig.socket.sent.length, beforeNav);
    eq('and latte prevented nothing', lastClickPrevented, false);
    // A modified click is the browser's, whatever the href says.
    links[0].dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true,
                                                     button: 0, metaKey: true }));
    eq('a command-click is left to the browser',
       navrig.socket.sent.length, beforeNav);
    eq('and latte prevented nothing there either', lastClickPrevented, false);

    // --- JS interop ---
    var jsrig = newCircuit();
    hello(jsrig);
    feed(jsrig, caseNamed('page').steps[0].b);
    jsrig.circuit.register('shout', function (a, b) { return a + '/' + b; });
    jsrig.circuit.register('boom', function () { throw new Error('nope'); });
    feed(jsrig, { t: 'js', i: 3, f: 'shout', a: ['x', 'y'] });
    eqJson('a registered function answers its call id', last(jsrig.socket.sent),
           { t: 'js', i: 3, ok: true, v: 'x/y' });
    feed(jsrig, { t: 'js', i: 4, f: 'boom', a: [] });
    eqJson('a throwing function answers ok:false', last(jsrig.socket.sent),
           { t: 'js', i: 4, ok: false, v: 'nope' });
    feed(jsrig, { t: 'js', i: 5, f: 'missing', a: [] });
    eqJson('an unregistered name answers ok:false and never evaluates anything',
           last(jsrig.socket.sent),
           { t: 'js', i: 5, ok: false, v: 'no function is registered as missing' });
    feed(jsrig, { t: 'js', i: 6, f: '__proto__', a: [] });
    eqJson('and neither does __proto__', last(jsrig.socket.sent),
           { t: 'js', i: 6, ok: false, v: 'no function is registered as __proto__' });

    // --- a version this client does not know ---
    var oldrig = newCircuit();
    hello(oldrig, 2);
    eq('an unknown wire version stops rather than guessing', oldrig.circuit.ended, true);
    eq('and it sent nothing', oldrig.socket.sent.length, 0);

    // --- a circuit id that is not this one ---
    var wrongrig = newCircuit();
    wrongrig.socket.onmessage({ data: JSON.stringify({
        t: 'hello', v: 1, c: 'ffffffffffffffffffff', mx: 65536 }) });
    eq('a hello for a different circuit stops', wrongrig.circuit.ended, true);

    // --- bye, and no reconnect after it ---
    var byerig = newCircuit();
    hello(byerig);
    feed(byerig, { t: 'bye', k: 'protocol', m: 'unknown event name' });
    eq('a bye ends the circuit', byerig.circuit.ended, true);
    eq('and it closed the socket', byerig.socket.closed, true);
    byerig.socket.onclose();
    eq('and a close after a bye does not reconnect', byerig.sockets.length, 1);

    // --- a drop, then a reconnect that resumes from the last acked batch ---
    var droprig = newCircuit();
    hello(droprig);
    feed(droprig, caseNamed('page').steps[0].b);
    feed(droprig, caseNamed('page').steps[1].b);
    eq('two batches applied', droprig.circuit.lastBatch, 2);
    droprig.circuit.backoff = [0];
    droprig.socket.onclose();
    eq('a drop is not the end', droprig.circuit.ended, false);

    // --- a replayed batch is acked again and applied once ---
    var replayrig = newCircuit();
    hello(replayrig);
    feed(replayrig, caseNamed('page').steps[0].b);
    var htmlAfterOne = replayrig.host.innerHTML;
    feed(replayrig, caseNamed('page').steps[0].b);
    eq('a replayed batch is not applied twice', replayrig.host.innerHTML, htmlAfterOne);
    eqJson('but it is acked again, so retention keeps moving',
           last(replayrig.socket.sent), { t: 'ack', b: 1 });

    // --- a message over the cap is refused here rather than ending the circuit ---
    var caprig = newCircuit();
    hello(caprig);
    caprig.circuit.maxMessage = 40;
    var beforeCap = caprig.socket.sent.length;
    caprig.circuit.send({ t: 'ev', h: 1, k: 'click',
                          p: { v: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' } });
    eq('an oversized message is dropped by the client, not sent',
       caprig.socket.sent.length, beforeCap);

    // =================================================== § 5 the fence
    //
    // BLOCKERS.md B11, the client half. Before this, `latte.js` sent an event
    // and waited in `onmessage` with no timer between "sent" and "an answer
    // arrived", so a click on a slot the server no longer had bound produced a
    // page that never acknowledged the click on a socket that looked alive.
    //
    // Every row here moves the FAKE clock. Nothing waits.

    say('');
    say('=== 5. the seen fence and the answer deadline');

    // --- an inert message is answered, and the deadline clears ---
    var fencerig = newCircuit({ answerMs: 5000 });
    hello(fencerig);
    eq('the attach is outstanding', fencerig.circuit.outstanding.length, 1);
    eq('and a deadline is armed for it', fencerig.timers.length, 1);
    feed(fencerig, { t: 'seen', n: 1 });
    eq('a seen retires it', fencerig.circuit.outstanding.length, 0);
    eq('and disarms the deadline', fencerig.timers.length, 0);
    // THE ROW B11 IS ABOUT: a message that produced no batch, answered.
    fencerig.advance(9000);
    eq('nine seconds past a five-second deadline is not a stall',
       fencerig.stalls.length, 0);
    eq('and the socket was not dropped', fencerig.sockets.length, 1);

    // --- the same message with NO answer stalls, and reconnects ---
    var stallrig = newCircuit({ answerMs: 5000 });
    hello(stallrig);
    stallrig.circuit.backoff = [0];
    stallrig.advance(4999);
    eq('one millisecond short of the deadline is not a stall',
       stallrig.stalls.length, 0);
    stallrig.advance(1);
    eq('the deadline fires exactly at answerMs', stallrig.stalls.length, 1);
    eq('and it names the message that went unanswered',
       stallrig.stalls[0].t, 'attach');
    eq('the socket was closed', stallrig.sockets[0].closed, true);
    eq('and nothing is left outstanding', stallrig.circuit.outstanding.length, 0);
    stallrig.advance(1);
    eq('the reconnect opened exactly one new socket', stallrig.sockets.length, 2);
    // The close this end started must not ALSO reconnect. Two sockets, not
    // three: `connect` compares socket identity rather than trusting a flag.
    stallrig.sockets[0].onclose();
    stallrig.advance(1000);
    eq('and the close it started does not reconnect a second time',
       stallrig.sockets.length, 2);

    // --- a stall is not the end of the circuit ---
    eq('a stall is not an ending', stallrig.circuit.ended, false);
    eq('it is reported', stallrig.errors.length > 0, true);

    // --- several in flight, retired by number and in order ---
    var manyrig = newCircuit({ answerMs: 5000 });
    hello(manyrig);
    feed(manyrig, { t: 'seen', n: 1 });
    feed(manyrig, caseNamed('page').steps[0].b);
    var wrap5 = manyrig.host.querySelector('#wrap');
    wrap5.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, button: 0 }));
    manyrig.advance(1000);
    wrap5.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, button: 0 }));
    manyrig.advance(1000);
    wrap5.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, button: 0 }));
    eq('three clicks are outstanding', manyrig.circuit.outstanding.length, 3);
    eq('numbered in send order',
       manyrig.circuit.outstanding.map(function (o) { return o.n; }).join(','),
       '2,3,4');
    feed(manyrig, { t: 'seen', n: 3 });
    eq('an answer for 3 retires 2 as well — the server answers in order',
       manyrig.circuit.outstanding.map(function (o) { return o.n; }).join(','),
       '4');
    // The deadline that remains belongs to the message that is still waiting,
    // and it is measured from when THAT message was sent. The clock is at
    // t=3000 here and the surviving click went out at t=3000, so its deadline
    // is t=8000 — NOT t=6000, which is when the retired attach would have
    // timed out. Advancing past 6000 with no stall is the whole point of the
    // row: a deadline is re-based on the survivor, never left where the first
    // message put it. My first version of this check advanced to 6000 and
    // expected a stall; the code was right and the arithmetic was mine.
    manyrig.advance(4999);
    eq('the retired message\'s deadline passes without a stall',
       manyrig.stalls.length, 0);
    manyrig.advance(1);
    eq('and the survivor times out at its OWN five seconds',
       manyrig.stalls.length, 1);
    eq('naming the click', manyrig.stalls[0].n, 4);

    // --- a bye answers every outstanding message ---
    var byefence = newCircuit({ answerMs: 5000 });
    hello(byefence);
    eq('the attach is outstanding', byefence.circuit.outstanding.length, 1);
    feed(byefence, { t: 'bye', k: 'protocol', m: 'unknown message kind' });
    eq('a bye clears every deadline', byefence.circuit.outstanding.length, 0);
    eq('and disarms the timer', byefence.timers.length, 0);
    byefence.advance(60000);
    eq('so an ended circuit never stalls', byefence.stalls.length, 0);
    eq('and never reconnects', byefence.sockets.length, 1);

    // --- a drop clears them too: the reconnect carries its own ---
    // A batch first, so this end has something to resume FROM: `attached` is
    // set by the first batch, and a circuit that never got one re-attaches
    // rather than resuming. The attach's own fence is still outstanding when
    // the socket drops, which is what makes the first row here mean anything.
    var dropfence = newCircuit({ answerMs: 5000 });
    hello(dropfence);
    feed(dropfence, caseNamed('page').steps[0].b);
    eq('the attach is still outstanding when the socket goes',
       dropfence.circuit.outstanding.length, 1);
    dropfence.circuit.backoff = [0];
    dropfence.socket.onclose();
    eq('a drop clears the deadlines', dropfence.circuit.outstanding.length, 0);
    dropfence.advance(1);
    eq('the reconnect opened a socket', dropfence.sockets.length, 2);
    dropfence.current().onmessage({ data: JSON.stringify({
        t: 'hello', v: 1, c: CIRCUIT_ID, mx: 65536 }) });
    eqJson('and the resume it sends carries a NEW sequence, not the old one',
           last(dropfence.current().sent),
           { t: 'resume', c: CIRCUIT_ID, a: 1, n: 2 });
    dropfence.advance(60000);
    eq('the dropped attach never stalls the reconnected circuit',
       dropfence.stalls.length, 1);
    eq('and the stall that did happen is the RESUME, not the dead attach',
       dropfence.stalls[0].t, 'resume');

    // --- an unsendable message owes nothing ---
    var unsent = newCircuit({ answerMs: 5000 });
    hello(unsent);
    feed(unsent, { t: 'seen', n: 1 });
    unsent.socket.readyState = 3;
    eq('a message that could not be sent returns false',
       unsent.circuit.sendFenced({ t: 'nav', u: '/x' }), false);
    eq('and is not outstanding', unsent.circuit.outstanding.length, 0);
    unsent.advance(60000);
    eq('so it can never stall', unsent.stalls.length, 0);
    // The number is still spent. A message this end believes it sent must
    // never reuse a number a later one will get.
    unsent.socket.readyState = 1;
    eq('the sequence moved on', unsent.circuit.sendFenced({ t: 'nav', u: '/y' }), true);
    eqJson('so the next message is 3, not 2', last(unsent.socket.sent),
           { t: 'nav', u: '/y', n: 3 });

    // --- an ack is deliberately NOT fenced ---
    var ackrig = newCircuit({ answerMs: 5000 });
    hello(ackrig);
    feed(ackrig, { t: 'seen', n: 1 });
    feed(ackrig, caseNamed('page').steps[0].b);
    eqJson('a batch is acked without a sequence', last(ackrig.socket.sent),
           { t: 'ack', b: 1 });
    eq('so nothing is outstanding', ackrig.circuit.outstanding.length, 0);
    ackrig.advance(60000);
    eq('and an idle tab that only acks never stalls', ackrig.stalls.length, 0);

    // --- a seen for a number this end never sent changes nothing ---
    var strayrig = newCircuit({ answerMs: 5000 });
    hello(strayrig);
    feed(strayrig, { t: 'seen', n: 99 });
    eq('a seen ahead of everything retires the lot', strayrig.circuit.outstanding.length, 0);
    strayrig.advance(60000);
    eq('and leaves no timer behind', strayrig.stalls.length, 0);

    // =================================================== § 6 streaming
    //
    // W6 row 1, the browser half. `stream.b` produces the bytes and
    // `assemble_chunks` says what a browser should be left holding; this feeds
    // the same bytes to Chrome's own HTML tokenizer AT EVERY SPLIT and
    // requires the DOM to be that.
    //
    // Why an iframe and `document.write`: a split is only a real split if the
    // parser sees it as one. `innerHTML = a + b` is not a split — it parses a
    // complete string. `doc.open(); doc.write(a); …; doc.write(b); doc.close()`
    // feeds an open document incrementally, which is exactly what a chunked
    // response does, and it is the only way to get a browser to hold half a
    // tag the way the network makes it hold one.

    say('');
    say('=== 6. streaming: every byte split, through the real HTML parser');

    var frame = document.createElement('iframe');
    frame.setAttribute('title', 'stream');
    document.body.appendChild(frame);

    // The id rule, both copies. latte.js reads an id out of an attribute and
    // writes it straight into an attribute SELECTOR, so the set that cannot
    // carry a quote or a bracket out of the document is the set that keeps
    // that safe.
    var badIds = 0;
    for (var ip = 0; ip < LATTE_STREAM.ids.length; ip++) {
        var probe = LATTE_STREAM.ids[ip];
        if (latte.streamIdIsSafe(probe[0]) !== probe[1]) {
            badIds += 1;
            say('   id ' + JSON.stringify(probe[0]) + ' beans=' + probe[1] +
                ' browser=' + latte.streamIdIsSafe(probe[0]));
        }
    }
    say('slot ids compared: ' + LATTE_STREAM.ids.length);
    eq('every slot id gets the same answer from both halves', badIds, 0);
    eq('the longest slot id is the same number on both sides',
       latte.maxStreamId, LATTE_CAPS.maxStreamId);

    /// Write `text` into the frame in `parts` pieces, sweeping after each, and
    /// answer what the document was left holding.
    function runStream(text, cuts) {
        var doc = frame.contentDocument;
        doc.open();
        var stream = new latte.Stream({ document: doc,
                                        log: { warn: function () {}, error: function () {} } });
        var at = 0;
        for (var c = 0; c < cuts.length; c++) {
            doc.write(text.slice(at, cuts[c]));
            stream.sweep();
            at = cuts[c];
        }
        doc.write(text.slice(at));
        stream.sweep();
        doc.close();
        stream.sweep();
        return { stream: stream,
                 html: doc.body ? doc.body.innerHTML : '',
                 doc: doc };
    }

    var splitsRun = 0;
    var splitWrong = 0;
    var splitFaults = 0;
    var firstSplitFailure = '';
    for (var sc = 0; sc < LATTE_STREAM.docs.length; sc++) {
        var scase = LATTE_STREAM.docs[sc];
        if (!scase.sealed) { continue; }
        var wantHtml = normalize(scase.want);
        var wantFaults = scase.faults.join('\n');
        // EVERY split, 0 through the whole length. 0 is "nothing written yet"
        // and length is "one write"; both are real deliveries and both have
        // caught something in this repo's siblings.
        for (var cut = 0; cut <= scase.doc.length; cut++) {
            var got = runStream(scase.doc, [cut]);
            splitsRun += 1;
            if (normalize(got.html) !== wantHtml) {
                splitWrong += 1;
                if (firstSplitFailure === '') {
                    firstSplitFailure = scase.name + ' at ' + cut + ': ' +
                        JSON.stringify(got.html) + ' want ' + JSON.stringify(scase.want);
                }
            }
            if (got.stream.faults.join('\n') !== wantFaults) {
                splitFaults += 1;
                if (firstSplitFailure === '') {
                    firstSplitFailure = scase.name + ' at ' + cut + ' faults: ' +
                        JSON.stringify(got.stream.faults) + ' want ' + JSON.stringify(scase.faults);
                }
            }
        }
        // And one three-way split, so a document is also cut in two places at
        // once — the shape where a chunk's OPEN tag and its SEAL land in
        // different writes with the body divided between them.
        for (var a = 0; a <= scase.doc.length; a += 7) {
            for (var b = a; b <= scase.doc.length; b += 11) {
                var got3 = runStream(scase.doc, [a, b]);
                splitsRun += 1;
                if (normalize(got3.html) !== wantHtml) {
                    splitWrong += 1;
                    if (firstSplitFailure === '') {
                        firstSplitFailure = scase.name + ' at ' + a + '/' + b + ': ' +
                            JSON.stringify(got3.html);
                    }
                }
            }
        }
    }
    if (firstSplitFailure !== '') { say('   first: ' + firstSplitFailure); }
    say('documents: ' + LATTE_STREAM.docs.length + ', splits run: ' + splitsRun);
    eq('every split lands on the document assemble_chunks describes', splitWrong, 0);
    eq('and raises exactly the faults assemble_chunks raises', splitFaults, 0);

    // --- the seal is what makes the difference, and here is the proof ---
    //
    // The `unsealed` document ends inside a chunk. The Beans model, handed the
    // whole event stream at once, can say the document ended mid-chunk. A
    // browser cannot and must not: the next byte may be the rest of it. So the
    // chunk stays exactly where it is and the placeholder stays with it — a
    // hole on the page rather than half a region moved into it.
    var unsealed = null;
    for (var u = 0; u < LATTE_STREAM.docs.length; u++) {
        if (LATTE_STREAM.docs[u].name === 'unsealed') { unsealed = LATTE_STREAM.docs[u]; }
    }
    var half = runStream(unsealed.doc, [unsealed.doc.length]);
    eq('an unsealed chunk lands nothing', half.stream.landed.length, 0);
    eq('and raises no fault, because more bytes could still be coming',
       half.stream.faults.length, 0);
    eq('the placeholder is still on the page',
       half.doc.querySelectorAll('latte-slot[id="s0"]').length, 1);
    eq('and the chunk is still beside it, whole',
       half.doc.querySelectorAll('latte-chunk[for="s0"]').length, 1);
    // The positive control: the SAME document with the seal appended lands.
    // Without it "nothing landed" could not be told from "this sweep never ran".
    var sealed = runStream(unsealed.doc + '</latte-chunk><latte-seal for="s0"></latte-seal>',
                           [unsealed.doc.length]);
    eq('the same bytes with a seal after them land the chunk',
       sealed.stream.landed.join(','), 's0');
    eq('and the placeholder is gone',
       sealed.doc.querySelectorAll('latte-slot').length, 0);
    eq('and the wrapper with it',
       sealed.doc.querySelectorAll('latte-chunk,latte-seal').length, 0);
    eq('leaving the content where the hole was',
       normalize(sealed.doc.body.innerHTML), normalize('<div><p>half</p></div>'));

    // --- sweeping twice does not land twice ---
    var twice = runStream(LATTE_STREAM.docs[0].doc, [LATTE_STREAM.docs[0].doc.length]);
    var before = twice.doc.body.innerHTML;
    eq('a second sweep lands nothing', twice.stream.sweep(), 0);
    eq('and changes nothing', twice.doc.body.innerHTML, before);

    // =================================================== § 7 virtual lists
    //
    // W6 row 2, the browser half. Two separate claims, and they are pinned
    // separately because they can fail separately:
    //
    //   the MIRROR — `latte.virtualWindow` answers what `VirtualGeometry
    //   .window_at` answers, for every scroll position in the fixture. Judged
    //   against Beans and nothing else.
    //
    //   the REPORTER — it reads the four numbers off the right element, takes
    //   `scrollTop` and `clientHeight` from a real scrolling box, coalesces to
    //   one message per frame, and sends `c` for the count. Judged against the
    //   mirror and against hand-computed messages.

    say('');
    say('=== 7. virtual lists: the geometry mirror and the scroll reporter');

    // The caps latte.js holds copies of. `hello` carries `v`, `c` and `mx` and
    // nothing else, so a client cannot ask what the window cap is — and
    // `circuit.b:on_range` ENDS the circuit for a range over it. A drift here
    // is a tab that dies on its first scroll of a tall list.
    eq('the window cap latte.js holds is the one circuit.b enforces',
       latte.maxWindow, LATTE_CAPS.wire);
    eq('and the one virtual.b trims to', latte.maxWindow, LATTE_CAPS.renderer);

    var windowWrong = 0;
    var firstWindow = '';
    for (var w = 0; w < LATTE_VIRTUAL.length; w++) {
        var row = LATTE_VIRTUAL[w];
        var band = latte.virtualWindow(row[0], row[1], row[2], row[3], row[4], row[5]);
        if (band.start !== row[6] || band.count !== row[7]) {
            windowWrong += 1;
            if (firstWindow === '') {
                firstWindow = 'rows=' + row[0] + ' h=' + row[1] + ' scan=' + row[2] +
                    ' cap=' + row[3] + ' top=' + row[4] + ' view=' + row[5] +
                    ' got ' + band.start + '+' + band.count +
                    ' want ' + row[6] + '+' + row[7];
            }
        }
    }
    if (firstWindow !== '') { say('   first: ' + firstWindow); }
    say('scroll positions compared: ' + LATTE_VIRTUAL.length);
    eq('every one lands on the window VirtualGeometry lays out', windowWrong, 0);

    // Four windows computed BY HAND from the rule in virtual.b, so the mirror
    // is not judged only against a table that came out of the same tree.
    //   50,000 rows of 32px, overscan 4, cap 200.
    //   at 320px with a 100px viewport: first = 320/32 = 10, last = (320+99)/32
    //   = 13, so the band is 6..17 — twelve rows.
    eqJson('by hand: 320px, 100px viewport',
           latte.virtualWindow(50000, 32, 4, 200, 320, 100), { start: 6, count: 12 });
    //   one pixel earlier the band starts a row sooner: first = 9, last = 13.
    eqJson('by hand: one pixel earlier crosses a row boundary',
           latte.virtualWindow(50000, 32, 4, 200, 319, 100), { start: 5, count: 13 });
    //   at the very top there is nothing to overscan into.
    eqJson('by hand: the top of the list',
           latte.virtualWindow(50000, 32, 4, 200, 0, 100), { start: 0, count: 8 });
    //   a viewport of 100,000px wants 3129 rows and gets the cap.
    eqJson('by hand: a viewport taller than the cap allows',
           latte.virtualWindow(50000, 32, 4, 200, 0, 100000), { start: 0, count: 200 });

    // --- the reporter, in a real scrolling box ---
    function scroller(id, rows, height, overscan, inner) {
        var el = document.createElement('div');
        el.setAttribute('data-latte-virtual', String(id));
        el.setAttribute('data-latte-rows', String(rows));
        el.setAttribute('data-latte-row-height', String(height));
        el.setAttribute('data-latte-overscan', String(overscan));
        // No border and no padding, so `clientHeight` is the number written
        // here and the check below is arithmetic rather than a measurement.
        el.setAttribute('style', 'height:100px;overflow:auto;border:0;padding:0');
        el.innerHTML = '<div style="height:' + inner + 'px"></div>';
        return el;
    }

    function newReporter(options) {
        options = options || {};
        var host = freshHost();
        var frames = [];
        var rig = newCircuit({ schedule: function (fn) { frames.push(fn); },
                               host: host });
        rig.frames = frames;
        rig.tick = function () {
            var due = frames.slice();
            frames.length = 0;
            for (var i = 0; i < due.length; i++) { due[i](); }
        };
        return rig;
    }

    var rrig = newReporter();
    hello(rrig);
    var list = scroller(7, 50, 32, 4, 1600);
    rrig.host.appendChild(list);
    eq('the box is exactly as tall as it was told to be', list.clientHeight, 100);
    list.scrollTop = 320;
    eq('and it really scrolled', list.scrollTop, 320);
    list.dispatchEvent(new Event('scroll', { bubbles: false }));
    eq('a scroll sends nothing until the frame comes', rrig.socket.sent.length, 1);
    // Four more scrolls before the frame. All of them cost one message.
    list.dispatchEvent(new Event('scroll', { bubbles: false }));
    list.dispatchEvent(new Event('scroll', { bubbles: false }));
    list.dispatchEvent(new Event('scroll', { bubbles: false }));
    eq('and four scrolls schedule one frame, not four', rrig.frames.length, 1);
    rrig.tick();
    // The COUNT rides on `c`. On `n` it would be read as the message sequence
    // — which wire.b takes before it looks at the kind — the range would
    // decode with no count at all, and "a range must be two non-negative
    // numbers" would refuse every scroll the page ever made.
    eqJson('one range goes out, with the count on c and the sequence on n',
           last(rrig.socket.sent), { t: 'range', h: 7, s: 6, c: 12, n: 2 });
    eq('four scrolls, one message', rrig.socket.sent.length, 2);

    // --- a window that did not move sends nothing ---
    rrig.circuit.ranges.request();
    rrig.tick();
    eq('the same window again sends nothing', rrig.socket.sent.length, 2);
    // ...and the positive control, so "nothing" is not "the reporter is dead".
    list.scrollTop = 1600;
    list.dispatchEvent(new Event('scroll', { bubbles: false }));
    rrig.tick();
    eqJson('a window that moved does send', last(rrig.socket.sent),
           { t: 'range', h: 7, s: 42, c: 8, n: 3 });

    // --- two lists on one page are two messages, each with its own id ---
    var second = scroller(9, 50, 32, 4, 1600);
    rrig.host.appendChild(second);
    second.scrollTop = 320;
    second.dispatchEvent(new Event('scroll', { bubbles: false }));
    rrig.tick();
    eqJson('the second list reports under its own id', last(rrig.socket.sent),
           { t: 'range', h: 9, s: 6, c: 12, n: 4 });
    eq('and the first, which did not move, says nothing', rrig.socket.sent.length, 4);

    // --- the cap is never crossed, whatever the box says ---
    var caprigv = newReporter();
    hello(caprigv);
    var tall = scroller(3, 50000, 32, 4, 1600000);
    tall.setAttribute('style', 'height:100000px;overflow:auto;border:0;padding:0');
    caprigv.host.appendChild(tall);
    tall.dispatchEvent(new Event('scroll', { bubbles: false }));
    caprigv.tick();
    var capped = last(caprigv.socket.sent);
    eq('a viewport that wants thousands of rows asks for the cap',
       capped.c, latte.maxWindow);
    eq('which is not more than circuit.b would accept',
       capped.c <= LATTE_CAPS.wire, true);

    // --- an element with no usable id is not reported ---
    var badrig = newReporter();
    hello(badrig);
    var nameless = scroller(0, 50, 32, 4, 1600);
    nameless.setAttribute('data-latte-virtual', 'nope');
    badrig.host.appendChild(nameless);
    nameless.scrollTop = 320;
    nameless.dispatchEvent(new Event('scroll', { bubbles: false }));
    badrig.tick();
    eq('an element whose id is not a number reports nothing',
       badrig.socket.sent.length, 1);
    // The positive control: the same element with a number on it does report,
    // so the silence above is the id and not the listener.
    nameless.setAttribute('data-latte-virtual', '0');
    nameless.dispatchEvent(new Event('scroll', { bubbles: false }));
    badrig.tick();
    eqJson('and with a number on it, it does', last(badrig.socket.sent),
           { t: 'range', h: 0, s: 6, c: 12, n: 2 });

    // --- a batch re-evaluates the lists it just changed ---
    //
    // A list that GREW under a stationary scroll position has a new window and
    // no scroll event is coming to say so.
    var batchrig = newReporter();
    hello(batchrig);
    var grows = scroller(11, 50, 32, 4, 1600);
    batchrig.host.appendChild(grows);
    grows.scrollTop = 1600;
    grows.dispatchEvent(new Event('scroll', { bubbles: false }));
    batchrig.tick();
    eqJson('the window at the bottom of a 50-row list', last(batchrig.socket.sent),
           { t: 'range', h: 11, s: 42, c: 8, n: 2 });
    grows.setAttribute('data-latte-rows', '500');
    batchrig.circuit.onBatch({ b: 1, u: [] });
    batchrig.tick();
    eqJson('the same scroll position in a 500-row list is a different window',
           last(batchrig.socket.sent), { t: 'range', h: 11, s: 42, c: 12, n: 3 });
    // And it settles: a batch that changed nothing about the list sends no
    // second range, so a batch and a range cannot chase each other.
    batchrig.circuit.onBatch({ b: 2, u: [] });
    batchrig.tick();
    eq('a batch that moved no window sends no range',
       last(batchrig.socket.sent).t, 'ack');

    // =================================================== § 8 uploads
    //
    // W6 row 3, the browser half. The POST is real; the progress REPORT stops
    // at a sink, because wire v1 has no client message for progress and a
    // client that invented one would be answered with `bye protocol`. See the
    // note above `Progress` in latte.js and lanes/W6.md.

    say('');
    say('=== 8. uploads: the POST, and progress clamped as UploadProgress clamps it');

    var progWrong = 0;
    var firstProg = '';
    for (var pr = 0; pr < LATTE_PROGRESS.length; pr++) {
        var prow = LATTE_PROGRESS[pr];
        var prog = new latte.Progress();
        prog.report(prow[0], prow[1]);
        var again = prog.report(prow[0], prow[1]);
        if (prog.sent !== prow[2] || prog.total !== prow[3] ||
            prog.percent() !== prow[4] || again !== prow[5]) {
            progWrong += 1;
            if (firstProg === '') {
                firstProg = prow[0] + '/' + prow[1] + ' got ' + prog.sent + '/' +
                    prog.total + ' ' + prog.percent() + '% changed=' + again +
                    ' want ' + prow[2] + '/' + prow[3] + ' ' + prow[4] + '% changed=' + prow[5];
            }
        }
    }
    if (firstProg !== '') { say('   first: ' + firstProg); }
    say('progress pairs compared: ' + LATTE_PROGRESS.length);
    eq('every pair clamps to what UploadProgress clamps it to', progWrong, 0);

    function FakeXhr() {
        this.method = '';
        this.url = '';
        this.body = null;
        this.status = 0;
        this.upload = {};
        this.onload = null;
        this.onerror = null;
    }
    FakeXhr.prototype.open = function (method, url) { this.method = method; this.url = url; };
    FakeXhr.prototype.send = function (body) { this.body = body; };

    function control(id, maxBytes, maxFiles, field, action) {
        var el = document.createElement('div');
        el.setAttribute('data-latte-upload', String(id));
        el.setAttribute('data-latte-max-bytes', String(maxBytes));
        el.setAttribute('data-latte-max-files', String(maxFiles));
        if (action) { el.setAttribute('data-latte-action', action); }
        if (field !== null) {
            var input = document.createElement('input');
            input.setAttribute('type', 'file');
            input.setAttribute('name', field);
            el.appendChild(input);
        }
        document.body.appendChild(el);
        return el;
    }

    function newUploader(el) {
        var made = { sent: [], refused: [], done: [], xhrs: [] };
        made.uploader = new latte.Uploader({
            element: el,
            document: document,
            request: function () {
                var x = new FakeXhr();
                made.xhrs.push(x);
                return x;
            },
            onprogress: function (message) { made.sent.push(message); },
            onrefused: function (why) { made.refused.push(why); },
            ondone: function (status) { made.done.push(status); }
        });
        return made;
    }

    function file(name, bytes, type) {
        var body = [];
        for (var i = 0; i < bytes; i++) { body.push('x'); }
        return new File([body.join('')], name, { type: type || 'text/plain' });
    }

    // --- an ordinary POST ---
    var up = newUploader(control(3, 100, 2, 'doc', '/upload'));
    eq('two files inside the limits post', up.uploader.post([file('a.txt', 10), file('b.txt', 90)]), true);
    eq('one request went out', up.xhrs.length, 1);
    eq('as a POST', up.xhrs[0].method, 'POST');
    eq('to the action the control names', up.xhrs[0].url, '/upload');
    eq('carrying both parts under the input\'s name',
       up.xhrs[0].body.getAll('doc').length, 2);
    eq('with the submitted filenames on them',
       up.xhrs[0].body.getAll('doc').map(function (f) { return f.name; }).join(','),
       'a.txt,b.txt');
    eq('and nothing was refused', up.refused.length, 0);

    // --- no action means the page's own url, which is what Upload.action means ---
    var own = newUploader(control(4, 100, 2, 'doc', null));
    own.uploader.post([file('a.txt', 10)]);
    eq('a control with no action posts to the page itself',
       own.xhrs[0].url, location.pathname + location.search);

    // --- progress, clamped, and reported once per change ---
    var prg = newUploader(control(5, 1000, 2, 'doc', '/u'));
    prg.uploader.post([file('a.txt', 100)]);
    prg.xhrs[0].upload.onprogress({ loaded: 0, total: 100, lengthComputable: true });
    prg.xhrs[0].upload.onprogress({ loaded: 50, total: 100, lengthComputable: true });
    prg.xhrs[0].upload.onprogress({ loaded: 50, total: 100, lengthComputable: true });
    prg.xhrs[0].upload.onprogress({ loaded: 100, total: 100, lengthComputable: true });
    eqJson('the reports that changed something',
           prg.sent, [{ t: 'progress', h: 5, s: 0, c: 100 },
                      { t: 'progress', h: 5, s: 50, c: 100 },
                      { t: 'progress', h: 5, s: 100, c: 100 }]);
    eq('and the percentage at the end', prg.uploader.progress.percent(), 100);
    // A browser that does not know the length says so, and a bar that jumped
    // to 100 because the total was missing would be a lie.
    prg.xhrs[0].upload.onprogress({ loaded: 90, total: 0, lengthComputable: false });
    eq('an unknown length is 0 of 0', prg.uploader.progress.total, 0);
    eq('which is nought per cent, not a hundred', prg.uploader.progress.percent(), 0);
    prg.xhrs[0].onload();
    eq('the request finishing marks it done', prg.uploader.progress.done, true);
    eq('and hands the status on', prg.done.join(','), '0');

    // --- what the control will not even attempt ---
    var big = newUploader(control(6, 100, 2, 'doc', '/u'));
    eq('a file over the advertised limit does not post',
       big.uploader.post([file('huge.bin', 101)]), false);
    eq('and no request went out', big.xhrs.length, 0);
    eq('and it says which file and by how much', big.refused.join('\n'),
       '"huge.bin" is 101 bytes, over the 100 this control offers');

    var many = newUploader(control(7, 100, 2, 'doc', '/u'));
    eq('more files than the control takes does not post',
       many.uploader.post([file('a', 1), file('b', 1), file('c', 1)]), false);
    eq('and says how many were offered and how many came',
       many.refused.join('\n'), 'this control takes 2 file(s) and 3 were chosen');

    // A set with ONE bad file in it posts nothing at all. A control that took
    // three of four and mentioned the fourth in a corner is a control that
    // silently lost a file.
    var mixed = newUploader(control(8, 100, 4, 'doc', '/u'));
    eq('one bad file refuses the whole set',
       mixed.uploader.post([file('a', 1), file('huge', 500), file('c', 1)]), false);
    eq('and nothing was posted', mixed.xhrs.length, 0);

    // The positive controls, so every refusal above is the rule it names and
    // not a control that refuses everything.
    var edge = newUploader(control(9, 100, 2, 'doc', '/u'));
    eq('exactly at both limits posts',
       edge.uploader.post([file('a', 100), file('b', 100)]), true);
    eq('and the request carries both', edge.xhrs[0].body.getAll('doc').length, 2);

    var handless = newUploader(control(10, 100, 2, null, '/u'));
    eq('a control with no file input posts nothing',
       handless.uploader.post([file('a', 1)]), false);
    eq('and says so', handless.refused.join('\n'), 'this control has no file input to post');

    // =============================================== § 9 the observer itself
    //
    // Everything in § 6 called `sweep()` by hand, which proves what a sweep
    // does and nothing about whether anything ever calls one. This is the
    // other half: `start()` puts a MutationObserver on the document and
    // NOTHING here sweeps.
    //
    // A MutationObserver callback is a microtask, queued when the mutation
    // happens. The writes below queue it, then this queues its own microtask
    // behind it, and microtasks run in the order they were queued — so by the
    // time `finish` runs the observer has run, deterministically, with no
    // timer and nothing to wait for. `emit()` is at the end of that chain
    // rather than at the end of the file: if the chain never runs, the page
    // prints no verdict at all and test.sh fails on an empty extraction,
    // which is the correct answer to "the observer never fired".

    function observerCheck(finish) {
        var doc = frame.contentDocument;
        doc.open();
        var watcher = new latte.Stream({ document: doc });
        var text = LATTE_STREAM.docs[0].doc;
        var cut = Math.floor(text.length / 2);
        doc.write(text.slice(0, cut));
        var started = watcher.start();
        doc.write(text.slice(cut));
        doc.close();
        Promise.resolve().then(function () {
            try {
                eq('start() attaches an observer', started, true);
                // NOTHING above called sweep. If the observer is not wired,
                // the chunk is still in a wrapper and this is the line that
                // says so.
                eq('the observer landed the chunk with nobody sweeping',
                   watcher.landed.join(','), 's0');
                eq('and left the document assemble_chunks describes',
                   normalize(doc.body.innerHTML),
                   normalize(LATTE_STREAM.docs[0].want));
                eq('with no wrapper and no placeholder left',
                   doc.querySelectorAll('latte-slot,latte-chunk,latte-seal').length, 0);
                watcher.stop();
                // The positive control for `stop()`: a write after it is not
                // landed, so the observer really was the thing doing the work.
                doc.body.insertAdjacentHTML('beforeend',
                    '<latte-slot id="s1"></latte-slot><latte-chunk for="s1"><b>x</b></latte-chunk>' +
                    '<latte-seal for="s1"></latte-seal>');
            } catch (err) {
                say('FAIL the observer check threw: ' + err);
                bad += 1;
            }
            Promise.resolve().then(function () {
                try {
                    eq('a stopped observer lands nothing', watcher.landed.join(','), 's0');
                    eq('and the second chunk is still in its wrapper',
                       doc.querySelectorAll('latte-chunk[for="s1"]').length, 1);
                } catch (err2) {
                    say('FAIL the observer control threw: ' + err2);
                    bad += 1;
                }
                finish();
            });
        });
    }

    observerCheck(function () {
        say('');
        say(checks + ' checks, ' + bad + ' bad');
        emit();
    });
})();
