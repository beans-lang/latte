// colors.b — a colour name to channel values, at compile time.
//
// `bg="red"` becomes `0xff0000ff` in the emitted source and nothing else
// happens at run time. bx/DESIGN.md gives the three reasons; the one that
// shapes this file is the first, that a typo has to be a bx error naming the
// nearest real colour. A table can only do that if it holds every name it
// claims to know, so the table below is generated from published data and
// checked against a second source, never typed out.
//
// Where the numbers come from — both machine-read, neither eyeballed:
//
//   * The 148 CSS names are the "Named Colors" table of CSS Color Module
//     Level 4, §6.1, read out of the CSSWG's own bikeshed source
//     (w3c/csswg-drafts, css-color-4/Overview.bs). That table prints each
//     colour twice, as `#rrggbb` and as three decimal channels; the two
//     agree for all 148, which is the first check.
//   * The 242 Tailwind names are tailwindcss v3.4.17 `src/public/colors.js`
//     — 22 hues by 11 steps. They were then diffed against the copy this
//     repo already vendors at
//     `.claude/vendor-ref/gpui-component/crates/ui/src/theme/default-colors.json`,
//     which is the same palette by way of shadcn/ui. All 242 agree.
//
//     That diff earned its keep: the vendored file's `violet-950` carries
//     `"hex": "#1e1b4b"` — indigo-950's value — while its own `rgb`, `hsl`
//     and `rgbChannel` fields all say `#2e1065`, which is what upstream
//     Tailwind says too. One source would have shipped that.
//
// The two namespaces do not collide, because a Tailwind name always carries
// its step: `red` is CSS red, `#ff0000`, and `red-500` is Tailwind's
// `#ef4444`. They are different colours under similar names and that is
// worth knowing before it surprises someone. Tailwind's own `black` and
// `white` are `#000` and `#fff`, identical to the CSS names, so they add
// nothing and are not repeated.
//
// `transparent` is here as `0x00000000` because a UI wants it and neither
// source lists it as a colour — CSS makes it a keyword and Tailwind an alias.
//
// bx imports nothing from crema. It emits `color.Rgba.from_hex_alpha(0x..)`
// as *text*; it never builds an `Rgba`. `from_hex_alpha` was picked over the
// struct literal because it is one call, it reads like the hex the author
// wrote, and its `channel()` is byte-for-byte the same arithmetic as
// `Rgba.parse`'s `scale255` — so a name and a `#rrggbbaa` string that mean
// the same colour produce the same f32 channels. tests/probe_bx_attrs.b
// checks that against the real `color.Rgba.parse`, which is the only place
// the two can be compared.

package bx

