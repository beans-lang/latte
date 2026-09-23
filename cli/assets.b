// assets.b — the half of a canvas build that is not the module: the page, and
// latte's JavaScript, CanvasKit and fonts staged beside it from a PageKit.

package cli

import std.fs
import std.io
import std.path

/// The JavaScript modules of latte's page half, named rather than swept so a
/// missing one is a refusal here, not a module-not-found in a browser.
pub fn page_scripts() -> List<string> {
    return ["latte-page.js", "latte-runtime.js", "latte-canvaskit.js",
            "latte-semantics.js", "latte-editing.js", "latte-input.js",
            "latte-link.js", "latte-floats.js"]
}

/// What an html application's server reads at startup, relative to its working
/// directory: web/assets.b's CLIENT_FILE and client_module_files().
pub fn html_scripts() -> List<string> {
    return ["latte.js", "latte-client.js", "latte-runtime.js", "latte-floats.js"]
}

/// The two files CanvasKit — Skia, compiled to WebAssembly — is made of.
pub fn canvaskit_files() -> List<string> {
    return ["canvaskit.js", "canvaskit.wasm"]
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

/// Copy `names` from one kit folder into `<out>/<into>/`, refusing on the
/// first one missing and naming the kit it should have come from.
fn stage_from(kit: PageKit, folder: string, names: List<string>,
              out: string, into: string, kind: string) -> Result<int> {
    var staged: int = 0
    for name: string in names {
        let source: string = path.join(folder, name)
        if !fs.exists(source) {
            return err("{source} is not there, and {kit.origin} needs it — {kit.repair}",
                       kind)
        }
        copy_into(source, path.join(path.join(out, into), name))?
        staged += 1
    }
    return ok(staged)
}

/// The fonts a build stages. A project's `font` rows win; with none, the kit's
/// three. CanvasKit reads no system fonts, so none at all draws blank controls.
fn stage_fonts(project: Project, kit: PageKit, out: string) -> Result<List<string>> {
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
    stage_from(kit, kit.fonts, default_fonts(), out, "fonts", "no_font")?
    for name: string in default_fonts() { names.push(name) }
    return ok(move names)
}

/// Escape the four characters that would end an attribute or open a tag in a
/// title a person wrote.
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

/// The page that loads the module, written on every build because every path
/// in it — the module, the fonts, CanvasKit — is the build's decision.
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
pub fn stage_page(project: Project, kit: PageKit, out: string) -> Result<int> {
    var staged: int = stage_from(kit, kit.scripts, page_scripts(), out, "latte", "no_latte")?
    staged += stage_from(kit, kit.canvaskit, canvaskit_files(), out, "canvaskit",
                         "no_canvaskit")?
    let fonts: List<string> = stage_fonts(project, kit, out)?
    staged += fonts.len()
    let page: string = path.join(out, "index.html")
    fs.write(page, page_html(project, project.output_name(), fonts))?
    return ok(staged + 1)
}

/// An html build's browser half, into `<out>/js/`, so the build folder runs
/// as it stands: `cd <out> && ./<name> serve 8080`.
pub fn stage_html_scripts(kit: PageKit, out: string) -> Result<int> {
    return stage_from(kit, kit.scripts, html_scripts(), out, "js", "no_latte")
}
