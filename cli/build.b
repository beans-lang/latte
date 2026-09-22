// build.b — turning a project, a target and a profile into a `beansc` command
// line, and for a canvas project a servable directory around it.
//
// **Every build generates first.** That is why this command exists rather than
// a line in a README: markup and the code built from it are two files, and any
// process where a person can compile one without the other eventually ships the
// pair out of step — a generated file that still compiles, still renders last
// week's screen, and says nothing. Here they cannot be.
//
// **Debug and Release are `beansc`'s two flags, named.** `--debug` is `-O0`
// with frame pointers and DWARF line tables; `--release` is `-O3` with
// `NDEBUG`. Passing neither is a third mode that is unoptimised *and* has
// nothing for a debugger to attach to, which was nobody's intention. The two
// profiles write to different directories so switching never overwrites the
// other one's output, and `beansc`'s object cache keys on both flags, so
// switching back is not a rebuild.
//
// **The three wasm flags are not options.** `--target wasm32-unknown-unknown`
// is the browser target; `--runtime freestanding` is the only runtime profile
// that target takes, because there is no operating system under it; `--emit
// shared` is a module with no `_start` that exports its memory and its
// `pub extern "C"` names. Without the third the driver refuses: there is no
// application host for this target.

package cli

import std.fs
import std.io
import std.os
import std.path
import std.process

/// What a build produced.
pub class Built {
    /// The module or binary, relative to the project root.
    pub output: string = ""
    /// The directory it landed in, relative to the project root.
    pub folder: string = ""
    pub profile: string = ""
    /// True when the build wrote a page beside the module.
    pub is_page: bool = false

    pub fn init(output: string, folder: string, profile: string, is_page: bool) {
        self.output = output
        self.folder = folder
        self.profile = profile
        self.is_page = is_page
    }
}

/// Where a profile's output goes, relative to the project root.
pub fn output_path(project: Project, profile: Profile) -> string {
    if project.manifest.is_canvas() {
        return path.join(profile.out, "{project.output_name()}.wasm")
    }
    return path.join(profile.out, project.output_name())
}

/// Where an html project's browser entry lives, and what its bundle is
/// called.
///
/// A directory with a manifest of its own, because a module root holds ONE
/// entry and `main.b` is the server's. `latte build --client` builds it only
/// when it is there, so a project with no `client` region needs none of it.
pub const CLIENT_ENTRY: string = "browser/main.b"

/// The `beansc` arguments for one project and profile.
///
/// Its own function because it is what the gate asserts: an expected output
/// holding this list is how "a canvas Release build really passes --release and
/// the three wasm flags" stops being something somebody checked once by hand.
pub fn beansc_arguments(project: Project, profile: Profile,
                        output: string, wasm_cc: string) -> List<string> {
    var arguments: List<string> = ["build"]
    if project.manifest.is_canvas() {
        arguments.push("--target"); arguments.push("wasm32-unknown-unknown")
        arguments.push("--runtime"); arguments.push("freestanding")
        arguments.push("--emit"); arguments.push("shared")
        if wasm_cc != "" { arguments.push("--cc"); arguments.push(wasm_cc) }
    }
    if profile.is_release() {
        arguments.push("--release")
        // `beansc` drops LTO from a debug build anyway, so this is only ever
        // asked for where it can be honoured.
        if profile.lto { arguments.push("--lto") }
    } else {
        arguments.push("--debug")
    }
    arguments.push(project.entry)
    arguments.push("-o"); arguments.push(output)
    return move arguments
}

/// Run `beansc` in the project root and report what it said.
///
/// The whole of its output is collected and printed rather than streamed:
/// a diagnostic that interleaves two streams is one somebody has to read twice,
/// and a gate diffing this needs the order to be the same on every machine.
fn run_beansc(project: Project, arguments: List<string>, extra_path: string) -> Result<bool> {
    let compiler: string = find_beansc()?
    var command: process.Command = new process.Command(compiler)
    for one: string in arguments { command.arg(one) }
    command.cwd(project.root)
    if extra_path != "" {
        var already: string = ""
        match os.env("PATH") { some(value) => { already = value } none => {} }
        command.env("PATH", "{extra_path}:{already}")
    }
    let finished: process.Output = command.run()?
    // beansc's own output is status too: a build's diagnostics belong beside
    // latte's, on the stream a person is reading, not the one they redirect.
    let said: string = finished.stdout_text()
    let complained: string = finished.stderr_text()
    if said != "" { io.eprint(said) }
    if complained != "" { io.eprint(complained) }
    if !finished.succeeded() {
        return err("beansc exited {finished.status}", "build")
    }
    return ok(true)
}

