// The serializer, and constant folding.
//
// Every case is rendered TWICE — once with `b.fold` on and once off — and the
// two HTML strings must be byte-identical: the folded string must equal what
// the unfolded walk would have produced, over every case in this suite. The
// case list lives here rather than in a
// shared fixture package because a package under a module root cannot import
// that root ("a package cannot import its own module root"), so a fixture
// package that builds frames has no spelling; putting the corpus in the
// shipped `latte` package to work around that would put five hundred lines of
// test data in everybody's binary.
//
// The expected output is the folded HTML of every case, with the builder's and the
// serializer's faults under it — a refusal that stopped being a refusal is a
// diff, not a silence. That makes a broken refusal visible as a diff; it does
// not exercise one. `tests/w1_faults.b` § 3 is the audit of `serialize.b`'s
// four report sites — a trip with the exact fault text, a positive control
// that must be accepted, and a confirmed deletion failure for each.
package main

import std.io
import {Builder, Component, InputEvent, MouseEvent, Serializer} from latte


pub class Case {
    pub name: string = ""
    pub body: fn(Builder) = fn(b: Builder) {}
    pub fn init(name: string, body: fn(Builder)) {
        self.name = name
        self.body = body
    }
}

// A child component, so the html suite covers a mounted child's own buffer
// being serialized inline where its `child` frame sits.
pub class Badge extends Component {
    pub label: string = ""
    pub fn init() {}
    pub override fn render(b: Builder) {
        b.open(0, "span")
        b.attr(1, "class", "badge")
        b.text(2, self.label)
        b.close()
    }
}

