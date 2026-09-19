// Rows and columns, filled by asking rather than by building.
package controls

import latte.platform
import latte.scene

class SharedTableRows implements scene.TableData {
    rows: TableRows
    pub fn init(rows: TableRows) { self.rows = rows }
    pub fn row_count() -> int { return self.rows.row_count() }
    pub fn cell(row: int, column: int) -> string { return self.rows.cell(row, column) }
}

/// A table.
///
/// `NSTableView`, a `GtkColumnView`, a virtual `SysListView32`, a
/// `UITableView` on the native backend. The shared backend uses `.bx` labels
/// for visible cells and one text field while editing. It receives a `TableRows`
/// source and asks only for visible rows plus overscan. Cached values stay valid
/// until the source is reloaded.
///
/// ```beans
/// var table: controls.Table = controls.Table.of(["Drink", "Price"])?
/// table.set_source(orders)?      // orders is a TableRows
/// ```
///
/// A selection raises `selection`, carrying the row in `event.index`.
///
/// **One platform has one column.** A `UITableView` is a list — the cell
/// styles that look like two columns are a label and a detail label, not
/// columns you can size or title — so asking for a second on iOS is
/// `unsupported` rather than four columns quietly collapsed into one.
pub class Table extends Widget {
    priv columns: int = 0

    /// Dense native macOS data grid or sidebar.
    pub fn set_compact(on: bool) -> Result<bool> {
        return self.set_property(platform.P_COMPACT, if on { 1 } else { 0 })
    }

    pub fn init(context: scene.UiContext) {
        super.init(WidgetKind.table, context)
    }

    /// A table with one column per title.
    pub static fn of(context: scene.UiContext, titles: List<string>) -> Result<Table> {
        WidgetKind.table.demand()?
        var table: Table = new Table(context)
        table.set_columns(titles.len())?
        var index: int = 0
        for index < titles.len() {
            table.set_column_title(index, titles[index])?
            index = index + 1
        }
        return ok(table)
    }

    /// How many columns. Set before the rows: a table with no columns has
    /// nothing to draw a row into, and every host treats this as the
    /// structural change it is.
    pub fn set_columns(count: int) -> Result<bool> {
        let table: scene.TableRender = (self.render_object()? as? scene.TableRender).expect("shared table")
        table.set_columns(count)?
        self.columns = count
        return ok(true)
    }

    pub fn column_count() -> int {
        return self.columns
    }

    /// Replaces the column titles used by a .bx table.
    pub fn set_titles(titles: List<string>) -> Result<bool> {
        let table: scene.TableRender = (self.render_object()? as? scene.TableRender).expect("shared table")
        table.set_titles(titles)?
        self.columns = table.column_count()
        return ok(true)
    }

    /// Replaces every column width, in title order.
    pub fn set_widths(widths: List<f64>) -> Result<bool> {
        let table: scene.TableRender = (self.render_object()? as? scene.TableRender).expect("shared table")
        return table.set_widths(widths)
    }
    pub fn reset_widths() -> Result<bool> {
        let table: scene.TableRender = (self.render_object()? as? scene.TableRender).expect("shared table")
        return table.reset_widths()
    }

    pub fn set_column_title(column: int, title: string) -> Result<bool> {
        let table: scene.TableRender = (self.render_object()? as? scene.TableRender).expect("shared table")
        return table.set_title(column, title)
    }

    pub fn set_column_width(column: int, points: f64) -> Result<bool> {
        let table: scene.TableRender = (self.render_object()? as? scene.TableRender).expect("shared table")
        return table.set_width(column, points)
    }

    /// Allow editing only for cells whose policy returns true.
    /// The policy must answer immediately. A committed edit raises
    /// `text_commit` on this table: `index` is the row, `token` the column,
    /// and `text` the proposed value. Save it in your source; call
    /// `reload()` if the row count changes. An unsaved cell reverts.
    /// Tables are read-only until this is called. The shared table opens one
    /// editor on double-click or Return and closes it on Escape.
    pub fn set_editable_when(policy: fn(int, int) -> bool) -> Result<bool> {
        let table: scene.TableRender = (self.render_object()? as? scene.TableRender).expect("shared table")
        return table.set_editable_when(policy)
    }

    /// Return the table to its default read-only state.
    pub fn clear_editable() -> Result<bool> {
        let table: scene.TableRender = (self.render_object()? as? scene.TableRender).expect("shared table")
        return table.clear_editable()
    }

    /// Simulate a user committing one cell through the table action path.
    /// Useful in tests that run without a visible window.
    pub fn edit_as_user(row: int, column: int, text: string) -> Result<bool> {
        self.render_object()?
        let context: scene.UiContext = self.render_context()
        return context.actions(self.handle().raw).commit_cell(row, column, text)
    }

    /// Where the cells come from, and how many rows there are.
    ///
    /// The row count is read once here, because it is one integer the program
    /// already knows — asking for it during every draw would be work per frame
    /// for a number that only changes when the program says so. `reload()` is
    /// how it changes.
    pub fn set_source(rows: TableRows) -> Result<bool> {
        let table: scene.TableRender = (self.render_object()? as? scene.TableRender).expect("shared table")
        return table.set_source(new SharedTableRows(rows))
    }
    pub fn clear_source() -> Result<bool> {
        let table: scene.TableRender = (self.render_object()? as? scene.TableRender).expect("shared table")
        return table.clear_source()
    }

    /// Ask again: the contents changed, the shape did not.
    pub fn reload() -> Result<bool> {
        let table: scene.TableRender = (self.render_object()? as? scene.TableRender).expect("shared table")
        return table.reload()
    }

    /// What the table has for one cell, asked through its own data source.
    ///
    /// The round trip, and the counterpart of `native_child_count`: Latte
    /// knows what it told the table, and bookkeeping that is never checked
    /// against the thing it describes is how a table ends up correct on paper
    /// and wrong on screen. It is also the only way to see the path work with
    /// nothing on screen — a table asks for cells when it draws, and a
    /// headless scene never draws.
    pub fn cell(row: int, column: int) -> Result<string> {
        let table: scene.TableRender = (self.render_object()? as? scene.TableRender).expect("table render")
        return table.cell(row, column)
    }

    /// The selected row, or -1 for none.
    pub fn selected() -> Result<int> {
        let table: scene.TableRender = (self.render_object()? as? scene.TableRender).expect("shared table")
        return ok(table.selected())
    }

    /// Select a row, or -1 to select none.
    pub fn select(row: int) -> Result<bool> {
        let table: scene.TableRender = (self.render_object()? as? scene.TableRender).expect("shared table")
        return table.select(row)
    }

}
