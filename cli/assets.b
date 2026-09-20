// assets.b — the half of a canvas build that is not the WebAssembly module.
//
// A canvas application is a module plus a page that loads it, and the page's
// half is latte's: the runtime, the CanvasKit bridge, the accessibility and
// editing hosts, the fonts CanvasKit has none of. None of it is checked into a
// project. It is staged into the build directory on every build, so a latte
// that fixed something is a rebuild away rather than a copy somebody has to
// notice went stale.
//
// What a canvas build writes:
//
//     build/debug/
//     ├── index.html      written here, from the project's name and title
//     ├── <name>.wasm     the module
//     ├── latte/          latte's js/, whole
//     ├── canvaskit/      canvaskit.js and canvaskit.wasm
//     └── fonts/          what the page registers
//
// The directory is servable as it stands: every path in the page is relative to
// it, so it works under any prefix and from the file system.

package cli

import std.fs
import std.io
import std.path

/// The JavaScript modules that make up latte's page half, in latte's `js/`.
///
/// Named rather than swept so a file that disappears is a refusal here instead
/// of a module-not-found in somebody's browser. `latte-page.js` imports the
/// rest, so the browser only ever asks for what it needs.
pub fn page_scripts() -> List<string> {
    return ["latte-page.js", "latte-runtime.js", "latte-canvaskit.js",
            "latte-semantics.js", "latte-editing.js", "latte-input.js",
            "latte-link.js", "latte-floats.js"]
}

/// The fonts a page registers when the project names none.
pub fn default_fonts() -> List<string> {
    return ["latte-regular.ttf", "latte-medium.ttf", "latte-bold.ttf"]
}

fn copy_into(from: string, to: string) -> Result<bool> {
    let folder: string = path.parent(to)
    match Dir.create_all(folder) {
        ok(_) => {}
        err(problem) => { return err("cannot make {folder}: {problem.msg}", "stage") }
    }
    fs.copy(from, to)?
    return ok(true)
}

/// Stage latte's `js/` into `<out>/latte/`.
fn stage_scripts(latte_root: string, out: string) -> Result<int> {
    let from: string = path.join(latte_root, "js")
    var staged: int = 0
    for name: string in page_scripts() {
        let source: string = path.join(from, name)
        if !fs.exists(source) {
            return err("{source} is not there — $LATTE_ROOT does not look like a latte checkout",
                       "no_latte")
        }
        copy_into(source, path.join(path.join(out, "latte"), name))?
        staged += 1
    }
    return ok(staged)
}

/// Stage CanvasKit out of latte's `node_modules`.
///
/// CanvasKit is an npm package and latte does not vendor it, so a checkout
/// nobody has run `npm install` in has none. The refusal says that rather than
/// letting the page fail on a 404 for a file whose absence looks like a typo.
fn stage_canvaskit(latte_root: string, out: string) -> Result<int> {
    let from: string = path.join(latte_root, "node_modules/canvaskit-wasm/bin")
    var staged: int = 0
    for name: string in ["canvaskit.js", "canvaskit.wasm"] {
        let source: string = path.join(from, name)
        if !fs.exists(source) {
            return err("{source} is not there — run 'npm install' in {latte_root}",
                       "no_canvaskit")
        }
        copy_into(source, path.join(path.join(out, "canvaskit"), name))?
        staged += 1
    }
    return ok(staged)
}

/// The fonts a build stages, as (source, name) pairs.
///
/// A project's own `font` rows win; with none, latte's prepared three are used.
/// CanvasKit ships no fonts and cannot read the system's, so a page that
/// registers none lays every paragraph out as zero glyphs — the controls appear
/// in the right places with no words in any of them and nothing reports an
/// error. That is why having none is a refusal here rather than a warning.
fn stage_fonts(project: Project, latte_root: string, out: string) -> Result<List<string>> {
    var names: List<string> = []
    if !project.manifest.fonts.is_empty() {
        for named: string in project.manifest.fonts {
            let source: string = path.join(project.root, named)
            if !fs.exists(source) {
                return err("latte.pot says 'font {named}', and it is not there", "no_font")
            }
            let name: string = path.name(named)
            copy_into(source, path.join(path.join(out, "fonts"), name))?
            names.push(name)
        }
        return ok(move names)
    }
    let from: string = path.join(path.join(latte_root, "build"), "fonts")
    for name: string in default_fonts() {
        let source: string = path.join(from, name)
        if !fs.exists(source) {
            return err("no fonts to register: {source} is not there. Run 'node tools/font_prepare.mjs' in {latte_root}, or name your own with a 'font' row in latte.pot",
                       "no_font")
        }
        copy_into(source, path.join(path.join(out, "fonts"), name))?
        names.push(name)
    }
    return ok(move names)
}

