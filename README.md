# TJS = tinyc compiler + quickjs

Mix the power of two worlds, allows you to call c function in js (inline).

Toy project, no guarantee of safety, use at your own risk.

# Example

```js
// yes, it support es-module
import Compiler from "builtin:c";
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
  msgbox: { arguments: ["string"] }
});
obj.msgbox(`from ${import.meta.url}`);
```