package visual

fn command_arity(command: string) -> int {
    if command == "M" || command == "m" || command == "L" || command == "l" ||
       command == "T" || command == "t" { return 2 }
    if command == "H" || command == "h" || command == "V" || command == "v" { return 1 }
    if command == "Q" || command == "q" || command == "S" || command == "s" { return 4 }
    if command == "C" || command == "c" { return 6 }
    if command == "A" || command == "a" { return 7 }
    if command == "Z" || command == "z" { return 0 }
    return -1
}

fn segment_problem(command: string, count: int) -> string {
    let arity: int = command_arity(command)
    if arity < 0 { return "unknown SVG path command '{command}'" }
    if arity == 0 { return if count == 0 { "" } else { "close-path {command} takes no numbers" } }
    if count < arity || count % arity != 0 {
        return "SVG path command {command} needs groups of {arity} numbers"
    }
    return ""
}

/// Validate literal path data in the markup compiler. Dynamic strings also
/// pass through Skia's full SVG parser before a draw is accepted.
pub fn path_problem(data: string) -> string {
    var command: string = ""
    var first: bool = true
    var count: int = 0
    var token: string = ""
    for index: int in 0..data.len() {
        let code: int = data.byte_at(index) as int
        let char: string = data.slice(index, index + 1)
        let letter: bool = (code >= 65 && code <= 90) || (code >= 97 && code <= 122)
        let digit: bool = code >= 48 && code <= 57
        let sign: bool = char == "+" || char == "-"
        let separator: bool = code == 32 || code == 9 || code == 10 || code == 13 || char == ","
        if letter && char != "e" && char != "E" {
            if token != "" {
                match token.to_float() { ok(_) => { count += 1 } err(_) => { return "invalid SVG path number '{token}'" } }
                token = ""
            }
            if command != "" {
                let problem: string = segment_problem(command, count)
                if problem != "" { return problem }
            }
            if command_arity(char) < 0 { return "unknown SVG path command '{char}'" }
            if first && char != "M" && char != "m" { return "SVG path data must start with M or m" }
            first = false
            command = char
            count = 0
            continue
        }
        if separator || (sign && token != "" && !token.ends_with("e") && !token.ends_with("E")) {
            if token != "" {
                match token.to_float() { ok(_) => { count += 1 } err(_) => { return "invalid SVG path number '{token}'" } }
                token = ""
            }
            if separator { continue }
        }
        if digit || sign || char == "." || char == "e" || char == "E" {
            if command == "" { return "SVG path data must start with M or m" }
            token = "{token}{char}"
        } else { return "invalid character in SVG path data" }
    }
    if token != "" {
        match token.to_float() { ok(_) => { count += 1 } err(_) => { return "invalid SVG path number '{token}'" } }
    }
    if command == "" { return "SVG path data is empty" }
    return segment_problem(command, count)
}
