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
typedef struct __tjscallback_data {
  size_t type;
  union {
    int i;
    double d;
    char const *s;
    wchar_t const *w;
    tjsvec_buf v;
    void *p;
  };
} tjscallback_data;

extern bool tjs_notify(tjscallback cb);
extern bool tjs_notify_data(tjscallback cb, size_t num, tjscallback_data const *ptr);

#define TJS_NOTIFY_DATA(cb, list...) \
  { \
    tjscallback_data __tmp_callback_data__[] = { list }; \
    tjs_notify_data(cb, sizeof(__tmp_callback_data__) / sizeof(tjscallback_data), &__tmp_callback_data__); \
  }
#define TJS_DATA_VOID(value) (tjscallback_data){ type: 0, i: (value) }
#define TJS_DATA_INT(value) (tjscallback_data){ type: 1, i: (value) }
#define TJS_DATA_DOUBLE(value) (tjscallback_data){ type: 2, d: (value) }
#define TJS_DATA_STRING(value) (tjscallback_data){ type: 3, s: (value) }
#define TJS_DATA_WSTRING(value) (tjscallback_data){ type: 4, w: (value) }
#define TJS_DATA_VECTOR(value_ptr, value_len) (tjscallback_data){ type: 5, v: { ptr: value_ptr, len: value_len } }
#define TJS_DATA_POINTER(value) (tjscallback_data){ type: 6, p: (value) }
#endif