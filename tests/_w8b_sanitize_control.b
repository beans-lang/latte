// tests/_w8b_sanitize_control.b — control A for `w8b_sanitize.sh`:
// **is the AddressSanitizer runtime actually under this build?**
//
// The lesson is written down in `beans/test/sanitize.sh`, about a different
// flag, and it is the reason both controls exist:
//
//     Apple's clang accepts -fsanitize=function and emits nothing for it.
//     That asymmetry is why the Linux CI leg found the call above and a full
//     macOS `make test-sanitize` reported EXIT=0 with no skip line to read:
//     passing the flag is not evidence the check ran.
//
// A double free is caught by ASan's **allocator**, which replaces malloc and
// free process-wide the moment `libclang_rt.asan` is linked in. It needs no
// instrumented load or store anywhere, so this control answers exactly one
// question and answers it cleanly: is the sanitizer runtime present and live
// in a binary the latte build produced. If it is not, nothing else in the
// sweep means anything and the script says so instead of printing green lines.
//
// Control B is `tests/_w8b_sanitize_reach.b`, and it asks the other half of
// the question — whether the code `beansc` emits is instrumented at all.
// Keeping them apart matters: they fail for different reasons, and one of them
// is a compiler gap this lane cannot close (BLOCKERS.md B15).
//
// `unsafe` and `RawPtr` on purpose: the fault has to be one the LANGUAGE
// cannot prevent. A checked `List` index would be a Beans panic — a message
// from the program, proving nothing about whether the sanitizer is there.
//
// Everything it prints goes to stderr. `std.io` has no `flush` — it is a
// builtin package and its whole surface is println/eprintln/print/eprint/
// read_line/read_all — and stdout is fully buffered when it is a pipe, so a
// process ASan halts loses whatever stdout still held. stderr is unbuffered.
package main

import std.io

fn main() {
    unsafe {
        let block: RawPtr<i64> = RawPtr.alloc(4)
        block.write(1)
        block.offset(3).write(4)
        // In bounds and freed once: if THIS faulted, the program would be
        // wrong rather than the check being right.
        io.eprintln("W8B-SANITIZE-CONTROL in bounds {block.offset(3).read()}")
        block.free()
        // The same block again. ASan's allocator halts here.
        block.free()
    }
    io.eprintln("W8B-SANITIZE-CONTROL freed the same block twice and lived")
    io.eprintln("W8B-SANITIZE-CONTROL the AddressSanitizer runtime is NOT under this build")
}
