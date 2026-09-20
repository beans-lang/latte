// Does a component keep its identity when the tree around it changes?
//
// The question a differ answers, and the one that decides whether typing into
// a field survives the render that happens while you type. A component that
// was rebuilt on every render would lose its state, its caret and its
// scroll offset — and it would look like an intermittent bug rather than a
// design, because it only shows when a render lands mid-interaction.
//
// Three claims:
//   * a component that stays in the tree is the same object across renders
//   * a keyed row keeps its identity when its siblings move
//   * a subtree that goes away really goes away
package main

import std.io
import latte.compose
import latte.geometry
import latte.headless
import latte.input
import latte.stage

/// A row that counts how many of itself have ever existed, and remembers
/// something no render sets. If the differ rebuilt it, `typed` would be empty.
pub class Row extends compose.Component {
    pub label: string = ""
    pub typed: string = ""
    /// A number nothing but this object's own construction sets, so two rows
    /// can be told apart without reference equality — which Beans does not
    /// spell, and which a `Map` lookup would answer for the wrong reason.
    pub serial: int = 0
    pub fn init() {
        super.init()
        Census.instance.built = Census.instance.built + 1
        self.serial = Census.instance.built
    }
    pub override fn render(b: compose.Builder) {
        b.open("Label")
        b.text("{self.label}{self.typed}")
        b.close()
    }
}

pub singleton class Census {
    pub built: int = 0
    fn init() {}
}

pub class Board extends compose.Component {
    pub names: List<string> = ["a", "b", "c"]
    pub show_extra: bool = false
    pub rows: Map<string, Row> = {}

    pub fn init() { super.init() }

    /// Holds each row itself, so a test can ask whether the object survived.
    fn row_for(name: string) -> Row {
        match self.rows.get(name) {
            some(row) => { return row }
            none => {
                let made: Row = new Row()
                made.label = name
                self.rows[name] = made
                return made
            }
        }
    }

    pub override fn render(b: compose.Builder) {
        b.open("VStack")
        b.number("padding", 8.0)
        b.number("spacing", 4.0)
        for name: string in self.names {
            b.show(name, self.row_for(name))
        }
        if self.show_extra {
            b.open("Label")
            b.text("extra")
            b.close()
        }
        b.close()
    }
}

fn rule(title: string) {
    io.println("")
    io.println("== {title} ==")
}

pub extern "C" fn run() -> i32 as "latte_identity_run" {
    let page: stage.Scene = new stage.Scene(new headless.MetricRenderer(),
                                            geometry.Size.of(320.0, 240.0))
    let board: Board = new Board()
    page.show(board).expect("show")

    rule("1 — a component that stays is the same object")

    let built_first: int = Census.instance.built
    io.println("rows built: {built_first}")
    board.rows["b"].typed = " (typed)"
    board.request_render()
    page.refresh().expect("refresh")
    io.println("rows built after a render: {Census.instance.built}")
    io.println("what b remembers: \"{board.rows["b"].typed}\"")

    rule("2 — reordering keeps each row's identity")

    let before: Row = board.rows["b"]
    board.names = ["c", "b", "a"]
    board.request_render()
    page.refresh().expect("refresh")
    io.println("rows built after reordering: {Census.instance.built}")
    io.println("b is the same object: {board.rows["b"].serial == before.serial}")
    io.println("and still remembers: \"{board.rows["b"].typed}\"")

    rule("3 — a row that leaves is gone, and coming back is a new one")

    board.names = ["c", "a"]
    board.rows.remove("b")
    board.request_render()
    page.refresh().expect("refresh")
    let after_removal: int = Census.instance.built
    io.println("rows built after removing one: {after_removal}")
    board.names = ["c", "b", "a"]
    board.request_render()
    page.refresh().expect("refresh")
    io.println("rows built after putting it back: {Census.instance.built}")
    io.println("it is a new object: {board.rows["b"].serial != before.serial}")
    io.println("with nothing remembered: \"{board.rows["b"].typed}\"")

    rule("4 — adding a sibling does not rebuild the rows")

    let steady: int = Census.instance.built
    board.show_extra = true
    board.request_render()
    page.refresh().expect("refresh")
    io.println("rows built after adding a sibling: {Census.instance.built - steady}")

    page.close()
    return 0
}

fn main() { run() }
