// tests/_w8b_tsan_reach.b — control C for `w8b_sanitize.sh`:
// **does ThreadSanitizer reach the code `beansc` emitted?**
//
// The same question control B (`_w8b_sanitize_reach.b`) asks about ASan, and
// it has to be asked separately because the answer could differ: TSan
// instruments the memory accesses of functions marked `sanitize_thread`, ASan
// those of functions marked `sanitize_address`, and they are two attributes.
// If neither is emitted, then "TSan reported no race" on five suites means
// "TSan watched `beans_rt.c` and nothing else", and five green lines would be
// saying far less than they look like they say.
//
// The race: two OS threads, each writing a plain (non-atomic) `i64` through
// the same `RawPtr`, with no synchronisation between them and a join after.
// `examples/unsafe_raw.b` in the beans tree does the same shape with
// `atomic_fetch_add`, which is exactly what makes it NOT a race; this uses
// `write`, which is one.
//
// Both writes are emitted by the compiler, not by the runtime, so a report
// here means the generated code is instrumented and a silence means it is not.
// Either way the answer is printed rather than assumed.
//
// stderr for the same reason the other two controls use it: `std.io` has no
// flush and stdout to a pipe is fully buffered.
package main

import std.io
import std.thread

const ROUNDS: int = 200000

fn main() {
    unsafe {
        let cell: RawPtr<i64> = RawPtr.alloc(1)
        cell.write(0)
        let first: Thread<int> = thread.spawn(fn() -> int {
            unsafe {
                var i: int = 0
                for i < ROUNDS { cell.write(cell.read() + 1); i += 1 }
            }
            return 0
        })
        let second: Thread<int> = thread.spawn(fn() -> int {
            unsafe {
                var i: int = 0
                for i < ROUNDS { cell.write(cell.read() + 1); i += 1 }
            }
            return 0
        })
        let a: int = first.join()
        let b: int = second.join()
        io.eprintln("W8B-TSAN-REACH two threads raced on one word, joined {a + b}")
        cell.free()
    }
}
