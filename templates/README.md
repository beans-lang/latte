Latte's shared control visuals are compiled from these `.bx` files.

Run `build/latte-bx build templates` after editing them. Generated Beans is
committed under `generated/templates/` so an application does not need to run
the markup compiler just to import Latte. `tools/test_rendered.py` checks
that the sources and generated output agree.

A `ControlTemplate` receives its owner's text, enabled/focused/hovered/pressed state,
font size, and theme colors. `hovered` follows the pointer path, including
control ancestors, and clears on leave. Templates can bind that state to colors
or to a drawing shape with `transition_seconds` and `transition_easing`. The
control keeps its handle, keyboard behavior, and semantics when its template
changes. A `TemplateFactory` can replace one default and delegate the
remaining controls to `DefaultTemplates`.

The current text field draws its editing content in Beans.
