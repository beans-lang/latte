// The server half, and the whole point of it is that it is not in the
// browser bundle.
//
// `browser.b` imports `modes.site` and nothing else, so nothing here is
// reachable from the WebAssembly module — `tools/client_check.mjs` asks the
// bundle what it can build and requires this package's name to be absent.
// That is a structural answer rather than a flag: there is no build switch
// to forget.
package server

import {action, actions} from latte

/// What a saved note came back as.
pub class Saved {
    pub stamp: string = ""
    pub length: int = 0
    pub fn init() {}
}

/// The store. In a real application this reaches a database, which is
/// exactly the kind of thing that must never be compiled into a page.
pub class Notes {
    pub saved: int = 0
    last: string = ""
    pub fn init() {}

    pub fn keep(body: string) -> string {
        self.saved += 1
        self.last = body
        return "note {self.saved}"
    }

    pub fn latest() -> string { return self.last }
}

/// The action group a browser region calls.
///
/// Its `init` takes the store, so the container builds it per call and the
/// action never reaches for a global.
@actions(name: "notes")
pub class NoteActions {
    store: Notes
    pub fn init(store: Notes) { self.store = store }

    /// Save a note. A `Result`, because "the note is empty" is an answer the
    /// caller should see rather than a 500 — and a Result of a STRING,
    /// because latte reads a Result back with `as?` and cannot spell a
    /// closed `Result<Saved, string>` from a descriptor. `stats` below is
    /// the shape for a structured reply.
    @action
    pub fn save(body: string) -> Result<string, string> {
        if body == "" { return err("a note needs a body") }
        if body.len() > 200 {
            return err("a note is at most 200 characters; this one is {body.len()}")
        }
        return ok(self.store.keep(body))
    }

    /// A structured reply, which needs no Result because it cannot fail.
    @action
    pub fn stats() -> Saved {
        var out: Saved = new Saved()
        out.stamp = self.store.latest()
        out.length = self.store.saved
        return out
    }

    /// One that only an editor may call, so the example carries a refusal
    /// a browser cannot talk its way past.
    @action(roles: ["editor"])
    pub fn purge() -> string { return "purged" }
}
