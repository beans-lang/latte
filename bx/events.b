// events.b — the HTML event table.
//
// `on:click={...}` becomes `b.on_click(seq, ...)`, and this file is the list
// of what `on:` may name. It exists for one reason: **an event the Builder has
// no method for must be refused here.** Emitting `b.on_wheel(...)` for a
// Builder that has no `on_wheel` is a beansc error in a file the author never
// wrote, about a method they never named — the failure arriving at build time
// in the emitter's vocabulary, which is the thing this workspace's rules
// forbid.
//
// **The table and `latte.Builder` are one contract.** Every row here is a
// method `Builder` declares, typed to the family in the second column. Five
// families exist because five event classes exist — `MouseEvent`,
// `InputEvent`, `KeyboardEvent`, `SubmitEvent` and `FocusEvent`. An event
// with no family is not in the table, and its refusal says so rather than
// pretending.
//
// The family is not used for emission — the author writes the closure's
// parameter type themselves, exactly as they would in hand-written builder
// code. It is here so the diagnostic can say which type to write, and so the
// documentation table is generated from the same list the refusal uses.

package bx

/// The Builder method for `on:<event>`, or `""` when there is no such event.
pub fn event_method(event: string) -> string {
    if event_family(event) == "" { return "" }
    return "on_{event}"
}

/// The event class an `on:<event>` handler receives, or `""` when the event is
/// not in the table.
pub fn event_family(event: string) -> string {
    // Mouse.
    if event == "click" { return "MouseEvent" }
    if event == "dblclick" { return "MouseEvent" }
    if event == "mousedown" { return "MouseEvent" }
    if event == "mouseup" { return "MouseEvent" }
    if event == "mouseenter" { return "MouseEvent" }
    if event == "mouseleave" { return "MouseEvent" }
    if event == "mouseover" { return "MouseEvent" }
    if event == "mouseout" { return "MouseEvent" }
    if event == "mousemove" { return "MouseEvent" }
    if event == "contextmenu" { return "MouseEvent" }
    // Input.
    if event == "input" { return "InputEvent" }
    if event == "change" { return "InputEvent" }
    // Keyboard.
    if event == "keydown" { return "KeyboardEvent" }
    if event == "keyup" { return "KeyboardEvent" }
    if event == "keypress" { return "KeyboardEvent" }
    // Submit.
    if event == "submit" { return "SubmitEvent" }
    if event == "reset" { return "SubmitEvent" }
    // Focus.
    if event == "focus" { return "FocusEvent" }
    if event == "blur" { return "FocusEvent" }
    if event == "focusin" { return "FocusEvent" }
    if event == "focusout" { return "FocusEvent" }
    return ""
}

/// Every event the table knows, in the order a diagnostic should list them.
///
/// Written out rather than derived, because `event_family` is a chain of
/// comparisons and a chain cannot be enumerated. `w2_event_table_agrees` in
/// tests/markup.b checks the two against each other, so a row added to one and
/// forgotten in the other fails the gate rather than shipping a table that
/// lists an event the compiler refuses.
pub fn event_names() -> List<string> {
    return ["click", "dblclick", "mousedown", "mouseup", "mouseenter",
            "mouseleave", "mouseover", "mouseout", "mousemove", "contextmenu",
            "input", "change",
            "keydown", "keyup", "keypress",
            "submit", "reset",
            "focus", "blur", "focusin", "focusout"]
}

/// The events, comma-separated, for the body of a diagnostic.
pub fn event_list() -> string {
    return event_names().join(", ")
}

/// The nearest event to `event` by edit distance, or `""` when nothing is
/// close enough to be worth suggesting.
///
/// A suggestion is only offered within two edits, so `on:clcik` says "did you
/// mean click?" and `on:wheel` does not say "did you mean keyup?". A wrong
/// suggestion is worse than none: it sends the reader to fix the wrong thing.
pub fn nearest_event(event: string) -> string {
    var best: string = ""
    var best_distance: int = 3
    for candidate: string in event_names() {
        let distance: int = edit_distance(event, candidate)
        if distance < best_distance {
            best_distance = distance
            best = candidate
        }
    }
    return best
}

/// Levenshtein distance between two short ASCII names.
///
/// Two rows rather than a matrix: the names here are at most eleven bytes and
/// the table is twenty long, so this runs once per bad event and never on a
/// path anyone measures.
pub fn edit_distance(from: string, to: string) -> int {
    let width: int = to.len() + 1
    var previous: List<int> = []
    var current: List<int> = []
    var i: int = 0
    for i < width {
        previous.push(i)
        current.push(0)
        i = i + 1
    }
    var row: int = 1
    for row <= from.len() {
        current[0] = row
        var column: int = 1
        for column < width {
            var cost: int = 1
            if from.byte_at(row - 1) == to.byte_at(column - 1) { cost = 0 }
            var best: int = previous[column] + 1
            if current[column - 1] + 1 < best { best = current[column - 1] + 1 }
            if previous[column - 1] + cost < best { best = previous[column - 1] + cost }
            current[column] = best
            column = column + 1
        }
        var copy: int = 0
        for copy < width {
            previous[copy] = current[copy]
            copy = copy + 1
        }
        row = row + 1
    }
    return previous[width - 1]
}
