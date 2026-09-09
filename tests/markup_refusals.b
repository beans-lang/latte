// Every refusal latte-bx's markup compiler makes.
//
// Most of what latte-bx refuses is a security control, not a diagnostic:
// interpolation inside a `<script>`, a literal `on*` attribute, a
// `javascript:` URL, a raw-text body that closes its own element. Each is
// refused *here*, at markup-compile time, precisely because the runtime
// cannot see it: `latte.Builder` substitutes or drops these at render time,
// and **a folded constant subtree never passes through a Builder**. Every
// row below is therefore a case where accepting it would make the folded arm
// and the unfolded arm of one subtree say different things — invisible until
// a user reports it.
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
// file checks is latte-bx's half — section 15: that the assertion function is
// emitted once per distinct component tag, from every shape a component tag can
// be written in. beansc can only refuse a tag latte-bx reported, so a tag that
// never reaches `note_component` is a tag whose type nothing checks.
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

    /// Every upcast assertion the file compiles to, in order.
    ///
    /// This is the half of "a `<Tag>` that is not a Component" that belongs to
    /// latte-bx. beansc answers the other half — see the header, and the
    /// `component-type` leg in `test.sh` — but beansc can only answer it about
    /// tags latte-bx actually reported, so "which tags reach `note_component`"
    /// is a question only this file can ask, on both backends, against a
    /// golden.
    fn assertions(label: string, decls: string, markup: string) {
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
        var found: int = 0
        for line: string in compiled.source.split("\n") {
            if !line.starts_with("fn _latte_component_") { continue }
            found = found + 1
            io.println("  {line}")
        }
        if found == 0 { io.println("  (no component tag, so no assertion)") }
    }

    fn heading(text: string) {
        io.println("")
        io.println("======== {text} ========")
    }

    // ================================================================ SECTION 1
    //
    // **Interpolation inside `<script>` and `<style>`.** Refused at compile
    // time, because the compiler knows the tag: the serializer escapes for
    // HTML *text*, and HTML escaping inside a script is not a defence —
    // `</script>` closes the element from inside a JavaScript string and
    // `&lt;` does not help. Every `$` form is refused, not only the one an
    // issue would have shown.

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

        // `a$b` IS a transition. The classifier never looks at the byte
        // before the `$`, only the one after it, so a JavaScript identifier
        // holding a dollar is refused here and is written `a$$b`.
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
    // **A literal `on*` attribute.** Refused at compile time: handlers exist
    // only as ids, and the client never evaluates a string.
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
        // A nested string holding an unmatched brace. The emitter has a
        // refusal for it — "with `"{"` around it the result does not read as
        // one Beans string" — and **nothing can reach it**: the markup-level
        // `$( )` and `{ }` scanners refuse the same shapes first, and their
        // message is the better one because it names what the author typed.
        // Deleting the emitter's branch leaves this golden unchanged; that is
        // recorded in bx/emit.b beside the branch, and it is why the branch is
        // kept rather than removed.
        self.refused("a nested string holding an unmatched brace, in a $( )", r#"pub fn f(s: string) -> string { return s }"#,
                     r#"<p>$(self.f("{"))</p>"#)
        self.refused("the same brace in an attribute expression", r#"pub fn f(s: string) -> string { return s }"#,
                     r#"<div class={self.f("{")}>x</div>"#)

        self.accepted("the same expression on one line", r#"pub a: int = 0; pub c: int = 0"#,
                      r#"<p>$(self.a + self.c)</p>"#)
        self.accepted("a multi-line handler — code, not a string", r#"pub n: int = 0"#,
                      lines([r#"<div on:click={fn(e: MouseEvent) {"#, r#"    self.n += 1"#, r#"}}>x</div>"#]))
        self.accepted("a nested string with the brace escaped", r#"pub fn f(s: string) -> string { return s }"#,
                      r#"<p>$(self.f("\{"))</p>"#)
        // A closing brace, a raw string and an index all survive the round trip
        // into `"{ … }"`, and beansc lexes every one of them. These are the
        // cases the refusal above must NOT fire on.
        self.accepted("a closing brace inside a nested string", r#"pub fn f(s: string) -> string { return s }"#,
                      r#"<p>$(self.f("}"))</p>"#)
        self.accepted("a raw string inside the interpolation", r#"pub fn f(s: string) -> string { return s }"#,
                      r##"<p>$(self.f(r#"}"#))</p>"##)
        self.accepted("an indexed chain", r#"pub rows: List<string> = []"#, r#"<p>$self.rows[0]</p>"#)
        self.accepted("a called chain", r#"pub rows: List<string> = []"#, r#"<p>$self.rows.len()</p>"#)
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
    // **A literal URL with a refused scheme.** `href`, `src`, `action`,
    // `formaction`, `poster` and `data` pass a scheme allowlist: http, https,
    // mailto, tel, relative. `javascript:` and `data:` are replaced with an
    // inert value and logged.
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

    // ================================================================ SECTION 9
    //
    // **Markup that binds `b`, or a `_latte_` name.** The generated render
    // writes every call on a Builder named `b`, and it binds the author's code
    // into the same scope. `$for b in self.books` would rebind it, and
    // `b.region(0, …)` would silently become a call on a book — nothing about
    // which reads as wrong, which is why it is refused rather than documented.
    // Every other name latte-bx binds carries the `_latte_` prefix, and that
    // prefix is refused too, so `b` is the only word this costs anyone.
    //
    // `check_code` guards twenty sites, and every one of them is below. A code
    // site that grows without the guard is a hole with no other alarm on it.

    fn reserved_names() {
        self.heading("markup that binds b, or a _latte_ name")
        self.refused("a $for header — the case that matters", r#"pub books: List<int> = []"#,
                     r#"$for b in self.books { <p>x</p> }"#)
        self.refused("a lone interpolated expression", "", r#"$b"#)
        self.refused("an expression merged with the text beside it", "", r#"<p>hi $b</p>"#)
        self.refused("$html", "", r#"$html(b)"#)
        self.refused("a $\{ \} statement block", "", r#"${ let b: int = 1 }"#)
        self.refused("an attribute expression", "", r#"<div class={b}>x</div>"#)
        self.refused("an event handler", "", r#"<div on:click={fn(e: MouseEvent) { b.close() }}>x</div>"#)
        self.refused("attrs= splat", "", r#"<div attrs={b}>x</div>"#)
        self.refused("ref= on an element", "", r#"<input ref={b} />"#)
        self.refused("a bind: place", "", r#"<input bind:value={b} />"#)
        self.refused("ref= on a component tag", "", r#"<Hint ref={b} />"#)
        self.refused("a component parameter", "", r#"<Hint label={b} />"#)
        self.refused("an $if condition", "", r#"$if b { <p>x</p> }"#)
        self.refused("an else-if condition", r#"pub on: bool = false"#,
                     r#"$if self.on { <p>x</p> } else if b { <p>y</p> }"#)
        self.refused("a key= expression", r#"pub rows: List<int> = []"#,
                     r#"$for row: int in self.rows { <li key={b}>x</li> }"#)
        self.refused("a $match subject", "", r#"$match b { _ => { <p>x</p> } }"#)
        self.refused("a $match pattern", r#"pub v: Option<int> = none"#,
                     r#"$match self.v { some(b) => { <p>x</p> } none => { <p>y</p> } }"#)
        self.refused("a $slot expression", "", r#"$slot(b)"#)
        self.refused("a $slot argument", "", r#"<Hint>$slot:row as b</Hint>"#)
        self.refused("a $slot parameter name", "",
                     r#"<Hint>$slot:row as b: int { <p>x</p> }</Hint>"#)
        self.refused("a $slot parameter type", "",
                     r#"<Hint>$slot:row as v: b { <p>x</p> }</Hint>"#)

        self.refused("_latte_row_0, the loop index latte-bx binds", r#"pub rows: List<int> = []"#,
                     r#"$for _latte_row_0 in self.rows { <p>x</p> }"#)
        self.refused("_latte_c, the component setter", "", r#"${ let _latte_c: int = 1 }"#)
        self.refused("_latte_inner, the fragment builder", "", r#"<div class={_latte_inner}>x</div>"#)
        self.refused("any other _latte_ name", "", r#"$_latte_anything"#)

        // The controls. Only a **bare** `b` is refused, and only a `_latte_`
        // name that is not a member: both predicates step over a name that
        // follows a dot, so a field of your own called either is untouched.
        self.accepted("self.b is a field, not the Builder", r#"pub b: int = 0"#, r#"$self.b"#)
        self.accepted("self._latte_x is a member name", r#"pub _latte_x: int = 0"#, r#"$self._latte_x"#)
        self.accepted("a longer name that starts with b", r#"pub books: List<int> = []"#,
                      r#"$for bx in self.books { <p>x</p> }"#)
        self.accepted("b inside a string or a comment is not a binding", "",
                      r#"<p>$(self.title("b") /* b */)</p>"#)
    }

    // =============================================================== SECTION 10
    //
    // **`key=` where the differ cannot use it.** A key names the identity of
    // one row so a reorder is a move instead of a rewrite. It is hoisted off a
    // **direct child of a `$for` body**; anywhere else it names nothing, and
    // silently emitting an attribute called `key` into the page would be the
    // worst of both.

    fn key_placement() {
        self.heading("key= away from a $for body's direct child")
        self.refused("at the top level", r#"pub id: int = 0"#, r#"<li key={self.id}>x</li>"#)
        self.refused("on a grandchild of the body", r#"pub rows: List<int> = []"#,
                     r#"$for row: int in self.rows { <ul><li key={row}>x</li></ul> }"#)
        self.refused("on a component tag", r#"pub id: int = 0"#, r#"<Hint key={self.id} />"#)
        self.refused("inside an $if, not a $for", r#"pub on: bool = false; pub id: int = 0"#,
                     r#"$if self.on { <li key={self.id}>x</li> }"#)
        self.refused("two keys in one $for body", r#"pub rows: List<int> = []"#,
                     r#"$for row: int in self.rows { <li key={row}>a</li><li key={row}>b</li> }"#)
        self.refused("key with no expression", "", r#"<li key="1">x</li>"#)

        self.accepted("on a direct child of a $for body", r#"pub rows: List<int> = []"#,
                      r#"$for row: int in self.rows { <li key={row}>x</li> }"#)
        self.accepted("a keyless $for is indexed instead", r#"pub rows: List<int> = []"#,
                      r#"$for row: int in self.rows { <li>x</li> }"#)
    }

    // =============================================================== SECTION 11
    //
    // **`ref=` on a component tag is NOT refused.** Every attribute-position
    // call needs `in_attributes`, only `open()` sets it, and a component tag
    // opens no element — so a `Reference` there has no spelling any emission
    // could reach. The setup closure assigns instead.
    //
    // This section is a **control**, and it is here so that reinstating the
    // refusal fails the suite. The emission is printed because what it compiles
    // to is the whole point: the concrete type, no downcast, and no sequence
    // number of its own.

    fn component_ref() {
        self.heading("ref= on a component tag is an assignment")
        self.accepted_showing("ref= on a component tag, written first",
                              r#"pub panel: Option<Hint> = none; pub label: string = """#,
                              r#"<Hint ref={self.panel} label={self.label} />"#)
        self.accepted_showing("ref= on an element is still a Reference sink",
                              r#"pub box: Reference = new Reference()"#,
                              r#"<input ref={self.box} name="boxed" />"#)
        self.refused("ref= still needs a place, not a call", "", r#"<Hint ref={self.find()} />"#)
        self.refused("ref= still needs an expression", "", r#"<Hint ref="x" />"#)
    }

    // =============================================================== SECTION 12
    //
    // **A `<beans>` import that collides with the generated one.** Every
    // generated file opens with `import {Builder, Callback, Component,
    // FocusEvent, InputEvent, KeyboardEvent, MouseEvent, Reference,
    // SubmitEvent} from latte`. An author who imports one of those names again
    // gets "already declared" in a file they did not write, about a line they
    // did not type. Refused where the line they did type is.

    fn import_collisions() {
        self.heading("a <beans> import that collides with the generated one")
        self.refused_file("Builder, imported again", lines([
            r#"<beans>"#,
            r#"package pages"#,
            r#"import {Builder} from latte"#,
            r#"pub partial class Refusal extends Component { pub fn init() {} }"#,
            r#"</beans>"#,
            r#"<p>x</p>"#]))
        self.refused_file("two of them at once", lines([
            r#"<beans>"#,
            r#"package pages"#,
            r#"import {MouseEvent, InputEvent} from latte"#,
            r#"pub partial class Refusal extends Component { pub fn init() {} }"#,
            r#"</beans>"#,
            r#"<p>x</p>"#]))
        self.refused_file("Component, which the class extends", lines([
            r#"<beans>"#,
            r#"package pages"#,
            r#"import {Component} from latte"#,
            r#"pub partial class Refusal extends Component { pub fn init() {} }"#,
            r#"</beans>"#,
            r#"<p>x</p>"#]))

        self.accepted_file("a latte name the generated line does not bind", lines([
            r#"<beans>"#,
            r#"package pages"#,
            r#"import {Serializer} from latte"#,
            r#"pub partial class Refusal extends Component { pub fn init() {} }"#,
            r#"</beans>"#,
            r#"<p>x</p>"#]))
        self.accepted_file("the same name under an alias binds a different one", lines([
            r#"<beans>"#,
            r#"package pages"#,
            r#"import {Component as Base} from latte"#,
            r#"pub partial class Refusal extends Component { pub fn init() {} }"#,
            r#"</beans>"#,
            r#"<p>x</p>"#]))
        self.accepted_file("the same name from somewhere else is not a collision here", lines([
            r#"<beans>"#,
            r#"package pages"#,
            r#"import {Builder} from std.fmt"#,
            r#"pub partial class Refusal extends Component { pub fn init() {} }"#,
            r#"</beans>"#,
            r#"<p>x</p>"#]))
    }

    // =============================================================== SECTION 13
    //
    // **The `<beans>` block itself.** One per file, all lowercase, at the top
    // level, declaring the partial class the file's name calls for.

    fn beans_block() {
        self.heading("the <beans> block")
        self.refused_file("no block at all", r#"<p>x</p>"#)
        self.refused_file("an empty file", "")
        self.refused_file("a block declaring no partial class", lines([
            r#"<beans>"#,
            r#"package pages"#,
            r#"</beans>"#,
            r#"<p>x</p>"#]))
        self.refused_file("a block declaring the wrong class", lines([
            r#"<beans>"#,
            r#"package pages"#,
            r#"pub partial class Other extends Component { pub fn init() {} }"#,
            r#"</beans>"#,
            r#"<p>x</p>"#]))
        self.refused_file("capitalised", lines([
            r#"<Beans>"#,
            r#"package pages"#,
            r#"</Beans>"#,
            r#"<p>x</p>"#]))
        self.refused_file("a second block", lines([
            r#"<beans>"#,
            r#"package pages"#,
            r#"pub partial class Refusal extends Component { pub fn init() {} }"#,
            r#"</beans>"#,
            r#"<beans>"#,
            r#"package pages"#,
            r#"</beans>"#]))
        self.refused_file("attributes on the block", lines([
            r#"<beans lang="beans">"#,
            r#"package pages"#,
            r#"</beans>"#]))
        self.refused_file("never closed", lines([
            r#"<beans>"#,
            r#"package pages"#]))
        self.refused_file("a second block, written inside a tag", lines([
            r#"<beans>"#,
            r#"package pages"#,
            r#"pub partial class Refusal extends Component { pub fn init() {} }"#,
            r#"</beans>"#,
            r#"<div><beans>package other</beans></div>"#]))
        // The only block in the file, written inside a tag. This was **silently
        // hoisted out** until the parser learned its nesting depth: the Beans
        // came through at the top of the generated file and the <div> rendered
        // empty. The emitter has carried a message for the shape all along and
        // could never reach it, because parse_beans lifts the block into
        // Document.beans and never puts a node in the tree.
        self.refused_file("the only block, written inside a tag", lines([
            r#"<div>"#,
            r#"  <beans>"#,
            r#"package pages"#,
            r#"pub partial class Refusal extends Component { pub fn init() {} }"#,
            r#"  </beans>"#,
            r#"  x"#,
            r#"</div>"#]))
        self.refused_file("the only block, written inside a $if body", lines([
            r#"$if true {"#,
            r#"  <beans>"#,
            r#"package pages"#,
            r#"pub partial class Refusal extends Component { pub fn init() {} }"#,
            r#"  </beans>"#,
            r#"}"#]))
        self.refused_file("no package, and no directory to take one from", lines([
            r#"<beans>"#,
            r#"pub partial class Refusal extends Component { pub fn init() {} }"#,
            r#"</beans>"#,
            r#"<p>x</p>"#]))
        self.refused_file("a generic component may not spell its type parameter", lines([
            r#"<beans>"#,
            r#"package pages"#,
            r#"pub partial class Refusal<T> extends Component { pub rows: List<T> = []; pub fn init() {} }"#,
            r#"</beans>"#,
            r#"$for row: T in self.rows { <p>x</p> }"#]))

        self.accepted_file("a generic component that lets the element type be inferred", lines([
            r#"<beans>"#,
            r#"package pages"#,
            r#"pub partial class Refusal<T> extends Component { pub rows: List<T> = []; pub fn init() {} }"#,
            r#"</beans>"#,
            r#"$for row in self.rows { <p>x</p> }"#]))
        self.accepted_file("a comment mentioning partial class is not a declaration", lines([
            r#"<beans>"#,
            r#"package pages"#,
            r#"// partial class Ghost — a comment, not a declaration"#,
            r#"pub partial class Refusal extends Component { pub fn init() {} }"#,
            r#"</beans>"#,
            r#"<p>x</p>"#]))
    }

    // =============================================================== SECTION 14
    //
    // **`live`, and every `bind:` shape.** `live` is the signal tier's own
    // attribute: marking a subtree live before signals exist would compile to
    // an ordinary render that never updates the way the attribute promises,
    // so it is refused rather than accepted and ignored. `bind:value` on a
    // `<select>` is refused for a different reason: a select's value is not
    // an attribute, it is which `<option>` carries `selected`, so a binding
    // there would set nothing and look right.

    fn bindings_and_live() {
        self.heading("live, and the bind: shapes")
        self.refused("live on its own", r#"pub ticks: int = 0"#, r#"<span live>$self.ticks</span>"#)
        self.refused("live with a value", "", r#"<div live="yes">y</div>"#)
        self.refused("bind:value on a <select>", r#"pub choice: string = """#,
                     r#"<select bind:value={self.choice}><option>a</option></select>"#)
        self.refused("bind:value on anything else", r#"pub note: string = """#,
                     r#"<p bind:value={self.note}>x</p>"#)
        self.refused("bind:checked away from an <input>", r#"pub on: bool = false"#,
                     r#"<select bind:checked={self.on}></select>"#)
        self.refused("bind:checked with a conversion", r#"pub on: bool = false"#,
                     r#"<input bind:checked.int={self.on} />"#)
        self.refused("a bind: target latte does not have", r#"pub note: string = """#,
                     r#"<input bind:text={self.note} />"#)
        self.refused("a conversion latte does not have", r#"pub note: string = """#,
                     r#"<input bind:value.date={self.note} />"#)
        self.refused("bind: with no place", "", r#"<input bind:value />"#)
        self.refused("a bind: place that is a call", "", r#"<input bind:value={self.get()} />"#)
        self.refused("bind: on a component tag", r#"pub note: string = """#,
                     r#"<Hint bind:value={self.note} />"#)
        self.refused("a <textarea> that binds AND has children", r#"pub note: string = """#,
                     r#"<textarea bind:value={self.note}>extra</textarea>"#)

        self.accepted("bind:value on an <input>", r#"pub note: string = """#,
                      r#"<input bind:value={self.note} />"#)
        self.accepted("bind:value on a <textarea>", r#"pub note: string = """#,
                      r#"<textarea bind:value={self.note}></textarea>"#)
        self.accepted("the three conversions", r#"pub n: int = 0; pub r: float = 0.0; pub f: bool = false"#,
                      r#"<input bind:value.int={self.n} /><input bind:value.float={self.r} /><input bind:value.bool={self.f} />"#)
        self.accepted("bind:checked on an <input>", r#"pub on: bool = false"#,
                      r#"<input type="checkbox" bind:checked={self.on} />"#)
        self.accepted("a select with an explicit selected= and on:change",
                      r#"pub choice: string = """#,
                      r#"<select on:change={fn(e: InputEvent) { self.choice = e.value }}><option selected={self.choice == "a"}>a</option></select>"#)
    }

    // =============================================================== SECTION 15
    //
    // **latte-bx's half of "a `<Tag>` that is not a Component".** The refusal
    // itself is beansc's, against the free function emitted here; `test.sh`'s
    // `component-type` leg runs it. But beansc can only refuse a tag latte-bx
    // *reported*, so a tag that never reaches `note_component` is a tag whose
    // type nothing checks — a silent hole in a security-shaped rule, and
    // exactly the shape of failure the header calls a refusal that never runs.
    //
    // So: every shape a component tag can be written in, and the assertions the
    // file compiles to. One per DISTINCT tag — `<Hint/><Hint/>` is one, because
    // two would be a duplicate definition and beansc would answer about that
    // instead. A file with no component tag emits none, which is why the block
    // is guarded rather than always written.

    fn component_assertions() {
        self.heading("the upcast assertion, per distinct component tag")
        self.assertions("a bare component tag", "", r#"<Hint />"#)
        self.assertions("with parameters", "", r#"<Hint label="a" count={1} />"#)
        self.assertions("with children", "", r#"<Hint><p>x</p></Hint>"#)
        self.assertions("with a named slot", "",
                        r#"<Hint>$slot:extra as n: int { <b>$n</b> }</Hint>"#)
        self.assertions("the same tag twice", "", r#"<Hint /><Hint />"#)
        self.assertions("three different tags", "", r#"<Hint /><Panel /><Card />"#)
        self.assertions("a dotted tag", "", r#"<ui.Table />"#)
        self.assertions("inside a $if arm", r#"pub open: bool = true"#,
                        r#"$if self.open { <Hint /> } else { <Panel /> }"#)
        self.assertions("inside a $for body", r#"pub rows: List<int> = []"#,
                        r#"$for row in self.rows { <Hint /> }"#)
        self.assertions("inside a $match arm", r#"pub n: int = 0"#,
                        r#"$match self.n { 0 => { <Hint /> } _ => { <Panel /> } }"#)
        self.assertions("nested inside another component's children", "",
                        r#"<Hint><Panel><Card /></Panel></Hint>"#)
        self.assertions("inside a named slot's body", "",
                        r#"<Hint>$slot:extra as n: int { <Panel /> }</Hint>"#)
        self.assertions("no component tag at all", "", r#"<p>plain</p>"#)
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
    suite.reserved_names()
    suite.key_placement()
    suite.component_ref()
    suite.import_collisions()
    suite.beans_block()
    suite.bindings_and_live()
    suite.component_assertions()

    io.println("")
    io.println("{suite.refusals} refusal(s) fired, {suite.controls} control(s) compiled")
    if suite.failures == 0 {
        io.println("======== markup refusals: every check passed ========")
    } else {
        io.println("======== markup refusals: {suite.failures} check(s) FAILED ========")
    }
}
