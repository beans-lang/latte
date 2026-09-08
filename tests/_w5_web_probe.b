package main

import latte
import latte.web
import std.io

fn main() {
    io.println("poller {web.has_fiber_poller()}")
    io.println("wake {web.WAKE_PUSH}{web.WAKE_TICK}{web.WAKE_GONE}{web.WAKE_MESSAGE}")
    io.println("latte {latte.WAKE_PUSH}{latte.WAKE_TICK}{latte.WAKE_GONE}{latte.WAKE_MESSAGE}")
}
