// tests/w8_threats.b — PLAN.md's threat table, one section per row.
//
// PLAN.md gate 10: "one case per threat row asserting the refusal, plus
// hostile frames that must never panic and never leak." This file is the
// first half; `tests/w8_hostile.b` is the second.
//
// **Every refusal here has a positive control beside it, and the control
// differs from the refusal in exactly one thing.** RULES.md § "The refusal
// that never runs" is about the four bugs W2 found in refusals that had been
// written and never exercised — three live refusals with a wrong edge, and one
// live refusal that no input could reach because a coarser rule upstream
// swallowed it. Without a control you cannot tell "refused for the right
// reason" from "refused earlier, for a different one".
//
// **The roll-call at the end is derived, not written.** `Report.row` marks the
// row a check belongs to and every check records it, so the summary is a
// function of the checks that actually ran. Delete a section and the summary
// changes. A hand-written list would print the same thing either way, which is
// the shape RULES.md § "A green count can mean two different things" is about.
//
// **A row that lands on a control latte does not have FAILS.** It is not
// silently marked "not covered" and it is not asserted against what the code
// happens to do today: the golden holds what PLAN.md says must happen, the run
// prints what happens, and the diff is the gap. A failing row someone can see
// beats a green one that pinned a hole.
//
// Proving the cases are live is `probes/w8_mutate.sh`: it breaks each guard a
// row names in BOTH directions — force-allow, which must turn the refusal
// case red, and force-refuse, which must turn the control red — and reports
// any case that survived either. A guard asserted in one direction only is the
// W6 `sound()` shape: forcing it to `return true` left a whole file green.
package main

import espresso
import std.io
import std.reflect
import {Antiforgery, Anonymous, Applier, Batch, Builder, Circuit,
        CircuitOptions, CircuitSet, ClientMessage, Component, ComponentUpdate,
        Differ,
        FormField, FormMap, FormPlan, FormResult, Layout, MouseEvent, PageMap,
        PageInstance, PageMatch, PagePlan, Placement, Principal, SeamSigner,
        Serializer, ErrorBoundary,
        Signer, TokenOutcome, Upload, UploadFile, Virtual, VirtualGeometry,
        WireLimits, INERT_URL, TOKEN_FIELD, UPLOAD_MAX_BYTES,
        UPLOAD_MAX_FILES, VIRTUAL_MAX_WINDOW,
        attribute_is_inline_handler, attribute_name_is_safe, decode_client,
        describe_outcome, describe_token, escape_attribute, escape_text,
        is_url_attribute, nav_target_is_local, open_page, parse_int, parse_json,
        raw_text_is_safe, scan_forms, scan_pages, scheme_is_allowed,
        tag_name_is_safe, authorize, page, form, field, required} from latte
import {fresh_id, hmac_signer, same_bytes, EndpointOptions, HeaderOptions,
        SESSION_COOKIE} from latte.web
import {run} from latte.boundary
import {describe_body, HandleStore, ReleaseLog} from latte.uploads

// ============================================================== the report
//
// `row(n, slug)` opens a row; every check after it is charged to that row.
// `uncovered` opens a row and says, in the golden, that latte has no control
// for it — a decision written down rather than a silence.

pub class RowTally {
    pub number: int = 0
    pub slug: string = ""
    pub checks: int = 0
    pub bad: int = 0
    pub declared_uncovered: bool = false
    pub reason: string = ""
    pub fn init() {}
}

pub class Report {
    pub checks: int = 0
    pub bad: int = 0
    pub rows: List<RowTally> = []
    current: int = -1
    pub fn init() {}

    /// Open a threat-table row. Prints its header so a reader can walk the
    /// table down the golden in PLAN.md's order.
    pub fn row(number: int, slug: string) {
        var made: RowTally = new RowTally()
        made.number = number
        made.slug = slug
        self.rows.push(made)
        self.current = self.rows.len() - 1
        io.println("")
        io.println("-- row {number}: {slug}")
    }

    /// Open a row latte has no control for. The row still runs whatever checks
    /// it can; this only records why the row cannot be complete.
    pub fn uncovered(number: int, slug: string, reason: string) {
        self.row(number, slug)
        let at: int = self.current
        var tally: RowTally = self.rows[at]
        tally.declared_uncovered = true
        tally.reason = reason
        io.println("   NO CONTROL IN LATTE: {reason}")
    }

    fn charge(failed: bool) {
        self.checks += 1
        if failed { self.bad += 1 }
        if self.current < 0 { return }
        let at: int = self.current
        var tally: RowTally = self.rows[at]
        tally.checks += 1
        if failed { tally.bad += 1 }
    }

    pub fn eq(name: string, got: string, want: string) {
        if got == want {
            self.charge(false)
            io.println("ok {name}")
        } else {
            self.charge(true)
            io.println("FAIL {name}:")
            io.println("   got  {got}")
            io.println("   want {want}")
        }
    }

    pub fn eqi(name: string, got: int, want: int) { self.eq(name, "{got}", "{want}") }
    pub fn yes(name: string, got: bool) { self.eq(name, "{got}", "true") }
    pub fn no(name: string, got: bool) { self.eq(name, "{got}", "false") }

    /// The roll-call. Derived from the rows that ran, so a deleted section is
    /// a diff and not a silence.
    pub fn roll_call() {
        io.println("")
        io.println("== the threat table, row by row ==")
        var covered: int = 0
        var failing: int = 0
        var gaps: int = 0
        for tally: RowTally in self.rows {
            var state: string = "covered"
            if tally.checks == 0 {
                state = "NO CHECKS RAN"
                gaps += 1
            } else if tally.bad > 0 {
                state = "COVERED-BUT-FAILING ({tally.bad} of {tally.checks})"
                failing += 1
            } else if tally.declared_uncovered {
                state = "partial — {tally.reason}"
                gaps += 1
            } else {
                covered += 1
            }
            io.println("row {tally.number} {tally.slug}: {state} ({tally.checks} checks)")
        }
        io.println("")
        io.println("{self.rows.len()} rows: {covered} covered, {failing} covered-but-failing, {gaps} with a gap")
        io.println("{self.checks} checks, {self.bad} failed")
    }
}

// ============================================================== helpers

/// A component whose render is whatever the case hands it. Every tree here is
/// built through `Builder.render_root`, which is the whole render cycle: a
/// hand-pushed `Builder` has `diffed = true` and the differ SKIPS it, so a
/// tree assembled by pushing frames produces an EMPTY batch and an applier
/// that lands on `""`. Two of this file's first checks passed that way before
/// the applier half was compared against anything.
pub class Sheet extends Component {
    pub body: fn(Builder) = fn(b: Builder) {}
    pub fn init() {}
    pub override fn render(b: Builder) { self.body(b) }
}

fn sheet_of(body: fn(Builder)) -> Builder {
    let b: Builder = new Builder()
    var made: Sheet = new Sheet()
    made.body = body
    b.render_root(made)
    return b
}

/// The HTML a builder's frames serialize to, through the real serializer.
fn html_of(b: Builder) -> string {
    let writer: Serializer = new Serializer()
    return writer.page(b)
}

/// The HTML the APPLIER lands on, after the frames have been diffed into a
/// batch and applied — the second half of "escaped at the serializer **and**
/// at the applier". A serializer that escapes and an applier that does not is
/// an XSS that only shows up in a browser.
fn applied_html(b: Builder) -> string {
    let d: Differ = new Differ()
    let a: Applier = new Applier()
    a.apply(d.batch(b))
    return a.html()
}

/// The serializer's own complaints about a tree, joined.
fn serializer_faults(b: Builder) -> string {
    let writer: Serializer = new Serializer()
    let _: string = writer.page(b)
    return writer.faults.join(" | ")
}

/// A builder's faults, joined. Empty when it raised none.
fn faults_of(b: Builder) -> string { return b.faults.join(" | ") }

/// The handler slot the first batch bound for `click`, read OUT OF the batch.
///
/// A hard-coded slot number is the quiet failure this file nearly shipped: a
/// click on a slot nothing bound lands nowhere, the circuit logs "no handler
/// bound to slot N" and carries on, and every assertion about what the click
/// caused then passes for the wrong reason. Three sections were doing that.
/// `control_click_landed` below is the check that says it did not happen again.
fn click_slot(batch: string) -> int {
    let mark: string = "\"click\","
    match batch.find(mark) {
        none => { return -1 }
        some(at) => {
            var index: int = at + mark.len()
            var digits: string = ""
            for index < batch.len() {
                let byte: int = batch.byte_at(index)
                if byte < 48 || byte > 57 { break }
                digits = "{digits}{batch.slice(index, index + 1)}"
                index += 1
            }
            match parse_int(digits) { some(found) => { return found } none => { return -1 } }
        }
    }
}

fn click_on(slot: int) -> string {
    return "\{\"t\":\"ev\",\"h\":{slot},\"k\":\"click\",\"p\":\{\"b\":0,\"x\":1,\"y\":2\}\}"
}

/// `latte.web.fresh_id()`, with its `Result` unwrapped into a string a check
/// can compare. A CSPRNG failure becomes a value no assertion below accepts,
/// rather than a panic that would read as a suite crash.
fn id_or(tag: string) -> string {
    match fresh_id() {
        ok(value) => { return value }
        err(problem) => { return "no-id-{tag}" }
    }
}

fn main() {
    var r: Report = new Report()

    row1_text(r)
    row2_attribute(r)
    row3_url(r)
    row4_raw_text(r)
    row5_inline_handler(r)
    row6_csrf(r)
    row7_origin(r)
    row8_circuit_id(r)
    row9_authorization(r)
    row10_mass_assignment(r)
    row11_virtual_range(r)
    row12_upload(r)
    row13_compression(r)
    row14_dos(r)
    row15_prototype_pollution(r)
    row16_navigation(r)
    row17_information_disclosure(r)
    row18_headers(r)

    r.roll_call()
}

// ======================================================================= 1
//
// | XSS through interpolated text | every `$expr` is escaped at the
// | serializer **and** at the applier. `$html` is the only bypass, named to be
// | greppable, and the gate counts its uses. |

fn row1_text(r: Report) {
    r.row(1, "XSS through interpolated text")

    // The refusal. `b.text` is what `$expr` compiles to.
    let hostile: Builder = sheet_of(fn(b: Builder) {
        b.open(0, "div")
        b.text(1, "<script>alert(1)</script>")
        b.close()
    })
    r.eq("row1.serializer-escapes-text",
         html_of(hostile),
         "<div>&lt;script&gt;alert(1)&lt;/script&gt;</div>")
    r.eq("row1.applier-escapes-text",
         applied_html(hostile),
         "<div>&lt;script&gt;alert(1)&lt;/script&gt;</div>")

    // The positive control: text with nothing to escape is byte-identical
    // through both. Without it, an escaper that mangled every string would
    // pass the two checks above.
    let plain: Builder = sheet_of(fn(b: Builder) {
        b.open(0, "div")
        b.text(1, "alert(1)")
        b.close()
    })
    r.eq("row1.control-plain-text-untouched", html_of(plain), "<div>alert(1)</div>")
    r.eq("row1.control-plain-text-applier", applied_html(plain), "<div>alert(1)</div>")

    // The escaper itself, on the three bytes it names and on a string with
    // none of them. `&` first, because an escaper that replaced `<` before `&`
    // would double-escape.
    r.eq("row1.escape-text-all-three", escape_text("&<>"), "&amp;&lt;&gt;")
    r.eq("row1.escape-text-ampersand-first", escape_text("&lt;"), "&amp;lt;")
    r.eq("row1.control-escape-text-nothing", escape_text("a'\"b"), "a'\"b")

    // The one bypass, and it is a bypass: `$html` — `b.raw` — writes the
    // markup through. This is asserted rather than assumed, because a bypass
    // that quietly stopped bypassing would break every page using it, and a
    // bypass nobody names is one nobody greps for.
    let bypass: Builder = sheet_of(fn(b: Builder) {
        b.open(0, "div")
        b.raw(1, "<em>trusted</em>")
        b.close()
    })
    r.eq("row1.html-bypass-passes-markup", html_of(bypass), "<div><em>trusted</em></div>")
    r.eq("row1.html-bypass-applier", applied_html(bypass), "<div><em>trusted</em></div>")

    // Nothing above raised a fault: escaping is not a refusal, it is a
    // transformation, and a builder that complained about ordinary text would
    // be a different bug wearing this row's clothes.
    r.eq("row1.no-fault-for-escaping", faults_of(hostile), "")
}

// ======================================================================= 2
//
// | XSS through attribute context | attribute values are always quoted and
// | escaped for attribute context. |

