// The two things a `.bx` file can compile into, and what differs between them.
package bx

/// What a `.bx` file is compiled for.
///
/// Latte draws interfaces two ways. `html` produces a DOM component — the
/// server-rendered pages and the circuit have always meant this, and it is the
/// default so that no existing file changes meaning. `canvas` produces a
/// component for the browser runtime, which draws its own controls.
///
/// **The two are not two dialects.** One lexer, one AST, one parser, one set
/// of source positions, one diagnostic type. A `$for` is a `$for`, `bind:` is
/// `bind:`, and an expression's boundaries are found the same way. What a
/// target decides is what a *tag* means, what an attribute may be, which
/// events exist, and which forms have nothing to compile into — and each of
/// those is a method on `TargetRules` rather than a branch inside the parser.
pub enum Target {
    html
    canvas

    pub fn name() -> string {
        return match self { html => "html", canvas => "canvas" }
    }

    pub static fn of(word: string) -> Option<Target> {
        if word == "html" { return some(Target.html) }
        if word == "canvas" { return some(Target.canvas) }
        return none
    }

    pub fn rules() -> TargetRules {
        match self {
            html => { let html_rules: TargetRules = new HtmlRules(); return html_rules }
            canvas => { let canvas_rules: TargetRules = new CanvasRules(); return canvas_rules }
        }
    }
}

/// Everything about a `.bx` file that depends on what it compiles into.
///
/// Every method answers for one target. A refusal comes back as a message
/// rather than a boolean wherever the message is the useful part: a reader
/// whose `$html` was refused needs to know there is nothing for it to write
/// into, not that a flag was false.
pub interface TargetRules {
    fn target() -> Target

    // ---- tags ----

    /// Whether a capitalised tag names a component the author wrote, rather
    /// than something the target has of its own. HTML has no tags of its own
    /// with a capital letter, so there every one is a component; a canvas
    /// target's controls are capitalised too and are not.
    fn names_a_component(tag: string) -> bool

    /// A tag that closes itself and takes no children: `<br>`, `<img>`.
    fn is_void_element(tag: string) -> bool
    /// A tag whose body is text rather than markup: `<script>`, `<style>`.
    fn is_raw_text_element(tag: string) -> bool
    /// A tag whose whitespace is significant: `<pre>`, `<textarea>`.
    fn preserves_whitespace(tag: string) -> bool
    /// Empty when the tag is one this target has; otherwise the refusal.
    fn tag_refusal(tag: string) -> string

    // ---- forms ----

    /// Empty when `<!DOCTYPE ...>` belongs here; otherwise the refusal.
    fn doctype_refusal(text: string) -> string
    /// Empty when `$html(...)` belongs here; otherwise the refusal.
    fn raw_html_refusal() -> string
    /// Empty when `attrs={...}` belongs here; otherwise the refusal.
    fn splat_refusal() -> string
    /// Empty when `preserve` belongs here; otherwise the refusal.
    fn preserve_refusal() -> string
    /// Empty when `live` belongs here; otherwise the refusal.
    fn live_refusal() -> string
    /// What may start an attribute name before a colon.
    fn namespace_refusal(name: string) -> string

    // ---- attributes ----

    /// Empty when the attribute is one `tag` takes; otherwise the refusal.
    ///
    /// The html target passes an unknown attribute through — HTML is open and
    /// an author may write `data-`, `aria-` or a framework's own. The canvas
    /// target refuses one: its controls have a closed set of properties, so a
    /// misspelling is a mistake and not an extension point, and a silent no-op
    /// is the most common way an interface ends up not matching the markup
    /// that describes it.
    fn attribute_refusal(tag: string, name: string) -> string
    /// Character references resolved on the way in, because the value is
    /// re-escaped on the way out and resolving twice would double-encode.
    /// The canvas target has no escaping and leaves a value alone.
    fn resolve_literal(value: string) -> string
    /// Empty when `ref=` belongs on this tag; otherwise the refusal.
    fn ref_refusal(tag: string, component: bool) -> string
    /// Empty when the name is fine; otherwise the refusal. This is where the
    /// html target refuses `onclick=` and everything shaped like it.
    fn inline_handler_refusal(name: string) -> string

    // ---- events ----

    fn is_event(event: string) -> bool
    fn event_list() -> string
    fn nearest_event(event: string) -> string
    /// What an `on:<event>` handler's parameter is declared as.
    fn event_family(event: string) -> string
    /// How an event reaches the Builder. Empty when the Builder takes the
    /// event by name rather than through a method of its own.
    fn event_method(event: string) -> string

    // ---- bindings ----

    /// Empty when `bind:checked` works on this tag; otherwise the refusal.
    fn bind_state_refusal(tag: string) -> string
    /// Empty when `bind:value` works on this tag; otherwise the refusal.
    fn bind_value_refusal(tag: string) -> string
}
