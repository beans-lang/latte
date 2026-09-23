// commands.b — the `latte` command line: parse once, dispatch, and turn every
// refusal into one line on stderr and a non-zero exit. Data alone goes to stdout.

package cli

import std.io
import std.os
import std.path
import latte.bx

pub fn usage() {
    io.eprintln("usage: latte <command> [options]")
    io.eprintln("")
    io.eprintln("commands:")
    io.eprintln("  init <name>    write a project: a layout, a page, and the manifests")
    io.eprintln("  build          regenerate the markup, then compile")
    io.eprintln("  check          regenerate and type-check; nothing is compiled")
    io.eprintln("  generate       compile the markup and stop")
    io.eprintln("  clean          remove the build directory")
    io.eprintln("  doctor         say what this machine can build, and what is missing")
    io.eprintln("  upgrade        replace this installation with the latest release")
    io.eprintln("  vocabulary     print latte's .bx surface as JSON, for an editor")
    io.eprintln("  version        print the version and stop")
    io.eprintln("")
    io.eprintln("options:")
    io.eprintln("  -c, --configuration <debug|release>   which profile (default: debug)")
    io.eprintln("      --release / --debug               the same two, spelled the short way")
    io.eprintln("      --target <html|canvas>            (init) which target; default html")
    io.eprintln("      --latte <path>                    (init) build against a latte checkout")
    io.eprintln("      --here                            (init) write into this directory")
    io.eprintln("      --drift                           (check) fail on a stale generated file")
    io.eprintln("      --generated                       (clean) remove generated/ as well")
    io.eprintln("      --client                          (init) scaffold browser/ too;")
    io.eprintln("                                        (build) compile it into a")
    io.eprintln("                                        WebAssembly bundle, for an")
    io.eprintln("                                        application with a client region")
    io.eprintln("      --force                           (upgrade) reinstall the same version")
    io.eprintln("      --project                         (upgrade) move this project's latte,")
    io.eprintln("                                        espresso and barista pins to this")
    io.eprintln("                                        latte's, and its lock with them")
    io.eprintln("")
    io.eprintln("An application does not need latte to build: generated/ is checked in, so a")
    io.eprintln("clone compiles with plain beansc and no latte binary present at all. This is")
    io.eprintln("what you need to write one.")
}

/// Everything the command line said, parsed once.
class Args {
    pub command: string = ""
    pub rest: List<string> = []
    pub configuration: string = ""
    pub target: string = ""
    pub latte_path: string = ""
    pub here: bool = false
    pub drift: bool = false
    pub generated: bool = false
    /// `--client`: build the browser half too, or (on init) scaffold it.
    pub client: bool = false
    pub force: bool = false
    pub project: bool = false

    pub fn init() {}
}

/// An option that takes a value, or a refusal naming what it wanted.
fn value_after(words: List<string>, index: int, option: string) -> Result<string> {
    if index + 1 >= words.len() {
        return err("{option} needs a value after it", "usage")
    }
    return ok(words[index + 1])
}

fn parse_args(words: List<string>) -> Result<Args> {
    var parsed: Args = new Args()
    if words.is_empty() { return ok(parsed) }
    parsed.command = words[0]
    var index: int = 1
    for index < words.len() {
        let word: string = words[index]
        if word == "-c" || word == "--configuration" {
            parsed.configuration = value_after(words, index, word)?
            index += 2
            continue
        }
        if word == "--release" || word == "--debug" {
            parsed.configuration = word.slice(2, word.len())
            index += 1
            continue
        }
        if word == "--target" {
            parsed.target = value_after(words, index, word)?
            index += 2
            continue
        }
        if word == "--latte" {
            parsed.latte_path = value_after(words, index, word)?
            index += 2
            continue
        }
        if word == "--here" { parsed.here = true; index += 1; continue }
        if word == "--drift" { parsed.drift = true; index += 1; continue }
        if word == "--generated" { parsed.generated = true; index += 1; continue }
        if word == "--client" { parsed.client = true; index += 1; continue }
        if word == "--force" { parsed.force = true; index += 1; continue }
        if word == "--project" { parsed.project = true; index += 1; continue }
        if word.starts_with("-") {
            return err("{word} is not an option latte has", "usage")
        }
        parsed.rest.push(word)
        index += 1
    }
    return ok(parsed)
}

/// The profile a command works in.
fn wanted_profile(manifest: AppManifest, named: string) -> Result<Profile> {
    if named == "" { return manifest.profile("debug") }
    return manifest.profile(named.to_lower())
}

// ------------------------------------------------------------------ commands

fn do_init(parsed: Args) -> Result<bool> {
    if parsed.rest.len() != 1 {
        return err("init needs one name: latte init <name>", "usage")
    }
    var target: bx.Target = bx.Target.html
    if parsed.target != "" {
        match bx.Target.of(parsed.target) {
            some(chosen) => { target = chosen }
            none => {
                return err("{parsed.target} is not a target — the two are html and canvas",
                           "usage")
            }
        }
    }
    let name: string = parsed.rest[0]
    if parsed.client {
        match target {
            canvas => {
                return err("--client scaffolds the browser half of an HTML application; a canvas project IS the browser half",
                           "usage")
            }
            html => {}
        }
    }
    let root: string = init_project(name, target, parsed.latte_path,
                                    parsed.here, parsed.client)?
    var article: string = "a"
    match target { html => { article = "an" } canvas => {} }
    io.eprintln("wrote {article} {target.name()} project in {root}/")
    io.eprintln("")
    if root == "." {
        io.eprintln("  latte build")
    } else {
        io.eprintln("  cd {root} && latte build")
    }
    match target {
        canvas => {
            io.eprintln("")
            io.eprintln("The build is a folder: open it with any static file server, e.g.")
            io.eprintln("  python3 -m http.server -d build/debug 8000")
        }
        html => {
            if parsed.client {
                io.eprintln("  latte build --client")
            }
            io.eprintln("  cd build/debug && ./{name} serve 8080")
        }
    }
    return ok(true)
}

