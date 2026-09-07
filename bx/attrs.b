// attrs.b — one markup attribute to one Beans call.
//
// This file answers exactly one question: given an `Attr` from the parser,
// what call text does it become, or what is the error? It does not parse and
// it does not emit — `bx/emit.b` decides where the calls go and bx/ast.b is
// the contract between them.
//
//     FlagAttr("flex")               ->  .flex()
//     RampAttr("gap", "2")           ->  .gap(style.Gap.s2)
//     RampAttr("p", "4")             ->  .p(style.Gap.s4)
//     RampAttr("m", "neg-4")         ->  .m(style.Space.neg_s4)
//     RampAttr("rounded", "lg")      ->  .rounded(style.Stroke.lg)
//     TextAttr("bg", "red")          ->  .bg(style.Fill.of_rgba(..))
//     ExprAttr("w", "my_width")      ->  .w(my_width)
//     HandlerAttr("click", "..")     ->  .on_click(..)
//
// Padding is served by `Gap` and not by `Space`, and that is the rule rather
// than the exception: docs/FLUENT.md says to pick the table by the type the
// method takes, not by the family's name. `p(..)` takes a
// `geo.DefiniteLength` because `padding: auto` does not exist. The tables
// below are built that way — every family whose argument is a `geo.Length`
// is a `Space` family, every `geo.DefiniteLength` family is a `Gap` family,
// every `geo.AbsoluteLength` family is a `Stroke` family, and no name was
// consulted.
//
// ---------------------------------------------- most flags arrive as ramps
//
// bx/parse.b splits an attribute name at its last hyphen and hands on both
// halves without deciding whether either is real. It is right not to: a
// parser that owned validity could not say "no such step `1p6`, did you mean
// `1p5`?". But it means a large part of what an author writes as a *flag*
// reaches `ramp_call` looking like a family and a step:
//
//     flex-col             -> flex / col              -> .flex_col()
//     items-center         -> items / center          -> .items_center()
//     text-lg              -> text / lg               -> .text_lg()
//     shadow-lg            -> shadow / lg             -> .shadow_lg()
//     cursor-pointer       -> cursor / pointer        -> .cursor_pointer()
//     text-ellipsis-middle -> text_ellipsis / middle  -> .text_ellipsis_middle()
//
// So `ramp_call` joins the halves back up and asks the flag table, and it
// does that *and* the ramp lookup on every attribute rather than stopping at
// the first hit — because a name that answered to both would otherwise pick
// one silently and hand the author the other. Both is a refusal that names
// both readings. There are none today and the driver counts them, over all
// 3,317 family-and-step pairs, so zero is measured rather than assumed.
//
// `text-lg` is the case worth staring at, because getting it wrong still
// compiles. `text_size(..)` takes a `geo.AbsoluteLength` and
// `style.Stroke.lg` is one, so treating `text` as a `Stroke` family would
// build cleanly and set 0.5rem where `text_lg()` sets 1.125rem. That is why
// `text_size` is not in the ramp table: docs/FLUENT.md says the Tailwind text
// sizes are hand-written named steps, and the flag is what `text-lg` must
// reach.
//
// A family written with no step — `border-t`, `gap-x`, `min-w` — is a
// diagnostic naming the step to add, not a default. Tailwind reads bare
// `border-t` as 1px; crema has no `border_t()` that takes nothing, and 1px
// appears nowhere in its API, so a default would put a number into the
// markup's meaning that no crema source states.
//
// ---------------------------------------------------------------- the tables
//
// Nothing here was invented. Every name was read out of crema:
//
//   * `flags`   — the 128 no-argument `-> Self` methods of the `Styled`
//                 chain (style/styled*.b) and `InteractiveElement`
//                 (element/interactive.b).
//   * `ramps`   — the 48 one-argument methods whose argument is one of the
//                 three ramp types, minus `flex_basis`, `scrollbar_width`
//                 and `text_size`. Those three take a ramp type and accept a
//                 table value where one fits, but docs/FLUENT.md says they
//                 are not ramp families: the Tailwind text sizes are their
//                 own named steps (`text_xs()` .. `text_3xl()`), which are
//                 flags, and `text-sm` must reach the flag rather than
//                 `text_size`.
//   * `counts`  — the 13 one-argument methods taking a whole number, which
//                 is how `grid-cols-3` and `line-clamp-2` are spelled.
//   * `values`  — the other 95 one-argument methods, for `attr={code}`.
//   * `texts`   — the 12 attributes that take a quoted string: eight colours
//                 and four names.
//   * `events`  — the 20 listener methods of `InteractiveElement`.
//   * the step  — `style/scale.b`'s `pub static` fields, 91 + 90 + 26.
//     lists
//
// ------------------------------------------------------- proving the tables
//
// A table entry naming a method that does not exist is the failure this file
// is exposed to, and nothing catches it: bx never calls these methods, it
// prints their names, so a misspelling survives every test until someone
// writes the markup that reaches it.
//
// Reflection would catch it and costs 32-80 us a call (RULES.md), which is
// not the reason to refuse it — the reason is that a compiler should not
// need a runtime to know whether the code it emits is real.
//
// So the check is a *build*. `proof_source()` walks every table and returns a
// complete `package main` program that calls every entry on a `Div` and
// discards the result. tests/probe_bx_attrs.b writes it out and runs beansc
// over it. If a family is misspelled the program does not compile, and the
// compiler names the misspelling.
//
// Two things make that a check rather than a ritual, and both are in the
// driver because both are easy to lose:
//
//   1. **It has to be able to fail.** The driver counts the calls it emitted
//      and asserts the count against the table sizes. A generator that
//      quietly emitted nothing would compile perfectly.
//   2. **It has to fail for the right reason.** A red proof means "something
//      is wrong", not "the table is wrong" — a typo in the generator, a
//      missing import or a bad receiver would look identical. The driver
//      therefore also builds a *corrupted* copy, with one family renamed to
//      something that cannot exist, and asserts that beansc refuses it and
//      that the message names that family. If corrupting the table does not
//      move the error, the proof is measuring something else.
//
// The calls come from the same `*_call` functions the emitter uses, not from
// a parallel copy of the tables, so the proof is over the text bx actually
// produces.
//
// ------------------------------------------------------------------ imports
//
// The emitted text names `crema.style` and `crema.color` and nothing else;
// `attr_imports()` says so, so emit.b does not have to guess.

package bx

/// One family that takes a step from one of the three ramp tables.
pub struct RampRow {
    /// The method, and the attribute family as written: `gap`, `mt`.
    pub family: string = ""
    /// Which table in `crema.style` holds its steps.
    pub table: string = ""
}

/// One method that takes a value, for `attr={code}`.
pub struct ValueRow {
    /// The attribute, which is also the method name.
    pub attr: string = ""
    /// The declared argument type, for the diagnostic.
    pub takes: string = ""
    /// An argument of that type, as Beans source, for the build proof.
    pub sample: string = ""
}

/// One attribute that takes a quoted string.
pub struct TextRow {
    /// The attribute as written.
    pub attr: string = ""
    /// The method it calls, which is not always the same name.
    pub method: string = ""
    /// What the value means: `fill`, `rgba`, `hsla`, `background` for
    /// a colour, `string` for text.
    pub kind: string = ""
}

