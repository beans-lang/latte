// Does a float print the same in a browser as it does natively?
//
// A freestanding WebAssembly module has no libc, so the Beans runtime asks its
// host to turn a double into text. In a browser that host is JavaScript, and
// JavaScript's spelling is not C's: it keeps trailing zeros, it reaches for
// exponent notation at a different magnitude, and it writes `e+5` where C
// writes `e+05`. `js/latte-floats.js` builds C's shape on top of JavaScript's
// correctly-rounded digits, and this is what holds it to that claim.
//
// It is not a test of the formatter's cleverness. It is a diff: the same
// program on three backends, one golden. A difference here is a browser
// showing a different number from the one the server logged, which is the
// worst kind of wrong because both look right on their own.
package main

import std.io

fn show(name: string, value: f64) {
    io.println("{name} = {value}")
}

pub extern "C" fn run() -> i32 as "latte_floats_run" {
    // Ordinary numbers, where nothing interesting happens and a difference
    // would mean the shortest-round-trip search disagrees.
    show("one and a half", 1.5)
    show("a third", 1.0 / 3.0)
    show("minus a half", -0.5)
    show("forty two", 42.0)
    show("zero", 0.0)

    // The place-value/exponent boundary. C's %g switches at an exponent of
    // -4 and at the digit count; JavaScript switches at -7 and at 21.
    show("ten thousandths", 0.0001)
    show("a hundred thousandth", 0.00001)
    show("a hundred", 100.0)
    show("a million", 1000000.0)
    show("ten to the twenty", 100000000000000000000.0)
    show("ten to the twenty one", 1000000000000000000000.0)

    // Values whose shortest round-trip needs every one of the seventeen
    // digits. A formatter that stopped early prints a number that reads back
    // as something else.
    show("a tenth", 0.1)
    show("two tenths", 0.2)
    show("a tenth plus two tenths", 0.1 + 0.2)
    show("largest double", 179769313486231570000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000.0)

    // The rounding decision %g makes on the exponent of the *rounded* value:
    // 9.99 at two significant digits is 10, not 9.9e+00.
    show("nine point nine nine", 9.99)
    show("nine nine nine nine", 9999.0)

    // Arithmetic a layout does, so the numbers a control reports are in the
    // same set the gates compare.
    show("a scale", 2.0)
    show("a half scale", 0.5)
    show("a third of a point", 13.0 / 3.0)
    show("a wide paragraph", 85.80000000000001)

    // Negative zero is a different value from zero and prints differently.
    show("negative zero", -0.0)
    return 0
}

fn main() { run() }
