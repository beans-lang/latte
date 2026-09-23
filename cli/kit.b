// kit.b — where a build's browser half comes from: latte's JavaScript, CanvasKit
// (Skia) and fonts, chosen by the project's own latte row so they match its code.

package cli

import std.fs
import std.os
import std.path

/// The remote a project requires latte by.
pub const LATTE_REMOTE: string = "github.com/beans-lang/latte"

/// The three folders a build's browser half is staged from, and their source.
pub class PageKit {
    /// latte's `js/`.
    pub scripts: string = ""
    /// `canvaskit.js` and `canvaskit.wasm`.
    pub canvaskit: string = ""
    /// The `.ttf` files a page registers when a project names none.
    pub fonts: string = ""
    /// Named in every refusal, so a missing file says which kit it is from.
    pub origin: string = ""
    /// What fixes a missing file in this kind of kit.
    pub repair: string = ""

    pub fn init(scripts: string, canvaskit: string, fonts: string,
                origin: string, repair: string) {
        self.scripts = scripts
        self.canvaskit = canvaskit
        self.fonts = fonts
        self.origin = origin
        self.repair = repair
    }
}

/// A latte checkout's kit: `js/`, npm's CanvasKit, and `build/fonts/`.
pub fn checkout_kit(root: string) -> PageKit {
    return new PageKit(path.join(root, "js"),
                       path.join(root, "node_modules/canvaskit-wasm/bin"),
                       path.join(path.join(root, "build"), "fonts"),
                       "the latte checkout at {root}",
                       "run 'npm install' and 'node tools/font_prepare.mjs' in {root}")
}

/// Where an installation keeps its kit.
pub fn share_dir(home: string) -> string {
    return path.join(path.join(home, "share"), "latte")
}

/// An installed latte's kit: `share/latte/` beside its `bin/`.
pub fn installed_kit(home: string) -> PageKit {
    let share: string = share_dir(home)
    return new PageKit(path.join(share, "js"), path.join(share, "canvaskit"),
                       path.join(share, "fonts"),
                       "this latte's own kit in {share}",
                       "this installation is damaged — reinstall it with 'latte upgrade --force'")
}

/// The installation this binary was started from, or `""`. The launcher in
/// `bin/` sets it; nothing guesses a default for a binary run from elsewhere.
pub fn latte_home() -> string {
    match os.env("LATTE_HOME") {
        some(home) => { return home }
        none => { return "" }
    }
}

/// Whether a directory is a latte checkout: the page's JavaScript is there,
/// which a bare `beans.pot` would not prove.
pub fn is_latte_tree(candidate: string) -> bool {
    return fs.exists(path.join(path.join(candidate, "js"), "latte-page.js"))
}

/// The ref a `require <remote> <ref>` row pins, or `""`. beansc's own rule: a
/// git row is exactly three words, so a `require path` row never matches.
pub fn required_ref(pot_text: string, remote: string) -> string {
    for line: string in pot_text.lines() {
        let words: List<string> = manifest_words(line)
        if words.len() == 3 && words[0] == "require" && words[1] == remote {
            return words[2]
        }
    }
    return ""
}

/// How a project's source names latte: the git path when it is pinned, else
/// `latte`, the module name a `require path` row binds.
pub fn latte_import_root(pot_text: string) -> string {
    if required_ref(pot_text, LATTE_REMOTE) != "" { return LATTE_REMOTE }
    return "latte"
}

/// One of latte's packages as such a project imports it. `app` and `client`
/// are modules of their own, so by module name they are `latte_app`, `latte_client`.
pub fn latte_import(root: string, name: string) -> string {
    if root == "latte" {
        if name == "" { return "latte" }
        if name == "app" || name == "client" { return "latte_{name}" }
        return "latte.{name}"
    }
    if name == "" { return root }
    return "{root}/{name}"
}

/// Every `require path` row in a `beans.pot`, resolved against its folder.
pub fn required_paths(root: string, pot_text: string) -> List<string> {
    var found: List<string> = []
    for line: string in pot_text.lines() {
        let words: List<string> = manifest_words(line)
        if words.len() == 3 && words[0] == "require" && words[1] == "path" {
            found.push(path.join(root, words[2]))
        }
    }
    return move found
}

/// One `key=value` line of a VERSION file, or `""`.
pub fn version_field(text: string, key: string) -> string {
    for line: string in text.lines() {
        let trimmed: string = line.trim()
        if trimmed.starts_with("{key}=") {
            return trimmed.slice(key.len() + 1, trimmed.len()).trim()
        }
    }
    return ""
}

/// The latte version an installation's kit was packaged for, or `""`.
pub fn kit_version(home: string) -> string {
    match fs.read(path.join(share_dir(home), "VERSION")) {
        ok(text) => { return version_field(text, "latte") }
        err(_) => { return "" }
    }
}

/// Why an installed kit cannot serve a project pinned at `pinned`, or `""`
/// when it can. Pure, so tests/cli.b covers every branch.
pub fn pin_mismatch(pinned: string, home: string, installed: string) -> string {
    if home == "" {
        return "this project requires latte {pinned}, and a build stages latte's browser half from an installed latte's kit — this latte was not started from an installation. Install latte, or set $LATTE_ROOT to a latte checkout at {pinned}"
    }
    if installed == "" {
        return "{share_dir(home)}/VERSION is not there, so nothing says which latte this kit is for — reinstall with 'latte upgrade --force'"
    }
    if pinned != "v{installed}" {
        return "this project requires latte {pinned}, and this latte's page kit is for v{installed}: the browser half would not match the code it talks to. Run 'latte upgrade --project' to move the project to v{installed}, or set $LATTE_ROOT to a latte checkout at {pinned}"
    }
    return ""
}

/// The kit a project's browser half is staged from: `$LATTE_ROOT`, else a
/// checkout a `require path` row names, else the installed kit its pin matches.
pub fn find_page_kit(project: Project) -> Result<PageKit> {
    match os.env("LATTE_ROOT") {
        some(named) => {
            if is_latte_tree(named) { return ok(checkout_kit(named)) }
            return err("$LATTE_ROOT is {named}, and there is no js/latte-page.js in it",
                       "no_latte")
        }
        none => {}
    }
    let pot: string = fs.read(path.join(project.root, "beans.pot"))?
    for candidate: string in required_paths(project.root, pot) {
        if is_latte_tree(candidate) { return ok(checkout_kit(candidate)) }
    }
    let pinned: string = required_ref(pot, LATTE_REMOTE)
    if pinned == "" {
        return err("this project requires latte neither from git nor by path, so there is no browser half to stage — add 'require {LATTE_REMOTE} v{LATTE_VERSION}' to beans.pot",
                   "no_latte")
    }
    let home: string = latte_home()
    var installed: string = ""
    if home != "" { installed = kit_version(home) }
    let problem: string = pin_mismatch(pinned, home, installed)
    if problem != "" { return err(problem, "no_latte") }
    return ok(installed_kit(home))
}
