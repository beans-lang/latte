// What one child asks of the run it sits in.
package layout

import latte.geometry

/// Per-child layout parameters.
///
/// Everything here belongs to the child but is read by the parent, which is
/// why it lives on the node rather than inside a layout object: the same child
/// keeps its margin and its size limits when it is moved from a stack into a
/// grid.
///
/// `-1.0` means "no opinion" for every size bound and for `basis`. Zero is a
/// legitimate minimum and a legitimate basis, so it cannot double as the empty
/// value, and an `Option<f64>` per bound would put four unwraps in the hot
/// path of every arrange pass.
pub struct LayoutSpec {
    /// Share of leftover main-axis space this child takes. 0 means it keeps
    /// its measured size. Read only by `FlexLayout`.
    pub grow: f64 = 0.0

    /// Share of main-axis overflow this child gives up, weighted by its size.
    /// The default of 1 matches the web's, where everything shrinks before
    /// anything overflows.
    pub shrink: f64 = 1.0

    /// Main-axis size to start distribution from, before growing or shrinking.
    /// -1 means start from the measured size.
    pub basis: f64 = -1.0

    pub min_width: f64 = -1.0
    pub max_width: f64 = -1.0
    pub min_height: f64 = -1.0
    pub max_height: f64 = -1.0

    /// Space kept outside this child's frame. The parent reserves it; the
    /// child never sees it.
    pub margin: geometry.EdgeInsets = geometry.EdgeInsets {}

    /// Cross-axis placement, or `inherit` to take the run's default.
    pub align: geometry.Align = geometry.Align.inherit

    /// Insets from a `Box`'s edges, or -1 for no opinion; every other layout
    /// ignores them. Two opposite insets stretch; none on an axis fills it.
    pub left: f64 = -1.0
    pub top: f64 = -1.0
    pub right: f64 = -1.0
    pub bottom: f64 = -1.0

    /// A share, 0 to 100, of the room the container offers on that axis — its
    /// content box less this child's own margin — or -1. While that room is unbounded, no opinion.
    pub width_percent: f64 = -1.0
    pub height_percent: f64 = -1.0

    /// Width over height, or -1 for none. Resolved at measure from whichever
    /// axis is settled; see `shaped`.
    pub aspect_ratio: f64 = -1.0

    /// Left out of the layout at every width: no frame, no room, no spacing.
    pub hidden: bool = false

    /// Shown only while the box around it is at least this wide, or -1.
    pub hide_below: f64 = -1.0

    /// Shown only while the box around it is under this width, or -1.
    pub hide_above: f64 = -1.0

    /// Whether this child takes part in a box `room` wide. A room nobody has
    /// bounded yet (-1) shows it; the parent decides again once it is placed.
    pub fn shown_in(room: f64) -> bool {
        if self.hidden { return false }
        if room < 0.0 { return true }
        if self.hide_below >= 0.0 && room < self.hide_below { return false }
        if self.hide_above >= 0.0 && room >= self.hide_above { return false }
        return true
    }

    pub static fn auto() -> LayoutSpec {
        return LayoutSpec {}
    }

    /// A child that takes `weight` shares of the leftover space.
    pub static fn flexible(weight: f64) -> LayoutSpec {
        return LayoutSpec { grow: weight }
    }

    /// A child pinned to one size on both axes.
    pub static fn fixed(width: f64, height: f64) -> LayoutSpec {
        return LayoutSpec { min_width: width, max_width: width,
                            min_height: height, max_height: height,
                            shrink: 0.0 }
    }

    /// A child pinned to one height, with no opinion about its width.
    ///
    /// `fixed(0.0, 96.0)` reads like "96 tall, any width" and is not: `0.0`
    /// is a box no points across, and the control lays out invisible.
    pub static fn tall(height: f64) -> LayoutSpec {
        return LayoutSpec { min_height: height, max_height: height,
                            shrink: 0.0 }
    }

    /// A child pinned to one width, with no opinion about its height — a
    /// sidebar, a gutter, a column of buttons. The mirror of `tall`.
    pub static fn wide(width: f64) -> LayoutSpec {
        return LayoutSpec { min_width: width, max_width: width,
                            shrink: 0.0 }
    }

    /// A child placed at an explicit offset from a `Box`'s top left corner,
    /// at its measured size.
    pub static fn at(x: f64, y: f64) -> LayoutSpec {
        return LayoutSpec { left: x, top: y }
    }

