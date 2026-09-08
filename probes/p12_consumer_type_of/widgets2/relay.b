// The same four questions asked from a NAMED package rather than an entry, so
// the matrix has both halves. Every answer here is produced the same two ways
// as in `main.b`: inside a string interpolation and outside one.
package widgets2

import std.reflect
import std.fmt
import {Card} from p12_consumer.widgets
import {Component} from latte

/// Named import, ANOTHER module — inside an interpolation.
pub fn component_inside() -> string { return "{type_of(Component).qualified_name()}" }
/// Named import, another module — outside.
pub fn component_outside() -> string {
    let t: reflect.Type = type_of(Component)
    return t.qualified_name()
}
/// Named import, a SUBPACKAGE of this module — inside an interpolation.
pub fn card_inside() -> string { return "{type_of(Card).qualified_name()}" }
/// Named import, a subpackage of this module — outside.
pub fn card_outside() -> string {
    let t: reflect.Type = type_of(Card)
    return t.qualified_name()
}
/// Dot-path — inside an interpolation.
pub fn dotpath_inside() -> string { return "{type_of(fmt.StringBuilder).qualified_name()}" }
/// Dot-path — outside.
pub fn dotpath_outside() -> string {
    let t: reflect.Type = type_of(fmt.StringBuilder)
    return t.qualified_name()
}
/// The question that matters: does the base recognise the subclass?
pub fn assignable_inside() -> bool { return "{type_of(Component).is_assignable_from(type_of(Card))}" == "true" }
pub fn assignable_outside() -> bool {
    let base: reflect.Type = type_of(Component)
    let sub: reflect.Type = type_of(Card)
    return base.is_assignable_from(sub)
}
