# TJS = tinyc compiler + quickjs

Mix the power of two worlds, allows you to call c function in js (inline).

Toy project, no guarantee of safety, use at your own risk.

# Example

```js
// yes, it support es-module
import { Compiler } from "builtin:c";
// initialize compiler
const compiler = new Compiler("memory");
// link to user32 to use MessageBoxA
compiler.link("user32");
// and place your c code inline
compiler.compile(`
#include <windows.h>
void msgbox(char const *text) {
  MessageBoxA(NULL, text, "from js", 0);
}
`);
// and relocate the function
const obj = compiler.relocate({
  msgbox: "w"
});
obj.msgbox(`from ${import.meta.url}`);
```

## About relocate syntax

Basic form: object { funcname: desc_string }

example:
* `"ii"` -> (int, int) => void
* `"dd!d"` -> (double, double) => double
* `"i[i]!i"` -> (int, (int) => int) => int
* `"[s]!i"` -> ((string) => int) => int

| Symbol | Type in c          | Type in js  | parameter | result | callback |
| ------ | ------------------ | ----------- | --------- | ------ | -------- |
| i      | int32_t            | number      | yes       | yes    | yes      |
| d      | double             | number      | yes       | yes    | yes      |
| s      | char *             | string      | yes       | no     | yes      |
| w      | wchar_t *          | string      | yes       | no     | yes      |
| v      | { void *, size_t } | ArrayBuffer | yes       | no     | yes      |
| b      | int64_t            | bigint      | yes       | yes    | yes      |
| p      | void *             | bigint      | yes       | yes    | yes      |
| `[]`   | opaque type        | function    | yes       | no     | no       |

> **_For typescript user:_**  We also provide a [d.ts](tjs.d.ts) files for type-checking, requires typescript 4.1+.