fn row2_attribute(r: Report) {
    r.row(2, "XSS through attribute context")

    // Breaking out of a quoted attribute needs a `"`. It must not survive.
    let hostile: Builder = sheet_of(fn(b: Builder) {
        b.open(0, "div")
        b.attr(1, "title", "\" onmouseover=\"alert(1)")
        b.close()
    })
    r.eq("row2.serializer-escapes-quote",
         html_of(hostile),
         "<div title=\"&quot; onmouseover=&quot;alert(1)\"></div>")
    r.eq("row2.applier-escapes-quote",
         applied_html(hostile),
         "<div title=\"&quot; onmouseover=&quot;alert(1)\"></div>")

    // A single quote is escaped too, which the serializer does not need — it
    // always writes double quotes — and which matters the moment anything
    // downstream rewrites the value into a single-quoted attribute.
    let apos: Builder = sheet_of(fn(b: Builder) {
        b.open(0, "div")
        b.attr(1, "title", "' onmouseover='alert(1)")
        b.close()
    })
    r.eq("row2.serializer-escapes-apostrophe",
         html_of(apos),
         "<div title=\"&#39; onmouseover=&#39;alert(1)\"></div>")

    // An unquoted attribute is the other way out, so the serializer quotes
    // every value — including one with a space, which is what an unquoted
    // emitter would have ended the attribute on.
    let spaced: Builder = sheet_of(fn(b: Builder) {
        b.open(0, "div")
        b.attr(1, "title", "a b")
        b.close()
    })
    r.eq("row2.always-quoted", html_of(spaced), "<div title=\"a b\"></div>")

    // The control: a value with none of the five escaped bytes passes through
    // unchanged, still quoted.
    let plain: Builder = sheet_of(fn(b: Builder) {
        b.open(0, "div")
        b.attr(1, "title", "hello")
        b.close()
    })
    r.eq("row2.control-plain-value", html_of(plain), "<div title=\"hello\"></div>")
    r.eq("row2.control-plain-value-applier", applied_html(plain), "<div title=\"hello\"></div>")

    // The escaper, directly. Attribute context escapes `& < > " '` — the three
    // text ones plus both quotes.
    r.eq("row2.escape-attribute-all-five", escape_attribute("&<>\"'"),
         "&amp;&lt;&gt;&quot;&#39;")
    r.eq("row2.control-escape-attribute-nothing", escape_attribute("a-b c"), "a-b c")

    // The attribute NAME is a second way in: a name carrying a space or a `>`
    // ends the tag. It is refused, and the frame is dropped — not written with
    // a mangled name.
    let badname: Builder = sheet_of(fn(b: Builder) {
        b.open(0, "div")
        b.attr(1, "x y", "1")
        b.close()
    })
    r.eq("row2.refused-attribute-name", faults_of(badname),
         "refused attribute name \"x y\"")
    r.eq("row2.refused-attribute-name-dropped", html_of(badname), "<div></div>")

    // The control for the name rule, differing in one byte: `x-y` is a legal
    // name and is written.
    let okname: Builder = sheet_of(fn(b: Builder) {
        b.open(0, "div")
        b.attr(1, "x-y", "1")
        b.close()
    })
    r.eq("row2.control-attribute-name-accepted", faults_of(okname), "")
    r.eq("row2.control-attribute-name-written", html_of(okname), "<div x-y=\"1\"></div>")

    // The predicate, both ways, so neither edge can be one-sided.
    r.no("row2.name-predicate-refuses-space", attribute_name_is_safe("x y"))
    r.no("row2.name-predicate-refuses-angle", attribute_name_is_safe("x>y"))
    r.no("row2.name-predicate-refuses-quote", attribute_name_is_safe("x\"y"))
    r.yes("row2.control-name-predicate-accepts", attribute_name_is_safe("x-y"))

    // The TAG name is the third. A refused tag becomes `span` rather than
    // being written, because a dropped element would silently lose a subtree.
    let badtag: Builder = sheet_of(fn(b: Builder) {
        b.open(0, "div><script")
        b.text(1, "x")
        b.close()
    })
    r.eq("row2.refused-tag-name", faults_of(badtag), "refused tag name \"div><script\"")
    r.eq("row2.refused-tag-substituted", html_of(badtag), "<span>x</span>")
    r.no("row2.tag-predicate-refuses", tag_name_is_safe("div><script"))
    r.yes("row2.control-tag-predicate-accepts", tag_name_is_safe("div"))
}

// ======================================================================= 3
//
// | XSS through a URL attribute | `href`, `src`, `action`, `formaction`,
// | `poster` and `data` pass a scheme allowlist: http, https, mailto, tel,
// | relative. `javascript:` and `data:` are replaced with an inert value and
// | logged. |

fn row3_url(r: Report) {
    r.row(3, "XSS through a URL attribute")

    // The refusal, on every attribute PLAN.md names plus `xlink:href`, which
    // is the SVG one and the one RULES.md tells the story about.
    let named: List<string> = ["href", "src", "action", "formaction",
                               "poster", "data", "xlink:href"]
    var refused: List<string> = []
    var written: List<string> = []
    for name: string in named {
        let b: Builder = sheet_of(fn(inner: Builder) {
            inner.open(0, "a")
            inner.attr(1, name, "javascript:alert(1)")
            inner.close()
        })
        refused.push("{name}={faults_of(b)}")
        written.push("{name}={html_of(b)}")
    }
    r.eq("row3.every-url-attribute-refuses-javascript",
         refused.join(" | "),
         "href=attribute href carried a refused scheme | src=attribute src carried a refused scheme | action=attribute action carried a refused scheme | formaction=attribute formaction carried a refused scheme | poster=attribute poster carried a refused scheme | data=attribute data carried a refused scheme | xlink:href=attribute xlink:href carried a refused scheme")
    r.eq("row3.every-url-attribute-goes-inert",
         written.join(" | "),
         "href=<a href=\"about:blank\"></a> | src=<a src=\"about:blank\"></a> | action=<a action=\"about:blank\"></a> | formaction=<a formaction=\"about:blank\"></a> | poster=<a poster=\"about:blank\"></a> | data=<a data=\"about:blank\"></a> | xlink:href=<a xlink:href=\"about:blank\"></a>")
    r.eq("row3.inert-value", INERT_URL, "about:blank")

    // The positive control, differing only in the scheme: the same seven
    // attributes carrying `https:` are written through untouched, with no
    // fault. Without this, `is_url_attribute` answering true for everything
    // and `scheme_is_allowed` answering false for everything would pass every
    // check above.
    var kept: List<string> = []
    for name: string in named {
        let b: Builder = sheet_of(fn(inner: Builder) {
            inner.open(0, "a")
            inner.attr(1, name, "https://example.test/x")
            inner.close()
        })
        kept.push("{name}={faults_of(b)}/{html_of(b)}")
    }
    r.eq("row3.control-https-is-kept",
         kept.join(" | "),
         "href=/<a href=\"https://example.test/x\"></a> | src=/<a src=\"https://example.test/x\"></a> | action=/<a action=\"https://example.test/x\"></a> | formaction=/<a formaction=\"https://example.test/x\"></a> | poster=/<a poster=\"https://example.test/x\"></a> | data=/<a data=\"https://example.test/x\"></a> | xlink:href=/<a xlink:href=\"https://example.test/x\"></a>")

    // The second control, and the one that makes the FIRST control mean
    // something: an attribute that is NOT a URL attribute keeps a
    // `javascript:` value verbatim, because it is a string and not a URL. If
    // `is_url_attribute` answered true for everything, this goes red.
    let notaurl: Builder = sheet_of(fn(b: Builder) {
        b.open(0, "a")
        b.attr(1, "title", "javascript:alert(1)")
        b.close()
    })
    r.eq("row3.control-non-url-attribute-keeps-value",
         html_of(notaurl), "<a title=\"javascript:alert(1)\"></a>")
    r.eq("row3.control-non-url-attribute-no-fault", faults_of(notaurl), "")

    // The bytes a browser ignores. `java&#9;script:` reaches the browser's URL
    // parser as `javascript:`, so the probe drops every byte at or below 0x20
    // and 0x7F before it looks for the colon. Six spellings, all inert.
    let evasions: List<string> = [
        "JaVaScRiPt:alert(1)",
        "java\tscript:alert(1)",
        "java\nscript:alert(1)",
        " javascript:alert(1)",
        "jav\u{7f}ascript:alert(1)",
        "data:text/html;base64,PHNjcmlwdD4="
    ]
    var evaded: List<string> = []
    for value: string in evasions {
        let b: Builder = sheet_of(fn(inner: Builder) {
            inner.open(0, "a")
            inner.attr(1, "href", value)
            inner.close()
        })
        evaded.push(html_of(b))
    }
    r.eq("row3.evasions-all-inert",
         evaded.join(" "),
         "<a href=\"about:blank\"></a> <a href=\"about:blank\"></a> <a href=\"about:blank\"></a> <a href=\"about:blank\"></a> <a href=\"about:blank\"></a> <a href=\"about:blank\"></a>")

    // And one by one, so the joined string above cannot hide a single wrong
    // answer behind five right ones.
    var refused2: List<string> = []
    for value: string in evasions { refused2.push("{scheme_is_allowed(value)}") }
    r.eq("row3.scheme-predicate-refuses-each",
         refused2.join(","), "false,false,false,false,false,false")

    // The controls for the evasion rule: the four allowed schemes, a relative
    // path, a fragment, a query, a colon that is inside a path rather than a
    // scheme, the empty value, and a scheme-relative `//`. Each is accepted,
    // and each would go red if the probe simply refused anything with a colon.
    let allowed: List<string> = [
        "http://example.test/", "https://example.test/", "mailto:a@example.test",
        "tel:+15550100", "/local/path", "#frag", "?q=1", "a/b:c", "", "//"
    ]
    var kept2: List<string> = []
    for value: string in allowed { kept2.push("{scheme_is_allowed(value)}") }
    r.eq("row3.control-allowed-schemes",
         kept2.join(","),
         "true,true,true,true,true,true,true,true,true,true")

    // `is_url_attribute` both ways.
    r.yes("row3.url-attribute-href", is_url_attribute("href"))
    r.yes("row3.url-attribute-xlink", is_url_attribute("xlink:href"))
    r.no("row3.control-url-attribute-title", is_url_attribute("title"))

    // The splat path — `attrs={ }` — applies the same rule. It is a SECOND
    // call site in `Builder`, and a rule applied at one of two sites is the
    // shape this project keeps finding.
    let splat: Builder = sheet_of(fn(b: Builder) {
        var extra: Map<string, string> = {}
        extra["href"] = "javascript:alert(1)"
        extra["title"] = "javascript:alert(1)"
        b.open(0, "a")
        b.attrs(1, extra)
        b.close()
    })
    r.eq("row3.splat-refuses-javascript", faults_of(splat),
         "attribute href carried a refused scheme")
    r.eq("row3.splat-goes-inert", html_of(splat),
         "<a href=\"about:blank\" title=\"javascript:alert(1)\"></a>")

    let splat_ok: Builder = sheet_of(fn(b: Builder) {
        var extra: Map<string, string> = {}
        extra["href"] = "https://example.test/"
        b.open(0, "a")
        b.attrs(1, extra)
        b.close()
    })
    r.eq("row3.control-splat-https", faults_of(splat_ok), "")
    r.eq("row3.control-splat-https-written", html_of(splat_ok),
         "<a href=\"https://example.test/\"></a>")
}

// ======================================================================= 4
//
// | XSS through a raw-text element | interpolation inside `<script>` and
// | `<style>` is **refused at compile time**, because the compiler knows the
// | tag. `<textarea>` and `<title>` use their own escaping rules. |
//
// The compile-time half is `tests/markup_refusals.b`, which owns latte-bx.
// This section is the RUNTIME half of the same rule, and it exists because
// the runtime is what a hand-written builder and a folded constant reach: a
// `</script` inside a script body ends the element in every browser, and a
// serializer that wrote it would produce a page whose behaviour was chosen by
// the data.

fn row4_raw_text(r: Report) {
    r.row(4, "XSS through a raw-text element")

    // The refusal: a script body that would close the element out from under
    // the serializer is dropped, with a fault.
    let hostile: Builder = sheet_of(fn(b: Builder) {
        b.open(0, "script")
        b.text(1, "var a = \"</script><img src=x onerror=alert(1)>\"")
        b.close()
    })
    r.eq("row4.script-body-dropped", html_of(hostile), "<script></script>")
    r.eq("row4.script-body-fault", serializer_faults(hostile),
         "text inside <script> could close it")

    // A comment opener moves where a raw-text element ends, so it is refused
    // too.
    let commented: Builder = sheet_of(fn(b: Builder) {
        b.open(0, "style")
        b.text(1, "a\{\} <!-- b")
        b.close()
    })
    r.eq("row4.style-comment-dropped", html_of(commented), "<style></style>")
    r.eq("row4.style-comment-fault", serializer_faults(commented),
         "text inside <style> could close it")

    // The positive control, differing only in the body: an ordinary script
    // body is written VERBATIM — not escaped, because escaping inside a
    // raw-text element changes what the script says.
    let fine: Builder = sheet_of(fn(b: Builder) {
        b.open(0, "script")
        b.text(1, "var a = 1 < 2 && 3 > 2;")
        b.close()
    })
    r.eq("row4.control-script-body-verbatim", html_of(fine),
         "<script>var a = 1 < 2 && 3 > 2;</script>")
    r.eq("row4.control-script-body-no-fault", serializer_faults(fine), "")

    // RCDATA — `<textarea>` and `<title>` — takes ORDINARY text escaping, not
    // raw-text rules: a `<` there is data and must not become a tag.
    let area: Builder = sheet_of(fn(b: Builder) {
        b.open(0, "textarea")
        b.text(1, "</textarea><script>alert(1)</script>")
        b.close()
    })
    r.eq("row4.textarea-escapes", html_of(area),
         "<textarea>&lt;/textarea&gt;&lt;script&gt;alert(1)&lt;/script&gt;</textarea>")

    let title: Builder = sheet_of(fn(b: Builder) {
        b.open(0, "title")
        b.text(1, "</title><script>alert(1)</script>")
        b.close()
    })
    r.eq("row4.title-escapes", html_of(title),
         "<title>&lt;/title&gt;&lt;script&gt;alert(1)&lt;/script&gt;</title>")

    // The control for RCDATA: a body with nothing to escape is untouched.
    let area_ok: Builder = sheet_of(fn(b: Builder) {
        b.open(0, "textarea")
        b.text(1, "hello")
        b.close()
    })
    r.eq("row4.control-textarea-plain", html_of(area_ok), "<textarea>hello</textarea>")

    // The predicate, both ways.
    r.no("row4.raw-text-predicate-refuses-close", raw_text_is_safe("</script>", "script"))
    r.no("row4.raw-text-predicate-refuses-comment", raw_text_is_safe("<!--", "script"))
    r.yes("row4.control-raw-text-predicate-accepts", raw_text_is_safe("1 < 2", "script"))
    // Case-insensitively: `</ScRiPt` closes the element too.
    r.no("row4.raw-text-predicate-case-insensitive",
         raw_text_is_safe("</ScRiPt >", "script"))
    // And it is about THIS tag: `</style` does not close a `<script>`.
    r.yes("row4.control-raw-text-other-tag", raw_text_is_safe("</style>", "script"))
}

// ======================================================================= 5
//
// | XSS through an inline handler | a literal `on*` attribute is refused at
// | compile time. Handlers exist only as ids, and the client never evaluates a
// | string. |

