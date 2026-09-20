// The `latte` command line, without a filesystem.
//
// Everything here is a pure function of its inputs — a manifest's text, a
// project's shape, a target and a profile — so the whole surface a mistake
// would land in is checked without a temporary directory anywhere. What needs
// real files is the `cli` leg in test.sh, which scaffolds both targets and
// builds them; this is the half that can say *why* rather than only "it built".
//
// § 1 the manifest, § 2 what it refuses, § 3 the mirror, § 4 the beansc
// command line, § 5 names, § 6 the page.
package main

import std.io
import latte.bx
import latte.cli

fn rule(title: string) {
    io.println("")
    io.println("== {title} ==")
}

fn eq(what: string, got: string, want: string) {
    if got == want { io.println("ok {what}") }
    else {
        io.println("FAIL {what}")
        io.println("     got  {got}")
        io.println("     want {want}")
    }
}

/// A refusal's message, or the word that means it was accepted.
fn refusal(answered: Result<cli.AppManifest>) -> string {
    match answered {
        err(problem) => { return problem.msg }
        ok(_) => { return "ACCEPTED" }
    }
}

fn parsed(text: string) -> cli.AppManifest {
    match cli.parse_manifest("latte.pot", text) {
        ok(manifest) => { return manifest }
        err(problem) => {
            io.println("FAIL the manifest did not parse: {problem.msg}")
            return new cli.AppManifest()
        }
    }
}

fn a_project(name: string, manifest: cli.AppManifest) -> cli.Project {
    var project: cli.Project = new cli.Project()
    project.root = "/somewhere/{name}"
    project.module_name = name
    project.manifest = manifest
    project.markup = ["site"]
    return move project
}

