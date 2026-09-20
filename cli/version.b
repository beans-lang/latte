// The one version string the binary carries.
//
// It mirrors the newest heading in CHANGELOG.md, and `tools/check_version.sh`
// fails the build when the two drift.
package cli

pub const LATTE_VERSION: string = "0.1.1"