fn row5_inline_handler(r: Report) {
    r.row(5, "XSS through an inline handler")

    // The refusal at the runtime builder, which is where a folded constant and
    // a hand-written builder both arrive.
    let hostile: Builder = sheet_of(fn(b: Builder) {
        b.open(0, "div")
        b.attr(1, "onclick", "alert(1)")
        b.close()
    })
    r.eq("row5.onclick-refused", faults_of(hostile),
         "refused inline handler attribute \"onclick\"")
    r.eq("row5.onclick-dropped", html_of(hostile), "<div></div>")

    // Deliberately blunter than "on plus letters": `on-foo` and `once` are
    // refused too, because `bx/html.b` applies exactly this test at compile
    // time and the two copies are one contract. A compiler that accepted
    // `on-foo` would emit an attribute the builder throws away, and a FOLDED
    // subtree — serialized at build time — would keep it. The same markup
    // would then say two different things depending on `b.fold`.
    let shapes: List<string> = ["onclick", "ONCLICK", "onerror", "on-foo", "once", "ony"]
    var results: List<string> = []
    for name: string in shapes {
        let b: Builder = sheet_of(fn(inner: Builder) {
            inner.open(0, "div")
            inner.attr(1, name, "x")
            inner.close()
        })
        results.push("{name}={html_of(b)}")
    }
    r.eq("row5.every-on-shape-dropped",
         results.join(" "),
         "onclick=<div></div> ONCLICK=<div></div> onerror=<div></div> on-foo=<div></div> once=<div></div> ony=<div></div>")

    // The positive control: two bytes, not three, so `on` itself is NOT a
    // handler — and neither is a name that merely contains `on`. If the
    // predicate answered true for everything, both go red.
    let short: Builder = sheet_of(fn(b: Builder) {
        b.open(0, "div")
        b.attr(1, "on", "x")
        b.close()
    })
    r.eq("row5.control-two-byte-on-kept", html_of(short), "<div on=\"x\"></div>")
    r.eq("row5.control-two-byte-on-no-fault", faults_of(short), "")

    let contains: Builder = sheet_of(fn(b: Builder) {
        b.open(0, "div")
        b.attr(1, "data-on", "x")
        b.close()
    })
    r.eq("row5.control-contains-on-kept", html_of(contains), "<div data-on=\"x\"></div>")

    // The predicate, both ways.
    r.yes("row5.handler-predicate-onclick", attribute_is_inline_handler("onclick"))
    r.yes("row5.handler-predicate-uppercase", attribute_is_inline_handler("ONCLICK"))
    r.no("row5.control-handler-predicate-on", attribute_is_inline_handler("on"))
    r.no("row5.control-handler-predicate-data-on", attribute_is_inline_handler("data-on"))

    // The splat path applies it too.
    let splat: Builder = sheet_of(fn(b: Builder) {
        var extra: Map<string, string> = {}
        extra["onclick"] = "alert(1)"
        extra["class"] = "row"
        b.open(0, "div")
        b.attrs(1, extra)
        b.close()
    })
    r.eq("row5.splat-refuses-handler", faults_of(splat),
         "refused splatted inline handler \"onclick\"")
    r.eq("row5.splat-keeps-the-rest", html_of(splat), "<div class=\"row\"></div>")

    // A real handler exists only as an id: the frame carries an integer, and
    // no string the client could evaluate ever reaches the wire. `dump_tree`
    // is the frame list, so this asserts what is IN the frames rather than
    // what the HTML happens to show.
    let real: Builder = sheet_of(fn(b: Builder) {
        b.open(0, "button")
        b.on_click(1, fn(e: MouseEvent) {})
        b.text(2, "go")
        b.close()
    })
    r.eq("row5.handler-is-an-id-not-a-string", html_of(real), "<button>go</button>")
    r.no("row5.control-handler-frame-carries-no-script",
         real.dump_tree().contains("alert"))
}

// ============================================== the pages rows 9 and 16 use
//
// Declared at file scope because `scan_pages()` reads the executable through
// reflection; a page declared inside a function is not a type.

pub class Member implements Principal {
    pub signed_in: bool = false
    pub role: string = ""
    pub fn init(signed_in: bool, role: string) {
        self.signed_in = signed_in
        self.role = role
    }
    pub fn authenticated() -> bool { return self.signed_in }
    pub fn has_role(role: string) -> bool { return self.role == role }
    pub fn satisfies(policy: string) -> bool { return policy == self.role }
}

@page(route: "/w8/open")
pub class OpenPage extends Component {
    pub fn init() {}
    pub override fn render(b: Builder) {
        b.open(0, "p")
        b.text(1, "open")
        b.close()
    }
}

@page(route: "/w8/private")
@authorize(roles: ["staff"])
pub class PrivatePage extends Component {
    pub fn init() {}
    pub override fn render(b: Builder) {
        b.open(0, "p")
        b.text(1, "private")
        b.close()
    }
}

// ======================================================================= 6
//
// | CSRF on a form post | HMAC-SHA256 over session id, form id and expiry,
// | compared in constant time; session cookie `HttpOnly`, `Secure`,
// | `SameSite=Lax`. |
//
// The cookie half is `tests/w4_formhost.b`, which runs a real espresso host
// and reads `Set-Cookie` off the wire — a cookie's attributes are an HTTP
// header and cannot be asserted from here. This section is the MAC.

fn row6_csrf(r: Report) {
    r.row(6, "CSRF on a form post")

    let signer: Signer = new SeamSigner(hmac_signer("a-test-key"), same_bytes())
    let anti: Antiforgery = new Antiforgery(signer, 900)
    let token: string = anti.issue("session-one", "CheckoutForm", 1000)

    // The positive control FIRST, because every refusal below is "the same
    // call with one input changed" and a control that came last would be
    // reading a token six failures had already established was rejectable.
    r.eq("row6.control-a-genuine-token-is-valid",
         describe_token(anti.check(token, "session-one", "CheckoutForm", 1000)),
         "the token is valid")

    // No token at all.
    r.eq("row6.no-token",
         describe_token(anti.check("", "session-one", "CheckoutForm", 1000)),
         "the form carried no antiforgery token")

    // No session: nothing could have been bound to one, and this is said
    // BEFORE the MAC, because a client with no session cannot be told whether
    // its guess at a token was close.
    r.eq("row6.no-session",
         describe_token(anti.check(token, "", "CheckoutForm", 1000)),
         "the request carried no session, so no token could belong to it")

    // Malformed: no separator, a non-numeric expiry, an empty MAC.
    r.eq("row6.malformed-no-dot",
         describe_token(anti.check("abcdef", "session-one", "CheckoutForm", 1000)),
         "the antiforgery token is malformed")
    r.eq("row6.malformed-expiry-not-a-number",
         describe_token(anti.check("later.abcdef", "session-one", "CheckoutForm", 1000)),
         "the antiforgery token is malformed")
    r.eq("row6.malformed-empty-mac",
         describe_token(anti.check("1900.", "session-one", "CheckoutForm", 1000)),
         "the antiforgery token is malformed")

    // Expired: genuine, and past its expiry. The lifetime is 900, so the token
    // issued at 1000 expires at 1900.
    r.eq("row6.control-one-second-before-expiry",
         describe_token(anti.check(token, "session-one", "CheckoutForm", 1899)),
         "the token is valid")
    r.eq("row6.expired-at-expiry",
         describe_token(anti.check(token, "session-one", "CheckoutForm", 1900)),
         "the antiforgery token has expired")

    // Forged. A token from another session, a token for another form, and a
    // token whose MAC has one byte changed are all `forged` — the same answer
    // an invented token gets, because telling them apart would tell an
    // attacker which of two guesses was wrong.
    r.eq("row6.cross-session",
         describe_token(anti.check(token, "session-two", "CheckoutForm", 1000)),
         "the antiforgery token does not match this session and form")
    r.eq("row6.cross-form",
         describe_token(anti.check(token, "session-one", "ProfileForm", 1000)),
         "the antiforgery token does not match this session and form")

    // One byte of the MAC changed, and nothing else. `0` and `1` are both hex,
    // so this stays a well-formed token and reaches the MAC comparison rather
    // than the shape check.
    var flipped: string = ""
    match token.find(".") {
        none => { flipped = "no-dot" }
        some(at) => {
            let head: string = token.slice(0, at + 1)
            let mac: string = token.slice(at + 1, token.len())
            var first: string = "0"
            if mac.slice(0, 1) == "0" { first = "1" }
            flipped = "{head}{first}{mac.slice(1, mac.len())}"
        }
    }
    r.eq("row6.one-flipped-mac-byte",
         describe_token(anti.check(flipped, "session-one", "CheckoutForm", 1000)),
         "the antiforgery token does not match this session and form")

    // The expiry is COVERED by the MAC, so moving it forward does not extend
    // the token. Without this, an expiry read off the string and trusted would
    // make every token immortal, and every check above would still pass.
    var extended: string = ""
    match token.find(".") {
        none => { extended = "no-dot" }
        some(at) => { extended = "999999.{token.slice(at + 1, token.len())}" }
    }
    r.eq("row6.expiry-is-covered-by-the-mac",
         describe_token(anti.check(extended, "session-one", "CheckoutForm", 1000)),
         "the antiforgery token does not match this session and form")

    // The payload is `{len}:{session}|{len}:{form}|{expiry}`, so no two
    // different (session, form) pairs can produce the same signed string by
    // moving the boundary. Naive concatenation would sign "ab" + "c" and
    // "a" + "bc" identically, and EVERY check above would still pass — a
    // two-literal test cannot see it.
    let ab_c: string = anti.issue("ab", "c", 1000)
    let a_bc: string = anti.issue("a", "bc", 1000)
    r.no("row6.no-boundary-collision", ab_c == a_bc)
    r.eq("row6.control-boundary-pair-checks-out",
         describe_token(anti.check(ab_c, "ab", "c", 1000)),
         "the token is valid")
    r.eq("row6.boundary-pair-does-not-cross",
         describe_token(anti.check(ab_c, "a", "bc", 1000)),
         "the antiforgery token does not match this session and form")

    // And the pair that proves the LENGTH PREFIXES rather than the `|`.
    //
    // The mutation probe found this: dropping `{len}:` from `payload` changed
    // no answer above, because `"ab" + "|" + "c"` and `"a" + "|" + "bc"` are
    // still different strings. The three checks above prove the SEPARATOR.
    // A session id is a value the host chooses and latte constrains nowhere,
    // so one containing the separator byte is an input, not a curiosity — and
    // with `|` alone, `"a|b" + "|" + "c"` and `"a" + "|" + "b|c"` are the same
    // eleven bytes. Only the prefixes tell them apart.
    let pipe_left: string = anti.issue("a|b", "c", 1000)
    let pipe_right: string = anti.issue("a", "b|c", 1000)
    r.no("row6.a-separator-inside-the-session-does-not-collide",
         pipe_left == pipe_right)
    r.eq("row6.control-the-separator-pair-checks-out",
         describe_token(anti.check(pipe_left, "a|b", "c", 1000)),
         "the token is valid")
    r.eq("row6.the-separator-pair-does-not-cross",
         describe_token(anti.check(pipe_left, "a", "b|c", 1000)),
         "the antiforgery token does not match this session and form")

    // A second key signs differently: the MAC is keyed, not a bare digest.
    let other: Antiforgery = new Antiforgery(
        new SeamSigner(hmac_signer("a-different-key"), same_bytes()), 900)
    r.eq("row6.another-key-does-not-verify",
         describe_token(other.check(token, "session-one", "CheckoutForm", 1000)),
         "the antiforgery token does not match this session and form")
    r.no("row6.another-key-signs-differently",
         other.issue("session-one", "CheckoutForm", 1000) == token)

    // The comparison itself, both ways and at three lengths — a compare that
    // stopped at the shorter string would answer true for a prefix.
    let same: fn(string, string) -> bool = same_bytes()
    r.yes("row6.control-compare-equal", same("abcdef", "abcdef"))
    r.no("row6.compare-differs-at-the-end", same("abcdef", "abcdeg"))
    r.no("row6.compare-differs-at-the-start", same("abcdef", "bbcdef"))
    r.no("row6.compare-prefix-is-not-equal", same("abc", "abcdef"))
    r.no("row6.compare-suffix-is-not-equal", same("abcdef", "abc"))

    // The token never carries the session id. A page renders this string into
    // its markup, and a token that carried the session would hand it to
    // anything that could read the page.
    r.no("row6.token-does-not-carry-the-session", token.contains("session-one"))
    r.no("row6.token-does-not-carry-the-form", token.contains("CheckoutForm"))

    // A signer that could not sign answers "", and "" must never verify. The
    // alternative — an empty MAC comparing equal to an empty wanted MAC —
    // would mint a skeleton key out of a digest failure.
    let dead: Antiforgery = new Antiforgery(
        new SeamSigner(fn(data: string) -> string { return "" }, same_bytes()), 900)
    r.eq("row6.a-signer-that-cannot-sign-refuses",
         describe_token(dead.check("1900.x", "session-one", "CheckoutForm", 1000)),
         "the antiforgery token does not match this session and form")

    // And the field the token rides in is one fixed name, not something off
    // the wire.
    r.eq("row6.token-field-name", TOKEN_FIELD, "__latte_token")
}

// ======================================================================= 7
//
// | cross-site WebSocket hijacking | SameSite does not protect a handshake, so
// | the upgrade checks `Origin` and the circuit id must match the session
// | cookie. |
//
// **The comparisons are not reachable from here and this row does not pretend
// they are.** Both live in `CircuitEndpoint.upgrade`, which takes
// `move stream: net.TcpStream`: espresso's in-memory `TestHost` cannot reach
// it and neither can this file. `tests/w4_upgrade.b` drives it over real
// sockets on port 0 — § 4 refuses a foreign `Origin` with the session
// satisfied and refuses a missing session with the `Origin` satisfied, which
// is what tells one refusal from the other.
//
// What IS here is the pair of DEFAULTS those comparisons read, and that is not
// a formality. W4 found that `session_cookie` defaulted to `"sid"` while
// `map_pages` mints `latte_session`, so every handshake read no session, every
// circuit opened for `""`, and `adopt`'s comparison ran on every pair of
// circuits on the machine and could never refuse. The comparison was fine. The
// default made it dead. So the defaults get their own checks, in the file whose
// subject is refusals that cannot fire.

