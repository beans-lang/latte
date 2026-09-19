// What a component renders into.
package compose

import latte.controls
import latte.platform
import latte.input
import latte.layout
import latte.geometry
import std.reflect
import latte.visual

/// Collects a render into a tree of `Element`s.
///
/// This is the method ABI the `.bx` markup compiler emits against, and it is
/// deliberately something a person can also write by hand. Markup is sugar
/// over these calls, not a second way of saying the same thing — so a
/// component written by hand and one generated from markup produce identical
/// trees, and the framework has one input to test.
///
/// ```beans
/// pub override fn render(into: component.Builder) {
///     into.open("VStack")
///     into.number("spacing", 12.0)
///         into.open("Label")
///         into.text(self.title)
///         into.close()
///         into.open("Button")
///         into.text("Buy")
///         into.on("click", fn(event: input.UiEvent) { self.buy() })
///         into.close()
///     into.close()
/// }
/// ```
///
/// ### Why nothing here answers `Result`
///
/// A render body is a description, and threading `?` through forty lines of
/// description would bury the description. So mistakes — an unknown tag, a
/// misspelled attribute, a `close` with nothing open — are recorded as faults
/// and `finish()` answers them all at once. The author sees every problem in
/// their markup in one message instead of the first one, and a render that
/// went wrong never reaches the platform.
pub class Builder {
    open_stack: List<Element> = []
    root: Option<Element> = none
    faults: List<string> = []

    /// Who renders child components, when this builder is building a real
    /// mount. `none` when nothing is composing — a builder used to compare two
    /// renders in a test, say — and `child()` then reports it rather than
    /// quietly dropping the child.
    composer: Option<Composer> = none

    /// The prefix every child key is qualified by while a fragment body is
    /// running, or `""` outside every fragment. `fragment` maintains it; see
    /// the note there for why it exists and how it composes with the mount's
    /// own scoping.
    fragment_scope: string = ""

    pub fn init() {}

    /// Framework use: the mount that will render child components.
    pub fn set_composer(who: Composer) {
        self.composer = some(who)
    }

    // ---- structure ----

    /// Opens a widget. Everything set until the matching `close` belongs to
    /// it, and any element opened in between becomes its child.
    pub fn open(tag: string) {
        match Vocabulary.kind_of(tag) {
            none => {
                let gone: string = Vocabulary.retired(tag)
                if gone != "" {
                    self.faults.push(gone)
                } else {
                    self.faults.push("<{tag}> is not a widget latte knows")
                }
                // A placeholder still goes on the stack, so the `close` that
                // follows is not reported as a second, imaginary mistake.
                self.push(new Element(controls.WidgetKind.container, tag))
            }
            some(kind) => {
                var element: Element = new Element(kind, tag)
                element.arranger = Vocabulary.arranger_of(tag)
                self.push(element)
            }
        }
    }

    /// Gives the element being built an identity that survives reordering.
    pub fn key(value: string) {
        match self.current() {
            none => { self.faults.push("key=\"{value}\" with no element open") }
            some(element) => { element.key = value }
        }
    }

    /// Closes the element being built.
    pub fn close() {
        if self.open_stack.len() == 0 {
            self.faults.push("close with nothing open")
            return
        }
        let finished: Element = self.open_stack.remove(self.open_stack.len() - 1)
        self.check_spec(finished)
        if self.open_stack.len() == 0 {
            match self.root {
                none => { self.root = some(finished) }
                some(already) => {
                    self.faults.push("a render has two roots: <{already.tag}> and <{finished.tag}>")
                }
            }
            return
        }
        self.open_stack[self.open_stack.len() - 1].add(finished)
    }

    /// Rules that need every attribute in first, checked as the element
    /// closes so they may be written in any order.
    fn check_spec(element: Element) {
        let low: f64 = element.spec.hide_below
        let high: f64 = element.spec.hide_above
        if low >= 0.0 && high >= 0.0 && low >= high {
            self.fault_once("<{element.tag}> is hidden at every width: hide_below={low} is not under hide_above={high}")
        }
        if element.flexed && element.tuned {
            self.fault_once("<{element.tag}> writes flex beside grow, shrink or basis, and flex is the three at once — write one or the other")
        }
        // A gap between lines on a run that never breaks into any.
        match self.flexing_run(element) {
            some(run) => {
                if !run.wraps() && run.line_spacing() > 0.0 {
                    self.fault_once("<{element.tag}> has line_spacing and does not wrap, so it has no lines to space — write wrap on it")
                }
            }
            none => {}
        }
        // A tag with children and nothing that places them leaves every one at
        // the corner, unmeasured. Say so instead.
        if element.count() > 0 {
            match element.arranger {
                none => { self.fault_once("<{element.tag}> holds {element.count()} children and lays nothing out — put them in a <Box> or a <VStack>") }
                some(arranger) => {}
            }
        }
        // Two insets and a size on one axis decide it three times.
        if element.spec.left >= 0.0 && element.spec.right >= 0.0 && element.spec.sizes(layout.Direction.horizontal) {
            self.fault_once("<{element.tag}> has x, right and a width, and its width is decided three times — drop one")
        }
        if element.spec.top >= 0.0 && element.spec.bottom >= 0.0 && element.spec.sizes(layout.Direction.vertical) {
            self.fault_once("<{element.tag}> has y, bottom and a height, and its height is decided three times — drop one")
        }
    }