/// One event listener.
pub struct EventRow {
    /// The event as written after `on:`, hyphens normalised.
    pub event: string = ""
    /// The method it calls.
    pub method: string = ""
    /// The type of the first parameter the listener is handed.
    pub payload: string = ""
    /// True when the method wants a `platform.MouseButton` first and
    /// so cannot be reached from `on:x={..}` at all.
    pub button: bool = false
}

/// The tables, read out of crema and written down here.
///
/// Plain `pub static` fields: they initialise once, before `main`, in
/// declaration order, and not one of them reads another — which is the
/// rule RULES.md gives for keeping file order from mattering.
pub class Tables {
    /// Every no-argument `-> Self` method: the whole `FlagAttr` surface.
    pub static flags: List<string> = [
        "absolute", "allow_concurrent_scroll", "aspect_square", "block",
        "block_mouse_except_scroll", "border_dashed", "col_end_auto", "col_span_full",
        "col_start_auto", "content_around", "content_between", "content_center",
        "content_end", "content_evenly", "content_normal", "content_start",
        "content_stretch", "cursor_alias", "cursor_col_resize", "cursor_context_menu",
        "cursor_copy", "cursor_crosshair", "cursor_default", "cursor_e_resize",
        "cursor_ew_resize", "cursor_grab", "cursor_grabbing", "cursor_move",
        "cursor_n_resize", "cursor_nesw_resize", "cursor_no_drop", "cursor_not_allowed",
        "cursor_ns_resize", "cursor_nwse_resize", "cursor_pointer", "cursor_row_resize",
        "cursor_s_resize", "cursor_text", "cursor_vertical_text", "cursor_w_resize",
        "debug", "debug_below", "flex", "flex_1",
        "flex_auto", "flex_col", "flex_col_reverse", "flex_grow_0",
        "flex_grow_1", "flex_initial", "flex_none", "flex_nowrap",
        "flex_row", "flex_row_reverse", "flex_shrink_0", "flex_shrink_1",
        "flex_wrap", "flex_wrap_reverse", "grid", "hidden",
        "invisible", "italic", "items_baseline", "items_center",
        "items_end", "items_start", "items_stretch", "justify_around",
        "justify_between", "justify_center", "justify_end", "justify_evenly",
        "justify_start", "line_through", "not_italic", "occlude",
        "overflow_hidden", "overflow_scroll", "overflow_x_hidden", "overflow_x_scroll",
        "overflow_y_hidden", "overflow_y_scroll", "relative", "restrict_scroll_to_axis",
        "row_end_auto", "row_span_full", "row_start_auto", "self_baseline",
        "self_center", "self_end", "self_flex_end", "self_flex_start",
        "self_start", "self_stretch", "shadow_2xl", "shadow_2xs",
        "shadow_lg", "shadow_md", "shadow_none", "shadow_sm",
        "shadow_xl", "shadow_xs", "text_2xl", "text_3xl",
        "text_base", "text_center", "text_decoration_0", "text_decoration_1",
        "text_decoration_2", "text_decoration_4", "text_decoration_8", "text_decoration_none",
        "text_decoration_solid", "text_decoration_wavy", "text_ellipsis", "text_ellipsis_middle",
        "text_ellipsis_start", "text_left", "text_lg", "text_right",
        "text_sm", "text_xl", "text_xs", "truncate",
        "underline", "visible", "whitespace_normal", "whitespace_nowrap",
    ]

    /// Every family that takes a ramp step, and its table.
    pub static ramps: List<RampRow> = [
        RampRow { family: "bottom", table: "Space" }, RampRow { family: "h", table: "Space" }, RampRow { family: "inset", table: "Space" },
        RampRow { family: "left", table: "Space" }, RampRow { family: "m", table: "Space" }, RampRow { family: "max_h", table: "Space" },
        RampRow { family: "max_size", table: "Space" }, RampRow { family: "max_w", table: "Space" }, RampRow { family: "mb", table: "Space" },
        RampRow { family: "min_h", table: "Space" }, RampRow { family: "min_size", table: "Space" }, RampRow { family: "min_w", table: "Space" },
        RampRow { family: "ml", table: "Space" }, RampRow { family: "mr", table: "Space" }, RampRow { family: "mt", table: "Space" },
        RampRow { family: "mx", table: "Space" }, RampRow { family: "my", table: "Space" }, RampRow { family: "right", table: "Space" },
        RampRow { family: "size", table: "Space" }, RampRow { family: "top", table: "Space" }, RampRow { family: "w", table: "Space" },
        RampRow { family: "gap", table: "Gap" }, RampRow { family: "gap_x", table: "Gap" }, RampRow { family: "gap_y", table: "Gap" },
        RampRow { family: "line_height", table: "Gap" }, RampRow { family: "p", table: "Gap" }, RampRow { family: "pb", table: "Gap" },
        RampRow { family: "pl", table: "Gap" }, RampRow { family: "pr", table: "Gap" }, RampRow { family: "pt", table: "Gap" },
        RampRow { family: "px", table: "Gap" }, RampRow { family: "py", table: "Gap" }, RampRow { family: "border", table: "Stroke" },
        RampRow { family: "border_b", table: "Stroke" }, RampRow { family: "border_l", table: "Stroke" }, RampRow { family: "border_r", table: "Stroke" },
        RampRow { family: "border_t", table: "Stroke" }, RampRow { family: "border_x", table: "Stroke" }, RampRow { family: "border_y", table: "Stroke" },
        RampRow { family: "rounded", table: "Stroke" }, RampRow { family: "rounded_b", table: "Stroke" }, RampRow { family: "rounded_bl", table: "Stroke" },
        RampRow { family: "rounded_br", table: "Stroke" }, RampRow { family: "rounded_l", table: "Stroke" }, RampRow { family: "rounded_r", table: "Stroke" },
        RampRow { family: "rounded_t", table: "Stroke" }, RampRow { family: "rounded_tl", table: "Stroke" }, RampRow { family: "rounded_tr", table: "Stroke" },
    ]

    /// Every family that takes a whole number: `grid-cols-3`.
    pub static counts: List<string> = [
        "col_end", "col_span", "col_start",
        "grid_cols", "grid_cols_max_content", "grid_cols_min_content",
        "grid_rows", "grid_rows_max_content", "grid_rows_min_content",
        "line_clamp", "row_end", "row_span",
        "row_start",
    ]

    /// Every attribute that takes a quoted string.
    pub static texts: List<TextRow> = [
        TextRow { attr: "bg", method: "bg", kind: "fill" },
        TextRow { attr: "bg_background", method: "bg_background", kind: "background" },
        TextRow { attr: "bg_color", method: "bg_color", kind: "hsla" },
        TextRow { attr: "bg_rgba", method: "bg_rgba", kind: "rgba" },
        TextRow { attr: "border_color", method: "border_color", kind: "hsla" },
        TextRow { attr: "font_family", method: "font_family", kind: "string" },
        TextRow { attr: "group", method: "group", kind: "string" },
        TextRow { attr: "id", method: "id_name", kind: "string" },
        TextRow { attr: "id_name", method: "id_name", kind: "string" },
        TextRow { attr: "text_bg", method: "text_bg", kind: "hsla" },
        TextRow { attr: "text_color", method: "text_color", kind: "hsla" },
        TextRow { attr: "text_decoration_color", method: "text_decoration_color", kind: "hsla" },
    ]