/// Every colour name bx knows, as a `0xRRGGBBAA` word.
///
/// An `OrderedMap` rather than a `Map` because the suggestion below walks
/// it, and `Map` promises no iteration order — two backends could then
/// pick different names out of a distance tie and a golden file would
/// disagree with itself. `OrderedMap` walks insertion order, which is the
/// order written here.
pub class Palette {
    /// Name to packed `0xRRGGBBAA`. CSS Color 4 §6.1 first, then the
    /// Tailwind v3 ramp, then `transparent`.
    pub static rgba: OrderedMap<string, int> = {
        "aliceblue": 0xf0f8ffff, "antiquewhite": 0xfaebd7ff, "aqua": 0x00ffffff, "aquamarine": 0x7fffd4ff,
        "azure": 0xf0ffffff, "beige": 0xf5f5dcff, "bisque": 0xffe4c4ff, "black": 0x000000ff,
        "blanchedalmond": 0xffebcdff, "blue": 0x0000ffff, "blueviolet": 0x8a2be2ff, "brown": 0xa52a2aff,
        "burlywood": 0xdeb887ff, "cadetblue": 0x5f9ea0ff, "chartreuse": 0x7fff00ff, "chocolate": 0xd2691eff,
        "coral": 0xff7f50ff, "cornflowerblue": 0x6495edff, "cornsilk": 0xfff8dcff, "crimson": 0xdc143cff,
        "cyan": 0x00ffffff, "darkblue": 0x00008bff, "darkcyan": 0x008b8bff, "darkgoldenrod": 0xb8860bff,
        "darkgray": 0xa9a9a9ff, "darkgreen": 0x006400ff, "darkgrey": 0xa9a9a9ff, "darkkhaki": 0xbdb76bff,
        "darkmagenta": 0x8b008bff, "darkolivegreen": 0x556b2fff, "darkorange": 0xff8c00ff, "darkorchid": 0x9932ccff,
        "darkred": 0x8b0000ff, "darksalmon": 0xe9967aff, "darkseagreen": 0x8fbc8fff, "darkslateblue": 0x483d8bff,
        "darkslategray": 0x2f4f4fff, "darkslategrey": 0x2f4f4fff, "darkturquoise": 0x00ced1ff, "darkviolet": 0x9400d3ff,
        "deeppink": 0xff1493ff, "deepskyblue": 0x00bfffff, "dimgray": 0x696969ff, "dimgrey": 0x696969ff,
        "dodgerblue": 0x1e90ffff, "firebrick": 0xb22222ff, "floralwhite": 0xfffaf0ff, "forestgreen": 0x228b22ff,
        "fuchsia": 0xff00ffff, "gainsboro": 0xdcdcdcff, "ghostwhite": 0xf8f8ffff, "gold": 0xffd700ff,
        "goldenrod": 0xdaa520ff, "gray": 0x808080ff, "green": 0x008000ff, "greenyellow": 0xadff2fff,
        "grey": 0x808080ff, "honeydew": 0xf0fff0ff, "hotpink": 0xff69b4ff, "indianred": 0xcd5c5cff,
        "indigo": 0x4b0082ff, "ivory": 0xfffff0ff, "khaki": 0xf0e68cff, "lavender": 0xe6e6faff,
        "lavenderblush": 0xfff0f5ff, "lawngreen": 0x7cfc00ff, "lemonchiffon": 0xfffacdff, "lightblue": 0xadd8e6ff,
        "lightcoral": 0xf08080ff, "lightcyan": 0xe0ffffff, "lightgoldenrodyellow": 0xfafad2ff, "lightgray": 0xd3d3d3ff,
        "lightgreen": 0x90ee90ff, "lightgrey": 0xd3d3d3ff, "lightpink": 0xffb6c1ff, "lightsalmon": 0xffa07aff,
        "lightseagreen": 0x20b2aaff, "lightskyblue": 0x87cefaff, "lightslategray": 0x778899ff, "lightslategrey": 0x778899ff,
        "lightsteelblue": 0xb0c4deff, "lightyellow": 0xffffe0ff, "lime": 0x00ff00ff, "limegreen": 0x32cd32ff,
        "linen": 0xfaf0e6ff, "magenta": 0xff00ffff, "maroon": 0x800000ff, "mediumaquamarine": 0x66cdaaff,
        "mediumblue": 0x0000cdff, "mediumorchid": 0xba55d3ff, "mediumpurple": 0x9370dbff, "mediumseagreen": 0x3cb371ff,
        "mediumslateblue": 0x7b68eeff, "mediumspringgreen": 0x00fa9aff, "mediumturquoise": 0x48d1ccff, "mediumvioletred": 0xc71585ff,
        "midnightblue": 0x191970ff, "mintcream": 0xf5fffaff, "mistyrose": 0xffe4e1ff, "moccasin": 0xffe4b5ff,
        "navajowhite": 0xffdeadff, "navy": 0x000080ff, "oldlace": 0xfdf5e6ff, "olive": 0x808000ff,
        "olivedrab": 0x6b8e23ff, "orange": 0xffa500ff, "orangered": 0xff4500ff, "orchid": 0xda70d6ff,
        "palegoldenrod": 0xeee8aaff, "palegreen": 0x98fb98ff, "paleturquoise": 0xafeeeeff, "palevioletred": 0xdb7093ff,
        "papayawhip": 0xffefd5ff, "peachpuff": 0xffdab9ff, "peru": 0xcd853fff, "pink": 0xffc0cbff,
        "plum": 0xdda0ddff, "powderblue": 0xb0e0e6ff, "purple": 0x800080ff, "rebeccapurple": 0x663399ff,
        "red": 0xff0000ff, "rosybrown": 0xbc8f8fff, "royalblue": 0x4169e1ff, "saddlebrown": 0x8b4513ff,
        "salmon": 0xfa8072ff, "sandybrown": 0xf4a460ff, "seagreen": 0x2e8b57ff, "seashell": 0xfff5eeff,
        "sienna": 0xa0522dff, "silver": 0xc0c0c0ff, "skyblue": 0x87ceebff, "slateblue": 0x6a5acdff,
        "slategray": 0x708090ff, "slategrey": 0x708090ff, "snow": 0xfffafaff, "springgreen": 0x00ff7fff,
        "steelblue": 0x4682b4ff, "tan": 0xd2b48cff, "teal": 0x008080ff, "thistle": 0xd8bfd8ff,
        "tomato": 0xff6347ff, "turquoise": 0x40e0d0ff, "violet": 0xee82eeff, "wheat": 0xf5deb3ff,
        "white": 0xffffffff, "whitesmoke": 0xf5f5f5ff, "yellow": 0xffff00ff, "yellowgreen": 0x9acd32ff,
        "slate-50": 0xf8fafcff, "slate-100": 0xf1f5f9ff, "slate-200": 0xe2e8f0ff, "slate-300": 0xcbd5e1ff,
        "slate-400": 0x94a3b8ff, "slate-500": 0x64748bff, "slate-600": 0x475569ff, "slate-700": 0x334155ff,
        "slate-800": 0x1e293bff, "slate-900": 0x0f172aff, "slate-950": 0x020617ff, "gray-50": 0xf9fafbff,
        "gray-100": 0xf3f4f6ff, "gray-200": 0xe5e7ebff, "gray-300": 0xd1d5dbff, "gray-400": 0x9ca3afff,
        "gray-500": 0x6b7280ff, "gray-600": 0x4b5563ff, "gray-700": 0x374151ff, "gray-800": 0x1f2937ff,
        "gray-900": 0x111827ff, "gray-950": 0x030712ff, "zinc-50": 0xfafafaff, "zinc-100": 0xf4f4f5ff,
        "zinc-200": 0xe4e4e7ff, "zinc-300": 0xd4d4d8ff, "zinc-400": 0xa1a1aaff, "zinc-500": 0x71717aff,
        "zinc-600": 0x52525bff, "zinc-700": 0x3f3f46ff, "zinc-800": 0x27272aff, "zinc-900": 0x18181bff,
        "zinc-950": 0x09090bff, "neutral-50": 0xfafafaff, "neutral-100": 0xf5f5f5ff, "neutral-200": 0xe5e5e5ff,
        "neutral-300": 0xd4d4d4ff, "neutral-400": 0xa3a3a3ff, "neutral-500": 0x737373ff, "neutral-600": 0x525252ff,
        "neutral-700": 0x404040ff, "neutral-800": 0x262626ff, "neutral-900": 0x171717ff, "neutral-950": 0x0a0a0aff,
        "stone-50": 0xfafaf9ff, "stone-100": 0xf5f5f4ff, "stone-200": 0xe7e5e4ff, "stone-300": 0xd6d3d1ff,
        "stone-400": 0xa8a29eff, "stone-500": 0x78716cff, "stone-600": 0x57534eff, "stone-700": 0x44403cff,
        "stone-800": 0x292524ff, "stone-900": 0x1c1917ff, "stone-950": 0x0c0a09ff, "red-50": 0xfef2f2ff,
        "red-100": 0xfee2e2ff, "red-200": 0xfecacaff, "red-300": 0xfca5a5ff, "red-400": 0xf87171ff,
        "red-500": 0xef4444ff, "red-600": 0xdc2626ff, "red-700": 0xb91c1cff, "red-800": 0x991b1bff,
        "red-900": 0x7f1d1dff, "red-950": 0x450a0aff, "orange-50": 0xfff7edff, "orange-100": 0xffedd5ff,
        "orange-200": 0xfed7aaff, "orange-300": 0xfdba74ff, "orange-400": 0xfb923cff, "orange-500": 0xf97316ff,
        "orange-600": 0xea580cff, "orange-700": 0xc2410cff, "orange-800": 0x9a3412ff, "orange-900": 0x7c2d12ff,
        "orange-950": 0x431407ff, "amber-50": 0xfffbebff, "amber-100": 0xfef3c7ff, "amber-200": 0xfde68aff,
        "amber-300": 0xfcd34dff, "amber-400": 0xfbbf24ff, "amber-500": 0xf59e0bff, "amber-600": 0xd97706ff,
        "amber-700": 0xb45309ff, "amber-800": 0x92400eff, "amber-900": 0x78350fff, "amber-950": 0x451a03ff,
        "yellow-50": 0xfefce8ff, "yellow-100": 0xfef9c3ff, "yellow-200": 0xfef08aff, "yellow-300": 0xfde047ff,
        "yellow-400": 0xfacc15ff, "yellow-500": 0xeab308ff, "yellow-600": 0xca8a04ff, "yellow-700": 0xa16207ff,
        "yellow-800": 0x854d0eff, "yellow-900": 0x713f12ff, "yellow-950": 0x422006ff, "lime-50": 0xf7fee7ff,
        "lime-100": 0xecfccbff, "lime-200": 0xd9f99dff, "lime-300": 0xbef264ff, "lime-400": 0xa3e635ff,
        "lime-500": 0x84cc16ff, "lime-600": 0x65a30dff, "lime-700": 0x4d7c0fff, "lime-800": 0x3f6212ff,
        "lime-900": 0x365314ff, "lime-950": 0x1a2e05ff, "green-50": 0xf0fdf4ff, "green-100": 0xdcfce7ff,
        "green-200": 0xbbf7d0ff, "green-300": 0x86efacff, "green-400": 0x4ade80ff, "green-500": 0x22c55eff,
        "green-600": 0x16a34aff, "green-700": 0x15803dff, "green-800": 0x166534ff, "green-900": 0x14532dff,
        "green-950": 0x052e16ff, "emerald-50": 0xecfdf5ff, "emerald-100": 0xd1fae5ff, "emerald-200": 0xa7f3d0ff,
        "emerald-300": 0x6ee7b7ff, "emerald-400": 0x34d399ff, "emerald-500": 0x10b981ff, "emerald-600": 0x059669ff,
        "emerald-700": 0x047857ff, "emerald-800": 0x065f46ff, "emerald-900": 0x064e3bff, "emerald-950": 0x022c22ff,
        "teal-50": 0xf0fdfaff, "teal-100": 0xccfbf1ff, "teal-200": 0x99f6e4ff, "teal-300": 0x5eead4ff,
        "teal-400": 0x2dd4bfff, "teal-500": 0x14b8a6ff, "teal-600": 0x0d9488ff, "teal-700": 0x0f766eff,
        "teal-800": 0x115e59ff, "teal-900": 0x134e4aff, "teal-950": 0x042f2eff, "cyan-50": 0xecfeffff,
        "cyan-100": 0xcffafeff, "cyan-200": 0xa5f3fcff, "cyan-300": 0x67e8f9ff, "cyan-400": 0x22d3eeff,
        "cyan-500": 0x06b6d4ff, "cyan-600": 0x0891b2ff, "cyan-700": 0x0e7490ff, "cyan-800": 0x155e75ff,
        "cyan-900": 0x164e63ff, "cyan-950": 0x083344ff, "sky-50": 0xf0f9ffff, "sky-100": 0xe0f2feff,
        "sky-200": 0xbae6fdff, "sky-300": 0x7dd3fcff, "sky-400": 0x38bdf8ff, "sky-500": 0x0ea5e9ff,
        "sky-600": 0x0284c7ff, "sky-700": 0x0369a1ff, "sky-800": 0x075985ff, "sky-900": 0x0c4a6eff,
        "sky-950": 0x082f49ff, "blue-50": 0xeff6ffff, "blue-100": 0xdbeafeff, "blue-200": 0xbfdbfeff,
        "blue-300": 0x93c5fdff, "blue-400": 0x60a5faff, "blue-500": 0x3b82f6ff, "blue-600": 0x2563ebff,
        "blue-700": 0x1d4ed8ff, "blue-800": 0x1e40afff, "blue-900": 0x1e3a8aff, "blue-950": 0x172554ff,
        "indigo-50": 0xeef2ffff, "indigo-100": 0xe0e7ffff, "indigo-200": 0xc7d2feff, "indigo-300": 0xa5b4fcff,
        "indigo-400": 0x818cf8ff, "indigo-500": 0x6366f1ff, "indigo-600": 0x4f46e5ff, "indigo-700": 0x4338caff,
        "indigo-800": 0x3730a3ff, "indigo-900": 0x312e81ff, "indigo-950": 0x1e1b4bff, "violet-50": 0xf5f3ffff,
        "violet-100": 0xede9feff, "violet-200": 0xddd6feff, "violet-300": 0xc4b5fdff, "violet-400": 0xa78bfaff,
        "violet-500": 0x8b5cf6ff, "violet-600": 0x7c3aedff, "violet-700": 0x6d28d9ff, "violet-800": 0x5b21b6ff,
        "violet-900": 0x4c1d95ff, "violet-950": 0x2e1065ff, "purple-50": 0xfaf5ffff, "purple-100": 0xf3e8ffff,
        "purple-200": 0xe9d5ffff, "purple-300": 0xd8b4feff, "purple-400": 0xc084fcff, "purple-500": 0xa855f7ff,
        "purple-600": 0x9333eaff, "purple-700": 0x7e22ceff, "purple-800": 0x6b21a8ff, "purple-900": 0x581c87ff,
        "purple-950": 0x3b0764ff, "fuchsia-50": 0xfdf4ffff, "fuchsia-100": 0xfae8ffff, "fuchsia-200": 0xf5d0feff,
        "fuchsia-300": 0xf0abfcff, "fuchsia-400": 0xe879f9ff, "fuchsia-500": 0xd946efff, "fuchsia-600": 0xc026d3ff,
        "fuchsia-700": 0xa21cafff, "fuchsia-800": 0x86198fff, "fuchsia-900": 0x701a75ff, "fuchsia-950": 0x4a044eff,
        "pink-50": 0xfdf2f8ff, "pink-100": 0xfce7f3ff, "pink-200": 0xfbcfe8ff, "pink-300": 0xf9a8d4ff,
        "pink-400": 0xf472b6ff, "pink-500": 0xec4899ff, "pink-600": 0xdb2777ff, "pink-700": 0xbe185dff,
        "pink-800": 0x9d174dff, "pink-900": 0x831843ff, "pink-950": 0x500724ff, "rose-50": 0xfff1f2ff,
        "rose-100": 0xffe4e6ff, "rose-200": 0xfecdd3ff, "rose-300": 0xfda4afff, "rose-400": 0xfb7185ff,
        "rose-500": 0xf43f5eff, "rose-600": 0xe11d48ff, "rose-700": 0xbe123cff, "rose-800": 0x9f1239ff,
        "rose-900": 0x881337ff, "rose-950": 0x4c0519ff, "transparent": 0x00000000,
    }

