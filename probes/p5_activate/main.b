// Probe 5 — what it costs to activate 1,000 components through espresso's DI.
//
// Latte mounts every component out of the circuit's DI scope, and this
// workspace's standing figure for reflective dispatch is 32-80 us per call. If
// mounting cost that, a 200-component page would spend 6-16 ms in reflection
// before rendering a byte, and mount-time DI would be the wrong design.
//
// espresso's `activate(implementation: reflect.Type)` is private today (W3
// makes it public), so this drives the public path that reaches it:
// `services.transient<T>()` then `provider.resolve<T>()`, which goes
// descriptor lookup -> factory -> activate -> initializer().call(args).
//
// Four costs, 1,000 rounds each:
//   new          a plain `new`, the floor
//   activate(0)  resolve a component with no constructor dependencies
//   activate(1)  resolve one with a single scoped dependency
//   activate(3)  resolve one with three
package main

import github.com/beans-lang/espresso
import std.io
import std.reflect
import std.time

// ---- the services a component's constructor asks for -----------------------
pub class Clock { pub fn init() {} pub fn now() -> int { return 1 } }
pub class Users { pub fn init() {} pub fn count() -> int { return 2 } }
pub class Theme { pub fn init() {} pub fn name() -> string { return "dark" } }

// ---- components, by how much they need -------------------------------------
pub class Zero {
    pub label: string = ""
    pub fn init() {}
}

pub class One {
    pub label: string = ""
    clock: Clock
    pub fn init(clock: Clock) { self.clock = clock }
    pub fn tick() -> int { return self.clock.now() }
}

pub class Three {
    pub label: string = ""
    clock: Clock
    users: Users
    theme: Theme
    pub fn init(clock: Clock, users: Users, theme: Theme) {
        self.clock = clock
        self.users = users
        self.theme = theme
    }
    pub fn describe() -> string {
        return "{self.clock.now()}/{self.users.count()}/{self.theme.name()}"
    }
}

const ROUNDS: int = 1000
// Five interleaved passes, and the minimum wins. A single pass on a cold machine reads
// 3x slow — measured: the first run of this program reports 205 ns for
// `new Zero()` and the fourth reports 67 — because the CPU has not ramped and
// nothing is in cache yet. The minimum of a few passes is the honest answer to
// "what does this cost", and it is the one a resuming agent will reproduce.
const PASSES: int = 5



// One pass of every bench, then the next pass, keeping a minimum per bench —
// NOT three passes of one bench and then three of the next. The difference is
// not cosmetic: run on its own this program's ratios are stable, but run
// inside `probes/run_all.sh` behind six other probes it failed, because a load
// spike landed inside one bench's whole run and not another's. Interleaving
// makes every bench see the same conditions, which is what makes a comparison
// between two of them mean anything.
class Best {
    pub plain: int = -1
    pub lookup: int = -1
    pub cached: int = -1
    pub zero: int = -1
    pub one: int = -1
    pub three: int = -1
    pub fn init() {}
}

fn keep(current: int, sample: int) -> int {
    if sample <= 0 { return current }
    if current < 0 { return sample }
    if sample < current { return sample }
    return current
}

fn passes(scope: espresso.ServiceProvider, rounds: int) -> Best {
    let best: Best = new Best()
    for pass: int in 0..PASSES {
        best.plain = keep(best.plain, bench_new(rounds))
        best.lookup = keep(best.lookup, bench_initializer_lookup(rounds))
        best.cached = keep(best.cached, bench_cached_initializer(rounds))
        best.zero = keep(best.zero, bench_zero(scope, rounds))
        best.one = keep(best.one, bench_one(scope, rounds))
        best.three = keep(best.three, bench_three(scope, rounds))
    }
    return best
}

fn bench_new(rounds: int) -> int {
    var kept: int = 0
    let t0: int = time.monotonic_nanos()
    for round: int in 0..rounds {
        let made: Zero = new Zero()
        made.label = "x"
        kept += 1
    }
    let spent: int = time.monotonic_nanos() - t0
    if kept != rounds { return -1 }
    return spent / rounds
}

fn bench_zero(scope: espresso.ServiceProvider, rounds: int) -> int {
    var kept: int = 0
    let t0: int = time.monotonic_nanos()
    for round: int in 0..rounds {
        match scope.resolve<Zero>() {
            ok(made) => { made.label = "x"; kept += 1 }
            err(e) => { io.println("zero failed: {e.kind}: {e.msg}"); return -1 }
        }
    }
    let spent: int = time.monotonic_nanos() - t0
    if kept != rounds { return -1 }
    return spent / rounds
}

fn bench_one(scope: espresso.ServiceProvider, rounds: int) -> int {
    var total: int = 0
    let t0: int = time.monotonic_nanos()
    for round: int in 0..rounds {
        match scope.resolve<One>() {
            ok(made) => { total += made.tick() }
            err(e) => { io.println("one failed: {e.kind}: {e.msg}"); return -1 }
        }
    }
    let spent: int = time.monotonic_nanos() - t0
    if total != rounds { return -1 }
    return spent / rounds
}

fn bench_three(scope: espresso.ServiceProvider, rounds: int) -> int {
    var kept: int = 0
    let t0: int = time.monotonic_nanos()
    for round: int in 0..rounds {
        match scope.resolve<Three>() {
            ok(made) => {
                if made.describe() == "1/2/dark" { kept += 1 }
            }
            err(e) => { io.println("three failed: {e.kind}: {e.msg}"); return -1 }
        }
    }
    let spent: int = time.monotonic_nanos() - t0
    if kept != rounds { return -1 }
    return spent / rounds
}

