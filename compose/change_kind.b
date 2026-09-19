// The six things that can happen to a mounted tree.
package compose

/// One edit the platform has to be told about.
///
/// Six kinds, and no more, because these are the six operations a native
/// widget tree actually supports: make one, get rid of one, put one somewhere
/// else, change a property, start listening, stop listening. Anything a render
/// can express reduces to a sequence of these.
pub enum ChangeKind {
    /// Build a widget and everything under it, and put it at `index` inside
    /// the element `path` names.
    create
    /// Remove the child at `index`, and everything under it.
    remove
    /// Move the child at `index` to `target`, keeping the control itself — so
    /// it keeps its focus, its selection and its scroll position. Named
    /// `relocate` because `move` is a reserved word in Beans.
    relocate
    /// Write one property.
    set
    /// Start delivering one event kind to the framework.
    bind
    /// Stop delivering one event kind.
    unbind

    pub fn name() -> string {
        match self {
            create => { return "create" }
            remove => { return "remove" }
            relocate => { return "move" }
            set => { return "set" }
            bind => { return "bind" }
            unbind => { return "unbind" }
        }
    }
}
