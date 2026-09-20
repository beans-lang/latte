// The text questions a real renderer answers differently.
//
// `headless.MetricRenderer` measures from a stated advance and carries the
// joins a caret must not split; it does not carry the whole Unicode
// segmentation table. `latte.canvaskit` asks the browser's `Intl.Segmenter`,
// which does. Both are right for what they are for, and the difference is
// something a reader has to be able to see — so this file prints the same
// questions and the browser leg answers them.
//
// It runs on three backends. Under the interpreter and natively there is no
// browser, so `MetricRenderer` answers and its limits show; in a page the same
// program reaches CanvasKit. **The two goldens are different on purpose**, and
// `tools/browser_gate.mjs` knows it: this suite's browser golden is
// `browser_text.browser.out`.
package main

import std.io
import latte.headless
import latte.paint

/// Whichever renderer this backend has. A page installs CanvasKit's; anything
/// else gets the measuring one.
fn renderer_for_this_backend() -> paint.Renderer {
    return new headless.MetricRenderer()
}

fn offsets(renderer: paint.Renderer, text: string, grapheme: bool) -> string {
    var out: List<string> = []
    let answer: Result<List<int>> = if grapheme { renderer.graphemes(text) }
                                    else { renderer.words(text) }
    match answer {
        ok(list) => { for at: int in list { out.push("{at}") } }
        err(problem) => { return "refused: {problem.msg}" }
    }
    return out.join(" ")
}

pub extern "C" fn run() -> i32 as "latte_browser_text_run" {
    let renderer: paint.Renderer = renderer_for_this_backend()

    io.println("== graphemes ==")
    io.println("plain: {offsets(renderer, "abc", true)}")
    io.println("accent: {offsets(renderer, "Zoë", true)}")
    io.println("family: {offsets(renderer, "👩‍👩‍👧‍👦", true)}")
    io.println("flag: {offsets(renderer, "🇯🇵", true)}")
    io.println("skin tone: {offsets(renderer, "👋🏽", true)}")
    io.println("arabic: {offsets(renderer, "مرحبا", true)}")

    io.println("")
    io.println("== words ==")
    io.println("plain: {offsets(renderer, "one two", false)}")
    io.println("punctuation: {offsets(renderer, "a, b", false)}")
    io.println("arabic: {offsets(renderer, "مرحبا bonjour", false)}")
    return 0
}

fn main() { run() }