    /// Every listener method.
    pub static events: List<EventRow> = [
        EventRow { event: "capture_any_mouse_down", method: "capture_any_mouse_down", payload: "platform.MouseDownEvent", button: false },
        EventRow { event: "capture_any_mouse_up", method: "capture_any_mouse_up", payload: "platform.MouseUpEvent", button: false },
        EventRow { event: "capture_key_down", method: "capture_key_down", payload: "platform.KeyDownEvent", button: false },
        EventRow { event: "capture_key_up", method: "capture_key_up", payload: "platform.KeyUpEvent", button: false },
        EventRow { event: "any_mouse_down", method: "on_any_mouse_down", payload: "platform.MouseDownEvent", button: false },
        EventRow { event: "aux_click", method: "on_aux_click", payload: "element.ClickEvent", button: false },
        EventRow { event: "click", method: "on_click", payload: "element.ClickEvent", button: false },
        EventRow { event: "hover", method: "on_hover", payload: "bool", button: false },
        EventRow { event: "key_down", method: "on_key_down", payload: "platform.KeyDownEvent", button: false },
        EventRow { event: "key_up", method: "on_key_up", payload: "platform.KeyUpEvent", button: false },
        EventRow { event: "modifiers_changed", method: "on_modifiers_changed", payload: "platform.ModifiersChangedEvent", button: false },
        EventRow { event: "mouse_down_out", method: "on_mouse_down_out", payload: "platform.MouseDownEvent", button: false },
        EventRow { event: "mouse_exit", method: "on_mouse_exit", payload: "platform.MouseExitEvent", button: false },
        EventRow { event: "mouse_move", method: "on_mouse_move", payload: "platform.MouseMoveEvent", button: false },
        EventRow { event: "mouse_pressure", method: "on_mouse_pressure", payload: "platform.MousePressureEvent", button: false },
        EventRow { event: "pinch", method: "on_pinch", payload: "platform.PinchEvent", button: false },
        EventRow { event: "scroll_wheel", method: "on_scroll_wheel", payload: "platform.ScrollWheelEvent", button: false },
        EventRow { event: "mouse_down", method: "on_mouse_down", payload: "platform.MouseDownEvent", button: true },
        EventRow { event: "mouse_up", method: "on_mouse_up", payload: "platform.MouseUpEvent", button: true },
        EventRow { event: "mouse_up_out", method: "on_mouse_up_out", payload: "platform.MouseUpEvent", button: true },
    ]

    /// Every other one-argument method, for `attr={code}`.
    pub static values: List<ValueRow> = [
        ValueRow { attr: "active", takes: "style.StyleRefinement", sample: "new style.StyleRefinement()" },
        ValueRow { attr: "aspect_ratio", takes: "f32", sample: "0.5" },
        ValueRow { attr: "bg", takes: "style.Fill", sample: "style.Fill.default()" },
        ValueRow { attr: "bg_background", takes: "color.Background", sample: "color.Background.solid_color(color.Hsla.black())" },
        ValueRow { attr: "bg_color", takes: "color.Hsla", sample: "color.Hsla.black()" },
        ValueRow { attr: "bg_rgba", takes: "color.Rgba", sample: "color.Rgba.transparent()" },
        ValueRow { attr: "border", takes: "geo.AbsoluteLength", sample: "style.Stroke.s0" },
        ValueRow { attr: "border_b", takes: "geo.AbsoluteLength", sample: "style.Stroke.s0" },
        ValueRow { attr: "border_color", takes: "color.Hsla", sample: "color.Hsla.black()" },
        ValueRow { attr: "border_l", takes: "geo.AbsoluteLength", sample: "style.Stroke.s0" },
        ValueRow { attr: "border_r", takes: "geo.AbsoluteLength", sample: "style.Stroke.s0" },
        ValueRow { attr: "border_t", takes: "geo.AbsoluteLength", sample: "style.Stroke.s0" },
        ValueRow { attr: "border_x", takes: "geo.AbsoluteLength", sample: "style.Stroke.s0" },
        ValueRow { attr: "border_y", takes: "geo.AbsoluteLength", sample: "style.Stroke.s0" },
        ValueRow { attr: "bottom", takes: "geo.Length", sample: "style.Space.s0" },
        ValueRow { attr: "col_end", takes: "i16", sample: "1" },
        ValueRow { attr: "col_span", takes: "u16", sample: "1" },
        ValueRow { attr: "col_start", takes: "i16", sample: "1" },
        ValueRow { attr: "cursor", takes: "style.CursorStyle", sample: "style.CursorStyle.arrow" },
        ValueRow { attr: "flex_basis", takes: "geo.Length", sample: "style.Space.s0" },
        ValueRow { attr: "flex_grow", takes: "f32", sample: "0.5" },
        ValueRow { attr: "flex_shrink", takes: "f32", sample: "0.5" },
        ValueRow { attr: "font_family", takes: "string", sample: "\"x\"" },
        ValueRow { attr: "font_weight", takes: "style.FontWeight", sample: "style.FontWeight.of(400.0)" },
        ValueRow { attr: "gap", takes: "geo.DefiniteLength", sample: "style.Gap.s0" },
        ValueRow { attr: "gap_x", takes: "geo.DefiniteLength", sample: "style.Gap.s0" },
        ValueRow { attr: "gap_y", takes: "geo.DefiniteLength", sample: "style.Gap.s0" },
        ValueRow { attr: "grid_cols", takes: "u16", sample: "1" },
        ValueRow { attr: "grid_cols_max_content", takes: "u16", sample: "1" },
        ValueRow { attr: "grid_cols_min_content", takes: "u16", sample: "1" },
        ValueRow { attr: "grid_rows", takes: "u16", sample: "1" },
        ValueRow { attr: "grid_rows_max_content", takes: "u16", sample: "1" },
        ValueRow { attr: "grid_rows_min_content", takes: "u16", sample: "1" },
        ValueRow { attr: "group", takes: "string", sample: "\"x\"" },
        ValueRow { attr: "h", takes: "geo.Length", sample: "style.Space.s0" },
        ValueRow { attr: "hover", takes: "style.StyleRefinement", sample: "new style.StyleRefinement()" },
        ValueRow { attr: "id", takes: "element.ElementId", sample: "element.ElementId.name(\"x\")" },
        ValueRow { attr: "id_name", takes: "string", sample: "\"x\"" },
        ValueRow { attr: "inset", takes: "geo.Length", sample: "style.Space.s0" },
        ValueRow { attr: "key_context", takes: "input.KeyContext", sample: "new input.KeyContext()" },
        ValueRow { attr: "left", takes: "geo.Length", sample: "style.Space.s0" },
        ValueRow { attr: "line_clamp", takes: "int", sample: "1" },
        ValueRow { attr: "line_height", takes: "geo.DefiniteLength", sample: "style.Gap.s0" },
        ValueRow { attr: "m", takes: "geo.Length", sample: "style.Space.s0" },
        ValueRow { attr: "max_h", takes: "geo.Length", sample: "style.Space.s0" },
        ValueRow { attr: "max_size", takes: "geo.Length", sample: "style.Space.s0" },
        ValueRow { attr: "max_w", takes: "geo.Length", sample: "style.Space.s0" },
        ValueRow { attr: "mb", takes: "geo.Length", sample: "style.Space.s0" },
        ValueRow { attr: "min_h", takes: "geo.Length", sample: "style.Space.s0" },
        ValueRow { attr: "min_size", takes: "geo.Length", sample: "style.Space.s0" },
        ValueRow { attr: "min_w", takes: "geo.Length", sample: "style.Space.s0" },
        ValueRow { attr: "ml", takes: "geo.Length", sample: "style.Space.s0" },
        ValueRow { attr: "mr", takes: "geo.Length", sample: "style.Space.s0" },
        ValueRow { attr: "mt", takes: "geo.Length", sample: "style.Space.s0" },
        ValueRow { attr: "mx", takes: "geo.Length", sample: "style.Space.s0" },
        ValueRow { attr: "my", takes: "geo.Length", sample: "style.Space.s0" },
        ValueRow { attr: "opacity", takes: "f32", sample: "0.5" },
        ValueRow { attr: "p", takes: "geo.DefiniteLength", sample: "style.Gap.s0" },
        ValueRow { attr: "pb", takes: "geo.DefiniteLength", sample: "style.Gap.s0" },
        ValueRow { attr: "pl", takes: "geo.DefiniteLength", sample: "style.Gap.s0" },
        ValueRow { attr: "pr", takes: "geo.DefiniteLength", sample: "style.Gap.s0" },
        ValueRow { attr: "pt", takes: "geo.DefiniteLength", sample: "style.Gap.s0" },
        ValueRow { attr: "px", takes: "geo.DefiniteLength", sample: "style.Gap.s0" },
        ValueRow { attr: "py", takes: "geo.DefiniteLength", sample: "style.Gap.s0" },
        ValueRow { attr: "right", takes: "geo.Length", sample: "style.Space.s0" },
        ValueRow { attr: "rounded", takes: "geo.AbsoluteLength", sample: "style.Stroke.s0" },
        ValueRow { attr: "rounded_b", takes: "geo.AbsoluteLength", sample: "style.Stroke.s0" },
        ValueRow { attr: "rounded_bl", takes: "geo.AbsoluteLength", sample: "style.Stroke.s0" },
        ValueRow { attr: "rounded_br", takes: "geo.AbsoluteLength", sample: "style.Stroke.s0" },
        ValueRow { attr: "rounded_l", takes: "geo.AbsoluteLength", sample: "style.Stroke.s0" },
        ValueRow { attr: "rounded_r", takes: "geo.AbsoluteLength", sample: "style.Stroke.s0" },
        ValueRow { attr: "rounded_t", takes: "geo.AbsoluteLength", sample: "style.Stroke.s0" },
        ValueRow { attr: "rounded_tl", takes: "geo.AbsoluteLength", sample: "style.Stroke.s0" },
        ValueRow { attr: "rounded_tr", takes: "geo.AbsoluteLength", sample: "style.Stroke.s0" },
        ValueRow { attr: "row_end", takes: "i16", sample: "1" },
        ValueRow { attr: "row_span", takes: "u16", sample: "1" },
        ValueRow { attr: "row_start", takes: "i16", sample: "1" },
        ValueRow { attr: "scrollbar_width", takes: "geo.AbsoluteLength", sample: "style.Stroke.s0" },
        ValueRow { attr: "set_column", takes: "geo.GridSpan", sample: "geo.GridSpan.auto()" },
        ValueRow { attr: "set_column_end", takes: "geo.GridPlacement", sample: "geo.GridPlacement.auto" },
        ValueRow { attr: "set_column_start", takes: "geo.GridPlacement", sample: "geo.GridPlacement.auto" },
        ValueRow { attr: "set_row", takes: "geo.GridSpan", sample: "geo.GridSpan.auto()" },
        ValueRow { attr: "set_row_end", takes: "geo.GridPlacement", sample: "geo.GridPlacement.auto" },
        ValueRow { attr: "set_row_start", takes: "geo.GridPlacement", sample: "geo.GridPlacement.auto" },
        ValueRow { attr: "shadow", takes: "style.BoxShadows", sample: "new style.BoxShadows()" },
        ValueRow { attr: "size", takes: "geo.Length", sample: "style.Space.s0" },
        ValueRow { attr: "text_align", takes: "style.TextAlign", sample: "style.TextAlign.left" },
        ValueRow { attr: "text_bg", takes: "color.Hsla", sample: "color.Hsla.black()" },
        ValueRow { attr: "text_color", takes: "color.Hsla", sample: "color.Hsla.black()" },
        ValueRow { attr: "text_decoration_color", takes: "color.Hsla", sample: "color.Hsla.black()" },
        ValueRow { attr: "text_decoration_thickness", takes: "geo.Pixels", sample: "geo.px(1.0)" },
        ValueRow { attr: "text_overflow", takes: "style.TextOverflow", sample: "style.TextOverflow.truncate(\"...\")" },
        ValueRow { attr: "text_size", takes: "geo.AbsoluteLength", sample: "style.Stroke.s0" },
        ValueRow { attr: "top", takes: "geo.Length", sample: "style.Space.s0" },
        ValueRow { attr: "w", takes: "geo.Length", sample: "style.Space.s0" },
    ]

