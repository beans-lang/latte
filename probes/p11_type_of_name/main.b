// p11 — `type_of(ImportedType).qualified_name()` is wrong in the importing
// package, and `is_assignable_from` is wrong as a consequence.
//
// The question a framework asks to decide "is this annotated type one of
// mine". Latte asks it of every `@page`. BLOCKERS.md B8.
package main

import std.io
import std.reflect
import {Base, base_name} from p11_type_of_name.core

pub class Derived extends Base { pub fn init() { super.init() } }

// The control: a base declared HERE, asked about HERE.
pub class LocalBase { pub fn init() {} }
pub class LocalSub extends LocalBase { pub fn init() { super.init() } }

fn main() {
    io.println("-- control: a base declared in this package")
    io.println("  type_of(LocalBase).qualified_name() = {type_of(LocalBase).qualified_name()}")
    match type_of(LocalSub).base_type() {
        some(link) => { io.println("  LocalSub's base link                = {link.qualified_name()}") }
        none => {}
    }
    io.println("  LocalBase.is_assignable_from(LocalSub) = {type_of(LocalBase).is_assignable_from(type_of(LocalSub))}")

    io.println("-- control: the SAME question asked inside the declaring package")
    io.println("  core's own type_of(Base).qualified_name() = {base_name()}")

    io.println("-- subject: an IMPORTED base, asked about here")
    io.println("  type_of(Base).qualified_name()      = {type_of(Base).qualified_name()}")
    match type_of(Derived).base_type() {
        some(link) => { io.println("  Derived's base link                 = {link.qualified_name()}") }
        none => {}
    }
    io.println("  Base.is_assignable_from(Derived)    = {type_of(Base).is_assignable_from(type_of(Derived))}")
}
