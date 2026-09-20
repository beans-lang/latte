// The same text questions, asked of the browser's own segmenter. Browser-only,
// and its expected output differs from `browser_text.out` on purpose: see that file.
package main

import std.io
import latte.canvaskit
import latte.paint

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

pub extern "C" fn run() -> i32 as "latte_browser_text_ck_run" {
    let renderer: paint.Renderer = new canvaskit.CanvasKitRenderer()

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