    /// The table is never instantiated; every member is static.
    pub fn init() {}
}

/// The `0xRRGGBBAA` word `text` names, or `none`.
///
/// A name is matched case-insensitively with surrounding space trimmed, the
/// same latitude `color.Rgba.parse` gives a hex string. Anything starting
/// with `#` goes to `hex_word` instead of the table.
pub fn colour_word(text: string) -> Option<int> {
    let name: string = text.trim().to_lower()
    if name.starts_with("#") {
        return hex_word(name)
    }
    return Palette.rgba.get(name)
}

/// `#rgb`, `#rgba`, `#rrggbb` or `#rrggbbaa` as a `0xRRGGBBAA` word.
///
/// This is `color.Rgba.parse`'s grammar written a second time, and a second
/// copy of anything is a liability — but the alternative is bx importing
/// `crema.color` to resolve a literal it is about to print as text, and bx
/// imports nothing from crema. The duplication is paid for in
/// tests/probe_bx_attrs.b, which runs both over the same inputs and compares
/// the channels the real `Rgba.parse` produces against the channels this
/// word produces through `Rgba.from_hex_alpha`. Change one and that test
/// fails.
///
/// The short forms duplicate each nibble — `#f0c` is `#ff00cc` — which is
/// the CSS rule and what `Rgba.parse` does.
pub fn hex_word(text: string) -> Option<int> {
    let body: string = text.trim().to_lower()
    if !body.starts_with("#") {
        return none
    }
    let hex: string = body.slice(1, body.len())
    let size: int = hex.len()
    if size == 3 || size == 4 {
        var out: int = 0
        for i: int in 0..3 {
            let d: int = hex_digit(hex, i)
            if d < 0 {
                return none
            }
            out = (out << 8) | (d << 4) | d
        }
        var alpha: int = 0xff
        if size == 4 {
            let d: int = hex_digit(hex, 3)
            if d < 0 {
                return none
            }
            alpha = (d << 4) | d
        }
        return some((out << 8) | alpha)
    }
    if size == 6 || size == 8 {
        var out: int = 0
        for i: int in 0..6 {
            let d: int = hex_digit(hex, i)
            if d < 0 {
                return none
            }
            out = (out << 4) | d
        }
        var alpha: int = 0xff
        if size == 8 {
            let hi: int = hex_digit(hex, 6)
            let lo: int = hex_digit(hex, 7)
            if hi < 0 || lo < 0 {
                return none
            }
            alpha = (hi << 4) | lo
        }
        return some((out << 8) | alpha)
    }
    return none
}

