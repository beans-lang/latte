// PLAN.md gate 4, the last clause: **"and every refusal."**
//
// Most of what latte-bx refuses is a security control, not a diagnostic. The
// list in PLAN.md's threat table — interpolation inside a `<script>`, a literal
// `on*` attribute, a `javascript:` URL, a raw-text body that closes its own
// element — is refused *here*, at markup-compile time, precisely because the
// runtime cannot see it: `latte.Builder` substitutes or drops these at render
// time, and **a folded constant subtree never passes through a Builder**. Every
// row below is therefore a case where accepting it would make the folded arm
// and the unfolded arm of one subtree say different things, which is the one
// failure PLAN.md calls out as invisible until a user reports it.
//
// A refusal nobody runs is a refusal nobody has reason to believe in. Until
// this file existed, fourteen of them had never been executed once.
//
// **How a case is written.** `refused(...)` compiles a `.bx` file that must not
// compile and prints the diagnostic verbatim, so the golden holds the exact
// message. If the refusal is deleted the file compiles, `FAIL it was ACCEPTED`
// goes into the output and the failure count moves — which is the property that
// makes this suite bite rather than merely pass. Every family also carries an
// `accepted(...)` control: a refusal that fires on the legal shape next door is
// as broken as one that never fires, and only the control can tell those apart.
//
// **The wrapper is a fixed four lines**, so a diagnostic's line number reads
// directly against the markup echoed under each label:
//
//     1  <beans>
//     2  package pages
//     3  pub partial class Refusal extends Component { <decls> pub fn init() {} }
//     4  </beans>
//     5  <the markup starts here>
//
// **One refusal is not latte-bx's and is not here.** "A `<Tag>` that is not a
// Component" is answered by *beansc*, against the assertion function latte-bx
// emits (`fn _latte_component_<stem>_<Tag>(value: Tag) -> Component`). Proving
// it needs the real compiler, and nothing in the stdlib reads an environment
// variable, so a suite cannot find `beansc` to run it. `test.sh` has a
// `component-type` leg for it, where `$BEANSC` is already resolved. What this
// file checks is latte-bx's half: that the assertion function is emitted, for
// every distinct component tag, once.
package main

import std.io
import latte.bx

/// A multi-line fixture, one raw string per line.
///
/// Written this way rather than as one `"...\n..."` because a `{` in an
/// ordinary Beans string opens an interpolation, and markup is mostly braces.
fn lines(parts: List<string>) -> string {
    return parts.join("\n")
}

pub class Suite {
    pub failures: int = 0
    /// How many cases were refused as intended, and how many controls compiled.
    pub refusals: int = 0
    pub controls: int = 0
    pub fn init() {}

    // ------------------------------------------------------------ the harness

    fn options() -> bx.Options {
        return new bx.Options()
    }

    /// The fixed four-line `<beans>` wrapper. See the header for why.
    fn wrap(decls: string, markup: string) -> string {
        return "<beans>\npackage pages\npub partial class Refusal extends Component \{ {decls} pub fn init() \{\} \}\n</beans>\n{markup}"
    }

    fn echo(source: string) {
        for line: string in source.split("\n") {
            io.println("  | {line}")
        }
    }

    fn show_diags(compiled: bx.Compiled) {
        for line: string in compiled.report("refusal.bx").split("\n") {
            io.println("  {line}")
        }
    }

    /// Markup that must be refused.
    fn refused(label: string, decls: string, markup: string) {
        io.println("refused: {label}")
        self.echo(markup)
        let compiled: bx.Compiled = bx.compile_source(
            self.wrap(decls, markup), "refusal.bx", self.options())
        if compiled.is_ok() {
            self.failures = self.failures + 1
            io.println("  FAIL it was ACCEPTED — the refusal did not fire")
            return
        }
        self.refusals = self.refusals + 1
        self.show_diags(compiled)
    }

    /// A whole `.bx` file that must be refused, for the cases where the
    /// `<beans>` block itself is what is wrong.
    fn refused_file(label: string, source: string) {
        io.println("refused: {label}")
        self.echo(source)
        let compiled: bx.Compiled = bx.compile_source(source, "refusal.bx", self.options())
        if compiled.is_ok() {
            self.failures = self.failures + 1
            io.println("  FAIL it was ACCEPTED — the refusal did not fire")
            return
        }
        self.refusals = self.refusals + 1
        self.show_diags(compiled)
    }

