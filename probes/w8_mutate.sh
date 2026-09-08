#!/usr/bin/env bash
# probes/w8_mutate.sh — break every guard PLAN.md's threat table names, one at
# a time, IN BOTH DIRECTIONS, and watch the case that names it turn red.
#
# `probes/delete_faults.sh` does this for `self.faults.push` report sites. Most
# of the controls in the Security table are not report sites: they are
# predicates (`scheme_is_allowed`), clamps (`VirtualGeometry.window`),
# comparisons (`Antiforgery.check`) and early returns (`open_page`). A deleted
# `push` is visible to that script; a predicate quietly answering `true` is
# visible to nothing, and it is the exact shape W6 found — `Placement.sound()`
# forced to `return true` left a whole file green, because it was asserted true
# a hundred times and false never.
#
# So every guard here is broken TWICE:
#
#   force-allow   the guard stops refusing.   The REFUSAL cases must go red.
#   force-refuse  the guard refuses always.   The CONTROL cases must go red.
#
# A mutation whose named cases all survive is reported as UNGUARDED, which
# means one of two things and both are worth knowing: the case is not really
# testing that guard, or the guard is unreachable because something coarser
# stands in front of it (RULES.md § "The refusal that never runs").
#
# It rewrites source files, so it must never run beside a gate. It runs the
# interpreter leg only: a guard is Beans code with no backend-specific
# behaviour, `test.sh` already runs the suite on both backends, and what is
# being measured here is which ASSERTION notices.
#
#     probes/w8_mutate.sh              # every mutation
#     probes/w8_mutate.sh frames.b     # only the ones in one file
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
beans=$(cd "$root/../../beans" && pwd)
beansc="${BEANSC:-$beans/build/beansc}"
only="${1:-}"

[[ -x "$beansc" ]] || { echo "no beansc at $beansc" >&2; exit 1; }
case "$("$beansc" --version)" in
    *"0.1.40"*) ;;
    *) echo "latte is recorded against beansc 0.1.40" >&2; exit 1 ;;
esac

[[ -z ${BEANS_RUNTIME:-} && -f "$beans/runtime/beans_rt.c" ]] && export BEANS_RUNTIME="$beans/runtime/beans_rt.c"
[[ -z ${BEANS_STDLIB:-}  && -d "$beans/stdlib/std"        ]] && export BEANS_STDLIB="$beans/stdlib/std"
[[ -z ${BEANS_ENCODING:-} && -d "$beans/runtime/encoding" ]] && export BEANS_ENCODING="$beans/runtime/encoding"
[[ -z ${BEANS_NET:-}      && -d "$beans/runtime/net"      ]] && export BEANS_NET="$beans/runtime/net"
[[ -z ${BEANS_LOG:-}      && -d "$beans/runtime/log"      ]] && export BEANS_LOG="$beans/runtime/log"

exec python3 - "$root" "$beansc" "$only" <<'PYTHON'
import subprocess
import sys
from pathlib import Path

root = Path(sys.argv[1])
beansc = sys.argv[2]
only = sys.argv[3]
SUITE = "tests/w8_threats.b"

# ---------------------------------------------------------------------------
# One entry per mutation:
#
#   file       the source to rewrite
#   label      what was broken, and which way
#   find       exact text in the file (must appear exactly once)
#   into       what to put there
#   breaks     the check names that MUST turn red
#
# `find` is a whole guard rather than a fragment, so a mutation that silently
# stops matching after a refactor fails loudly here instead of passing.
# ---------------------------------------------------------------------------

