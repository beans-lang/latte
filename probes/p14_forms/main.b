// p14 — the four language questions forms.b's design depends on.
package main

import std.io
import std.reflect

@target(value: ["field"])
@retention(value: "runtime")
annotation field2 {
    name: string = ""
}

@target(value: ["field"])
@retention(value: "runtime")
annotation required2 {
    message: string = ""
}

@target(value: ["field"])
@retention(value: "runtime")
annotation length2 {
    min: int = 0
    max: int = -1
}

class Named {
    pub fn init() {}
    pub fn who() -> string { return "named" }
}

class Model {
    @field2 @required2 @length2(min: 3, max: 8) pub title: string = ""
    pub count: int = 0
    pub fn init() {}
}

class Holder extends Named {
    pub model: Model = new Model()
    pub fn init() { super.init() }
    pub override fn who() -> string { return "holder" }
}

class Plain {
    pub fn init() {}
}

fn main() {
    // Q1: does a reflective write through reflect.value(obj) reach the object?
    let holder: Holder = new Holder()
    let value: reflect.Value = reflect.value(holder.model)
    match value.type().field("title") {
        some(f) => {
            match f.set(value.copy(), reflect.value("written")) {
                ok(_) => { io.println("Q1 set: ok") }
                err(e) => { io.println("Q1 set: err {e.message()}") }
            }
        }
        none => { io.println("Q1 set: no field") }
    }
    io.println("Q1 holder.model.title = \"{holder.model.title}\"")

    // Q2: as? to an interface
    let a: Named = new Holder()
    match a as? Holder {
        some(n) => { io.println("Q2 base as? Holder = {n.who()}") }
        none => { io.println("Q2 base as? Holder = none") }
    }
    let b: Named = new Named()
    match b as? Holder {
        some(_) => { io.println("Q2 plain base as? Holder = some") }
        none => { io.println("Q2 plain base as? Holder = none") }
    }

    // Q3: three annotation types on one field, all readable
    let described: reflect.Type = type_of(Model)
    for f: reflect.Field in described.fields() {
        var names: List<string> = []
        for use: reflect.Annotation in f.annotations() { names.push(use.qualified_name()) }
        let joined: string = names.join(" ")
        io.println("Q3 {f.name()}: [{joined}]")
    }

    // Q4: reading an annotation argument that was left at its default
    for f: reflect.Field in described.fields() {
        for use: reflect.Annotation in f.annotations() {
            if !use.qualified_name().ends_with(".length2") { continue }
            match use.argument("min") {
                some(arg) => { io.println("Q4 min arg present: {arg.value().text()}") }
                none => { io.println("Q4 min arg absent") }
            }
            match use.type().field("max") {
                some(af) => {
                    match af.default_value() {
                        some(d) => { io.println("Q4 max default: {d.text()}") }
                        none => { io.println("Q4 max default: none") }
                    }
                }
                none => { io.println("Q4 max field: none") }
            }
        }
    }
}