    /// The control: the nearest legal shape, which must compile.
    fn accepted(label: string, decls: string, markup: string) {
        let compiled: bx.Compiled = bx.compile_source(
            self.wrap(decls, markup), "refusal.bx", self.options())
        if !compiled.is_ok() {
            self.failures = self.failures + 1
            io.println("FAIL the control was REFUSED: {label}")
            self.echo(markup)
            self.show_diags(compiled)
            return
        }
        self.controls = self.controls + 1
        io.println("accepted: {label}")
    }

    /// A control whose emission is worth recording, because what it compiles to
    /// is the point — `ref=` on a component tag most of all.
    fn accepted_showing(label: string, decls: string, markup: string) {
        let compiled: bx.Compiled = bx.compile_source(
            self.wrap(decls, markup), "refusal.bx", self.options())
        if !compiled.is_ok() {
            self.failures = self.failures + 1
            io.println("FAIL the control was REFUSED: {label}")
            self.echo(markup)
            self.show_diags(compiled)
            return
        }
        self.controls = self.controls + 1
        io.println("accepted: {label}")
        self.echo(markup)
        var inside: bool = false
        for line: string in compiled.source.split("\n") {
            if line.starts_with("partial class ") { inside = true }
            if inside { io.println("  {line}") }
        }
    }

    fn accepted_file(label: string, source: string) {
        let compiled: bx.Compiled = bx.compile_source(source, "refusal.bx", self.options())
        if !compiled.is_ok() {
            self.failures = self.failures + 1
            io.println("FAIL the control was REFUSED: {label}")
            self.echo(source)
            self.show_diags(compiled)
            return
        }
        self.controls = self.controls + 1
        io.println("accepted: {label}")
    }

    fn heading(text: string) {
        io.println("")
        io.println("======== {text} ========")
    }

    // ================================================================ SECTION 1
    //
    // **Interpolation inside `<script>` and `<style>`.** PLAN.md's threat
    // table: "XSS through a raw-text element — interpolation inside <script>
    // and <style> is refused at compile time, because the compiler knows the
    // tag." The serializer escapes for HTML *text*, and HTML escaping inside a
    // script is not a defence: `</script>` closes the element from inside a
    // JavaScript string and `&lt;` does not help. Every `$` form is refused,
    // not only the one an issue would have shown.

