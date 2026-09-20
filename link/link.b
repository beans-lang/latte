// What a canvas application says to a server, and what it hears back.
package link

/// The one channel between a Latte canvas application and whatever is serving
/// it.
///
/// **It carries messages, not calls.** A canvas application runs in the
/// browser: its state, its layout, its editing and its focus are all local,
/// and none of them waits for a network. What it asks a server for is *data*,
/// and what it asks a server to *do* is an action — and both are one-way
/// messages with a reply that arrives later, because a WebAssembly call cannot
/// wait for a promise and a UI that waited for one would freeze while it did.
///
/// That shape is a deliberate constraint rather than an accident of the
/// platform. A scroll, a keystroke, a drag and an animation are all local by
/// construction, so an application built on this cannot accidentally put a
/// round trip in the middle of one.
pub interface Link {
    /// Asks the server to do something.
    ///
    /// `action` names it and `payload` carries its arguments as text. The
    /// answer, if there is one, arrives through `receive` under a topic the
    /// server chooses.
    ///
    /// **Whatever the server does with this, it checks for itself.** A page can
    /// send any action with any payload — a browser is the user's machine and
    /// nothing in it is evidence of anything — so the server authenticates and
    /// authorizes every one of them again. Nothing here is a permission.
    fn send(action: string, payload: string) -> Result<bool>

    /// Whether the channel is usable. A page that is offline, or whose socket
    /// has closed, answers false, and a caller shows that rather than queuing
    /// forever.
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

/// The link a program has when nothing else is installed.
///
/// It refuses to send and never receives. That is the right default for a
/// showcase, a gate and any screen that has no server behind it: a component
/// that asks for data gets a named refusal instead of silence, and a test that
/// forgot to install a link fails saying so.
pub class NoLink implements Link {
    pub fn init() {}

    pub fn send(action: string, payload: string) -> Result<bool> {
        return err("could not send {action}: this program has no link to a server",
                   "unsupported")
    }

    pub fn ready() -> bool { return false }

    pub fn receive() -> Option<Message> { return none }
}

/// A link that keeps everything in memory.
///
/// What a test uses, and what a screen uses before its server exists: a
/// message sent goes on a list a test can read, and a message the test pushes
/// arrives as though a server had sent it. No network, no timing, no ordering
/// surprises — which is what makes a component's behaviour testable at all.
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
