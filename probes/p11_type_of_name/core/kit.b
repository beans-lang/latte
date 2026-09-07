// The "framework" half: the base type a scan wants to recognise.
package core

pub class Base { pub fn init() {} }

/// What a framework writes INSIDE its own package. This one is correct.
pub fn base_name() -> string { return type_of(Base).qualified_name() }
