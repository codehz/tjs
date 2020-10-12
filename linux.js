import { Compiler } from "builtin:c";
import { log } from "builtin:io";
const compiler = new Compiler("memory");
compiler.link("user32");
compiler.compile(`
#include <stdio.h>

void hello(char const *name) {
  printf("hello %s\n", name);
}

double add(double a, double b) {
  return a + b;
}
`)
const obj = compiler.relocate({
  hello: { arguments: ["string"] },
  add: { arguments: ["double", "double"], result: "double" },
});
log(obj.hello(import.meta.url));
log(obj.add(1, 2));