fn row7_origin(r: Report) {
    r.uncovered(7, "cross-site WebSocket hijacking",
        "the Origin and session comparisons are inside CircuitEndpoint.upgrade, which takes `move stream: net.TcpStream`; the socket half of this row is tests/w4_upgrade.b")

    let fresh: EndpointOptions = new EndpointOptions()

    // Empty, and empty means "refuse every handshake that carries an Origin".
    // A deployment must name its own. A default holding some example value
    // would be an allowlist that allows one host nobody deployed.
    r.eqi("row7.the-origin-allowlist-starts-empty", fresh.origins.len(), 0)

    // The name the socket half reads must be the name the page half writes.
    // These are two spellings of one thing in two files, which is exactly the
    // shape that broke, so they are compared to each other and not to a
    // literal — a literal here would have matched `"sid"` just as happily.
    r.eq("row7.the-session-cookie-default-is-the-one-map-pages-mints",
         fresh.session_cookie, SESSION_COOKIE)

    // And a handshake with no session may NOT open a circuit by default,
    // because `""` is not a weaker identity: it is one identity shared by
    // everyone who has it, and `adopt` comparing `""` to `""` is the dead
    // refusal all over again.
    r.no("row7.anonymous-circuits-are-off-by-default", fresh.anonymous_circuits)

    // The control for the whole trio: they are OPTIONS, not constants. Without
    // this, three fields hard-coded to their safe values would pass every check
    // above and a deployment would have no way to name its own origin.
    var opened: EndpointOptions = new EndpointOptions()
    opened.origins = ["https://example.test"]
    opened.session_cookie = "other"
    opened.anonymous_circuits = true
    r.eqi("row7.control-the-allowlist-is-an-option", opened.origins.len(), 1)
    r.eq("row7.control-the-cookie-name-is-an-option", opened.session_cookie, "other")
    r.yes("row7.control-anonymous-circuits-is-an-option", opened.anonymous_circuits)
    r.eqi("row7.control-and-a-fresh-one-is-unchanged",
          new EndpointOptions().origins.len(), 0)
}

// ======================================================================= 8
//
// | circuit id theft or fixation | 256 bits from `std.random`, bound to the
// | session, never in a URL, never logged, rotated when privileges change. |

fn row8_circuit_id(r: Report) {
    r.uncovered(8, "circuit id theft or fixation",
        "PLAN.md says the id is rotated when privileges change; latte has no rotation and no spelling for a privilege change, so that clause has no case here")

    // 256 bits, as 64 hex characters, and two ids differ. A generator that
    // answered a constant would pass a length check on its own.
    let one: string = id_or("first")
    let two: string = id_or("second")
    r.eqi("row8.id-is-64-hex-characters", one.len(), 64)
    r.no("row8.two-ids-differ", one == two)
    var hexonly: bool = true
    var index: int = 0
    for index < one.len() {
        let b: int = one.byte_at(index)
        let digit: bool = b >= 48 && b <= 57
        let lower: bool = b >= 97 && b <= 102
        if !digit && !lower { hexonly = false }
        index += 1
    }
    r.yes("row8.id-is-hex", hexonly)

    // A short id is refused at `open`, so a host that minted its own cannot
    // hand the set a guessable one.
    var short_set: CircuitSet = new CircuitSet(new CircuitOptions(),
        fn(facts: Map<string, string>, url: string) -> Option<Component> {
            return some(new Shell())
        })
    var short_facts: Map<string, string> = {}
    short_facts["id"] = "123456789012345"
    r.eqi("row8.short-id-refused", short_set.open(short_facts, 0), -1)
    r.eq("row8.short-id-fault", short_set.faults.join(" | "),
         "a circuit id must be at least 16 characters")

    // The control, one byte longer.
    var ok_facts: Map<string, string> = {}
    ok_facts["id"] = "1234567890123456"
    r.no("row8.control-sixteen-is-accepted", short_set.open(ok_facts, 0) < 0)

    // An id already open is refused: a second socket cannot fix a circuit onto
    // an id it did not mint.
    var dup_facts: Map<string, string> = {}
    dup_facts["id"] = "1234567890123456"
    short_set.faults.clear()
    r.eqi("row8.duplicate-id-refused", short_set.open(dup_facts, 0), -1)
    r.eq("row8.duplicate-id-fault", short_set.faults.join(" | "),
         "a circuit with that id is already open")

    // Attach must present the id THIS connection was opened with. A stolen id
    // reaches a different socket, and that socket's circuit says no.
    let mine: string = "aaaaaaaaaaaaaaaaaaaa"
    let theirs: string = "bbbbbbbbbbbbbbbbbbbb"
    let wrong: Circuit = new Circuit(mine, new CircuitOptions(),
        fn(url: string) -> Option<Component> { return some(new Shell()) })
    wrong.open(0)
    let _: List<string> = wrong.take_outbox()
    wrong.accept("\{\"t\":\"attach\",\"c\":\"{theirs}\",\"u\":\"/\"\}", 1)
    r.eq("row8.attach-with-another-id-ends-the-circuit",
         wrong.take_outbox().join(" "),
         "\{\"t\":\"bye\",\"k\":\"forbidden\",\"m\":\"the circuit id does not match this connection\"\}")

    // The control, differing only in the id it presents.
    let right: Circuit = new Circuit(mine, new CircuitOptions(),
        fn(url: string) -> Option<Component> { return some(new Shell()) })
    right.open(0)
    let _2: List<string> = right.take_outbox()
    right.accept("\{\"t\":\"attach\",\"c\":\"{mine}\",\"u\":\"/\"\}", 1)
    r.yes("row8.control-attach-with-its-own-id-attaches", right.is_attached())
    r.no("row8.control-attach-with-its-own-id-does-not-end", right.ending())

    // Bound to the session: a resume naming a circuit another session opened
    // is not adopted, and the socket keeps its own fresh circuit.
    var set: CircuitSet = new CircuitSet(new CircuitOptions(),
        fn(facts: Map<string, string>, url: string) -> Option<Component> {
            return some(new Shell())
        })
    var victim: Map<string, string> = {}
    victim["id"] = "cccccccccccccccccccc"
    victim["session"] = "victim-session"
    let vh: int = set.open(victim, 0)
    let _3: List<string> = set.accept(vh, "\{\"t\":\"attach\",\"c\":\"cccccccccccccccccccc\",\"u\":\"/\"\}", 1)

    var thief: Map<string, string> = {}
    thief["id"] = "dddddddddddddddddddd"
    thief["session"] = "thief-session"
    let th: int = set.open(thief, 2)
    set.faults.clear()
    let after: int = set.adopt(th, "\{\"t\":\"resume\",\"c\":\"cccccccccccccccccccc\",\"a\":0\}", 3)
    r.eqi("row8.a-stolen-id-does-not-adopt-across-sessions", after, th)
    r.eq("row8.cross-session-resume-fault", set.faults.join(" | "),
         "a resume named a circuit that belongs to another session")

    // The control, differing only in the session the second socket carries.
    var friend: Map<string, string> = {}
    friend["id"] = "eeeeeeeeeeeeeeeeeeee"
    friend["session"] = "victim-session"
    let fh: int = set.open(friend, 4)
    set.faults.clear()
    let moved: int = set.adopt(fh, "\{\"t\":\"resume\",\"c\":\"cccccccccccccccccccc\",\"a\":0\}", 5)
    r.eqi("row8.control-the-same-session-does-adopt", moved, vh)
    r.eq("row8.control-the-same-session-raises-no-fault", set.faults.join(" | "), "")
}

// ======================================================================= 9
//
// | authorization outliving its token | a circuit can outlive a session's
// | expiry. Auth is revalidated on an interval and at every in-circuit
// | navigation, and `@authorize` is checked **at mount**, not only at the
// | first HTTP request. Blazor's best-known pitfall. |

fn row9_authorization(r: Report) {
    r.row(9, "authorization outliving its token")

    let pages: PageMap = scan_pages()
    r.eq("row9.the-page-scan-refused-nothing", pages.report(), "")

    var found: Option<PageMatch> = pages.find("GET", "/w8/private")
    match found {
        none => { r.eq("row9.the-private-page-is-in-the-map", "missing", "found") }
        some(hit) => {
            r.eq("row9.the-private-page-is-in-the-map", "found", "found")

            // Nobody signed in: challenge, not allow, and not forbid.
            let nobody: PageInstance = open_page(hit, new Anonymous(), none)
            r.no("row9.anonymous-does-not-open", nobody.ok())
            r.eq("row9.anonymous-is-challenged", nobody.problems.join(" | "),
                 "PrivatePage: challenge")

            // Signed in with the wrong role: forbid, not challenge. Two
            // different refusals, and a check that only asserted "did not
            // open" could not tell them apart — which is the difference
            // between a sign-in redirect and a 403.
            let wrong: PageInstance = open_page(hit, new Member(true, "guest"), none)
            r.no("row9.the-wrong-role-does-not-open", wrong.ok())
            r.eq("row9.the-wrong-role-is-forbidden", wrong.problems.join(" | "),
                 "PrivatePage: forbid")

            // The control, differing only in the role.
            let right: PageInstance = open_page(hit, new Member(true, "staff"), none)
            r.yes("row9.control-the-right-role-opens", right.ok())
            r.eq("row9.control-the-right-role-has-no-problem",
                 right.problems.join(" | "), "")
        }
    }

    // The control for the whole rule: a page with no `@authorize` opens for
    // nobody. Without it, `open_page` refusing everything would pass every
    // check above.
    match pages.find("GET", "/w8/open") {
        none => { r.eq("row9.control-an-open-page-is-in-the-map", "missing", "found") }
        some(hit) => {
            r.eq("row9.control-an-open-page-is-in-the-map", "found", "found")
            let anyone: PageInstance = open_page(hit, new Anonymous(), none)
            r.yes("row9.control-an-open-page-opens-for-anonymous", anyone.ok())
        }
    }

    // Checked at MOUNT and not cached from the first request: the same match,
    // opened twice with two principals, answers twice.
    match pages.find("GET", "/w8/private") {
        none => { r.eq("row9.mount-is-not-cached", "missing", "allow-then-refuse") }
        some(hit) => {
            let first: PageInstance = open_page(hit, new Member(true, "staff"), none)
            let second: PageInstance = open_page(hit, new Member(true, "guest"), none)
            r.eq("row9.mount-is-not-cached",
                 "{first.ok()}-then-{second.ok()}", "true-then-false")
        }
    }

    // And at every in-circuit navigation. The circuit's page factory is called
    // again on a `nav`, so a principal that lost its role between the attach
    // and the navigation is refused — which is the pitfall PLAN.md names.
    var ledger: Ledger = new Ledger()
    ledger.role = "staff"
    let pages2: PageMap = pages
    let c: Circuit = new Circuit("ffffffffffffffffffff", new CircuitOptions(),
        fn(url: string) -> Option<Component> {
            match pages2.find("GET", url) {
                none => { return none }
                some(hit) => {
                    let made: PageInstance = open_page(hit, new Member(true, ledger.role), none)
                    if !made.ok() { return none }
                    return made.root()
                }
            }
        })
    c.open(0)
    let _: List<string> = c.take_outbox()
    c.accept("\{\"t\":\"attach\",\"c\":\"ffffffffffffffffffff\",\"u\":\"/w8/private\"\}", 1)
    r.yes("row9.control-the-attach-mounts-while-the-role-holds", c.is_attached())
    r.no("row9.control-the-attach-does-not-end", c.ending())
    let _2: List<string> = c.take_outbox()

    // The role is revoked. Nothing tells the circuit; only the navigation
    // re-asks.
    ledger.role = "guest"
    c.accept("\{\"t\":\"nav\",\"u\":\"/w8/private\"\}", 2)
    r.eq("row9.navigation-re-checks-authorization",
         c.take_outbox().join(" "),
         "\{\"t\":\"bye\",\"k\":\"notfound\",\"m\":\"no page answers that url\"\}")

    // The control, differing only in whether the role was revoked: the same
    // navigation on a circuit whose role still holds renders.
    var ledger2: Ledger = new Ledger()
    ledger2.role = "staff"
    let c2: Circuit = new Circuit("ffffffffffffffffffff", new CircuitOptions(),
        fn(url: string) -> Option<Component> {
            match pages2.find("GET", url) {
                none => { return none }
                some(hit) => {
                    let made: PageInstance = open_page(hit, new Member(true, ledger2.role), none)
                    if !made.ok() { return none }
                    return made.root()
                }
            }
        })
    c2.open(0)
    let _3: List<string> = c2.take_outbox()
    c2.accept("\{\"t\":\"attach\",\"c\":\"ffffffffffffffffffff\",\"u\":\"/w8/private\"\}", 1)
    let _4: List<string> = c2.take_outbox()
    c2.accept("\{\"t\":\"nav\",\"u\":\"/w8/private\"\}", 2)
    r.no("row9.control-navigation-with-the-role-still-held", c2.ending())

    // ---- the interval clause ---------------------------------------------
    //
    // "Auth is revalidated on an interval." A circuit that is neither mounting
    // nor navigating can run for as long as its socket lives, so without this
    // a session that expired an hour ago is still driving a page. Every check
    // below reads `asked.count`: the page factory is the ONE place latte
    // spells page authorization, so a re-ask is what "revalidated" means here,
    // and counting the calls is what tells a re-ask apart from a cached yes.

    var ledger3: Ledger = new Ledger()
    ledger3.role = "staff"
    var asked: Ledger = new Ledger()
    let c3: Circuit = watched_circuit(pages2, ledger3, asked, new CircuitOptions())
    c3.open(0)
    c3.accept("\{\"t\":\"attach\",\"c\":\"ffffffffffffffffffff\",\"u\":\"/w8/private\"\}", 1)
    let asked_at_mount: int = asked.count
    let _5: List<string> = c3.take_outbox()

    // The role is revoked and nothing tells the circuit. Two ticks INSIDE the
    // interval must not re-ask — an interval that fires on every tick would
    // be a page rebuild per tick, and this is the check that says it is an
    // interval and not "always".
    ledger3.role = "guest"
    let _6: bool = c3.tick(2)
    let _7: bool = c3.tick(1000)
    r.eqi("row9.a-tick-inside-the-interval-does-not-re-ask",
          asked.count - asked_at_mount, 0)
    r.no("row9.a-tick-inside-the-interval-does-not-end", c3.ending())

    // One tick past it does, exactly once.
    let _8: bool = c3.tick(60000)
    r.eqi("row9.a-tick-revalidates-authorization", asked.count - asked_at_mount, 1)
    r.yes("row9.a-lapsed-authorization-ends-the-circuit", c3.ending())
    r.eq("row9.a-lapsed-authorization-sends-a-bye", c3.take_outbox().join(" "),
         "\{\"t\":\"bye\",\"k\":\"forbidden\",\"m\":\"the authorization this circuit opened with no longer holds\"\}")

    // The control, differing only in whether the role was revoked. Without it,
    // a `tick` that ended every circuit past 30 s would pass every check above
    // — and `asked.count` proves the control did not pass by skipping the
    // check, which is the other way a green control lies.
    var ledger4: Ledger = new Ledger()
    ledger4.role = "staff"
    var asked4: Ledger = new Ledger()
    let c4: Circuit = watched_circuit(pages2, ledger4, asked4, new CircuitOptions())
    c4.open(0)
    c4.accept("\{\"t\":\"attach\",\"c\":\"ffffffffffffffffffff\",\"u\":\"/w8/private\"\}", 1)
    let asked4_at_mount: int = asked4.count
    let _9: List<string> = c4.take_outbox()
    let _10: bool = c4.tick(60000)
    r.eqi("row9.control-the-held-role-is-re-asked-too",
          asked4.count - asked4_at_mount, 1)
    r.no("row9.control-the-held-role-keeps-the-circuit", c4.ending())
    r.eq("row9.control-the-held-role-sends-nothing", c4.take_outbox().join(" "), "")

    // The interval is the option, not a constant. Same revocation, same tick
    // times, a shorter `revalidate_ms`: the tick at 1000 now re-asks, which
    // the identical tick above did not.
    var ledger5: Ledger = new Ledger()
    ledger5.role = "staff"
    var asked5: Ledger = new Ledger()
    var brisk: CircuitOptions = new CircuitOptions()
    brisk.revalidate_ms = 500
    let c5: Circuit = watched_circuit(pages2, ledger5, asked5, brisk)
    c5.open(0)
    c5.accept("\{\"t\":\"attach\",\"c\":\"ffffffffffffffffffff\",\"u\":\"/w8/private\"\}", 1)
    let _11: List<string> = c5.take_outbox()
    ledger5.role = "guest"
    let _12: bool = c5.tick(2)
    r.no("row9.the-interval-is-the-option-not-a-constant", c5.ending())
    let _13: bool = c5.tick(1000)
    r.yes("row9.a-shorter-interval-catches-it-sooner", c5.ending())

    // A NAVIGATION re-establishes it. `on_nav` runs the factory, so the clock
    // must restart there. The two times are chosen so that ONLY a clock that
    // restarted answers correctly: 31,000 is past the interval measured from
    // the attach at 1 and inside it measured from the nav at 15,000. A case
    // that ticked at 30,000 would pass either way, which is how the first
    // draft of this check let the mutation through.
    var ledger6: Ledger = new Ledger()
    ledger6.role = "staff"
    var asked6: Ledger = new Ledger()
    let c6: Circuit = watched_circuit(pages2, ledger6, asked6, new CircuitOptions())
    c6.open(0)
    c6.accept("\{\"t\":\"attach\",\"c\":\"ffffffffffffffffffff\",\"u\":\"/w8/private\"\}", 1)
    c6.accept("\{\"t\":\"nav\",\"u\":\"/w8/private\"\}", 15000)
    let asked6_after_nav: int = asked6.count
    let _14: List<string> = c6.take_outbox()
    let _15: bool = c6.tick(31000)
    r.eqi("row9.a-navigation-restarts-the-interval",
          asked6.count - asked6_after_nav, 0)
    // and the clock runs from the navigation, not from nothing.
    let _16: bool = c6.tick(45001)
    r.eqi("row9.control-the-interval-still-fires-after-a-navigation",
          asked6.count - asked6_after_nav, 1)

    // A circuit that never attached has no page to be authorized for, and
    // asking would call the factory with the empty url. Ticking one past the
    // interval must ask nothing and end nothing.
    var ledger7: Ledger = new Ledger()
    ledger7.role = "staff"
    var asked7: Ledger = new Ledger()
    let c7: Circuit = watched_circuit(pages2, ledger7, asked7, new CircuitOptions())
    c7.open(0)
    let _17: bool = c7.tick(60000)
    r.eqi("row9.an-unattached-circuit-is-not-revalidated", asked7.count, 0)
    r.no("row9.an-unattached-circuit-is-not-ended-by-it", c7.ending())
}

