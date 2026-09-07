package main

import std.io

pub enum Move {
    step_in(index: int)
    step_out
    relocate(from: int, to: int)
}

pub class Node {
    pub name: string = ""
    pub kids: List<Node> = []
    pub fn init(name: string) { self.name = name }
}

fn main() {
    var xs: List<int> = [1, 2, 3]
    xs.insert(1, 9)
    io.println("{xs}")
    let taken: int = xs.remove(0)
    io.println("taken={taken} rest={xs}")

    var tree: List<Node> = []
    tree.push(new Node("a"))
    tree.push(new Node("b"))
    tree[0].kids.push(new Node("a1"))
    tree.insert(1, new Node("mid"))
    let moved: Node = tree.remove(0)
    tree.insert(2, moved)
    var out: string = ""
    for n: Node in tree { out = "{out}{n.name}({n.kids.len()}) " }
    io.println(out)

    let e: Move = Move.relocate(3, 1)
    match e {
        step_in(i) => { io.println("in {i}") }
        step_out => { io.println("out") }
        relocate(f, t) => { io.println("relocate {f}->{t}") }
    }
    io.println("index_of: {[10,20,30].index_of(20)}")
}
