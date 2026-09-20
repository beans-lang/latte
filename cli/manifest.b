// manifest.b — `latte.pot`, the application's own manifest.
//
// `beans.pot` says what a module is and what it depends on. It cannot say what
// an *application* is: the compiler refuses a row it does not know, so which of
// latte's two targets a project renders with, what its page is called, and
// which fonts it ships have nowhere to live in it. This is that file, beside
// it, in the same shape:
//
//     name    myapp
//     target  canvas
//     version 0.1.0
//
//     markup  site
//
//     title   My Application
//     font    fonts/inter.ttf
//
//     profile debug
//         out build/debug
//     profile release
//         out build/release
//         lto true
//
// Three decisions worth a sentence each.
//
// **An unknown row is refused, not ignored.** That is `beans.pot`'s rule and it
// is the right one: a manifest that silently drops `taget canvas` gives you an
// HTML build and nothing to read about why.
//
// **The tokenizer is `beans.pot`'s.** Whitespace separates words, `"` quotes
// one, `\` escapes inside a quote, and `#` or `//` outside a quote ends the
// line. A page title is a sentence with spaces in it, so it could not be
// written without this.
//
// **Indentation means nothing.** `profile` opens a block and the rows that only
// make sense inside one belong to the profile above them. The indentation above
// is for a person; a parser that depended on it would refuse a re-tabbed file.

package cli

import std.fs
import std.path
import latte.bx

/// One build configuration. Two, and only two, for the reason `beansc` has
/// two flags: `--debug` is `-O0` with frame pointers and DWARF line tables and
/// `--release` is `-O3` with `NDEBUG`. Passing neither is a third mode that is
/// unoptimised *and* has nothing for a debugger to attach to.
pub class Profile {
    /// `debug` or `release`.
    pub name: string = ""
    /// Where the build is written, relative to the project root.
    pub out: string = ""
    /// Link-time optimization. `beansc` refuses it in a debug build, so it is
    /// ignored rather than refused there.
    pub lto: bool = false

    pub fn init(name: string, out: string) {
        self.name = name
        self.out = out
    }

    pub fn is_release() -> bool { return self.name == "release" }
}

/// What `latte.pot` said.
pub class AppManifest {
    /// What the build is called: the binary for html, the module for canvas.
    /// Empty means take `beans.pot`'s `module` line.
    pub name: string = ""
    /// Which of latte's two targets this application renders with.
    pub target: bx.Target = bx.Target.html
    pub version: string = "0.1.0"
    /// The folders holding `.bx` markup, relative to the project root.
    pub markup: List<string> = []
    /// The canvas page's `<title>`. Empty means take the application's name.
    pub title: string = ""
    /// Fonts staged into a canvas build. CanvasKit ships none and cannot read
    /// the system's, so a page that registers none draws every control in the
    /// right place with no words in it.
    pub fonts: List<string> = []
    pub debug: Profile = new Profile("debug", "build/debug")
    pub release: Profile = new Profile("release", "build/release")
    /// Whether a `latte.pot` was read at all. A project without one still
    /// builds — every field above has an answer — and renders html, which is
    /// what latte meant before it had a second target.
    pub present: bool = false

    pub fn init() {}

    pub fn profile(named: string) -> Result<Profile> {
        if named == "debug" { return ok(self.debug) }
        if named == "release" { return ok(self.release) }
        return err("{named} is not a configuration — latte has debug and release",
                   "profile")
    }

    pub fn is_canvas() -> bool {
        return match self.target { canvas => true, html => false }
    }
}

/// Tokenize one line the way `beans.pot` is tokenized.
///
/// Comments only start outside quotes, so a title may contain a `#` and a font
/// path may contain a `//`. An unterminated quote collapses the line to one
/// sentinel word, which the caller turns into a diagnostic naming the line.
fn manifest_words(line: string) -> List<string> {
    var words: List<string> = []
    var word: string = ""
    var started: bool = false
    var quoted: bool = false
    var escaping: bool = false
    var index: int = 0
    for index < line.len() {
        let byte: int = line.byte_at(index)
        if quoted {
            if escaping {
                word = "{word}{line.slice(index, index + 1)}"
                escaping = false
            } else if byte == 92 {
                escaping = true
            } else if byte == 34 {
                quoted = false
            } else {
                word = "{word}{line.slice(index, index + 1)}"
            }
            index += 1
            continue
        }
        if byte == 34 {
            quoted = true
            started = true
            index += 1
            continue
        }
        let slash_comment: bool =
            byte == 47 && index + 1 < line.len() && line.byte_at(index + 1) == 47
        if byte == 35 || slash_comment { break }
        if byte == 32 || byte == 9 || byte == 13 {
            if started {
                words.push(word)
                word = ""
                started = false
            }
        } else {
            word = "{word}{line.slice(index, index + 1)}"
            started = true
        }
        index += 1
    }
    if started { words.push(word) }
    if quoted || escaping { words = ["$manifest-error:unterminated-quote$"] }
    return move words
}

