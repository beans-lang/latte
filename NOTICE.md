# Third-party notices

## Cortado

Latte's canvas UI runtime began as a one-time source copy from **Cortado**
(<https://github.com/beans-lang/cortado>), taken at revision
`bb6e29ff45991f50feab3b4d30d780390289d9d9` on 2026-09-19.

It is a copy, not a dependency. Latte does not import Cortado, does not look
for it on disk, and builds in a checkout that has no `cortado/` directory in
it. The copied files have been renamed, re-packaged and rewritten — see
[`docs/source-copy.md`](docs/source-copy.md) for the file-by-file inventory and
for what changed.

Cortado is MIT-licensed. Latte is Apache-2.0. The MIT licence permits this and
requires its notice to travel with the copy, so here it is in full:

```
MIT License

Copyright (c) 2026 the cortado authors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Roboto

The showcase and the screenshot gates draw text with **Roboto**, which is
licensed under the Apache License 2.0. It arrives through the `roboto-fontface`
npm package and `tools/font_prepare.mjs` turns its WOFF files back into the
TrueType files CanvasKit can read; nothing is committed to this repository.

Why a font is needed at all: **CanvasKit has no fonts and cannot read the
system's.** A browser will not hand a page glyph data, and CanvasKit ships
none, so a page that registers nothing lays every paragraph out as zero glyphs
— the controls appear in the right places with no words in any of them, and no
error is raised anywhere. Latte refuses to shape text with no font registered
rather than draw that.

An application may of course use its own face. `Renderer.use_font` takes the
files, and the metrics of the shipped theme were measured against the macOS
system font, so a different face will not match the pinned screenshots — see
`docs/source-copy.md`.
