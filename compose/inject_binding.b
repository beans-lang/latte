// One field the container fills.
package compose

import std.reflect

/// An `@inject` field and the type it wants.
///
/// `fault` is filled in at scan time rather than at fill time, because the
/// mistakes worth catching here — a field that is not `pub`, so reflection
/// cannot write it — are properties of the declaration and not of any
/// particular mount. Recording the message once and repeating it means a
/// hundred rows of one component report the same problem the same way.
class InjectBinding {
    field: reflect.Field
    wanted: reflect.Type
    fault: string = ""

    fn init(field: reflect.Field, wanted: reflect.Type) {
        self.field = field
        self.wanted = wanted
    }
}
