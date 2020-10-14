import { Compiler } from "builtin:c";
import { log } from "builtin:io";
import { encode, decode } from "builtin:utf8";
const compiler = new Compiler("memory");
compiler.link("user32");
compiler.compile(`
#include <stdio.h>
#include <ctype.h>
#include <windows.h>
#include <tjs.h>

void hello(char const *name) {
  printf("hello %s\n", name);
}

double add(double a, double b) {
  return a + b;
}

void msgbox(wchar_t const *text) {
  MessageBoxW(NULL, text, L"from js", 0);
}

void lower(tjsvec_wstr vec) {
  for (size_t i = 0; i < vec.len; i++) {
    vec.ptr[i] = tolower(vec.ptr[i]);
  }
}
void callback(tjscallback cb) {
  tjs_notify(cb);
  tjs_notify(cb);
}
`);
const obj = compiler.relocate({
  hello: "s",
  add: "dd!d",
  msgbox: "w",
  lower: "v",
  callback: "[]",
});
log(obj.hello(import.meta.url));
log(obj.add(1, 2));
obj.msgbox(`from ${import.meta.url} ❤ UNICODE`);
const temp = encode("TEST");
obj.lower(temp);
log(decode(temp));
obj.callback(() => log("cb"));
