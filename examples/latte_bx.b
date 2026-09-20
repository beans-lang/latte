// latte-bx — the markup compiler's command line.
//
// **Why this is under `examples/` and not at the module root.** latte is a
// `kind library` module, and a library may only hold a program entry under
// `examples/` or `tests/` — `in_entry_directory` in `beans/src/module.b:1768`.
// A root-level `package main` file is refused twice over ("one directory is one
// package", and "a library root declares a normal package name, not 'main'").
// So this is not a mistake and it is not a demo; it is where the binary's entry
// is allowed to live.
//
//     beansc build examples/latte_bx.b -o build/latte-bx
//     build/latte-bx build pages/counter.bx
//
// Build-time only. It imports `std.fs` and `std.os`; nothing under the module
// root imports `latte.bx`, so a program that ships a latte page never links a
// compiler.
package main

import std.fs
import std.io
import std.os
import latte.bx

fn usage() {
    io.eprintln("usage: latte-bx <command> [options] <file.bx>...")
    io.eprintln("")
    io.eprintln("commands:")
    io.eprintln("  build       compile each file, writing <stem>_gen.b beside it")
    io.eprintln("  check       parse and emit, and write nothing")
    io.eprintln("  vocabulary  print latte's .bx surface as JSON, for an editor")
    io.eprintln("")
    io.eprintln("options:")
    io.eprintln("  -o <path>          write the generated Beans to <path> (one input only)")
    io.eprintln("  --stdout           write the generated Beans to stdout")
    io.eprintln("  --target <name>    html (the default) or canvas")
    io.eprintln("  --latte <module>   the module Builder comes from (default: latte)")
    io.eprintln("  --package <name>   the package the generated file declares")
    io.eprintln("")
    io.eprintln("A generated file is checked in — beside its source for html, in a")
    io.eprintln("mirror for a canvas tree — and a drift gate regenerates and diffs it,")
    io.eprintln("so a stale one fails the build rather than shipping.")
}

fn main() {
    let args: List<string> = os.args()
    if args.is_empty() {
        usage()
        os.exit(2)
    }
    let command: string = args[0]
    if command == "--help" || command == "-h" || command == "help" {
        usage()
        return
    }
    // The vocabulary takes no input file and no option: it is the language,
    // not a translation of anything. `editors/shared/bx.json` is this string,
    // and `tests/w2_editor_data.out` is the same string as a golden, so the
    // gate says the two cannot drift.
    if command == "vocabulary" {
        var target: bx.Target = bx.Target.html
        if args.len() == 3 && args[1] == "--target" {
            match bx.Target.of(args[2]) {
                some(chosen) => { target = chosen }
                none => {
                    io.eprintln("latte-bx: {args[2]} is not a target — the two are html and canvas")
                    os.exit(2)
                }
            }
        } else if args.len() > 1 {
            io.eprintln("latte-bx: vocabulary takes only --target <name> — it prints latte's own surface")
            os.exit(2)
        }
        io.print(bx.vocabulary_json_for(target))
        return
    }
    if command != "build" && command != "check" {
        io.eprintln("latte-bx: {command} is not a command — the three are build, check and vocabulary")
        usage()
        os.exit(2)
    }

    let options: bx.Options = new bx.Options()
    let inputs: List<string> = []
    var output: string = ""
    var to_stdout: bool = false
    var index: int = 1
    for index < args.len() {
        let arg: string = args[index]
        if arg == "--target" {
            index = index + 1
            if index >= args.len() {
                io.eprintln("latte-bx: --target needs a name — html or canvas")
                os.exit(2)
            }
            match bx.Target.of(args[index]) {
                some(target) => { options.target = target }
                none => {
                    io.eprintln("latte-bx: {args[index]} is not a target — the two are html and canvas")
                    os.exit(2)
                }
            }
            index = index + 1
            continue
        }
        if arg == "-o" {
            index = index + 1
            if index >= args.len() {
                io.eprintln("latte-bx: -o needs a path after it")
                os.exit(2)
            }
            output = args[index]
            index = index + 1
            continue
        }
        if arg == "--stdout" {
            to_stdout = true
            index = index + 1
            continue
        }
        if arg == "--latte" {
            index = index + 1
            if index >= args.len() {
                io.eprintln("latte-bx: --latte needs a module path after it")
                os.exit(2)
            }
            options.latte_module = args[index]
            index = index + 1
            continue
        }
        if arg == "--package" {
            index = index + 1
            if index >= args.len() {
                io.eprintln("latte-bx: --package needs a name after it")
                os.exit(2)
            }
            options.package_name = args[index]
            index = index + 1
            continue
        }
        if arg.starts_with("-") {
            io.eprintln("latte-bx: {arg} is not an option latte-bx has")
            usage()
            os.exit(2)
        }
        inputs.push(arg)
        index = index + 1
    }

    if inputs.is_empty() {
        io.eprintln("latte-bx: no input files")
        usage()
        os.exit(2)
    }
    if output != "" && inputs.len() > 1 {
        io.eprintln("latte-bx: -o names one output and there are {inputs.len()} inputs")
        os.exit(2)
    }

    var failed: bool = false
    for path: string in inputs {
        let compiled: bx.Compiled = bx.compile_file(path, options)
        if !compiled.is_ok() {
            io.eprintln(compiled.report(path))
            failed = true
            continue
        }
        if command == "check" { continue }
        if to_stdout {
            io.print(compiled.source)
            continue
        }
        var target: string = output
        if target == "" { target = bx.generated_path_for(path) }
        match fs.write(target, compiled.source) {
            ok(_) => {}
            err(problem) => {
                io.eprintln("latte-bx: cannot write {target}: {problem.msg}")
                failed = true
            }
        }
    }
    if failed { os.exit(1) }
}
