// latte.js — the browser half of a latte circuit.
//
// One hand-written, dependency-free file: the DOM applier, the delegated event
// listeners, the payload serializers, the JS interop registry, enhanced
// navigation, and reconnect with replay.
//
// **This file is NOT embedded into the Beans package, and there is no drift
// check for a copy of it.** This comment used to say it was — embedded as a
// constant by `examples/latte_js.b`, regenerated and diffed by a `js-embed`
// leg in `test.sh` — and PLAN.md line 563 still says so. Neither the file nor
// the leg has ever existed: `git log --all` finds no `latte_js` file on any
// branch, and no `.b` file in this repo holds a copy of this one. A host
// serves it from disk instead (`tests/_w8b_smoke_server.b` reads
// `js/latte.js` and answers `/latte.js` with it). Nothing is stale, because
// there is no second copy to go stale; what is missing is the packaging, and
// closing it means a generator that writes this file into a Beans constant
// plus a `test.sh` leg that regenerates and diffs it, the way the
// `examples/markup` leg already does for `counter.bx`.
//
// Three rules shape everything below, and none of them is a preference.
//
//   1. THE LOGICAL TREE IS NOT THE DOM TREE. The edit stream addresses a
//      logical tree in which a region, a fragment, a boundary and a mounted
//      child are NODES that write no HTML of their own; their children lay out
//      in the nearest enclosing element. That is what lets a keyed row hold
//      several roots and still move as one thing. So every DOM operation here
//      goes through `hostOf` / `anchorFor` / `attach` / `detach`, which
//      flatten the logical tree onto the DOM, and never through
//      `parent.dom.appendChild(kid.dom)`.
//
//   2. A MOUNT FRAME IS A LEAF, AND A RE-INSERTED ONE MOVES WHAT IT ALREADY
//      HAS. A component's content arrives as its own entry in `u`, and an
//      unchanged child sends NOTHING. So when a mount frame for a live
//      component id is built again — an element whose tag changed with a
//      mount inside it, or an error boundary that failed and recovered around
//      one — `build` returns the node already held for that id and `attach`
//      MOVES its DOM. W1's reference applier rebuilt one instead and produced
//      an empty node: the child's whole subtree gone, permanently, with
//      nothing reported (LANES.md, "What W1 leaves for W5").
//
//   3. NO HANDLER ID IS EVER CACHED. Dispatch reads `node.binds` at the moment
//      the event fires. Slot ids are never reused — after a boundary recovers,
//      the child re-mounts at a NEW slot with a NEW handler id — so a table
//      built at batch time and read at click time delivers a click to a
//      component that has left the page.
//
// See lanes/W5.md § "THE APPLIER CONTRACT" for the kind rules and the exact
// fault sentences, which are shared byte for byte with the Beans applier.
(function (root, factory) {
    'use strict';
    var api = factory();
    if (typeof module === 'object' && module !== null && module.exports) {
        module.exports = api;
    } else {
        root.latte = api;
    }
})(typeof globalThis !== 'undefined' ? globalThis : this, function () {
    'use strict';

    // ---------------------------------------------------------------- kinds
    //
    // diff.b's SPAN_* values, one numbering shared by both appliers so a
    // walker cannot map them wrong.
    var SPAN_ELEMENT = 0;
    var SPAN_TEXT = 1;
    var SPAN_MARKUP = 2;
    var SPAN_MOUNT = 3;
    var SPAN_REGION = 4;
    var SPAN_FRAGMENT = 5;
    var SPAN_BOUNDARY = 6;

    var KIND_NAMES = ['element', 'text', 'markup', 'mount', 'region',
                      'fragment', 'boundary'];

    function kindName(kind) {
        if (kind >= 0 && kind < KIND_NAMES.length) { return KIND_NAMES[kind]; }
        return 'unknown';
    }

    // Two kinds are leaves; the other five are containers. Only `element`
    // carries attributes and handlers — `Applier.emit` writes an attribute run
    // for SPAN_ELEMENT and for nothing else.
    function isContainer(kind) {
        return kind !== SPAN_TEXT && kind !== SPAN_MARKUP;
    }

    var WIRE_VERSION = 1;

    // ---------------------------------------------------------------- events
    //
    // wire.b's `event_names()` and `event_captures()`, in the same order. A
    // suite compares the two lists rather than trusting that someone kept them
    // in step, which is why `latte.eventNames` is public.
    var EVENT_NAMES = [
        'click', 'dblclick', 'mousedown', 'mouseup', 'mouseenter',
        'mouseleave', 'mouseover', 'mouseout', 'mousemove', 'contextmenu',
        'input', 'change',
        'keydown', 'keyup', 'keypress',
        'submit', 'reset',
        'focus', 'blur', 'focusin', 'focusout'
    ];

    // These four do not bubble, so a delegating listener at the page root only
    // sees them in the CAPTURE phase. The event still travels the capture path
    // down to its target, which is what makes one root listener enough.
    var CAPTURE_EVENTS = ['mouseenter', 'mouseleave', 'focus', 'blur'];

    var FAMILY_NONE = 0;
    var FAMILY_MOUSE = 1;
    var FAMILY_INPUT = 2;
    var FAMILY_KEYBOARD = 3;
    var FAMILY_SUBMIT = 4;
    var FAMILY_FOCUS = 5;

    function eventFamily(name) {
        switch (name) {
            case 'click': case 'dblclick': case 'mousedown': case 'mouseup':
            case 'mouseenter': case 'mouseleave': case 'mouseover':
            case 'mouseout': case 'mousemove': case 'contextmenu':
                return FAMILY_MOUSE;
            case 'input': case 'change':
                return FAMILY_INPUT;
            case 'keydown': case 'keyup': case 'keypress':
                return FAMILY_KEYBOARD;
            case 'submit': case 'reset':
                return FAMILY_SUBMIT;
            case 'focus': case 'blur': case 'focusin': case 'focusout':
                return FAMILY_FOCUS;
        }
        return FAMILY_NONE;
    }

    function eventCaptures(name) {
        return name === 'mouseenter' || name === 'mouseleave' ||
               name === 'focus' || name === 'blur';
    }

    // ---------------------------------------------------------------- maps
    //
    // Every map keyed by a string that came off the wire is null-prototype, so
    // a name like `__proto__` is an ordinary own property and can reach
    // nothing. PLAN.md, "prototype pollution in the applier".
    function bareMap() { return Object.create(null); }

    // Two names are refused as attribute names outright. Neither can do
    // anything through `setAttribute` — an attribute is not a property — but
    // the plan names them and the cost of holding the line is two comparisons.
    function attributeNameIsRefused(name) {
        return name === '__proto__' || name === 'constructor';
    }

    // frames.b's `attribute_name_is_safe`: `[a-zA-Z_:][a-zA-Z0-9_:.-]*`. The
    // Builder already refuses an unsafe name, so no well-formed batch carries
    // one; this is here because `setAttribute` THROWS on an illegal name and a
    // throw would abandon the rest of the batch. A drop with a fault is what
    // every other malformed edit gets.
    function attributeNameIsSafe(name) {
        if (typeof name !== 'string' || name.length === 0) { return false; }
        for (var i = 0; i < name.length; i++) {
            var byte = name.charCodeAt(i);
            var letter = (byte >= 97 && byte <= 122) || (byte >= 65 && byte <= 90);
            var digit = byte >= 48 && byte <= 57;
            var punct = byte === 95 || byte === 58 || byte === 46 || byte === 45;
            if (i === 0 && digit) { return false; }
            if (!letter && !digit && !punct) { return false; }
        }
        return true;
    }

    // ---------------------------------------------------------------- frames
    //
    // The `r` pool, read exactly the way diff.b reads a `Frames`. A frame is
    // the raw array off the wire; nothing is copied into an object first,
    // because the span scan reads each frame at most twice.

    function frameOp(frame) {
        return (frame && frame.length > 0) ? frame[0] : '';
    }

    function frameOpens(op) {
        return op === 'o' || op === 'g' || op === 'p' || op === 'b';
    }

    function frameCloses(op) {
        return op === 'z' || op === 'G' || op === 'P' || op === 'B';
    }

    // frames.b's `frame_is_attribute`: everything between `open` and the first
    // child.
    function frameIsAttribute(op) {
        return op === 'a' || op === 'f' || op === 's' || op === 'h' ||
               op === 'e' || op === 'v';
    }

    // diff.b's `matching_close`. The builder guarantees balance; a walker that
    // trusts a guarantee absolutely is a walker that crashes when the
    // guarantee has a bug, so this stops at the end of the list.
    function matchingClose(frames, opener) {
        var depth = 0;
        for (var i = opener + 1; i < frames.length; i++) {
            var op = frameOp(frames[i]);
            if (frameCloses(op)) {
                if (depth === 0) { return i; }
                depth -= 1;
            }
            if (frameOpens(op)) { depth += 1; }
        }
        return frames.length;
    }

    // diff.b's `span_at`. Answers null where it answers `none`.
    function spanAt(frames, index) {
        if (index < 0 || index >= frames.length) { return null; }
        var frame = frames[index];
        var span = {
            kind: 0, seq: 0, start: index, body: index + 1, stop: index,
            next: index + 1, tag: '', key: '', html: '', raw: false,
            failed: false, id: 0, typeName: ''
        };
        var op = frameOp(frame);
        var closeAt;
        if (op === 'o') {
            span.kind = SPAN_ELEMENT;
            span.seq = frame[1];
            span.tag = frame[2];
            closeAt = matchingClose(frames, index);
            span.stop = closeAt;
            span.next = closeAt + 1;
            var body = index + 1;
            while (body < closeAt && frameIsAttribute(frameOp(frames[body]))) {
                body += 1;
            }
            span.body = body;
        } else if (op === 't') {
            span.kind = SPAN_TEXT;
            span.seq = frame[1];
            span.html = frame[2];
        } else if (op === 'r') {
            span.kind = SPAN_MARKUP;
            span.seq = frame[1];
            span.html = frame[2];
            span.raw = true;
        } else if (op === 'k') {
            span.kind = SPAN_MARKUP;
            span.seq = frame[1];
            span.html = frame[2];
            span.raw = false;
        } else if (op === 'c') {
            span.kind = SPAN_MOUNT;
            span.seq = frame[1];
            span.typeName = frame[2];
            span.id = frame[3];
        } else if (op === 'g') {
            span.kind = SPAN_REGION;
            span.seq = frame[1];
            span.key = frame[2];
            span.stop = matchingClose(frames, index);
            span.next = span.stop + 1;
        } else if (op === 'p') {
            span.kind = SPAN_FRAGMENT;
            span.seq = frame[1];
            span.stop = matchingClose(frames, index);
            span.next = span.stop + 1;
        } else if (op === 'b') {
            span.kind = SPAN_BOUNDARY;
            span.seq = frame[1];
            span.failed = frame[2] === true;
            span.stop = matchingClose(frames, index);
            span.next = span.stop + 1;
        } else {
            return null;
        }
        return span;
    }

    function scanSpans(frames, start, stop) {
        var out = [];
        var index = start;
        while (index < stop) {
            var span = spanAt(frames, index);
            if (span === null) { break; }
            out.push(span);
            index = span.next;
        }
        return out;
    }

    // diff.b's `read_head`: one element's attribute run, read once.
    function readHead(frames, span) {
        var head = { attrs: [], binds: [], refs: [], preserved: false,
                     preserveSeq: -1 };
        for (var i = span.start + 1; i < span.body; i++) {
            var frame = frames[i];
            var op = frameOp(frame);
            if (op === 'a') {
                head.attrs.push({ seq: frame[1], name: frame[2],
                                  value: frame[3], present: true, flag: false });
            } else if (op === 'f') {
                head.attrs.push({ seq: frame[1], name: frame[2], value: '',
                                  present: frame[3] === true, flag: true });
            } else if (op === 'h') {
                head.binds.push({ seq: frame[1], event: frame[2], id: frame[3] });
            } else if (op === 'e') {
                head.refs.push(frame[1]);
            } else if (op === 'v') {
                head.preserved = true;
                head.preserveSeq = frame[1];
            }
        }
        return head;
    }

    // `(seq, name)` and `(seq, event)` order — the merge keys apply.b keeps
    // its slots in, so the flattened frames come out in the order the
    // serializer reads them from.
    function compareSlot(a, b) {
        if (a.seq < b.seq) { return -1; }
        if (a.seq > b.seq) { return 1; }
        if (a.name < b.name) { return -1; }
        if (a.name > b.name) { return 1; }
        return 0;
    }

    function compareBind(a, b) {
        if (a.seq < b.seq) { return -1; }
        if (a.seq > b.seq) { return 1; }
        if (a.event < b.event) { return -1; }
        if (a.event > b.event) { return 1; }
        return 0;
    }

    function putSlot(node, slot) {
        for (var i = 0; i < node.attrs.length; i++) {
            var order = compareSlot(node.attrs[i], slot);
            if (order === 0) { node.attrs[i] = slot; return; }
            if (order > 0) { node.attrs.splice(i, 0, slot); return; }
        }
        node.attrs.push(slot);
    }

    function dropSlot(node, probe) {
        for (var i = 0; i < node.attrs.length; i++) {
            if (compareSlot(node.attrs[i], probe) === 0) {
                node.attrs.splice(i, 1);
                return true;
            }
        }
        return false;
    }

    function putBind(node, bind) {
        for (var i = 0; i < node.binds.length; i++) {
            var order = compareBind(node.binds[i], bind);
            if (order === 0) { node.binds[i] = bind; return; }
            if (order > 0) { node.binds.splice(i, 0, bind); return; }
        }
        node.binds.push(bind);
    }

    function dropBind(node, probe) {
        for (var i = 0; i < node.binds.length; i++) {
            if (compareBind(node.binds[i], probe) === 0) {
                node.binds.splice(i, 1);
                return true;
            }
        }
        return false;
    }

    // ---------------------------------------------------------------- nodes

    function makeNode() {
        return {
            kind: 0, seq: 0, tag: '', key: '', html: '', raw: false,
            failed: false, component: 0, typeName: '',
            attrs: [], binds: [], refs: [], preserved: false, preserveSeq: -1,
            kids: [], parent: null,
            // An element's or a text node's DOM node; a markup node's list of
            // them. A transparent container owns none of its own.
            dom: null,
            doms: null,
            // The attribute list last written to `dom`, in written order, so a
            // change of ORDER can be told from a change of value.
            applied: null,
            // Which live properties this element has been given, so removing
            // the slot can put the property back rather than leave it stale.
            live: null
        };
    }

    // The DOM nodes this logical node contributes to its host element, in
    // document order. A transparent container answers its children's.
    function collectDom(node, out) {
        if (node.kind === SPAN_ELEMENT || node.kind === SPAN_TEXT) {
            if (node.dom) { out.push(node.dom); }
            return out;
        }
        if (node.kind === SPAN_MARKUP) {
            if (node.doms) {
                for (var i = 0; i < node.doms.length; i++) { out.push(node.doms[i]); }
            }
            return out;
        }
        for (var k = 0; k < node.kids.length; k++) { collectDom(node.kids[k], out); }
        return out;
    }

    // The first DOM node this logical node contributes, or null when it
    // contributes none — an empty fragment, a mount whose component rendered
    // nothing, a markup node holding "".
    function firstDom(node) {
        if (node.kind === SPAN_ELEMENT || node.kind === SPAN_TEXT) { return node.dom; }
        if (node.kind === SPAN_MARKUP) {
            return (node.doms && node.doms.length > 0) ? node.doms[0] : null;
        }
        for (var k = 0; k < node.kids.length; k++) {
            var found = firstDom(node.kids[k]);
            if (found) { return found; }
        }
        return null;
    }

    function indexInParent(node) {
        var up = node.parent;
        if (!up) { return -1; }
        for (var i = 0; i < up.kids.length; i++) {
            if (up.kids[i] === node) { return i; }
        }
        return -1;
    }

    // ---------------------------------------------------------------- applier

    function Applier(options) {
        options = options || {};
        this.document = options.document ||
            (typeof document !== 'undefined' ? document : null);
        // Where component 0's children live. Everything below it is latte's.
        this.host = options.host || null;
        this.roots = new Map();
        this.faults = [];
        // element -> logical node, so a delegated listener can walk up from
        // `event.target` and read the binds that are on the node RIGHT NOW.
        this.nodes = new WeakMap();
        this.onfault = options.onfault || null;
    }

    Applier.prototype.fault = function (text) {
        this.faults.push(text);
        if (this.onfault) { this.onfault(text); }
    };

    // ---- the DOM seam ------------------------------------------------------

    // The nearest element at or above `node`, which is where `node`'s DOM
    // contribution lives. Component 0's root has no parent and answers the
    // configured host.
    Applier.prototype.hostOf = function (node) {
        var walk = node;
        while (walk) {
            if (walk.kind === SPAN_ELEMENT && walk.dom) { return walk.dom; }
            walk = walk.parent;
        }
        return this.host;
    };

    // The DOM node a child inserted at logical `index` of `parent` must go
    // before, or null to append. It is the first DOM node of the first later
    // sibling that has one; failing that, whatever follows `parent` itself —
    // which is only a question at all because a transparent container's
    // children share their host with everything around it.
    Applier.prototype.anchorFor = function (parent, index) {
        for (var i = index; i < parent.kids.length; i++) {
            var found = firstDom(parent.kids[i]);
            if (found) { return found; }
        }
        if (parent.kind === SPAN_ELEMENT) { return null; }
        var up = parent.parent;
        if (!up) { return null; }
        var at = indexInParent(parent);
        if (at < 0) { return null; }
        return this.anchorFor(up, at + 1);
    };

    // Put every DOM node this logical node holds into `host` before `anchor`.
    // For a node built from frames these are fresh; for a re-inserted mount
    // they are the ones the component already has, and `insertBefore` MOVES
    // them. That is rule 2 at the top of this file, and it is the whole reason
    // this is one function rather than two.
    function attach(node, host, anchor) {
        if (!host) { return; }
        var doms = collectDom(node, []);
        for (var i = 0; i < doms.length; i++) {
            host.insertBefore(doms[i], anchor);
        }
    }

    function detach(node) {
        var doms = collectDom(node, []);
        for (var i = 0; i < doms.length; i++) {
            var dom = doms[i];
            if (dom.parentNode) { dom.parentNode.removeChild(dom); }
        }
    }

    Applier.prototype.parseMarkup = function (html) {
        var doc = this.document;
        if (!doc) { return []; }
        // A <template> is the one element whose innerHTML parses in a context
        // that accepts anything, so `<tr>` and `<td>` survive rather than
        // being dropped by the in-body insertion mode.
        var holder = doc.createElement('template');
        holder.innerHTML = html === null || html === undefined ? '' : String(html);
        var out = [];
        var kids = holder.content ? holder.content.childNodes : holder.childNodes;
        for (var i = 0; i < kids.length; i++) { out.push(kids[i]); }
        return out;
    };

    // ---- attributes --------------------------------------------------------

    // serialize.b's `emit_attributes`: deduplicate by name, the LAST slot
    // wins, and an absent flag is a tombstone that removes the name rather
    // than nothing at all. The winner keeps the position of its last slot,
    // which is why this answers an ordered list and not a map.
    function effectiveAttrs(node) {
        var winner = bareMap();
        var i;
        for (i = 0; i < node.attrs.length; i++) { winner[node.attrs[i].name] = i; }
        var out = [];
        for (i = 0; i < node.attrs.length; i++) {
            var slot = node.attrs[i];
            if (winner[slot.name] !== i) { continue; }
            if (!slot.present) { continue; }
            out.push({ name: slot.name, value: slot.value });
        }
        return out;
    }

    // The three IDL attributes that stop reflecting their content attribute
    // once a user has touched the control. Setting `value=""` on an <input>
    // the user has typed into changes nothing visible; setting `.value` does.
    function livePropertyFor(el, name) {
        var tag = el.tagName;
        if (name === 'value' &&
            (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT')) {
            return { prop: 'value', empty: '' };
        }
        if (name === 'checked' && tag === 'INPUT') {
            return { prop: 'checked', empty: false };
        }
        if (name === 'selected' && tag === 'OPTION') {
            return { prop: 'selected', empty: false };
        }
        return null;
    }

    // A live property is written only when it DIFFERS. That is what keeps a
    // bound <input> from losing the caret on every keystroke: the round trip
    // echoes the value the field already holds, and an equal write would still
    // move the selection to the end. The stated rule is "skip when the element
    // is document.activeElement and already equal"; equality alone is the same
    // rule with one fewer way to get it wrong, and it holds for an element
    // that is about to be focused too.
    function writeLiveProperty(el, prop, value) {
        try {
            if (el[prop] === value) { return; }
            el[prop] = value;
        } catch (err) {
            // A property a browser refuses to set is not worth ending a batch
            // over; the attribute below it is already written.
        }
    }

    Applier.prototype.syncAttrs = function (node, component) {
        var el = node.dom;
        if (!el || !el.setAttribute) { return; }
        var want = [];
        var effective = effectiveAttrs(node);
        var i;
        for (i = 0; i < effective.length; i++) {
            var name = effective[i].name;
            if (attributeNameIsRefused(name) || !attributeNameIsSafe(name)) {
                // Recorded once per sync rather than once per edit, because a
                // name this bad can only arrive from a hand-built batch and
                // saying it every time is the useful behaviour for the one
                // reader who will ever see it.
                this.fault('component ' + component + ': ' +
                           JSON.stringify(name) + ' is not a usable attribute name');
                continue;
            }
            want.push(effective[i]);
        }

        var applied = node.applied || [];
        var sameOrder = applied.length === want.length;
        if (sameOrder) {
            for (i = 0; i < want.length; i++) {
                if (applied[i].name !== want[i].name) { sameOrder = false; break; }
            }
        }
        if (sameOrder) {
            for (i = 0; i < want.length; i++) {
                if (applied[i].value !== want[i].value) {
                    el.setAttribute(want[i].name, want[i].value);
                }
            }
        } else {
            // The serializer writes an attribute at the position of its LAST
            // slot, so a reordering changes the HTML. `setAttribute` on a name
            // the element already has keeps the old position, so the only way
            // to land on the same document is to write the run again.
            for (i = 0; i < applied.length; i++) { el.removeAttribute(applied[i].name); }
            for (i = 0; i < want.length; i++) {
                el.setAttribute(want[i].name, want[i].value);
            }
        }

        // Live properties, from the same effective list. A name that was
        // applied last time and is gone now goes back to its empty value —
        // otherwise clearing a bound field would leave the old text on screen.
        var live = bareMap();
        for (i = 0; i < want.length; i++) {
            var rule = livePropertyFor(el, want[i].name);
            if (!rule) { continue; }
            live[want[i].name] = true;
            if (rule.prop === 'checked' || rule.prop === 'selected') {
                writeLiveProperty(el, rule.prop, true);
            } else {
                writeLiveProperty(el, rule.prop, want[i].value);
            }
        }
        if (node.live) {
            for (var gone in node.live) {
                if (live[gone]) { continue; }
                var back = livePropertyFor(el, gone);
                if (back) { writeLiveProperty(el, back.prop, back.empty); }
            }
        }
        node.live = live;

        node.applied = want;
    };

    // ---- building from frames ---------------------------------------------

    Applier.prototype.build = function (frames, span, component) {
        var node = makeNode();
        node.kind = span.kind;
        node.seq = span.seq;
        node.tag = span.tag;
        node.key = span.key;
        node.html = span.html;
        node.raw = span.raw;
        node.failed = span.failed;
        node.component = span.id;
        node.typeName = span.typeName;

        var i;
        if (span.kind === SPAN_ELEMENT) {
            var head = readHead(frames, span);
            for (i = 0; i < head.attrs.length; i++) { node.attrs.push(head.attrs[i]); }
            for (i = 0; i < head.binds.length; i++) { node.binds.push(head.binds[i]); }
            for (i = 0; i < head.refs.length; i++) { node.refs.push(head.refs[i]); }
            node.preserved = head.preserved;
            node.preserveSeq = head.preserveSeq;
            node.dom = this.makeElement(node.tag);
            if (node.dom) { this.nodes.set(node.dom, node); }
            this.syncAttrs(node, component);
        }

        if (span.kind === SPAN_MOUNT) {
            // A mount frame is a LEAF. Re-inserting one re-parents a live
            // component's existing nodes; building a fresh empty node instead
            // loses its whole subtree silently and for ever, because the
            // child's next update carries only what CHANGED and an unchanged
            // child sends nothing at all.
            var existing = this.roots.get(span.id);
            if (existing) {
                existing.seq = span.seq;
                existing.typeName = span.typeName;
                return existing;
            }
            this.roots.set(span.id, node);
            return node;
        }

        if (span.kind === SPAN_TEXT) {
            node.dom = this.document ? this.document.createTextNode(span.html) : null;
            return node;
        }

        if (span.kind === SPAN_MARKUP) {
            node.doms = this.parseMarkup(span.html);
            return node;
        }

        var kids = scanSpans(frames, span.body, span.stop);
        for (i = 0; i < kids.length; i++) {
            var kid = this.build(frames, kids[i], component);
            kid.parent = node;
            node.kids.push(kid);
        }
        if (span.kind === SPAN_ELEMENT && node.dom) {
            // Appending each child in turn is right even for a transparent
            // one: `attach` flattens it, so a fragment holding three roots
            // lands as three children of this element.
            for (i = 0; i < node.kids.length; i++) {
                attach(node.kids[i], node.dom, null);
            }
        }
        return node;
    };

    Applier.prototype.makeElement = function (tag) {
        if (!this.document) { return null; }
        try {
            return this.document.createElement(tag);
        } catch (err) {
            // frames.b's `tag_name_is_safe` refuses a name that could carry a
            // `>` out of its slot, so nothing well-formed reaches this; a
            // hand-built batch does, and a throw here would abandon the rest
            // of the stream.
            this.fault('cannot create an element named ' + JSON.stringify(tag));
            return this.document.createElement('span');
        }
    };

    // ---- the kind rules ----------------------------------------------------
    //
    // lanes/W5.md § "THE APPLIER CONTRACT". Both appliers refuse a
    // kind-mismatched edit and refuse it identically: the edit is DROPPED, one
    // fault is recorded, the rest of the stream applies, and the circuit does
    // NOT end.
    //
    // Two sentence shapes, and which one an edit gets is decided by WHAT the
    // check is about, not by whether the opcode happens to carry a number:
    //
    //   about the child at an index  ->  "{op} {index} needs a … node, not a … node"
    //   about the CURRENT node       ->  "{op} needs a … node, not a … node"
    //
    // So `set_text`, `set_markup` and `step_in` name their index and the other
    // eight do not. `insert 3 needs a container node` would be pointing at the
    // position the new child was going to, which is not the thing that is
    // wrong.

    Applier.prototype.faultChildKind = function (component, op, index, want, got) {
        this.fault('component ' + component + ': ' + op + ' ' + index +
                   ' needs a ' + want + ' node, not a ' + kindName(got) + ' node');
    };

    Applier.prototype.faultHereKind = function (component, op, want, got) {
        this.fault('component ' + component + ': ' + op +
                   ' needs a ' + want + ' node, not a ' + kindName(got) + ' node');
    };

    // The child at `index`, checked for range and then for kind. `want` is the
    // kind this edit needs.
    Applier.prototype.kid = function (parent, index, component, op, want) {
        if (index < 0 || index >= parent.kids.length) {
            this.fault('component ' + component + ': ' + op + ' ' + index +
                       ' of ' + parent.kids.length);
            return null;
        }
        var node = parent.kids[index];
        if (node.kind !== want) {
            this.faultChildKind(component, op, index, kindName(want), node.kind);
            return null;
        }
        return node;
    };

    // `step_in` at a child that is not a container. The two failures it can
    // have are answered DIFFERENTLY, and the difference is load-bearing:
    //
    //   index out of range  ->  descend into a fresh placeholder, because
    //                           there is no node to descend into and the
    //                           matching `step_out` still has to balance.
    //                           This is what apply.b already does.
    //   kind mismatch       ->  descend into THE NODE ITSELF. It exists; it
    //                           simply cannot hold what follows.
    //
    // Descending into the node is what makes the rest of the contract
    // reachable. A placeholder is a fresh `Node`, and a fresh Node's kind is
    // SPAN_ELEMENT — so with a placeholder here, the CURRENT node is a
    // container on every path (the root is a mount, and `step_in` only ever
    // pushes a container or that element-shaped placeholder), the
    // `insert`/`remove`/`relocate` container checks could never fire, and
    // `set_attr` inside a mis-stepped scope would quietly succeed against a
    // throwaway with no fault at all. Stepping into the leaf instead makes
    // every one of those refusals live and every edit under it loud, and it
    // still cannot mutate the leaf: all five attribute edits want an element,
    // all three list edits want a container, and `set_text`/`set_markup`/
    // `step_in` see a childless node and fault on the index.
    Applier.prototype.stepInto = function (parent, index, component) {
        if (index < 0 || index >= parent.kids.length) {
            this.fault('component ' + component + ': step_in ' + index +
                       ' of ' + parent.kids.length);
            return makeNode();
        }
        var node = parent.kids[index];
        if (!isContainer(node.kind)) {
            this.faultChildKind(component, 'step_in', index, 'container', node.kind);
        }
        return node;
    };

    // ---- applying ----------------------------------------------------------

    Applier.prototype.rootFor = function (id) {
        var found = this.roots.get(id);
        if (found) { return found; }
        var made = makeNode();
        made.kind = SPAN_MOUNT;
        made.component = id;
        this.roots.set(id, made);
        if (id !== 0) {
            // The batch is in pre-order, parent before child, exactly so this
            // cannot happen.
            this.fault('update for component ' + id + ' arrived before its mount');
        }
        return made;
    };

    Applier.prototype.apply = function (batch) {
        var frames = (batch && batch.r) ? batch.r : [];
        var updates = (batch && batch.u) ? batch.u : [];
        var disposed = (batch && batch.d) ? batch.d : [];
        var i;
        for (i = 0; i < updates.length; i++) {
            this.run(frames, updates[i]);
        }
        for (i = 0; i < disposed.length; i++) {
            // A disposal for a component this applier never mounted is not a
            // fault: a component can be mounted and dropped inside ONE render
            // pass, in which case its mount frame was truncated away before
            // any batch went out.
            this.roots.delete(disposed[i]);
        }
    };

    Applier.prototype.run = function (frames, update) {
        var component = update && update.c !== undefined ? update.c : 0;
        var edits = (update && update.e) ? update.e : [];
        var stack = [this.rootFor(component)];
        for (var i = 0; i < edits.length; i++) {
            this.one(frames, component, stack, edits[i]);
        }
        if (stack.length !== 1) {
            this.fault('component ' + component + ': the edit stream ended ' +
                       (stack.length - 1) + ' level(s) deep');
        }
    };

    Applier.prototype.one = function (frames, component, stack, edit) {
        var cur = stack[stack.length - 1];
        var op = edit && edit.length > 0 ? edit[0] : '';
        var node, index, host, anchor, span;

        if (op === 'si') {
            stack.push(this.stepInto(cur, edit[1], component));
            return;
        }

        if (op === 'so') {
            if (stack.length <= 1) {
                this.fault('component ' + component + ': step_out at the root');
            } else {
                stack.pop();
            }
            return;
        }

        if (op === 'in') {
            index = edit[1];
            if (!isContainer(cur.kind)) {
                this.faultHereKind(component, 'insert', 'container', cur.kind);
                return;
            }
            span = spanAt(frames, edit[2]);
            if (span === null) {
                this.fault('component ' + component + ': no staged subtree at ' + edit[2]);
                return;
            }
            node = this.build(frames, span, component);
            var at = index;
            if (index < 0 || index > cur.kids.length) {
                this.fault('component ' + component + ': insert at ' + index +
                           ' of ' + cur.kids.length);
                at = cur.kids.length;
            }
            host = this.hostOf(cur);
            anchor = this.anchorFor(cur, at);
            node.parent = cur;
            cur.kids.splice(at, 0, node);
            attach(node, host, anchor);
            return;
        }

        if (op === 'rm') {
            index = edit[1];
            if (!isContainer(cur.kind)) {
                this.faultHereKind(component, 'remove', 'container', cur.kind);
                return;
            }
            if (index < 0 || index >= cur.kids.length) {
                this.fault('component ' + component + ': remove ' + index +
                           ' of ' + cur.kids.length);
                return;
            }
            node = cur.kids[index];
            detach(node);
            cur.kids.splice(index, 1);
            node.parent = null;
            return;
        }

        if (op === 'mv') {
            var from = edit[1];
            var to = edit[2];
            if (!isContainer(cur.kind)) {
                this.faultHereKind(component, 'relocate', 'container', cur.kind);
                return;
            }
            if (from < 0 || from >= cur.kids.length) {
                this.fault('component ' + component + ': move from ' + from +
                           ' of ' + cur.kids.length);
                return;
            }
            node = cur.kids[from];
            detach(node);
            cur.kids.splice(from, 1);
            var target = to;
            if (to < 0 || to > cur.kids.length) {
                this.fault('component ' + component + ': move to ' + to +
                           ' of ' + cur.kids.length);
                target = cur.kids.length;
            }
            host = this.hostOf(cur);
            anchor = this.anchorFor(cur, target);
            cur.kids.splice(target, 0, node);
            node.parent = cur;
            attach(node, host, anchor);
            return;
        }

        if (op === 'ut') {
            node = this.kid(cur, edit[1], component, 'set_text', SPAN_TEXT);
            if (node === null) { return; }
            node.html = edit[2];
            if (node.dom) { node.dom.data = edit[2]; }
            return;
        }

        if (op === 'um') {
            node = this.kid(cur, edit[1], component, 'set_markup', SPAN_MARKUP);
            if (node === null) { return; }
            node.html = edit[2];
            host = this.hostOf(node);
            anchor = this.anchorFor(cur, edit[1] + 1);
            detach(node);
            node.doms = this.parseMarkup(edit[2]);
            attach(node, host, anchor);
            return;
        }

        if (op === 'sa' || op === 'sf') {
            if (cur.kind !== SPAN_ELEMENT) {
                this.faultHereKind(component, op === 'sa' ? 'set_attr' : 'set_flag',
                                   'element', cur.kind);
                return;
            }
            if (op === 'sa') {
                putSlot(cur, { seq: edit[1], name: edit[2], value: edit[3],
                               present: true, flag: false });
            } else {
                putSlot(cur, { seq: edit[1], name: edit[2], value: '',
                               present: edit[3] === true, flag: true });
            }
            this.syncAttrs(cur, component);
            return;
        }

        if (op === 'ra') {
            if (cur.kind !== SPAN_ELEMENT) {
                this.faultHereKind(component, 'remove_attr', 'element', cur.kind);
                return;
            }
            if (!dropSlot(cur, { seq: edit[1], name: edit[2] })) {
                this.fault('component ' + component + ': no attribute ' + edit[1] +
                           ':' + edit[2] + ' to remove');
                return;
            }
            this.syncAttrs(cur, component);
            return;
        }

        if (op === 'sh') {
            if (cur.kind !== SPAN_ELEMENT) {
                this.faultHereKind(component, 'set_handler', 'element', cur.kind);
                return;
            }
            putBind(cur, { seq: edit[1], event: edit[2], id: edit[3] });
            return;
        }

        if (op === 'rh') {
            if (cur.kind !== SPAN_ELEMENT) {
                this.faultHereKind(component, 'remove_handler', 'element', cur.kind);
                return;
            }
            if (!dropBind(cur, { seq: edit[1], event: edit[2] })) {
                this.fault('component ' + component + ': no handler ' + edit[1] +
                           ':' + edit[2] + ' to remove');
            }
            return;
        }

        // A fixed opcode table: an unknown opcode reaches no property and no
        // function, it is recorded and dropped.
        this.fault('component ' + component + ': unknown edit ' + JSON.stringify(op));
    };

    // ---- reading it back ---------------------------------------------------
    //
    // The logical tree as text, in exactly the shape `Builder.dump_tree()`
    // prints: one block per component, headed by its id, frames indented by
    // depth, a mount frame a LEAF whose content is the block below. So a
    // failing gate-3 case reads as two frame lists side by side rather than
    // two long strings, and the comparison is about the tree the applier
    // reconstructed rather than a string that looks right.
    //
    // It walks the applier's own tree and never the DOM, which is what makes
    // it evidence about the applier and not about the browser.

    function emitNode(node, buffer) {
        var i;
        if (node.kind === SPAN_ELEMENT) {
            buffer.frames.push({ text: node.seq + ' open ' + node.tag, opens: true });
            for (i = 0; i < node.attrs.length; i++) {
                var slot = node.attrs[i];
                if (slot.flag) {
                    buffer.frames.push({ text: slot.seq + ' flag ' + slot.name + '=' +
                                               (slot.present ? 'true' : 'false') });
                } else {
                    buffer.frames.push({ text: slot.seq + ' attr ' + slot.name + '=' + slot.value });
                }
            }
            for (i = 0; i < node.binds.length; i++) {
                buffer.frames.push({ text: node.binds[i].seq + ' on:' +
                                           node.binds[i].event + ' -> ' + node.binds[i].id });
            }
            for (i = 0; i < node.refs.length; i++) {
                buffer.frames.push({ text: node.refs[i] + ' ref' });
            }
            if (node.preserved) {
                buffer.frames.push({ text: node.preserveSeq + ' preserve' });
            }
            for (i = 0; i < node.kids.length; i++) { emitNode(node.kids[i], buffer); }
            buffer.frames.push({ text: '/close', closes: true });
            return;
        }
        if (node.kind === SPAN_TEXT) {
            buffer.frames.push({ text: node.seq + ' text ' + node.html });
            return;
        }
        if (node.kind === SPAN_MARKUP) {
            buffer.frames.push({ text: node.seq + (node.raw ? ' raw ' : ' const ') + node.html });
            return;
        }
        if (node.kind === SPAN_MOUNT) {
            buffer.frames.push({ text: node.seq + ' child ' + node.typeName +
                                       ' #' + node.component });
            var child = { frames: [], nested: [] };
            for (i = 0; i < node.kids.length; i++) { emitNode(node.kids[i], child); }
            buffer.nested.push({ id: node.component, buffer: child });
            return;
        }
        var opener, closer;
        if (node.kind === SPAN_REGION) {
            opener = node.seq + ' region ' + node.key;
            closer = '/region';
        } else if (node.kind === SPAN_FRAGMENT) {
            opener = node.seq + ' fragment';
            closer = '/fragment';
        } else {
            opener = node.seq + ' boundary failed=' + (node.failed ? 'true' : 'false');
            closer = '/boundary';
        }
        buffer.frames.push({ text: opener, opens: true });
        for (i = 0; i < node.kids.length; i++) { emitNode(node.kids[i], buffer); }
        buffer.frames.push({ text: closer, closes: true });
    }

    // frames.b's `Frames.dump`: one frame per line, indented by depth.
    function dumpFrames(frames) {
        var out = '';
        var depth = 0;
        for (var i = 0; i < frames.length; i++) {
            if (frames[i].closes) { depth -= 1; }
            if (depth < 0) { depth = 0; }
            for (var pad = 0; pad < depth; pad++) { out += '  '; }
            out += frames[i].text + '\n';
            if (frames[i].opens) { depth += 1; }
        }
        return out;
    }

    function dumpBuffer(id, buffer) {
        var out = 'component ' + id + '\n' + dumpFrames(buffer.frames);
        var nested = buffer.nested.slice();
        nested.sort(function (a, b) { return a.id - b.id; });
        for (var i = 0; i < nested.length; i++) {
            out += dumpBuffer(nested[i].id, nested[i].buffer);
        }
        return out;
    }

    Applier.prototype.dump = function () {
        var root = this.roots.get(0);
        var buffer = { frames: [], nested: [] };
        if (root) {
            for (var i = 0; i < root.kids.length; i++) { emitNode(root.kids[i], buffer); }
        }
        return dumpBuffer(0, buffer);
    };

    // The HTML the browser holds. Not the applier's own serialization — the
    // DOM's, which is the whole reason a browser leg proves something a text
    // test cannot.
    Applier.prototype.html = function () {
        return this.host ? this.host.innerHTML : '';
    };

    // ---------------------------------------------------------------- wire
    //
    // Every number that crosses is an integer. wire.b's reader REFUSES a
    // fraction or an exponent rather than truncating one, because `{"b":1e999}`
    // quietly becoming an ack for batch 1 is the shape that ships — so a
    // fractional `clientX` on a zoomed page must be rounded HERE.
    var MAX_WIRE_INT = 9007199254740991;

    function wireInt(value) {
        var n = Number(value);
        if (!isFinite(n)) { return 0; }
        n = Math.trunc(n);
        if (n > MAX_WIRE_INT) { return MAX_WIRE_INT; }
        if (n < -MAX_WIRE_INT) { return -MAX_WIRE_INT; }
        return n;
    }

    // A lone surrogate is legal in a JavaScript string and REFUSED by wire.b's
    // reader ("a high surrogate with no low surrogate"), which would end the
    // circuit with a `bye protocol` over one bad character in a text field.
    // JSON.stringify escapes it faithfully rather than repairing it, so the
    // repair is here.
    function wireText(value) {
        var text = value === null || value === undefined ? '' : String(value);
        var out = '';
        var clean = true;
        for (var i = 0; i < text.length; i++) {
            var code = text.charCodeAt(i);
            if (code >= 0xD800 && code <= 0xDBFF) {
                var next = i + 1 < text.length ? text.charCodeAt(i + 1) : 0;
                if (next >= 0xDC00 && next <= 0xDFFF) {
                    out += text.charAt(i) + text.charAt(i + 1);
                    i += 1;
                    continue;
                }
                out += '�';
                clean = false;
                continue;
            }
            if (code >= 0xDC00 && code <= 0xDFFF) {
                out += '�';
                clean = false;
                continue;
            }
            out += text.charAt(i);
        }
        return clean ? text : out;
    }

    // ---------------------------------------------------------------- circuit

    function Circuit(options) {
        options = options || {};
        this.url = options.url || '';
        this.id = options.id || '';
        this.document = options.document ||
            (typeof document !== 'undefined' ? document : null);
        this.host = options.host || null;
        this.enhanceNav = options.enhanceNav !== false;
        this.maxMessage = options.maxMessage || 65536;
        this.backoff = options.backoff || [250, 500, 1000, 2000, 5000, 10000];
        this.open = options.open || defaultOpen;
        this.log = options.log || defaultLog;

        // The clock and the timer are injected for the same reason the socket
        // is: a deadline that can only be observed by waiting is a deadline no
        // gate can assert. `tests/js_apply.js` drives all three by hand.
        //
        // WRAPPED, never stored bare. `window.setTimeout` is a method of
        // `window`, so `this.setTimeout(fn, ms)` on a bare copy calls it with
        // a `Circuit` as its receiver and every browser answers
        // `TypeError: Illegal invocation`. Nothing here would have armed a
        // fence or reconnected a dropped socket, and no rig in
        // `tests/js_apply.js` could see it because every one of them injects a
        // timer — see § 10 there, which injects none. A closure and not
        // `.bind(window)`: this file also loads under node, where `setTimeout`
        // is a bare function and `window` does not exist. `Ranges` wraps
        // `requestAnimationFrame` the same way.
        this.setTimeout = options.setTimeout ||
            (typeof setTimeout !== 'undefined'
                ? function (fn, ms) { return setTimeout(fn, ms); }
                : null);
        this.clearTimeout = options.clearTimeout ||
            (typeof clearTimeout !== 'undefined'
                ? function (id) { return clearTimeout(id); }
                : null);
        this.now = options.now || function () { return Date.now(); };

        // How long a fenced message may go unanswered before this end treats
        // the socket as dead. See `fence` below for what that means and what
        // it must exceed.
        this.answerMs = options.answerMs || 15000;
        this.sequence = 0;
        // Fenced messages awaiting their `seen`, oldest first. The server
        // answers in the order it received them, so only the head is ever
        // checked and an answer for `n` retires everything at or before it.
        this.outstanding = [];
        this.fenceTimer = null;
        this.onstall = options.onstall || null;

        this.applier = new Applier({
            document: this.document,
            host: this.host,
            onfault: this.log.error
        });
        // The scroll reporter. It is part of the circuit and not of the page
        // because the only thing it does is send a message, and a reporter
        // with no circuit to send on would be a listener that costs a frame
        // and produces nothing.
        this.ranges = new Ranges({
            circuit: this,
            host: this.host,
            maxWindow: options.maxWindow,
            schedule: options.schedule
        });
        this.socket = null;
        this.attached = false;
        this.lastBatch = 0;
        this.ended = false;
        this.endKind = '';
        this.attempt = 0;
        this.timer = null;
        this.listeners = [];
        this.registry = bareMap();
        this.onbatch = options.onbatch || null;
        this.onbye = options.onbye || null;
        this.onhello = options.onhello || null;
    }

    function defaultOpen(url) { return new WebSocket(url); }

    var defaultLog = {
        error: function (text) {
            if (typeof console !== 'undefined' && console.error) { console.error(text); }
        },
        warn: function (text) {
            if (typeof console !== 'undefined' && console.warn) { console.warn(text); }
        }
    };

    /// Register a function the SERVER may call by name. The name selects from
    /// this registry and nothing else: nothing here evaluates a string and
    /// nothing reads a property named on the wire off an object that has a
    /// prototype.
    Circuit.prototype.register = function (name, fn) {
        if (typeof name !== 'string' || typeof fn !== 'function') { return false; }
        this.registry[name] = fn;
        return true;
    };

    Circuit.prototype.start = function () {
        this.listen();
        this.ranges.watch();
        this.connect();
    };

    Circuit.prototype.connect = function () {
        if (this.ended) { return; }
        var self = this;
        var socket;
        try {
            socket = this.open(this.url);
        } catch (err) {
            this.retry();
            return;
        }
        this.socket = socket;
        socket.onmessage = function (event) {
            // A socket this end has already given up on may still deliver. Its
            // frames belong to a circuit state that no longer exists.
            if (self.socket !== socket) { return; }
            self.receive(event.data);
        };
        // `stalled` closes the socket and reconnects immediately, and a close
        // it started would otherwise arrive later and start a SECOND reconnect.
        // Identity, not a flag: whatever detached this socket already did the
        // deciding.
        socket.onclose = function () {
            if (self.socket !== socket) { return; }
            self.dropped();
        };
        socket.onerror = function () { /* onclose follows; one retry, not two */ };
    };

    Circuit.prototype.dropped = function () {
        this.socket = null;
        // Nothing outstanding survives a socket. The reconnect re-attaches or
        // resumes, and those carry their own fences; carrying the old ones
        // over would time out a message the server can no longer answer.
        this.clearFences();
        if (this.ended) { return; }
        this.retry();
    };

    Circuit.prototype.retry = function () {
        var self = this;
        var wait = this.backoff[Math.min(this.attempt, this.backoff.length - 1)];
        this.attempt += 1;
        // A little jitter, so a server that dropped every circuit at once does
        // not get all of them back in the same millisecond.
        wait = wait + Math.floor(Math.random() * (wait / 4));
        if (!this.setTimeout) { return; }
        this.timer = this.setTimeout(function () { self.connect(); }, wait);
    };

    Circuit.prototype.send = function (message) {
        if (!this.socket || this.socket.readyState !== 1) { return false; }
        var text = JSON.stringify(message);
        if (text.length > this.maxMessage) {
            // Sending it would end the circuit with a `bye limit`. Refusing it
            // here costs one message and keeps the tab alive.
            this.log.error('latte: a ' + message.t + ' message of ' + text.length +
                           ' bytes is over the ' + this.maxMessage + ' byte cap');
            return false;
        }
        this.socket.send(text);
        return true;
    };

    // ------------------------------------------------------------ the fence
    //
    // BLOCKERS.md B11. Every server frame v1 had was a statement about the
    // PAGE — `hello`, `batch`, `err`, `bye`, `js`, `nav` — and none of them
    // said "I received your message and it changed nothing". So a click on a
    // button whose row had already left the page produced no frame at all, and
    // this end sat in `onmessage` with a live-looking socket and a page that
    // never acknowledged the click. A browser cannot avoid sending such a
    // message; a suite can, which is exactly why a suite never found it.
    //
    // `n` on an outgoing message asks the server for a fence. The server sends
    // `{"t":"seen","n":n}` AFTER whatever else the message produced, so an
    // answer means FINISHED and this end needs no case analysis over what else
    // arrived in between.
    //
    // What the deadline must exceed: the longest a handler may occupy the
    // circuit fiber, because the fence is sent after that handler returns.
    // Crossing it is NOT treated as an error — the circuit is retained on the
    // server for its retention window, so this end drops the socket and
    // reconnects, and `resume` replays whatever it missed. A false positive
    // therefore costs a reconnect, never the page.
    Circuit.prototype.sendFenced = function (message) {
        this.sequence += 1;
        message.n = this.sequence;
        if (!this.send(message)) {
            // Nothing went out, so nothing is owed. Rolling the number back
            // would be wrong — a message this end believes it sent and the
            // server never saw must not reuse a number a later one will get.
            return false;
        }
        this.outstanding.push({ n: this.sequence, t: message.t, at: this.now() });
        this.armFence();
        return true;
    };

    // With no timer at all — a host that has no `setTimeout` and none injected
    // — there is no deadline. That is a real hole and it is stated rather than
    // hidden: every browser has `setTimeout`, and `tests/js_apply.js` injects a
    // fake one, so the only way to reach this branch is to pass `null` on
    // purpose.
    Circuit.prototype.armFence = function () {
        if (!this.setTimeout || this.fenceTimer !== null) { return; }
        if (this.outstanding.length === 0) { return; }
        var self = this;
        var waited = this.now() - this.outstanding[0].at;
        var left = this.answerMs - waited;
        if (left < 0) { left = 0; }
        this.fenceTimer = this.setTimeout(function () {
            self.fenceTimer = null;
            self.checkFences();
        }, left);
    };

    Circuit.prototype.disarmFence = function () {
        if (this.fenceTimer !== null && this.clearTimeout) {
            this.clearTimeout(this.fenceTimer);
        }
        this.fenceTimer = null;
    };

    Circuit.prototype.checkFences = function () {
        if (this.ended || this.outstanding.length === 0) { return; }
        var head = this.outstanding[0];
        if (this.now() - head.at >= this.answerMs) {
            this.stalled(head);
            return;
        }
        this.armFence();
    };

    /// A fenced message went unanswered. The socket is up as far as this end
    /// can see and the server has stopped answering, which is the one state
    /// v1.0 could not distinguish from "nothing happened".
    Circuit.prototype.stalled = function (head) {
        this.log.error('latte: the server did not answer a ' + head.t +
                       ' within ' + this.answerMs + ' ms — reconnecting');
        this.clearFences();
        if (this.onstall) { this.onstall(head); }
        if (this.socket) {
            var socket = this.socket;
            this.socket = null;
            try { socket.close(); } catch (err) { /* already closing */ }
            // `close()` on a socket whose peer is gone may never fire
            // `onclose`, so the retry is started here rather than waited for.
            // `dropped` is idempotent about a socket that is already null.
            this.retry();
        }
    };

    Circuit.prototype.clearFences = function () {
        this.outstanding = [];
        this.disarmFence();
    };

    Circuit.prototype.onSeen = function (message) {
        var number = wireInt(message.n);
        var kept = [];
        for (var i = 0; i < this.outstanding.length; i++) {
            // The server answers in order, so an answer for `n` retires every
            // message at or before it. Keeping the later ones by number rather
            // than by position means a fence this end somehow missed cannot
            // strand every message behind it forever.
            if (this.outstanding[i].n > number) { kept.push(this.outstanding[i]); }
        }
        this.outstanding = kept;
        this.disarmFence();
        this.armFence();
    };

    Circuit.prototype.receive = function (data) {
        if (typeof data !== 'string') {
            this.log.error('latte: a binary frame arrived on a wire v1 circuit');
            return;
        }
        var message;
        try {
            message = JSON.parse(data);
        } catch (err) {
            this.log.error('latte: the server sent something that is not JSON');
            return;
        }
        if (message === null || typeof message !== 'object') { return; }
        var kind = message.t;
        if (kind === 'hello') { this.onHello(message); return; }
        if (kind === 'batch') { this.onBatch(message); return; }
        if (kind === 'err') {
            // A failure the circuit SURVIVED. `m` is a trace id, never a
            // server message.
            this.log.error('latte: ' + message.k + ' ' + message.m);
            return;
        }
        if (kind === 'seen') { this.onSeen(message); return; }
        if (kind === 'bye') { this.onBye(message); return; }
        if (kind === 'js') { this.onJs(message); return; }
        if (kind === 'nav') { this.onNav(message); return; }
        this.log.warn('latte: unknown server frame ' + JSON.stringify(kind));
    };

    Circuit.prototype.onHello = function (message) {
        if (message.v !== WIRE_VERSION) {
            // A client that does not know the protocol version must stop
            // rather than guess what the next frame means.
            this.stop('version', 'this page speaks wire v' + WIRE_VERSION +
                      ' and the server speaks v' + message.v);
            return;
        }
        // THE ID IS COMPARED ONLY WHERE THIS END IS ABOUT TO ATTACH.
        //
        // This is the client half of `Circuit.on_attach`'s rule — "the id the
        // client presents must be the one this circuit was opened with" — and
        // it holds for an attach and for nothing else.
        //
        // A RECONNECT always arrives with a different id, and that is the
        // protocol rather than an error. Nothing in a WebSocket handshake says
        // which circuit a returning client wants, so the server can only open
        // a FRESH circuit for the new socket and announce ITS id here; this
        // end then sends `resume` naming the circuit it remembers, and
        // `CircuitSet.adopt` moves the socket to it. See `adopt`'s own
        // comment in circuit.b, and `tests/circuit_live.b` § 8.2, which
        // asserts that the second hello's id is NOT the one being resumed.
        // Comparing ids here refused every reconnect the whole `adopt`
        // mechanism exists for.
        //
        // `this.attached` is the gate because it is already what chooses
        // `resume` over `attach` below, so the two can never disagree about
        // which message is going out. It is set by the first batch: a circuit
        // that never received one has nothing to resume and re-attaches.
        if (!this.attached && this.id && message.c && message.c !== this.id) {
            this.stop('forbidden', 'the socket belongs to a different circuit');
            return;
        }
        // Only ever on the attach path — `this.id` must stay the id of the
        // circuit being resumed, not the id of the fresh one the socket
        // landed on.
        if (!this.id) { this.id = message.c; }
        if (typeof message.mx === 'number' && message.mx > 0) {
            this.maxMessage = message.mx;
        }
        this.attempt = 0;
        if (this.onhello) { this.onhello(message); }
        if (this.attached) {
            this.sendFenced({ t: 'resume', c: this.id, a: wireInt(this.lastBatch) });
        } else {
            this.sendFenced({ t: 'attach', c: this.id, u: this.here() });
        }
    };

    Circuit.prototype.here = function () {
        if (typeof location === 'undefined') { return '/'; }
        return location.pathname + location.search;
    };

    Circuit.prototype.onBatch = function (message) {
        var number = wireInt(message.b);
        if (number <= this.lastBatch) {
            // A replayed batch this end already applied. Acking it again is
            // free and keeps the server's retention window moving.
            this.send({ t: 'ack', b: number });
            return;
        }
        this.attached = true;
        this.applier.apply(message);
        this.lastBatch = number;
        this.send({ t: 'ack', b: number });
        // A batch can mount a list, unmount one, or change how many rows one
        // holds, and every one of those changes what window the client should
        // be asking for. Without this a list that grew under a stationary
        // scroll position would keep the window it had until the user touched
        // the trackpad. It cannot loop: `report` sends nothing for a window it
        // already sent, and `apply_range` answers false for a window that did
        // not move, so a batch and a range settle in one round.
        this.ranges.forget();
        this.ranges.request();
        if (this.onbatch) { this.onbatch(message, this.applier); }
    };

    Circuit.prototype.onBye = function (message) {
        this.ended = true;
        this.endKind = message.k;
        // `bye` is the last frame on a circuit, so the server will never fence
        // anything else. Every outstanding deadline is answered by it.
        this.clearFences();
        if (this.timer && this.clearTimeout) { this.clearTimeout(this.timer); }
        this.timer = null;
        if (this.socket) {
            try { this.socket.close(); } catch (err) { /* already closing */ }
            this.socket = null;
        }
        this.log.error('latte: the circuit ended — ' + message.k + ': ' + message.m);
        if (this.onbye) { this.onbye(message); }
    };

    Circuit.prototype.stop = function (kind, why) {
        this.onBye({ k: kind, m: why });
    };

    Circuit.prototype.onJs = function (message) {
        var call = wireInt(message.i);
        var fn = this.registry[message.f];
        if (typeof fn !== 'function') {
            this.send({ t: 'js', i: call, ok: false,
                        v: 'no function is registered as ' + wireText(message.f) });
            return;
        }
        var args = [];
        if (message.a && message.a.length) {
            for (var i = 0; i < message.a.length; i++) { args.push(String(message.a[i])); }
        }
        var value;
        try {
            value = fn.apply(null, args);
        } catch (err) {
            this.send({ t: 'js', i: call, ok: false,
                        v: wireText(err && err.message ? err.message : String(err)) });
            return;
        }
        this.send({ t: 'js', i: call, ok: true,
                    v: value === undefined || value === null ? '' : wireText(String(value)) });
    };

    Circuit.prototype.onNav = function (message) {
        var target = message.u;
        if (typeof target !== 'string' || !navTargetIsLocal(target)) {
            this.log.error('latte: the server asked to navigate somewhere that is not a local path');
            return;
        }
        if (typeof location !== 'undefined') { location.assign(target); }
    };

    // circuit.b's `nav_target_is_local`, applied on this side too. The server
    // already refuses a target that is not same-origin and path-only; a client
    // that trusts a frame it can check for itself is a client one compromised
    // server turns into an open redirect.
    function navTargetIsLocal(url) {
        if (typeof url !== 'string' || url.length === 0) { return false; }
        if (url.charCodeAt(0) !== 47) { return false; }
        if (url.length > 1 && url.charCodeAt(1) === 47) { return false; }
        for (var i = 0; i < url.length; i++) {
            var byte = url.charCodeAt(i);
            if (byte < 32 || byte === 127) { return false; }
            if (byte === 92) { return false; }
        }
        var path = url.split('?')[0].split('#')[0];
        var pieces = path.split('/');
        for (var p = 0; p < pieces.length; p++) {
            if (pieces[p] === '..') { return false; }
        }
        return true;
    }

    // ---- delegation --------------------------------------------------------

    Circuit.prototype.listen = function () {
        if (!this.host || !this.host.addEventListener) { return; }
        var self = this;
        for (var i = 0; i < EVENT_NAMES.length; i++) {
            var name = EVENT_NAMES[i];
            var capture = eventCaptures(name);
            var listener = (function (eventName) {
                return function (event) { self.dispatch(eventName, event); };
            })(name);
            this.host.addEventListener(name, listener, capture);
            this.listeners.push({ name: name, listener: listener, capture: capture });
        }
        if (this.enhanceNav) { this.listenNav(); }
    };

    Circuit.prototype.unlisten = function () {
        if (!this.host || !this.host.removeEventListener) { return; }
        for (var i = 0; i < this.listeners.length; i++) {
            var row = this.listeners[i];
            this.host.removeEventListener(row.name, row.listener, row.capture);
        }
        this.listeners = [];
        this.ranges.unwatch();
    };

    // The handler bound to `name` on this node RIGHT NOW. Never cached: slot
    // ids are never reused, so a table built when a batch arrived and read
    // when a click happened delivers the click to a component that has left
    // the page. Where one element carries two binds for one event — two
    // sequence numbers, one name — the LAST wins, which is the rule
    // `emit_attributes` already applies to a duplicated attribute.
    function handlerIdFor(node, name) {
        var id = 0;
        for (var i = 0; i < node.binds.length; i++) {
            if (node.binds[i].event === name) { id = node.binds[i].id; }
        }
        return id;
    }

    Circuit.prototype.dispatch = function (name, event) {
        if (this.ended || !this.attached) { return; }
        var el = event.target;
        var stop = this.host.parentNode;
        while (el && el !== stop) {
            if (el.nodeType === 1) {
                var node = this.applier.nodes.get(el);
                if (node) {
                    var id = handlerIdFor(node, name);
                    if (id > 0) {
                        if (name === 'submit') {
                            // Without this the form posts and the page
                            // navigates away from the circuit.
                            event.preventDefault();
                        }
                        this.sendFenced({ t: 'ev', h: wireInt(id), k: name,
                                          p: payloadFor(name, event, el) });
                        return;
                    }
                }
            }
            if (el === this.host) { break; }
            el = el.parentNode;
        }
    };

    // The five payload shapes, one per family. `k` selects a FAMILY on the
    // server, never a method, so nothing here has to agree with a handler
    // name — only with the family table in wire.b.
    function payloadFor(name, event, bound) {
        var family = eventFamily(name);
        if (family === FAMILY_MOUSE) {
            return { b: wireInt(event.button), x: wireInt(event.clientX),
                     y: wireInt(event.clientY) };
        }
        if (family === FAMILY_INPUT) {
            var source = event.target && event.target.nodeType === 1 ? event.target : bound;
            return { v: wireText(source && source.value !== undefined ? source.value : ''),
                     c: !!(source && source.checked) };
        }
        if (family === FAMILY_KEYBOARD) {
            return { k: wireText(event.key === undefined ? '' : event.key),
                     r: !!event.repeat };
        }
        if (family === FAMILY_SUBMIT) {
            return { f: formFields(bound) };
        }
        return {};
    }

    // A form's successful controls, as one name-to-value map. A checkbox or a
    // radio that is not checked is not submitted, which is the HTML rule and
    // also the one that keeps an unchecked box from arriving as "on". Where
    // one name carries several values the LAST wins, because the server side
    // is a `Map<string, string>` and pretending otherwise would silently drop
    // a different one.
    function formFields(form) {
        var out = {};
        if (!form || !form.elements) { return out; }
        var controls = form.elements;
        for (var i = 0; i < controls.length; i++) {
            var control = controls[i];
            var name = control.name;
            if (!name) { continue; }
            var type = (control.type || '').toLowerCase();
            if (type === 'submit' || type === 'reset' || type === 'button' ||
                type === 'file' || type === 'image') { continue; }
            if ((type === 'checkbox' || type === 'radio') && !control.checked) { continue; }
            if (name === '__proto__' || name === 'constructor') { continue; }
            out[name] = wireText(control.value);
        }
        return out;
    }

    // ---- enhanced navigation ----------------------------------------------
    //
    // A same-origin link click becomes a `nav` message rather than a page
    // load, so the circuit and its component state survive it. Anything the
    // browser should still handle itself — a modified click, a target, a
    // download, a different origin — is left alone.
    Circuit.prototype.listenNav = function () {
        var self = this;
        var listener = function (event) { self.maybeNavigate(event); };
        this.host.addEventListener('click', listener, false);
        this.listeners.push({ name: 'click', listener: listener, capture: false });
    };

    Circuit.prototype.maybeNavigate = function (event) {
        if (this.ended || !this.attached) { return; }
        if (event.defaultPrevented) { return; }
        if (event.button !== 0 || event.metaKey || event.ctrlKey ||
            event.shiftKey || event.altKey) { return; }
        var el = event.target;
        while (el && el !== this.host.parentNode) {
            if (el.nodeType === 1 && el.tagName === 'A') { break; }
            el = el.parentNode;
        }
        if (!el || el.nodeType !== 1 || el.tagName !== 'A') { return; }
        if (el.hasAttribute('download') || el.hasAttribute('target')) { return; }
        var href = el.getAttribute('href');
        if (!href || !navTargetIsLocal(href)) { return; }
        event.preventDefault();
        // The address bar is the client's job — the server answers a `nav`
        // with a batch, not with a redirect — but `pushState` THROWS on an
        // opaque origin (a sandboxed iframe, a `file://` page) and a throw
        // here would leave the click prevented and the message unsent, which
        // is a link that does nothing at all. The message goes first and the
        // address bar is best-effort.
        this.sendFenced({ t: 'nav', u: href });
        if (typeof history !== 'undefined' && history.pushState) {
            try {
                history.pushState(null, '', href);
            } catch (err) {
                this.log.warn('latte: this document may not change its history entry');
            }
        }
    };

    // --------------------------------------------------------------- streaming
    //
    // stream.b's browser half. A streamed page arrives as a first pass with
    // `<latte-slot id="s3"></latte-slot>` wherever a region was not ready, then
    // each region's content as `<latte-chunk for="s3">…</latte-chunk>` followed
    // by `<latte-seal for="s3"></latte-seal>`.
    //
    // WHY THE SEAL, restated here because this is the code that depends on it:
    // a MutationObserver watching the body sees `<latte-chunk>` the moment the
    // parser OPENS it, which is long before its content is complete — the bytes
    // after it are still on the wire. Landing a chunk on the open event moves a
    // fragment of it and loses the rest, silently, and only for a chunk that
    // straddled a network boundary. The parser cannot insert the seal until it
    // has read `</latte-chunk>`, so a seal in the DOM is the parser's own word
    // that the chunk before it is whole. Nothing here ever looks at a chunk
    // that has no seal.
    //
    // The observer is a MutationObserver and NOT an inline script for the
    // reason PLAN.md gives: the shell ships `script-src 'self'` with no
    // `unsafe-inline`, and a streaming mechanism that needed a weaker rule than
    // the product would not be the product.

    var SLOT_TAG = 'latte-slot';
    var CHUNK_TAG = 'latte-chunk';
    var SEAL_TAG = 'latte-seal';
    // stream.b's MAX_STREAM_ID.
    var MAX_STREAM_ID = 64;

    // stream.b's `stream_id_is_safe`, applied on this side too. It is not
    // decoration: an id read off an attribute is written straight back into an
    // attribute SELECTOR below, and the set — letters, digits, `-`, `_` — is
    // the one that cannot carry a quote, a bracket or a space out of the
    // document and into the query. `tests/js_cases.b` emits the same probe
    // list both halves are judged on.
    function streamIdIsSafe(id) {
        if (typeof id !== 'string') { return false; }
        if (id.length === 0 || id.length > MAX_STREAM_ID) { return false; }
        for (var i = 0; i < id.length; i++) {
            var code = id.charCodeAt(i);
            var ok = (code >= 48 && code <= 57) ||
                     (code >= 65 && code <= 90) ||
                     (code >= 97 && code <= 122) ||
                     code === 45 || code === 95;
            if (!ok) { return false; }
        }
        return true;
    }

    function Stream(options) {
        options = options || {};
        this.document = options.document ||
            (typeof document !== 'undefined' ? document : null);
        this.root = options.root || null;
        this.log = options.log || defaultLog;
        /// Chunks landed, in the order they landed.
        this.landed = [];
        /// What went wrong, in the words assemble_chunks uses for the same
        /// thing, so the two halves can be compared on the failures too.
        this.faults = [];
        this.observer = null;
    }

    Stream.prototype.scope = function () {
        if (this.root) { return this.root; }
        if (!this.document) { return null; }
        return this.document.body || this.document.documentElement;
    };

    /// Land every chunk whose seal has arrived. Idempotent, and safe to call
    /// on a document the parser is still writing into.
    ///
    /// Answers how many chunks landed on THIS call, which is what makes an
    /// observer that fires four times during one chunk distinguishable from
    /// one that lands the chunk four times.
    Stream.prototype.sweep = function () {
        var scope = this.scope();
        if (!scope) { return 0; }
        var landed = 0;
        // A guard rather than `while (true)`: every iteration removes a seal,
        // so this cannot spin, but a document with a million seals should not
        // be able to occupy the main thread forever either.
        for (var guard = 0; guard < 100000; guard++) {
            var seal = scope.querySelector(SEAL_TAG + '[for]');
            if (!seal) { break; }
            var id = seal.getAttribute('for');
            // The seal comes out FIRST and unconditionally. Every `continue`
            // below is a chunk this sweep cannot land, and a seal left in
            // place would make the next iteration find the same one forever.
            if (seal.parentNode) { seal.parentNode.removeChild(seal); }
            if (!streamIdIsSafe(id)) {
                this.faults.push('a chunk arrived under an unusable slot id');
                continue;
            }
            var chunk = scope.querySelector(CHUNK_TAG + '[for="' + id + '"]');
            if (!chunk) {
                // A seal with no chunk before it is a document that was
                // assembled wrong, not a chunk that is still arriving: the
                // parser could not have inserted this seal without having read
                // the whole element before it.
                this.faults.push('the chunk "' + id + '" arrived sealed but empty');
                continue;
            }
            var slot = scope.querySelector(SLOT_TAG + '[id="' + id + '"]');
            if (!slot) {
                // assemble_chunks' sentence, word for word: the head and the
                // chunks disagree about a name, which is a page with a hole.
                this.faults.push('the chunk "' + id + '" has no placeholder to fill');
                if (chunk.parentNode) { chunk.parentNode.removeChild(chunk); }
                continue;
            }
            // Move, never re-parse. `slot.outerHTML = chunk.innerHTML` would
            // round-trip the content through the serializer and the parser a
            // second time, which loses a live form control's value and any
            // node identity the applier is holding.
            while (chunk.firstChild) {
                slot.parentNode.insertBefore(chunk.firstChild, slot);
            }
            if (chunk.parentNode) { chunk.parentNode.removeChild(chunk); }
            slot.parentNode.removeChild(slot);
            this.landed.push(id);
            landed += 1;
        }
        return landed;
    };

    Stream.prototype.start = function () {
        var scope = this.scope();
        if (!scope || typeof MutationObserver === 'undefined') {
            // No observer means no streaming, and a page that silently never
            // fills its holes is worse than one that says so.
            this.log.warn('latte: this browser has no MutationObserver, so streamed regions will not land');
            return false;
        }
        var self = this;
        this.observer = new MutationObserver(function () { self.sweep(); });
        this.observer.observe(scope, { childList: true, subtree: true });
        // The parser may already be past a seal by the time this runs — a
        // script at the end of `<head>` is not, but a deferred one is, and so
        // is anything that boots on DOMContentLoaded. An observer only reports
        // what happens AFTER it starts.
        this.sweep();
        return true;
    };

    Stream.prototype.stop = function () {
        if (this.observer) { this.observer.disconnect(); }
        this.observer = null;
    };

    // ---------------------------------------------------------- virtual lists
    //
    // virtual.b's browser half: the scroll reporter.
    //
    // The element carries four data attributes and the client reads all four:
    // `data-latte-virtual` is the component id it hands back, and
    // `data-latte-rows`, `data-latte-row-height` and `data-latte-overscan` are
    // the three numbers `VirtualGeometry` lays a window out from. The element
    // IS the scroller — the spacers are inside it — so `scrollTop` and
    // `clientHeight` are exactly the two arguments `window_at` takes.
    //
    // THE CAP IS NOT NEGOTIABLE AND IS NOT ON THE WIRE. `circuit.b:on_range`
    // ENDS the circuit for a range asking for more than `CircuitOptions
    // .max_window` rows, and `hello` does not carry that number — it carries
    // `v`, `c` and `mx` and nothing else. So this constant is the client's copy
    // of a server limit, and a client that got it wrong would kill its own
    // circuit on the first scroll of a tall list. `tests/js_cases.b` emits the
    // server's two spellings of it and `tests/js_apply.js` requires all three
    // to be the same number.
    var VIRTUAL_MAX_WINDOW = 200;

    function readInt(el, name, fallback) {
        if (!el || !el.getAttribute) { return fallback; }
        var text = el.getAttribute(name);
        if (text === null || text === '') { return fallback; }
        var value = Number(text);
        if (!isFinite(value)) { return fallback; }
        return Math.trunc(value);
    }

    /// `VirtualGeometry.window_at` followed by `window`, on this side.
    ///
    /// It is a mirror and it is judged as one: `tests/js_cases.b` emits what
    /// the Beans geometry answers for a table of scroll positions — the
    /// ordinary ones and the hostile ones — and the browser leg requires this
    /// function to answer the same pair for every row.
    function virtualWindow(rows, rowHeight, overscan, maxWindow, scrollTop, viewport) {
        // `VirtualGeometry.ok()`. A geometry that cannot be laid out has no
        // correct window, and answering numbers from one would send a range
        // computed out of a negative row height.
        if (!(rowHeight > 0 && overscan >= 0 && maxWindow > 0 && rows >= 0)) {
            return { start: 0, count: 0 };
        }
        var span = rows * rowHeight;
        var offset = scrollTop;
        if (!isFinite(offset)) { offset = 0; }
        offset = Math.trunc(offset);
        if (offset < 0) { offset = 0; }
        if (offset > span) { offset = span; }
        var height = viewport;
        if (!isFinite(height)) { height = 0; }
        height = Math.trunc(height);
        if (height < 0) { height = 0; }
        // THIS LINE CHANGES NO ANSWER HERE and it is kept anyway. `stop` below
        // is already clamped to `rows`, so bounding the viewport by the list's
        // own height moves nothing: breaking it and re-running the whole
        // fixture turns nothing red, which is how that was established rather
        // than assumed. It is live in `virtual.b` for a reason a double does
        // not have — `offset + height - 1` is an i64 add there and a viewport
        // near i64 max overflows it — so the mirror keeps the same shape as
        // the thing it mirrors. A reader should not take it for a guard that
        // this file is relying on.
        if (height > span) { height = span; }

        var first = Math.floor(offset / rowHeight);
        var last = first;
        if (height > 0) { last = Math.floor((offset + height - 1) / rowHeight); }

        var at = first - overscan;
        if (at < 0) { at = 0; }
        var stop = last + 1 + overscan;
        if (stop > rows) { stop = rows; }
        var size = stop - at;
        if (size < 0) { size = 0; }

        // `window(at, size)`, whose clamps are the ones that hold for a
        // hostile pair. `at` is already in range; `size` is not.
        if (at > rows) { at = rows; }
        if (size > maxWindow) { size = maxWindow; }
        var room = rows - at;
        if (size > room) { size = room; }
        return { start: at, count: size };
    }

    /// The window an element's own geometry and scroll position describe.
    function windowForElement(el, maxWindow) {
        return virtualWindow(readInt(el, 'data-latte-rows', 0),
                             readInt(el, 'data-latte-row-height', 0),
                             readInt(el, 'data-latte-overscan', 0),
                             maxWindow,
                             el.scrollTop || 0,
                             el.clientHeight || 0);
    }

    /// The scroll reporter. One message per animation frame per list, and none
    /// at all for a list whose window has not moved.
    function Ranges(options) {
        options = options || {};
        this.circuit = options.circuit || null;
        this.host = options.host || null;
        this.maxWindow = options.maxWindow || VIRTUAL_MAX_WINDOW;
        // Injected for the same reason the socket and the clock are: a gate
        // that asserted coalescing by really waiting for a frame could not say
        // which frame it was waiting for.
        this.schedule = options.schedule ||
            (typeof requestAnimationFrame !== 'undefined'
                ? function (fn) { return requestAnimationFrame(fn); }
                : function (fn) { return setTimeout(fn, 16); });
        /// The last range sent per component id, so a finger resting on a
        /// trackpad costs nothing. The server dedupes too — `apply_range`
        /// answers false for a window that did not move — but a message per
        /// frame per list is a message the wire should never carry.
        this.sent = bareMap();
        this.pending = false;
        this.listener = null;
    }

    Ranges.prototype.watch = function () {
        if (!this.host || !this.host.addEventListener) { return false; }
        var self = this;
        this.listener = function () { self.request(); };
        // CAPTURE, and this is load-bearing: `scroll` does not bubble, so a
        // listener on the host in the bubble phase never sees a descendant
        // scroll. It fires on the way DOWN or not at all.
        this.host.addEventListener('scroll', this.listener, true);
        return true;
    };

    Ranges.prototype.unwatch = function () {
        if (this.listener && this.host && this.host.removeEventListener) {
            this.host.removeEventListener('scroll', this.listener, true);
        }
        this.listener = null;
    };

    /// Ask for a flush on the next frame. Any number of scroll events between
    /// now and then cost nothing.
    Ranges.prototype.request = function () {
        if (this.pending) { return false; }
        this.pending = true;
        var self = this;
        this.schedule(function () { self.flush(); });
        return true;
    };

    Ranges.prototype.flush = function () {
        this.pending = false;
        if (!this.host || !this.host.querySelectorAll) { return 0; }
        var lists = this.host.querySelectorAll('[data-latte-virtual]');
        var sent = 0;
        for (var i = 0; i < lists.length; i++) {
            if (this.report(lists[i])) { sent += 1; }
        }
        return sent;
    };

    /// One list. Answers whether a message went out.
    Ranges.prototype.report = function (el) {
        var id = readInt(el, 'data-latte-virtual', -1);
        // `h` on a range is a component id and the server looks it up; a
        // negative one cannot be a component, and wire.b refuses it as "a
        // range carries no region id" — which would be this end asking the
        // server to spend a refusal on a message it should never have sent.
        if (id < 0) { return false; }
        var band = windowForElement(el, this.maxWindow);
        var key = String(id);
        var mark = band.start + ',' + band.count;
        if (this.sent[key] === mark) { return false; }
        if (!this.circuit) { return false; }
        // `c` carries the count and NOT `n`. `n` is the message sequence on
        // every client message and wire.b reads it before it looks at the
        // kind; a count on `n` is silently a sequence, the range decodes as
        // `c` missing — that is, -1 — and "a range must be two non-negative
        // numbers" refuses every scroll the page ever makes.
        if (!this.circuit.sendFenced({ t: 'range', h: id,
                                       s: wireInt(band.start),
                                       c: wireInt(band.count) })) {
            return false;
        }
        this.sent[key] = mark;
        return true;
    };

    /// A list that left the page must not keep its last window remembered:
    /// slot ids are never reused, so a NEW list can never collide with a dead
    /// one — but a page that mounts and unmounts lists for an hour would grow
    /// this map forever. Called after every batch.
    Ranges.prototype.forget = function () {
        if (!this.host || !this.host.querySelectorAll) { return; }
        var live = bareMap();
        var lists = this.host.querySelectorAll('[data-latte-virtual]');
        for (var i = 0; i < lists.length; i++) {
            live[String(readInt(lists[i], 'data-latte-virtual', -1))] = true;
        }
        var keys = Object.keys(this.sent);
        for (var k = 0; k < keys.length; k++) {
            if (!live[keys[k]]) { delete this.sent[keys[k]]; }
        }
    };

    // -------------------------------------------------------------- uploads
    //
    // upload.b's browser half. PLAN.md: "Inside a circuit an upload is still an
    // HTTP POST, not a socket message. `latte.js` posts the file and reports
    // progress over the circuit."
    //
    // The POST is here and it is real. THE REPORT IS NOT SENT, and that is a
    // boundary and not an oversight: wire v1 has seven client message kinds —
    // attach, resume, ev, ack, nav, js, range — and no eighth for progress.
    // `decode_body` answers `refuse("unknown message kind")` for anything else
    // and `Circuit.accept` turns a refusal into `bye protocol`, so a client
    // that invented a `progress` message would end its own circuit on the
    // first byte of the first upload. So progress goes to a sink the page
    // supplies, the numbers are clamped exactly as `UploadProgress` clamps
    // them, and `lanes/W6.md` carries what wire.b and circuit.b would have to
    // grow for the sink to be the circuit.

    /// `UploadProgress`, on this side. Same clamps, same percentage.
    function Progress() {
        this.sent = 0;
        this.total = 0;
        this.started = false;
        this.done = false;
    }

    /// Answers whether anything changed, so a browser firing `progress` sixty
    /// times a second for the same two numbers costs one comparison.
    Progress.prototype.report = function (sent, total) {
        var size = wireInt(total);
        if (size < 0) { size = 0; }
        var done = wireInt(sent);
        if (done < 0) { done = 0; }
        // Clamped to the total AFTER the total is clamped: the total is the
        // ceiling and a wrong pair is two wrong numbers, not one.
        if (done > size) { done = size; }
        if (this.started && done === this.sent && size === this.total) { return false; }
        this.sent = done;
        this.total = size;
        this.started = true;
        return true;
    };

    /// 0..100. A total of zero is 0%, not a division by zero and not 100%.
    ///
    /// THIS IS NOT A COPY OF WHAT `UploadProgress.percent` DOES, and an
    /// earlier draft that was one answered 26 where Beans answers 27.
    ///
    /// Beans halves both sides while `sent` is above 92233720368547758,
    /// because an i64 `sent * 100` overflows there. That loop can never run
    /// for anything a browser produces: every number this class holds has been
    /// through `wireInt`, which clamps at 9007199254740991, so Beans' answer
    /// for every reachable pair is the plain exact truncated `sent * 100 /
    /// total`. Halving HERE is a different operation — two integer divisions
    /// in front of a third — and it moves a quotient that lands exactly on an
    /// integer percentage down to the one below it.
    ///
    /// So the mirror has to be exact over the whole of that range, and a
    /// double is not: `sent * 100` is exact only while `sent` is at most
    /// 2^53/100, and above that the product rounds — `1945564707327492` of
    /// `7782258829309968` is 25% and the float multiply answers 24. Below the
    /// ceiling the multiply is exact and is used; above it the arithmetic is
    /// done in integers that cannot round. `BigInt` is no bigger a dependency
    /// than the `Map` and `WeakMap` the applier already needs.
    Progress.prototype.percent = function () {
        if (this.total <= 0) { return 0; }
        // `report` clamps `sent` into `[0, total]`, so this is equality and
        // not a guess — and it keeps the exact path off the one pair where
        // the answer is not a fraction at all.
        if (this.sent >= this.total) { return 100; }
        var out;
        if (this.sent <= 90071992547409) {
            out = Math.floor(this.sent * 100 / this.total);
        } else {
            out = Number(BigInt(this.sent) * BigInt(100) / BigInt(this.total));
        }
        if (out < 0) { return 0; }
        if (out > 100) { return 100; }
        return out;
    };

    function defaultRequest() { return new XMLHttpRequest(); }

    /// One `<div data-latte-upload>` control.
    function Uploader(options) {
        options = options || {};
        this.element = options.element || null;
        this.document = options.document ||
            (typeof document !== 'undefined' ? document : null);
        this.request = options.request || defaultRequest;
        /// Where a progress report goes. See the note above: it is NOT the
        /// circuit, because wire v1 has no message for one.
        this.onprogress = options.onprogress || null;
        /// A file this control will not post, in the words it refused it with.
        this.onrefused = options.onrefused || null;
        this.ondone = options.ondone || null;
        this.progress = new Progress();
        this.refusals = [];
        this.xhr = null;
    }

    Uploader.prototype.id = function () { return readInt(this.element, 'data-latte-upload', -1); };
    Uploader.prototype.maxBytes = function () { return readInt(this.element, 'data-latte-max-bytes', 0); };
    Uploader.prototype.maxFiles = function () { return readInt(this.element, 'data-latte-max-files', 0); };

    /// Where the body goes. An empty `data-latte-action` is the page's own
    /// url, which is what `Upload.action` means server-side.
    Uploader.prototype.action = function () {
        var named = this.element && this.element.getAttribute
            ? this.element.getAttribute('data-latte-action') : null;
        if (named) { return named; }
        if (typeof location === 'undefined') { return '/'; }
        return location.pathname + location.search;
    };

    /// The field name the parts post under, taken from the control's own
    /// `<input type=file>` — never from a data attribute, because the server
    /// reads the part name out of the body and the input is the thing that
    /// produced the body.
    Uploader.prototype.field = function () {
        if (!this.element || !this.element.querySelector) { return ''; }
        var input = this.element.querySelector('input[type=file]');
        return input && input.name ? input.name : '';
    };

    /// What this control will not even attempt, and why.
    ///
    /// These are the CLIENT's sentences and they have no Beans counterpart:
    /// the server's refusals come out of espresso's multipart parser, which is
    /// looking at a body rather than at a file the user just picked. Refusing
    /// here saves a person watching a 4 MB upload complete and then fail; it
    /// authorizes nothing, and every one of these is checked again on the far
    /// side against limits this control never sees.
    Uploader.prototype.refusalsFor = function (files) {
        var out = [];
        var most = this.maxFiles();
        var cap = this.maxBytes();
        if (most > 0 && files.length > most) {
            out.push('this control takes ' + most + ' file(s) and ' +
                     files.length + ' were chosen');
        }
        for (var i = 0; i < files.length; i++) {
            if (cap > 0 && files[i].size > cap) {
                out.push('"' + wireText(files[i].name) + '" is ' + files[i].size +
                         ' bytes, over the ' + cap + ' this control offers');
            }
        }
        return out;
    };

    /// Post `files`. Answers whether a request went out.
    ///
    /// Nothing partial: a set with one refusal in it posts NOTHING, because a
    /// control that took three of four files and said so in a corner is a
    /// control that silently lost a file.
    Uploader.prototype.post = function (files) {
        var refused = this.refusalsFor(files);
        if (refused.length > 0) {
            for (var r = 0; r < refused.length; r++) {
                this.refusals.push(refused[r]);
                if (this.onrefused) { this.onrefused(refused[r]); }
            }
            return false;
        }
        var name = this.field();
        if (name === '') {
            // `Upload.render` refuses a control with no field name and renders
            // nothing that can be posted to, so this is only reachable for an
            // element a page built by hand.
            this.refusals.push('this control has no file input to post');
            if (this.onrefused) { this.onrefused(this.refusals[this.refusals.length - 1]); }
            return false;
        }
        var body = new FormData();
        for (var i = 0; i < files.length; i++) { body.append(name, files[i]); }
        var self = this;
        var xhr = this.request();
        this.xhr = xhr;
        this.progress = new Progress();
        xhr.open('POST', this.action(), true);
        if (xhr.upload) {
            xhr.upload.onprogress = function (event) {
                // A body whose length the browser does not know reports
                // `lengthComputable` false and a total of 0, and `report`
                // clamps that to 0 of 0 — which `percent()` answers 0 for.
                // A bar that sat at 0 is honest; one that jumped to 100
                // because the total was missing is not.
                self.tick(event.loaded, event.lengthComputable ? event.total : 0);
            };
        }
        xhr.onload = function () { self.finish(xhr.status); };
        xhr.onerror = function () { self.finish(0); };
        xhr.send(body);
        return true;
    };

    /// One progress report. Answers whether it changed anything.
    Uploader.prototype.tick = function (loaded, total) {
        if (!this.progress.report(loaded, total)) { return false; }
        if (this.onprogress) {
            // The shape the message would carry if there were a message: the
            // component id, the bytes sent and the bytes there are. `s` and
            // `c` are the two names a range already uses for its pair, for the
            // same reason — `n` is the sequence and belongs to no payload.
            this.onprogress({ t: 'progress', h: this.id(),
                              s: wireInt(this.progress.sent),
                              c: wireInt(this.progress.total) });
        }
        return true;
    };

    Uploader.prototype.finish = function (status) {
        this.progress.done = true;
        if (this.ondone) { this.ondone(status); }
    };

    // ---------------------------------------------------------------- boot

    // The shell carries the circuit id and the socket path on the script tag
    // itself, so nothing on the page is an inline script and a
    // `script-src 'self'` CSP holds with no `unsafe-inline`.
    function readConfig(doc, script) {
        var config = { id: '', path: '/_latte/ws', rootId: 'latte-root' };
        if (script && script.dataset) {
            if (script.dataset.latteCircuit) { config.id = script.dataset.latteCircuit; }
            if (script.dataset.latteWs) { config.path = script.dataset.latteWs; }
            if (script.dataset.latteRoot) { config.rootId = script.dataset.latteRoot; }
        }
        return config;
    }

    function socketUrl(path) {
        if (typeof location === 'undefined') { return path; }
        var scheme = location.protocol === 'https:' ? 'wss:' : 'ws:';
        return scheme + '//' + location.host + path;
    }

    var api = {
        version: WIRE_VERSION,
        Applier: Applier,
        Circuit: Circuit,
        // Public so a suite can assert the browser half registers exactly the
        // set `wire.event_names()` answers, rather than trusting that someone
        // kept the two in step.
        eventNames: EVENT_NAMES,
        captureEvents: CAPTURE_EVENTS,
        eventFamily: eventFamily,
        eventCaptures: eventCaptures,
        navTargetIsLocal: navTargetIsLocal,
        wireInt: wireInt,
        wireText: wireText,
        // The streaming, virtual-list and upload halves. Public for the same
        // reason `eventNames` is: each one reimplements a rule that lives in
        // Beans, and a suite has to be able to compare the two copies rather
        // than trust that someone kept them in step.
        Stream: Stream,
        Ranges: Ranges,
        Uploader: Uploader,
        Progress: Progress,
        streamIdIsSafe: streamIdIsSafe,
        virtualWindow: virtualWindow,
        windowForElement: windowForElement,
        maxStreamId: MAX_STREAM_ID,
        maxWindow: VIRTUAL_MAX_WINDOW,
        kindName: kindName,
        spanAt: spanAt,
        scanSpans: scanSpans,
        current: null,

        /// Start the circuit this page was served with. Called automatically
        /// on DOMContentLoaded when the script tag carries a circuit id.
        boot: function (options) {
            options = options || {};
            var doc = options.document ||
                (typeof document !== 'undefined' ? document : null);
            if (!doc) { return null; }
            var config = readConfig(doc, options.script || null);
            var id = options.id || config.id;
            if (!id) { return null; }
            var host = options.host || doc.getElementById(config.rootId);
            if (!host) { return null; }
            var circuit = new Circuit({
                url: options.url || socketUrl(config.path),
                id: id,
                document: doc,
                host: host,
                open: options.open,
                enhanceNav: options.enhanceNav
            });
            api.current = circuit;
            circuit.start();
            return circuit;
        },

        /// Register a function the server may call by name on the running
        /// circuit. A page calls this from its own script file; the wire never
        /// carries anything but the name it was given here.
        register: function (name, fn) {
            if (!api.current) { return false; }
            return api.current.register(name, fn);
        },

        /// Start the MutationObserver that lands streamed chunks.
        ///
        /// Separate from `boot` and started BEFORE it, for two reasons. A
        /// streamed page need not have a circuit at all — `@stream` is about
        /// delivery and says nothing about interactivity — so a page whose
        /// script tag carries no circuit id must still fill its holes. And the
        /// chunks are arriving WHILE this runs: the sooner the observer is on
        /// the document, the fewer of them the first sweep has to catch up on.
        stream: function (options) {
            options = options || {};
            var doc = options.document ||
                (typeof document !== 'undefined' ? document : null);
            if (!doc) { return null; }
            var made = new Stream({ document: doc, root: options.root || null });
            made.start();
            api.streaming = made;
            return made;
        },

        streaming: null
    };

    // Auto-boot, but only in a browser and only when the page said so. A node
    // or a test harness gets the module and calls `boot` itself.
    if (typeof document !== 'undefined' && typeof window !== 'undefined') {
        var self_script = document.currentScript || null;
        var startup = function () {
            // The stream first: it needs no circuit and a page may have no
            // circuit id at all, in which case `boot` answers null and every
            // placeholder on a streamed static page would stay a placeholder.
            api.stream({ document: document });
            api.boot({ document: document, script: self_script });
        };
        if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', startup);
        } else {
            startup();
        }
    }

    return api;
});
