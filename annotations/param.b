// Marks a field as a parameter the caller sets.
package annotations

/// A component parameter: a field whose value comes from whoever is showing
/// this component, not from the component itself.
///
/// Two things follow from marking a field this way, and both are the reason
/// the annotation exists rather than a naming convention:
///
/// - **It is settable from markup.** `<OrderRow title="Flat white" />` finds
///   the field by name and assigns it. A field with no `@param` is refused by
///   name, so a typo in markup is an error and not a value silently ignored.
/// - **It is what a re-render compares.** A component that re-renders only
///   when its inputs changed needs to know what its inputs are, and reading
///   the `@param` fields means that list cannot drift from the fields it is
///   meant to mirror.
///
/// The field must be `pub`: reflection does not bypass visibility, and a
/// private `@param` is refused at mount with a message naming it rather than
/// staying empty forever.
@target(value: ["field"])
@retention(value: "runtime")
pub annotation param {
}
