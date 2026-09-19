// One pixel, as the platform painted it.
package controls

/// A colour read back out of a snapshot: four channels, each 0 to 255.
///
/// A struct rather than a class because it is a value and there are a great
/// many of them — a hundred-by-forty snapshot holds four thousand — and
/// because nothing about a colour needs identity.
pub struct Rgba {
    pub red: int = 0
    pub green: int = 0
    pub blue: int = 0
    /// 255 is opaque. A pixel nothing painted is 0 everywhere, alpha
    /// included, which is what makes "nothing was drawn here" a fact a test
    /// can assert rather than a guess about the allocator.
    pub alpha: int = 0

    /// A colour written the way every designer and every stylesheet writes
    /// one: `#rgb`, `#rrggbb`, or `#rrggbbaa`.
    ///
    /// Here rather than in whichever package first wanted it, because a colour
    /// is a colour: the GPU parses one out of markup today and a background
    /// property will want the same spelling tomorrow, and two parsers would
    /// disagree about `#abc` inside a month.
    ///
    /// Refused rather than defaulted. A typo in a colour is invisible if it
    /// quietly becomes black, and a shader that draws the wrong colour is a
    /// long afternoon.
    pub static fn of_hex(text: string) -> Result<Rgba> {
        if !text.starts_with("#") {
            return err("a colour is written #rgb, #rrggbb or #rrggbbaa, and {text} has no #",
                       "not_a_colour")
        }
        let digits: string = text.slice(1, text.len())
        if digits.len() == 3 {
            let red: int = Rgba.nibble(digits, 0)?
            let green: int = Rgba.nibble(digits, 1)?
            let blue: int = Rgba.nibble(digits, 2)?
            // #abc means #aabbcc: each digit doubled, so the shorthand reaches
            // 255 rather than topping out at 15/255.
            return ok(Rgba { red: red * 17, green: green * 17, blue: blue * 17, alpha: 255 })
        }
        if digits.len() == 6 || digits.len() == 8 {
            let red: int = Rgba.byte_at(digits, 0)?
            let green: int = Rgba.byte_at(digits, 2)?
            let blue: int = Rgba.byte_at(digits, 4)?
            var alpha: int = 255
            if digits.len() == 8 { alpha = Rgba.byte_at(digits, 6)? }
            return ok(Rgba { red: red, green: green, blue: blue, alpha: alpha })
        }
        return err("a colour is written #rgb, #rrggbb or #rrggbbaa, and {text} has {digits.len()} digits",
                   "not_a_colour")
    }

    static fn byte_at(digits: string, at: int) -> Result<int> {
        let high: int = Rgba.nibble(digits, at)?
        let low: int = Rgba.nibble(digits, at + 1)?
        return ok(high * 16 + low)
    }

    static fn nibble(digits: string, at: int) -> Result<int> {
        let code: int = digits.byte_at(at)
        if code >= 48 && code <= 57 { return ok(code - 48) }
        if code >= 97 && code <= 102 { return ok(code - 87) }
        if code >= 65 && code <= 70 { return ok(code - 55) }
        return err("a colour's digits are 0-9 and a-f, and {digits} has one that is not",
                   "not_a_colour")
    }

    /// The four channels in one integer, red in the high byte.
    ///
    /// The packing is the property protocol's, not this type's: a colour
    /// crosses `set_integer`/`integer` as one word, so both ends have to
    /// agree on the order, and one place to read it is the way to keep them
    /// agreeing.
    pub fn packed() -> int {
        return self.red * 16777216 + self.green * 65536 +
               self.blue * 256 + self.alpha
    }

    pub static fn of_packed(packed: int) -> Rgba {
        return Rgba { red: (packed / 16777216) % 256,
                      green: (packed / 65536) % 256,
                      blue: (packed / 256) % 256,
                      alpha: packed % 256 }
    }

    /// Each channel as a fraction, which is what a shader counts in.
    pub fn fractions() -> List<f64> {
        var out: List<f64> = []
        out.push(self.red as f64 / 255.0)
        out.push(self.green as f64 / 255.0)
        out.push(self.blue as f64 / 255.0)
        out.push(self.alpha as f64 / 255.0)
        return move out
    }

    pub fn same_as(other: Rgba) -> bool {
        return self.red == other.red && self.green == other.green &&
               self.blue == other.blue && self.alpha == other.alpha
    }

    /// `rgba(255,0,255,255)`. Decimal rather than hex because Beans has no
    /// hex formatting and a hand-rolled one in a value type is a second thing
    /// to get wrong.
    pub fn show() -> string {
        return "rgba({self.red},{self.green},{self.blue},{self.alpha})"
    }
}