    /// `style.Space` — the 91 `geo.Length` steps, `auto` included.
    pub static space_steps: List<string> = [
        "s0", "s0p5", "s1", "s1p5", "s2", "s2p5", "s3", "s3p5",
        "s4", "s5", "s6", "s7", "s8", "s9", "s10", "s11",
        "s12", "s16", "s20", "s24", "s32", "s40", "s48", "s56",
        "s64", "s72", "s80", "s96", "s112", "s128", "auto", "px",
        "full", "s1_2", "s1_3", "s2_3", "s1_4", "s2_4", "s3_4", "s1_5",
        "s2_5", "s3_5", "s4_5", "s1_6", "s5_6", "s1_12", "neg_s0", "neg_s0p5",
        "neg_s1", "neg_s1p5", "neg_s2", "neg_s2p5", "neg_s3", "neg_s3p5", "neg_s4", "neg_s5",
        "neg_s6", "neg_s7", "neg_s8", "neg_s9", "neg_s10", "neg_s11", "neg_s12", "neg_s16",
        "neg_s20", "neg_s24", "neg_s32", "neg_s40", "neg_s48", "neg_s56", "neg_s64", "neg_s72",
        "neg_s80", "neg_s96", "neg_s112", "neg_s128", "neg_px", "neg_full", "neg_s1_2", "neg_s1_3",
        "neg_s2_3", "neg_s1_4", "neg_s2_4", "neg_s3_4", "neg_s1_5", "neg_s2_5", "neg_s3_5", "neg_s4_5",
        "neg_s1_6", "neg_s5_6", "neg_s1_12",
    ]

    /// `style.Gap` — the 90 `geo.DefiniteLength` steps, `Space` without
    /// `auto`.
    pub static gap_steps: List<string> = [
        "s0", "s0p5", "s1", "s1p5", "s2", "s2p5", "s3", "s3p5",
        "s4", "s5", "s6", "s7", "s8", "s9", "s10", "s11",
        "s12", "s16", "s20", "s24", "s32", "s40", "s48", "s56",
        "s64", "s72", "s80", "s96", "s112", "s128", "px", "full",
        "s1_2", "s1_3", "s2_3", "s1_4", "s2_4", "s3_4", "s1_5", "s2_5",
        "s3_5", "s4_5", "s1_6", "s5_6", "s1_12", "neg_s0", "neg_s0p5", "neg_s1",
        "neg_s1p5", "neg_s2", "neg_s2p5", "neg_s3", "neg_s3p5", "neg_s4", "neg_s5", "neg_s6",
        "neg_s7", "neg_s8", "neg_s9", "neg_s10", "neg_s11", "neg_s12", "neg_s16", "neg_s20",
        "neg_s24", "neg_s32", "neg_s40", "neg_s48", "neg_s56", "neg_s64", "neg_s72", "neg_s80",
        "neg_s96", "neg_s112", "neg_s128", "neg_px", "neg_full", "neg_s1_2", "neg_s1_3", "neg_s2_3",
        "neg_s1_4", "neg_s2_4", "neg_s3_4", "neg_s1_5", "neg_s2_5", "neg_s3_5", "neg_s4_5", "neg_s1_6",
        "neg_s5_6", "neg_s1_12",
    ]

