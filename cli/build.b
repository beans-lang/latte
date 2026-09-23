// build.b — a project, a target and a profile turned into a `beansc` command
// line; every build regenerates the markup first, so the two halves never drift.

package cli

import std.fs
import std.io
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

/// An html project's browser entry: a module of its own, because a module
/// root holds ONE entry and `main.b` is the server's.
pub const CLIENT_ENTRY: string = "browser/main.b"

/// The `beansc` arguments for one project and profile — its own function so
/// tests/cli.b can hold every flag a canvas Release build passes.
pub fn beansc_arguments(project: Project, profile: Profile,
                        output: string, wasm_cc: string,
                        linker: string = "") -> List<string> {
    var arguments: List<string> = ["build"]
    if project.manifest.is_canvas() {
        push_wasm_flags(arguments, wasm_cc, linker)
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

/// The three wasm flags every browser build passes, then the tools. Without
/// `--emit shared` the driver refuses: there is no application host for wasm32.
fn push_wasm_flags(arguments: List<string>, wasm_cc: string, linker: string) {
    arguments.push("--target"); arguments.push("wasm32-unknown-unknown")
    arguments.push("--runtime"); arguments.push("freestanding")
    arguments.push("--emit"); arguments.push("shared")
    if wasm_cc != "" { arguments.push("--cc"); arguments.push(wasm_cc) }
    if linker != "" { arguments.push("--linker"); arguments.push(linker) }
}

/// Run `beansc` in `folder` and print what it said, collected rather than
/// streamed so both streams read in one order. The environment is inherited whole.
fn run_beansc_in(folder: string, arguments: List<string>) -> Result<bool> {
    let compiler: string = find_beansc()?
    var command: process.Command = new process.Command(compiler)
    for one: string in arguments { command.arg(one) }
    command.cwd(folder)
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

fn run_beansc(project: Project, arguments: List<string>) -> Result<bool> {
    return run_beansc_in(project.root, arguments)
}

/// The `beansc` arguments for an html project's browser bundle.
pub fn client_arguments(profile: Profile, output: string,
                        wasm_cc: string, linker: string = "") -> List<string> {
    var arguments: List<string> = ["build"]
    push_wasm_flags(arguments, wasm_cc, linker)
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

/// Build the browser half, answering its path, or `""` when there is no
/// `browser/main.b` — every project with no `client` region, and not an error.
pub fn build_client(project: Project, profile: Profile) -> Result<string> {
    let entry: string = path.join(project.root, CLIENT_ENTRY)
    if !File.exists(entry) { return ok("") }
    let output: string = client_output(project, profile)
    let folder: string = path.join(project.root, path.parent(output))
    match Dir.create_all(folder) {
        ok(_) => {}
        err(problem) => { return err("cannot make {folder}: {problem.msg}", "build") }
    }
    // Resolved before `beansc` runs, so a missing linker costs no compile.
    let tools: WasmTools = find_wasm_tools()?
    run_beansc(project, client_arguments(profile, output, tools.cc, tools.linker))?
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

    // Before `beansc` runs, so a missing kit or linker costs no compile.
    let kit: PageKit = find_page_kit(project)?
    var tools: WasmTools = new WasmTools("", "")
    if project.manifest.is_canvas() { tools = find_wasm_tools()? }

    run_beansc(project, beansc_arguments(project, profile, output, tools.cc, tools.linker))?

    if project.manifest.is_canvas() {
        let staged: int = stage_page(project, kit,
                                     path.join(project.root, profile.out))?
        io.eprintln("staged {staged} file(s) around the module, from {kit.origin}")
        return ok(new Built(output, profile.out, profile.name, true))
    }
    let scripts: int = stage_html_scripts(kit, path.join(project.root, profile.out))?
    io.eprintln("staged {scripts} browser script(s) beside the binary, from {kit.origin}")
    return ok(new Built(output, profile.out, profile.name, false))
}

/// Generate, then type-check. Nothing is compiled.
pub fn check_project(project: Project) -> Result<bool> {
    let made: int = generate_project(project)?
    if made > 0 { io.eprintln("generated {made} file(s) from markup") }
    return run_beansc(project, ["check", project.entry])
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
