// The text questions a real renderer answers differently, and the two goldens
// differ on purpose: the browser's is `browser_text.browser.out`.
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