fn read_flag(file: string, line_number: int, row: string,
             written: string) -> Result<bool> {
    if written == "true" { return ok(true) }
    if written == "false" { return ok(false) }
    return err("{file}:{line_number}: {row} needs true or false, not '{written}'",
               "manifest")
}

/// Parse the text of a `latte.pot`.
///
/// Separated from reading the file so a refusal can be checked without a
/// temporary directory, which is how every row below is covered.
pub fn parse_manifest(file: string, text: string) -> Result<AppManifest> {
    var manifest: AppManifest = new AppManifest()
    manifest.present = true
    var open_profile: string = ""
    var line_number: int = 0
    for line: string in text.lines() {
        line_number += 1
        let words: List<string> = manifest_words(line)
        if words.is_empty() { continue }
        if words.len() == 1 && words[0] == "$manifest-error:unterminated-quote$" {
            return err("{file}:{line_number}: unterminated quoted string", "manifest")
        }
        let row: string = words[0]

        if row == "profile" {
            if words.len() != 2 {
                return err("{file}:{line_number}: profile needs a name", "manifest")
            }
            if words[1] != "debug" && words[1] != "release" {
                return err("{file}:{line_number}: '{words[1]}' is not a configuration — latte has debug and release",
                           "manifest")
            }
            open_profile = words[1]
            continue
        }

        // The rows that only mean something inside a profile. Above the first
        // `profile` line they are a mistake with an obvious shape, so name that
        // rather than refusing the word.
        if row == "out" || row == "lto" {
            if open_profile == "" {
                return err("{file}:{line_number}: {row} belongs to a profile — put it under 'profile debug' or 'profile release'",
                           "manifest")
            }
            if words.len() != 2 {
                return err("{file}:{line_number}: {row} needs exactly one value", "manifest")
            }
            var into: Profile = manifest.debug
            if open_profile == "release" { into = manifest.release }
            if row == "out" { into.out = words[1] }
            else { into.lto = read_flag(file, line_number, row, words[1])? }
            continue
        }

        // A top-level row closes the profile above it, so a `name` written
        // after a profile block is the application's and not a profile row.
        open_profile = ""

        if row == "name" || row == "version" || row == "title" {
            if words.len() != 2 {
                return err("{file}:{line_number}: {row} needs exactly one value", "manifest")
            }
            if row == "name" { manifest.name = words[1] }
            else if row == "version" { manifest.version = words[1] }
            else { manifest.title = words[1] }
            continue
        }
        if row == "target" {
            if words.len() != 2 {
                return err("{file}:{line_number}: target needs a name — html or canvas", "manifest")
            }
            match bx.Target.of(words[1]) {
                some(chosen) => { manifest.target = chosen }
                none => {
                    return err("{file}:{line_number}: '{words[1]}' is not a target — the two are html and canvas",
                               "manifest")
                }
            }
            continue
        }
        if row == "markup" || row == "font" {
            if words.len() != 2 {
                return err("{file}:{line_number}: {row} needs exactly one path", "manifest")
            }
            if row == "markup" {
                for seen: string in manifest.markup {
                    if seen == words[1] {
                        return err("{file}:{line_number}: markup {words[1]} is written twice", "manifest")
                    }
                }
                manifest.markup.push(words[1])
            } else {
                for seen: string in manifest.fonts {
                    if seen == words[1] {
                        return err("{file}:{line_number}: font {words[1]} is written twice", "manifest")
                    }
                }
                manifest.fonts.push(words[1])
            }
            continue
        }
        return err("{file}:{line_number}: unknown latte.pot row: {row}", "manifest")
    }
    return ok(manifest)
}

/// Read `latte.pot` from a project root.
///
/// A project without one is not an error: every field has a default and the
/// default target is html, which is what a latte application meant before
/// there was a second target to choose.
pub fn read_manifest(root: string) -> Result<AppManifest> {
    let file: string = path.join(root, "latte.pot")
    if !fs.exists(file) {
        var absent: AppManifest = new AppManifest()
        return ok(absent)
    }
    let text: string = fs.read(file)?
    return parse_manifest(file, text)
}
