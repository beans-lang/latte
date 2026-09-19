// What a `.bx` file means when it compiles into DOM.
package bx

/// The html target's rules.
///
/// Every answer here is HTML's own, and every one of them was already written
/// somewhere in `html.b`, `events.b` or `parse.b` — this is where they are
/// collected so the parser can ask a target rather than know the target.
/// Nothing about the behaviour changed; the generated Beans for every existing
/// `.bx` file is byte for byte what it was, which `tests/w2_equiv.b` and the
/// checked-in generated files hold it to.
pub class HtmlRules implements TargetRules {
    pub fn init() {}

    pub fn target() -> Target { return Target.html }

    pub fn names_a_component(tag: string) -> bool { return names_a_component(tag) }

    pub fn is_void_element(tag: string) -> bool { return is_void_element(tag) }
    pub fn is_raw_text_element(tag: string) -> bool { return is_raw_text_element(tag) }
    pub fn preserves_whitespace(tag: string) -> bool { return preserves_whitespace(tag) }

    /// HTML is open: an element name latte does not know is an element the
    /// browser might, and a custom element is a real thing. Nothing is refused
    /// by name here.
    pub fn tag_refusal(tag: string) -> string { return "" }

    pub fn doctype_refusal(text: string) -> string { return "" }
    pub fn raw_html_refusal() -> string { return "" }
    pub fn splat_refusal() -> string { return "" }
    pub fn preserve_refusal() -> string { return "" }
    pub fn live_refusal() -> string { return "" }

    pub fn namespace_refusal(name: string) -> string {
        return "{name} uses an attribute namespace latte does not have — latte has two, on: for a DOM event and bind: for a two-way binding, beside the XML namespaces xlink:, xml: and xmlns:"
    }

    /// Open, for the same reason tags are: `data-`, `aria-`, a framework's own
    /// attribute and a custom element's property are all legitimate, and a
    /// table that refused them would have to grow forever.
    pub fn attribute_refusal(tag: string, name: string) -> string { return "" }

    pub fn resolve_literal(value: string) -> string { return resolve_references(value) }

    /// `ref=` hands back what a tag built. On an element that is a DOM node,
    /// on a component tag it is the instance — both are things a render owns,
    /// so neither is refused.
    pub fn ref_refusal(tag: string, component: bool) -> string { return "" }

    pub fn inline_handler_refusal(name: string) -> string {
        if !is_inline_handler_attribute(name) { return "" }
        if names_an_event_handler(name) {
            return "{name} is an inline script handler and latte refuses it — a handler exists only as an id and the client never evaluates a string. Write on:{name.slice(2, name.len()).to_lower()}=\{fn(e: <EventType>) \{ ... \}\} instead"
        }
        return "{name} starts with on, and latte refuses every attribute whose name does — HTML's inline handlers all have that shape, latte.Builder drops such an attribute at run time, and a folded constant subtree would keep what the unfolded walk dropped. Rename it, or write on:<event>=\{...\} if you meant a handler"
    }

    pub fn is_event(event: string) -> bool { return event_method(event) != "" }
    pub fn event_list() -> string { return event_list() }
    pub fn nearest_event(event: string) -> string { return nearest_event(event) }
    pub fn event_family(event: string) -> string { return event_family(event) }
    pub fn event_method(event: string) -> string { return event_method(event) }

    pub fn bind_state_refusal(tag: string) -> string {
        if tag.to_lower() == "input" { return "" }
        return "bind:checked works on an <input>, and this is a <{tag}>"
    }

    pub fn bind_value_refusal(tag: string) -> string {
        let lower: string = tag.to_lower()
        if lower == "input" || lower == "textarea" { return "" }
        if lower == "select" {
            return "bind:value on a <select> cannot set the initial selection: a select's value is not an attribute, it is which <option> carries selected. Write selected=\{...\} on the option and on:change=\{...\} for the write-back"
        }
        return "bind:value works on an <input> and a <textarea>, and this is a <{tag}>"
    }
}