    /// The flexing run this element arranges its children with, or `none`.
    fn flexing_run(element: Element) -> Option<layout.FlexLayout> {
        match element.arranger {
            none => { return none }
            some(arranger) => {
                match arranger as? layout.FlexLayout {
                    some(run) => { return some(run) }
                    none => { return none }
                }
            }
        }
    }

    /// A fault checked on more than one attribute lands once.
    fn fault_once(message: string) {
        if self.faults.len() > 0 && self.faults[self.faults.len() - 1] == message { return }
        self.faults.push(message)
    }

    // ---- values ----

    /// The text this control shows.
    pub fn text(value: string) {
        match self.current() {
            none => { self.faults.push("text with no element open") }
            some(element) => {
                if visual.is_tag(element.tag) && element.tag != "Path" && element.tag != "ResourceImage" {
                    self.faults.push("<{element.tag}> does not take source text")
                } else { element.set(Attribute.of_text(value)) }
            }
        }
    }

    /// Names the current control for accessibility without changing its visible text.
    pub fn a11y_label(value: string) {
        match self.current() {
            none => { self.faults.push("a11y_label with no element open") }
            some(element) => { element.set(Attribute.of_a11y_label(value)) }
        }
    }

    /// A typed choice list for ComboBox and Segmented widgets.
    pub fn items(values: List<string>) {
        match self.current() {
            none => { self.faults.push("items with no element open") }
            some(element) => {
                if element.tag != "ComboBox" && element.tag != "Segmented" {
                    self.faults.push("<{element.tag}> has no items")
                    return
                }
                element.set(Attribute.of_items(values))
            }
        }
    }
    pub fn labels(values: List<string>) {
        match self.current() {
            none => { self.faults.push("labels with no element open") }
            some(element) => {
                if element.tag != "TabView" { self.faults.push("<{element.tag}> has no labels"); return }
                element.set(Attribute.of_labels(values))
            }
        }
    }
    pub fn columns(values: List<string>) {
        match self.current() {
            none => { self.faults.push("columns with no element open") }
            some(element) => {
                if element.tag != "Table" { self.faults.push("<{element.tag}> has no typed columns"); return }
                element.set(Attribute.of_columns(values))
            }
        }
    }
    pub fn column_widths(values: List<f64>) {
        match self.current() {
            none => { self.faults.push("column_widths with no element open") }
            some(element) => {
                if element.tag != "Table" { self.faults.push("<{element.tag}> has no column widths"); return }
                element.set(Attribute.of_column_widths(values))
            }
        }
    }
    pub fn table_source(value: controls.TableRows) {
        match self.current() {
            none => { self.faults.push("source with no element open") }
            some(element) => {
                if element.tag != "Table" { self.faults.push("<{element.tag}> has no table source"); return }
                element.set(Attribute.of_table_source(value))
            }
        }
    }
    pub fn editable_when(value: TableEditRule) {
        match self.current() {
            none => { self.faults.push("editable_when with no element open") }
            some(element) => {
                if element.tag != "Table" { self.faults.push("<{element.tag}> has no table edit policy"); return }
                element.set(Attribute.of_table_edit_policy(value))
            }
        }
    }

    /// Refuses a property this control has not got, and says which do.
    /// `true` when refused. One spelling for three call sites.
    fn refuse_unless_carried(element: Element, name: string) -> bool {
        match visual.kind_of(element.tag) {
            some(kind) => {
                if visual.carries(kind, name) { return false }
                self.faults.push("<{element.tag}> has no {name}")
                return true
            }
            none => {}
        }
        if Vocabulary.carries(element.kind, name) { return false }
        self.faults.push("<{element.tag}> has no {name} — {Vocabulary.who_carries(name)}")
        return true
    }

    /// A true/false property: `enabled`, `hidden`, `checked`, `editable`.
    pub fn flag(name: string, value: bool) {
        match self.current() {
            none => { self.faults.push("{name} with no element open") }
            some(element) => {
                // `hidden` leaves the layout, not just the screen: the sheet
                // hides the control as it culls it, so no property is written.
                if name == "hidden" {
                    if self.refuse_unless_carried(element, name) { return }
                    element.spec.hidden = value
                    return
                }
                // `wrap` is a stack's own: it breaks the run into lines.
                if name == "wrap" {
                    match self.flexing_run(element) {
                        some(run) => { run.set_wrap(value) }
                        none => { self.faults.push("<{element.tag}> does not run its children, so it cannot wrap — write wrap on a <VStack> or <HStack>") }
                    }
                    return
                }
                let property: int = Vocabulary.property_of(name)
                if property < 0 {
                    self.faults.push("<{element.tag}> has no attribute called '{name}'")
                    return
                }
                if self.refuse_unless_carried(element, name) { return }
                element.set(Attribute.of_flag(property, value))
            }
        }
    }

    /// A numeric property, or one of the layout numbers — `spacing`, `padding`,
    /// `grow`, `shrink`, `basis`, `margin`, `width`, `height` and their per-edge forms.
    pub fn number(name: string, value: f64) {
        match self.current() {
            none => { self.faults.push("{name} with no element open") }
            some(element) => {
                if Vocabulary.is_layout_name(name) {
                    self.layout_number(element, name, value, self.parent_of_open())
                    return
                }
                let property: int = Vocabulary.property_of(name)
                if property < 0 {
                    self.faults.push("<{element.tag}> has no attribute called '{name}'")
                    return
                }
                if self.refuse_unless_carried(element, name) { return }
                if Vocabulary.kind_of_property(name) == AttributeKind.real {
                    element.set(Attribute.of_real(property, value))
                } else {
                    element.set(Attribute.of_whole(property, value as int))
                }
            }
        }
    }

