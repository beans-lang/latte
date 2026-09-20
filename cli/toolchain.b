// toolchain.b — finding the four things a build needs that are not in the
// project: `beansc`, a Clang with a wasm32 backend, a `wasm-ld` for it, and
// latte's own tree.
//
// The last one is only needed by a canvas build, and it is the interesting one.
// A canvas application is a WebAssembly module plus a page that loads it, and
// the page's half — the runtime, the CanvasKit bridge, the accessibility and
// editing hosts — is latte's JavaScript, not the project's. Copying it into
// every project at `init` would fork it: the copy would go stale the first time
// latte fixed anything, and nothing would say so. So it is staged into the
// build directory on every build, from whichever latte the project is built
// against, and never checked in.

package cli

import std.fs
import std.os
import std.path
import std.process

/// Where `beansc` is.
///
/// The same search every `test.sh` in this workspace uses, so a compiler built
/// from the tree and an installed release are both found and neither is
/// preferred by accident. `$BEANSC` first, because that is how a gate pins the
/// compiler it means to test.
pub fn find_beansc() -> Result<string> {
    match os.env("BEANSC") {
        some(named) => {
            if fs.exists(named) { return ok(named) }
            return err("$BEANSC is {named}, and there is nothing there", "no_beansc")
        }
        none => {}
    }
    match os.env("BEANS_ROOT") {
        some(root) => {
            let built: string = path.join(path.join(root, "build"), "beansc")
            if fs.exists(built) { return ok(built) }
        }
        none => {}
    }
    match os.env("BEANS_HOME") {
        some(home) => {
            let installed: string = path.join(path.join(home, "bin"), "beansc")
            if fs.exists(installed) { return ok(installed) }
        }
        none => {}
    }
    match os.env("HOME") {
        some(user) => {
            let dot: string = path.join(path.join(path.join(user, ".beans"), "bin"), "beansc")
            if fs.exists(dot) { return ok(dot) }
        }
        none => {}
    }
    return ok("beansc")
}

/// Whether a directory is a latte checkout: the page's JavaScript is there.
///
/// `js/latte-page.js` rather than `beans.pot`, because what a canvas build
/// needs from latte is exactly this directory — a manifest would be satisfied
/// by any module at all.
fn is_latte_tree(candidate: string) -> bool {
    return fs.exists(path.join(path.join(candidate, "js"), "latte-page.js"))
}

/// Every `require path` row in a `beans.pot`, resolved against it.
///
/// A project inside the latte checkout, and one `latte init --latte <path>`
/// wrote, both reach latte this way; a project that requires it from git does
/// not, and falls through to the package cache below.
fn required_paths(root: string) -> List<string> {
    var found: List<string> = []
    let file: string = path.join(root, "beans.pot")
    match fs.read(file) {
        err(_) => { return move found }
        ok(text) => {
            for line: string in text.lines() {
                let trimmed: string = line.trim()
                if !trimmed.starts_with("require path ") { continue }
                var rest: string = trimmed.slice(13, trimmed.len()).trim()
                if rest.starts_with("\"") && rest.ends_with("\"") && rest.len() >= 2 {
                    rest = rest.slice(1, rest.len() - 1)
                }
                if rest != "" { found.push(path.join(root, rest)) }
            }
        }
    }
    return move found
}

/// The one cached checkout of a git dependency, or `""`.
///
/// `$BEANS_HOME/pkg/<remote>/<commit>` is the compiler's own layout. Two
/// commits cached and no way to tell which this project resolves to is not a
/// guess worth making, so it answers nothing and the caller says what to set.
fn cached_latte() -> string {
    var home: string = ""
    match os.env("BEANS_HOME") {
        some(named) => { home = named }
        none => {
            match os.env("HOME") {
                some(user) => { home = path.join(user, ".beans") }
                none => { return "" }
            }
        }
    }
    let base: string = path.join(path.join(home, "pkg"),
                                 "github.com/beans-lang/latte")
    if !Dir.exists(base) { return "" }
    var only: string = ""
    var count: int = 0
    match Dir.list(base) {
        err(_) => { return "" }
        ok(entries) => {
            for entry: string in entries {
                let full: string = path.join(base, entry)
                if !is_latte_tree(full) { continue }
                only = full
                count += 1
            }
        }
    }
    if count == 1 { return only }
    return ""
}

