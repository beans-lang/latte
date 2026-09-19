// What sort of value an attribute carries.
package compose

/// The four shapes a widget property takes.
///
/// There are three host calls — `ctd_set_text`, `ctd_set_int`, `ctd_set_real`
/// — and four kinds, because `flag` and `whole` both travel as an integer but
/// read very differently. A golden file saying `enabled=true` is a golden file
/// somebody can check; one saying `enabled=1` is a golden file people skim.
pub enum AttributeKind {
    text
    whole
    real
    flag
    items
    numbers
    table_source
    table_edit_policy

    pub fn name() -> string {
        match self {
            text => { return "text" }
            whole => { return "whole" }
            real => { return "real" }
            flag => { return "flag" }
            items => { return "items" }
            numbers => { return "numbers" }
            table_source => { return "table_source" }
            table_edit_policy => { return "table_edit_policy" }
        }
    }
}