/// A circuit whose page factory re-runs `open_page` against whatever role the
/// ledger holds AT THE MOMENT IT IS CALLED, and counts the calls.
///
/// The count is the instrument. "Revalidated" means the factory ran again;
/// a check that only looked at `ending()` could not tell a revalidation that
/// refused from a tick that ended the circuit for some other reason, and a
/// control that only looked at `ending()` could not tell "still authorized"
/// from "never asked".
fn watched_circuit(pages: PageMap, ledger: Ledger, asked: Ledger,
                   options: CircuitOptions) -> Circuit {
    let map: PageMap = pages
    return new Circuit("ffffffffffffffffffff", options,
        fn(url: string) -> Option<Component> {
            asked.count += 1
            match map.find("GET", url) {
                none => { return none }
                some(hit) => {
                    let made: PageInstance = open_page(hit, new Member(true, ledger.role), none)
                    if !made.ok() { return none }
                    return made.root()
                }
            }
        })
}

/// A cell two closures share. A `var` captured by a closure is copied, so the
/// role a page factory reads has to live in an object for a later write to be
/// visible to it.
pub class Ledger {
    pub role: string = ""
    pub count: int = 0
    pub fn init() {}
}

pub class Shell extends Component {
    pub fn init() {}
    pub override fn render(b: Builder) {
        b.open(0, "div")
        b.text(1, "shell")
        b.close()
    }
}

// ======================================================================= 10
//
// | mass assignment | no field name ever crosses the wire. Binds are compiled
// | closures over the fields the author wrote. |

@form
pub class Account {
    @field @required pub email: string = ""
    @field pub display: string = ""
    /// Public, and NOT a `@field`. A body naming it must not reach it.
    pub is_admin: bool = false
    /// Public, not a `@field`, and named like something a hostile body would
    /// try. Nothing here is looked up by name off the wire, so it is as
    /// unreachable as `is_admin` — and being unreachable for the SAME reason
    /// is the point.
    pub role: string = "guest"
    pub fn init() {}
}

fn row10_mass_assignment(r: Report) {
    r.row(10, "mass assignment")

    let forms: FormMap = scan_forms(scan_pages())
    var plan: Option<FormPlan> = forms.named("Account")
    match plan {
        none => { r.eq("row10.the-model-is-in-the-map", "missing", "found") }
        some(found) => {
            r.eq("row10.the-model-is-in-the-map", "found", "found")

            // The positive control FIRST: the two annotated fields bind.
            var good: Account = new Account()
            var body: Map<string, string> = {}
            body["email"] = "a@example.test"
            body["display"] = "Ada"
            let took: FormResult = found.bind(reflect.value(good), body)
            r.eq("row10.control-annotated-fields-bind",
                 "{good.email}/{good.display}", "a@example.test/Ada")
            r.yes("row10.control-a-clean-body-is-ok", took.ok())
            r.eq("row10.control-a-clean-body-ignores-nothing", took.ignored.join(","), "")

            // The refusal. Four names a hostile body would post: two real
            // public fields that are not `@field`, one that is not a field at
            // all, and one JavaScript would use to reach an object's parent.
            // Every one of them is IGNORED — named in the report, and written
            // nowhere.
            var target: Account = new Account()
            var hostile: Map<string, string> = {}
            hostile["email"] = "b@example.test"
            hostile["is_admin"] = "true"
            hostile["role"] = "admin"
            hostile["mount"] = "0"
            hostile["__proto__"] = "polluted"
            let bound: FormResult = found.bind(reflect.value(target), hostile)
            r.eq("row10.unannotated-names-are-ignored",
                 bound.ignored.join(","), "__proto__,is_admin,mount,role")
            r.eq("row10.the-model-was-not-mass-assigned",
                 "{target.is_admin}/{target.role}", "false/guest")
            // And the annotated field in the SAME body still bound, so the
            // refusal is per-name and not "this body was thrown away".
            r.eq("row10.the-annotated-field-in-the-same-body-bound",
                 target.email, "b@example.test")
            r.yes("row10.a-hostile-body-is-still-ok", bound.ok())

            // The plan knows only the names the author wrote.
            var names: List<string> = []
            for bound_field: FormField in found.fields { names.push(bound_field.wire_name) }
            names.sort()
            r.eq("row10.the-plan-names-only-the-annotated-fields",
                 names.join(","), "display,email")
            r.no("row10.the-plan-has-no-entry-for-is-admin",
                 found.field_named("is_admin").is_some())
            r.yes("row10.control-the-plan-has-an-entry-for-email",
                  found.field_named("email").is_some())
        }
    }

    // The other half of the row: an EVENT carries no name either. A handler is
    // a slot number the renderer looked up, and a `range` names a component id
    // — both integers this end minted. The frame stream carries the handler's
    // EVENT name (`click`), which is a fixed vocabulary, and never a field, a
    // method or a type.
    let handled: Builder = sheet_of(fn(b: Builder) {
        b.open(0, "button")
        b.on_click(1, fn(e: MouseEvent) {})
        b.close()
    })
    // `describe_frame` prints a handler frame as `{seq} on:{event} -> {id}`
    // (frames.b). The arrow's right-hand side is a slot NUMBER this end minted;
    // nothing in the frame names the method, the field or the closure.
    let dump: string = handled.dump_tree()
    r.yes("row10.a-handler-frame-carries-a-slot-number", dump.contains("on:click -> "))
    r.no("row10.a-handler-frame-carries-no-method-name", dump.contains("on_click"))
    r.no("row10.a-handler-frame-carries-no-closure", dump.contains("fn("))

    // An event for a slot this page never bound reaches nothing, and does not
    // end the circuit: a stale click from a client mid-reconnect is ordinary.
    let c: Circuit = new Circuit("aaaaaaaaaaaaaaaaaaaa", new CircuitOptions(),
        fn(url: string) -> Option<Component> { return some(new Shell()) })
    c.open(0)
    c.accept("\{\"t\":\"attach\",\"c\":\"aaaaaaaaaaaaaaaaaaaa\",\"u\":\"/\"\}", 1)
    let _: List<string> = c.take_outbox()
    c.accept(click_on(9999), 2)
    r.no("row10.an-unknown-slot-does-not-end-the-circuit", c.ending())
    r.eq("row10.an-unknown-slot-is-logged-and-dropped", c.log.join(" | "),
         "no handler bound to slot 9999")
}

// ======================================================================= 11
//
// | virtual range abuse | clamped to collection length, window capped. |

fn row11_virtual_range(r: Report) {
    r.row(11, "virtual range abuse")

    var geometry: VirtualGeometry = new VirtualGeometry()
    geometry.total = 1000
    geometry.row_height = 20
    geometry.max_window = 50

    // The control FIRST: an ordinary window is answered as asked.
    let ordinary: Placement = geometry.window(100, 10)
    r.eq("row11.control-an-ordinary-window",
         ordinary.describe(), "start=100 shown=10 top=2000 bottom=17800")
    r.yes("row11.control-an-ordinary-window-is-sound", ordinary.sound())

    // Capped: a count over `max_window` is trimmed to it, not answered.
    let over: Placement = geometry.window(0, 5000)
    r.eqi("row11.a-count-over-the-cap-is-trimmed", over.shown, 50)
    r.yes("row11.a-trimmed-window-is-sound", over.sound())

    // Clamped to the collection: a window that runs off the end is trimmed to
    // what is left, and a start past the end shows nothing.
    let tail: Placement = geometry.window(990, 50)
    r.eq("row11.a-window-past-the-end-is-trimmed",
         "{tail.start}+{tail.shown}", "990+10")
    let past: Placement = geometry.window(5000, 10)
    r.eq("row11.a-start-past-the-end-shows-nothing",
         "{past.start}+{past.shown}", "1000+0")

    // Negative and extreme numbers. The largest int as a start is the one that
    // breaks the arithmetic if `start` is not clamped FIRST: `total - at` goes
    // hugely negative and the count clamps down to it.
    let negative: Placement = geometry.window(-5, 10)
    r.eq("row11.a-negative-start-clamps-to-zero",
         "{negative.start}+{negative.shown}", "0+10")
    let negative_count: Placement = geometry.window(10, -5)
    r.eq("row11.a-negative-count-clamps-to-zero",
         "{negative_count.start}+{negative_count.shown}", "10+0")
    let huge: Placement = geometry.window(9223372036854775807, 10)
    r.eq("row11.the-largest-int-as-a-start",
         "{huge.start}+{huge.shown}", "1000+0")
    r.yes("row11.the-largest-int-is-still-sound", huge.sound())
    let huge_count: Placement = geometry.window(0, 9223372036854775807)
    r.eqi("row11.the-largest-int-as-a-count", huge_count.shown, 50)

    // `sound()` must be able to answer FALSE, or every assertion of it above
    // is worth nothing. This is the W6 shape: a predicate forced to
    // `return true` left a whole file green because it was asserted true a
    // hundred times and false never.
    var broken: Placement = new Placement()
    broken.start = 5
    broken.shown = 10
    broken.total = 3
    broken.row_height = 20
    r.no("row11.sound-can-answer-false", broken.sound())
    var negative_spacer: Placement = new Placement()
    negative_spacer.start = 0
    negative_spacer.shown = 0
    negative_spacer.total = 10
    negative_spacer.row_height = 20
    negative_spacer.top = -1
    negative_spacer.bottom = 201
    r.no("row11.sound-refuses-a-negative-spacer", negative_spacer.sound())

    // The WIRE's cap is a second, harder one: a `range` message asking for
    // more than `CircuitOptions.max_window` rows ENDS the circuit, because no
    // client latte ships ever sends one.
    var options: CircuitOptions = new CircuitOptions()
    options.max_window = 200
    let c: Circuit = new Circuit("aaaaaaaaaaaaaaaaaaaa", options,
        fn(url: string) -> Option<Component> { return some(new Shell()) })
    c.open(0)
    c.accept("\{\"t\":\"attach\",\"c\":\"aaaaaaaaaaaaaaaaaaaa\",\"u\":\"/\"\}", 1)
    let _: List<string> = c.take_outbox()
    c.accept("\{\"t\":\"range\",\"h\":1,\"s\":0,\"c\":50000\}", 2)
    r.eq("row11.a-range-over-the-wire-cap-ends-the-circuit",
         c.take_outbox().join(" "),
         "\{\"t\":\"bye\",\"k\":\"limit\",\"m\":\"a range asked for 50000 rows, over the 200 cap\"\}")

    // The control, differing only in the count: a range AT the cap does not
    // end the circuit. Without it, "any range ends the circuit" would pass.
    let c2: Circuit = new Circuit("aaaaaaaaaaaaaaaaaaaa", options,
        fn(url: string) -> Option<Component> { return some(new Shell()) })
    c2.open(0)
    c2.accept("\{\"t\":\"attach\",\"c\":\"aaaaaaaaaaaaaaaaaaaa\",\"u\":\"/\"\}", 1)
    let _2: List<string> = c2.take_outbox()
    c2.accept("\{\"t\":\"range\",\"h\":1,\"s\":0,\"c\":200\}", 2)
    r.no("row11.control-a-range-at-the-cap-is-accepted", c2.ending())

    // A negative range is refused at the DECODER, before any of this.
    let message: ClientMessage =
        decode_client("\{\"t\":\"range\",\"h\":1,\"s\":-1,\"c\":5\}", new WireLimits())
    r.eq("row11.a-negative-range-is-refused-at-the-decoder", message.fault,
         "a range must be two non-negative numbers")
}