/// The latte tree a canvas build stages its page from.
///
/// `$LATTE_ROOT` first, so a person working on latte itself can point a project
/// at their checkout without editing its manifest.
pub fn find_latte(project: Project) -> Result<string> {
    match os.env("LATTE_ROOT") {
        some(named) => {
            if is_latte_tree(named) { return ok(named) }
            return err("$LATTE_ROOT is {named}, and there is no js/latte-page.js in it",
                       "no_latte")
        }
        none => {}
    }
    for candidate: string in required_paths(project.root) {
        if is_latte_tree(candidate) { return ok(candidate) }
    }
    let cached: string = cached_latte()
    if cached != "" { return ok(cached) }
    return err("cannot find latte's own tree, which a canvas build stages its page from — set $LATTE_ROOT to a latte checkout",
               "no_latte")
}

/// A Clang that can emit wasm32, and the directory holding a `wasm-ld`.
pub class WasmTools {
    pub cc: string = ""
    /// A directory to put in front of `PATH` so Clang finds `wasm-ld`, or `""`
    /// when one is already there.
    pub linker_dir: string = ""

    pub fn init(cc: string, linker_dir: string) {
        self.cc = cc
        self.linker_dir = linker_dir
    }
}

/// Whether a Clang has the wasm32 backend compiled in.
///
/// Asked rather than assumed: Apple's Clang is first on `PATH` on every Mac and
/// has no wasm32 at all, and what it produces instead of a module is a link
/// error about an unknown target that names neither Clang nor the target.
fn emits_wasm32(candidate: string) -> bool {
    var command: process.Command = new process.Command(candidate)
    command.arg("--print-targets")
    match command.run() {
        err(_) => { return false }
        ok(finished) => {
            if !finished.succeeded() { return false }
            return finished.stdout_text().contains("wasm32")
        }
    }
}

fn first_wasm_clang() -> string {
    match os.env("BEANS_WASM_CC") {
        some(named) => { return named }
        none => {}
    }
    for candidate: string in ["/opt/homebrew/opt/llvm/bin/clang",
                              "/usr/local/opt/llvm/bin/clang",
                              "clang"] {
        if emits_wasm32(candidate) { return candidate }
    }
    return ""
}

/// Whether `wasm-ld` is already reachable without help.
fn wasm_ld_on_path() -> bool {
    var command: process.Command = new process.Command("wasm-ld")
    command.arg("--version")
    match command.run() {
        err(_) => { return false }
        ok(finished) => { return finished.succeeded() }
    }
}

/// A directory holding a `wasm-ld`, or `""`.
///
/// The last candidate is the copy inside a rustup toolchain, which is on most
/// machines that have rustup and is why this works without a 1.5 GB llvm
/// install. It is looked for under the toolchains directory rather than at one
/// spelled-out path, because the triple in that path is the machine's.
fn find_wasm_ld(cc: string) -> string {
    var places: List<string> = ["/opt/homebrew/opt/lld/bin", "/usr/local/opt/lld/bin"]
    let beside: string = path.parent(cc)
    if beside != "" { places.push(beside) }
    for place: string in places {
        if fs.exists(path.join(place, "wasm-ld")) { return place }
    }
    match os.env("HOME") {
        some(user) => {
            let toolchains: string = path.join(path.join(user, ".rustup"), "toolchains")
            // Two listings and an exists, not a walk: a rustup toolchain is
            // tens of thousands of files and `Dir.walk` answers all of them.
            // The only unknown in the path is the toolchain's own triple.
            match Dir.list(toolchains) {
                err(_) => {}
                ok(named) => {
                    for toolchain: string in named {
                        let rustlib: string = path.join(
                            path.join(path.join(toolchains, toolchain), "lib"), "rustlib")
                        match Dir.list(rustlib) {
                            err(_) => {}
                            ok(triples) => {
                                for triple: string in triples {
                                    let bin: string = path.join(
                                        path.join(path.join(rustlib, triple), "bin"), "gcc-ld")
                                    if fs.exists(path.join(bin, "wasm-ld")) { return bin }
                                }
                            }
                        }
                    }
                }
            }
        }
        none => {}
    }
    return ""
}

/// The two tools a wasm build needs, or a refusal naming the one that is
/// missing and how to get it.
pub fn find_wasm_tools() -> Result<WasmTools> {
    let cc: string = first_wasm_clang()
    if cc == "" {
        return err("no Clang with a wasm32 backend — install one (brew install llvm) or set $BEANS_WASM_CC",
                   "no_wasm_cc")
    }
    if wasm_ld_on_path() { return ok(new WasmTools(cc, "")) }
    let directory: string = find_wasm_ld(cc)
    if directory == "" {
        return err("no wasm-ld to link with — install one (brew install lld), or use the copy inside a rustup toolchain",
                   "no_wasm_ld")
    }
    return ok(new WasmTools(cc, directory))
}
