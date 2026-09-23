// generate.b — the `.bx` compiler's driver. A markup folder means every `.bx`
// under it, however deep, and a source is named relative to the project root.

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
/// `generated/site/home.b`, so a generated file never sits in a source folder.
pub fn mirror_for(relative_source: string) -> string {
    // `path.parent`, not `bx.folder_of`, which answers only the last segment and
    // would mirror `site/parts/row.bx` onto a `parts/` beside `site/`.
    let folder: string = path.parent(relative_source)
    let stem: string = bx.stem_of(relative_source)
    if folder == "" { return path.join(MIRROR_ROOT, "{stem}.b") }
    return path.join(path.join(MIRROR_ROOT, folder), "{stem}.b")
}

/// Every `.bx` under a project's markup folders, relative to the root, sorted
/// so two machines generate in one order and a drift report diffs.
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
            // Not a skip: an empty markup folder means the layout moved, and a drift
            // check comparing nothing against nothing would be green forever.
            return err("{folder}/ has no .bx files in it", "no_markup")
        }
    }
    return ok(move units)
}

/// The `bx` options a project compiles its markup with, its imports spelled
/// the way its `beans.pot` reaches latte.
pub fn bx_options(project: Project) -> bx.Options {
    var options: bx.Options = new bx.Options()
    options.target = project.manifest.target
    options.latte_module = project.import_of("")
    options.canvas_module = project.import_of("compose")
    options.canvas_events_module = project.import_of("input")
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

/// Generate every markup file, writing only what changed so an unchanged
/// file keeps the mtime the object cache keys on. Answers how many were written.
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

/// Report which generated files differ from what their markup says. Writes
/// nothing: a check that fixed the drift would hide what it exists to report.
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