    /// A named choice: `align`, `justify`.
    pub fn word(name: string, value: string) {
        match self.current() {
            none => { self.faults.push("{name} with no element open") }
            some(element) => {
                if name == "align" || name == "align_self" {
                    match Vocabulary.align_of(value) {
                        none => { self.faults.push("{name}=\"{value}\" is not one of start, center, end, stretch") }
                        some(mode) => {
                            if name == "align" {
                                self.set_align(element, mode, self.parent_of_open())
                            } else {
                                self.set_own_align(element, mode, self.parent_of_open(), name)
                            }
                        }
                    }
                    return
                }
                if name == "justify" {
                    match Vocabulary.justify_of(value) {
                        none => { self.faults.push("justify=\"{value}\" is not a justification latte knows") }
                        some(mode) => { self.set_justify(element, mode) }
                    }
                    return
                }
                if name == "columns" {
                    self.set_columns(element, value)
                    return
                }
                // A size by the job it does, which is the only way a size
                // follows the reader's own text setting.
                if name == "font_role" {
                    if self.refuse_unless_carried(element, name) { return }
                    match Vocabulary.font_role_of(value) {
                        none => { self.faults.push(font_role_refusal(value)) }
                        some(role) => {
                            match role.size() {
                                err(problem) => { self.faults.push(problem.msg) }
                                ok(points) => {
                                    element.set(Attribute.of_real(platform.P_FONT_SIZE, points))
                                }
                            }
                        }
                    }
                    return
                }
                if name == "transition_easing" {
                    if self.refuse_unless_carried(element, name) { return }
                    let code: int = visual.easing_code(value)
                    if code < 0 { self.faults.push("transition_easing must be linear or ease_in_out") }
                    else { element.set(Attribute.of_whole(visual.TRANSITION_EASING, code)) }
                    return
                }
                if name == "stroke_cap" {
                    if self.refuse_unless_carried(element, name) { return }
                    let code: int = visual.cap_code(value)
                    if code < 0 { self.faults.push("stroke_cap must be butt, round or square") }
                    else { element.set(Attribute.of_whole(visual.STROKE_CAP, code)) }
                    return
                }
                if name == "stroke_join" {
                    if self.refuse_unless_carried(element, name) { return }
                    let code: int = visual.join_code(value)
                    if code < 0 { self.faults.push("stroke_join must be miter, round or bevel") }
                    else { element.set(Attribute.of_whole(visual.STROKE_JOIN, code)) }
                    return
                }
                // Parsed here rather than in the markup compiler, so `#abc`
                // means one thing in `<ColorWell />` and in a shader.
                if Vocabulary.is_colour(name) {
                    if self.refuse_unless_carried(element, name) { return }
                    match controls.Rgba.of_hex(value) {
                        err(problem) => { self.faults.push(problem.msg) }
                        ok(shade) => {
                            element.set(Attribute.of_whole(Vocabulary.property_of(name),
                                                           shade.packed()))
                        }
                    }
                    return
                }
                self.faults.push("<{element.tag}> has no attribute called '{name}'")
            }
        }
    }

    /// Subscribes to an event by its markup name — `click`, `change`,
    /// `commit`, `focus`.
    pub fn on(name: string, action: fn(input.UiEvent)) {
        match self.current() {
            none => { self.faults.push("on:{name} with no element open") }
            some(element) => {
                match Vocabulary.event_of(name) {
                    none => { self.faults.push("on:{name} is not an event latte raises") }
                    some(kind) => { element.listen(kind, action) }
                }
            }
        }
    }

    /// Subscribes by kind, for a component written by hand that would rather
    /// name the event than spell it.
    pub fn on_kind(kind: input.EventKind, action: fn(input.UiEvent)) {
        match self.current() {
            none => { self.faults.push("{kind.name()} handler with no element open") }
            some(element) => { element.listen(kind, action) }
        }
    }

    /// Shows a component the parent already holds.
    ///
    /// Beans has no overloading, so this and `child<T>` are two names for two
    /// ownerships: here the parent owns the instance, usually in a field;
    /// there the mount does, because markup names a type rather than an
    /// object. Both keep their state across renders.
    ///
    /// `key` names this child among its siblings and must be unique within the
    /// component that wrote it. It is what lets the child keep its state
    /// across renders: the same key is the same child, holding whatever it was
    /// holding, even when the markup around it moved.
    ///
    /// The parent normally keeps the child in a field, which is where its
    /// state naturally lives:
    ///
    /// ```beans
    /// total: SubTotal = new SubTotal()
    /// pub override fn render(into: component.Builder) {
    ///     into.open("VStack")
    ///     into.child("total", self.total)
    ///     into.close()
    /// }
    /// ```
    pub fn show(key: string, sub: Component) -> Placement {
        match self.composer {
            none => {
                self.faults.push("child \"{key}\" cannot be rendered: this builder is not attached to a mount")
                return Placement.nowhere(self)
            }
            some(who) => {
                // The composer is handed the qualified key and the fault names
                // the one the author wrote, which is why the qualifying
                // happens here and not inside the mount.
                match who.compose(self.scoped_key(key), sub) {
                    ok(subtree) => { return self.place(subtree, some(reflect.value(sub).type())) }
                    err(problem) => {
                        self.faults.push("child \"{key}\": {problem.msg}")
                        return Placement.nowhere(self)
                    }
                }
            }
        }
    }