/// The `beansc` arguments for a browser bundle.
///
/// The three wasm flags are not options: `--target wasm32-unknown-unknown`
/// is the browser target, `--runtime freestanding` is the only runtime
/// profile it takes, and `--emit shared` is a module with no `_start` that
/// exports its memory and its `pub extern "C"` names. Without the third the
/// driver refuses: there is no application host for this target.
pub fn client_arguments(profile: Profile, output: string,
                        wasm_cc: string) -> List<string> {
    var arguments: List<string> = ["build"]
    arguments.push("--target"); arguments.push("wasm32-unknown-unknown")
    arguments.push("--runtime"); arguments.push("freestanding")
    arguments.push("--emit"); arguments.push("shared")
    if wasm_cc != "" { arguments.push("--cc"); arguments.push(wasm_cc) }
    if profile.is_release() { arguments.push("--release") }
    else { arguments.push("--debug") }
    arguments.push(CLIENT_ENTRY)
    arguments.push("-o"); arguments.push(output)
    return move arguments
}

/// Where a profile's browser bundle goes, relative to the project root.
pub fn client_output(project: Project, profile: Profile) -> string {
    return path.join(profile.out, "{project.output_name()}.wasm")
}

/// Build the browser half, when the project has one.
///
/// Answers the path, or `""` when there is no `browser/main.b` — which is
/// every project with no `client` region, and is not an error.
pub fn build_client(project: Project, profile: Profile) -> Result<string> {
    let entry: string = path.join(project.root, CLIENT_ENTRY)
    if !File.exists(entry) { return ok("") }
    let output: string = client_output(project, profile)
    let folder: string = path.join(project.root, path.parent(output))
    match Dir.create_all(folder) {
        ok(_) => {}
        err(problem) => { return err("cannot make {folder}: {problem.msg}", "build") }
    }
    // Resolved before `beansc` runs: a build that compiled for a minute and
    // then found it had no linker would have wasted every second of it.
    let tools: WasmTools = find_wasm_tools()?
    run_beansc(project, client_arguments(profile, output, tools.cc),
               tools.linker_dir)?
    return ok(output)
}

/// Generate, then compile, and for a canvas project stage the page.
pub fn build_project(project: Project, profile: Profile) -> Result<Built> {
    let made: int = generate_project(project)?
    if made > 0 { io.eprintln("generated {made} file(s) from markup") }

    let output: string = output_path(project, profile)
    let folder: string = path.join(project.root, path.parent(output))
    match Dir.create_all(folder) {
        ok(_) => {}
        err(problem) => { return err("cannot make {folder}: {problem.msg}", "build") }
    }

    var wasm_cc: string = ""
    var extra_path: string = ""
    var latte_root: string = ""
    if project.manifest.is_canvas() {
        // Both are resolved before `beansc` runs. A build that compiled for
        // four minutes and then found it had no page to put the module in
        // would have wasted every one of them.
        latte_root = find_latte(project)?
        let tools: WasmTools = find_wasm_tools()?
        wasm_cc = tools.cc
        extra_path = tools.linker_dir
    }

    run_beansc(project, beansc_arguments(project, profile, output, wasm_cc), extra_path)?

    if project.manifest.is_canvas() {
        let staged: int = stage_page(project, latte_root,
                                     path.join(project.root, profile.out))?
        io.eprintln("staged {staged} file(s) around the module")
        return ok(new Built(output, profile.out, profile.name, true))
    }
    return ok(new Built(output, profile.out, profile.name, false))
}

/// Generate, then type-check. Nothing is compiled.
pub fn check_project(project: Project) -> Result<bool> {
    let made: int = generate_project(project)?
    if made > 0 { io.eprintln("generated {made} file(s) from markup") }
    return run_beansc(project, ["check", project.entry], "")
}

/// Remove a project's build directory, and `generated/` too when asked.
pub fn clean_project(project: Project, also_generated: bool) -> Result<int> {
    var removed: int = 0
    for folder: string in ["build", MIRROR_ROOT] {
        if folder == MIRROR_ROOT && !also_generated { continue }
        let full: string = path.join(project.root, folder)
        if !Dir.exists(full) { continue }
        match Dir.remove_all(full) {
            ok(_) => { removed += 1 }
            err(problem) => { return err("cannot remove {full}: {problem.msg}", "clean") }
        }
    }
    return ok(removed)
}