/// Escape the four characters that would end an attribute or open a tag.
///
/// The title comes from a manifest a person wrote, so it is not hostile — but a
/// title with an apostrophe in it is ordinary, and a page that broke on one
/// would be a bug reported as "latte cannot render my app's name".
fn escape_html(text: string) -> string {
    var out: string = ""
    var index: int = 0
    for index < text.len() {
        let byte: int = text.byte_at(index)
        let one: string = text.slice(index, index + 1)
        if byte == 38 { out = "{out}&amp;" }
        else if byte == 60 { out = "{out}&lt;" }
        else if byte == 62 { out = "{out}&gt;" }
        else if byte == 34 { out = "{out}&quot;" }
        else { out = "{out}{one}" }
        index += 1
    }
    return out
}

/// The page that loads the module.
///
/// It is written on every build rather than scaffolded once, because every path
/// in it is decided by the build: the module's name, which fonts were staged,
/// where CanvasKit landed. A page checked into the project would be a second
/// place those answers live.
pub fn page_html(project: Project, module_name: string, fonts: List<string>) -> string {
    var registered: List<string> = []
    for name: string in fonts { registered.push("      \"fonts/{name}\",") }
    let opening: string = r##"<!doctype html>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>"##
    let styling: string = r##"</title>
<style>
  html, body { margin: 0; height: 100%; }
  body { display: grid; grid-template-rows: 1fr; background: #ececed; }
  /* The canvas is the application. Latte owns the backing store and this
     stylesheet owns the size, which is what lets the interface follow the
     window — see "Who decides how big the canvas is" in latte's docs. */
  #host { position: relative; background: #fff; overflow: hidden; }
  canvas { display: block; width: 100%; height: 100%; }
  #problem {
    position: absolute; inset: 0; display: none; place-content: center;
    padding: 24px; font: 12px ui-monospace, monospace; color: #b42318;
    background: #fff5f4; white-space: pre-wrap;
  }
  @media (prefers-color-scheme: dark) {
    body { background: #16171a; } #host { background: #1d1f24; }
  }
</style>
<div id="host">
  <canvas id="canvas"></canvas>
  <pre id="problem"></pre>
</div>
<!-- CanvasKit ships as a UMD script rather than an ES module: importing it
     asks for a default export it has not got. -->
<script src="canvaskit/canvaskit.js"></script>
<script type="module">
import { LattePage } from "./latte/latte-page.js";

const problem = document.getElementById("problem");
const show = (message) => {
  problem.style.display = "grid";
  problem.textContent = message;
};

try {
  const canvasKit = await CanvasKitInit({
    locateFile: (file) => `canvaskit/${file}`,
  });
  const page = await LattePage.load({
    element: document.getElementById("canvas"),
    canvasKit,
    module: ""##
    let after_module: string = r##"",
    // CanvasKit has no fonts of its own and cannot read the system's.
    fonts: [
"##
    let closing: string = r##"    ],
    semanticsRoot: document.getElementById("host"),
    editingRoot: document.getElementById("host"),
    onError: show,
  });
  await page.mount();
  window.__lattePage = page;
} catch (error) {
  show(String((error && error.stack) || error));
}
</script>
"##
    let pieces: List<string> = [
        opening, escape_html(project.page_title()), styling,
        "{module_name}.wasm", after_module, registered.join("\n"), "\n", closing,
    ]
    return pieces.join("")
}

/// Everything a canvas build needs beside the module.
pub fn stage_page(project: Project, latte_root: string, out: string) -> Result<int> {
    var staged: int = stage_scripts(latte_root, out)?
    staged += stage_canvaskit(latte_root, out)?
    let fonts: List<string> = stage_fonts(project, latte_root, out)?
    staged += fonts.len()
    let page: string = path.join(out, "index.html")
    fs.write(page, page_html(project, project.output_name(), fonts))?
    return ok(staged + 1)
}
