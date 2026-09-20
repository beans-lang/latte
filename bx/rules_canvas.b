// What a `.bx` file means when it compiles into drawn controls.
package bx

/// The canvas target's rules. This target is closed where the html one is
/// open: a name nobody wrote a renderer for is a misspelling, not an extension.
pub class CanvasRules implements TargetRules {
    pub fn init() {}

    pub fn target() -> Target { return Target.canvas }

    pub fn names_a_component(tag: string) -> bool { return canvas_names_a_component(tag) }

    /// There are none: every control is self-closed or has a body, and a body
    /// is always markup. Nothing here holds text that is not the language.
    pub fn is_void_element(tag: string) -> bool { return false }
    pub fn is_raw_text_element(tag: string) -> bool { return false }
    pub fn preserves_whitespace(tag: string) -> bool { return false }

    pub fn tag_refusal(tag: string) -> string {
        if canvas_tag_is_drawn(tag) { return "" }
        let retired: string = canvas_retired_tag(tag)
        if retired != "" { return retired }
        // A name the markup knows and the renderer has not got yet, refused
        // here where the message names the file and the line.
        if canvas_is_widget_tag(tag) {
            return "<{tag}> is a control latte has no renderer for yet — the ones it draws are {canvas_drawn_list()}"
        }
        // A capitalised name is the author's own component, and this rule has
        // nothing to say about it.
        if canvas_names_a_component(tag) { return "" }
        // Lower case and unknown — HTML element names are what this catches,
        // so a page copied from the html target says so rather than drawing.
        let near: string = canvas_nearest_of(tag, canvas_widget_tags())
        if near != "" { return "<{tag}> is not a control latte draws — did you mean <{near}>?" }
        return "<{tag}> is not a control latte draws — a canvas component is built from {canvas_drawn_list()}"
    }

    pub fn doctype_refusal(text: string) -> string {
        return "{text} declares the grammar of an HTML document, and a canvas component draws controls — there is no document for it to be the first line of. Delete it; the surface a component renders into is made by the application, not by the markup"
    }

    pub fn raw_html_refusal() -> string {
        return "$html writes unescaped HTML and a canvas component draws controls, so there is nothing for it to write into. Build the controls you want with tags"
    }

    pub fn splat_refusal() -> string {
        return "attrs=\{ \} splats a map of HTML attributes onto an element, and a canvas control has a closed set of typed properties rather than a bag of strings. Write the ones you mean"
    }

    pub fn preserve_refusal() -> string {
        return "preserve stops the differ walking into a subtree a third-party script owns, and nothing but latte draws into a canvas. Remove it"
    }

    pub fn live_refusal() -> string {
        return "live binds an element's text to a signal so a write patches one DOM node, and a canvas component repaints the control instead. Remove it; a change to state re-renders"
    }

    pub fn namespace_refusal(name: string) -> string {
        return "{name} uses an attribute prefix latte does not have here — there are two, on: for an event and bind: for a two-way binding"
    }

    pub fn attribute_refusal(tag: string, name: string) -> string {
        let html_only: string = canvas_html_only_attribute(name)
        if html_only != "" { return html_only }
        if canvas_attribute_call(name) != "" { return "" }
        let near: string = canvas_nearest_attribute(name)
        if near == "" {
            return "<{tag}> has no attribute called {name} — the ones a canvas control knows are {canvas_attribute_list()}"
        }
        return "<{tag}> has no attribute called {name} — did you mean {near}?"
    }

    /// Nothing to resolve: this value becomes a Beans string a renderer draws,
    /// so `&amp;` is the five characters it is written as.
    pub fn resolve_literal(value: string) -> string { return value }

    pub fn ref_refusal(tag: string, component: bool) -> string {
        if component { return "" }
        return "ref=\{ \} hands back the component instance a tag built, and <{tag}> is a control — a control is made and owned by the mount, not by the render that described it. Name it with key=\"...\" and reach it once it exists: Stage.control(key) for its handle, Stage.widget(key) for the control itself, both from on_mount"
    }

    /// Nothing here is an inline script handler: there is no script, and the
    /// closed table above refuses an `on` attribute that is not an event.
    pub fn inline_handler_refusal(name: string) -> string { return "" }

    pub fn is_event(event: string) -> bool { return canvas_event_family(event) != "" }
    pub fn event_list() -> string { return canvas_event_list() }
    pub fn nearest_event(event: string) -> string { return canvas_nearest_event(event) }
    pub fn event_family(event: string) -> string { return canvas_event_family(event) }

    /// The Builder takes a canvas event by name — `b.on("click", ...)` — so
    /// there is no per-event method to name.
    pub fn event_method(event: string) -> string { return "" }

    pub fn bind_state_refusal(tag: string) -> string {
        if tag == "CheckBox" || tag == "RadioButton" || tag == "Switch" { return "" }
        return "bind:checked works on a <CheckBox>, a <RadioButton> and a <Switch>, and this is a <{tag}>"
    }

    pub fn bind_value_refusal(tag: string) -> string {
        if tag == "TextField" || tag == "SecureField" || tag == "SearchField" ||
           tag == "TextArea" { return "" }
        if tag == "ComboBox" || tag == "Segmented" || tag == "TabView" {
            return "bind:value on a <{tag}> would bind the words, and what one of these holds is an index. Write selected=\{...\} and on:change=\{...\} for the write-back"
        }
        return "bind:value works on the controls that hold text a user edits — <TextField>, <SecureField>, <SearchField> and <TextArea> — and this is a <{tag}>"
    }
}
