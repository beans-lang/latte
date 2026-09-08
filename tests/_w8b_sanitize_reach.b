// tests/_w8b_sanitize_reach.b — control B for `w8b_sanitize.sh`:
// **does the sanitizer reach the code `beansc` emitted?**
//
// Control A (`_w8b_sanitize_control.b`) proves the ASan runtime is under the
// build, because its allocator catches a double free without instrumenting
// anything. This one asks the harder question: an out-of-bounds READ is only
// caught if the *load itself* was instrumented, and a load in Beans-generated
// code is only instrumented if the function carrying it is marked
// `sanitize_address` in the emitted LLVM IR.
//
// On beansc 0.1.40 it is not, and this program reads 32 KiB past the end of a
// 32-byte heap block and lives. See BLOCKERS.md B15 — including the
// experiment that pins it: the same `.ll`, with `sanitize_address` added to
// its 3240 `define`s by hand and nothing else changed, is caught instantly.
//
// So the script treats this one as a **loud skip, never a silent pass**: it
// prints exactly which half of the sanitizer sweep did not run. The day the
// emitter marks its functions, this control starts being caught and the skip
// turns into an ok with no edit here.
//
// Everything it prints goes to stderr, for the reason control A gives.
package main

import std.io

const WORDS: int = 4
/// Far enough past the end that no allocator rounding could make it legal.
const PAST: int = 4096

fn main() {
    var seen: int = 0
    unsafe {
        let block: RawPtr<i64> = RawPtr.alloc(WORDS)
        for index: int in 0..WORDS { block.offset(index).write(index + 1) }
        // In bounds, so the control has a control: if THIS faulted, the
        // program would be wrong rather than the check being right.
        io.eprintln("W8B-SANITIZE-REACH in bounds {block.offset(WORDS - 1).read()}")
        // 32 KiB past the end of a 32-byte block. An instrumented load halts.
        seen = block.offset(PAST).read()
    }
    io.eprintln("W8B-SANITIZE-REACH read {PAST} words past the end and lived: {seen}")
    io.eprintln("W8B-SANITIZE-REACH generated code is NOT instrumented")
}