pub fn html_cases() -> List<Case> {
    var cases: List<Case> = []

    cases.push(new Case("nesting", fn(b: Builder) {
        b.open(0, "div")
        b.attr(1, "id", "root")
        b.open(2, "p")
        b.text(3, "one")
        b.close()
        b.open(4, "p")
        b.text(5, "two")
        b.close()
        b.close()
    }))

    cases.push(new Case("text-escaping", fn(b: Builder) {
        b.open(0, "p")
        b.text(1, "5 < 6 && 7 > 6, \"quoted\" and 'single' and & alone")
        b.close()
    }))

    cases.push(new Case("text-already-entity", fn(b: Builder) {
        // A value that already looks like a character reference must be
        // escaped again, or `&amp;` typed by a user renders as `&`.
        b.open(0, "p")
        b.text(1, "&amp; &#39; &lt;script&gt;")
        b.close()
    }))

    cases.push(new Case("attribute-escaping", fn(b: Builder) {
        b.open(0, "div")
        b.attr(1, "title", "a \"quoted\" & 'single' <tag>")
        b.attr(2, "data-json", "\{\"k\":\"v\"\}")
        b.close()
    }))

    cases.push(new Case("attribute-breakout", fn(b: Builder) {
        // The classic: a value that tries to close its own attribute and open
        // an event handler.
        b.open(0, "div")
        b.attr(1, "class", "x\" onclick=\"steal()")
        b.close()
    }))

    cases.push(new Case("flags", fn(b: Builder) {
        b.open(0, "input")
        b.flag(1, "disabled", true)
        b.flag(2, "readonly", false)
        b.close()
    }))

    cases.push(new Case("flag-shadows-attribute", fn(b: Builder) {
        // The last slot for a name wins, so an absent flag removes an earlier
        // attribute of the same name.
        b.open(0, "input")
        b.attr(1, "checked", "checked")
        b.flag(2, "checked", false)
        b.close()
    }))

    cases.push(new Case("splat", fn(b: Builder) {
        var extra: Map<string, string> = {}
        extra["data-z"] = "last"
        extra["aria-label"] = "first"
        extra["data-m"] = "middle"
        b.open(0, "button")
        b.attr(1, "type", "button")
        b.attrs(2, extra)
        b.close()
    }))

    cases.push(new Case("splat-overrides", fn(b: Builder) {
        var extra: Map<string, string> = {}
        extra["class"] = "from-splat"
        b.open(0, "div")
        b.attr(1, "class", "written-first")
        b.attrs(2, extra)
        b.close()
    }))

    cases.push(new Case("splat-refused-names", fn(b: Builder) {
        var extra: Map<string, string> = {}
        extra["onclick"] = "steal()"
        extra["bad name"] = "x"
        extra["ok-name"] = "y"
        b.open(0, "div")
        b.attrs(1, extra)
        b.close()
    }))

    cases.push(new Case("void-elements", fn(b: Builder) {
        b.open(0, "div")
        b.open(1, "br")
        b.close()
        b.open(2, "img")
        b.attr(3, "src", "/logo.png")
        b.attr(4, "alt", "a & b")
        b.close()
        b.open(5, "hr")
        b.close()
        b.close()
    }))

    cases.push(new Case("script-is-raw-text", fn(b: Builder) {
        b.open(0, "script")
        b.text(1, "if (a < b && c > d) \{ x(\"&\") \}")
        b.close()
    }))

    cases.push(new Case("script-cannot-be-closed", fn(b: Builder) {
        b.open(0, "script")
        b.text(1, "var s = \"</script><img src=x onerror=alert(1)>\"")
        b.close()
    }))

    cases.push(new Case("style-is-raw-text", fn(b: Builder) {
        b.open(0, "style")
        b.text(1, "a > b \{ content: \"&\" \}")
        b.close()
    }))

    cases.push(new Case("rcdata", fn(b: Builder) {
        b.open(0, "textarea")
        b.text(1, "a < b & c")
        b.close()
        b.open(2, "title")
        b.text(3, "Title & <b>")
        b.close()
    }))

    cases.push(new Case("leading-newline", fn(b: Builder) {
        // The parser eats one newline after these start tags, so the
        // serializer writes two to keep one.
        b.open(0, "pre")
        b.text(1, "\nkept")
        b.close()
        b.open(2, "textarea")
        b.text(3, "\nalso kept")
        b.close()
        b.open(4, "div")
        b.text(5, "\nnot special")
        b.close()
    }))

    cases.push(new Case("urls-allowed", fn(b: Builder) {
        b.open(0, "div")
        b.open(1, "a")
        b.attr(2, "href", "/relative/path")
        b.text(3, "relative")
        b.close()
        b.open(4, "a")
        b.attr(5, "href", "https://example.com/x?a=1&b=2")
        b.text(6, "https")
        b.close()
        b.open(7, "a")
        b.attr(8, "href", "mailto:someone@example.com")
        b.text(9, "mail")
        b.close()
        b.open(10, "a")
        b.attr(11, "href", "#anchor")
        b.text(12, "fragment")
        b.close()
        b.open(13, "a")
        b.attr(14, "href", "?query=1")
        b.text(15, "query")
        b.close()
        b.close()
    }))

    cases.push(new Case("urls-refused", fn(b: Builder) {
        b.open(0, "div")
        b.open(1, "a")
        b.attr(2, "href", "javascript:alert(1)")
        b.text(3, "plain")
        b.close()
        b.open(4, "a")
        b.attr(5, "href", "JaVaScRiPt:alert(1)")
        b.text(6, "case")
        b.close()
        b.open(7, "a")
        b.attr(8, "href", "  java\tscript:alert(1)")
        b.text(9, "tab")
        b.close()
        b.open(10, "a")
        b.attr(11, "href", "java\nscript:alert(1)")
        b.text(12, "newline")
        b.close()
        b.open(13, "img")
        b.attr(14, "src", "data:text/html;base64,PHNjcmlwdD4=")
        b.close()
        b.open(15, "a")
        b.attr(16, "xlink:href", "javascript:alert(1)")
        b.text(17, "svg link")
        b.close()
        b.close()
    }))

    cases.push(new Case("raw-html", fn(b: Builder) {
        b.open(0, "div")
        b.raw(1, "<em>trusted by the author</em>")
        b.text(2, "<em>not trusted</em>")
        b.close()
    }))

    cases.push(new Case("constant-simple", fn(b: Builder) {
        b.open(0, "div")
        if b.fold {
            b.constant(1, "<span class=\"icon\"><svg width=\"12\"></svg></span>")
        } else {
            b.open(1, "span")
            b.attr(2, "class", "icon")
            b.open(3, "svg")
            b.attr(4, "width", "12")
            b.close()
            b.close()
        }
        b.close()
    }))

    cases.push(new Case("constant-with-entities", fn(b: Builder) {
        // The folded string is what the walk must produce, character for
        // character. Writing it by hand is the check.
        b.open(0, "footer")
        if b.fold {
            b.constant(1, "<p title=\"a &amp; b &quot;c&quot;\">5 &lt; 6 &amp; 7 &gt; 6</p>")
        } else {
            b.open(1, "p")
            b.attr(2, "title", "a & b \"c\"")
            b.text(3, "5 < 6 & 7 > 6")
            b.close()
        }
        b.close()
    }))

    cases.push(new Case("constant-deep", fn(b: Builder) {
        if b.fold {
            b.constant(0, "<nav class=\"bar\"><ul><li><a href=\"/a\">A</a></li><li><a href=\"/b\">B</a></li></ul></nav>")
        } else {
            b.open(0, "nav")
            b.attr(1, "class", "bar")
            b.open(2, "ul")
            b.open(3, "li")
            b.open(4, "a")
            b.attr(5, "href", "/a")
            b.text(6, "A")
            b.close()
            b.close()
            b.open(7, "li")
            b.open(8, "a")
            b.attr(9, "href", "/b")
            b.text(10, "B")
            b.close()
            b.close()
            b.close()
            b.close()
        }
    }))

    cases.push(new Case("constant-void-inside", fn(b: Builder) {
        b.open(0, "div")
        if b.fold {
            b.constant(1, "<img src=\"/a.png\" alt=\"a\"><br>")
        } else {
            b.open(1, "img")
            b.attr(2, "src", "/a.png")
            b.attr(3, "alt", "a")
            b.close()
            b.open(4, "br")
            b.close()
        }
        b.close()
    }))

    cases.push(new Case("constant-beside-dynamic", fn(b: Builder) {
        b.open(0, "section")
        if b.fold {
            b.constant(1, "<h2>Fixed heading</h2>")
        } else {
            b.open(1, "h2")
            b.text(2, "Fixed heading")
            b.close()
        }
        b.open(3, "p")
        b.text(4, "changes & moves")
        b.close()
        if b.fold {
            b.constant(5, "<hr>")
        } else {
            b.open(5, "hr")
            b.close()
        }
        b.close()
    }))

    cases.push(new Case("keyed-rows", fn(b: Builder) {
        var rows: List<string> = ["alpha", "beta", "gamma", "delta", "epsilon"]
        b.open(0, "ul")
        for row: string in rows {
            b.region(1, row)
            b.open(0, "li")
            b.attr(1, "data-key", row)
            b.text(2, row)
            b.close()
            b.end_region()
        }
        b.close()
    }))

    cases.push(new Case("keyed-multi-root-rows", fn(b: Builder) {
        // A row with two roots. A region is a transparent container, so the
        // two `<dt>`/`<dd>` land as siblings inside the `<dl>`.
        var rows: List<string> = ["a", "b", "c", "d", "e"]
        b.open(0, "dl")
        for row: string in rows {
            b.region(1, row)
            b.open(0, "dt")
            b.text(1, row)
            b.close()
            b.open(2, "dd")
            b.text(3, "value of {row}")
            b.close()
            b.end_region()
        }
        b.close()
    }))

    cases.push(new Case("nested-regions", fn(b: Builder) {
        var outer: List<string> = ["x", "y", "z"]
        var inner: List<string> = ["1", "2", "3"]
        b.open(0, "div")
        for a: string in outer {
            b.region(1, a)
            b.open(0, "ul")
            for c: string in inner {
                b.region(1, c)
                b.open(0, "li")
                b.text(1, "{a}{c}")
                b.close()
                b.end_region()
            }
            b.close()
            b.end_region()
        }
        b.close()
    }))

    cases.push(new Case("fragment", fn(b: Builder) {
        b.open(0, "div")
        b.fragment(1, fn(inner: Builder) {
            inner.open(0, "em")
            inner.text(1, "slotted")
            inner.close()
        })
        b.text(2, "after")
        b.close()
    }))

    cases.push(new Case("child-component", fn(b: Builder) {
        b.open(0, "div")
        b.component<Badge>(1, fn(c: Badge) { c.label = "new & shiny" })
        b.text(2, "beside it")
        b.close()
    }))

    cases.push(new Case("refused-names", fn(b: Builder) {
        b.open(0, "div")
        b.attr(1, "on click", "x")
        b.attr(2, "onclick", "steal()")
        b.attr(3, "ok", "kept")
        b.close()
        b.open(4, "not a tag")
        b.text(5, "inside a substituted tag")
        b.close()
    }))

    cases.push(new Case("unicode", fn(b: Builder) {
        b.open(0, "p")
        b.attr(1, "title", "café 東京 🍜")
        b.text(2, "café 東京 🍜 & more")
        b.close()
    }))

    cases.push(new Case("empty-and-deep", fn(b: Builder) {
        b.open(0, "div")
        b.open(1, "span")
        b.close()
        b.open(2, "div")
        b.open(0, "div")
        b.open(0, "div")
        b.open(0, "div")
        b.text(0, "bottom")
        b.close()
        b.close()
        b.close()
        b.close()
        b.close()
    }))

    cases.push(new Case("boundary-ok", fn(b: Builder) {
        b.open(0, "main")
        b.boundary(1)
        b.open(0, "p")
        b.text(1, "the body rendered")
        b.close()
        b.end_boundary()
        b.close()
    }))

    cases.push(new Case("boundary-failed", fn(b: Builder) {
        b.open(0, "main")
        b.boundary(1)
        b.open(0, "p")
        b.text(1, "half-written when it panicked")
        // no close: the panic arrived mid-element
        b.fail_boundary("divide by zero")
        b.open(0, "p")
        b.attr(1, "class", "error")
        b.text(2, "Something went wrong.")
        b.close()
        b.end_boundary()
        b.close()
    }))

    return move cases
}