    /// `style.Stroke` — the 17 border widths and the 9 corner radii.
    pub static stroke_steps: List<string> = [
        "s0", "s1", "s2", "s3", "s4", "s5", "s6", "s7",
        "s8", "s9", "s10", "s11", "s12", "s16", "s20", "s24",
        "s32", "none", "xs", "sm", "md", "lg", "xl", "s2xl",
        "s3xl", "full",
    ]

    /// The tables are never instantiated; every member is static.
    pub fn init() {}
}

// ------------------------------------------------------------------- lookups

/// The Beans call text this attribute becomes, or why it cannot.
///
/// The parser decides an attribute's *shape* and never consults a table, so
/// this is where shape meets meaning. `as?` recovers the concrete class the
/// way `crema.element` recovers `ElementState`; an `Attr` subclass this file
/// has not met is a diagnostic rather than a non-exhaustive match.
pub fn attr_call(attr: Attr) -> Result<string> {
    match attr as? FlagAttr {
        some(a) => { return flag_call(a.attr_name, a.span) },
        none => {},
    }
    match attr as? RampAttr {
        some(a) => { return ramp_call(a.family, a.step, a.span) },
        none => {},
    }
    match attr as? TextAttr {
        some(a) => { return text_call(a.attr_name, a.value, a.span) },
        none => {},
    }
    match attr as? ExprAttr {
        some(a) => { return expr_call(a.attr_name, a.code, a.span) },
        none => {},
    }
    match attr as? HandlerAttr {
        some(a) => { return handler_call(a.event, a.code, a.span) },
        none => {},
    }
    return err("{attr.span.show()}: bx has no rule for {attr.show()}", "unknown_attr")
}

/// A bare name: `flex` becomes `.flex()`.
pub fn flag_call(name: string, span: Span) -> Result<string> {
    if Tables.flags.contains(name) {
        return ok(".{name}()")
    }
    if find_ramp(name).len() > 0 {
        return err(
            "{span.show()}: '{markup(name)}' needs a step — write '{markup(name)}-2', or {markup(name)}=\{..\}",
            "needs_value")
    }
    if Tables.counts.contains(name) {
        return err(
            "{span.show()}: '{markup(name)}' needs a number — write '{markup(name)}-3'",
            "needs_value")
    }
    let taken: string = value_takes(name)
    if taken.len() > 0 {
        return err(
            "{span.show()}: '{markup(name)}' needs a value — write {markup(name)}=\{..\}, a {taken}",
            "needs_value")
    }
    return unknown_attr(name, span)
}

/// A family and a step: `gap-2` becomes `.gap(style.Gap.s2)`.
///
/// **Most of what an author writes as a flag arrives here.** bx/parse.b
/// splits an attribute name at its last hyphen and hands on both halves
/// without deciding whether either is real — that is this file's job. So
/// `flex-col` arrives as `flex` / `col`, `items-center` as `items` /
/// `center`, `text-lg` as `text` / `lg`, and `text-ellipsis-middle` as
/// `text_ellipsis` / `middle`. Not one of those families exists. Joining the
/// halves back up with an underscore and asking the flag table is what turns
/// them into `.flex_col()`, `.items_center()`, `.text_lg()` and
/// `.text_ellipsis_middle()`.
///
/// `text-lg` is the one to keep in mind, because it is the case where being
/// wrong still compiles: `text_size(..)` takes a `geo.AbsoluteLength` and
/// `style.Stroke.lg` is one, so `.text_size(style.Stroke.lg)` would build and
/// mean 0.5rem instead of the 1.125rem `text_lg()` sets. docs/FLUENT.md says
/// the Tailwind text sizes are hand-written named steps and not a ramp, which
/// is why `text_size` is not a ramp family in the table above and why the
/// flag is what `text-lg` reaches.
///
/// **The order, and why it cannot be silent.** The flag table is asked first
/// and the ramp tables second — but if a name resolves *both* ways, neither
/// answer is returned. Picking one would mean an author writing `X-Y` and
/// getting the other, with nothing said, and a table this file does not own
/// could grow such a name at any time. So a name that is a flag and a
/// family-plus-step at once is refused, loudly, naming both readings.
/// There are none today: tests/probe_bx_attrs.b walks all 3,317
/// family-and-step pairs against the 128 flags and reports the count, so
/// zero is a measured result rather than an assumption.
///
/// The rules, in order:
///
///  1. `family_step` is a flag — `.flex_col()`. Refused if rule 2 also
///     applies.
///  2. `family` is a ramp family and `step` is a step of its table —
///     `.gap(style.Gap.s2)`.
///  3. `family` is a counted family and `step` is a number —
///     `.grid_cols(3)`.
///  4. `family_step` is itself a family — the author wrote `border-t` and
///     stopped. That is a diagnostic naming the step to add, not a default:
///     Tailwind's bare `border-t` means 1px, and 1px appears nowhere in
///     crema's API, so inventing it here would put a number in the markup's
///     meaning that no crema source states. See the note on rule 4 below.
///  5. anything else is a diagnostic with the nearest real name.
pub fn ramp_call(family: string, step: string, span: Span) -> Result<string> {
    let joined: string = joined_name(family, step)
    let table: string = find_ramp(family)
    let field: string = step_name(step)
    let is_flag: bool = Tables.flags.contains(joined)
    let is_ramp: bool = table.len() > 0 && has_step(table, field)
    if is_flag && is_ramp {
        return err(
            "{span.show()}: '{markup(joined)}' reads two ways — as the flag .{joined}() and as .{family}(style.{table}.{field}) — so bx will not guess. This is a bx table bug: see ramp_call in bx/attrs.b",
            "ambiguous_attr")
    }
    if is_flag {
        return ok(".{joined}()")
    }
    if is_ramp {
        return ok(".{family}(style.{table}.{field})")
    }
    if Tables.counts.contains(family) {
        let number: string = count_value(step)
        if number.len() > 0 {
            return ok(".{family}({number})")
        }
    }

    // Rule 4. `border-t`, `gap-x`, `min-w`, `grid-cols` — a family written
    // with no step, which Tailwind gives a default and crema does not. crema
    // has no `border_t()` taking nothing: `border_t` takes a value, always.
    // Naming the step to write keeps the markup and the API saying the same
    // thing, and costs the author four characters once.
    let joined_table: string = find_ramp(joined)
    if joined_table.len() > 0 {
        let example: string = example_step(joined, joined_table)
        return err(
            "{span.show()}: '{markup(joined)}' is a family, not a step — write '{markup(joined)}-{example}'",
            "needs_value")
    }
    if Tables.counts.contains(joined) {
        return err(
            "{span.show()}: '{markup(joined)}' needs a number — write '{markup(joined)}-3'",
            "needs_value")
    }
    let joined_kind: string = text_kind(joined)
    if joined_kind.len() > 0 {
        return err(
            "{span.show()}: '{markup(joined)}' takes a value — write {markup(joined)}=\"..\"",
            "needs_value")
    }
    let joined_takes: string = value_takes(joined)
    if joined_takes.len() > 0 {
        return err(
            "{span.show()}: '{markup(joined)}' needs a value — write {markup(joined)}=\{..\}, a {joined_takes}",
            "needs_value")
    }

    // The family is real but the step is not.
    if table.len() > 0 {
        let near: string = nearest_name(field, steps_of(table))
        if near.len() == 0 {
            return err(
                "{span.show()}: '{markup(family)}' has no step '{step}' — style.{table} does not carry one",
                "unknown_step")
        }
        return err(
            "{span.show()}: '{markup(family)}' has no step '{step}' — did you mean '{step_markup(near)}'?",
            "unknown_step")
    }
    if Tables.counts.contains(family) {
        return err(
            "{span.show()}: '{markup(family)}' takes a number, not '{step}'",
            "unknown_step")
    }
    return unknown_attr(joined, span)
}

