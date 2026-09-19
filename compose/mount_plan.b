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
                    // field marked for injection is not a field that gets
                    // filled quietly — it is one that never gets filled at
                    // all. Saying so beats an empty service found later.
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