M = [

# ---------------------------------------------------------------- frames.b
{
 "file": "frames.b", "label": "scheme_is_allowed / force-allow",
 "find": 'pub fn scheme_is_allowed(value: string) -> bool {\n    let probe: string = url_probe(value)',
 "into": 'pub fn scheme_is_allowed(value: string) -> bool {\n    if true { return true }\n    let probe: string = url_probe(value)',
 "breaks": ["row3.every-url-attribute-refuses-javascript",
            "row3.every-url-attribute-goes-inert",
            "row3.evasions-all-inert",
            "row3.scheme-predicate-refuses-each",
            "row3.splat-refuses-javascript",
            "row3.splat-goes-inert"],
},
{
 "file": "frames.b", "label": "scheme_is_allowed / force-refuse",
 "find": 'pub fn scheme_is_allowed(value: string) -> bool {\n    let probe: string = url_probe(value)',
 "into": 'pub fn scheme_is_allowed(value: string) -> bool {\n    if true { return false }\n    let probe: string = url_probe(value)',
 "breaks": ["row3.control-https-is-kept",
            "row3.control-allowed-schemes",
            "row3.control-splat-https",
            "row3.control-splat-https-written"],
},
{
 "file": "frames.b", "label": "is_url_attribute / force-allow (nothing is a URL)",
 "find": 'pub fn is_url_attribute(name: string) -> bool {\n    if name == "href" { return true }',
 "into": 'pub fn is_url_attribute(name: string) -> bool {\n    if true { return false }\n    if name == "href" { return true }',
 "breaks": ["row3.every-url-attribute-refuses-javascript",
            "row3.every-url-attribute-goes-inert",
            "row3.evasions-all-inert",
            "row3.url-attribute-href",
            "row3.url-attribute-xlink",
            "row3.splat-refuses-javascript",
            "row3.splat-goes-inert"],
},
{
 "file": "frames.b", "label": "is_url_attribute / force-refuse (everything is a URL)",
 "find": 'pub fn is_url_attribute(name: string) -> bool {\n    if name == "href" { return true }',
 "into": 'pub fn is_url_attribute(name: string) -> bool {\n    if true { return true }\n    if name == "href" { return true }',
 "breaks": ["row3.control-non-url-attribute-keeps-value",
            "row3.control-non-url-attribute-no-fault",
            "row3.control-url-attribute-title",
            "row3.splat-refuses-javascript",
            "row3.splat-goes-inert"],
},
{
 "file": "frames.b", "label": "attribute_is_inline_handler / force-allow",
 "find": 'pub fn attribute_is_inline_handler(name: string) -> bool {',
 "into": 'pub fn attribute_is_inline_handler(name: string) -> bool {\n    if true { return false }',
 "breaks": ["row5.onclick-refused", "row5.onclick-dropped",
            "row5.every-on-shape-dropped",
            "row5.handler-predicate-onclick",
            "row5.handler-predicate-uppercase",
            "row5.splat-refuses-handler"],
},
{
 "file": "frames.b", "label": "attribute_is_inline_handler / force-refuse",
 "find": 'pub fn attribute_is_inline_handler(name: string) -> bool {',
 "into": 'pub fn attribute_is_inline_handler(name: string) -> bool {\n    if true { return true }',
 "breaks": ["row5.control-two-byte-on-kept",
            "row5.control-contains-on-kept",
            "row5.control-handler-predicate-on",
            "row5.control-handler-predicate-data-on"],
},
{
 "file": "frames.b", "label": "attribute_name_is_safe / force-allow",
 "find": 'pub fn attribute_name_is_safe(name: string) -> bool {\n    if name.len() == 0 { return false }',
 "into": 'pub fn attribute_name_is_safe(name: string) -> bool {\n    if true { return true }\n    if name.len() == 0 { return false }',
 "breaks": ["row2.refused-attribute-name",
            "row2.refused-attribute-name-dropped",
            "row2.name-predicate-refuses-space",
            "row2.name-predicate-refuses-angle",
            "row2.name-predicate-refuses-quote"],
},
{
 "file": "frames.b", "label": "attribute_name_is_safe / force-refuse",
 "find": 'pub fn attribute_name_is_safe(name: string) -> bool {\n    if name.len() == 0 { return false }',
 "into": 'pub fn attribute_name_is_safe(name: string) -> bool {\n    if true { return false }\n    if name.len() == 0 { return false }',
 "breaks": ["row2.control-attribute-name-accepted",
            "row2.control-attribute-name-written",
            "row2.control-name-predicate-accepts"],
},
{
 "file": "frames.b", "label": "tag_name_is_safe / force-allow",
 "find": 'pub fn tag_name_is_safe(tag: string) -> bool {\n    if tag.len() == 0 { return false }',
 "into": 'pub fn tag_name_is_safe(tag: string) -> bool {\n    if true { return true }\n    if tag.len() == 0 { return false }',
 "breaks": ["row2.refused-tag-name", "row2.refused-tag-substituted",
            "row2.tag-predicate-refuses"],
},
{
 "file": "frames.b", "label": "tag_name_is_safe / force-refuse",
 "find": 'pub fn tag_name_is_safe(tag: string) -> bool {\n    if tag.len() == 0 { return false }',
 "into": 'pub fn tag_name_is_safe(tag: string) -> bool {\n    if true { return false }\n    if tag.len() == 0 { return false }',
 "breaks": ["row2.control-tag-predicate-accepts"],
},
{
 "file": "frames.b", "label": "raw_text_is_safe / force-allow",
 "find": 'pub fn raw_text_is_safe(body: string, tag: string) -> bool {',
 "into": 'pub fn raw_text_is_safe(body: string, tag: string) -> bool {\n    if true { return true }',
 "breaks": ["row4.script-body-dropped", "row4.script-body-fault",
            "row4.style-comment-dropped", "row4.style-comment-fault",
            "row4.raw-text-predicate-refuses-close",
            "row4.raw-text-predicate-refuses-comment",
            "row4.raw-text-predicate-case-insensitive"],
},
{
 "file": "frames.b", "label": "raw_text_is_safe / force-refuse",
 "find": 'pub fn raw_text_is_safe(body: string, tag: string) -> bool {',
 "into": 'pub fn raw_text_is_safe(body: string, tag: string) -> bool {\n    if true { return false }',
 "breaks": ["row4.control-script-body-verbatim",
            "row4.control-script-body-no-fault",
            "row4.control-raw-text-predicate-accepts",
            "row4.control-raw-text-other-tag"],
},
{
 "file": "frames.b", "label": "escape_text / force-allow (no escaping)",
 "find": 'pub fn escape_text(body: string) -> string {\n    var out: fmt.StringBuilder = new fmt.StringBuilder()',
 "into": 'pub fn escape_text(body: string) -> string {\n    if true { return body }\n    var out: fmt.StringBuilder = new fmt.StringBuilder()',
 "breaks": ["row1.serializer-escapes-text", "row1.applier-escapes-text",
            "row1.escape-text-all-three", "row1.escape-text-ampersand-first",
            "row4.textarea-escapes", "row4.title-escapes"],
},
{
 "file": "frames.b", "label": "escape_attribute / force-allow (no escaping)",
 "find": 'pub fn escape_attribute(value: string) -> string {\n    var out: fmt.StringBuilder = new fmt.StringBuilder()',
 "into": 'pub fn escape_attribute(value: string) -> string {\n    if true { return value }\n    var out: fmt.StringBuilder = new fmt.StringBuilder()',
 "breaks": ["row2.serializer-escapes-quote", "row2.applier-escapes-quote",
            "row2.serializer-escapes-apostrophe",
            "row2.escape-attribute-all-five"],
},

# ---------------------------------------------------------------- circuit.b
{
 "file": "circuit.b", "label": "nav_target_is_local / force-allow",
 "find": 'pub fn nav_target_is_local(url: string) -> bool {\n    if url.len() == 0 { return false }',
 "into": 'pub fn nav_target_is_local(url: string) -> bool {\n    if true { return true }\n    if url.len() == 0 { return false }',
 "breaks": ["row16.every-hostile-target-is-refused",
            "row16.but-dot-dot-in-the-path-is",
            "row16.a-hostile-nav-ends-the-circuit",
            "row16.the-server-cannot-navigate-off-origin"],
},
{
 "file": "circuit.b", "label": "nav_target_is_local / force-refuse",
 "find": 'pub fn nav_target_is_local(url: string) -> bool {\n    if url.len() == 0 { return false }',
 "into": 'pub fn nav_target_is_local(url: string) -> bool {\n    if true { return false }\n    if url.len() == 0 { return false }',
 "breaks": ["row16.control-every-local-target-is-accepted",
            "row16.control-dot-dot-in-a-query-is-not-a-path-segment",
            "row16.control-dot-dot-in-a-fragment-is-not-a-path-segment",
            "row16.control-a-local-nav-does-not-end-the-circuit",
            "row16.control-the-server-can-navigate-locally"],
},
{
 "file": "circuit.b", "label": "on_attach circuit-id compare / force-allow",
 "find": '    fn on_attach(message: ClientMessage, now_ms: int) {\n        // The id the client presents must be the one this circuit was opened\n        // with. The host has already checked it against the session cookie;\n        // this is the second half of the same check and it is cheap.\n        if message.circuit != self.id {',
 "into": '    fn on_attach(message: ClientMessage, now_ms: int) {\n        if false {',
 "breaks": ["row8.attach-with-another-id-ends-the-circuit"],
},
{
 "file": "circuit.b", "label": "adopt session compare / force-allow",
 "find": '        if self.session_of(target) != self.session_of(handle) {',
 "into": '        if false {',
 "breaks": ["row8.a-stolen-id-does-not-adopt-across-sessions",
            "row8.cross-session-resume-fault"],
},
{
 "file": "circuit.b", "label": "adopt session compare / force-refuse",
 "find": '        if self.session_of(target) != self.session_of(handle) {',
 "into": '        if true {',
 "breaks": ["row8.control-the-same-session-does-adopt",
            "row8.control-the-same-session-raises-no-fault"],
},
{
 "file": "circuit.b", "label": "the range window cap / force-allow",
 "find": '        if message.count > self.options.max_window {',
 "into": '        if false {',
 "breaks": ["row11.a-range-over-the-wire-cap-ends-the-circuit"],
},
{
 "file": "circuit.b", "label": "the range window cap / force-refuse",
 "find": '        if message.count > self.options.max_window {',
 "into": '        if true {',
 "breaks": ["row11.control-a-range-at-the-cap-is-accepted"],
},
{
 "file": "circuit.b", "label": "the 16-character circuit-id floor / force-allow",
 "find": '        if id.len() < 16 {',
 "into": '        if false {',
 "breaks": ["row8.short-id-refused", "row8.short-id-fault"],
},
{
 "file": "circuit.b", "label": "the un-acked window / force-allow",
 "find": '        if self.batch_number - self.last_ack > self.options.max_unacked {',
 "into": '        if false {',
 "breaks": ["row14.a-client-that-never-acks-is-ended",
            "row14.and-the-reason-names-the-window"],
},
{
 "file": "circuit.b", "label": "the un-acked window / force-refuse",
 "find": '        if self.batch_number - self.last_ack > self.options.max_unacked {',
 "into": '        if true {',
 "breaks": ["row14.control-a-client-that-acks-is-not-ended"],
},
{
 "file": "circuit.b", "label": "the render-pass cap / force-allow (it fires and says nothing)",
 "find": '                let culprit: int = self.first_dirty()\n                self.contain(culprit,\n                    "a component re-rendered itself {self.options.max_renders} times without settling")\n                return',
 "into": '                return',
 "breaks": ["row14.and-the-client-is-told-through-err",
            "row14.and-the-log-names-the-render-cap",
            "row14.an-unguarded-render-loop-ends-the-circuit",
            "row14.and-the-reason-is-panic",
            "row14.and-that-log-names-the-render-cap-too"],
},
{
 "file": "circuit.b", "label": "the render-pass cap / force-refuse (every settle trips it)",
 "find": '            if passes > self.options.max_renders {',
 "into": '            if true {',
 "breaks": ["row14.control-a-component-that-settles-is-not-stopped",
            "row14.control-and-it-logged-nothing"],
},
{
 "file": "circuit.b", "label": "the idle timeout / force-allow",
 "find": '        if self.connected && now_ms - self.seen_ms >= self.options.idle_ms {',
 "into": '        if false {',
 "breaks": ["row14.past-the-idle-window-the-circuit-ends",
            "row14.and-the-reason-is-idle"],
},
{
 "file": "circuit.b", "label": "the idle timeout / force-refuse",
 "find": '        if self.connected && now_ms - self.seen_ms >= self.options.idle_ms {',
 "into": '        if self.connected {',
 "breaks": ["row14.control-just-inside-the-idle-window"],
},
{
 "file": "circuit.b", "label": "the per-worker circuit cap / force-allow",
 "find": '        if self.live.len() >= self.options.max_circuits {',
 "into": '        if false {',
 "breaks": ["row14.a-full-set-of-live-circuits-refuses", "row14.and-says-so",
            "row14.the-oldest-disconnected-circuit-was-evicted"],
},
{
 "file": "circuit.b", "label": "oldest-first eviction / force-refuse (never evict)",
 "find": '                    if !existing.is_connected() {',
 "into": '                    if false {',
 "breaks": ["row14.the-third-circuit-was-opened",
            "row14.the-oldest-disconnected-circuit-was-evicted"],
},
{
 "file": "circuit.b", "label": "eviction of a LIVE circuit / force-allow",
 "find": '                    if !existing.is_connected() {',
 "into": '                    if true {',
 "breaks": ["row14.a-full-set-of-live-circuits-refuses", "row14.and-says-so",
            "row14.control-no-live-circuit-was-evicted"],
},
{
 "file": "circuit.b", "label": "the retention window / force-allow (never expires)",
 "find": '        return now_ms - self.dropped_ms >= self.options.retention_ms',
 "into": '        return false',
 "breaks": ["row14.past-the-retention-window-it-is-swept", "row14.and-is-gone"],
},
{
 "file": "circuit.b", "label": "the retention window / force-refuse (expires at once)",
 "find": '        return now_ms - self.dropped_ms >= self.options.retention_ms',
 "into": '        return true',
 "breaks": ["row14.control-a-dropped-circuit-is-kept-inside-the-window",
            "row14.control-and-is-still-there"],
},
{
 "file": "circuit.b", "label": "the trace id / force-allow (send the panic message)",
 "find": '                self.outbox.push(encode_err("panic", trace))',
 "into": '                self.outbox.push(encode_err("panic", report))',
 "breaks": ["row17.the-wire-does-not-carry-the-panic-message",
            "row17.the-trace-id-on-the-wire-matches-the-log"],
},
{
 "file": "circuit.b", "label": "the trace id on an unguarded panic / force-allow",
 "find": '                self.stop("panic", trace)',
 "into": '                self.stop("panic", report)',
 "breaks": ["row17.and-still-does-not-carry-the-message"],
},

# ---------------------------------------------------------------- forms.b
{
 "file": "forms.b", "label": "Antiforgery.check / force-allow (every token is valid)",
 "find": '        if token == "" { return TokenOutcome.missing }',
 "into": '        if true { return TokenOutcome.valid }\n        if token == "" { return TokenOutcome.missing }',
 "breaks": ["row6.no-token", "row6.no-session", "row6.malformed-no-dot",
            "row6.malformed-expiry-not-a-number", "row6.malformed-empty-mac",
            "row6.expired-at-expiry", "row6.cross-session", "row6.cross-form",
            "row6.one-flipped-mac-byte", "row6.expiry-is-covered-by-the-mac",
            "row6.boundary-pair-does-not-cross",
            "row6.another-key-does-not-verify",
            "row6.a-signer-that-cannot-sign-refuses"],
},
{
 "file": "forms.b", "label": "the MAC comparison / force-allow",
 "find": '                        if !self.signer.same(mac, wanted) { return TokenOutcome.forged }',
 "into": '                        if false { return TokenOutcome.forged }',
 "breaks": ["row6.cross-session", "row6.cross-form", "row6.one-flipped-mac-byte",
            "row6.expiry-is-covered-by-the-mac",
            "row6.boundary-pair-does-not-cross",
            "row6.another-key-does-not-verify",
            "row6.a-signer-that-cannot-sign-refuses"],
},
{
 "file": "forms.b", "label": "the MAC comparison / force-refuse",
 "find": '                        if !self.signer.same(mac, wanted) { return TokenOutcome.forged }',
 "into": '                        if true { return TokenOutcome.forged }',
 "breaks": ["row6.control-a-genuine-token-is-valid",
            "row6.control-one-second-before-expiry",
            "row6.expired-at-expiry",
            "row6.control-boundary-pair-checks-out"],
},
{
 "file": "forms.b", "label": "the payload's length prefixes / dropped",
 "find": '        return "{session.len()}:{session}|{form_id.len()}:{form_id}|{expiry}"',
 "into": '        return "{session}|{form_id}|{expiry}"',
 "breaks": ["row6.no-boundary-collision", "row6.boundary-pair-does-not-cross"],
},
{
 "file": "forms.b", "label": "the @field filter / force-allow (every field is bindable)",
 "find": '        let uses: List<reflect.Annotation> = annotations_named(member.annotations(), "field")\n        if uses.len() == 0 {',
 "into": '        let uses: List<reflect.Annotation> = annotations_named(member.annotations(), "field")\n        if false {',
 "breaks": ["row10.unannotated-names-are-ignored",
            "row10.the-model-was-not-mass-assigned",
            "row10.the-plan-names-only-the-annotated-fields",
            "row10.the-plan-has-no-entry-for-is-admin"],
},

# ---------------------------------------------------------------- pages.b
{
 "file": "pages.b", "label": "open_page's authorization check / force-allow",
 "find": '    let outcome: AuthOutcome = found.plan.authorize(who)\n    match outcome {\n        allow => {}\n        _ => {',
 "into": '    let outcome: AuthOutcome = found.plan.authorize(who)\n    match outcome {\n        _ => {}\n        allow => {',
 "breaks": ["row9.anonymous-does-not-open", "row9.anonymous-is-challenged",
            "row9.the-wrong-role-does-not-open",
            "row9.the-wrong-role-is-forbidden",
            "row9.mount-is-not-cached",
            "row9.navigation-re-checks-authorization"],
},
{
 "file": "pages.b", "label": "authorize_all / force-refuse (nobody is ever allowed)",
 "find": '    if requirements.len() == 0 { return AuthOutcome.allow }',
 "into": '    if true { return AuthOutcome.forbid }',
 "breaks": ["row9.control-the-right-role-opens",
            "row9.control-the-right-role-has-no-problem",
            "row9.control-an-open-page-opens-for-anonymous",
            "row9.control-the-attach-mounts-while-the-role-holds",
            "row9.control-the-attach-does-not-end",
            "row9.mount-is-not-cached"],
},

# ---------------------------------------------------------------- virtual.b
{
 "file": "virtual.b", "label": "the window's start clamp / force-allow",
 "find": '        if at > self.total { at = self.total }',
 "into": '        if false { at = self.total }',
 "breaks": ["row11.a-start-past-the-end-shows-nothing",
            "row11.the-largest-int-as-a-start"],
},
{
 "file": "virtual.b", "label": "the window's cap clamp / force-allow",
 "find": '        if size > self.max_window { size = self.max_window }',
 "into": '        if false { size = self.max_window }',
 "breaks": ["row11.a-count-over-the-cap-is-trimmed",
            "row11.the-largest-int-as-a-count"],
},
{
 "file": "virtual.b", "label": "the window's collection clamp / force-allow",
 "find": '        if size > room { size = room }',
 "into": '        if false { size = room }',
 "breaks": ["row11.a-window-past-the-end-is-trimmed"],
},
{
 "file": "virtual.b", "label": "Placement.sound / force-allow",
 "find": '    pub fn sound() -> bool {\n        if self.start < 0 || self.shown < 0 { return false }',
 "into": '    pub fn sound() -> bool {\n        if true { return true }\n        if self.start < 0 || self.shown < 0 { return false }',
 "breaks": ["row11.sound-can-answer-false",
            "row11.sound-refuses-a-negative-spacer"],
},
{
 "file": "virtual.b", "label": "Placement.sound / force-refuse",
 "find": '    pub fn sound() -> bool {\n        if self.start < 0 || self.shown < 0 { return false }',
 "into": '    pub fn sound() -> bool {\n        if true { return false }\n        if self.start < 0 || self.shown < 0 { return false }',
 "breaks": ["row11.control-an-ordinary-window-is-sound",
            "row11.a-trimmed-window-is-sound",
            "row11.the-largest-int-is-still-sound"],
},

# ---------------------------------------------------------------- wire.b
{
 "file": "wire.b", "label": "the message size cap / force-allow",
 "find": '    if text.len() > limits.max_message {',
 "into": '    if false {',
 "breaks": ["row13.an-oversized-message-is-refused-before-the-parse",
            "row13.the-size-check-runs-before-the-syntax-check"],
},
{
 "file": "wire.b", "label": "the nesting cap / force-allow",
 "find": '        if self.depth >= self.limits.max_depth {',
 "into": '        if false {',
 "breaks": ["row13.nesting-over-the-depth-cap"],
},
{
 "file": "wire.b", "label": "the nesting cap / force-refuse",
 "find": '        if self.depth >= self.limits.max_depth {',
 "into": '        if true {',
 "breaks": ["row13.control-nesting-at-the-depth-cap",
            "row13.control-a-message-under-the-limit-decodes"],
},
{
 "file": "wire.b", "label": "the array element cap / force-allow",
 "find": '            if out.items.len() >= self.limits.max_items {',
 "into": '            if false {',
 "breaks": ["row13.an-array-over-the-item-cap"],
},
{
 "file": "wire.b", "label": "the object member cap / force-allow",
 "find": '            if out.keys.len() >= self.limits.max_items {',
 "into": '            if false {',
 "breaks": ["row13.an-object-over-the-item-cap"],
},
{
 "file": "wire.b", "label": "the string length cap / force-allow",
 "find": '            if size >= self.limits.max_text {',
 "into": '            if false {',
 "breaks": ["row13.a-string-over-the-text-cap"],
},
{
 "file": "wire.b", "label": "the kind table / force-refuse (ack falls off it)",
 "find": '    if kind == "ack" {',
 "into": '    if kind == "ack-disabled" {',
 "breaks": ["row15.control-a-known-kind-decodes",
            "row15.control-and-carries-its-batch",
            "row15.control-all-seven-kinds-decode"],
},

# ---------------------------------------------------------------- apply.b
{
 "file": "apply.b", "label": "the unmounted-component fault / force-allow",
 "find": '                if id != 0 {',
 "into": '                if false {',
 "breaks": ["row15.an-update-for-an-unmounted-component-is-a-fault"],
},
]

