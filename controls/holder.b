// A control that holds other controls.
package controls

/// What a `Container` and a `ScrollView` have in common.
///
/// Two kinds hold children and they are not related by inheritance: a
/// `ScrollView` is not a box with a scrollbar, it is a control that puts its
/// children somewhere the platform chose — inside a document view on macOS,
/// inside a viewport on GTK. Making one extend the other would be modelling
/// the platform's implementation rather than what the two actually share.
///
/// So they share an interface, which is what the component applier asks for.
/// It does not care which it has; it cares that it can insert, remove and
/// reorder.
pub interface Holder {
    fn count() -> int
    fn child_at(index: int) -> Option<Widget>
    fn add(child: Widget) -> Result<bool>
    fn insert(child: Widget, index: int) -> Result<bool>
    fn remove(index: int) -> Result<bool>
    fn move_child(from: int, to: int) -> Result<bool>
}
