// The handlers registered against one widget.
package input

/// Every handler for a single widget, keyed by event kind.
///
/// This is a class rather than a nested `Map` because a map inside a map is
/// move-only in Beans — reading the inner one out by index would move it. A
/// class reference copies freely, so the router can reach a widget's handlers
/// in one lookup and still mutate them in place.
pub class WidgetSubscriptions {
    by_kind: Map<int, fn(UiEvent)> = {}

    pub fn init() {}

    pub fn set(kind_code: int, handler: fn(UiEvent)) {
        self.by_kind[kind_code] = handler
    }

    pub fn clear(kind_code: int) {
        self.by_kind.remove(kind_code)
    }

    /// Whether this widget already has a handler for the kind.
    ///
    /// The router needs it to keep a count per kind honest: `set` replaces a
    /// handler as often as it adds one, and a count that rose on a replacement
    /// would never fall back to zero.
    pub fn has(kind_code: int) -> bool {
        return self.by_kind.contains_key(kind_code)
    }

    /// Every kind this widget has a handler for, so `forget` can take them all
    /// out of the router's per-kind count.
    pub fn kinds() -> List<int> {
        var every: List<int> = []
        for code: int in self.by_kind.keys() {
            every.push(code)
        }
        return move every
    }

    pub fn count() -> int {
        return self.by_kind.len()
    }

    pub fn handler(kind_code: int) -> Option<fn(UiEvent)> {
        return self.by_kind.get(kind_code)
    }
}