    /// Shows a component of type `T` here, building it the first time.
    ///
    /// What markup emits. `<Price drink={self.drink} />` becomes
    ///
    /// ```beans
    /// into.child<Price>("c4", fn(c: Price) { c.drink = self.drink })
    /// ```
    ///
    /// The `Placement` answered is where `<Price margin_top={8} />` lands:
    /// `.number("margin_top", 8.0)` chained on the call, after the child rendered.
    ///
    /// The mount owns the instance and hands the same one back on every later
    /// render, so the child keeps its state; `setup` runs each time, which is
    /// what carries a changed parameter down.
    ///
    /// Generic, and on a concrete class rather than on the `Composer`
    /// interface, because Beans refuses generic interface methods. The
    /// interface answers a boxed value and the downcast happens here — legal
    /// because a `reflect.Value` is the one source `as?` may narrow to an
    /// instantiation.
    pub fn child<T>(key: string, setup: fn(T)) -> Placement {
        match self.composer {
            none => {
                self.faults.push("<{type_of(T).name()}> cannot be rendered: this builder is not attached to a mount")
                return Placement.nowhere(self)
            }
            some(who) => {
                // The same qualification `show` applies below, so the instance
                // this obtains and the subtree that gets composed are one
                // child and not two.
                match who.obtain(self.scoped_key(key), type_of(T)) {
                    err(problem) => {
                        self.faults.push("<{type_of(T).name()}>: {problem.msg}")
                        return Placement.nowhere(self)
                    }
                    ok(boxed) => {
                        match boxed as? T {
                            none => {
                                self.faults.push("<{type_of(T).name()}> came back as something else")
                                return Placement.nowhere(self)
                            }
                            some(built) => {
                                setup(built)
                                match boxed as? Component {
                                    none => {
                                        self.faults.push("<{type_of(T).name()}> is not a Component")
                                        return Placement.nowhere(self)
                                    }
                                    some(shown) => { return self.show(key, shown) }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // ---- fragments ----

    /// Places a template this component's parent supplied: what `$slot`
    /// compiles to.
    ///
    /// A fragment is a `fn(Builder)` the parent wrote and the child places.
    /// The body is **written** in the parent's markup — so `self` inside it is
    /// the parent, and it reads the parent's fields — and **run** here,
    /// against this builder, so the controls it describes land wherever the
    /// child put its `$slot`. That split is the whole feature: a `<Tile>`
    /// decides where its content goes and the screen around it decides what
    /// the content is.
    ///
    /// ### `site` is load-bearing, not decoration
    ///
    /// `site` names **where this placement is** — which `$slot` of this render,
    /// and which turn of the `$for` around it. latte-bx writes `"2"` for the
    /// third placement in a render and `"2.{row}"` for one inside a loop, the
    /// same two-part identity it gives a component tag. It is what makes
    /// placing one template at two sites — or on two rows — produce two
    /// independent children rather than one shared between them, and it is
    /// needed because **a fragment body restarts key numbering at 0**:
    /// latte-bx emits a fragment body in a counter scope of its own, so the
    /// first component tag inside any fragment body asks for the key `c0` —
    /// which is exactly what the placing component's own first component tag
    /// asks for.
    ///
    /// So every child key written while the body runs is qualified with
    /// `$f{site}/`. A `$` can never begin a key latte-bx generates — those
    /// are `c{n}` and `c{n}.{row}` — so a qualified key can never collide with
    /// an unqualified one, and two placements differ because their site does.
    /// It is the move `$for` already makes with the row index, which is a
    /// suffix for the same reason: a counter that restarts needs something
    /// from outside it to tell its numbers apart.
    ///
    /// A string rather than a number, and the loop is why: a `$slot` in a
    /// `$for` body is *one* emitted call run once per row, so the number in it
    /// is the same on every turn and only the row tells the turns apart. A
    /// number could carry the site or the row and not both.
    ///
    /// ### Two layers of scoping, and why neither covers the other
    ///
    /// `Mount.scoped_key` qualifies a key by the component whose `render` is
    /// running, because latte-bx numbers from 0 in every render it writes.
    /// This qualifies a key by the fragment placement it was asked for inside,
    /// because latte-bx numbers from 0 *again* inside every fragment body.
    /// The mount cannot do this one: a fragment body is a closure it never
    /// sees, called from inside a render it has already entered. The builder
    /// cannot do the mount's: it does not know which component it is building
    /// for, and must not — it is the same object whether it is building a real
    /// window or a tree for a test. The mount applies its layer to whatever
    /// this hands it, so a component inside the first `$slot` of a `<Tile>`
    /// ends up under `<the tile>/$f0/c0`.
    ///
    /// ### Element keys are deliberately *not* qualified
    ///
    /// `key=` on a control is not identity for state; it is the name
    /// `Stage.control` and `Stage.widget` look a control up by once it is
    /// real. Qualifying it would make that name unreachable — the author
    /// writes `key="plot"` and would have to ask for `$f0/plot`, a string they
    /// have no way to know. So two placements of one body do produce two
    /// siblings carrying one key: the differ matches keyed siblings
    /// first-untaken, which leaves each in its own place, and `Stage.control`
    /// answers the first of them.
    pub fn fragment(site: string, body: fn(Builder)) {
        let outer: string = self.fragment_scope
        self.fragment_scope = "{outer}$f{site}/"
        body(self)
        self.fragment_scope = outer
    }

    /// A child's key, qualified by the fragment placement it was asked for
    /// inside. Outside every fragment it is the key itself, so nothing that
    /// places no fragment is affected at all.
    fn scoped_key(key: string) -> string {
        if self.fragment_scope == "" { return key }
        return "{self.fragment_scope}{key}"
    }

    /// Splices an already-built subtree in as a child.
    ///
    /// This is how one component shows another. The child's own render
    /// produced the subtree — or, when nothing about the child changed, the
    /// subtree it produced last time, unchanged and not re-rendered.
    pub fn embed(subtree: Element) -> Placement {
        return self.place(subtree, none)
    }

    /// `embed`, knowing the class the subtree came from — what `show` and
    /// `child` know, and what a placement checks a field name against.
    fn place(subtree: Element, kind: Option<reflect.Type>) -> Placement {
        if self.open_stack.len() == 0 {
            match self.root {
                none => { self.root = some(subtree) }
                some(already) => {
                    self.faults.push("a render has two roots: <{already.tag}> and <{subtree.tag}>")
                    return Placement.nowhere(self)
                }
            }
            return new Placement(self, some(subtree), kind)
        }
        let parent: Element = self.open_stack[self.open_stack.len() - 1]
        self.settle(subtree, parent)
        parent.add(subtree)
        return new Placement(self, some(subtree), kind)
    }

    /// Framework use, from `Placement`: `name={value}` on a component tag,
    /// applied to the child's root inside the element open here.
    pub fn place_number(root: Element, kind: Option<reflect.Type>, name: string, value: f64) {
        if !self.placement_allowed(root, kind, name) { return }
        self.layout_number(root, name, value, self.current())
        // The root closed in its own render, before the tag's word landed.
        self.check_spec(root)
    }

    /// Framework use, from `Placement`: `align="..."` on a component tag. The
    /// one word a root asks of its run, and on a component tag always its own.
    pub fn place_word(root: Element, kind: Option<reflect.Type>, name: string, value: string) {
        if !self.placement_allowed(root, kind, name) { return }
        match Vocabulary.align_of(value) {
            none => { self.faults.push("{name}=\"{value}\" is not one of start, center, end, stretch") }
            some(mode) => { self.set_own_align(root, mode, self.current(), name) }
        }
    }

    /// Whether `name` may be written on a component tag whose root is `root`.
    /// Refused by name: the component's own, a control's property, or a field.
    fn placement_allowed(root: Element, kind: Option<reflect.Type>, name: string) -> bool {
        var who: string = root.tag
        match kind {
            none => {}
            some(described) => { who = described.name() }
        }
        if !Vocabulary.is_placement_name(name) {
            if Vocabulary.is_layout_name(name) {
                self.faults.push("{name} is <{who}>'s own to set — a component tag takes what its root asks of the run around it: margin and its edges, grow, shrink, basis, width, height, x, y and align. Give <{who}> a parameter and let its render write {name}")
            } else if Vocabulary.property_of(name) >= 0 || name == "text" {
                self.faults.push("{name} is a control's property, and <{who}> is a component — its render names the control that carries it. Give <{who}> a parameter and let its render write {name}")
            } else {
                self.faults.push("<{who}> has no attribute called '{name}'")
            }
            return false
        }
        // A public field of the same name would be set by the same markup,
        // and one spelling meaning two things is refused rather than decided.
        match kind {
            none => {}
            some(described) => {
                match described.field(name) {
                    none => {}
                    some(field) => {
                        if field.is_public() {
                            self.faults.push("<{who}> has a field called {name}, and {name} on a component tag places the component rather than setting it — rename the field, or write {name} inside <{who}>'s own render")
                            return false
                        }
                    }
                }
            }
        }
        return true
    }

    /// Answers the requirement a component's root element carried out of its
    /// own render, now that the container it landed in is known.
    fn settle(subtree: Element, parent: Element) {
        if subtree.pending == "" { return }
        var answered: bool = false
        match parent.arranger {
            none => {}
            some(arranger) => {
                if subtree.pending == "flex" {
                    match arranger as? layout.FlexLayout {
                        some(run) => { answered = true }
                        none => {}
                    }
                } else {
                    match arranger as? layout.AbsoluteLayout {
                        some(box) => { answered = true }
                        none => {}
                    }
                }
            }
        }
        if !answered {
            self.faults.push(Builder.wrong_parent(subtree.tag, subtree.pending_name, subtree.pending))
        }
        subtree.pending = ""
        subtree.pending_name = ""
    }

    // ---- the result ----

    /// The tree, or every mistake in the render that produced it.
    pub fn finish() -> Result<Element> {
        if self.open_stack.len() > 0 {
            self.faults.push("<{self.open_stack[self.open_stack.len() - 1].tag}> was never closed")
        }
        if self.faults.len() > 0 {
            var joined: string = ""
            for fault: string in self.faults {
                if joined != "" { joined = "{joined}; " }
                joined = "{joined}{fault}"
            }
            return err(joined, "bad_render")
        }
        match self.root {
            none => { return err("a render produced nothing", "empty_render") }
            some(element) => { return ok(element) }
        }
    }

    // ---- internals ----

    fn push(element: Element) {
        self.open_stack.push(element)
    }

    fn current() -> Option<Element> {
        if self.open_stack.len() == 0 { return none }
        return some(self.open_stack[self.open_stack.len() - 1])
    }

    /// The element the open one sits inside, or `none` at a render's root.
    fn parent_of_open() -> Option<Element> {
        if self.open_stack.len() < 2 { return none }
        return some(self.open_stack[self.open_stack.len() - 2])
    }

    /// Whether `around` shares out leftover space.
    static fn flexes(around: Element) -> bool {
        match around.arranger {
            none => { return false }
            some(arranger) => {
                match arranger as? layout.FlexLayout {
                    some(run) => { return true }
                    none => { return false }
                }
            }
        }
    }

    /// Whether `around` places its children at the coordinates they carry,
    /// which is the only thing that reads `x` and `y`.
    static fn places(around: Element) -> bool {
        match around.arranger {
            none => { return false }
            some(arranger) => {
                match arranger as? layout.AbsoluteLayout {
                    some(box) => { return true }
                    none => { return false }
                }
            }
        }
    }

    /// Whether `name` may be written on `element`, inside `container`. With no
    /// container the element is a root still to be embedded, and `embed` answers.
    fn parent_allows(element: Element, container: Option<Element>, name: string, want: string) -> bool {
        match container {
            none => {
                if element.pending != "" && element.pending != want {
                    self.faults.push("<{element.tag}> asks both to be placed and to flex, and no one container does both")
                    return false
                }
                element.pending = want
                element.pending_name = name
                return true
            }
            some(around) => {
                if want == "flex" {
                    if Builder.flexes(around) { return true }
                } else if Builder.places(around) {
                    return true
                }
                self.faults.push(Builder.wrong_parent(element.tag, name, want))
                return false
            }
        }
    }

    /// The one sentence for a requirement no container around it answers,
    /// written once so a deferred refusal reads the same as an immediate one.
    static fn wrong_parent(tag: string, name: string, want: string) -> string {
        if want == "flex" {
            return "{name} is shared out by a run, and <{tag}> sits in a container that does not run its children — write <VStack> or <HStack> around it, or set width/height instead"
        }
        return "{name} is a coordinate a placing container reads, and <{tag}> sits in one that arranges its children itself — write <Box> around it, or use spacing and padding instead"
    }

    // `spacing` and `padding` configure the container's own arrangement;
    // everything else is what this element asks of the run around it. The
    // split matters because the two live on different objects and are read at
    // different moments — one when this element lays its children out, the
    // other when this element's parent lays *it* out.
    fn layout_number(element: Element, name: string, value: f64, container: Option<Element>) {
        if name == "spacing" {
            match element.arranger {
                none => { self.faults.push("<{element.tag}> has no children to space") }
                some(arranger) => {
                    match arranger as? layout.StackLayout {
                        some(run) => { run.set_spacing(value) }
                        none => { self.faults.push("<{element.tag}> does not arrange its children in a run, so it has no spacing") }
                    }
                }
            }
            return
        }
        if name == "line_spacing" {
            // Taken now and checked at `close`, so `wrap` may come after it.
            match self.flexing_run(element) {
                some(run) => { run.set_line_spacing(value) }
                none => { self.faults.push("<{element.tag}> does not run its children, so it has no line spacing — write it on a <VStack wrap> or <HStack wrap>") }
            }
            return
        }
        // A grid's own three. `spacing` is a run's, and a grid is not a run:
        // its two axes are set apart because they are laid out apart.
        if name == "min_column" || name == "max_column" ||
           name == "column_gap" || name == "row_gap" {
            self.set_grid_number(element, name, value)
            return
        }
        if name == "padding" {
            self.set_padding(element, geometry.EdgeInsets.all(value))
            return
        }
        if name == "margin" {
            element.spec.margin = geometry.EdgeInsets.all(value)
            return
        }
        // A per-edge form writes only the edges it names and keeps the rest, in
        // source order: `padding={8} padding_x={16}` is 8 above and below, 16 at the sides.
        let pad_edge: string = Vocabulary.padding_edge(name)
        if pad_edge != "" {
            self.set_padding(element, with_edge(self.padding_of(element), pad_edge, value))
            return
        }
        let margin_edge: string = Vocabulary.margin_edge(name)
        if margin_edge != "" {
            element.spec.margin = with_edge(element.spec.margin, margin_edge, value)
            return
        }
        // `grow`, `shrink` and `basis` are read by a flexing run and by
        // nothing else. An author who writes `grow={1}` inside a plain
        // `<HStack>` gets a control that does not grow and no explanation —
        // the exact silent no-op latte refuses everywhere else — so the
        // parent is checked here, where both markup and hand-written code go
        // through.
        if name == "grow" || name == "shrink" || name == "basis" {
            if !self.parent_allows(element, container, name, "flex") { return }
            if name == "grow" { element.spec.grow = value }
            if name == "shrink" { element.spec.shrink = value }
            if name == "basis" { element.spec.basis = value }
            element.tuned = true
            return
        }
        // `flex={n}` is the web's shorthand: grow n, shrink 1, from nothing.
        if name == "flex" {
            if value <= 0.0 {
                self.faults.push("<{element.tag}> asks for flex={value}, and flex is a share above 0 — leave it off for a child that keeps its size")
                return
            }
            if !self.parent_allows(element, container, name, "flex") { return }
            element.spec.grow = value
            element.spec.shrink = 1.0
            element.spec.basis = 0.0
            element.flexed = true
            return
        }
        // `x` and `y` are read by a placing run and by nothing else, the
        // same shape as `grow` above: an author who writes `x={20}` inside a
        // `<VStack>` would get a control at the run's coordinate and no word
        // about why.
        if name == "x" || name == "y" || name == "right" || name == "bottom" {
            if !self.parent_allows(element, container, name, "place") { return }
            // -1 is every spec's word for no opinion, so an inset starts at 0.
            if value < 0.0 {
                self.faults.push("<{element.tag}> asks for {name}={value}, and an inset from a <Box>'s edge is 0 or more")
                return
            }
            if name == "x" { element.spec.left = value }
            if name == "y" { element.spec.top = value }
            if name == "right" { element.spec.right = value }
            if name == "bottom" { element.spec.bottom = value }
            return
        }
        if name == "width" {
            if self.refuse_double_pin(element, "width", element.spec.width_percent >= 0.0) { return }
            element.spec.min_width = value
            element.spec.max_width = value
            return
        }
        if name == "height" {
            if self.refuse_double_pin(element, "height", element.spec.height_percent >= 0.0) { return }
            element.spec.min_height = value
            element.spec.max_height = value
            return
        }
        if name == "width_percent" || name == "height_percent" {
            if value < 0.0 || value > 100.0 {
                self.faults.push("<{element.tag}> asks for {name}={value}, and a share of the room is 0 to 100")
                return
            }
            if name == "width_percent" {
                if self.refuse_double_pin(element, "width", Builder.pinned(element.spec.min_width, element.spec.max_width)) { return }
                element.spec.width_percent = value
            } else {
                if self.refuse_double_pin(element, "height", Builder.pinned(element.spec.min_height, element.spec.max_height)) { return }
                element.spec.height_percent = value
            }
            return
        }
        if name == "aspect_ratio" {
            if value <= 0.0 {
                self.faults.push("<{element.tag}> asks for aspect_ratio={value}, and a ratio is width over height, above 0")
                return
            }
            element.spec.aspect_ratio = value
            return
        }
        // Hidden by the box around it, judged by the layout on every pass.
        if name == "hide_below" || name == "hide_above" {
            if value < 0.0 {
                self.faults.push("<{element.tag}> asks for {name}={value}, and a width is 0 or more")
                return
            }
            if name == "hide_below" { element.spec.hide_below = value } else { element.spec.hide_above = value }
            return
        }
        // One bound at a time. Later attributes win, so `width={150}` after a
        // `max_width` pins both, and a range that ends up reversed is refused.
        if name == "min_width" || name == "max_width" {
            if name == "min_width" { element.spec.min_width = value } else { element.spec.max_width = value }
            self.check_range(element, "width", element.spec.min_width, element.spec.max_width)
            return
        }
        if name == "min_height" || name == "max_height" {
            if name == "min_height" { element.spec.min_height = value } else { element.spec.max_height = value }
            self.check_range(element, "height", element.spec.min_height, element.spec.max_height)
            return
        }
        self.faults.push("<{element.tag}> has no attribute called '{name}'")
    }

    /// Whether a lower and an upper bound are one number: a pin.
    static fn pinned(lower: f64, upper: f64) -> bool {
        return lower >= 0.0 && upper >= 0.0 && lower == upper
    }

    /// A pinned size and a share of the room both decide the same axis, so
    /// writing both is refused rather than ordered.
    fn refuse_double_pin(element: Element, axis: string, already: bool) -> bool {
        if !already { return false }
        self.faults.push("<{element.tag}> has its {axis} decided twice — {axis} and {axis}_percent both pin it, so write one")
        return true
    }

    /// A minimum above a maximum is no box at all. The solver would fold the
    /// two together silently, so it is refused here, naming both numbers.
    fn check_range(element: Element, axis: string, least: f64, most: f64) {
        if least >= 0.0 && most >= 0.0 && least > most {
            self.faults.push("<{element.tag}> asks for a {axis} of at least {least} and at most {most}, and no box has one — the two bounds are reversed")
        }
    }

    /// What `element` keeps inside its box so far, for a per-edge attribute to
    /// add one edge to. A leaf answers zero, and `set_padding` refuses it a call later.
    fn padding_of(element: Element) -> geometry.EdgeInsets {
        match element.arranger {
            none => { return geometry.EdgeInsets.zero() }
            some(arranger) => { return arranger.padding() }
        }
    }

    fn set_padding(element: Element, insets: geometry.EdgeInsets) {
        match element.arranger {
            none => { self.faults.push("<{element.tag}> has no children to pad") }
            some(arranger) => {
                match arranger as? layout.StackLayout {
                    some(run) => { run.set_padding(insets); return }
                    none => {}
                }
                match arranger as? layout.GridLayout {
                    some(grid) => { grid.set_padding(insets); return }
                    none => {}
                }
                match arranger as? layout.AbsoluteLayout {
                    some(box) => { box.set_padding(insets); return }
                    none => {}
                }
                self.faults.push("<{element.tag}> cannot be padded")
            }
        }
    }

    // `align` on a container is the default for its children; `align` on a
    // child is that child's own. One name, two meanings, told apart by whether
    // the element arranges anything — which is what an author means when they
    // write it.
    fn set_align(element: Element, mode: geometry.Align, container: Option<Element>) {
        match element.arranger {
            none => {}
            some(arranger) => {
                match arranger as? layout.StackLayout {
                    some(run) => { run.set_align(mode); return }
                    none => {}
                }
                match arranger as? layout.GridLayout {
                    some(grid) => { grid.set_align(mode); return }
                    none => {}
                }
                // A box or a holder runs nothing, so `align` can only have
                // meant the element's own place, which has its own name.
                self.faults.push("<{element.tag}> arranges no run to align its children in — write align_self for its own place")
                return
            }
        }
        if self.set_own_align(element, mode, container, "align") { return }
    }

    /// The element's own cross-axis place in `container`, refused where the
    /// container places by insets or fills; `true` when it landed or refused.
    fn set_own_align(element: Element, mode: geometry.Align, container: Option<Element>, name: string) -> bool {
        match container {
            none => {}
            some(around) => {
                if Builder.places(around) {
                    self.faults.push("{name} on <{element.tag}> inside a <{around.tag}>, and a layer is placed by its insets — write x, y, right or bottom")
                    return true
                }
                match around.arranger {
                    none => {}
                    some(arranger) => {
                        match arranger as? layout.FillLayout {
                            some(holder) => {
                                self.faults.push("{name} on <{element.tag}> inside a <{around.tag}>, which hands it the whole box")
                                return true
                            }
                            none => {}
                        }
                        match arranger as? layout.ScrollLayout {
                            some(holder) => {
                                self.faults.push("{name} on <{element.tag}> inside a <{around.tag}>, which hands it the whole width")
                                return true
                            }
                            none => {}
                        }
                    }
                }
            }
        }
        element.spec.align = mode
        return true
    }

    /// The grid this element arranges its children with, or a refusal naming
    /// what `name` belongs to.
    fn grid_of(element: Element, name: string) -> Option<layout.GridLayout> {
        match element.arranger {
            none => { self.faults.push("<{element.tag}> has no children, so it has no {name}") }
            some(arranger) => {
                match arranger as? layout.GridLayout {
                    some(grid) => { return some(grid) }
                    none => { self.faults.push("<{element.tag}> does not arrange its children in rows and columns, so it has no {name} — write <Grid>") }
                }
            }
        }
        return none
    }

    fn set_grid_number(element: Element, name: string, value: f64) {
        match self.grid_of(element, name) {
            none => {}
            some(grid) => {
                if name == "column_gap" { grid.set_column_gap(value); return }
                if name == "row_gap" { grid.set_row_gap(value); return }
                if name == "max_column" {
                    if grid.min_column() > 0.0 && value < grid.min_column() {
                        self.faults.push("<{element.tag}> has a max_column of {value} under its min_column of {grid.min_column()}, and no column could be both")
                        return
                    }
                    grid.set_max_column(value)
                    return
                }
                if grid.max_column() > 0.0 && value > grid.max_column() {
                    self.faults.push("<{element.tag}> has a min_column of {value} over its max_column of {grid.max_column()}, and no column could be both")
                    return
                }
                if grid.column_count() > 0 {
                    self.faults.push("<{element.tag}> has columns and a min_column, which decides the columns twice — keep whichever the screen means")
                    return
                }
                grid.set_min_column(value)
            }
        }
    }

    /// `columns="160 1fr auto"`, parsed here rather than in the markup
    /// compiler so one spelling means one thing wherever it is written.
    fn set_columns(element: Element, list: string) {
        match self.grid_of(element, "columns") {
            none => {}
            some(grid) => {
                if grid.has_min_column() {
                    self.faults.push("<{element.tag}> has columns and a min_column, which decides the columns twice — keep whichever the screen means")
                    return
                }
                grid.clear_columns()
                var written: int = 0
                for word: string in list.split(" ") {
                    if word == "" { continue }
                    match Vocabulary.track_of(word) {
                        none => {
                            self.faults.push("columns=\"{list}\" has no column called '{word}' — a column is a number of points, a share like 1fr, or auto")
                            return
                        }
                        some(track) => { grid.add_column(track); written = written + 1 }
                    }
                }
                if written == 0 {
                    self.faults.push("columns=\"{list}\" names no columns — write at least one, as in columns=\"160 1fr\"")
                }
            }
        }
    }

    fn set_justify(element: Element, mode: layout.Justify) {
        match element.arranger {
            none => { self.faults.push("<{element.tag}> has no children to justify") }
            some(arranger) => {
                match arranger as? layout.StackLayout {
                    some(run) => { run.set_justify(mode); return }
                    none => {}
                }
                // A grid justifies each row in the room its columns leave, so
                // a short last row can sit where the full ones do.
                match arranger as? layout.GridLayout {
                    some(grid) => { grid.set_justify(mode); return }
                    none => { self.faults.push("<{element.tag}> does not arrange its children in a run, so it has no justification") }
                }
            }
        }
    }
}

/// Why a word is not a font role, in the sentence that says what to write.
fn font_role_refusal(word: string) -> string {
    if word == "mono" {
        return "font_role is a size, and mono is body's size in a monospaced family — a family is not a property a control carries, so this would set nothing. Write font_role=\"body\""
    }
    return "font_role=\"{word}\" is not one of body, heading, caption"
}

/// `insets` with one edge replaced, or both edges of one axis for `x` and `y`.
/// Any other edge name changes nothing, and `Vocabulary` never answers one.
fn with_edge(insets: geometry.EdgeInsets, edge: string, value: f64) -> geometry.EdgeInsets {
    var out: geometry.EdgeInsets = insets
    if edge == "top" { out.top = value }
    if edge == "right" { out.right = value }
    if edge == "bottom" { out.bottom = value }
    if edge == "left" { out.left = value }
    if edge == "x" { out.left = value; out.right = value }
    if edge == "y" { out.top = value; out.bottom = value }
    return out
}