// ======================================================================= 12
//
// | upload abuse | per-part and total size caps, a part count cap, an allowed
// | content-type list, a generated storage id, a disk quota. |
//
// The caps are espresso's `MultipartLimits` and are crossed here one at a
// time, each with a control just under it. `tests/w6_upload.b` owns the
// byte-split sweep and the release; this is the row-level index.

fn row12_upload(r: Report) {
    r.uncovered(12, "upload abuse",
        "PLAN.md names a disk quota; latte's store keeps no total and std.fs cannot delete a file (BLOCKERS.md B13), so there is no quota to cross")

    var limits: espresso.MultipartLimits = new espresso.MultipartLimits()
    limits.max_parts = 2
    limits.max_part_bytes = 16
    limits.max_total_bytes = 24
    limits.max_filename_bytes = 8

    // The control FIRST: a body inside every cap is taken, and the file's id
    // is one the store opened.
    r.eq("row12.control-a-body-inside-every-cap",
         upload_of(limits, one_file("a.txt", "0123456789")),
         "fields=0 | file f \"a.txt\" text/plain form=10 stored=10")

    // Per-part size.
    r.eq("row12.a-part-over-the-part-cap",
         upload_of(limits, one_file("a.txt", "0123456789abcdefgh")),
         "refused: a multipart part exceeds the 16-byte limit")
    r.eq("row12.control-a-part-at-the-part-cap",
         upload_of(limits, one_file("a.txt", "0123456789abcdef")),
         "fields=0 | file f \"a.txt\" text/plain form=16 stored=16")

    // Total size, crossed by two parts that are each under the part cap. A
    // suite that only ever posted one part could not tell the two caps apart.
    r.eq("row12.two-parts-over-the-total-cap",
         upload_of(limits, two_files("a.txt", "0123456789abcde",
                                     "b.txt", "0123456789abcde")),
         "refused: the multipart body exceeds the 24-byte total limit")
    r.eq("row12.control-two-parts-under-the-total-cap",
         upload_of(limits, two_files("a.txt", "0123456789ab",
                                     "b.txt", "0123456789ab")),
         "fields=0 | file f \"a.txt\" text/plain form=12 stored=12 | file f \"b.txt\" text/plain form=12 stored=12")

    // Part count.
    r.eq("row12.more-parts-than-the-cap",
         upload_of(limits, three_files()),
         "refused: the multipart body carries more than 2 parts")

    // Filename length. The submitted filename is metadata; a long one is
    // refused rather than truncated, because a truncated name is a name the
    // client did not send.
    r.eq("row12.a-filename-over-the-cap",
         upload_of(limits, one_file("aaaaaaaaa.txt", "x")),
         "refused: a submitted filename is longer than 8 bytes")
    r.eq("row12.control-a-filename-at-the-cap",
         upload_of(limits, one_file("aaaa.txt", "x")),
         "fields=0 | file f \"aaaa.txt\" text/plain form=1 stored=1")

    // The storage id is GENERATED and is not the submitted filename. This is
    // the path-traversal defence: a part calling itself `../../etc/passwd`
    // still lands on an id this end minted.
    var log: ReleaseLog = new ReleaseLog()
    var store: HandleStore = new HandleStore(log)
    let traversal: string = describe_body(
        Bytes.from(one_file("../../etc/passwd", "x")),
        "multipart/form-data; boundary=B", new espresso.MultipartLimits(),
        store, ["f"])
    var minted: string = "no handle"
    if store.handles.len() > 0 { minted = store.handles[0].storage_id }
    r.no("row12.the-storage-id-is-not-the-submitted-name",
         minted.contains("passwd"))
    r.no("row12.the-storage-id-has-no-path-separator", minted.contains("/"))
    r.no("row12.the-storage-id-has-no-dot-dot", minted.contains(".."))
    r.yes("row12.control-the-submitted-name-is-kept-as-metadata",
          traversal.contains("../../etc/passwd"))

    // Two parts get two different ids: an id derived from the name would
    // collide the moment two people upload `photo.jpg`.
    var log2: ReleaseLog = new ReleaseLog()
    var store2: HandleStore = new HandleStore(log2)
    let _: string = describe_body(
        Bytes.from(two_files("same.txt", "a", "same.txt", "b")),
        "multipart/form-data; boundary=B", new espresso.MultipartLimits(),
        store2, ["f"])
    var ids: string = "fewer than two handles"
    if store2.handles.len() == 2 {
        ids = "{store2.handles[0].storage_id == store2.handles[1].storage_id}"
    }
    r.eq("row12.two-parts-with-one-name-get-two-ids", ids, "false")

    // latte's own control refuses its AUTHOR's numbers rather than clamping
    // them, with a control for each.
    var bad: Upload = new Upload()
    bad.field = ""
    bad.max_files = 0
    bad.max_bytes = 0
    bad.accept = [""]
    r.eq("row12.an-upload-controls-configuration-refusals",
         bad.problems().join(" | "),
         "an upload control needs a field name | an upload control needs to take at least one file, not 0 | an upload control needs a positive size limit, not 0 | an upload control cannot accept an empty media type")
    var good: Upload = new Upload()
    r.eq("row12.control-a-default-upload-control-is-ok",
         good.problems().join(" | "), "")
    r.eqi("row12.control-the-default-size-cap", good.max_bytes, UPLOAD_MAX_BYTES)
    r.eqi("row12.control-the-default-file-cap", good.max_files, UPLOAD_MAX_FILES)
}

/// One multipart body through latte's store, as one line.
fn upload_of(limits: espresso.MultipartLimits, body: string) -> string {
    var log: ReleaseLog = new ReleaseLog()
    var store: HandleStore = new HandleStore(log)
    return describe_body(Bytes.from(body),
                         "multipart/form-data; boundary=B", limits, store, ["f"])
}

fn one_file(name: string, body: string) -> string {
    return "--B\r\nContent-Disposition: form-data; name=\"f\"; filename=\"{name}\"\r\nContent-Type: text/plain\r\n\r\n{body}\r\n--B--\r\n"
}

fn two_files(a: string, abody: string, b: string, bbody: string) -> string {
    return "--B\r\nContent-Disposition: form-data; name=\"f\"; filename=\"{a}\"\r\nContent-Type: text/plain\r\n\r\n{abody}\r\n--B\r\nContent-Disposition: form-data; name=\"f\"; filename=\"{b}\"\r\nContent-Type: text/plain\r\n\r\n{bbody}\r\n--B--\r\n"
}

fn three_files() -> string {
    return "--B\r\nContent-Disposition: form-data; name=\"f\"; filename=\"a\"\r\nContent-Type: text/plain\r\n\r\nx\r\n--B\r\nContent-Disposition: form-data; name=\"f\"; filename=\"b\"\r\nContent-Type: text/plain\r\n\r\nx\r\n--B\r\nContent-Disposition: form-data; name=\"f\"; filename=\"c\"\r\nContent-Type: text/plain\r\n\r\nx\r\n--B--\r\n"
}

// ======================================================================= 13
//
// | compression amplification | a decompressed message is bounded before it is
// | parsed. The same rule `std.http` already applies to gzip bodies. |

fn row13_compression(r: Report) {
    r.row(13, "compression amplification")

    var limits: WireLimits = new WireLimits()
    limits.max_message = 64

    // The bound is checked BEFORE the parse, so the reader never walks a
    // message it has already decided is too big. The refusal names the size,
    // which is what makes "before" observable: a parser that ran first would
    // answer a syntax fault about the tail instead.
    var long: string = "\{\"t\":\"nav\",\"u\":\"/"
    var index: int = 0
    for index < 100 { long = "{long}a"; index += 1 }
    long = "{long}\"\}"
    let refused: ClientMessage = decode_client(long, limits)
    r.eq("row13.an-oversized-message-is-refused-before-the-parse",
         refused.fault,
         "the message is {long.len()} bytes, over the 64-byte limit")

    // A message that is over the limit AND syntactically broken is refused for
    // being over the limit. That is the ordering, asserted rather than assumed.
    var broken: string = "\{\"t\":\"nav\",\"u\":\"/"
    var index2: int = 0
    for index2 < 100 { broken = "{broken}a"; index2 += 1 }
    let broken_reason: ClientMessage = decode_client(broken, limits)
    r.eq("row13.the-size-check-runs-before-the-syntax-check",
         broken_reason.fault,
         "the message is {broken.len()} bytes, over the 64-byte limit")

    // The control, differing only in length: a message under the limit is
    // decoded.
    let fine: ClientMessage = decode_client("\{\"t\":\"nav\",\"u\":\"/ok\"\}", limits)
    r.eq("row13.control-a-message-under-the-limit-decodes", fine.fault, "")
    r.eq("row13.control-and-it-decoded-the-url", fine.url, "/ok")

    // The default the endpoint runs with, so a deployment that changes nothing
    // is still bounded. The framer's own cap is larger, because it bounds what
    // is ASSEMBLED and this bounds what is READ.
    var stock: WireLimits = new WireLimits()
    r.eqi("row13.the-default-message-cap", stock.max_message, 65536)
    r.eqi("row13.the-default-string-cap", stock.max_text, 32768)
    r.eqi("row13.the-default-depth-cap", stock.max_depth, 24)
    r.eqi("row13.the-default-item-cap", stock.max_items, 512)

    // The other three bounds, each crossed and each with a control one step
    // inside it. A message can be small and still be an attack: 64 bytes of
    // `[[[[…` is a recursive-descent reader's cheapest target.
    var deep: WireLimits = new WireLimits()
    deep.max_depth = 4
    // The cap is charged to EVERY value, a scalar included, so at
    // `max_depth = 4` the deepest literal that reads is three brackets around
    // a number: the `1` inside four brackets is itself a value at depth 4.
    r.eq("row13.nesting-over-the-depth-cap",
         parse_fault("[[[[1]]]]", deep), "nesting deeper than 4")
    r.eq("row13.control-nesting-at-the-depth-cap",
         parse_fault("[[[1]]]", deep), "")

    var wide: WireLimits = new WireLimits()
    wide.max_items = 3
    r.eq("row13.an-array-over-the-item-cap",
         parse_fault("[1,2,3,4]", wide), "an array longer than 3")
    r.eq("row13.control-an-array-at-the-item-cap",
         parse_fault("[1,2,3]", wide), "")
    r.eq("row13.an-object-over-the-item-cap",
         parse_fault("\{\"a\":1,\"b\":2,\"c\":3,\"d\":4\}", wide),
         "an object with more than 3 members")
    r.eq("row13.control-an-object-at-the-item-cap",
         parse_fault("\{\"a\":1,\"b\":2,\"c\":3\}", wide), "")

    var texty: WireLimits = new WireLimits()
    texty.max_text = 4
    r.eq("row13.a-string-over-the-text-cap",
         parse_fault("\"abcde\"", texty), "a string longer than 4 bytes")
    r.eq("row13.control-a-string-at-the-text-cap",
         parse_fault("\"abcd\"", texty), "")
}

/// `parse_json`'s complaint, or `""` when it accepted.
fn parse_json_fault(text: string, limits: WireLimits) -> string {
    match parse_json(text, limits) {
        ok(value) => { return "" }
        err(problem) => { return problem }
    }
}

fn parse_fault(text: string, limits: WireLimits) -> string {
    return parse_json_fault(text, limits)
}

// ======================================================================= 14
//
// | DoS: flooding, render loops, retention | message size cap, inbox depth,
// | per-circuit rate; a cap on render passes per event so a component that
// | dirties itself surfaces in its error boundary; a retention window and a
// | per-worker circuit cap with oldest-first eviction. |