    /// Whether this spec pins one size on `axis`: min and max the same number,
    /// or a share of the room.
    pub fn sizes(axis: Direction) -> bool {
        if self.percent_on(axis) >= 0.0 { return true }
        let lower: f64 = self.min_on(axis)
        let upper: f64 = self.max_on(axis)
        return upper >= 0.0 && lower == upper
    }

    /// The inset before this child along `axis` (left or top), or -1.
    pub fn inset_lead(axis: Direction) -> f64 {
        if axis.is_horizontal() { return self.left }
        return self.top
    }

    /// The inset after this child along `axis` (right or bottom), or -1.
    pub fn inset_trail(axis: Direction) -> f64 {
        if axis.is_horizontal() { return self.right }
        return self.bottom
    }

    /// This spec's own size bounds folded into `limit`.
    ///
    /// The child's bounds win where they are set, but they are still pulled
    /// inside the parent's: a child asking for 400 points of width inside a
    /// 300-point parent gets 300. Letting the child win outright is how a
    /// layout ends up drawing outside its window.
    pub fn constrain(limit: Constraint) -> Constraint {
        var out: Constraint = limit
        if self.min_width >= 0.0 { out.min_width = self.min_width }
        if self.max_width >= 0.0 {
            if !limit.has_max_width() || self.max_width < limit.max_width {
                out.max_width = self.max_width
            }
        }
        if self.min_height >= 0.0 { out.min_height = self.min_height }
        if self.max_height >= 0.0 {
            if !limit.has_max_height() || self.max_height < limit.max_height {
                out.max_height = self.max_height
            }
        }
        if out.has_max_width() && out.min_width > out.max_width {
            out.min_width = out.max_width
        }
        if out.has_max_height() && out.min_height > out.max_height {
            out.min_height = out.max_height
        }
        // A percent of a bounded axis is a size, pinned like `width` would be;
        // of an unbounded one it is no opinion, and the bounds above stand.
        let wide: f64 = self.percent_size(Direction.horizontal, limit.max_width)
        if wide >= 0.0 {
            out.min_width = wide
            out.max_width = wide
        }
        let tall: f64 = self.percent_size(Direction.vertical, limit.max_height)
        if tall >= 0.0 {
            out.min_height = tall
            out.max_height = tall
        }
        return out
    }

    /// The share this spec asks for along `axis`, or -1.
    pub fn percent_on(axis: Direction) -> f64 {
        if axis.is_horizontal() { return self.width_percent }
        return self.height_percent
    }

    /// What the share along `axis` comes to inside `room`, pulled inside this
    /// spec's own bounds and the room; -1 with no share, or no room to take it of.
    pub fn percent_size(axis: Direction, room: f64) -> f64 {
        let share: f64 = self.percent_on(axis)
        if share < 0.0 || room < 0.0 { return -1.0 }
        var size: f64 = room * share / 100.0
        let lower: f64 = self.min_on(axis)
        let upper: f64 = self.max_on(axis)
        if size < lower { size = lower }
        if upper >= 0.0 && size > upper { size = upper }
        if size > room { size = room }
        return size
    }

    /// `size` reshaped to `aspect_ratio`: a width `limit` has settled decides
    /// the height, a settled height the width, and with neither the measured width decides.
    pub fn shaped(size: geometry.Size, limit: Constraint) -> geometry.Size {
        let width_set: bool = limit.has_max_width() && limit.min_width == limit.max_width
        let height_set: bool = limit.has_max_height() && limit.min_height == limit.max_height
        if width_set && height_set { return size }
        if height_set {
            return geometry.Size.of(limit.max_height * self.aspect_ratio, limit.max_height)
        }
        var width: f64 = size.width
        if width_set { width = limit.max_width }
        return geometry.Size.of(width, width / self.aspect_ratio)
    }

    /// This spec's lower bound on `axis`, or 0 when it sets none.
    pub fn min_on(axis: Direction) -> f64 {
        var value: f64 = self.min_height
        if axis.is_horizontal() { value = self.min_width }
        if value < 0.0 { return 0.0 }
        return value
    }

    /// This spec's upper bound on `axis`, or -1 when it sets none.
    pub fn max_on(axis: Direction) -> f64 {
        if axis.is_horizontal() { return self.max_width }
        return self.max_height
    }

    /// The margin taken along `axis`.
    pub fn margin_on(axis: Direction) -> f64 {
        if axis.is_horizontal() { return self.margin.horizontal() }
        return self.margin.vertical()
    }

    /// The margin before this child along `axis` — its left or its top.
    pub fn margin_lead(axis: Direction) -> f64 {
        if axis.is_horizontal() { return self.margin.left }
        return self.margin.top
    }
}