/// A component whose whole render is one case body, so a `fn(Builder)` can go
/// through the ordinary render cycle instead of a second one written for tests.
pub class Sheet extends Component {
    pub body: fn(Builder) = fn(b: Builder) {}
    pub fn init() {}
    pub override fn render(b: Builder) { self.body(b) }
}


fn render(probe: Case, fold: bool) -> string {
    let sheet: Sheet = new Sheet()
    sheet.body = probe.body
    let b: Builder = new Builder()
    b.fold = fold
    b.render_root(sheet)
    let writer: Serializer = new Serializer()
    return writer.page(b)
}

fn main() {
    var cases: List<Case> = html_cases()
    var folded_shorter: int = 0
    var identical: int = 0
    for probe: Case in cases {
        let sheet: Sheet = new Sheet()
        sheet.body = probe.body
        let b: Builder = new Builder()
        b.render_root(sheet)
        let writer: Serializer = new Serializer()
        let html: string = writer.page(b)

        io.println("== {probe.name}")
        io.println(html)
        io.println("   balanced: {b.balanced()}")
        for fault: string in b.all_faults() { io.println("   builder: {fault}") }
        for fault: string in writer.faults { io.println("   serializer: {fault}") }

        // Check 2, on this case: the folded walk and the unfolded walk must
        // produce the same bytes. A folding bug that emits valid but DIFFERENT
        // html is the silent one — nothing else here would see it.
        let unfolded: string = render(probe, false)
        if unfolded == html {
            identical += 1
        } else {
            io.println("   FOLD MISMATCH")
            io.println("   folded:   {html}")
            io.println("   unfolded: {unfolded}")
        }
        let folded_frames: int = frame_count(probe, true)
        let walked_frames: int = frame_count(probe, false)
        if folded_frames < walked_frames { folded_shorter += 1 }
    }
    io.println("== summary")
    io.println("cases: {cases.len()}, folded == unfolded: {identical}")
    io.println("cases where folding collapsed frames: {folded_shorter}")
}

fn frame_count(probe: Case, fold: bool) -> int {
    let sheet: Sheet = new Sheet()
    sheet.body = probe.body
    let b: Builder = new Builder()
    b.fold = fold
    b.render_root(sheet)
    return b.frames.len()
}