fn row14_dos(r: Report) {
    r.uncovered(14, "DoS: flooding, render loops, retention",
        "PLAN.md names a per-circuit rate limit; CircuitOptions has no rate and Circuit.accept counts no messages per unit time, so that clause has no case here")

    // The un-acked window. A client that never acks is cut off after
    // `max_unacked` batches rather than being replayed forever.
    var options: CircuitOptions = new CircuitOptions()
    options.max_unacked = 3
    let c: Circuit = new Circuit("aaaaaaaaaaaaaaaaaaaa", options,
        fn(url: string) -> Option<Component> { return some(new Ticker()) })
    c.open(0)
    c.accept("\{\"t\":\"attach\",\"c\":\"aaaaaaaaaaaaaaaaaaaa\",\"u\":\"/\"\}", 1)
    let boot: int = click_slot(c.take_outbox().join(" "))
    var step: int = 0
    for step < 8 {
        c.accept(click_on(boot), 2 + step)
        step += 1
    }
    r.eq("row14.control-the-clicks-landed-on-a-handler", c.log.join(" | "), "")
    r.yes("row14.a-client-that-never-acks-is-ended", c.ending())
    r.eq("row14.and-the-reason-names-the-window", c.end_reason(), "limit")

    // The control, differing only in that the client acks: the same eight
    // clicks on a circuit that acknowledges each batch never end it.
    let c2: Circuit = new Circuit("aaaaaaaaaaaaaaaaaaaa", options,
        fn(url: string) -> Option<Component> { return some(new Ticker()) })
    c2.open(0)
    c2.accept("\{\"t\":\"attach\",\"c\":\"aaaaaaaaaaaaaaaaaaaa\",\"u\":\"/\"\}", 1)
    let boot2: int = click_slot(c2.take_outbox().join(" "))
    var step2: int = 0
    for step2 < 8 {
        c2.accept(click_on(boot2), 2 + step2 * 2)
        c2.accept("\{\"t\":\"ack\",\"b\":{c2.batch_count()}\}", 3 + step2 * 2)
        step2 += 1
    }
    r.eq("row14.control-the-acking-clients-clicks-landed", c2.log.join(" | "), "")
    r.no("row14.control-a-client-that-acks-is-not-ended", c2.ending())

    // Render loops. A component that dirties itself from its own render would
    // spin forever on the circuit's fiber. The cap is charged in `settle()`,
    // which runs on an EVENT — `on_attach` publishes and does not settle — so
    // a spinning page mounts once and only loops when something is clicked.
    // That is PLAN.md's reading, "a cap on render passes per event".
    //
    // With a boundary above it the failure SURFACES THERE and the circuit
    // lives, which is the clause PLAN.md actually states.
    var loop_options: CircuitOptions = new CircuitOptions()
    loop_options.max_renders = 4
    let c3: Circuit = new Circuit("aaaaaaaaaaaaaaaaaaaa", loop_options,
        fn(url: string) -> Option<Component> { return some(new SpinShell()) })
    c3.open(0)
    c3.accept("\{\"t\":\"attach\",\"c\":\"aaaaaaaaaaaaaaaaaaaa\",\"u\":\"/\"\}", 1)
    let boot3: int = click_slot(c3.take_outbox().join(" "))
    r.no("row14.control-a-spinning-page-mounts-without-looping", c3.ending())
    c3.accept(click_on(boot3), 2)
    let spun: string = c3.take_outbox().join(" ")
    r.no("row14.a-boundary-catches-the-render-loop", c3.ending())
    r.yes("row14.and-the-client-is-told-through-err", spun.contains("\"t\":\"err\""))
    r.yes("row14.and-the-log-names-the-render-cap",
          c3.log.join(" | ").contains("a component re-rendered itself 4 times without settling"))

    // With NO boundary the circuit ends instead of spinning. The kind is
    // `panic` and not a limit word, because the render cap routes through the
    // same containment a panic does — which is what makes the boundary case
    // above possible at all.
    let c3b: Circuit = new Circuit("aaaaaaaaaaaaaaaaaaaa", loop_options,
        fn(url: string) -> Option<Component> { return some(new Spinner()) })
    c3b.open(0)
    c3b.accept("\{\"t\":\"attach\",\"c\":\"aaaaaaaaaaaaaaaaaaaa\",\"u\":\"/\"\}", 1)
    let boot3b: int = click_slot(c3b.take_outbox().join(" "))
    c3b.accept(click_on(boot3b), 2)
    r.yes("row14.an-unguarded-render-loop-ends-the-circuit", c3b.ending())
    r.eq("row14.and-the-reason-is-panic", c3b.end_reason(), "panic")
    r.yes("row14.and-that-log-names-the-render-cap-too",
          c3b.log.join(" | ").contains("a component re-rendered itself 4 times without settling"))

    // The control: a component that settles renders and the circuit lives.
    let c4: Circuit = new Circuit("aaaaaaaaaaaaaaaaaaaa", loop_options,
        fn(url: string) -> Option<Component> { return some(new Ticker()) })
    c4.open(0)
    c4.accept("\{\"t\":\"attach\",\"c\":\"aaaaaaaaaaaaaaaaaaaa\",\"u\":\"/\"\}", 1)
    let boot4: int = click_slot(c4.take_outbox().join(" "))
    c4.accept(click_on(boot4), 2)
    r.no("row14.control-a-component-that-settles-is-not-stopped", c4.ending())
    r.eq("row14.control-and-it-logged-nothing", c4.log.join(" | "), "")

    // The idle timeout.
    var idle: CircuitOptions = new CircuitOptions()
    idle.idle_ms = 1000
    let c5: Circuit = new Circuit("aaaaaaaaaaaaaaaaaaaa", idle,
        fn(url: string) -> Option<Component> { return some(new Shell()) })
    c5.open(0)
    c5.accept("\{\"t\":\"attach\",\"c\":\"aaaaaaaaaaaaaaaaaaaa\",\"u\":\"/\"\}", 100)
    let _: bool = c5.tick(1099)
    r.no("row14.control-just-inside-the-idle-window", c5.ending())
    let _2: bool = c5.tick(1100)
    r.yes("row14.past-the-idle-window-the-circuit-ends", c5.ending())
    r.eq("row14.and-the-reason-is-idle", c5.end_reason(), "idle")

    // The per-worker circuit cap, and oldest-FIRST eviction of a DISCONNECTED
    // circuit. Three circuits into a set of two: the first, which dropped, is
    // the one that goes.
    var two: CircuitOptions = new CircuitOptions()
    two.max_circuits = 2
    var set: CircuitSet = new CircuitSet(two,
        fn(facts: Map<string, string>, url: string) -> Option<Component> {
            return some(new Shell())
        })
    var f1: Map<string, string> = {}
    f1["id"] = "1111111111111111"
    var f2: Map<string, string> = {}
    f2["id"] = "2222222222222222"
    var f3: Map<string, string> = {}
    f3["id"] = "3333333333333333"
    let h1: int = set.open(f1, 0)
    let h2: int = set.open(f2, 1)
    let _3: bool = set.disconnect(h1, 2)
    let _4: bool = set.disconnect(h2, 3)
    let h3: int = set.open(f3, 4)
    r.no("row14.the-third-circuit-was-opened", h3 < 0)
    r.eqi("row14.the-oldest-disconnected-circuit-was-evicted",
          set.handle_for("1111111111111111"), -1)
    r.no("row14.the-newer-one-was-kept", set.handle_for("2222222222222222") < 0)

    // And a set whose circuits are all LIVE refuses the new one rather than
    // killing a working tab for a speculative one.
    var live: CircuitSet = new CircuitSet(two,
        fn(facts: Map<string, string>, url: string) -> Option<Component> {
            return some(new Shell())
        })
    var g1: Map<string, string> = {}
    g1["id"] = "1111111111111111"
    var g2: Map<string, string> = {}
    g2["id"] = "2222222222222222"
    var g3: Map<string, string> = {}
    g3["id"] = "3333333333333333"
    let k1: int = live.open(g1, 0)
    let k2: int = live.open(g2, 1)
    live.faults.clear()
    r.eqi("row14.a-full-set-of-live-circuits-refuses", live.open(g3, 2), -1)
    r.eq("row14.and-says-so", live.faults.join(" | "),
         "this worker already holds 2 live circuits")
    r.no("row14.control-no-live-circuit-was-evicted",
         live.handle_for("1111111111111111") < 0)

    // Retention: a dropped circuit is kept for `retention_ms` and swept after.
    var kept: CircuitOptions = new CircuitOptions()
    kept.retention_ms = 500
    var set2: CircuitSet = new CircuitSet(kept,
        fn(facts: Map<string, string>, url: string) -> Option<Component> {
            return some(new Shell())
        })
    var f4: Map<string, string> = {}
    f4["id"] = "4444444444444444"
    let h4: int = set2.open(f4, 0)
    let _5: bool = set2.disconnect(h4, 100)
    r.eqi("row14.control-a-dropped-circuit-is-kept-inside-the-window",
          set2.sweep(599), 0)
    r.no("row14.control-and-is-still-there", set2.handle_for("4444444444444444") < 0)
    r.eqi("row14.past-the-retention-window-it-is-swept", set2.sweep(600), 1)
    r.eqi("row14.and-is-gone", set2.handle_for("4444444444444444"), -1)
}

/// A component that renders once and settles. The control for the loop cap.
pub class Ticker extends Component {
    pub count: int = 0
    pub fn init() {}
    pub override fn render(b: Builder) {
        b.open(0, "button")
        b.on_click(1, fn(e: MouseEvent) { self.count += 1 })
        b.text(2, "{self.count}")
        b.close()
    }
}

/// The same spinner behind an error boundary, which is where PLAN.md says the
/// failure must surface.
pub class SpinShell extends ErrorBoundary {
    pub inner: Spinner = new Spinner()
    pub fn init() {
        super.init()
        self.body = fn(b: Builder) {
            b.component_made<Spinner>(0, fn() -> Spinner { return self.inner },
                                      fn(c: Spinner) {})
        }
    }
}

/// A component that marks itself dirty from inside its own render. Without the
/// cap this is an infinite loop on the circuit's fiber.
pub class Spinner extends Component {
    pub count: int = 0
    pub fn init() {}
    pub override fn render(b: Builder) {
        self.count += 1
        self.notify()
        b.open(0, "button")
        b.on_click(1, fn(e: MouseEvent) {})
        b.text(2, "{self.count}")
        b.close()
    }
}

// ======================================================================= 15
//
// | prototype pollution in the applier | a fixed opcode table, no property
// | name taken from the wire, `__proto__` and `constructor` refused,
// | null-prototype maps. |
//
// The JavaScript half is `js/latte.js` and is exercised by `test.sh`'s
// browser-apply leg against a real DOM. This section is the BEANS half: the
// reader that turns bytes into a message, and the decoder that turns a message
// into a kind. Both must treat every name off the wire as data.

fn row15_prototype_pollution(r: Report) {
    r.row(15, "prototype pollution in the applier")

    var limits: WireLimits = new WireLimits()

    // `__proto__` and `constructor` as object keys are ordinary members. They
    // parse, they are readable by name, and reading one reaches nothing else.
    match parse_json("\{\"__proto__\":\{\"polluted\":1\},\"constructor\":2,\"t\":\"ack\"\}", limits) {
        err(problem) => { r.eq("row15.hostile-keys-parse-as-data", problem, "parsed") }
        ok(root) => {
            r.eq("row15.hostile-keys-parse-as-data", "parsed", "parsed")
            r.eqi("row15.and-are-ordinary-members", root.int_field("constructor", -1), 2)
            r.eq("row15.and-nothing-else-changed", root.text_field("t", ""), "ack")
            // The key that would matter: reading a field this object does NOT
            // have must answer the fallback, not something inherited.
            r.eqi("row15.an-absent-field-answers-the-fallback",
                  root.int_field("polluted", -1), -1)
            r.eq("row15.an-absent-text-field-answers-the-fallback",
                 root.text_field("toString", "absent"), "absent")
        }
    }

    // A message whose kind is `__proto__` reaches no branch: the decoder is a
    // fixed table of seven names and everything else is refused.
    let hostile: ClientMessage =
        decode_client("\{\"t\":\"__proto__\",\"h\":1\}", limits)
    // The message does not quote the kind back. That is deliberate on the
    // information-disclosure row's own logic and it is what `wire.b` says.
    r.eq("row15.an-unknown-kind-is-refused", hostile.fault,
         "unknown message kind")

    // The control, differing only in the kind: one of the seven decodes.
    let known: ClientMessage = decode_client("\{\"t\":\"ack\",\"b\":3\}", limits)
    r.eq("row15.control-a-known-kind-decodes", known.fault, "")
    r.eqi("row15.control-and-carries-its-batch", known.batch, 3)

    // Every one of the seven, so "an unknown kind is refused" cannot be a
    // decoder that refuses everything.
    let kinds: List<string> = [
        "\{\"t\":\"attach\",\"c\":\"cid1234567890123456\",\"u\":\"/\"\}",
        "\{\"t\":\"resume\",\"c\":\"cid1234567890123456\",\"a\":0\}",
        "\{\"t\":\"ev\",\"h\":1,\"k\":\"click\",\"p\":\{\"b\":0,\"x\":0,\"y\":0\}\}",
        "\{\"t\":\"ack\",\"b\":1\}",
        "\{\"t\":\"nav\",\"u\":\"/x\"\}",
        "\{\"t\":\"js\",\"i\":1,\"ok\":true,\"v\":\"\"\}",
        "\{\"t\":\"range\",\"h\":1,\"s\":0,\"c\":1\}"
    ]
    var faults: List<string> = []
    for text: string in kinds {
        faults.push("{decode_client(text, limits).fault}")
    }
    r.eq("row15.control-all-seven-kinds-decode", faults.join("/"), "//////")

    // A message that is not an object at all — an array, a bare string, a
    // number — is refused before any field is read.
    r.eq("row15.an-array-is-not-a-message",
         decode_client("[1,2,3]", limits).fault, "a message must be a JSON object")
    r.eq("row15.a-string-is-not-a-message",
         decode_client("\"__proto__\"", limits).fault, "a message must be a JSON object")
    r.eq("row15.a-number-is-not-a-message",
         decode_client("7", limits).fault, "a message must be a JSON object")

    // The event NAME is a fixed vocabulary too, and an unknown one is refused
    // rather than being passed through to a lookup.
    let odd: ClientMessage =
        decode_client("\{\"t\":\"ev\",\"h\":1,\"k\":\"__proto__\",\"p\":\{\}\}", limits)
    r.no("row15.an-unknown-event-name-does-not-decode-clean", odd.fault == "")

    // And a handler id is a NUMBER. A string there is refused, not coerced —
    // a coerced 0 would land on a real slot.
    let stringy: ClientMessage =
        decode_client("\{\"t\":\"ev\",\"h\":\"__proto__\",\"k\":\"click\",\"p\":\{\}\}", limits)
    r.no("row15.a-string-handler-id-does-not-decode-clean", stringy.fault == "")

    // On the Beans side the opcode table is an ENUM, so an unknown opcode is
    // unrepresentable and the row's "fixed opcode table" clause is a claim
    // about `js/latte.js` — which `test.sh`'s browser-apply leg checks against
    // a real DOM. What this side can assert is the other clause: a component
    // is addressed by an INTEGER this end minted, and an update naming one
    // that was never mounted is a fault rather than a root the wire created.
    var stray: Applier = new Applier()
    var stray_batch: Batch = new Batch()
    stray_batch.updates.push(new ComponentUpdate(42))
    stray.apply(stray_batch)
    r.eq("row15.an-update-for-an-unmounted-component-is-a-fault",
         stray.faults.join(" | "),
         "update for component 42 arrived before its mount")

    // The control, differing only in the component id: an update for the page
    // root, which every applier holds, raises nothing.
    var mounted: Applier = new Applier()
    var mount_batch: Batch = new Batch()
    mount_batch.updates.push(new ComponentUpdate(0))
    mounted.apply(mount_batch)
    r.eq("row15.control-an-update-for-the-root-is-not-a-fault",
         mounted.faults.join(" | "), "")
}

