// generate.b — the `.bx` compiler's driver.
//
// Two rules, both about not missing a file.
//
// **A markup folder stands for every `.bx` under it, however deep.** A shell
// glob is not recursive: `site/*.bx` silently misses `site/parts/`, and what
// that produces is a *stale* generated file that still compiles, still renders
// last week's screen, and says nothing. A markup folder with no `.bx` in it is
// an error rather than no work.
//
// **A source is always named relative to the project root.** The path goes into
// the generated file's header, so spelling it `./site/home.bx` from inside the
// project and `myapp/site/home.bx` from above it would write two different
// files and a drift check would call one of them stale. The file is read at its
// full path and compiled under its short one, so where the command was run
// never reaches the output.

package cli

import std.fs
import std.path
import std.io
import latte.bx

/// One `.bx` and where its generated half goes.
pub class Unit {
    /// The source, relative to the project root.
    pub source: string = ""
    /// The generated Beans, relative to the project root.
    pub output: string = ""

    pub fn init(source: string, output: string) {
        self.source = source
        self.output = output
    }
}

/// The root every mirror hangs off, relative to the project root.
pub const MIRROR_ROOT: string = "generated"

/// Where one source's generated half goes: `site/home.bx` becomes
/// `generated/site/home.b`, and the folders under a markup root are kept.
///
/// The mirror rather than a `_gen.b` beside the source, for both targets: a
/// folder holding only markup can be read at a glance, and a generated file
/// that is never in a source folder cannot be mistaken for one to edit.
pub fn mirror_for(relative_source: string) -> string {
    // `path.parent`, not `bx.folder_of`: the latter answers the last segment of
    // the directory because it names a package, so `site/parts/row.bx` would
    // mirror to `generated/parts/` and collide with a `parts/` beside `site/`.
    let folder: string = path.parent(relative_source)
    let stem: string = bx.stem_of(relative_source)
    if folder == "" { return path.join(MIRROR_ROOT, "{stem}.b") }
    return path.join(path.join(MIRROR_ROOT, folder), "{stem}.b")
}

/// Every `.bx` under a project's markup folders, sorted, relative to the root.
///
/// `Dir.walk` answers a sorted list, so the order two machines generate in is
/// the same one — which a drift check depends on for its output to be diffable.
pub fn markup_units(project: Project) -> Result<List<Unit>> {
    var units: List<Unit> = []
    for folder: string in project.markup {
        let full: string = path.join(project.root, folder)
        var found: int = 0
        for under: string in Dir.walk(full)? {
            if !under.ends_with(".bx") { continue }
            let relative: string = path.join(folder, under)
            units.push(new Unit(relative, mirror_for(relative)))
            found += 1
        }
        if found == 0 {
            // Not a skip. A markup folder that is empty means the layout moved,
            // and a generator that shrugged would leave a drift check comparing
            // nothing against nothing, green forever.
            return err("{folder}/ has no .bx files in it", "no_markup")
        }
    }
    return ok(move units)
}

/// The `bx` options a project compiles its markup with.
pub fn bx_options(project: Project) -> bx.Options {
    var options: bx.Options = new bx.Options()
    options.target = project.manifest.target
    return move options
}

/// Compile one unit and answer the Beans it produced.
pub fn compile_unit(project: Project, unit: Unit,
                    options: bx.Options) -> Result<string> {
    let full: string = path.join(project.root, unit.source)
    let text: string = fs.read(full)?
    // Compiled under its short name, read at its full one: the header the
    // generated file carries must not depend on where this was run.
    let compiled: bx.Compiled = bx.compile_source(text, unit.source, options)
    if !compiled.is_ok() {
        return err(compiled.report(unit.source), "markup")
    }
    return ok(compiled.source)
}

/// Generate every markup file in the project, writing only what changed.
///
/// Answers how many files were written. Unchanged files are left alone so a
/// build does not touch a mtime the compiler's object cache keys on — a
/// regenerate that rewrote every file identically would make every build a
/// full rebuild.
pub fn generate_project(project: Project) -> Result<int> {
    let units: List<Unit> = markup_units(project)?
    let options: bx.Options = bx_options(project)
    var written: int = 0
    for unit: Unit in units {
        let source: string = compile_unit(project, unit, options)?
        let target: string = path.join(project.root, unit.output)
        if fs.exists(target) {
            match fs.read(target) {
                ok(already) => { if already == source { continue } }
                err(_) => {}
            }
        }
        let folder: string = path.parent(target)
        match Dir.create_all(folder) {
            ok(_) => {}
            err(problem) => {
                return err("cannot make {folder}: {problem.msg}", "generate")
            }
        }
        fs.write(target, source)?
        written += 1
    }
    return ok(written)
}

/// Generate into a scratch root and report which files differ from what is
/// checked in. Nothing in the project is written.
///
/// A check that "fixed" the drift would hide exactly the change it exists to
/// report, so this one cannot write.
pub fn drifted_files(project: Project) -> Result<List<string>> {
    let units: List<Unit> = markup_units(project)?
    let options: bx.Options = bx_options(project)
    var stale: List<string> = []
    for unit: Unit in units {
        let source: string = compile_unit(project, unit, options)?
        let target: string = path.join(project.root, unit.output)
        if !fs.exists(target) { stale.push(unit.output); continue }
        match fs.read(target) {
            ok(already) => { if already != source { stale.push(unit.output) } }
            err(_) => { stale.push(unit.output) }
        }
    }
    return ok(move stale)
}
