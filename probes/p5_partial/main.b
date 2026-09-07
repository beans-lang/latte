// Probe 4 — a generated `partial class` half beside a hand-written one.
//
// The base case was answered before the lane started: `pages/counter.b` holds
// the class header and `pages/counter_gen.b` holds
// `pub override fn render(b: Builder)`, and dispatch through the base class
// works on both backends. This file adds the three cases the lane owes:
//
//   1. an ANNOTATION on the hand-written half while the generated half carries
//      the method — latte's page scan reads `@page` and `@param` back through
//      reflection at startup, and it must find them across the split;
//   2. a GENERIC partial class, `partial class Grid<T> extends Component`;
//   3. a `fn(Builder)` FIELD, which is what child content (`$slot`) and a
//      template (`$slot:row as o`) compile to.
package main

import std.io
import std.reflect
import {Card, Counter, Grid, Builder, Component} from p5_partial.pages

// A page scan, as latte will do it: find the annotation by name and read an
// argument out of it.
fn annotation_string(described: reflect.Type, note_name: string,
                     argument_name: string) -> string {
    for note: reflect.Annotation in described.annotations() {
        if note.name() == note_name {
            match note.argument(argument_name) {
                some(argument) => {
                    match argument.value().as_string() {
                        some(text) => { return text }
                        none => { return "<not a string>" }
                    }
                }
                none => { return "<no such argument>" }
            }
        }
    }
    return "<no {note_name}>"
}

fn field_annotation_names(described: reflect.Type, field_name: string) -> string {
    match described.field(field_name) {
        some(field) => {
            var out: string = ""
            for note: reflect.Annotation in field.annotations() {
                out = "{out}{note.name()};"
            }
            return out
        }
        none => { return "<no field {field_name}>" }
    }
}

fn required_of(described: reflect.Type, field_name: string) -> string {
    match described.field(field_name) {
        some(field) => {
            for note: reflect.Annotation in field.annotations() {
                if note.name() == "param" {
                    match note.argument("required") {
                        some(argument) => {
                            match argument.value().as_bool() {
                                some(flag) => { return "{flag}" }
                                none => { return "<not a bool>" }
                            }
                        }
                        none => { return "default" }
                    }
                }
            }
            return "<no param>"
        }
        none => { return "<no field>" }
    }
}

fn main() {
    // ---- the base case, unchanged ----
    let counter: Counter = new Counter()
    counter.count = 7
    let b0: Builder = new Builder()
    let base0: Component = counter
    base0.render(b0)
    io.println("base case, render through the base class: {b0.out}")

    // ---- 1. annotations on the hand-written half ----
    let described: reflect.Type = type_of(Card)
    io.println("@page survives the split: {annotation_string(described, "page", "route")}")
    io.println("@layout default is materialised: {annotation_string(described, "layout", "name")}")
    io.println("@param on a field: {field_annotation_names(described, "id")}")
    io.println("@param(required: true) reads back: {required_of(described, "id")}")
    io.println("@param with no argument reads its default: {required_of(described, "title")}")
    // The method the GENERATED half carries must still be on the one type.
    io.println("render is on the type reflection sees: {described.method("render").is_some()}")
    io.println("the fields the hand-written half declared are all there: {described.fields().len()}")

    // ---- 3. a fn(Builder) field ----
    let card: Card = new Card()
    card.id = 4
    card.title = "orders"
    let b1: Builder = new Builder()
    let base1: Component = card
    base1.render(b1)
    io.println("the fn(Builder) field's default ran: {b1.out}")

    // Child content supplied by a caller, exactly as `<Card><p>…</p></Card>`
    // compiles: a closure assigned to the field.
    card.body = fn(b: Builder) { b.text(80, "child content") }
    card.row = fn(b: Builder, value: int) { b.text(81, "row {value}") }
    card.rows.push(11)
    card.rows.push(12)
    let b2: Builder = new Builder()
    base1.render(b2)
    io.println("child content and a template: {b2.out}")

    // A closure that captures a local, which is what an outer component's
    // fields become when it supplies child content.
    let tag: string = "captured"
    card.body = fn(b: Builder) { b.text(82, tag) }
    let b3: Builder = new Builder()
    base1.render(b3)
    io.println("a capturing closure in the field: {b3.out}")

    // ---- 2. a generic partial class ----
    let grid: Grid<int> = new Grid<int>()
    grid.title = "orders"
    grid.add(5)
    grid.add(6)
    let b4: Builder = new Builder()
    let base4: Component = grid
    base4.render(b4)
    io.println("a generic partial renders through the base: {b4.out}")

    let words: Grid<string> = new Grid<string>()
    words.title = "words"
    words.add("a")
    let b5: Builder = new Builder()
    let base5: Component = words
    base5.render(b5)
    io.println("a second instantiation is its own type: {b5.out}")
}
