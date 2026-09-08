// tests/w4_csp_probe.js — the verdict writer for test.sh's `csp-browser` leg.
//
// It is an EXTERNAL script on purpose. The whole claim under test is that
// latte's policy needs no `'unsafe-inline'`, so a probe that ran from an inline
// <script> would be testing a policy nobody ships. It is loaded from the same
// origin as the page, immediately after `latte.js`, and it overwrites a verdict
// block the SERVER rendered — so "the script did not run" and "the page never
// arrived" cannot print the same thing.
(function () {
    'use strict';
    var out = [];
    out.push('script: ran');
    out.push('latte global: ' + (typeof window.latte));
    out.push('latte.boot: ' + (window.latte ? typeof window.latte.boot : 'n/a'));

    // connect-src, synchronously, so the verdict needs no timer and no
    // virtual-time budget. A CSP that refused this throws at send().
    try {
        var x = new XMLHttpRequest();
        x.open('GET', '/ping', false);
        x.send(null);
        out.push('xhr: ' + x.status + ' ' + x.responseText);
    } catch (e) {
        out.push('xhr: blocked ' + (e && e.name ? e.name : 'error'));
    }

    var el = document.getElementById('verdict');
    el.textContent = '@@CSP-BEGIN@@\n' + out.join('\n') + '\n@@CSP-END@@';
})();
