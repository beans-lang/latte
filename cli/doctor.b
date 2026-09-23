// doctor.b — `latte doctor`: one line per thing a build needs, the fix beside
// each missing one, and a non-zero exit when something this project needs is missing.

package cli

import std.fmt
import std.fs
import std.io
import std.path
import std.process

/// Whether dotted version `have` is at least `floor`, compared number by
/// number so 0.1.100 is newer than 0.1.44. A non-number compares as zero.
pub fn version_at_least(have: string, floor: string) -> bool {
    let mine: List<string> = have.split(".")
    let needed: List<string> = floor.split(".")
    var index: int = 0
    for index < needed.len() {
        var a: int = 0
        var b: int = 0
        if index < mine.len() {
            match mine[index].to_int() { ok(value) => { a = value } err(_) => {} }
        }
        match needed[index].to_int() { ok(value) => { b = value } err(_) => {} }
        if a > b { return true }
        if a < b { return false }
        index += 1
    }
    return true
}

/// The version word in `beansc --version`'s answer, or `""`.
pub fn beansc_version_of(answer: string) -> string {
    let words: List<string> = answer.trim().split(" ")
    if words.len() >= 2 && words[0] == "beansc" { return words[1] }
    return ""
}

/// Collects the report and remembers whether any required line failed.
class Report {
    pub failed: bool = false
    pub fn init() {}

    fn line(status: string, what: string, detail: string) {
        io.println("  {fmt.pad_right(status, 8)} {fmt.pad_right(what, 13)} {detail}")
    }
    pub fn good(what: string, detail: string) { self.line("ok", what, detail) }
    pub fn note(what: string, detail: string) { self.line("-", what, detail) }
    pub fn bad(what: string, detail: string) {
        self.failed = true
        self.line("MISSING", what, detail)
    }
}

/// Every file an installed kit must hold, relative to `share/latte/`.
pub fn kit_files() -> List<string> {
    var files: List<string> = ["VERSION"]
    for name: string in page_scripts() { files.push("js/{name}") }
    for name: string in canvaskit_files() { files.push("canvaskit/{name}") }
    for name: string in default_fonts() { files.push("fonts/{name}") }
    return move files
}

fn check_installation(report: Report) {
    let home: string = latte_home()
    if home == "" {
        report.note("installation", "none — this latte was not started from bin/latte, so it has no page kit; a checkout build does not need one")
        return
    }
    report.good("installation", home)
    let share: string = share_dir(home)
    for relative: string in kit_files() {
        if !fs.exists(path.join(share, relative)) {
            report.bad("page kit", "{share}/{relative} is not there — reinstall with 'latte upgrade --force'")
            return
        }
    }
    let installed: string = kit_version(home)
    if installed != LATTE_VERSION {
        report.bad("page kit", "{share} is for latte {installed}, and this binary is {LATTE_VERSION} — reinstall with 'latte upgrade --force'")
        return
    }
    var canvaskit: string = "?"
    match fs.read(path.join(share, "VERSION")) {
        ok(text) => { canvaskit = version_field(text, "canvaskit") }
        err(_) => {}
    }
    report.good("page kit", "latte {installed}, CanvasKit (Skia) {canvaskit}")
}

fn check_beansc(report: Report) {
    var compiler: string = ""
    match find_beansc() {
        ok(found) => { compiler = found }
        err(problem) => { report.bad("beansc", problem.msg); return }
    }
    var command: process.Command = new process.Command(compiler)
    command.arg("--version")
    match command.run() {
        err(problem) => {
            report.bad("beansc", "{compiler} did not start ({problem.msg}) — install Beans: https://github.com/beans-lang/beans#install")
        }
        ok(finished) => {
            let answer: string = finished.stdout_text().trim()
            let version: string = beansc_version_of(answer)
            if !finished.succeeded() || version == "" {
                report.bad("beansc", "{compiler} --version said '{answer}'")
            } else if !version_at_least(version, BEANS_FLOOR) {
                report.bad("beansc", "{answer} is older than {BEANS_FLOOR} — run 'beansc upgrade'")
            } else {
                report.good("beansc", "{answer} ({compiler})")
            }
        }
    }
}

/// The wasm tools: required for a canvas project or a browser half, and a note
/// anywhere else, because an html-only project never touches them.
fn check_wasm(report: Report, needed: bool) {
    match find_wasm_tools() {
        ok(tools) => {
            report.good("wasm clang", tools.cc)
            if tools.linker == "" { report.good("wasm-ld", "on PATH") }
            else { report.good("wasm-ld", tools.linker) }
        }
        err(problem) => {
            if needed { report.bad("wasm tools", problem.msg) }
            else { report.note("wasm tools", "{problem.msg} (only a canvas build or --client needs them)") }
        }
    }
}

/// `latte doctor`. Answers false when a required line failed.
pub fn run_doctor() -> bool {
    var report: Report = new Report()
    io.println("latte {LATTE_VERSION}")
    check_installation(report)
    check_beansc(report)
    match find_root(".") {
        err(_) => {
            check_wasm(report, false)
            report.note("project", "none here — run this inside one to check what it needs")
        }
        ok(root) => {
            match open_project(root) {
                err(problem) => {
                    check_wasm(report, false)
                    report.bad("project", "{root}: {problem.msg}")
                }
                ok(project) => {
                    let browser_half: bool = fs.exists(path.join(root, CLIENT_ENTRY))
                    check_wasm(report, project.manifest.is_canvas() || browser_half)
                    var pinned: string = "by path"
                    match fs.read(path.join(root, "beans.pot")) {
                        ok(text) => {
                            let pin: string = required_ref(text, LATTE_REMOTE)
                            if pin != "" { pinned = pin }
                        }
                        err(_) => {}
                    }
                    report.good("project", "{root}: {project.manifest.target.name()}, latte {pinned}")
                    match find_page_kit(project) {
                        ok(kit) => { report.good("page", kit.origin) }
                        err(problem) => { report.bad("page", problem.msg) }
                    }
                }
            }
        }
    }
    return !report.failed
}
