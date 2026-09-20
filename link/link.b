// What a canvas application says to a server, and what it hears back.
package link

/// The one channel to whatever is serving a Latte application. It carries
/// messages, never calls; which side owns what is in docs/notes.md.
pub interface Link {
    /// Asks the server to do something; the answer arrives through `receive`.
    /// Nothing sent here is a permission — the server checks every one again.
    fn send(action: string, payload: string) -> Result<bool>

    /// Whether the channel is usable. Offline or closed answers false, so a
    /// caller can show it rather than queue forever.
    fn ready() -> bool

    /// What the server last said, or `none`. Read once: a message is removed
    /// as it is taken, so a component that reads it twice gets it once.
    fn receive() -> Option<Message>
}

/// One message from the server.
pub struct Message {
    /// What kind of message it is — the server's own word.
    pub topic: string = ""
    /// Its body, as text. JSON usually, and this layer does not care: a
    /// component decodes what it asked for and a mismatch is its own error.
    pub payload: string = ""

    pub static fn of(topic: string, payload: string) -> Message {
        return Message { topic: topic, payload: payload }
    }

    pub fn show() -> string { return "{self.topic}: {self.payload}" }
}

/// The link a program has when nothing else is installed: it refuses to send
/// and never receives, so a missing link is a named refusal, not silence.
pub class NoLink implements Link {
    pub fn init() {}

    pub fn send(action: string, payload: string) -> Result<bool> {
        return err("could not send {action}: this program has no link to a server",
                   "unsupported")
    }

    pub fn ready() -> bool { return false }

    pub fn receive() -> Option<Message> { return none }
}

/// A link that keeps everything in memory: what a test uses, and a screen
/// before its server exists. No network, no timing, no ordering surprises.
pub class LocalLink implements Link {
    pub sent: List<Message> = []
    inbox: List<Message> = []
    reachable: bool = true

    pub fn init() {}

    pub fn send(action: string, payload: string) -> Result<bool> {
        if !self.reachable {
            return err("could not send {action}: the link is closed", "wrong_moment")
        }
        self.sent.push(Message.of(action, payload))
        return ok(true)
    }

    pub fn ready() -> bool { return self.reachable }

    pub fn receive() -> Option<Message> {
        if self.inbox.len() == 0 { return none }
        return some(self.inbox.remove(0))
    }

    /// What a test uses to answer.
    pub fn deliver(topic: string, payload: string) {
        self.inbox.push(Message.of(topic, payload))
    }

    pub fn close() { self.reachable = false }
}

/// The link this program is using.
pub singleton class LinkDesk {
    current: Link = new NoLink()

    fn init() {}

    pub fn install(link: Link) { self.current = link }
    pub fn link() -> Link { return self.current }
    pub fn reset() { self.current = new NoLink() }
}
