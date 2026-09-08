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

    function newCircuit(options) {
        options = options || {};
        var host = freshHost();
        var sockets = [];
        var circuit = new latte.Circuit({
            url: 'ws://localhost/_latte/ws',
            id: CIRCUIT_ID,
            document: document,
            host: host,
            enhanceNav: options.enhanceNav,
            open: function () {
                var made = new FakeSocket();
                sockets.push(made);
                return made;
            },
            log: { error: function () {}, warn: function () {} }
        });
        circuit.start();
        return { circuit: circuit, host: host, sockets: sockets,
                 socket: sockets[sockets.length - 1] };
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
           { t: 'attach', c: CIRCUIT_ID, u: location.pathname + location.search });

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
           { t: 'ev', h: 1, k: 'click', p: { b: 0, x: 5, y: 7 } });

    // --- a click on a descendant with no handler walks up to the one that has ---
    var inner = rig.host.querySelector('p');
    inner.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true,
                                                  clientX: 1, clientY: 2, button: 0 }));
    eqJson('a click inside walks up to the nearest bound element',
           rig.socket.sent[3],
           { t: 'ev', h: 1, k: 'click', p: { b: 0, x: 1, y: 2 } });

    // --- an input event reads the control's live value ---
    var field = rig.host.querySelector('input[name=q]');
    field.value = 'edited';
    field.dispatchEvent(new InputEvent('input', { bubbles: true }));
    eqJson('an input event carries the value and the checked flag',
           rig.socket.sent[4],
           { t: 'ev', h: 2, k: 'input', p: { v: 'edited', c: false } });

    // --- THE NO-CACHE RULE. The same element, a new handler id. ---
    feed(rig, { t: 'batch', b: 2, r: [], d: [],
                u: [{ c: 0, e: [['si', 0], ['sh', 5, 'click', 99], ['so']] }] });
    wrap.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true,
                                                 clientX: 0, clientY: 0, button: 0 }));
    eqJson('a rebound handler sends the NEW id, not the one from the first batch',
           rig.socket.sent[6],
           { t: 'ev', h: 99, k: 'click', p: { b: 0, x: 0, y: 0 } });

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
           { t: 'ev', h: 4, k: 'focus', p: {} });
    box.dispatchEvent(new MouseEvent('mouseenter', { bubbles: false, clientX: 3, clientY: 4 }));
    eqJson('mouseenter does not bubble and is still delivered', last(caphost.socket.sent),
           { t: 'ev', h: 5, k: 'mouseenter', p: { b: 0, x: 3, y: 4 } });
    box.dispatchEvent(new KeyboardEvent('keydown', { bubbles: true, key: 'Enter', repeat: true }));
    eqJson('a keyboard event carries the key and the repeat flag', last(caphost.socket.sent),
           { t: 'ev', h: 6, k: 'keydown', p: { k: 'Enter', r: true } });

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
           { t: 'ev', h: 7, k: 'submit', p: { f: { who: 'ada' } } });
    eq('and the form post was prevented', submit.defaultPrevented, true);
    form.querySelector('input[name=ok]').checked = true;
    form.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }));
    eqJson('a checked box is submitted, an unchecked one is not',
           last(formrig.socket.sent),
           { t: 'ev', h: 7, k: 'submit', p: { f: { who: 'ada', ok: 'on' } } });

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
           { t: 'nav', u: '/next' });
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

    say('');
    say(checks + ' checks, ' + bad + ' bad');
    emit();
})();
