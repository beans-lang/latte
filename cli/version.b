// The versions the binary carries. tools/check_version.sh holds each one to what
// it mirrors: CHANGELOG.md's heading, and the rows in beans.pot and app/beans.pot.
package cli

pub const LATTE_VERSION: string = "0.2.0"

/// The refs latte itself requires. An application must pin the same ones, or
/// beansc refuses a graph holding two refs for one dependency.
pub const ESPRESSO_PIN: string = "v0.3.0"
pub const BARISTA_PIN: string = "v0.1.1"

/// The oldest beansc a latte application builds with: reaching `latte_app`, a
/// nested module, through a `require` row is what 0.1.44 fixed.
pub const BEANS_FLOOR: string = "0.1.44"
