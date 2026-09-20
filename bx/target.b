// The two things a `.bx` file can compile into, and what differs between them.
package bx

/// What a `.bx` file is compiled for. Not two dialects: one lexer, one AST,
/// one parser. A target decides only what a tag and an attribute mean.
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

/// Everything about a `.bx` file that depends on what it compiles into. A
/// refusal comes back as a message wherever the message is the useful part.
pub interface TargetRules {
    fn target() -> Target

    // ---- tags ----

    /// Whether a capitalised tag is the author's component. In HTML every one
    /// is; on the canvas the controls are capitalised too, and are not.
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

    /// Empty when `tag` takes the attribute, otherwise the refusal. HTML is
    /// open and passes one through; the canvas set is closed and refuses.
    fn attribute_refusal(tag: string, name: string) -> string
    /// Character references resolved on the way in, because the value is
    /// re-escaped on the way out. The canvas target leaves a value alone.
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
