// latte — the project command line.
//
// **Why this is under `examples/` and not at the module root.** latte is a
// `kind library` module, and a library may only hold a program entry under
// `examples/` or `tests/` — `in_entry_directory` in `beans/src/module.b`. A
// root-level `package main` file is refused twice over ("one directory is one
// package", and "a library root declares a normal package name, not 'main'").
// So this is not a demo; it is where the binary's entry is allowed to live.
//
// It imports `latte.cli` and nothing else of latte's, and `latte.cli` imports
// `latte.bx`, `std.fs`, `std.path` and `std.process`. None of that reaches
// latte's renderer or espresso, so this tool builds on every machine — and an
// application that ships a page links none of it.
//
//     beansc build examples/latte_cli.b -o build/latte
//     build/latte init myapp && cd myapp && ../build/latte build
package main

import latte.cli

fn main() {
    cli.run_cli()
}
