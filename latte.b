package latte

// latte — a Blazor-shaped web framework for Beans.
//
// A component is a markup file with Beans in it. The markup compiler under
// bx/ turns it into `Builder` calls with fixed sequence numbers; the core
// turns those into frames, and frames into either HTML (static rendering) or
// edits on a WebSocket circuit (interactive rendering). Both paths consume
// the same frames, which is why static HTML and interactive edits cannot
// disagree about what a component looks like.
//
// The module root is the surface a consumer imports:
//
//     import {Builder, Component, Callback} from latte
//
// Nothing here imports std.fs, std.net or std.io. See beans.pot for why.

/// The version of latte this package is.
pub let version: string = "0.0.0-dev"
