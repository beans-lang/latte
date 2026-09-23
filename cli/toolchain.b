// toolchain.b — finding what a build needs that is not in the project: `beansc`,
// and for a WebAssembly build a Clang with a wasm32 backend and a `wasm-ld`.

package cli

import std.fs
import std.os
import std.path
import std.process
import std.target

/// `.exe` on Windows, where a program's file name carries it.
fn exe_suffix() -> string {
    if target.os() == "windows" { return ".exe" }
    return ""
}

/// Where `beansc` is: `$BEANSC`, a tree build under `$BEANS_ROOT`, an install
/// under `$BEANS_HOME` or `~/.beans`, then `PATH` — every test.sh's order.
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
            let built: string = path.join(path.join(root, "build"), "beansc{exe_suffix()}")
            if fs.exists(built) { return ok(built) }
        }
        none => {}
    }
    // An installed Windows compiler must be reached through its launcher,
    // which sets the source roots; beansc.real.exe alone cannot build.
    var launcher: string = "beansc"
    if target.os() == "windows" { launcher = "beansc.cmd" }
    match os.env("BEANS_HOME") {
        some(home) => {
            let installed: string = path.join(path.join(home, "bin"), launcher)
            if fs.exists(installed) { return ok(installed) }
        }
        none => {}
    }
    match os.env("HOME") {
        some(user) => {
            let dot: string = path.join(path.join(path.join(user, ".beans"), "bin"), launcher)
            if fs.exists(dot) { return ok(dot) }
        }
        none => {}
    }
    // Where beans-install.ps1 puts it on Windows.
    match os.env("LOCALAPPDATA") {
        some(local) => {
            let user_install: string = path.join(path.join(path.join(local, "Beans"), "bin"), launcher)
            if fs.exists(user_install) { return ok(user_install) }
        }
        none => {}
    }
    return ok(launcher)
}

/// A Clang that can emit wasm32, and the `wasm-ld` it links with.
pub class WasmTools {
    pub cc: string = ""
    /// A full path handed to `beansc --linker`, or `""` when `wasm-ld` is
    /// already on `PATH` and Clang finds it unaided.
    pub linker: string = ""

    pub fn init(cc: string, linker: string) {
        self.cc = cc
        self.linker = linker
    }
}

/// Whether a Clang has the wasm32 backend. Asked, not assumed: Apple's Clang
/// is first on `PATH` on every Mac and has none.
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
                              "C:/Program Files/LLVM/bin/clang.exe",
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

/// A full path to a `wasm-ld`, or `""`. The last place is the copy inside a
/// rustup toolchain, found by listing rather than walking tens of thousands of files.
fn find_wasm_ld(cc: string) -> string {
    let name: string = "wasm-ld{exe_suffix()}"
    var places: List<string> = ["/opt/homebrew/opt/lld/bin", "/usr/local/opt/lld/bin"]
    let beside: string = path.parent(cc)
    if beside != "" { places.push(beside) }
    for place: string in places {
        if fs.exists(path.join(place, name)) { return path.join(place, name) }
    }
    match os.env("HOME") {
        some(user) => {
            let toolchains: string = path.join(path.join(user, ".rustup"), "toolchains")
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
                                    if fs.exists(path.join(bin, name)) {
                                        return path.join(bin, name)
                                    }
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

/// The two tools a wasm build needs, or a refusal naming the missing one.
pub fn find_wasm_tools() -> Result<WasmTools> {
    let cc: string = first_wasm_clang()
    if cc == "" {
        return err("no Clang with a wasm32 backend — install one (brew install llvm, apt install clang, or LLVM for Windows) or set $BEANS_WASM_CC",
                   "no_wasm_cc")
    }
    if wasm_ld_on_path() { return ok(new WasmTools(cc, "")) }
    let linker: string = find_wasm_ld(cc)
    if linker == "" {
        return err("no wasm-ld to link with — install one (brew install lld, apt install lld), or use the copy inside a rustup toolchain",
                   "no_wasm_ld")
    }
    return ok(new WasmTools(cc, linker))
}