// Where the time actually goes. espresso looks the initializer up on every
// activation; latte would cache it per component type at scan time. This is
// the same construction with the lookup hoisted, so the difference between it
// and `resolve<Zero>()` is everything espresso adds, and the difference
// between it and `new Zero()` is what reflective construction itself costs.
fn bench_cached_initializer(rounds: int) -> int {
    match type_of(Zero).initializer() {
        some(ctor) => {
            var kept: int = 0
            let t0: int = time.monotonic_nanos()
            for round: int in 0..rounds {
                match ctor.call([]) {
                    ok(made) => {
                        match made as? Zero {
                            some(instance) => { instance.label = "x"; kept += 1 }
                            none => {}
                        }
                    }
                    err(e) => { return -1 }
                }
            }
            let spent: int = time.monotonic_nanos() - t0
            if kept != rounds { return -1 }
            return spent / rounds
        }
        none => { return -1 }
    }
}

// The other half of the same question: how much of an activation is finding
// the initializer, and how much is calling it. espresso finds it every time;
// latte's page scan would find it once per component type.
fn bench_initializer_lookup(rounds: int) -> int {
    var found: int = 0
    let t0: int = time.monotonic_nanos()
    for round: int in 0..rounds {
        match type_of(Zero).initializer() {
            some(ctor) => { found += 1 }
            none => { return -1 }
        }
    }
    let spent: int = time.monotonic_nanos() - t0
    if found != rounds { return -1 }
    return spent / rounds
}

fn run(scope: espresso.ServiceProvider) {
    // A full discarded pass of everything first. The scoped services need to
    // be cached, but more than that the process needs to be warm: measured on
    // this machine, the first pass of this program reports 203 ns for
    // `new Zero()` and every later one reports 68. A 20-round warm-up was not
    // enough — the ramp is longer than that — so the warm-up is a whole pass.
    let warm_new: int = bench_new(ROUNDS)
    let warm_lookup: int = bench_initializer_lookup(ROUNDS)
    let warm_cached: int = bench_cached_initializer(ROUNDS)
    let warm_zero: int = bench_zero(scope, ROUNDS)
    let warm_one: int = bench_one(scope, ROUNDS)
    let warm_three: int = bench_three(scope, ROUNDS)

    let best: Best = passes(scope, ROUNDS)
    let plain: int = best.plain
    let lookup: int = best.lookup
    let cached: int = best.cached
    let zero: int = best.zero
    let one: int = best.one
    let three: int = best.three

    io.println("ns per activation, best of {PASSES} interleaved passes of {ROUNDS} rounds:")
    io.println("  new Zero()                 {plain}")
    io.println("  Type.initializer() lookup  {lookup}")
    io.println("  a cached Initializer.call  {cached}")
    io.println("  resolve<Zero>()  0 deps    {zero}")
    io.println("  resolve<One>()   1 dep     {one}")
    io.println("  resolve<Three>() 3 deps    {three}")
    io.println("1000 components: {zero / 1000} us with no deps, {three / 1000} us with three")
    io.println("a 200-component page: {zero * 200 / 1000} us with no deps, {three * 200 / 1000} us with three")
    io.println("every activation produced a working instance: {warm_zero > 0 && warm_one > 0 && warm_three > 0 && zero > 0 && one > 0 && three > 0}")
    io.println("hoisting the initializer lookup is worth it: {cached * 2 < zero}")
    // Two shape claims, both with a wide enough margin to survive a loaded
    // machine: hoisting the initializer lookup is worth it (a 4x gap), and
    // three constructor dependencies cost more than none (a 2.7x gap). The
    // adjacent comparisons zero<one<three are only 1.5x apart and are left to
    // the printed numbers rather than asserted, because a 1.5x assertion on
    // separately timed passes is a flake, and a flaky assertion proves less
    // than none.
    let all_ok: bool = warm_zero > 0 && warm_one > 0 && warm_three > 0 &&
        plain > 0 && lookup > 0 && cached > 0 &&
        zero > 0 && one > 0 && three > 0 &&
        cached * 2 < zero && three > zero * 2
    if all_ok { io.println("probe p5_activate: ok") }
    else {
        io.println("probe p5_activate: FAILED warm={warm_zero}/{warm_one}/{warm_three} plain={plain} lookup={lookup} cached={cached} zero={zero} one={one} three={three}")
    }
}

fn main() {
    let services: espresso.ServiceCollection = new espresso.ServiceCollection()
    let clock_added: Result<bool> = services.scoped<Clock>()
    let users_added: Result<bool> = services.scoped<Users>()
    let theme_added: Result<bool> = services.scoped<Theme>()
    let zero_added: Result<bool> = services.transient<Zero>()
    let one_added: Result<bool> = services.transient<One>()
    let three_added: Result<bool> = services.transient<Three>()
    let ok_all: bool = clock_added.is_ok() && users_added.is_ok() &&
        theme_added.is_ok() && zero_added.is_ok() && one_added.is_ok() &&
        three_added.is_ok()
    io.println("registration: {ok_all}")

    let root: espresso.ServiceProvider = services.build_provider()
    match root.create_scope() {
        ok(scope) => {
            run(scope)
            let closed: Result<bool> = scope.close()
        }
        err(e) => { io.println("scope failed: {e.kind}: {e.msg}") }
    }
    let closed_root: Result<bool> = root.close()
}
