// The same text questions, asked of the browser's own segmenter.
//
// A browser-only suite: it imports `latte.canvaskit`, whose every entry is an
// undefined symbol outside a WebAssembly module, so there is no interpreter
// leg and no native one. `test.sh` builds a `_browser_`-named suite for the
// page and nothing else.
//
// Its golden is deliberately **not** `browser_text.out`. That one is what
// `headless.MetricRenderer` answers, and the difference between the two is the
// point: the measuring renderer carries the joins a caret must not split, and
// a real one carries the whole Unicode table. A flag is one grapheme here and
// two there, and a reader should be able to see exactly that rather than find
// it later in a caret that lands in the middle of a flag.
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