if only:
    M = [m for m in M if m["file"] == only]
    if not M:
        print(f"no mutation names {only}", file=sys.stderr)
        sys.exit(1)


def failing_checks():
    """The names of every check that printed FAIL, or None if it did not run."""
    done = subprocess.run([beansc, "run", SUITE], cwd=root,
                          capture_output=True, text=True, timeout=600)
    if done.returncode != 0:
        return None, done.stdout + done.stderr
    names = set()
    for line in done.stdout.split("\n"):
        if line.startswith("FAIL "):
            names.add(line[len("FAIL "):].rstrip(":"))
    return names, ""


# The two rows PLAN.md requires and latte does not have yet. They fail in every
# run, mutated or not, so they are subtracted rather than reported forty times.
EXPECTED = {"row9.a-tick-revalidates-authorization",
            "row18.latte-ships-a-security-header-middleware"}

base, why = failing_checks()
if base is None:
    print("the suite does not run unmutated:\n" + why, file=sys.stderr)
    sys.exit(1)
if base != EXPECTED:
    print("BASELINE MISMATCH — the suite's failures are not the two known gaps.",
          file=sys.stderr)
    print("  extra:   " + ", ".join(sorted(base - EXPECTED)), file=sys.stderr)
    print("  missing: " + ", ".join(sorted(EXPECTED - base)), file=sys.stderr)
    print("  Fix the suite before reading anything below.", file=sys.stderr)
    sys.exit(1)

