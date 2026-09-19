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
