package pages

pub class Builder {
    pub out: string = ""
    pub fn text(seq: int, s: string) { self.out = "{self.out}[{seq}:{s}]" }
}

pub class Component {
    pub fn render(b: Builder) {}
}

pub partial class Counter extends Component {
    pub count: int = 0
    pub fn init() {}
}
