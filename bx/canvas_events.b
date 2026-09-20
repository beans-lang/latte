// canvas_events.b — what `on:` may name. An event the Builder cannot deliver
// is refused here: subscribed, it would be a handler that never fires.

package bx

/// Whether `on:<event>` names something latte raises.
pub fn canvas_is_event(event: string) -> bool {
    return canvas_event_family(event) != ""
}

/// The event class an `on:<event>` handler receives, or `""` when the event is
/// not one latte raises.
pub fn canvas_event_family(event: string) -> string {
    if event == "click" { return "UiEvent" }
    if event == "activate" { return "UiEvent" }
    if event == "change" { return "UiEvent" }
    if event == "commit" { return "UiEvent" }
    if event == "select" { return "UiEvent" }
    if event == "focus" { return "UiEvent" }
    if event == "blur" { return "UiEvent" }
    if event == "pointer_down" { return "UiEvent" }
    if event == "pointer_up" { return "UiEvent" }
    if event == "pointer_move" { return "UiEvent" }
    if event == "key_down" { return "UiEvent" }
    if event == "key_up" { return "UiEvent" }
    return ""
}

/// Every event name, in order, for a diagnostic that can list them.
pub fn canvas_event_names() -> List<string> {
    return ["activate", "blur", "change", "click", "commit", "focus",
            "key_down", "key_up", "pointer_down", "pointer_move",
            "pointer_up", "select"]
}

/// The events, comma-separated, for the body of a diagnostic.
pub fn canvas_event_list() -> string {
    return canvas_event_names().join(", ")
}

/// The nearest event by edit distance, within two, or `""`. A wrong suggestion
/// is worse than none: it sends the reader to fix the wrong thing.
pub fn canvas_nearest_event(event: string) -> string {
    return canvas_nearest_of(event, canvas_event_names())
}
