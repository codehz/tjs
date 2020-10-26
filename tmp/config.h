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

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

typedef struct _iobuf FILE;
extern FILE *utf8_fopen(const char *path, const char *mode);
extern FILE *utf8_freopen(const char *path, const char *mode, FILE *stream);
extern int utf8__stat(const char *path, struct _stat *buff);
extern char *utf8_getcwd(char *buff, int size);
extern char *utf8_getenv(const char *var);
extern int utf8_open(const char *path, int flag, ...);
extern int utf8_system(const char *command);
extern HMODULE utf8_LoadLibrary(LPCSTR module);
#define fopen utf8_fopen
#define freopen utf8_freopen
#define _stat utf8__stat
#define stat utf8__stat
#define getcwd utf8_getcwd
#define getenv utf8_getenv
#define open utf8_open
#define system utf8_system
#define LoadLibraryA utf8_LoadLibrary

#else
#define TCC_LIBTCC1 "lib/libtcc1.a"
#endif
