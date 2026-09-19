// Floating-point text for a freestanding WebAssembly module.
//
// The Beans runtime asks its host for two things it will not attempt itself:
// turn a double into decimal text, and read one back. Correct double-to-decimal
// is a page of subtle code and a freestanding module has no libc to borrow one
// from — but a browser has a correctly-rounded implementation of both in the
// language, so the page is the right place to ask.
//
// **The hard part is not the digits, it is the spelling.** The runtime's own
// callers expect C's `%g` and `%.*f`, because that is what the native backend
// prints, and Latte's gates diff the three backends byte for byte. JavaScript's
// `toPrecision` is close and differs in three places that matter:
//
//   * it keeps trailing zeros, and `%g` removes them
//   * it reaches for exponent notation at 1e-7, and `%g` at 1e-5
//   * it writes `e+5`, and `%g` writes `e+05`
//
// So the digits come from `toExponential`/`toFixed`, which are correctly
// rounded by specification, and the shape is built here. `tests/canvas/floats.b`
// runs a table of values through all three backends and diffs the output,
// which is the only way to know this is right rather than nearly right.

/// Trailing zeros after a decimal point, and a lone trailing point, are what
/// `%g` removes and `toPrecision` keeps.
function trimZeros(text) {
    if (text.indexOf(".") < 0) return text;
    let end = text.length;
    while (end > 0 && text[end - 1] === "0") end--;
    if (end > 0 && text[end - 1] === ".") end--;
    return text.slice(0, end);
}

/// C's `%.*e` exponent: a sign, then at least two digits.
function exponentText(value) {
    const sign = value < 0 ? "-" : "+";
    const digits = String(Math.abs(value));
    return `e${sign}${digits.length < 2 ? "0" + digits : digits}`;
}

/// C's `%.*g`.
export function formatG(value, places) {
    if (places <= 0) places = 1;
    if (Number.isNaN(value)) return "nan";
    if (!Number.isFinite(value)) return value > 0 ? "inf" : "-inf";
    if (value === 0) return Object.is(value, -0) ? "-0" : "0";

    // The decision is made on the exponent of the value *after* rounding to
    // `places` significant digits: 9.99 at two digits is 1.0e+01, and %g looks
    // at the 1, not at the 9.
    const rounded = value.toExponential(places - 1);
    const exponent = Number(rounded.slice(rounded.indexOf("e") + 1));

    if (exponent < -4 || exponent >= places) {
        const mantissa = trimZeros(rounded.slice(0, rounded.indexOf("e")));
        return mantissa + exponentText(exponent);
    }
    const decimals = places - 1 - exponent;
    // toFixed refuses more than 100 decimals; %g never needs more than 17
    // significant digits, so this only bites for a very small value, and there
    // the exponent branch above has already taken it.
    const fixed = value.toFixed(Math.max(0, Math.min(100, decimals)));
    return trimZeros(fixed);
}

/// C's `%.*f`.
export function formatF(value, places) {
    if (Number.isNaN(value)) return "nan";
    if (!Number.isFinite(value)) return value > 0 ? "inf" : "-inf";
    if (places < 0) places = 0;
    // toFixed switches to exponential notation at 1e21 and %f never does, so
    // a large value is written out digit by digit from its exponential form.
    if (Math.abs(value) >= 1e21) {
        const text = value.toExponential(17);
        const [mantissa, exponentText] = text.split("e");
        const exponent = Number(exponentText);
        const negative = mantissa[0] === "-";
        const digits = mantissa.replace("-", "").replace(".", "");
        let whole = digits;
        if (exponent + 1 > digits.length) {
            whole = digits + "0".repeat(exponent + 1 - digits.length);
        }
        const body = (negative ? "-" : "") + whole;
        return places > 0 ? `${body}.${"0".repeat(places)}` : body;
    }
    return value.toFixed(Math.min(100, places));
}

/// `strtod`, with the end pointer C's version reports.
///
/// Answers the number and how many bytes of `text` it consumed. Zero consumed
/// means nothing numeric was there, which is what the runtime reads as a
/// refusal.
export function parseF64(text) {
    let at = 0;
    while (at < text.length && (text[at] === " " || text[at] === "\t" ||
                                text[at] === "\n" || text[at] === "\r" ||
                                text[at] === "\f" || text[at] === "\v")) at++;
    const rest = text.slice(at);
    // The grammar strtod takes, less the hexadecimal form, which nothing in
    // Beans writes. Matching rather than handing the whole string to
    // parseFloat is what makes the end offset right: parseFloat stops
    // wherever it likes and does not say where.
    const match = /^[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?/.exec(rest) ||
                  /^[+-]?(?:inf(?:inity)?|nan)/i.exec(rest);
    if (!match) return { value: 0, consumed: 0 };
    const token = match[0];
    let value;
    if (/inf/i.test(token)) value = token[0] === "-" ? -Infinity : Infinity;
    else if (/nan/i.test(token)) value = NaN;
    else value = Number(token);
    return { value, consumed: at + token.length };
}

/// The two imports, bound to one runtime's memory.
export function floatImports(runtime) {
    const encoder = new TextEncoder();
    return {
        latte_js_format_f64(out, cap, value, places, mode) {
            const text = mode === 102 /* 'f' */ ? formatF(value, places)
                                                : formatG(value, places);
            const bytes = encoder.encode(text);
            // The runtime measures the text with strlen rather than trusting
            // this return value, so the NUL matters and the number does not.
            if (!out || cap === 0) return bytes.length;
            const room = Math.min(bytes.length, cap - 1);
            const view = new Uint8Array(runtime.memory.buffer, out, cap);
            view.set(bytes.subarray(0, room));
            view[room] = 0;
            return bytes.length;
        },

        latte_js_parse_f64(text, out, end) {
            // The text is NUL-terminated C, so its length is found here rather
            // than passed: the runtime's callers have a `const char*` and no
            // count.
            const memory = new Uint8Array(runtime.memory.buffer);
            let stop = text;
            while (memory[stop] !== 0) stop++;
            const source = runtime.text(text, stop - text);
            const { value, consumed } = parseF64(source);
            if (out) new Float64Array(runtime.memory.buffer, out, 1)[0] = value;
            // The end pointer is where strtod stopped, which is the start when
            // nothing was consumed — that is how the runtime tells a refusal
            // from a zero.
            if (end) new Uint32Array(runtime.memory.buffer, end, 1)[0] = text + consumed;
            return consumed > 0 ? 1 : 0;
        },
    };
}
