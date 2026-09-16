# Changelog

This file records user-facing changes in each latte release.

## [0.1.1] - 2026-09-16

### Changed — BREAKING: espresso and barista are required from git, not by path

**`require path "../../community-libs/espresso"` is gone.** It named a
directory in this workspace, so latte built here and nowhere else: a consumer
who fetched this repository got errors about unknown packages `espresso` and
`barista`, because these manifests pointed at sibling directories that were not
in their tree.

```beans-pot
require github.com/beans-lang/latte v0.1.1
```

That one row reaches both halves. `latte_app` — the composition root under
`app/` — is a module inside this repository, so `import
github.com/beans-lang/latte/app` resolves through the same row and still binds
as `latte_app`: a package is named by the manifest that declares it, never by
the path that reached it.

```beans
import github.com/beans-lang/latte
import {LatteApp, LatteOptions, build_with} from github.com/beans-lang/latte/app
```

Every `latte.X` and `latte_app.X` in existing source stands; only the import
lines change.

### Requirements

**Beans 0.1.44 or newer to use latte.** Reaching a nested module through a
`require` row is what that release fixed — before it, `app/` was loaded as a
package of the repository above it and failed on its own `import latte`.
0.1.41 is still the floor for building this repository, and `test.sh` holds it.

## [0.1.0] - 2026-09-08

The first release: frames, builder, serializer and differ; the circuit
endpoint over espresso; `latte.bx` markup; forms, uploads, signals and
view-models; the `latte_app` composition root.