/// A step worth naming in "you left the step off" — a real field of the
/// family's own table, picked so the suggestion is something an author would
/// actually write.
///
/// `Stroke` needs the split because it carries two runs that share a type:
/// a border is counted in whole pixels and a radius in Tailwind's names, so
/// `border-t-1` and `rounded-t-md` are the two right answers and neither
/// works for the other family.
fn example_step(family: string, table: string) -> string {
    if table == "Stroke" {
        if family.starts_with("rounded") {
            return "md"
        }
        return "1"
    }
    return "4"
}

/// What a text attribute of this name does with its value, or "" when there
/// is no such attribute.
pub fn text_kind(attr: string) -> string {
    for row: TextRow in Tables.texts {
        if row.attr == attr {
            return row.kind
        }
    }
    return ""
}

/// A name and a quoted string: `bg="red"` becomes a channel literal.
pub fn text_call(attr: string, value: string, span: Span) -> Result<string> {
    for row: TextRow in Tables.texts {
        if row.attr == attr {
            return text_row_call(row, value, span)
        }
    }
    if Tables.flags.contains(attr) {
        return err(
            "{span.show()}: '{markup(attr)}' takes no value — write it on its own",
            "unexpected_value")
    }
    let table: string = find_ramp(attr)
    if table.len() > 0 {
        // Suggest the author's own value back only when it is a real step —
        // `gap="2"` means `gap-2`, but `gap="red"` does not mean `gap-red`
        // and printing that would send them somewhere else wrong.
        var suggestion: string = example_step(attr, table)
        if has_step(table, step_name(value)) {
            suggestion = value
        }
        return err(
            "{span.show()}: '{markup(attr)}' takes a step, not a string — write '{markup(attr)}-{suggestion}', or {markup(attr)}=\{..\}",
            "unexpected_value")
    }
    let taken: string = value_takes(attr)
    if taken.len() > 0 {
        return err(
            "{span.show()}: '{markup(attr)}' takes a {taken}, not a string — write {markup(attr)}=\{..\}",
            "unexpected_value")
    }
    return unknown_attr(attr, span)
}

/// A name and a Beans expression: `w={my_width}` becomes `.w(my_width)`.
///
/// bx does not look inside `code`. beansc will, and it will say something
/// more useful about it than bx could.
pub fn expr_call(attr: string, code: string, span: Span) -> Result<string> {
    if value_takes(attr).len() > 0 {
        return ok(".{attr}({code})")
    }
    for row: EventRow in Tables.events {
        if row.method == attr {
            return handler_call(row.event, code, span)
        }
    }
    if Tables.flags.contains(attr) {
        return err(
            "{span.show()}: '{markup(attr)}' takes no value — write it on its own",
            "unexpected_value")
    }
    for row: EventRow in Tables.events {
        if row.event == attr {
            return err(
                "{span.show()}: '{markup(attr)}' is an event — write on:{markup(attr)}=\{..\}",
                "unknown_attr")
        }
    }
    return unknown_attr(attr, span)
}

/// An event and a Beans expression: `on:click={..}` becomes `.on_click(..)`.
pub fn handler_call(event: string, code: string, span: Span) -> Result<string> {
    for row: EventRow in Tables.events {
        if row.event == event {
            return event_row_call(row, code, span)
        }
    }
    for row: EventRow in Tables.events {
        if row.method == event {
            return event_row_call(row, code, span)
        }
    }
    let near: string = nearest_name(event, event_names())
    if near.len() == 0 {
        return err(
            "{span.show()}: no event named '{markup(event)}'",
            "unknown_event")
    }
    return err(
        "{span.show()}: no event named '{markup(event)}' — did you mean '{markup(near)}'?",
        "unknown_event")
}

// ------------------------------------------------------------------- shaping

/// The call one text row produces, once the colour has resolved.
fn text_row_call(row: TextRow, value: string, span: Span) -> Result<string> {
    if row.kind == "string" {
        return ok(".{row.method}({beans_string(value)})")
    }
    let word: int = colour_or_error(value, span)?
    let rgba: string = rgba_expr(word)
    if row.kind == "fill" {
        return ok(".{row.method}(style.Fill.of_rgba({rgba}))")
    }
    if row.kind == "rgba" {
        return ok(".{row.method}({rgba})")
    }
    if row.kind == "background" {
        return ok(".{row.method}(color.Background.from_rgba({rgba}))")
    }
    // `hsla`. gpui's `border_color(impl Into<Hsla>)` has no Rgba form in
    // crema, so the conversion is one call on a value that is already a
    // literal — still no name table and no string parse at run time, which is
    // what "resolved at compile time" was protecting.
    return ok(".{row.method}({rgba}.to_hsla())")
}

/// The call one event row produces.
fn event_row_call(row: EventRow, code: string, span: Span) -> Result<string> {
    if row.button {
        let alternative: string = any_form(row.event)
        if alternative.len() > 0 {
            return err(
                "{span.show()}: on:{markup(row.event)} needs a mouse button first, so it cannot come from markup — write on:{markup(alternative)} for any button, or .{row.method}(platform.MouseButton.left, ..) by hand",
                "needs_button")
        }
        return err(
            "{span.show()}: on:{markup(row.event)} needs a mouse button first, so it cannot come from markup — write .{row.method}(platform.MouseButton.left, ..) by hand",
            "needs_button")
    }
    return ok(".{row.method}({code})")
}

/// The `any_`-prefixed sibling of a button event, when the table has one:
/// `mouse_down` has `any_mouse_down`, `mouse_up_out` has nothing.
fn any_form(event: string) -> string {
    let candidate: string = "any_{event}"
    for row: EventRow in Tables.events {
        if row.event == candidate {
            return candidate
        }
    }
    return ""
}

/// The listener signature an event hands its handler, for a diagnostic or a
/// doc: `fn(element.ClickEvent, element.Frame, app.App)`.
pub fn event_signature(event: string) -> string {
    for row: EventRow in Tables.events {
        if row.event == event {
            return "fn({row.payload}, element.Frame, app.App)"
        }
    }
    return ""
}

