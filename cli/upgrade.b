// upgrade.b — `latte upgrade --project`: move a project's pins to this latte's,
// then `beansc pot update` so the lock moves with them, or neither moves.

package cli

import std.fs
import std.io
import std.path

pub const ESPRESSO_REMOTE: string = "github.com/beans-lang/espresso"
pub const BARISTA_REMOTE: string = "github.com/beans-lang/barista"

/// One pin that moves.
pub class Repin {
    pub remote: string = ""
    pub from: string = ""
    pub to: string = ""

    pub fn init(remote: string, from: string, to: string) {
        self.remote = remote
        self.from = from
        self.to = to
    }
}

/// The pins in a `beans.pot` that differ from this latte's. espresso and
/// barista move too, and only when the project already names them.
pub fn repins_for(pot_text: string) -> List<Repin> {
    var moves: List<Repin> = []
    let remotes: List<string> = [LATTE_REMOTE, ESPRESSO_REMOTE, BARISTA_REMOTE]
    let wanted: List<string> = ["v{LATTE_VERSION}", ESPRESSO_PIN, BARISTA_PIN]
    var index: int = 0
    for index < remotes.len() {
        let have: string = required_ref(pot_text, remotes[index])
        if have != "" && have != wanted[index] {
            moves.push(new Repin(remotes[index], have, wanted[index]))
        }
        index += 1
    }
    return move moves
}

/// `pot_text` with each moved row's ref replaced in place, so a comment or
/// the spacing a person chose on that line survives.
pub fn repinned_text(pot_text: string, moves: List<Repin>) -> string {
    var lines: List<string> = []
    for line: string in pot_text.split("\n") {
        let words: List<string> = manifest_words(line)
        var written: string = line
        if words.len() == 3 && words[0] == "require" {
            for one: Repin in moves {
                if words[1] != one.remote || words[2] != one.from { continue }
                match line.find(one.remote) {
                    some(at) => {
                        let after: int = at + one.remote.len()
                        let tail: string = line.slice(after, line.len())
                        match tail.find(one.from) {
                            some(offset) => {
                                let start: int = after + offset
                                written = "{line.slice(0, start)}{one.to}{line.slice(start + one.from.len(), line.len())}"
                            }
                            none => {}
                        }
                    }
                    none => {}
                }
            }
        }
        lines.push(written)
    }
    return lines.join("\n")
}

/// Move one manifest's pins and its lock. A failed `pot update` puts the
/// manifest back, so the pin and the lock never disagree.
fn repin_manifest(folder: string, label: string) -> Result<int> {
    let file: string = path.join(folder, "beans.pot")
    let before: string = fs.read(file)?
    let moves: List<Repin> = repins_for(before)
    if moves.is_empty() { return ok(0) }
    fs.write(file, repinned_text(before, moves))?
    // One remote moved: update that one alone. More: every row at once,
    // because moving them one by one passes through a graph with two refs.
    var arguments: List<string> = ["pot", "update"]
    if moves.len() == 1 { arguments.push(moves[0].remote) }
    match run_beansc_in(folder, arguments) {
        ok(_) => {}
        err(problem) => {
            fs.write(file, before)?
            return err("beansc could not resolve the new pins in {label}, so it is back as it was ({problem.msg})",
                       "upgrade")
        }
    }
    for one: Repin in moves {
        io.eprintln("{label}: {one.remote} {one.from} -> {one.to}")
    }
    return ok(moves.len())
}

/// `latte upgrade --project`, from anywhere inside a project.
pub fn upgrade_project(start: string) -> Result<int> {
    let root: string = find_root(start)?
    let pot: string = fs.read(path.join(root, "beans.pot"))?
    if required_ref(pot, LATTE_REMOTE) == "" {
        for candidate: string in required_paths(root, pot) {
            if is_latte_tree(candidate) {
                return err("this project builds against the latte checkout at {candidate} by path, so it has no pin to move",
                           "upgrade")
            }
        }
        return err("this project does not require {LATTE_REMOTE}, so there is nothing to move",
                   "upgrade")
    }
    var moved: int = repin_manifest(root, "beans.pot")?
    let browser: string = path.join(root, "browser")
    if fs.exists(path.join(browser, "beans.pot")) {
        moved += repin_manifest(browser, "browser/beans.pot")?
    }
    return ok(moved)
}
