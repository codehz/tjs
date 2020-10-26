#define _CRT_SECURE_NO_WARNINGS
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <tlhelp32.h>
#include <wchar.h>

static void freex_c(char **ptr) { free(*ptr); }
static void freex_w(wchar_t **ptr) { free(*ptr); }
#define scoped(f) __attribute__((cleanup(f)))
#define alloc(T, c) (T *)calloc(c, sizeof(T));

#define wstr wchar_t *scoped(freex_w)
#define str char *scoped(freex_c)

static char *utf16to8(wchar_t const *input) {
  int size = WideCharToMultiByte(CP_UTF8, 0, input, -1, NULL, 0, NULL, NULL);
  char *ret = alloc(char, size);
  if (ret) {
    WideCharToMultiByte(CP_UTF8, 0, input, -1, ret, size, NULL, NULL);
  }
  return ret;
}

static wchar_t *utf8to16(char const *input) {
  int size = MultiByteToWideChar(CP_UTF8, 0, input, -1, NULL, 0);
  wchar_t *ret = alloc(wchar_t, size);
  if (ret) {
    MultiByteToWideChar(CP_UTF8, 0, input, -1, ret, size);
  }
  return ret;
}

FILE *utf8_fopen(const char *path, const char *mode) {
  wstr wpath = utf8to16(path);
  wstr wmode = utf8to16(mode);
  return _wfopen(wpath, wmode);
}

FILE *utf8_freopen(const char *path, const char *mode, FILE *stream) {
  wstr wpath = utf8to16(path);
  wstr wmode = utf8to16(mode);
  return _wfreopen(wpath, wmode, stream);
}

int utf8__stat(const char *path, struct _stat *buff) {
  wstr wpath = utf8to16(path);
  return _wstat(wpath, buff);
}

char *utf8_getcwd(char *buff, int size) {
  wstr wp = _wgetcwd(NULL, 0);
  return utf16to8(wp);
}

char *utf8_getenv(const char *var) {
  wstr wvar = utf8to16(var);
  wstr e = _wgetenv(wvar);
  return utf16to8(e);
}

int utf8_open(const char *path, int flag, ...) {
  int mode = 0777;
  va_list list;
  va_start(list, flag);
  if (flag & O_CREAT)
    mode = va_arg(list, int);
  va_end(list);

  wstr wpath = utf8to16(path);

  return _wopen(wpath, flag, mode);
}

int utf8_system(const char *command) {
  wstr wcommand = utf8to16(command);
  return _wsystem(wcommand);
}

HMODULE utf8_LoadLibrary(LPCSTR module) {
  wstr wmodule = utf8to16(module);
  return LoadLibraryExW(wmodule, NULL,
                        LOAD_LIBRARY_SEARCH_DEFAULT_DIRS |
                            LOAD_LIBRARY_SEARCH_USER_DIRS);
}