fn do_build(parsed: Args) -> Result<bool> {
    let project: Project = open_project(".")?
    let profile: Profile = wanted_profile(project.manifest, parsed.configuration)?
    let built: Built = build_project(project, profile)?
    io.eprintln("{built.profile}: {built.output}")
    if built.is_page {
        io.eprintln("the page is {path.join(built.folder, "index.html")} — serve {built.folder}/")
    } else {
        io.eprintln("run it: cd {built.folder} && ./{project.output_name()} serve 8080")
    }
    if parsed.client {
        if project.manifest.is_canvas() {
            return err("--client builds the browser half of an HTML application; a canvas project IS the browser half and `latte build` already made it",
                       "usage")
        }
        let bundle: string = build_client(project, profile)?
        if bundle == "" {
            return err("--client needs a browser entry at {CLIENT_ENTRY}; an application with a `client` region has one, and a project written before render modes existed does not yet",
                       "usage")
        }
        io.eprintln("{built.profile}: {bundle}")
        io.eprintln("point LatteOptions.client_module at it")
    }
    return ok(true)
}

fn do_check(parsed: Args) -> Result<bool> {
    let project: Project = open_project(".")?
    if parsed.drift {
        let stale: List<string> = drifted_files(project)?
        if !stale.is_empty() {
            for one: string in stale { io.eprintln("stale: {one}") }
            return err("{stale.len()} generated file(s) are not what the markup says — run 'latte generate'",
                       "drift")
        }
        io.eprintln("no drift: every generated file is what its markup says")
        return ok(true)
    }
    check_project(project)?
    io.eprintln("checked")
    return ok(true)
}

fn do_generate() -> Result<bool> {
    let project: Project = open_project(".")?
    let made: int = generate_project(project)?
    io.eprintln("generated {made} file(s) from markup")
    return ok(true)
}

fn do_clean(parsed: Args) -> Result<bool> {
    let project: Project = open_project(".")?
    let removed: int = clean_project(project, parsed.generated)?
    io.eprintln("removed {removed} directory(s)")
    return ok(true)
}

/// `latte upgrade` replaces an installation, and the launcher in its `bin/`
/// does it; this binary only answers `--project`, or says where to go.
fn do_upgrade(parsed: Args) -> Result<bool> {
    if parsed.project {
        if parsed.force {
            return err("--force reinstalls latte itself; --project moves a project's pins — run them one at a time",
                       "usage")
        }
        let moved: int = upgrade_project(".")?
        if moved == 0 {
            io.eprintln("already on latte v{LATTE_VERSION}: nothing to move")
        } else {
            io.eprintln("moved {moved} pin(s) to latte v{LATTE_VERSION}")
        }
        return ok(true)
    }
    let home: string = latte_home()
    if home != "" {
        return err("run {home}/bin/latte upgrade — the launcher replaces the installation, and this binary was started without it",
                   "upgrade")
    }
    return err("this latte is not an installation, so there is nothing to upgrade — install a release with the one-line installer in latte's README",
               "upgrade")
}

fn do_vocabulary(parsed: Args) -> Result<bool> {
    var target: bx.Target = bx.Target.html
    if parsed.target != "" {
        match bx.Target.of(parsed.target) {
            some(chosen) => { target = chosen }
            none => {
                return err("{parsed.target} is not a target — the two are html and canvas",
                           "usage")
            }
        }
    }
    io.print(bx.vocabulary_json_for(target))
    return ok(true)
}

/// Dispatch, and turn every refusal into one line and a non-zero exit.
pub fn run_cli() {
    let words: List<string> = os.args()
    match parse_args(words) {
        err(problem) => {
            io.eprintln("latte: {problem.msg}")
            usage()
            os.exit(2)
        }
        ok(parsed) => {
            let command: string = parsed.command
            if command == "" || command == "help" || command == "--help" ||
               command == "-h" {
                usage()
                return
            }
            if command == "version" || command == "--version" {
                io.println("latte {LATTE_VERSION}")
                return
            }
            var answered: Result<bool> = ok(true)
            if command == "init" { answered = do_init(parsed) }
            else if command == "build" { answered = do_build(parsed) }
            else if command == "check" { answered = do_check(parsed) }
            else if command == "generate" { answered = do_generate() }
            else if command == "clean" { answered = do_clean(parsed) }
            else if command == "vocabulary" { answered = do_vocabulary(parsed) }
            else if command == "upgrade" { answered = do_upgrade(parsed) }
            else if command == "doctor" {
                if !run_doctor() { os.exit(1) }
            }
            else {
                io.eprintln("latte: {command} is not a command latte has")
                usage()
                os.exit(2)
            }
            match answered {
                ok(_) => {}
                err(problem) => {
                    io.eprintln("latte: {problem.msg}")
                    os.exit(1)
                }
            }
        }
    }
}