    fn script_interpolation() {
        self.heading("interpolation inside <script> and <style>")
        self.refused("an implicit expression in a <script>", r#"pub count: int = 0"#,
                     r#"<script>let n = $self.count;</script>"#)
        self.refused("an explicit expression in a <script>", r#"pub count: int = 0"#,
                     r#"<script>let n = $(self.count + 1);</script>"#)
        self.refused("an implicit expression in a <style>", r#"pub colour: string = """#,
                     r#"<style>.a { color: $self.colour }</style>"#)
        self.refused("an explicit expression in a <style>", r#"pub colour: string = """#,
                     r#"<style>.a { color: $(self.colour) }</style>"#)
        self.refused("a $\{ \} statement block in a <script>", "",
                     r#"<script>${ let x: int = 1 }</script>"#)
        self.refused("a $if in a <script>", r#"pub on: bool = false"#,
                     r#"<script>$if self.on { let x = 1; }</script>"#)
        self.refused("a $for in a <style>", r#"pub rows: List<string> = []"#,
                     r#"<style>$for row: string in self.rows { }</style>"#)
        self.refused("$html in a <script>", r#"pub js: string = """#,
                     r#"<script>$html(self.js)</script>"#)
        self.refused("two of them in one body — both are reported", r#"pub a: int = 0"#,
                     r#"<script>let x = $self.a; let y = $self.a;</script>"#)
        self.refused("a <script> with attributes is still raw text", r#"pub a: int = 0"#,
                     r#"<script type="module" defer>let x = $self.a;</script>"#)

        // `a$b` IS a transition. The classifier never looks at the byte before
        // the `$` — PLAN.md's rule is written entirely in terms of the one
        // after it — so a JavaScript identifier holding a dollar is refused
        // here and is written `a$$b`. bx/parse.b's own comment claimed the
        // opposite until this control failed.
        self.refused("a JavaScript identifier holding a dollar", "",
                     r#"<script>let a$b = 1;</script>"#)

        // The controls. A `$` that is not a transition anywhere else is not one
        // here either, and `$$` is the escape the rest of the file has.
        self.accepted("a price, a currency and a bare $ in a <script>", "",
                      r#"<script>let cost = 5; // $5.00, US$, $ 20, and a trailing $</script>"#)
        self.accepted("a$$b is how that identifier is written", "",
                      r#"<script>let a$$b = 1;</script>"#)
        self.accepted("a JavaScript template literal's $\{ \} is not markup", "",
                      r#"<script>let s = "a" + "b";</script>"#)
        self.accepted("$$ writes one dollar in a <script>", "",
                      r#"<script>let s = "$$";</script>"#)
        self.accepted("< and braces in a <script> body", "",
                      r#"<script>if (1 < 2) { run(); }</script>"#)
        self.accepted("an ordinary <style> body", "",
                      r#"<style>.a { color: red }</style>"#)
    }

    // ================================================================ SECTION 2
    //
    // **A literal `on*` attribute.** PLAN.md: "XSS through an inline handler —
    // a literal `on*` attribute is refused at compile time. Handlers exist only
    // as ids and the client never evaluates a string."
    //
    // The predicate is the runtime's, byte for byte (`bx/html.b` mirrors
    // `frames.b`): **three bytes or more, beginning `on`, case-insensitively**.
    // That is deliberately wider than "an HTML event handler" — `on-foo` and
    // `on_dismiss` are not events and are refused anyway, because
    // `latte.Builder` drops them at run time and a folded subtree would keep
    // what the unfolded walk dropped. It also means `once` and `only` are
    // refused; that is the price of a predicate with no exceptions, and it is
    // recorded here rather than discovered.

    fn inline_handlers() {
        self.heading("a literal on* attribute")
        self.refused("onclick", "", r#"<div onclick="steal()">x</div>"#)
        self.refused("onCLICK — the predicate is case-insensitive", "",
                     r#"<div onCLICK="steal()">x</div>"#)
        self.refused("on-foo — not an event, refused all the same", "",
                     r#"<div on-foo="steal()">y</div>"#)
        self.refused("on_dismiss", "", r#"<div on_dismiss="steal()">y</div>"#)
        self.refused("onx — three bytes, no event name", "", r#"<div onx="steal()">y</div>"#)
        self.refused("onclick with no value at all", "", r#"<div onclick>y</div>"#)
        self.refused("onclick=\{ \} as an expression", r#"pub js: string = """#,
                     r#"<div onclick={self.js}>y</div>"#)
        self.refused("once — the predicate has no exceptions", "", r#"<div once="1">y</div>"#)
        self.refused("only — likewise", "", r#"<div only="1">y</div>"#)
        self.refused("onclick inside a constant run that would fold", "",
                     lines([r#"<div>"#, r#"  <i>one</i>"#, r#"  <b onclick="steal()">two</b>"#, r#"</div>"#]))

        self.accepted("on:click=\{ \} is the handler spelling", r#"pub n: int = 0"#,
                      r#"<div on:click={fn(e: MouseEvent) { self.n += 1 }}>x</div>"#)
        self.accepted("on — two bytes, so not a handler name", "", r#"<div on="1">y</div>"#)
        self.accepted("no, o, ono-like names that do not begin on", "",
                      r#"<div no="1" o="2" nope="3">y</div>"#)
    }

    // ================================================================ SECTION 3
    //
    // **A closed generic component tag.** `BLOCKERS.md` B1: reflection cannot
    // construct a closed generic, and the two backends disagree about reading
    // its fields. This refusal was dead code until this lane fixed it —
    // `is_name_byte` stops at `<`, so the old `tag.contains("<")` was a
    // question no tag could answer yes to, and `<Grid<int>>` fell through to
    // "a < inside <Grid>". These cases are what prove it fires now.

    fn closed_generics() {
        self.heading("a closed generic component tag")
        self.refused("<Grid<int>>", "", r#"<Grid<int>>x</Grid>"#)
        self.refused("<Grid<T>> — a type parameter reads the same way", "",
                     r#"<Grid<T>>x</Grid>"#)
        self.refused("a dotted component, self-closing", "", r#"<ui.Table<Order> />"#)
        self.refused("<Grid<int> /> self-closing", "", r#"<Grid<int> />"#)
        self.refused("nested angles", "", r#"<Grid<Map<string, int>> />"#)

        self.accepted("<Grid> open, which is the supported spelling", r#"pub rows: List<int> = []"#,
                      r#"<Grid rows={self.rows} />"#)
        self.accepted("a lowercase tag with an entity is not a generic", "",
                      r#"<div>a &lt; b</div>"#)
    }

    // ================================================================ SECTION 4
    //
    // **A multi-line interpolated expression.** A Beans string literal cannot
    // span lines — `"sum {a +\n b}"` is `error: string not closed before end of
    // line` — and every interpolated frame is emitted as `b.text(n, "{code}")`.
    // So a multi-line expression has **no correct emission at all**. Joining
    // the lines is the tempting fix and it is wrong: it swallows the rest of a
    // `//` comment.
    //
    // The control below is the one that says what the rule actually is. A
    // multi-line *handler* is fine — it is written as code, not into a string —
    // so the refusal is about interpolation, not about newlines.

    fn multiline_interpolation() {
        self.heading("an expression that cannot be interpolated")
        self.refused("a multi-line $( ) in text", r#"pub a: int = 0; pub c: int = 0"#,
                     lines([r#"<p>$(self.a +"#, r#"   self.c)</p>"#]))
        self.refused("a multi-line attribute expression", r#"pub on: bool = false"#,
                     lines([r#"<div class={if self.on {"#, r#"    "yes""#, r#"} else {"#, r#"    "no""#, r#"}}>x</div>"#]))
        self.refused("a multi-line key= expression", r#"pub rows: List<int> = []"#,
                     lines([r#"$for row: int in self.rows {"#, r#"  <li key={row +"#, r#"    1}>x</li>"#, r#"}"#]))
        self.refused("a bind:value place spanning lines is not even a place", r#"pub note: string = """#,
                     lines([r#"<input bind:value={self."#, r#"  note} />"#]))
        self.refused("a nested string holding an unmatched brace", r#"pub fn f(s: string) -> string { return s }"#,
                     r#"<p>$(self.f("{"))</p>"#)

        self.accepted("the same expression on one line", r#"pub a: int = 0; pub c: int = 0"#,
                      r#"<p>$(self.a + self.c)</p>"#)
        self.accepted("a multi-line handler — code, not a string", r#"pub n: int = 0"#,
                      lines([r#"<div on:click={fn(e: MouseEvent) {"#, r#"    self.n += 1"#, r#"}}>x</div>"#]))
        self.accepted("a nested string with the brace escaped", r#"pub fn f(s: string) -> string { return s }"#,
                      r#"<p>$(self.f("\{"))</p>"#)
    }

    // ================================================================ SECTION 5
    //
    // **An unsafe tag name.** `latte.Builder` substitutes `<span>` for a tag
    // name it will not write. A folded constant subtree never passes through a
    // Builder, so it would keep the name as written — the folded and unfolded
    // arms of one subtree would then render different elements. Refused here
    // instead, where it is visible.
    //
    // The lexer's tag-name bytes are wider than the safe set on purpose (`_`,
    // `.` and `:` are all legal name bytes, because `<ui.Button>` is a
    // component spelling), so every one of these parses cleanly and is refused
    // by the emitter rather than by the scanner.

    fn unsafe_tag_names() {
        self.heading("an unsafe tag name")
        self.refused("an underscore in the name", "", r#"<a_b>x</a_b>"#)
        self.refused("a dot in a non-component name", "", r#"<x.y>z</x.y>"#)
        self.refused("a colon in the name", "", r#"<p:q>z</p:q>"#)
        self.refused("a name starting with an underscore", "", r#"<_x>z</_x>"#)
        self.refused("inside a constant run that would fold", "",
                     lines([r#"<div>"#, r#"  <i>one</i>"#, r#"  <a_b>two</a_b>"#, r#"</div>"#]))
        self.refused("a self-closing unsafe tag", "", r#"<a_b />"#)

        self.accepted("a custom element with a hyphen", "", r#"<my-widget>x</my-widget>"#)
        self.accepted("a heading with a digit", "", r#"<h1>x</h1>"#)
        self.accepted("a trailing hyphen is legal HTML", "", r#"<x->z</x->"#)
    }

    // ================================================================ SECTION 6
    //
    // **An unsafe attribute name.** This one is refused *twice* and reached
    // once, and saying so is the point of the section.
    //
    // The scanner will not build a name outside `[a-zA-Z_][a-zA-Z0-9_:.-]*`,
    // and `attribute_name_is_safe` refuses exactly the complement of that set,
    // so **no markup can reach `Emitter.check_element`'s attribute-name
    // branch**. It stays as defence in depth for the day the scanner widens,
    // and `tests/markup.b` proves the predicate itself still agrees with
    // `frames.b`'s over a corpus that includes the unreachable names. What the
    // author actually meets is the scanner's message, and these are those.

    fn unsafe_attribute_names() {
        self.heading("an attribute name latte will not write")
        self.refused("a name starting with a dot", "", r#"<div .x="1">y</div>"#)
        self.refused("a name starting with a digit", "", r#"<div 1x="1">y</div>"#)
        self.refused("a quoted name", "", r#"<div "x"="1">y</div>"#)
        self.refused("an = with no name in front of it", "", r#"<div ="1">y</div>"#)
        self.refused("a name with no value after its =", "", r#"<div x=>y</div>"#)
        self.refused("a value that is neither a string nor an expression", "",
                     r#"<div x=1>y</div>"#)

        self.refused("a namespace latte does not have", "", r#"<div a:b="2">y</div>"#)
        self.refused("a mistyped bind: is still an error, not an attribute", r#"pub note: string = """#,
                     r#"<input bnd:value={self.note} />"#)

        self.accepted("every punctuation the safe set allows", "",
                      r#"<div a.b="1" a-b="3" _x="4" x1="5">y</div>"#)
        // The three XML namespaces are ordinary attribute names, which is what
        // makes `xlink:href`'s scheme check reachable — see section 7.
        self.accepted("the XML namespaces are ordinary names", "",
                      r#"<svg xmlns:xlink="http://www.w3.org/1999/xlink"><a xlink:href="/x" xml:lang="en">y</a></svg>"#)
    }

    // ================================================================ SECTION 7
    //
    // **A literal URL with a refused scheme.** PLAN.md: "href, src, action,
    // formaction, poster and data pass a scheme allowlist: http, https,
    // mailto, tel, relative. javascript: and data: are replaced with an inert
    // value and logged."
    //
    // Replaced — at run time, inside `latte.Builder.attr`. A folded constant
    // never reaches it, so a literal one is refused here. An *expression* URL
    // is not refused: its value is not known until render, and the Builder is
    // the control for it (`tests/w2_equiv.b` and the p8 probe exercise that
    // half). The obfuscations below are the ones a browser unwinds before it
    // parses the scheme: case, leading space, and a control byte in the middle.

    fn refused_url_schemes() {
        self.heading("a literal URL with a refused scheme")
        self.refused("javascript: in an href", "", r#"<a href="javascript:alert(1)">x</a>"#)
        self.refused("data: in a src", "", r#"<img src="data:text/html,x" />"#)
        self.refused("javascript: in a form action", "",
                     r#"<form action="javascript:alert(1)"><i>x</i></form>"#)
        self.refused("javascript: in a formaction", "",
                     r#"<button formaction="javascript:alert(1)">x</button>"#)
        self.refused("javascript: in a poster", "", r#"<video poster="javascript:alert(1)"></video>"#)
        self.refused("javascript: in an object data", "", r#"<object data="javascript:alert(1)"></object>"#)
        self.refused("javascript: in an SVG xlink:href", "",
                     r#"<svg><a xlink:href="javascript:alert(1)">x</a></svg>"#)
        self.refused("mixed case is the same scheme", "", r#"<a href="JaVaScRiPt:alert(1)">x</a>"#)
        self.refused("a leading space is stripped by the browser", "",
                     r#"<a href=" javascript:alert(1)">x</a>"#)
        self.refused("a tab in the middle is stripped too", "",
                     r#"<a href="java\tscript:alert(1)">x</a>"#)
        self.refused("vbscript:", "", r#"<a href="vbscript:x">x</a>"#)
        self.refused("about:blank is not on the list either", "", r#"<a href="about:blank">x</a>"#)
        self.refused("inside a constant run that would fold", "",
                     lines([r#"<div>"#, r#"  <i>one</i>"#, r#"  <a href="javascript:alert(1)">two</a>"#, r#"</div>"#]))

        self.accepted("a relative path", "", r#"<a href="/safe/path">x</a>"#)
        self.accepted("a bare relative name", "", r#"<a href="page.html">x</a>"#)
        self.accepted("http and https, any case", "",
                      r#"<a href="http://a">x</a><img src="HTTPS://a" />"#)
        self.accepted("mailto and tel", "",
                      r#"<a href="mailto:a@b.c">x</a><a href="tel:+1">y</a>"#)
        self.accepted("a query or fragment holding a colon", "",
                      r##"<a href="?q=1:2">x</a><a href="#a:b">y</a>"##)
        self.accepted("a protocol-relative URL", "", r#"<a href="//host/x">x</a>"#)
        self.accepted("an expression href is the Builder's job, not this one",
                      r#"pub url: string = """#, r#"<a href={self.url}>x</a>"#)
    }

    // ================================================================ SECTION 8
    //
    // **A raw-text body that ends its own element.** `</script` inside a
    // JavaScript string closes the element in every browser whatever the
    // language inside thinks, and `<!--` starts a comment-like state that moves
    // where it ends. `latte.Serializer` drops such a body with a fault, so the
    // page silently loses its behaviour; latte-bx refuses it instead.
    //
    // The scanner ends the element at the first `</script>`, so the shape that
    // reaches this check is `</script` **not** followed by `>` — a space, a
    // letter, anything.

    fn raw_text_bodies() {
        self.heading("a <script> or <style> body that ends its own element")
        self.refused("</script with a space after it", "",
                     r#"<script>var s = "</script foo";</script>"#)
        self.refused("</script with a letter after it", "",
                     r#"<script>var s = "</scriptx";</script>"#)
        self.refused("a comment opener in a <script>", "",
                     r#"<script><!-- hidden --></script>"#)
        self.refused("</style with a space after it", "",
                     r#"<style>/* </style x */ .a{color:red}</style>"#)
        self.refused("a comment opener in a <style>", "", r#"<style><!-- x --></style>"#)
        self.refused("case does not help", "", r#"<script>var s = "</SCRIPT foo";</script>"#)

        self.accepted("a less-than that closes nothing", "",
                      r#"<script>if (1 < 2) { run(); }</script>"#)
        self.accepted("a closing tag for a different element", "",
                      r#"<script>var s = "</div>";</script>"#)
        self.accepted("an ordinary stylesheet", "", r#"<style>.a{color:red}</style>"#)
        self.accepted("an empty raw-text body emits no frame at all", "",
                      r#"<script src="/app.js"></script>"#)
    }
}

fn main() {
    let suite: Suite = new Suite()
    suite.script_interpolation()
    suite.inline_handlers()
    suite.closed_generics()
    suite.multiline_interpolation()
    suite.unsafe_tag_names()
    suite.unsafe_attribute_names()
    suite.refused_url_schemes()
    suite.raw_text_bodies()

    io.println("")
    io.println("{suite.refusals} refusal(s) fired, {suite.controls} control(s) compiled")
    if suite.failures == 0 {
        io.println("======== markup refusals: every check passed ========")
    } else {
        io.println("======== markup refusals: {suite.failures} check(s) FAILED ========")
    }
}