/// The colour `text` names, or an error carrying `span` and the nearest real
/// name.
///
/// The suggestion is the whole point of resolving a colour here rather than
/// at run time, so it is not optional and it is not best-effort: every name
/// in the table is a candidate and the nearest one wins, subject to the
/// distance gate in `nearest_name` that stops `bg="octarine"` claiming to
/// have meant `orange`.
pub fn colour_or_error(text: string, span: Span) -> Result<int> {
    let found: Option<int> = colour_word(text)
    match found {
        some(word) => { return ok(word) },
        none => {},
    }
    let asked: string = text.trim().to_lower()
    if asked.starts_with("#") {
        return err(
            "{span.show()}: '{text}' is not a hex colour — expected #rgb, #rgba, #rrggbb or #rrggbbaa",
            "unknown_colour")
    }
    let near: string = nearest_name(asked, Palette.rgba.keys())
    if near.len() == 0 {
        return err(
            "{span.show()}: no colour named \"{text}\" — write a hex literal, or bg=\{color.Rgba.parse(..)?\} to decide at run time",
            "unknown_colour")
    }
    return err(
        "{span.show()}: no colour named \"{text}\" — did you mean \"{near}\"?",
        "unknown_colour")
}

/// The Beans expression for a resolved colour word.
///
/// `color.Rgba.from_hex_alpha(0xff0000ff)` — one call into a real static, and
/// the hex reads back as the colour the author wrote.
pub fn rgba_expr(word: int) -> string {
    return "color.Rgba.from_hex_alpha(0x{hex8(word)})"
}

/// A whole 32-bit word as eight lowercase hex digits.
///
/// `fmt.hex` is lowercase and unprefixed but is not zero padded, so
/// `0x00ff00ff` would come back as `ff00ff` and read as a different colour.
pub fn hex8(word: int) -> string {
    let digits: string = "0123456789abcdef"
    var out: List<string> = []
    for i: int in 0..8 {
        let shift: int = (7 - i) * 4
        let nibble: int = (word >> shift) & 0xf
        out.push(digits.slice(nibble, nibble + 1))
    }
    return out.join("")
}

/// The value of one hex digit, or -1 when that byte is not one.
fn hex_digit(hex: string, index: int) -> int {
    if index >= hex.len() {
        return -1
    }
    let byte: int = hex.byte_at(index)
    if byte >= 48 && byte <= 57 {
        return byte - 48
    }
    if byte >= 97 && byte <= 102 {
        return (byte - 97) + 10
    }
    return -1
}
