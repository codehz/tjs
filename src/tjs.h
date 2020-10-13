#ifndef __TJS__
#error Can only be used in tjs.
#endif
#include <stdint.h>
#include <stdbool.h>
#ifdef __TJS_MEMORY__
typedef struct __tjsvec_str {
  char *ptr;
  size_t len;
} tjsvec_str;
typedef struct __tjsvec_wstr {
  wchar_t *ptr;
  size_t len;
} tjsvec_wstr;
typedef struct __tjsvec_buf {
  void *ptr;
  size_t len;
} tjsvec_buf;
typedef struct __tjscallback {
  size_t a, b; // placeholder
} tjscallback;
extern bool tjs_notify(tjscallback cb);
#endif