
import { Compiler } from "c";
const compiler = new Compiler("memory");
compiler.link("user32");
compiler.compile(`
#include <stdio.h>
#include <windows.h>

void hello(char const *name) {
  printf("hello %s\n", name);
}

double add(double a, double b) {
  return a + b;
}

void msgbox(char const *text) {
  MessageBoxA(NULL, text, "from js", 0);
}
`)
const obj = compiler.relocate({
  hello: { arguments: ["string"] },
  add: { arguments: ["double", "double"], result: "double" },
  msgbox: { arguments: ["string"] }
});
console.log(obj.hello("test"));
console.log(obj.add(1, 2));
obj.msgbox("hi");