// What the framework does to one component type.
package compose

import std.reflect

/// The reflection a component type needs, worked out once.
///
/// A class and not a bare pair of lists, for a reason that is specific to
/// Beans: a `List` is move-only, so reading one out of a cache would take it
/// out of the cache. A class is a reference, so the map keeps it and every
/// mount borrows the same one.
///
/// The cache matters. Reflecting over a type's fields and their annotations
/// costs real time, and an application that shows two hundred rows of one
/// component should pay for that type once and not two hundred times. A type's
/// fields cannot change while a program runs, so the plan is correct forever
/// once built.
class MountPlan {
    /// `@inject` fields, and what each needs.
    bindings: List<InjectBinding> = []
    /// `@param` fields, in declaration order.
    parameters: List<reflect.Field> = []
    /// Problems found while scanning, reported at the first mount rather than
    /// silently producing a component with empty fields.
    faults: List<string> = []

    fn init() {}

    /// The plan for a type, built once for the whole program.
    ///
    /// **Per process, not per mount.** It used to be a map on `Mount`, which
    /// is right for a screen and wrong for everything else: a control with a
    /// `.bx` template gets a `Mount` of its own, so every button on a screen
    /// built a fresh cache and paid the whole scan again. One button cost
    /// 120 ms, of which 109 ms was asking 146 fields for annotations and
    /// finding none — twelve of them took a second and a half.
    ///
    /// Sound because a plan is a fact about a *type*: its fields and their
    /// annotations cannot change while a program runs, so an answer computed
    /// once is correct forever.
    static fn for_type(described: reflect.Type) -> MountPlan {
        return PlanDesk.instance.plan(described)
    }

    /// Reads one component type and records everything the framework will do
    /// to instances of it.
    static fn of(described: reflect.Type) -> MountPlan {
        var plan: MountPlan = new MountPlan()
        let owner: string = described.qualified_name()
        for field: reflect.Field in described.fields() {
            var injected: bool = false
            var parameter: bool = false
            for use: reflect.Annotation in field.annotations() {
                if use.qualified_name() == "latte.annotations.inject" { injected = true }
                if use.qualified_name() == "latte.annotations.param" { parameter = true }
            }
            if injected {
                var binding: InjectBinding = new InjectBinding(field, field.type())
                if !field.is_public() {
                    // Reflection does not bypass visibility, so a private
                    // @inject field is never filled and never says so.
                    binding.fault =
                        "{owner}.{field.name()} is @inject but is not pub, and reflection cannot write what it cannot see"
                }
                plan.bindings.push(binding)
            }
            if parameter {
                if field.is_public() {
                    plan.parameters.push(field)
                } else {
                    plan.faults.push(
                        "{owner}.{field.name()} is @param but is not pub, so nothing can set it")
                }
            }
        }
        return plan
    }
}

/// Every plan this program has worked out.
///
/// A singleton because reflection is a fact about the program rather than
/// about any one screen, and because the cost it exists to avoid is paid per
/// *mount* — and a templated control is a mount.
pub singleton class PlanDesk {
    plans: Map<string, MountPlan> = {}

    fn init() {}

    fn plan(described: reflect.Type) -> MountPlan {
        let key: string = described.qualified_name()
        match self.plans.get(key) {
            some(found) => { return found }
            none => {}
        }
        let made: MountPlan = MountPlan.of(described)
        self.plans[key] = made
        return made
    }

    /// How many types have been scanned. A test reads it to say that a second
    /// mount of the same type scanned nothing.
    pub fn scanned() -> int { return self.plans.len() }

    /// Forgets everything. Teardown in a test; nothing else should need it,
    /// because a type's fields do not change.
    pub fn reset() { self.plans = {} }
}
