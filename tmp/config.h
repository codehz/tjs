#define TCC_VERSION "(null)"
#define _GNU_SOURCE
#if defined(__x86_64__)
#define TCC_TARGET_X86_64 1
#elif defined(__aarch64__)
#define TCC_TARGET_ARM64 1
#elif defined(__i386__)
#define TCC_TARGET_I386 1
#else
#error Not supported
#endif
#ifdef _WIN32
#define TCC_TARGET_PE
#else
#define TCC_LIBTCC1 "lib/libtcc1.a"
#endif
