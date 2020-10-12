#define TCC_VERSION "(null)"
#define _GNU_SOURCE
#ifdef __x86_64__
#define TCC_TARGET_X86_64 1
#else
#define TCC_TARGET_I386 1
#define 
#endif
#ifdef _WIN32
#define TCC_TARGET_PE
#else
#define TCC_LIBTCC1 "lib/libtcc1.a"
#endif
