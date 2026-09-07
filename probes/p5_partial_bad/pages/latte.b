package pages

pub class Builder {
    pub out: string = ""
    pub fn text(seq: int, body: string) { self.out = "{self.out}[{seq}:{body}]" }
}

pub class Component {
    pub fn render(b: Builder) {}
}