// ======================================================================= 16
//
// | open redirect and SSRF through navigation | a nav target must be
// | same-origin and path-only; anything else ends the circuit. |

fn row16_navigation(r: Report) {
    r.row(16, "open redirect and SSRF through navigation")

    // The predicate, refusing every shape that leaves this origin.
    let hostile: List<string> = [
        "https://evil.test/x",
        "//evil.test/x",
        "\\\\evil.test\\x",
        "/x\\..\\y",
        "http://127.0.0.1:9200/_cluster/health",
        "file:///etc/passwd",
        "javascript:alert(1)",
        "x/y",
        "",
        "/a/../../etc/passwd",
        "/ok\nSet-Cookie: a=b",
        "/ok\rSet-Cookie: a=b"
    ]
    var answers: List<string> = []
    for url: string in hostile { answers.push("{nav_target_is_local(url)}") }
    r.eq("row16.every-hostile-target-is-refused",
         answers.join(","),
         "false,false,false,false,false,false,false,false,false,false,false,false")

    // The control: every shape a real navigation takes is accepted. Without
    // it, a predicate that answered false for everything would pass the check
    // above — and latte would have no working navigation at all.
    let local: List<string> = [
        "/", "/orders", "/orders/17", "/orders?page=2", "/orders#top",
        "/a/b/c", "/orders/17?tab=lines#row-3", "/a.b", "/a..b", "/...",
        "/%2e%2e/x"
    ]
    var ok_answers: List<string> = []
    for url: string in local { ok_answers.push("{nav_target_is_local(url)}") }
    r.eq("row16.control-every-local-target-is-accepted",
         ok_answers.join(","),
         "true,true,true,true,true,true,true,true,true,true,true")

    // A `..` segment after the query is NOT a path segment and does not make
    // the target hostile — the rule reads the path, not the whole string. This
    // is the edge that separates "checks the path" from "greps for two dots".
    r.yes("row16.control-dot-dot-in-a-query-is-not-a-path-segment",
          nav_target_is_local("/orders?next=../x"))
    r.yes("row16.control-dot-dot-in-a-fragment-is-not-a-path-segment",
          nav_target_is_local("/orders#../x"))
    r.no("row16.but-dot-dot-in-the-path-is",
         nav_target_is_local("/orders/../x"))

    // And through a circuit: a hostile `nav` message ends it, with `forbidden`.
    let c: Circuit = new Circuit("aaaaaaaaaaaaaaaaaaaa", new CircuitOptions(),
        fn(url: string) -> Option<Component> { return some(new Shell()) })
    c.open(0)
    c.accept("\{\"t\":\"attach\",\"c\":\"aaaaaaaaaaaaaaaaaaaa\",\"u\":\"/\"\}", 1)
    let _: List<string> = c.take_outbox()
    c.accept("\{\"t\":\"nav\",\"u\":\"https://evil.test/x\"\}", 2)
    r.eq("row16.a-hostile-nav-ends-the-circuit",
         c.take_outbox().join(" "),
         "\{\"t\":\"bye\",\"k\":\"forbidden\",\"m\":\"a navigation target must be same-origin and path-only\"\}")

    // The control, differing only in the target.
    let c2: Circuit = new Circuit("aaaaaaaaaaaaaaaaaaaa", new CircuitOptions(),
        fn(url: string) -> Option<Component> { return some(new Shell()) })
    c2.open(0)
    c2.accept("\{\"t\":\"attach\",\"c\":\"aaaaaaaaaaaaaaaaaaaa\",\"u\":\"/\"\}", 1)
    let _2: List<string> = c2.take_outbox()
    c2.accept("\{\"t\":\"nav\",\"u\":\"/other\"\}", 2)
    r.no("row16.control-a-local-nav-does-not-end-the-circuit", c2.ending())

    // The SERVER's own navigation takes the same road: `Circuit.navigate`
    // refuses a target a client would have been ended for, rather than
    // trusting the application.
    let c3: Circuit = new Circuit("aaaaaaaaaaaaaaaaaaaa", new CircuitOptions(),
        fn(url: string) -> Option<Component> { return some(new Shell()) })
    c3.open(0)
    r.no("row16.the-server-cannot-navigate-off-origin",
         c3.navigate("https://evil.test/x"))
    r.yes("row16.control-the-server-can-navigate-locally", c3.navigate("/other"))
}

// ======================================================================= 17
//
// | information disclosure | espresso's `detailed_errors` gate already hides
// | server detail behind a trace id; a contained panic goes to the log, never
// | to the client. |

fn row17_information_disclosure(r: Report) {
    r.row(17, "information disclosure")

    let secret: string = "the-connection-string-is-secret"

    // A panic inside a boundary: the client gets a trace id, the log gets the
    // message. `run` is latte's containment; without it the panic would end
    // the process.
    let c: Circuit = new Circuit("aaaaaaaaaaaaaaaaaaaa", new CircuitOptions(),
        fn(url: string) -> Option<Component> { return some(new Guarded(secret)) })
    c.guard = fn(body: fn() -> bool) -> string { return run(body) }
    c.open(0)
    c.accept("\{\"t\":\"attach\",\"c\":\"aaaaaaaaaaaaaaaaaaaa\",\"u\":\"/\"\}", 1)
    let slot: int = click_slot(c.take_outbox().join(" "))
    c.accept(click_on(slot), 2)
    let sent: string = c.take_outbox().join(" ")

    r.no("row17.the-wire-does-not-carry-the-panic-message", sent.contains(secret))
    r.yes("row17.the-wire-carries-a-trace-id", sent.contains("\"t\":\"err\""))
    r.yes("row17.the-log-carries-the-panic-message",
          c.log.join(" | ").contains(secret))

    // The trace id the client was given is the one the log line is keyed by,
    // or the id is useless.
    var quoted: string = "no trace"
    for line: string in c.log {
        match line.find(":") {
            none => {}
            some(at) => { if quoted == "no trace" { quoted = line.slice(0, at) } }
        }
    }
    r.yes("row17.the-trace-id-on-the-wire-matches-the-log",
          sent.contains("\"m\":\"{quoted}\""))

    // The control, differing only in whether the handler panics: an ordinary
    // click sends a batch and writes nothing to the log.
    let c2: Circuit = new Circuit("aaaaaaaaaaaaaaaaaaaa", new CircuitOptions(),
        fn(url: string) -> Option<Component> { return some(new Guarded("")) })
    c2.guard = fn(body: fn() -> bool) -> string { return run(body) }
    c2.open(0)
    c2.accept("\{\"t\":\"attach\",\"c\":\"aaaaaaaaaaaaaaaaaaaa\",\"u\":\"/\"\}", 1)
    let slot2: int = click_slot(c2.take_outbox().join(" "))
    c2.accept(click_on(slot2), 2)
    let sent2: string = c2.take_outbox().join(" ")
    r.eq("row17.control-an-ordinary-click-logs-nothing", c2.log.join(" | "), "")
    r.no("row17.control-an-ordinary-click-sends-no-err", sent2.contains("\"t\":\"err\""))
    r.no("row17.control-an-ordinary-click-does-not-end", c2.ending())

    // A panic with NO boundary above it ends the circuit — and still sends the
    // trace id and not the message.
    let c3: Circuit = new Circuit("aaaaaaaaaaaaaaaaaaaa", new CircuitOptions(),
        fn(url: string) -> Option<Component> { return some(new Unguarded(secret)) })
    c3.guard = fn(body: fn() -> bool) -> string { return run(body) }
    c3.open(0)
    c3.accept("\{\"t\":\"attach\",\"c\":\"aaaaaaaaaaaaaaaaaaaa\",\"u\":\"/\"\}", 1)
    let slot3: int = click_slot(c3.take_outbox().join(" "))
    c3.accept(click_on(slot3), 2)
    let sent3: string = c3.take_outbox().join(" ")
    r.yes("row17.an-unguarded-panic-ends-the-circuit", c3.ending())
    r.no("row17.and-still-does-not-carry-the-message", sent3.contains(secret))
    r.yes("row17.and-still-carries-a-trace-id", sent3.contains("\"t\":\"bye\""))
    r.yes("row17.and-the-unguarded-log-carries-the-message",
          c3.log.join(" | ").contains(secret))

    // Every `bye` reason is a short fixed word, not a sentence about this
    // server. The message beside it is latte's own text, which is why the two
    // checks above are about the PANIC text and not about the reason.
    r.eq("row17.the-end-reason-is-a-fixed-word", c3.end_reason(), "panic")
}

/// A page with an error boundary and a handler that panics inside it.
///
/// The boundary is a mounted COMPONENT and not a frame: `b.boundary(seq)`
/// writes a frame, but `Circuit.nearest_boundary` walks the MOUNT tree looking
/// for a component that is an `ErrorBoundary`. A page that only wrote the
/// frame has no boundary at all, and its panic ends the circuit — which is
/// what the first draft of this section measured while claiming otherwise.
pub class Guarded extends ErrorBoundary {
    pub inner: Fragile = new Fragile()
    pub fn init(secret: string) {
        super.init()
        self.inner.secret = secret
        self.body = fn(b: Builder) {
            b.component_made<Fragile>(0, fn() -> Fragile { return self.inner },
                                      fn(c: Fragile) {})
        }
    }
}

/// The button whose handler panics. Separate from the boundary because a
/// boundary catches what is BELOW it, and a component cannot be below itself.
pub class Fragile extends Component {
    pub secret: string = ""
    pub fn init() {}
    pub override fn render(b: Builder) {
        b.open(0, "button")
        b.on_click(1, fn(e: MouseEvent) {
            if self.secret != "" { panic(self.secret) }
        })
        b.text(2, "go")
        b.close()
    }
}

/// The same handler with no boundary above it.
pub class Unguarded extends Component {
    pub secret: string = ""
    pub fn init(secret: string) { self.secret = secret }
    pub override fn render(b: Builder) {
        b.open(0, "button")
        b.on_click(1, fn(e: MouseEvent) { panic(self.secret) })
        b.text(2, "go")
        b.close()
    }
}

// ======================================================================= 18
//
// | clickjacking and script injection | `latte.security_headers(options)`:
// | `frame-ancestors 'none'`, nosniff, a referrer policy, and a CSP of
// | `script-src 'self'` with `connect-src` for the socket. |
//
// This row failed for as long as `latte.security_headers` did not exist. It
// landed with W4, and the check that stood in for it here was a hand-written
// sentence about what was missing — so it had to be REPLACED by one that
// probes, not flipped to green. A gap-marker check goes on printing whatever
// it was written to print, whether or not the gap closed.
//
// `HeaderOptions.policy()` is the half that needs no server. The middleware
// putting those headers on a real response, and a real headless Chrome reading
// them, is `tests/w4_headers.b` and the gated `csp-browser` leg.

fn row18_headers(r: Report) {
    r.row(18, "clickjacking and script injection")

    // PLAN.md names four things, so four checks. A single `eq` against the
    // whole policy string would say "the policy changed" and not WHICH clause
    // of the plan stopped holding, and it would have to be re-recorded every
    // time a directive is added — which is how an assertion becomes a
    // photograph of a run.
    let options: HeaderOptions = new HeaderOptions()
    let policy: string = options.policy()
    r.yes("row18.the-policy-denies-framing",
          policy.contains("frame-ancestors 'none'"))
    r.yes("row18.the-policy-names-a-script-source",
          policy.contains("script-src 'self'"))
    r.yes("row18.the-policy-names-a-connect-source-for-the-socket",
          policy.contains("connect-src 'self'"))
    r.eq("row18.the-referrer-policy-is-set", options.referrer, "no-referrer")

    // PLAN.md's concrete finding is that espresso's own middleware sends
    // `default-src 'none'` and names no script or connect source, so it blocks
    // `latte.js` and the socket. latte's `default-src` is `'none'` TOO — the
    // difference is only that latte names what it needs, so the refusal falls
    // on what is not named instead of on everything. Asserting `default-src
    // 'none'` here is what stops that clause being read as "latte loosened it".
    r.yes("row18.default-src-is-still-none", policy.contains("default-src 'none'"))
    r.no("row18.and-nothing-was-loosened-with-unsafe-inline",
         policy.contains("unsafe-inline"))
    r.no("row18.and-nothing-was-loosened-with-unsafe-eval",
         policy.contains("unsafe-eval"))

    // The control, and it is the one that matters: `policy()` must READ its
    // options, not print a constant. Every check above passes against a
    // hard-coded string. One field moves, and exactly one directive must move
    // with it — no more, and not none.
    var framed: HeaderOptions = new HeaderOptions()
    framed.frame_ancestors = ["'self'"]
    let moved: string = framed.policy()
    r.yes("row18.control-the-policy-reads-its-options",
          moved.contains("frame-ancestors 'self'"))
    let before: List<string> = policy.split("; ")
    let after: List<string> = moved.split("; ")
    r.eqi("row18.control-and-no-directive-appeared-or-vanished",
          after.len(), before.len())
    var differing: int = 0
    var index: int = 0
    for index < before.len() && index < after.len() {
        if before[index] != after[index] { differing += 1 }
        index += 1
    }
    r.eqi("row18.control-one-option-moves-exactly-one-directive", differing, 1)

    // The half that IS true today, and the reason no `unsafe-inline` is
    // needed: latte writes no inline script and no `eval`. A CSP of
    // `script-src 'self'` is only possible because of this, so it is asserted
    // here rather than left as a claim in a comment.
    let page: Builder = sheet_of(fn(b: Builder) {
        b.open(0, "button")
        b.on_click(1, fn(e: MouseEvent) {})
        b.text(2, "go")
        b.close()
    })
    let markup: string = html_of(page)
    r.no("row18.a-rendered-page-writes-no-inline-handler",
         markup.contains("onclick"))
    r.no("row18.a-rendered-page-writes-no-inline-script",
         markup.contains("<script"))
    r.no("row18.a-rendered-page-writes-no-javascript-url",
         markup.contains("javascript:"))
}
