import { Compiler } from "builtin:c";
import { log } from "builtin:io";
import { encode, decode } from "builtin:utf8";
const compiler = new Compiler("memory");
compiler.link("user32");
compiler.compile(`
#include <stdio.h>
#include <stdint.h>
#include <ctype.h>
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

struct strvector {
  char *ptr;
  size_t len;
};

void lower(struct strvector vec) {
  for (size_t i = 0; i < vec.len; i++) {
    vec.ptr[i] = tolower(vec.ptr[i]);
  }
}
`)
const obj = compiler.relocate({
  hello: { arguments: ["string"] },
  add: { arguments: ["double", "double"], result: "double" },
  msgbox: { arguments: ["string"] },
  lower: { arguments: ["vector"] },
});
log(obj.hello(import.meta.url));
log(obj.add(1, 2));
obj.msgbox(`from ${import.meta.url}`);
const temp = encode("TEST");
obj.lower(temp);
log(decode(temp));
