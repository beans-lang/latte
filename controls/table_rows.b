// Where a table's cells come from.
package controls

/// What a table asks for its contents.
///
/// **A table does not hold its rows; it asks for them.** That is the whole
/// design, and the reason is the only one that matters: a list long enough to
/// need a table is long enough that building it shows. Ten thousand rows of
/// four columns is forty thousand controls, forty thousand frames for the
/// solver, and a reconciler pass over all of them every time one cell changes
/// — for a screen with thirty rows on it.
///
/// Every native toolkit solves this the same way and has for thirty years:
/// `NSTableView` calls it a data source, Win32 calls it `LVS_OWNERDATA`, GTK4
/// a list model, UIKit a table view data source. latte calls it the same
/// thing all four do, and `cell` is called by the platform *while it is
/// drawing*.
///
/// Which is the one rule an implementation has to keep: **`cell` must return.**
/// It runs on the UI thread inside the platform's draw, so no waiting, no
/// joining, no fetching. A cell is a lookup in something the program already
/// has. If the data is not there yet, answer what you have — a dash, an empty
/// string — and call `reload()` when it arrives.
pub interface TableRows {
    /// How many rows there are now.
    fn row_count() -> int
    /// The text of one cell. `row` and `column` are both zero-based, and both
    /// are already inside the range the table was told about.
    fn cell(row: int, column: int) -> string
}