/// The step suffix as a `style` table field name.
///
/// docs/FLUENT.md, "Step names": a step keeps the macro's own suffix with an
/// `s` in front when it starts with a digit, because a Beans name cannot.
/// `neg_` stays in front of that.
///
/// Two separators come in and both leave as `_`. A hyphen, because the
/// markup writes `neg-4` where Beans writes `neg_s4` — that is the only
/// hyphen a step can carry, since bx/parse.b splits the attribute at the
/// last hyphen that is not a `neg` marker. And a slash, because Tailwind
/// spells a fraction `w-1/2` and the parser hands that on verbatim.
///
///     2      -> s2         1p5    -> s1p5
///     1/2    -> s1_2       2xl    -> s2xl
///     full   -> full       neg-4  -> neg_s4
pub fn step_name(step: string) -> string {
    let under: string = step.replace("-", "_").replace("/", "_")
    if under.starts_with("neg_") {
        let rest: string = under.slice(4, under.len())
        return "neg_{digit_prefixed(rest)}"
    }
    return digit_prefixed(under)
}

/// The markup a table field name came from, for a suggestion: `neg_s4` reads
/// back as `neg-4` and `s1_2` as `1/2`, which is what the author has to type.
///
/// The inverse of `step_name` over every field in every table, which
/// tests/probe_bx_attrs.b checks all 207 of. A suggestion that named a step
/// nobody can type would be worse than no suggestion.
pub fn step_markup(field: string) -> string {
    var body: string = field
    var sign: string = ""
    if body.starts_with("neg_") {
        sign = "neg-"
        body = body.slice(4, body.len())
    }
    if body.starts_with("s") {
        let rest: string = body.slice(1, body.len())
        if rest.len() > 0 && is_digit(rest.byte_at(0)) {
            body = rest
        }
    }
    // Whatever `_` is left separates a fraction — `s1_12` is Tailwind's
    // `1/12`. `1p5` carries no separator and comes through untouched.
    return "{sign}{body.replace("_", "/")}"
}

/// An `s` in front of a suffix that starts with a digit.
fn digit_prefixed(suffix: string) -> string {
    if suffix.len() == 0 {
        return suffix
    }
    if is_digit(suffix.byte_at(0)) {
        return "s{suffix}"
    }
    return suffix
}

/// The family and step joined the way a flag is spelled: `flex` + `col` is
/// `flex_col`.
fn joined_name(family: string, step: string) -> string {
    let tail: string = step.replace("-", "_").replace("/", "_")
    return "{family}_{tail}"
}

/// A step written as a whole number, or "" when it is not one. `neg-2` is
/// `-2`, so a negative grid line keeps the markup's own spelling.
fn count_value(step: string) -> string {
    var body: string = step
    var sign: string = ""
    if body.starts_with("neg-") || body.starts_with("neg_") {
        sign = "-"
        body = body.slice(4, body.len())
    }
    if body.len() == 0 {
        return ""
    }
    for i: int in 0..body.len() {
        if !is_digit(body.byte_at(i)) {
            return ""
        }
    }
    return "{sign}{body}"
}

/// A Beans name as the markup spells it: underscores back to hyphens.
pub fn markup(name: string) -> string {
    return name.replace("_", "-")
}

/// A Beans string literal holding exactly `value`.
///
/// `TextAttr.value` arrives with its escapes already resolved (bx/ast.b), so
/// they have to be put back — and a literal brace is `\{`, never `{{`, which
/// is the escape a string-writing routine gets wrong first.
pub fn beans_string(value: string) -> string {
    var parts: List<string> = ["\""]
    for i: int in 0..value.len() {
        let byte: int = value.byte_at(i)
        if byte == 34 {
            parts.push("\\\"")
        } else if byte == 92 {
            parts.push("\\\\")
        } else if byte == 10 {
            parts.push("\\n")
        } else if byte == 13 {
            parts.push("\\r")
        } else if byte == 9 {
            parts.push("\\t")
        } else if byte == 0 {
            parts.push("\\0")
        } else if byte == 123 {
            parts.push("\\\{")
        } else if byte == 125 {
            parts.push("\\\}")
        } else {
            parts.push(value.slice(i, i + 1))
        }
    }
    parts.push("\"")
    return parts.join("")
}

/// The packages the call text this file produces names, so `bx/emit.b` does
/// not have to work it out from the strings.
pub fn attr_imports() -> List<string> {
    let out: List<string> = ["crema.style", "crema.color"]
    return move out
}

// -------------------------------------------------------------- table reads

/// Which table holds `family`'s steps, or "" when it is not a ramp family.
pub fn find_ramp(family: string) -> string {
    for row: RampRow in Tables.ramps {
        if row.family == family {
            return row.table
        }
    }
    return ""
}

/// The declared argument type of a one-argument method, or "" when there is
/// no such method. Ramp and count families are one-argument methods too, so
/// `w={expr}` works alongside `w-4`.
pub fn value_takes(attr: string) -> string {
    for row: ValueRow in Tables.values {
        if row.attr == attr {
            return row.takes
        }
    }
    return ""
}

/// Does `table` carry a step called `field`?
pub fn has_step(table: string, field: string) -> bool {
    if table == "Space" {
        return Tables.space_steps.contains(field)
    }
    if table == "Gap" {
        return Tables.gap_steps.contains(field)
    }
    if table == "Stroke" {
        return Tables.stroke_steps.contains(field)
    }
    return false
}

/// Every step in `table`. A copy, because a `List` is move-only and the
/// static has to keep its own; this is the suggestion path, not a hot one.
pub fn steps_of(table: string) -> List<string> {
    if table == "Space" {
        return Tables.space_steps.clone()
    }
    if table == "Gap" {
        return Tables.gap_steps.clone()
    }
    if table == "Stroke" {
        return Tables.stroke_steps.clone()
    }
    let empty: List<string> = []
    return move empty
}

/// Every event name, for a suggestion.
pub fn event_names() -> List<string> {
    var out: List<string> = []
    for row: EventRow in Tables.events {
        out.push(row.event)
    }
    return move out
}

/// Every attribute a tag can carry, for a suggestion: the flags, the ramp
/// families, the counted families, the string attributes and every other
/// one-argument method.
pub fn attr_names() -> List<string> {
    var out: List<string> = Tables.flags.clone()
    for row: RampRow in Tables.ramps {
        out.push(row.family)
    }
    for name: string in Tables.counts {
        out.push(name)
    }
    for row: TextRow in Tables.texts {
        if !out.contains(row.attr) {
            out.push(row.attr)
        }
    }
    for row: ValueRow in Tables.values {
        if !out.contains(row.attr) {
            out.push(row.attr)
        }
    }
    return move out
}

// -------------------------------------------------------------- diagnostics

/// "no attribute named X — did you mean Y?", which is the difference between
/// a markup language people use and one they fight.
pub fn unknown_attr(name: string, span: Span) -> Result<string> {
    let near: string = nearest_name(name, attr_names())
    if near.len() == 0 {
        return err(
            "{span.show()}: no attribute named '{markup(name)}'",
            "unknown_attr")
    }
    // A suggestion that renders identically to the input is worse than none:
    // "no attribute named 'border-color' — did you mean 'border-color'?" tells
    // the reader their eyes are wrong. It happens when a caller hands this
    // function a markup-form name (`border-color`) instead of the underscored
    // form the tables key on — `bx/parse.b` always underscores first, so
    // markup cannot reach it, but the bx API is public and a caller can.
    if markup(near) == markup(name) {
        return err(
            "{span.show()}: no attribute named '{markup(name)}' — the tables key on '{near}', so pass the underscored name",
            "unknown_attr")
    }
    return err(
        "{span.show()}: no attribute named '{markup(name)}' — did you mean '{markup(near)}'?",
        "unknown_attr")
}