fn main() {
    rule("1. every row latte.pot has")
    let whole: cli.AppManifest = parsed(r##"# a canvas application
name    drawpad
target  canvas
version 2.5.0

markup  site
markup  parts

title   "Draw Pad — beta"
font    fonts/inter.ttf
font    fonts/inter-bold.ttf

profile debug
    out build/dev
profile release
    out dist
    lto true
"##)
    eq("1.1 name", whole.name, "drawpad")
    eq("1.2 target", whole.target.name(), "canvas")
    eq("1.3 version", whole.version, "2.5.0")
    eq("1.4 markup", whole.markup.join(", "), "site, parts")
    // A quoted value keeps its spaces and its em dash, which is the whole
    // reason the tokenizer is beans.pot's rather than a split on whitespace.
    eq("1.5 a quoted title", whole.title, "Draw Pad — beta")
    eq("1.6 fonts", whole.fonts.join(", "), "fonts/inter.ttf, fonts/inter-bold.ttf")
    eq("1.7 the debug profile's out", whole.debug.out, "build/dev")
    eq("1.8 the release profile's out", whole.release.out, "dist")
    eq("1.9 lto belongs to the profile above it", "{whole.release.lto}", "true")
    eq("1.10 and not to the other one", "{whole.debug.lto}", "false")

    // A comment after a value, and a `#` inside a quote. Both are ordinary and
    // a tokenizer that split on whitespace would get one of them wrong.
    let commented: cli.AppManifest = parsed(r##"name  shop   # what it is called
title "the #1 shop"
"##)
    eq("1.11 a trailing comment is not part of the value", commented.name, "shop")
    eq("1.12 a # inside a quote is", commented.title, "the #1 shop")

    let bare: cli.AppManifest = parsed("")
    eq("1.13 an empty manifest is html", bare.target.name(), "html")
    eq("1.14 with the two default profiles",
       "{bare.debug.out} {bare.release.out}", "build/debug build/release")

    rule("2. what it refuses")
    eq("2.1 an unknown row",
       refusal(cli.parse_manifest("latte.pot", "taget canvas\n")),
       "latte.pot:1: unknown latte.pot row: taget")
    eq("2.2 a target that is not one",
       refusal(cli.parse_manifest("latte.pot", "target svg\n")),
       "latte.pot:1: 'svg' is not a target — the two are html and canvas")
    eq("2.3 a row with no value",
       refusal(cli.parse_manifest("latte.pot", "name\n")),
       "latte.pot:1: name needs exactly one value")
    eq("2.4 a row with two",
       refusal(cli.parse_manifest("latte.pot", "name one two\n")),
       "latte.pot:1: name needs exactly one value")
    eq("2.5 a profile row outside a profile",
       refusal(cli.parse_manifest("latte.pot", "out build/x\n")),
       "latte.pot:1: out belongs to a profile — put it under 'profile debug' or 'profile release'")
    eq("2.6 a third profile",
       refusal(cli.parse_manifest("latte.pot", "profile fast\n")),
       "latte.pot:1: 'fast' is not a configuration — latte has debug and release")
    eq("2.7 lto that is not a flag",
       refusal(cli.parse_manifest("latte.pot", "profile release\nlto yes\n")),
       "latte.pot:2: lto needs true or false, not 'yes'")
    eq("2.8 the same markup folder twice",
       refusal(cli.parse_manifest("latte.pot", "markup site\nmarkup site\n")),
       "latte.pot:2: markup site is written twice")
    eq("2.9 the same font twice",
       refusal(cli.parse_manifest("latte.pot", "font a.ttf\nfont a.ttf\n")),
       "latte.pot:2: font a.ttf is written twice")
    eq("2.10 a quote nobody closed",
       refusal(cli.parse_manifest("latte.pot", "title \"open\n")),
       "latte.pot:1: unterminated quoted string")
    // A top-level row closes the profile above it, so this `out` is orphaned
    // rather than quietly landing on `release`.
    eq("2.11 a top-level row closes the profile above it",
       refusal(cli.parse_manifest("latte.pot", "profile release\nname shop\nout dist\n")),
       "latte.pot:3: out belongs to a profile — put it under 'profile debug' or 'profile release'")

    rule("3. where a generated file goes")
    eq("3.1 one folder deep", cli.mirror_for("site/home.bx"), "generated/site/home.b")
    eq("3.2 and deeper", cli.mirror_for("site/parts/row.bx"), "generated/site/parts/row.b")
    eq("3.3 a file at the root", cli.mirror_for("home.bx"), "generated/home.b")

    rule("4. the beansc command line")
    // The four combinations, printed whole. A test that asserted "it passes
    // --release" would pass on a canvas build that had lost --emit shared.
    let html_app: cli.Project = a_project("shopfront", parsed("target html\n"))
    let canvas_app: cli.Project = a_project("drawpad", parsed("target canvas\n"))
    eq("4.1 html, debug",
       cli.beansc_arguments(html_app, html_app.manifest.debug,
                            cli.output_path(html_app, html_app.manifest.debug), "").join(" "),
       "build --debug main.b -o build/debug/shopfront")
    eq("4.2 html, release",
       cli.beansc_arguments(html_app, html_app.manifest.release,
                            cli.output_path(html_app, html_app.manifest.release), "").join(" "),
       "build --release main.b -o build/release/shopfront")
    eq("4.3 canvas, debug",
       cli.beansc_arguments(canvas_app, canvas_app.manifest.debug,
                            cli.output_path(canvas_app, canvas_app.manifest.debug), "/usr/bin/clang").join(" "),
       "build --target wasm32-unknown-unknown --runtime freestanding --emit shared --cc /usr/bin/clang --debug main.b -o build/debug/drawpad.wasm")
    let with_lto: cli.AppManifest = parsed("target canvas\nprofile release\n    lto true\n")
    let lto_app: cli.Project = a_project("drawpad", with_lto)
    eq("4.4 canvas, release, lto",
       cli.beansc_arguments(lto_app, lto_app.manifest.release,
                            cli.output_path(lto_app, lto_app.manifest.release), "cc").join(" "),
       "build --target wasm32-unknown-unknown --runtime freestanding --emit shared --cc cc --release --lto main.b -o build/release/drawpad.wasm")
    // The name a build is called by: latte.pot's, and the module's when it
    // says nothing.
    let unnamed: cli.Project = a_project("shopfront", parsed("target html\n"))
    eq("4.5 an unnamed project is called after its module", unnamed.output_name(), "shopfront")
    let renamed: cli.Project = a_project("shopfront", parsed("name Storefront\n"))
    eq("4.6 and a named one after its name", renamed.output_name(), "Storefront")

    rule("5. a name that can be a module")
    eq("5.1 a word", "{cli.is_module_name("drawpad")}", "true")
    eq("5.2 with an underscore and a digit", "{cli.is_module_name("draw_pad2")}", "true")
    eq("5.3 starting with a digit", "{cli.is_module_name("9lives")}", "false")
    eq("5.4 with a dash", "{cli.is_module_name("draw-pad")}", "false")
    eq("5.5 with a dot", "{cli.is_module_name("draw.pad")}", "false")
    eq("5.6 nothing at all", "{cli.is_module_name("")}", "false")

    rule("6. the page a canvas build writes")
    let page: string = cli.page_html(renamed, "drawpad", ["latte-regular.ttf", "latte-mono.ttf"])
    eq("6.1 the title is the manifest's name", "{page.contains("<title>Storefront</title>")}", "true")
    eq("6.2 the module is named by the build", "{page.contains("module: \"drawpad.wasm\"")}", "true")
    eq("6.3 every staged font is registered",
       "{page.contains("\"fonts/latte-regular.ttf\",")} {page.contains("\"fonts/latte-mono.ttf\",")}",
       "true true")
    // The page's own stylesheet sizes the canvas and latte owns only the
    // backing store. A page that pinned the canvas could not follow a window.
    eq("6.4 the stylesheet sizes the canvas",
       "{page.contains(r"canvas { display: block; width: 100%; height: 100%; }")}", "true")
    eq("6.5 every path in it is relative, so it serves under any prefix",
       "{page.contains("src=\"canvaskit/canvaskit.js\"")} {page.contains("\"./latte/latte-page.js\"")}",
       "true true")
    let titled: cli.Project = a_project("shopfront", parsed("title \"Ada & Co <hats>\"\n"))
    eq("6.6 a title with markup characters is escaped",
       "{cli.page_html(titled, "shopfront", []).contains("<title>Ada &amp; Co &lt;hats&gt;</title>")}",
       "true")
}
