// A GENERIC partial class, split the same way: a generic component is
// `pub partial class Grid<T> extends Component` and needs no feature at all
// beyond that — this half is the claim, grid_gen.b is the other half.
package pages

@page(route: r"/grid")
pub partial class Grid<T> extends Component {
    @param pub title: string = "grid"
    pub rows: List<T> = []
    pub fn init() {}
    pub fn add(item: T) { self.rows.push(item) }
}