/// The candidate nearest `name`, or "" when nothing is near enough.
///
/// The gate matters as much as the distance. Without one every typo gets a
/// suggestion, including the ones that are not typos: `bg="octarine"` would
/// be told it meant `orange` and that is worse than saying nothing. One edit
/// per three characters, plus one, is loose enough for `rd` -> `red` and
/// tight enough to stay quiet on a word nobody misspelled.
///
/// Ties go to the earlier candidate, and every candidate list here is built
/// in a fixed order — the tables are `List`s and the palette is an
/// `OrderedMap` — so two backends cannot pick different names and disagree
/// about a golden file.
pub fn nearest_name(name: string, candidates: List<string>) -> string {
    let limit: int = 1 + (name.len() / 3)
    var best: string = ""
    var best_distance: int = limit + 1
    for candidate: string in candidates {
        let gap: int = length_gap(name, candidate)
        if gap <= limit {
            let distance: int = edit_distance(name, candidate)
            if distance < best_distance {
                best_distance = distance
                best = candidate
            }
        }
    }
    if best_distance > limit {
        return ""
    }
    return best
}

/// How far apart two lengths are — a free lower bound on the edit distance,
/// which keeps the O(n*m) loop off the 391 palette entries that cannot win.
fn length_gap(a: string, b: string) -> int {
    let difference: int = a.len() - b.len()
    if difference < 0 {
        return -difference
    }
    return difference
}

/// Levenshtein distance in bytes.
///
/// Two rows rather than a full matrix, and a counted `for` rather than a
/// `while`, because Beans has one loop keyword and five shapes and `while`
/// is not one of them (spec/SYNTAX.md, "Control flow").
pub fn edit_distance(a: string, b: string) -> int {
    let rows: int = a.len()
    let columns: int = b.len()
    if rows == 0 {
        return columns
    }
    if columns == 0 {
        return rows
    }
    var previous: List<int> = []
    for column: int in 0..(columns + 1) {
        previous.push(column)
    }
    for row: int in 0..rows {
        var current: List<int> = [row + 1]
        for column: int in 0..columns {
            var cost: int = 1
            if a.byte_at(row) == b.byte_at(column) {
                cost = 0
            }
            var best: int = previous[column + 1] + 1
            let insert: int = current[column] + 1
            if insert < best {
                best = insert
            }
            let substitute: int = previous[column] + cost
            if substitute < best {
                best = substitute
            }
            current.push(best)
        }
        previous = move current
    }
    return previous[columns]
}

/// Is this byte an ASCII digit? `string.byte_at` answers an `int`, not a
/// `byte`, so this takes one (RULES.md).
pub fn is_digit(byte: int) -> bool {
    return byte >= 48 && byte <= 57
}

// ------------------------------------------------------------- the proof

/// Every call the tables can produce, one Beans statement each, on a
/// receiver called `d`.
///
/// The lines come from `flag_call`, `ramp_call`, `text_call`, `expr_call`
/// and `handler_call` — the same functions the emitter uses — so what gets
/// compiled is the text bx actually writes, not a second copy of the tables
/// that could drift from the first.
///
/// The three button events are the exception and are written out longhand:
/// `.on_mouse_down(button, listener)` cannot be reached from `on:x={..}` at
/// all, so there is no emitter path to borrow. The method still has to exist.
///
/// A caller should check the length against the tables before trusting a
/// green build — a generator that emitted nothing would compile perfectly.
pub fn proof_calls() -> List<string> {
    let span: Span = Span.at(0, 0)
    var out: List<string> = []
    for name: string in Tables.flags {
        push_call(out, flag_call(name, span))
    }
    for row: RampRow in Tables.ramps {
        push_call(out, ramp_call(row.family, first_step_markup(row.table), span))
    }
    for name: string in Tables.counts {
        push_call(out, ramp_call(name, "1", span))
    }
    push_steps(out, "Space")
    push_steps(out, "Gap")
    push_steps(out, "Stroke")
    for row: ValueRow in Tables.values {
        push_call(out, expr_call(row.attr, row.sample, span))
    }
    for row: EventRow in Tables.events {
        if row.button {
            let listener: string = listener_sample(row.payload)
            out.push("d.{row.method}(platform.MouseButton.left, {listener})")
        } else {
            push_call(out, handler_call(row.event, listener_sample(row.payload), span))
        }
    }
    for row: TextRow in Tables.texts {
        push_call(out, text_call(row.attr, text_sample(row.kind), span))
    }
    return move out
}

/// A complete `package main` program that runs `calls` and says how many it
/// ran, ready for `beansc run`.
pub fn proof_program(calls: List<string>) -> string {
    var out: List<string> = []
    out.push("// GENERATED by bx.proof_program — do not edit, do not check in.")
    out.push("//")
    out.push("// One statement per entry in bx/attrs.b's tables, on a real Div. It")
    out.push("// exists to be compiled: a table naming a method or a step that crema")
    out.push("// does not have cannot produce this file, and beansc names what is")
    out.push("// missing. See bx/attrs.b, \"proving the tables\".")
    out.push("")
    out.push("package main")
    out.push("")
    for name: string in proof_imports() {
        out.push("import {name}")
    }
    out.push("")
    out.push("fn main() \{")
    out.push("    let d: element.Div = element.div()")
    for line: string in calls {
        out.push("    {line}")
    }
    let total: int = calls.len()
    out.push("    io.println(\"proof ok: {total} calls\")")
    out.push("\}")
    out.push("")
    return out.join("\n")
}

/// The packages the proof program needs. `attr_imports()` is the emitted
/// text's own two; the rest are what the sample arguments name.
pub fn proof_imports() -> List<string> {
    var out: List<string> = ["std.io", "crema.element"]
    for name: string in attr_imports() {
        out.push(name)
    }
    out.push("crema.geo")
    out.push("crema.input")
    out.push("crema.app")
    out.push("crema.platform")
    return move out
}

/// One call per step in `table`, through the first family that uses it.
fn push_steps(out: List<string>, table: string) {
    let family: string = first_family(table)
    let span: Span = Span.at(0, 0)
    for field: string in steps_of(table) {
        push_call(out, ramp_call(family, step_markup(field), span))
    }
}

/// Add one emitted call to the proof, or a line that cannot compile when the
/// table refused to produce one. A silent skip would turn a broken table into
/// a green build.
fn push_call(out: List<string>, produced: Result<string>) {
    match produced {
        ok(text) => { out.push("d{text}") },
        err(e) => { out.push("BX_TABLE_REFUSED_TO_EMIT") },
    }
}

/// The first family that draws its steps from `table`.
fn first_family(table: string) -> string {
    for row: RampRow in Tables.ramps {
        if row.table == table {
            return row.family
        }
    }
    return ""
}

/// The first step of `table`, spelled the way markup spells it.
fn first_step_markup(table: string) -> string {
    let steps: List<string> = steps_of(table)
    match steps.first() {
        some(field) => { return step_markup(field) },
        none => {},
    }
    return ""
}

/// A closure of the right shape for an event that hands over `payload`.
fn listener_sample(payload: string) -> string {
    return "fn(event: {payload}, frame: element.Frame, running: app.App) \{ \}"
}

/// A value a text attribute of this kind accepts.
fn text_sample(kind: string) -> string {
    if kind == "string" {
        return "x"
    }
    return "black"
}
