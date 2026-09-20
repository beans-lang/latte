// What the platform said when it refused.
package platform

/// The result of a host call.
///
/// Every call that can be refused answers one of these rather than a
/// boolean, because "it did not work" is not actionable: the difference
/// between `unsupported` and `stale` decides whether the caller has a bug or
/// the platform does.
///
/// `unsupported` is the load-bearing one. A platform that cannot do something
/// says so out loud and latte turns that into a `Result` the caller can see.
/// Silently doing nothing would leave a menu bar missing on one platform with
/// no way to find out why.
pub enum HostStatus {
    ok
    stale
    kind
    platform
    thread
    unsupported
    range
    abi
    state
    unknown

    /// The `err` kind slug this status becomes, so a caller can match on the
    /// failure instead of reading the message.
    fn slug() -> string {
        return match self {
            ok => "ok",
            stale => "stale_handle",
            kind => "wrong_widget",
            platform => "platform_refused",
            thread => "wrong_thread",
            unsupported => "unsupported",
            range => "out_of_range",
            abi => "abi_mismatch",
            state => "wrong_moment",
            unknown => "host_failed",
        }
    }

    /// The clause that follows "could not <attempt>: " in the message.
    fn reason() -> string {
        return match self {
            ok => "succeeded",
            stale => "the widget it names has been released",
            kind => "that widget does not have this property",
            platform => "the operating system refused it",
            thread => "it must run on the UI thread",
            unsupported => "this platform has no such thing",
            range => "the index or size is out of range",
            abi => "the host and this build disagree on the ABI version",
            state => "it is the right call at the wrong moment",
            unknown => "the host reported an unrecognized failure",
        }
    }

    /// Every negative code the header defines, and `unknown` for anything
    /// else — a host built against a newer header must not be read as success.
    pub static fn of(code: int) -> HostStatus {
        if code >= 0 { return HostStatus.ok }
        if code == ERR_STALE { return HostStatus.stale }
        if code == ERR_KIND { return HostStatus.kind }
        if code == ERR_PLATFORM { return HostStatus.platform }
        if code == ERR_THREAD { return HostStatus.thread }
        if code == ERR_UNSUPPORTED { return HostStatus.unsupported }
        if code == ERR_RANGE { return HostStatus.range }
        if code == ERR_ABI { return HostStatus.abi }
        if code == ERR_STATE { return HostStatus.state }
        return HostStatus.unknown
    }
}

/// Checks a raw status code, naming what was being attempted when it failed.
///
/// `attempt` reads into the message as "could not <attempt>: <reason>", so
/// write it as a verb phrase — "set the title of a button", not "set_title".
pub fn check(code: int, attempt: string) -> Result<bool> {
    let status: HostStatus = HostStatus.of(code)
    if status == HostStatus.ok {
        return ok(true)
    }
    return err("could not {attempt}: {status.reason()}", status.slug())
}
