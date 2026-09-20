// project.b — what a latte project is, and how a command finds it.
//
// A project is a directory with a `beans.pot` in it. That is not a second
// definition of anything: it is the compiler's own rule — `find_root` in
// beans/src/module.b walks up from a file to the nearest manifest — so a
// command run from `site/` and the same command run from the root do the same
// work on the same files.
//
// **Markup folders are named, and anything outside them is refused.** A project
// says `markup site`, or says nothing and gets `site` if it exists. Either way
// the whole project is swept for `.bx` files no markup root covers, and one
// found is an error. A screen that is never regenerated is a screen that still
// compiles, still renders last week's design, and says nothing.

package cli

import std.fs
import std.path

/// Where a project is, and what is in it.
pub class Project {
    /// The directory holding `beans.pot`.
    pub root: string = ""
    /// The module name `beans.pot` declares.
    pub module_name: string = ""
    /// The entry file, relative to the root.
    pub entry: string = "main.b"
    pub manifest: AppManifest = new AppManifest()
    /// The folders holding `.bx` markup, relative to the root.
    pub markup: List<string> = []

    pub fn init() {}

    /// What the build is called: `latte.pot`'s name, else the module name.
    pub fn output_name() -> string {
        if self.manifest.name != "" { return self.manifest.name }
        return self.module_name
    }

    /// The page's `<title>`: `latte.pot`'s, else the application's name.
    pub fn page_title() -> string {
        if self.manifest.title != "" { return self.manifest.title }
        return self.output_name()
    }
}

/// The directory names a sweep never descends into.
///
/// `generated` holds this tool's own output, `build` holds the compiler's,
/// `node_modules` is somebody else's, and a dot directory is tooling. None can
/// hold a source `.bx` a person wrote, and walking them makes a sweep of a real
/// project cost the whole tree.
fn skipped_directory(name: string) -> bool {
    return name == "generated" || name == "build" || name == "node_modules" ||
           name.starts_with(".")
}

/// The nearest directory at or above `start` holding a `beans.pot`.
pub fn find_root(start: string) -> Result<string> {
    var here: string = start
    // A relative path runs out of parents before it runs out of directories —
    // `path.parent(".")` is `""` — so a walk from `.` would look in one
    // directory and stop. Starting from the absolute working directory is what
    // lets the walk climb.
    if here == "" || here == "." { here = Dir.current() }
    var depth: int = 0
    for depth < 64 {
        if fs.exists(path.join(here, "beans.pot")) { return ok(here) }
        var up: string = path.parent(here)
        if up == "" {
            if here == "." { break }
            up = "."
        }
        if up == here { break }
        here = up
        depth += 1
    }
    return err("no beans.pot here or above — run this in a project, or make one with 'latte init <name>'",
               "no_project")
}

/// The `module` line from a `beans.pot`.
fn read_module_name(root: string) -> Result<string> {
    let file: string = path.join(root, "beans.pot")
    let text: string = fs.read(file)?
    for line: string in text.lines() {
        let trimmed: string = line.trim()
        if !trimmed.starts_with("module ") { continue }
        let rest: string = trimmed.slice(7, trimmed.len()).trim()
        if rest != "" { return ok(rest) }
    }
    return err("{file}: no 'module <name>' line", "manifest")
}

/// Every `.bx` file in the project that no markup root covers.
///
/// A screen in a folder nobody declared is the failure this tool exists to make
/// impossible, so it is an error with the fix in it rather than a file quietly
/// left ungenerated.
fn orphan_markup(root: string, covered: List<string>) -> Result<List<string>> {
    var orphans: List<string> = []
    for under: string in Dir.walk(root)? {
        if !under.ends_with(".bx") { continue }
        var inside: bool = false
        for folder: string in covered {
            if under == folder || under.starts_with("{folder}/") { inside = true }
        }
        if inside { continue }
        // `Dir.walk` has no filter, so output and tooling are skipped by
        // looking at the path it answered.
        var hidden: bool = false
        for piece: string in under.split("/") {
            if skipped_directory(piece) { hidden = true }
        }
        if hidden { continue }
        orphans.push(under)
    }
    return ok(move orphans)
}

/// The first path segment of a relative path, which is the folder a `markup`
/// row would name.
fn top_folder(relative: string) -> string {
    let pieces: List<string> = relative.split("/")
    if pieces.is_empty() { return relative }
    return pieces[0]
}

/// The markup folders: what `latte.pot` said, or the one the scaffolder writes,
/// and then a sweep proving nothing was left out.
fn resolve_markup(root: string, manifest: AppManifest) -> Result<List<string>> {
    var folders: List<string> = []
    if !manifest.markup.is_empty() {
        for named: string in manifest.markup {
            if !Dir.exists(path.join(root, named)) {
                return err("latte.pot says 'markup {named}', and {named}/ is not there",
                           "no_markup")
            }
            folders.push(named)
        }
    } else {
        for guess: string in ["site", "screens", "pages"] {
            if Dir.exists(path.join(root, guess)) { folders.push(guess) }
        }
    }

    let orphans: List<string> = orphan_markup(root, folders)?
    if !orphans.is_empty() {
        var shown: string = orphans[0]
        let extra: int = orphans.len() - 1
        if extra > 0 { shown = "{shown} (and {extra} more)" }
        return err("{shown} is outside every markup folder, so nothing would regenerate it — add 'markup {top_folder(orphans[0])}' to latte.pot",
                   "no_markup")
    }
    if folders.is_empty() {
        return err("this project has no markup folder — add 'markup <dir>' to latte.pot",
                   "no_markup")
    }
    return ok(move folders)
}

/// Open the project containing `start`.
pub fn open_project(start: string) -> Result<Project> {
    let root: string = find_root(start)?
    var project: Project = new Project()
    project.root = root
    project.module_name = read_module_name(root)?
    project.manifest = read_manifest(root)?
    project.markup = resolve_markup(root, project.manifest)?
    if !fs.exists(path.join(root, project.entry)) {
        return err("{root}/main.b is not there — a latte application's entry is main.b, beside beans.pot",
                   "no_entry")
    }
    return ok(project)
}
