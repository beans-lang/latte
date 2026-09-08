// tests/_w8b_leak_control.b — the positive control for `w8b_leaks.sh`.
//
// RULES.md, "the refusal that never runs": a check needs a control beside it,
// or you cannot tell "found nothing" from "did not look". Every other program
// that script runs is expected to report zero leaked bytes, and a `leaks` that
// cannot examine the process at all reports zero too — with a report line, an
// exit status of 0, and a node count that looks entirely plausible. macOS says
// so out loud in every one of those reports:
//
//     Process N is not debuggable. Due to security restrictions, leaks can
//     only show or save contents of readonly memory of restricted processes.
//
// So this program leaks a KNOWN amount on purpose, through the same build, the
// same `BEANS_NO_POOL=1`, and the same `leaks --atExit`, and the script
// requires the tool to find it. If this one ever reports zero, every zero
// beside it is worthless and the script says so and fails.
//
// Why `RawPtr` and not a reference cycle: Beans reclaims a cycle. The cycle
// collector is precisely what the rest of the sweep is there to check, so a
// control built out of one would be testing the thing under test. An `unsafe`
// allocation the program never frees is outside ARC altogether, so it leaks
// whatever the collector does, and it leaks the same number of bytes on every
// run — which is what makes the expected total a constant the script can
// assert rather than a threshold it has to guess.
//
// The bytes: 8 blocks of 512 i64 = 32768 asked for. Each block is written and
// read back and folded into the printed total, so nothing here is dead code an
// optimiser may drop — a control the compiler deleted would report zero and
// read exactly like a `leaks` that could not look.
//
// **The number `leaks` reports is NOT 32768 and the script must not assert it
// is.** Observed on this host: `7 leaks for 35840 total leaked bytes` — seven,
// because the last block's pointer is still live in a register or a stack slot
// when the process exits and a still-reachable block is not a leak; and 5120
// bytes each, because that is the malloc size class a 4096-byte request lands
// in. Both numbers are properties of the allocator and the codegen, not of
// this program, so the script asserts a floor (most of the blocks, most of the
// bytes) and PRINTS what it saw.
package main

import std.io

const BLOCKS: int = 8
const WORDS_PER_BLOCK: int = 512
const BYTES_PER_BLOCK: int = WORDS_PER_BLOCK * 8

fn main() {
    var total: int = 0
    unsafe {
        for block: int in 0..BLOCKS {
            let held: RawPtr<i64> = RawPtr.alloc(WORDS_PER_BLOCK)
            for index: int in 0..WORDS_PER_BLOCK {
                held.offset(index).write(1)
            }
            for index: int in 0..WORDS_PER_BLOCK {
                total += held.offset(index).read()
            }
            // No free. That is the entire point of this file.
        }
    }
    io.println("W8B-LEAK-CONTROL wrote {total} words in {BLOCKS} blocks")
    io.println("W8B-LEAK-CONTROL leaks {BLOCKS * BYTES_PER_BLOCK} bytes on purpose")
}
