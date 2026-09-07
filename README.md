# latte

A Blazor-shaped web framework for Beans. Components are markup files with
Beans in them, rendered on the server, updated a frame at a time over a
WebSocket circuit, hosted by [espresso](../espresso).

```
<section class="counter">
    <h2>Count: $self.count</h2>
    <button on:click={fn(e: MouseEvent) { self.count += 1 }}>Add one</button>
</section>

<beans>
@page(route: r"/counter")
pub partial class Counter extends Component {
    pub count: int = 0
}
</beans>
```

**Status: under construction.** Nothing here works yet. `PLAN.md` is the
design, `LANES.md` is what is being built and by whom, `RULES.md` is the
contract every contributor works to, and `BLOCKERS.md` is where language walls
are recorded rather than worked around.

## Requirements

- **Beans 0.1.40 or newer.** Latte uses `std.websocket`'s permessage-deflate,
  `std.compress`'s `Deflater`, and `std.http`'s `encode_response_head_append`,
  none of which exist in 0.1.39.
- espresso, for the HTTP host.

## The gate

```bash
./test.sh              # both backends, every suite
./test.sh --interp     # the interpreter only — the edit loop
./test.sh diff         # one suite, both backends
./test.sh --wasm       # proves the core still imports no I/O
```

Both backends must print every golden file byte for byte. See `RULES.md`.
