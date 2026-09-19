// The layout of something that has no children.
package layout

import latte.geometry

/// A node that measures itself through `Measure` and arranges nothing.
///
/// This is the null object that keeps `LayoutNode.arranger` non-optional. The
/// alternative — an `Option<Layout>` meaning "leaf" — would put an unwrap at
/// every point in the engine that touches a node, and would leave two ways to
/// express the same thing.
///
/// It is also where the decision "does this node ask the platform how big it
/// is" lives. A node measures through `Measure` exactly when its layout is
/// this one, so a container that happens to have a widget key is not asked
/// twice and a leaf without one measures as zero.
pub class LeafLayout extends Layout {
    pub fn init() {}

    pub override fn measure(node: LayoutNode, limit: Constraint,
                            ruler: Measure) -> Result<geometry.Size> {
        if node.key < 0 {
            return ok(limit.clamp(geometry.Size.zero()))
        }
        let natural: geometry.Size = ruler.measure(node.key, limit.available())?
        return ok(limit.clamp(natural))
    }

    pub override fn arrange(node: LayoutNode, content: geometry.Rect,
                            ruler: Measure) -> Result<bool> {
        return ok(true)
    }

    pub override fn label() -> string {
        return "leaf"
    }
}