print(f"baseline: {len(base)} known failure(s) — "
      + ", ".join(sorted(base)))
print()

unguarded = 0
checked = 0
for m in M:
    path = root / m["file"]
    original = path.read_text()
    count = original.count(m["find"])
    if count != 1:
        print(f"STALE  {m['file']:<12} {m['label']}")
        print(f"       its `find` appears {count} times, not once — the guard moved.")
        unguarded += 1
        continue
    path.write_text(original.replace(m["find"], m["into"], 1))
    try:
        got, why = failing_checks()
    finally:
        path.write_text(original)
    checked += 1
    if got is None:
        # A mutation that stops the suite compiling or running proves nothing
        # about which assertion noticed, so it is a failure of the mutation.
        print(f"BROKE  {m['file']:<12} {m['label']}")
        print("       the suite did not run under this mutation:")
        print("       " + why.strip().split("\n")[0])
        unguarded += 1
        continue
    new = got - base
    survived = [name for name in m["breaks"] if name not in new]
    if survived:
        print(f"UNGUARDED  {m['file']:<12} {m['label']}")
        for name in survived:
            print(f"           {name} still passed")
        unguarded += 1
    else:
        extra = len(new) - len(m["breaks"])
        tail = f", and {extra} more" if extra > 0 else ""
        print(f"caught {m['file']:<12} {m['label']}  "
              f"({len(m['breaks'])} named check(s) went red{tail})")

print()
if unguarded == 0:
    print(f"ok — all {checked} mutation(s) were caught by the check that names them")
    sys.exit(0)
print(f"--- {unguarded} mutation(s) of {len(M)} were NOT caught ---", file=sys.stderr)
sys.exit(1)
PYTHON
