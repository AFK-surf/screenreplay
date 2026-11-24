// The replay app's files on Windows: the buffer's segments listed, a part of a file read for the player, a small file
// read whole. Paths come as UTF-8 ending in a NUL.
#include <windows.h>
#include <shellapi.h>
#include <shlobj.h>
#include <dwmapi.h>
#include <shobjidl.h>
#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "uuid.lib")
#pragma comment(lib, "shell32.lib")
#pragma comment(lib, "shell32.lib")
#pragma comment(lib, "dwmapi.lib")
#pragma comment(lib, "advapi32.lib")
#include <stdint.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include "moonbit.h"

static wchar_t *rp_wide(const char *utf8) {
  int n = MultiByteToWideChar(CP_UTF8, 0, utf8, -1, NULL, 0);
  wchar_t *w = (wchar_t *)malloc(sizeof(wchar_t) * (n > 0 ? n : 1));
  if (n > 0) MultiByteToWideChar(CP_UTF8, 0, utf8, -1, w, n); else w[0] = 0;
  return w;
}

static BOOL CALLBACK rp_square_owned_window(HWND hwnd, LPARAM context) {
  DWORD pid = 0;
  GetWindowThreadProcessId(hwnd, &pid);
  if (pid == GetCurrentProcessId() && GetWindow(hwnd, GW_OWNER) == NULL) {
    DWM_WINDOW_CORNER_PREFERENCE preference = DWMWCP_DONOTROUND;
    if (SUCCEEDED(DwmSetWindowAttribute(hwnd, DWMWA_WINDOW_CORNER_PREFERENCE, &preference, sizeof(preference))))
      *(int *)context = 1;
  }
  return TRUE;
}

int32_t rp_square_window(void) {
  int applied = 0;
  EnumWindows(rp_square_owned_window, (LPARAM)&applied);
  return applied;
}

int32_t rp_launch(moonbit_bytes_t path) {
  wchar_t *w = rp_wide((const char *)path);
  INT_PTR result = (INT_PTR)ShellExecuteW(NULL, L"open", w, NULL, NULL, SW_SHOWNORMAL);
  free(w);
  return result > 32;
}

// FOF_ALLOWUNDO sends a local file to the Recycle Bin. Never silently fall back
// to permanent deletion if recycling is unavailable: ask Windows to confirm.
int32_t rp_recycle(moonbit_bytes_t path) {
  wchar_t *w = rp_wide((const char *)path);
  size_t n = wcslen(w);
  wchar_t *names = (wchar_t *)calloc(n + 2, sizeof(wchar_t));
  memcpy(names, w, n * sizeof(wchar_t));
  free(w);
  SHFILEOPSTRUCTW op = {0};
  op.wFunc = FO_DELETE;
  op.pFrom = names;
  op.fFlags = FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_WANTNUKEWARNING | FOF_SILENT;
  int result = SHFileOperationW(&op);
  free(names);
  return result ? result : (op.fAnyOperationsAborted ? ERROR_CANCELLED : 0);
}

int32_t rp_take_request(moonbit_bytes_t path) {
  wchar_t *w = rp_wide((const char *)path);
  BOOL taken = DeleteFileW(w);
  free(w);
  return taken;
}

static moonbit_bytes_t rp_bytes(const char *p, int32_t n) {
  moonbit_bytes_t b = moonbit_make_bytes(n, 0);
  if (n > 0) memcpy(b, p, (size_t)n);
  return b;
}

// The names of `dir`'s files matching one of `globs`, one a line.
static moonbit_bytes_t rp_list_globs(moonbit_bytes_t dir, const char *const *globs, int n_globs) {
  size_t cap = 4096, len = 0;
  char *out = (char *)malloc(cap);
  for (int g = 0; g < n_globs; g++) {
    char pattern[2048];
    snprintf(pattern, sizeof pattern, "%s\\%s", (const char *)dir, globs[g]);
    wchar_t *w = rp_wide(pattern);
    WIN32_FIND_DATAW fd;
    HANDLE h = FindFirstFileW(w, &fd);
    free(w);
    if (h == INVALID_HANDLE_VALUE) continue;
    do {
      if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) continue;
      char name[1024];
      int n = WideCharToMultiByte(CP_UTF8, 0, fd.cFileName, -1, name, sizeof name, NULL, NULL);
      if (n <= 1) continue;
      if (len + (size_t)n + 1 > cap) {
        cap = (len + n + 1) * 2;
        char *more = (char *)realloc(out, cap);
        // (no more memory: the names so far)
        if (!more) break;
        out = more;
      }
      memcpy(out + len, name, (size_t)n - 1);
      len += (size_t)n - 1;
      out[len++] = '\n';
    } while (FindNextFileW(h, &fd));
    FindClose(h);
  }
  moonbit_bytes_t b = rp_bytes(out, (int32_t)len);
  free(out);
  return b;
}

// The names of `dir`'s files ending in `.mp4`, one a line.
moonbit_bytes_t rp_list(moonbit_bytes_t dir) {
  static const char *const globs[] = {"*.mp4"};
  return rp_list_globs(dir, globs, 1);
}

// The saved clips' names in `dir`: its videos and its GIFs, one a line.
moonbit_bytes_t rp_list_clips(moonbit_bytes_t dir) {
  static const char *const globs[] = {"*.mp4", "*.gif"};
  return rp_list_globs(dir, globs, 2);
}

static HANDLE rp_open(moonbit_bytes_t path) {
  wchar_t *w = rp_wide((const char *)path);
  HANDLE h = CreateFileW(w, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL, OPEN_EXISTING,
                         FILE_ATTRIBUTE_NORMAL, NULL);
  free(w);
  return h;
}

// A file's attributes as its folder has them (no handle opened: opening one cost the system's scan of the file, for
// each of the many files whose size or time is asked); false where there is none, or it is a folder (as before, when a
// folder could not be opened as a file).
static BOOL rp_attributes(moonbit_bytes_t path, WIN32_FILE_ATTRIBUTE_DATA *a) {
  wchar_t *w = rp_wide((const char *)path);
  BOOL ok = GetFileAttributesExW(w, GetFileExInfoStandard, a);
  free(w);
  return ok && !(a->dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY);
}

// A file's size in bytes, -1 when there is none.
double rp_size(moonbit_bytes_t path) {
  WIN32_FILE_ATTRIBUTE_DATA a;
  if (!rp_attributes(path, &a)) return -1.0;
  return (double)(((ULONGLONG)a.nFileSizeHigh << 32) | a.nFileSizeLow);
}

// Last-write time helps invalidate a preview when a clip is replaced in place.
double rp_modified(moonbit_bytes_t path) {
  WIN32_FILE_ATTRIBUTE_DATA a;
  if (!rp_attributes(path, &a)) return -1.0;
  ULARGE_INTEGER t;
  t.LowPart = a.ftLastWriteTime.dwLowDateTime;
  t.HighPart = a.ftLastWriteTime.dwHighDateTime;
  return (double)(t.QuadPart / 10000ULL);
}

// At most `length` bytes of a file from `offset`; none when it cannot be read.
moonbit_bytes_t rp_read(moonbit_bytes_t path, double offset, int32_t length) {
  HANDLE h = rp_open(path);
  if (h == INVALID_HANDLE_VALUE || length <= 0) {
    if (h != INVALID_HANDLE_VALUE) CloseHandle(h);
    return moonbit_make_bytes(0, 0);
  }
  LARGE_INTEGER sz;
  // (its size not known: nothing read, rather than `length` made ready for a whole file asked for: read_text's)
  if (!GetFileSizeEx(h, &sz)) {
    CloseHandle(h);
    return moonbit_make_bytes(0, 0);
  }
  {
    LONGLONG rem = sz.QuadPart - (LONGLONG)offset;
    if (rem <= 0) {
      CloseHandle(h);
      return moonbit_make_bytes(0, 0);
    }
    if ((LONGLONG)length > rem) length = (int32_t)rem;
  }
  LARGE_INTEGER at;
  at.QuadPart = (LONGLONG)offset;
  moonbit_bytes_t b = moonbit_make_bytes(length, 0);
  DWORD got = 0;
  if ((offset != 0.0 && !SetFilePointerEx(h, at, NULL, FILE_BEGIN)) ||
      !ReadFile(h, b, (DWORD)length, &got, NULL)) {
    got = 0;
  }
  CloseHandle(h);
  if ((int32_t)got == length) return b;
  return rp_bytes((const char *)b, (int32_t)got);
}

// Writes `data` to a file atomically via a sibling temp file + MoveFileExW so readers (and the recorder's
// FileSystemWatcher) never see a truncated or write-locked settings/request file; falls back to direct write.
int32_t rp_write(moonbit_bytes_t path, moonbit_bytes_t data) {
  wchar_t *w = rp_wide((const char *)path);
  size_t wlen = wcslen(w);
  size_t tcap = wlen + 48;
  wchar_t *tmp = (wchar_t *)malloc(tcap * sizeof(wchar_t));
  DWORD n = (DWORD)Moonbit_array_length(data);
  if (tmp) {
    static volatile LONG rp_write_seq = 0;
    LONG seq = InterlockedIncrement(&rp_write_seq);
    swprintf(tmp, tcap, L"%ls.%lu.%ld.tmp", w, (unsigned long)GetCurrentProcessId(), (long)seq);
    HANDLE h = CreateFileW(tmp, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h != INVALID_HANDLE_VALUE) {
      DWORD wrote = 0;
      BOOL ok = WriteFile(h, data, n, &wrote, NULL) && wrote == n;
      CloseHandle(h);
      if (ok && MoveFileExW(tmp, w, MOVEFILE_REPLACE_EXISTING)) {
        free(tmp);
        free(w);
        return 1;
      }
      DeleteFileW(tmp);
    }
    free(tmp);
  }
  HANDLE h = CreateFileW(w, GENERIC_WRITE, FILE_SHARE_READ, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
  free(w);
  if (h == INVALID_HANDLE_VALUE) return 0;
  DWORD wrote = 0;
  BOOL ok = WriteFile(h, data, n, &wrote, NULL) && wrote == n;
  CloseHandle(h);
  return ok ? 1 : 0;
}

// Makes a directory and those above it.
int32_t rp_mkdirs(moonbit_bytes_t path) {
  wchar_t *w = rp_wide((const char *)path);
  int32_t ok = 1;
  // (from past the drive's "C:\"; a path shorter than that from its start: w + 3 was past its end, read beyond it)
  size_t len = wcslen(w);
  for (wchar_t *p = w + (len < 3 ? len : 3); *p; p++) {
    if (*p == L'\\' || *p == L'/') {
      wchar_t c = *p;
      *p = 0;
      CreateDirectoryW(w, NULL);
      *p = c;
    }
  }
  if (!CreateDirectoryW(w, NULL) && GetLastError() != ERROR_ALREADY_EXISTS) ok = 0;
  free(w);
  return ok;
}

// How far local time is ahead of UTC now, in minutes.
int32_t rp_local_offset(void) {
  SYSTEMTIME utc, local;
  GetSystemTime(&utc);
  SystemTimeToTzSpecificLocalTime(NULL, &utc, &local);
  FILETIME fu, fl;
  SystemTimeToFileTime(&utc, &fu);
  SystemTimeToFileTime(&local, &fl);
  ULARGE_INTEGER a, b;
  a.LowPart = fu.dwLowDateTime; a.HighPart = fu.dwHighDateTime;
  b.LowPart = fl.dwLowDateTime; b.HighPart = fl.dwHighDateTime;
  return (int32_t)(((LONGLONG)b.QuadPart - (LONGLONG)a.QuadPart) / 600000000LL);
}

// Milliseconds since the epoch, UTC.
double rp_now(void) {
  FILETIME ft;
  // (precise and to the fraction of a millisecond: the playhead is moved by it every frame, and the plain clock's
  // whole milliseconds, or its 15.6 ms ticks, made it go in uneven steps)
  GetSystemTimePreciseAsFileTime(&ft);
  ULARGE_INTEGER t;
  t.LowPart = ft.dwLowDateTime; t.HighPart = ft.dwHighDateTime;
  double real = (double)(t.QuadPart - 116444736000000000ULL) / 10000.0;
  // (REPLAY_NOW, ms since the epoch: the clock set to that moment as the window starts and going on from it, for a
  // demo's pictures to say "Today 10:40 · 3 min ago" whenever they are taken; a test instance's only)
  static int asked = 0;
  static double shift = 0.0;
  if (!asked) {
    asked = 1;
    char v[32];
    DWORD n = GetEnvironmentVariableA("REPLAY_NOW", v, sizeof v);
    if (n > 0 && n < sizeof v) shift = atof(v) - real;
  }
  return real + shift;
}

// The file shown selected in Explorer.
void rp_reveal(moonbit_bytes_t path) {
  char args[2300];
  snprintf(args, sizeof args, "/select,\"%s\"", (const char *)path);
  wchar_t *w = rp_wide(args);
  ShellExecuteW(NULL, L"open", L"explorer.exe", w, NULL, SW_SHOWNORMAL);
  free(w);
}

// The file put on the clipboard as a file (CF_HDROP), as Explorer's Copy does: pasted into a chat or a folder, it is
// the file. 1 when it is there.
int32_t rp_copy_file(moonbit_bytes_t path) {
  wchar_t *w = rp_wide((const char *)path);
  size_t n = wcslen(w);
  SIZE_T bytes = sizeof(DROPFILES) + (n + 2) * sizeof(wchar_t);
  HGLOBAL mem = GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT, bytes);
  int32_t ok = 0;
  if (mem) {
    DROPFILES *drop = (DROPFILES *)GlobalLock(mem);
    if (drop) {
      drop->pFiles = sizeof(DROPFILES);
      drop->fWide = TRUE;
      memcpy((char *)drop + sizeof(DROPFILES), w, n * sizeof(wchar_t));
      GlobalUnlock(mem);
    }
    if (drop && OpenClipboard(NULL)) {
      EmptyClipboard();
      if (SetClipboardData(CF_HDROP, mem)) {
        ok = 1;
        mem = NULL;
      }
      CloseClipboard();
    }
    if (mem) GlobalFree(mem);
  }
  free(w);
  return ok;
}

// The recorder (ScreenReplay.exe, beside this program) started in the background: what the replay window's "start
// recording" does when the recorder is not running. 1 when it was started.
int32_t rp_launch_recorder(void) {
  wchar_t self[MAX_PATH];
  DWORD n = GetModuleFileNameW(NULL, self, MAX_PATH);
  if (n == 0 || n >= MAX_PATH) return 0;
  wchar_t *slash = wcsrchr(self, L'\\');
  if (!slash) return 0;
  wcscpy_s(slash + 1, MAX_PATH - (slash + 1 - self), L"ScreenReplay.exe");
  INT_PTR r = (INT_PTR)ShellExecuteW(NULL, L"open", self, L"--background", NULL, SW_SHOWNORMAL);
  return r > 32;
}

// A file moved to another name, replacing nothing (1 when it was).
int32_t rp_rename(moonbit_bytes_t from, moonbit_bytes_t to) {
  wchar_t *a = rp_wide((const char *)from);
  wchar_t *b = rp_wide((const char *)to);
  BOOL ok = MoveFileExW(a, b, MOVEFILE_WRITE_THROUGH);
  free(a);
  free(b);
  return ok ? 1 : 0;
}

// A file removed (what a failed save left).
void rp_delete(moonbit_bytes_t path) {
  wchar_t *w = rp_wide((const char *)path);
  DeleteFileW(w);
  free(w);
}

// The folder this program is in (UTF-8, no slash at its end).
moonbit_bytes_t rp_exe_dir(void) {
  wchar_t self[MAX_PATH];
  DWORD n = GetModuleFileNameW(NULL, self, MAX_PATH);
  if (n == 0 || n >= MAX_PATH) return moonbit_make_bytes(0, 0);
  wchar_t *slash = wcsrchr(self, L'\\');
  if (slash) *slash = 0;
  int k = WideCharToMultiByte(CP_UTF8, 0, self, -1, NULL, 0, NULL, NULL);
  moonbit_bytes_t out = moonbit_make_bytes(k > 0 ? k - 1 : 0, 0);
  if (k > 1) WideCharToMultiByte(CP_UTF8, 0, self, -1, (char *)out, k - 1, NULL, NULL);
  return out;
}

// How many bytes the files directly in a folder take (-1: no such folder).
double rp_dir_size(moonbit_bytes_t dir) {
  char pattern[2100];
  snprintf(pattern, sizeof pattern, "%s\\*", (const char *)dir);
  wchar_t *w = rp_wide(pattern);
  WIN32_FIND_DATAW fd;
  HANDLE h = FindFirstFileW(w, &fd);
  free(w);
  if (h == INVALID_HANDLE_VALUE) return -1;
  double total = 0;
  do {
    if (!(fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY))
      total += (double)fd.nFileSizeHigh * 4294967296.0 + (double)fd.nFileSizeLow;
  } while (FindNextFileW(h, &fd));
  FindClose(h);
  return total;
}

// Adds `data` at the end of a file (made if missing; another program may be appending too); whether it could.
int32_t rp_append(moonbit_bytes_t path, moonbit_bytes_t data) {
  wchar_t *w = rp_wide((const char *)path);
  HANDLE h = CreateFileW(w, FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL, OPEN_ALWAYS,
                         FILE_ATTRIBUTE_NORMAL, NULL);
  free(w);
  if (h == INVALID_HANDLE_VALUE) return 0;
  DWORD wrote = 0;
  BOOL ok = WriteFile(h, data, (DWORD)Moonbit_array_length(data), &wrote, NULL);
  CloseHandle(h);
  return ok ? 1 : 0;
}

// The window filling its screen, or back as it was (mbui's Windows host has none of this: @hostapi.set_full_screen).
static HWND rp_main_window;
static BOOL CALLBACK rp_find_main(HWND hwnd, LPARAM context) {
  DWORD pid = 0;
  (void)context;
  GetWindowThreadProcessId(hwnd, &pid);
  if (pid == GetCurrentProcessId() && GetWindow(hwnd, GW_OWNER) == NULL && IsWindowVisible(hwnd)) {
    rp_main_window = hwnd;
    return FALSE;
  }
  return TRUE;
}

static int rp_full = 0;
static LONG_PTR rp_full_style;
static WINDOWPLACEMENT rp_full_place = {sizeof(WINDOWPLACEMENT)};

int32_t rp_fullscreen(int32_t on) {
  if (on < 0) return rp_full;
  if (!rp_main_window || !IsWindow(rp_main_window)) {
    rp_main_window = NULL;
    EnumWindows(rp_find_main, 0);
  }
  HWND h = rp_main_window;
  if (!h || (on != 0) == (rp_full != 0)) return rp_full;
  if (on) {
    MONITORINFO mi = {sizeof(mi)};
    if (!GetMonitorInfoW(MonitorFromWindow(h, MONITOR_DEFAULTTONEAREST), &mi)) return rp_full;
    GetWindowPlacement(h, &rp_full_place);
    rp_full_style = GetWindowLongPtrW(h, GWL_STYLE);
    SetWindowLongPtrW(h, GWL_STYLE, rp_full_style & ~(LONG_PTR)(WS_CAPTION | WS_THICKFRAME | WS_MAXIMIZE));
    SetWindowPos(h, NULL, mi.rcMonitor.left, mi.rcMonitor.top, mi.rcMonitor.right - mi.rcMonitor.left,
                 mi.rcMonitor.bottom - mi.rcMonitor.top, SWP_FRAMECHANGED | SWP_NOZORDER | SWP_NOOWNERZORDER);
    rp_full = 1;
  } else {
    SetWindowLongPtrW(h, GWL_STYLE, rp_full_style);
    SetWindowPlacement(h, &rp_full_place);
    SetWindowPos(h, NULL, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOOWNERZORDER | SWP_FRAMECHANGED);
    rp_full = 0;
  }
  return rp_full;
}

// Whether Windows' apps are light (HKCU ... Themes\Personalize, AppsUseLightTheme; 0 when it cannot be read).
int32_t rp_system_light(void) {
  DWORD v = 0, n = sizeof(v);
  if (RegGetValueW(HKEY_CURRENT_USER, L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
                   L"AppsUseLightTheme", RRF_RT_REG_DWORD, NULL, &v, &n) != ERROR_SUCCESS)
    return 0;
  return v ? 1 : 0;
}

// Whether Windows shows Chinese (its UI language's primary language).
int32_t rp_system_chinese(void) {
  return PRIMARYLANGID(GetUserDefaultUILanguage()) == LANG_CHINESE ? 1 : 0;
}

// The window's frame and system menu dark or light (DWMWA_USE_IMMERSIVE_DARK_MODE).
void rp_window_dark(int32_t on) {
  if (!rp_main_window || !IsWindow(rp_main_window)) {
    rp_main_window = NULL;
    EnumWindows(rp_find_main, 0);
  }
  if (!rp_main_window) return;
  BOOL v = on ? TRUE : FALSE;
  DwmSetWindowAttribute(rp_main_window, 20, &v, sizeof(v));
}

// Every window of this process kept out of what the screen is captured into, or let back (SetWindowDisplayAffinity's
// WDA_EXCLUDEFROMCAPTURE: the recorder's capture shows what is under them, and so does every other screenshot, recording
// or share; the user, 2026-11-15: 「可以不录制 screenreplay 本身」, a switch in the settings, on at first). Set only
// where it is not so already, each window as it is found (the tray's panel, a window made later).
static BOOL CALLBACK rp_affinity_one(HWND hwnd, LPARAM on) {
  DWORD pid = 0;
  GetWindowThreadProcessId(hwnd, &pid);
  if (pid == GetCurrentProcessId()) {
    DWORD now = 0, want = on ? 0x11 /* WDA_EXCLUDEFROMCAPTURE */ : 0 /* WDA_NONE */;
    if (!GetWindowDisplayAffinity(hwnd, &now) || now != want) SetWindowDisplayAffinity(hwnd, want);
  }
  return TRUE;
}

// (asked every second, in each of the program's three processes: every window of the desktop walked each time before;
// now this thread's own windows, where its windows are made, and the whole desktop's only as the switch turns or
// every 30 s for a window another thread of the process made)
static BOOL CALLBACK rp_affinity_thread(HWND hwnd, LPARAM on) { return rp_affinity_one(hwnd, on); }

static int rp_last_affinity = -1;

void rp_hide_from_capture(int32_t on) {
  static ULONGLONG walked = 0;
  ULONGLONG now = GetTickCount64();
  if (rp_last_affinity != on || now - walked >= 30000) {
    rp_last_affinity = on;
    walked = now;
    EnumWindows(rp_affinity_one, (LPARAM)on);
    return;
  }
  EnumThreadWindows(GetCurrentThreadId(), rp_affinity_thread, (LPARAM)on);
}

// The pointer hidden till it moves (full screen, the bars gone): the window shows its own again at the next move.
void rp_hide_cursor(void) {
  SetCursor(NULL);
}

// Whether Windows' animation effects are off (Accessibility > Visual effects > Animation effects).
int32_t rp_animations_off(void) {
  BOOL on = TRUE;
  if (!SystemParametersInfoW(SPI_GETCLIENTAREAANIMATION, 0, &on, 0)) return 0;
  return on ? 0 : 1;
}

// Text put on the clipboard (UTF-8 in); whether it could.
int32_t rp_copy_text(moonbit_bytes_t text) {
  wchar_t *w = rp_wide((const char *)text);
  size_t n = (wcslen(w) + 1) * sizeof(wchar_t);
  int ok = 0;
  if (OpenClipboard(NULL)) {
    EmptyClipboard();
    HGLOBAL g = GlobalAlloc(GMEM_MOVEABLE, n);
    void *to = g ? GlobalLock(g) : NULL;
    if (to) {
      memcpy(to, w, n);
      GlobalUnlock(g);
      ok = SetClipboardData(CF_UNICODETEXT, g) != NULL;
    }
    if (g && !ok) GlobalFree(g);
    CloseClipboard();
  }
  free(w);
  return ok;
}

static moonbit_bytes_t rp_utf8(const wchar_t *w) {
  int k = WideCharToMultiByte(CP_UTF8, 0, w, -1, NULL, 0, NULL, NULL);
  moonbit_bytes_t out = moonbit_make_bytes(k > 0 ? k - 1 : 0, 0);
  if (k > 1) WideCharToMultiByte(CP_UTF8, 0, w, -1, (char *)out, k - 1, NULL, NULL);
  return out;
}

// Windows' version, "10.0.26300" (RtlGetVersion: not what the manifest lets GetVersionEx say).
moonbit_bytes_t rp_windows_version(void) {
  typedef LONG(WINAPI * RtlGetVersionFn)(OSVERSIONINFOW *);
  OSVERSIONINFOW v = {sizeof(v)};
  RtlGetVersionFn f = (RtlGetVersionFn)GetProcAddress(GetModuleHandleW(L"ntdll.dll"), "RtlGetVersion");
  wchar_t s[64] = L"?";
  if (f && f(&v) == 0) swprintf(s, 64, L"%lu.%lu.%lu", v.dwMajorVersion, v.dwMinorVersion, v.dwBuildNumber);
  return rp_utf8(s);
}

// The primary display adapter's name and its driver's version (from the registry key EnumDisplayDevices names).
moonbit_bytes_t rp_gpu(void) {
  DISPLAY_DEVICEW d = {sizeof(d)};
  wchar_t s[512] = L"?";
  for (DWORD i = 0; EnumDisplayDevicesW(NULL, i, &d, 0); i++) {
    if (d.StateFlags & DISPLAY_DEVICE_PRIMARY_DEVICE) {
      wchar_t driver[128] = L"";
      const wchar_t *key = wcsstr(d.DeviceKey, L"\\Control\\");
      if (key) {
        wchar_t path[256];
        swprintf(path, 256, L"SYSTEM\\CurrentControlSet%s", key);
        DWORD n = sizeof(driver);
        RegGetValueW(HKEY_LOCAL_MACHINE, path, L"DriverVersion", RRF_RT_REG_SZ, NULL, driver, &n);
      }
      swprintf(s, 512, L"%s%s%s", d.DeviceString, driver[0] ? L", driver " : L"", driver);
      break;
    }
  }
  return rp_utf8(s);
}

// Resident (the user's ask, 2026-11-13: 「做成常驻，瞬开」): the window kept by the recorder from its start, hidden, and
// shown at once when asked (the recorder shows it: ScreenReplay.exe's OpenReplay). Closed, it is only hidden again:
// its close (the title bar's ×, Alt+F4, WM_CLOSE) taken here before mbui's host would end the program. How many times it
// was hidden and shown, for the app to put itself back as at a fresh open (rp_window_turns).
extern void *mb_app_hwnd(void);
extern void *mb_app_hwnd_of(int wid);
extern void mb_app_wake(void);
extern void mb_post(const char *channel, const char *json, size_t len, const uint8_t *bytes, size_t blen);
static void rp_wake_moonbit(void) {
  mb_post("rp.wake", "", 0, NULL, 0);
}
static WNDPROC rp_prev_proc;
static volatile LONG rp_hides, rp_shows;
static volatile LONG rp_tray_req_seq, rp_note_req_seq;
static volatile int rp_tray_req_x, rp_tray_req_y;
static int rp_priming, rp_show_asked, rp_hiding;
static HWND rp_primed_hwnd, rp_hiding_hwnd;
static LONG_PTR rp_primed_ex;
static COLORREF rp_bg_rgb = RGB(0x1B, 0x1C, 0x1F);

// What the hidden window holds for playing let go of at once, as it hides (replay_play.cpp, replay_mf.cpp): mbui draws
// no frame for a hidden window, so nothing of the app's runs till it shows again; on WM_CLOSE the window is cloaked
// immediately (0 ms visual vanish) and given one frame for MoonBit's put_away() to release GPU/image caches before
// rp_resident_hidden() calls ShowWindow(SW_HIDE), with a short fallback timer in case no frame runs.
extern void rp_play_release(void);
extern void rp_aac_release_all(void);
extern void rp_thumb_release(void);
extern void rp_frame_release(void);

void rp_set_bg_rgb(int32_t rgb) {
  rp_bg_rgb = RGB((rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF, rgb & 0xFF);
}

void rp_resident_primed(void);
void rp_resident_hidden(void);

static VOID CALLBACK rp_resident_primed_timer(HWND h, UINT msg, UINT_PTR id, DWORD at) {
  (void)msg;
  (void)at;
  KillTimer(h, id);
  rp_resident_primed();
}

static VOID CALLBACK rp_resident_hide_timer(HWND h, UINT msg, UINT_PTR id, DWORD at) {
  (void)msg;
  (void)at;
  KillTimer(h, id);
  rp_resident_hidden();
}

static void rp_unprime_now(HWND h, int hide) {
  if (!rp_priming || !h) return;
  KillTimer(h, 0x5252);
  rp_priming = 0;
  if (hide) ShowWindow(h, SW_HIDE);
  SetWindowLongPtrW(h, GWL_EXSTYLE, rp_primed_ex);
  BOOL cloak = FALSE;
  DwmSetWindowAttribute(h, DWMWA_CLOAK, &cloak, sizeof(cloak));
}

void rp_resident_primed(void) {
  HWND h = rp_primed_hwnd ? rp_primed_hwnd : (HWND)mb_app_hwnd();
  if (!rp_priming || !h) return;
  if (rp_show_asked) {
    rp_unprime_now(h, 0);
    InterlockedIncrement(&rp_shows);
    mb_app_wake();
    return;
  }
  rp_unprime_now(h, 1);
}

void rp_resident_hidden(void) {
  HWND h = rp_hiding_hwnd ? rp_hiding_hwnd : (HWND)mb_app_hwnd();
  if (!rp_hiding || !h) return;
  KillTimer(h, 0x5253);
  rp_hiding = 0;
  rp_hiding_hwnd = NULL;
  ShowWindow(h, SW_HIDE);
  BOOL cloak = FALSE;
  DwmSetWindowAttribute(h, DWMWA_CLOAK, &cloak, sizeof(cloak));
}

static void rp_cancel_hiding(HWND h) {
  if (!rp_hiding || !h) return;
  KillTimer(h, 0x5253);
  rp_hiding = 0;
  rp_hiding_hwnd = NULL;
  BOOL cloak = FALSE;
  DwmSetWindowAttribute(h, DWMWA_CLOAK, &cloak, sizeof(cloak));
}

static LRESULT CALLBACK rp_resident_proc(HWND h, UINT msg, WPARAM wp, LPARAM lp) {
  if (msg == WM_ERASEBKGND && wp) {
    RECT rc;
    if (GetClientRect(h, &rc)) {
      HBRUSH br = CreateSolidBrush(rp_bg_rgb);
      if (br) {
        FillRect((HDC)wp, &rc, br);
        DeleteObject(br);
      }
    }
    return 1;
  }
  if (msg == WM_APP + 0x54) {
    rp_tray_req_x = (int)(intptr_t)wp;
    rp_tray_req_y = (int)(intptr_t)lp;
    InterlockedIncrement(&rp_tray_req_seq);
    rp_wake_moonbit();
    return 0;
  }
  if (msg == WM_APP + 0x53) {
    InterlockedIncrement(&rp_note_req_seq);
    rp_wake_moonbit();
    return 0;
  }
  if (msg == WM_CLOSE) {
    if (!rp_hiding) {
      BOOL cloak = TRUE;
      DwmSetWindowAttribute(h, DWMWA_CLOAK, &cloak, sizeof(cloak));
      rp_hiding = 1;
      rp_hiding_hwnd = h;
      SetTimer(h, 0x5253, 300, rp_resident_hide_timer);
      InterlockedIncrement(&rp_hides);
      rp_play_release();
      rp_aac_release_all();
      rp_thumb_release();
      rp_frame_release();
      rp_wake_moonbit();
    }
    return 0;
  }
  if (msg == WM_ACTIVATE && LOWORD(wp) != WA_INACTIVE) {
    if (rp_priming) {
      rp_show_asked = 1;
      rp_unprime_now(h, 0);
      InterlockedIncrement(&rp_shows);
      rp_wake_moonbit();
    } else if (rp_hiding) {
      rp_cancel_hiding(h);
      InterlockedIncrement(&rp_shows);
      rp_wake_moonbit();
    }
  }
  if (msg == WM_WINDOWPOSCHANGED && !rp_priming) {
    const WINDOWPOS *pos = (const WINDOWPOS *)lp;
    if (pos->flags & SWP_SHOWWINDOW) {
      if (rp_hiding) rp_cancel_hiding(h);
      InterlockedIncrement(&rp_shows);
      rp_wake_moonbit();
    }
  }
  return CallWindowProcW(rp_prev_proc, h, msg, wp, lp);
}

// The window kept when closed (1 when it is now).
int32_t rp_stay_resident(void) {
  HWND h = (HWND)mb_app_hwnd();
  if (!h || rp_prev_proc) return rp_prev_proc ? 1 : 0;
  rp_prev_proc = (WNDPROC)SetWindowLongPtrW(h, GWLP_WNDPROC, (LONG_PTR)rp_resident_proc);
  return rp_prev_proc ? 1 : 0;
}

// Alt with an arrow (a clip's region resized by the keys): Windows sends it as WM_SYSKEYDOWN, which mbui's host takes
// for back and forward; given to it as a WM_KEYDOWN instead, it tells the arrow with the modifiers held (Alt among
// them), as any key.
static WNDPROC rp_alt_prev;

static LRESULT CALLBACK rp_alt_proc(HWND h, UINT msg, WPARAM wp, LPARAM lp) {
  if (msg == WM_SYSKEYDOWN && (wp == VK_LEFT || wp == VK_RIGHT || wp == VK_UP || wp == VK_DOWN))
    return CallWindowProcW(rp_alt_prev, h, WM_KEYDOWN, wp, lp);
  return CallWindowProcW(rp_alt_prev, h, msg, wp, lp);
}

// The Alt+arrows taken so (1 when they are now).
int32_t rp_alt_arrows(void) {
  HWND h = (HWND)mb_app_hwnd();
  if (!h || rp_alt_prev) return rp_alt_prev ? 1 : 0;
  rp_alt_prev = (WNDPROC)SetWindowLongPtrW(h, GWLP_WNDPROC, (LONG_PTR)rp_alt_proc);
  return rp_alt_prev ? 1 : 0;
}

// How many times it was hidden (closed) and shown, as hides * 65536 + shows (each kept under 65536).
int32_t rp_window_turns(void) {
  return (int32_t)(((rp_hides & 0x7FFF) << 16) | (rp_shows & 0xFFFF));
}

// Whether the window shows now (false while cloaked for hidden first-frame priming or closing cleanup).
int32_t rp_window_shown(void) {
  HWND h = (HWND)mb_app_hwnd();
  return h && IsWindowVisible(h) && !rp_priming && !rp_hiding ? 1 : 0;
}

// Started hidden (the recorder's resident start, REPLAY_HIDDEN=1): mbui's host shows its window as it makes it, and
// the program's start-up show state is not asked there, so the first show of this thread's first top-level window is
// either stripped (tray panel / note card: rp_start_hidden) or shown DWM-cloaked with WS_EX_TOOLWINDOW for one frame
// (main resident window: rp_start_resident_hidden) so shaders and the UI shell are presented before the window hides,
// preventing a ~0.5 s blank white flash on first activation.
static HHOOK rp_cbt;
static WNDPROC rp_hidden_prev;
static HWND rp_hidden_window;
static int rp_hidden_prime;

static LRESULT CALLBACK rp_hidden_proc(HWND h, UINT msg, WPARAM wp, LPARAM lp) {
  if (msg == WM_ACTIVATE && LOWORD(wp) != WA_INACTIVE && rp_priming && h == rp_primed_hwnd) {
    rp_show_asked = 1;
    rp_unprime_now(h, 0);
    InterlockedIncrement(&rp_shows);
    mb_app_wake();
  }
  if (msg == WM_WINDOWPOSCHANGING && rp_hidden_window == h) {
    WINDOWPOS *pos = (WINDOWPOS *)lp;
    if (pos->flags & SWP_SHOWWINDOW) {
      rp_hidden_window = NULL;
      if (rp_hidden_prime) {
        pos->flags |= SWP_NOACTIVATE;
        rp_primed_ex = GetWindowLongPtrW(h, GWL_EXSTYLE);
        SetWindowLongPtrW(h, GWL_EXSTYLE, (rp_primed_ex & ~(LONG_PTR)WS_EX_APPWINDOW) | WS_EX_TOOLWINDOW);
        BOOL cloak = TRUE;
        DwmSetWindowAttribute(h, DWMWA_CLOAK, &cloak, sizeof(cloak));
        rp_priming = 1;
        rp_primed_hwnd = h;
        SetTimer(h, 0x5252, 2000, rp_resident_primed_timer);
      } else {
        pos->flags &= ~SWP_SHOWWINDOW;
      }
    }
  }
  return CallWindowProcW(rp_hidden_prev, h, msg, wp, lp);
}

static LRESULT CALLBACK rp_cbt_proc(int code, WPARAM wp, LPARAM lp) {
  if (code == HCBT_CREATEWND) {
    CBT_CREATEWNDW *c = (CBT_CREATEWNDW *)lp;
    if (c->lpcs->hwndParent == NULL && !(c->lpcs->style & WS_CHILD) && !rp_hidden_prev) {
      HWND h = (HWND)wp;
      rp_hidden_window = h;
      rp_hidden_prev = (WNDPROC)SetWindowLongPtrW(h, GWLP_WNDPROC, (LONG_PTR)rp_hidden_proc);
      UnhookWindowsHookEx(rp_cbt);
      rp_cbt = NULL;
      return 0;
    }
  }
  return CallNextHookEx(rp_cbt, code, wp, lp);
}

void rp_start_hidden(void) {
  rp_hidden_prime = 0;
  if (!rp_cbt) rp_cbt = SetWindowsHookExW(WH_CBT, rp_cbt_proc, NULL, GetCurrentThreadId());
}

void rp_start_resident_hidden(void) {
  rp_hidden_prime = 1;
  if (!rp_cbt) rp_cbt = SetWindowsHookExW(WH_CBT, rp_cbt_proc, NULL, GetCurrentThreadId());
}

// The window's menu (Restore, Move, Size, Minimize, Maximize, Close), as a right click on a title bar opens it: at
// (x, y) in pixels of the window's client area. mbui's host moves the window from the app's own title bar but opens
// no menu for it. (Its calls found as it is asked, not linked: linked, the window took 0.27 s longer to first show,
// measured 2026-11-13; WM_SYSMENU posted to the window opens nothing, mbui's window procedure keeping it.)
typedef HMENU(WINAPI *rp_get_menu_f)(HWND, BOOL);
typedef BOOL(WINAPI *rp_enable_f)(HMENU, UINT, UINT);
typedef BOOL(WINAPI *rp_default_f)(HMENU, UINT, UINT);
typedef BOOL(WINAPI *rp_track_f)(HMENU, UINT, int, int, int, HWND, const RECT *);
void rp_system_menu(double x, double y) {
  HWND h = (HWND)mb_app_hwnd();
  HMODULE u = GetModuleHandleW(L"user32.dll");
  if (!h || !u) return;
  rp_get_menu_f get_menu = (rp_get_menu_f)(void *)GetProcAddress(u, "GetSystemMenu");
  rp_enable_f enable = (rp_enable_f)(void *)GetProcAddress(u, "EnableMenuItem");
  rp_default_f set_default = (rp_default_f)(void *)GetProcAddress(u, "SetMenuDefaultItem");
  rp_track_f track = (rp_track_f)(void *)GetProcAddress(u, "TrackPopupMenu");
  if (!get_menu || !enable || !set_default || !track) return;
  POINT p = {(LONG)x, (LONG)y};
  ClientToScreen(h, &p);
  HMENU m = get_menu(h, FALSE);
  if (!m) return;
  BOOL zoomed = IsZoomed(h);
  enable(m, SC_RESTORE, MF_BYCOMMAND | (zoomed ? MF_ENABLED : MF_GRAYED));
  enable(m, SC_MAXIMIZE, MF_BYCOMMAND | (zoomed ? MF_GRAYED : MF_ENABLED));
  enable(m, SC_MOVE, MF_BYCOMMAND | (zoomed ? MF_GRAYED : MF_ENABLED));
  enable(m, SC_SIZE, MF_BYCOMMAND | (zoomed ? MF_GRAYED : MF_ENABLED));
  set_default(m, SC_CLOSE, FALSE);
  int cmd = track(m, TPM_RETURNCMD | TPM_RIGHTBUTTON, p.x, p.y, 0, h, NULL);
  if (cmd) PostMessageW(h, WM_SYSCOMMAND, (WPARAM)cmd, 0);
}

// How the window stands, for the playing log (perf_log.mbt): 1 in front, 2 minimized, 4 shown.
int rp_window_state(void) {
  HWND h = (HWND)mb_app_hwnd();
  if (!h) return 0;
  return (GetForegroundWindow() == h ? 1 : 0) | (IsIconic(h) ? 2 : 0) | (IsWindowVisible(h) ? 4 : 0);
}

// The buffer's folder chosen by the system's own folder dialog over the window, its path in UTF-8 ("" none chosen).
moonbit_bytes_t rp_pick_folder(void) {
  HWND h = (HWND)mb_app_hwnd();
  IFileOpenDialog *d = NULL;
  char out[2048];
  int n = 0;
  if (SUCCEEDED(CoCreateInstance(&CLSID_FileOpenDialog, NULL, CLSCTX_INPROC_SERVER, &IID_IFileOpenDialog, (void **)&d))) {
    DWORD opts = 0;
    d->lpVtbl->GetOptions(d, &opts);
    d->lpVtbl->SetOptions(d, opts | FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST);
    if (SUCCEEDED(d->lpVtbl->Show(d, h))) {
      IShellItem *item = NULL;
      if (SUCCEEDED(d->lpVtbl->GetResult(d, &item))) {
        PWSTR path = NULL;
        if (SUCCEEDED(item->lpVtbl->GetDisplayName(item, SIGDN_FILESYSPATH, &path))) {
          n = WideCharToMultiByte(CP_UTF8, 0, path, -1, out, sizeof out, NULL, NULL);
          CoTaskMemFree(path);
        }
        item->lpVtbl->Release(item);
      }
    }
    d->lpVtbl->Release(d);
  }
  return rp_bytes(out, n > 1 ? n - 1 : 0);
}

// Whether a file can be made in `dir` (made where it is not there yet): 1 yes, 0 no.
int32_t rp_can_write(moonbit_bytes_t dir) {
  wchar_t *w = rp_wide((const char *)dir);
  SHCreateDirectoryExW(NULL, w, NULL);
  wchar_t probe[2100];
  _snwprintf(probe, 2100, L"%ls\\.replay-write-probe", w);
  free(w);
  HANDLE f = CreateFileW(probe, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_FLAG_DELETE_ON_CLOSE, NULL);
  if (f == INVALID_HANDLE_VALUE) return 0;
  CloseHandle(f);
  return 1;
}

// The bytes free on the drive `dir` is on (-1 not known).
double rp_disk_free(moonbit_bytes_t dir) {
  wchar_t *w = rp_wide((const char *)dir);
  ULARGE_INTEGER free_bytes;
  BOOL ok = GetDiskFreeSpaceExW(w, &free_bytes, NULL, NULL);
  free(w);
  return ok ? (double)free_bytes.QuadPart : -1.0;
}

// The tray's panel (REPLAY_TRAY=1, tray_panel.mbt): its window made a panel once it is up: no caption, no frame, no
// taskbar button, over the other windows, its corners round as Windows 11 draws a menu's; hidden (not closed) when it
// loses the focus or is closed, as a menu goes. The recorder shows it, where its icon is.
static WNDPROC rp_tray_prev;
static HHOOK rp_tray_mouse;
static HWND rp_tray_hwnd;
// (while it is shown cloaked to be drawn once; and whether it has been shown since, by the recorder: then left shown)
static int rp_tray_priming, rp_tray_asked;

// (a press anywhere outside it while it shows: hidden, as a menu goes; it may not have the focus to lose, Windows
// keeping the focus where it was when the panel could not take it)
static LRESULT CALLBACK rp_tray_mouse_proc(int code, WPARAM wp, LPARAM lp) {
  if (code == HC_ACTION && (wp == WM_LBUTTONDOWN || wp == WM_RBUTTONDOWN || wp == WM_MBUTTONDOWN) && rp_tray_hwnd) {
    MSLLHOOKSTRUCT *m = (MSLLHOOKSTRUCT *)lp;
    RECT r;
    if (IsWindowVisible(rp_tray_hwnd) && GetWindowRect(rp_tray_hwnd, &r) && !PtInRect(&r, m->pt))
      ShowWindow(rp_tray_hwnd, SW_HIDE);
  }
  return CallNextHookEx(rp_tray_mouse, code, wp, lp);
}

static LRESULT CALLBACK rp_tray_proc(HWND h, UINT msg, WPARAM wp, LPARAM lp) {
  if (msg == WM_CLOSE) {
    ShowWindow(h, SW_HIDE);
    return 0;
  }
  if (msg == WM_ACTIVATE && LOWORD(wp) == WA_INACTIVE) ShowWindow(h, SW_HIDE);
  // (shown or hidden by ShowWindow or by SetWindowPos, as the recorder shows it: WM_SHOWWINDOW does not come for that)
  if (msg == WM_WINDOWPOSCHANGED) {
    const WINDOWPOS *pos = (const WINDOWPOS *)lp;
    if ((pos->flags & SWP_SHOWWINDOW) && !rp_tray_priming) rp_tray_asked = 1;
    // (not for its showing cloaked to be drawn once (priming): the hook then hid it at the first press anywhere on the
    // desktop in those 2.5 s, its first frame not drawn yet, and watched every press of the whole desktop meanwhile)
    if ((pos->flags & SWP_SHOWWINDOW) && !rp_tray_mouse && !rp_tray_priming) {
      rp_tray_mouse = SetWindowsHookExW(WH_MOUSE_LL, rp_tray_mouse_proc, GetModuleHandleW(NULL), 0);
    } else if ((pos->flags & SWP_HIDEWINDOW) && rp_tray_mouse) {
      UnhookWindowsHookEx(rp_tray_mouse);
      rp_tray_mouse = NULL;
    }
  }
  if (msg == WM_KEYDOWN && wp == VK_ESCAPE) ShowWindow(h, SW_HIDE);
  return CallWindowProcW(rp_tray_prev, h, msg, wp, lp);
}

void rp_tray_primed(void);

static VOID CALLBACK rp_tray_primed_timer(HWND h, UINT msg, UINT_PTR id, DWORD at) {
  KillTimer(h, id);
  rp_tray_primed();
}

int32_t rp_tray_window(double w_pt, double h_pt) {
  HWND h = (HWND)mb_app_hwnd();
  if (!h) return 0;
  if (rp_tray_prev) {
    int dpi = (int)GetDpiForWindow(h);
    SetWindowPos(h, NULL, 0, 0, (int)(w_pt * dpi / 96.0 + 0.5), (int)(h_pt * dpi / 96.0 + 0.5),
                 SWP_NOMOVE | SWP_NOACTIVATE | SWP_NOZORDER);
    return 1;
  }
  LONG_PTR style = GetWindowLongPtrW(h, GWL_STYLE);
  style &= ~(LONG_PTR)(WS_CAPTION | WS_THICKFRAME | WS_MINIMIZEBOX | WS_MAXIMIZEBOX | WS_SYSMENU);
  SetWindowLongPtrW(h, GWL_STYLE, style | WS_POPUP);
  LONG_PTR ex = GetWindowLongPtrW(h, GWL_EXSTYLE);
  SetWindowLongPtrW(h, GWL_EXSTYLE, (ex & ~(LONG_PTR)WS_EX_APPWINDOW) | WS_EX_TOOLWINDOW | WS_EX_TOPMOST);
  // DWMWA_WINDOW_CORNER_PREFERENCE: DWMWCP_ROUND
  DWORD corner = 2;
  DwmSetWindowAttribute(h, 33, &corner, sizeof(corner));
  // (sized to the panel as its frame goes: the window mbui made has room for a frame it no longer has, the panel's
  // right and foot margins wider than its left and top, as the note card's were)
  int dpi = (int)GetDpiForWindow(h);
  SetWindowPos(h, HWND_TOPMOST, 0, 0, (int)(w_pt * dpi / 96.0 + 0.5), (int)(h_pt * dpi / 96.0 + 0.5),
               SWP_NOMOVE | SWP_NOACTIVATE | SWP_FRAMECHANGED);
  rp_tray_hwnd = h;
  rp_tray_prev = (WNDPROC)SetWindowLongPtrW(h, GWLP_WNDPROC, (LONG_PTR)rp_tray_proc);
  // (shown once now, cloaked (DWMWA_CLOAK: drawn, never seen, no input), so its device is made and its first frame
  // drawn while nobody waits: mbui makes them only for a window shown, and made at the press they took 3 s once, the
  // panel an empty frame meanwhile (the user, 2026-11-18, 「这会托盘点击又卡住了」); rp_tray_primed hides it again
  // 2.5 s on, by a timer of the window's own: one of the tree's waited while the window was hidden by anything else
  // first, and left it cloaked, its first showing empty (mbui of monoid 96481b9))
  if (rp_tray_prev) {
    BOOL cloak = TRUE;
    DwmSetWindowAttribute(h, 13, &cloak, sizeof(cloak));
    rp_tray_priming = 1;
    SetWindowPos(h, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW);
    rp_tray_priming = 0;
    SetTimer(h, 0x5250, 2500, rp_tray_primed_timer);
  }
  return rp_tray_prev ? 1 : 0;
}

// The panel drawn once while cloaked (rp_tray_window): hidden, then let be seen when the recorder shows it. Left as it
// is where the recorder showed it meanwhile (it is visible and has been pressed for: only the cloak taken off).
void rp_tray_primed(void) {
  HWND h = rp_tray_hwnd;
  if (!h) return;
  // (shown by the recorder meanwhile, a press come before the priming was done: left shown, only seen now)
  if (!rp_tray_asked && GetForegroundWindow() != h) ShowWindow(h, SW_HIDE);
  BOOL cloak = FALSE;
  DwmSetWindowAttribute(h, 13, &cloak, sizeof(cloak));
}

// The recorder's note (REPLAY_NOTE, note_card.mbt): its window made a card at the foot of the screen by the tray, over
// the other windows, never taking the focus (a game in front keeps it), shown cloaked till rp_note_reveal so its first
// frame is drawn before it is seen.
static WNDPROC rp_note_prev;

// (the recorder's ask (WM_APP + 0x53, the card kept warm and hidden): shown, still cloaked, so its frames go and its
// look finds the ask in note.json; let be seen by rp_note_reveal once drawn)
static LRESULT CALLBACK rp_note_proc(HWND h, UINT msg, WPARAM wp, LPARAM lp) {
  if (msg == WM_APP + 0x53) {
    BOOL cloak = TRUE;
    DwmSetWindowAttribute(h, 13, &cloak, sizeof(cloak));
    ShowWindow(h, SW_SHOWNOACTIVATE);
    return 0;
  }
  return CallWindowProcW(rp_note_prev, h, msg, wp, lp);
}

int32_t rp_note_window(double w_pt, double h_pt, int32_t cloaked) {
  HWND h = (HWND)mb_app_hwnd();
  if (!h) return 0;
  if (!rp_note_prev) rp_note_prev = (WNDPROC)SetWindowLongPtrW(h, GWLP_WNDPROC, (LONG_PTR)rp_note_proc);
  LONG_PTR style = GetWindowLongPtrW(h, GWL_STYLE);
  style &= ~(LONG_PTR)(WS_CAPTION | WS_THICKFRAME | WS_MINIMIZEBOX | WS_MAXIMIZEBOX | WS_SYSMENU);
  SetWindowLongPtrW(h, GWL_STYLE, style | WS_POPUP);
  LONG_PTR ex = GetWindowLongPtrW(h, GWL_EXSTYLE);
  SetWindowLongPtrW(h, GWL_EXSTYLE, (ex & ~(LONG_PTR)WS_EX_APPWINDOW) | WS_EX_TOOLWINDOW | WS_EX_TOPMOST | WS_EX_NOACTIVATE);
  DWORD corner = 2;
  DwmSetWindowAttribute(h, 33, &corner, sizeof(corner));
  // (cloaked as it is placed when it is to be seen anew; left as it is when it grows in sight)
  BOOL cloak = TRUE;
  if (cloaked) DwmSetWindowAttribute(h, 13, &cloak, sizeof(cloak));
  // (its size set again as its frame goes: the window mbui made has room for a frame it no longer has, which left
  // the card's margins uneven, wider at the right and the foot)
  RECT work;
  SystemParametersInfoW(SPI_GETWORKAREA, 0, &work, 0);
  int dpi = (int)GetDpiForWindow(h);
  int w = (int)(w_pt * dpi / 96.0 + 0.5), hh = (int)(h_pt * dpi / 96.0 + 0.5);
  int margin = MulDiv(12, dpi, 96);
  SetWindowPos(h, HWND_TOPMOST, work.right - w - margin, work.bottom - hh - margin, w, hh,
               SWP_NOACTIVATE | SWP_SHOWWINDOW | SWP_FRAMECHANGED);
  return 1;
}

void rp_note_hide(void) {
  HWND h = (HWND)mb_app_hwnd();
  if (h) ShowWindow(h, SW_HIDE);
}

void rp_note_reveal(void) {
  HWND h = (HWND)mb_app_hwnd();
  if (!h) return;
  // (a test's card left cloaked: looked at with PrintWindow, never over the screen of whoever is at it)
  wchar_t v[4];
  if (GetEnvironmentVariableW(L"REPLAY_NOTE_UNSEEN", v, 4) > 0) return;
  BOOL cloak = FALSE;
  DwmSetWindowAttribute(h, 13, &cloak, sizeof(cloak));
}

void rp_tray_hide(void) {
  HWND h = (HWND)mb_app_hwnd();
  if (h) ShowWindow(h, SW_HIDE);
}

// In-process secondary popups (tray menu and save note card hosted inside the single resident ScreenReplayViewer.exe,
// sharing its D3D11 device, shaders, and 64 MB font atlas so the background app stays at 2 processes total).
int32_t rp_tray_req_seq_get(void) { return (int32_t)rp_tray_req_seq; }
int32_t rp_tray_req_x_get(void) { return (int32_t)rp_tray_req_x; }
int32_t rp_tray_req_y_get(void) { return (int32_t)rp_tray_req_y; }
int32_t rp_note_req_seq_get(void) { return (int32_t)rp_note_req_seq; }

static HHOOK rp_popup_cbt;
static int rp_popup_kind;
static HWND rp_sub_tray_hwnd, rp_sub_note_hwnd;
static WNDPROC rp_sub_tray_prev, rp_sub_note_prev;
static HHOOK rp_sub_tray_mouse;
static int rp_sub_tray_active;

static LRESULT CALLBACK rp_sub_note_proc(HWND h, UINT msg, WPARAM wp, LPARAM lp) {
  if (msg == WM_MOUSEACTIVATE) return MA_NOACTIVATE;
  if (msg == WM_WINDOWPOSCHANGING) {
    WINDOWPOS *pos = (WINDOWPOS *)lp;
    pos->flags |= SWP_NOACTIVATE;
  }
  WNDPROC prev = rp_sub_note_prev;
  if (msg == WM_DESTROY) {
    if (rp_sub_note_hwnd == h) {
      rp_sub_note_hwnd = NULL;
      rp_sub_note_prev = NULL;
    }
    if (prev) SetWindowLongPtrW(h, GWLP_WNDPROC, (LONG_PTR)prev);
  }
  return prev ? CallWindowProcW(prev, h, msg, wp, lp) : DefWindowProcW(h, msg, wp, lp);
}

static LRESULT CALLBACK rp_popup_cbt_proc(int code, WPARAM wp, LPARAM lp) {
  if (code == HCBT_CREATEWND && rp_popup_kind != 0) {
    CBT_CREATEWNDW *c = (CBT_CREATEWNDW *)lp;
    if (c->lpcs->hwndParent == NULL && !(c->lpcs->style & WS_CHILD)) {
      HWND h = (HWND)wp;
      int kind = rp_popup_kind;
      rp_popup_kind = 0;
      if (rp_popup_cbt) {
        UnhookWindowsHookEx(rp_popup_cbt);
        rp_popup_cbt = NULL;
      }
      c->lpcs->style = (c->lpcs->style & ~(LONG)(WS_CAPTION | WS_THICKFRAME | WS_MINIMIZEBOX | WS_MAXIMIZEBOX | WS_SYSMENU)) | WS_POPUP;
      c->lpcs->dwExStyle = (c->lpcs->dwExStyle & ~(DWORD)WS_EX_APPWINDOW) | WS_EX_TOOLWINDOW | WS_EX_TOPMOST | (kind == 2 ? WS_EX_NOACTIVATE : 0);
      if (kind == 2 && !rp_sub_note_prev) {
        rp_sub_note_hwnd = h;
        rp_sub_note_prev = (WNDPROC)SetWindowLongPtrW(h, GWLP_WNDPROC, (LONG_PTR)rp_sub_note_proc);
      }
      return 0;
    }
  }
  return CallNextHookEx(rp_popup_cbt, code, wp, lp);
}

void rp_prepare_popup(int32_t kind) {
  if (kind == 0) {
    rp_popup_kind = 0;
    if (rp_popup_cbt) {
      UnhookWindowsHookEx(rp_popup_cbt);
      rp_popup_cbt = NULL;
    }
    return;
  }
  rp_popup_kind = (int)kind;
  if (!rp_popup_cbt) rp_popup_cbt = SetWindowsHookExW(WH_CBT, rp_popup_cbt_proc, NULL, GetCurrentThreadId());
}

static LRESULT CALLBACK rp_sub_tray_mouse_proc(int code, WPARAM wp, LPARAM lp) {
  if (code == HC_ACTION && (wp == WM_LBUTTONDOWN || wp == WM_RBUTTONDOWN || wp == WM_MBUTTONDOWN) && rp_sub_tray_hwnd) {
    MSLLHOOKSTRUCT *m = (MSLLHOOKSTRUCT *)lp;
    RECT r;
    if (IsWindowVisible(rp_sub_tray_hwnd) && GetWindowRect(rp_sub_tray_hwnd, &r) && !PtInRect(&r, m->pt))
      PostMessageW(rp_sub_tray_hwnd, WM_CLOSE, 0, 0);
  }
  return CallNextHookEx(rp_sub_tray_mouse, code, wp, lp);
}

static LRESULT CALLBACK rp_sub_tray_proc(HWND h, UINT msg, WPARAM wp, LPARAM lp) {
  if (msg == WM_ACTIVATE) {
    if (LOWORD(wp) != WA_INACTIVE) {
      rp_sub_tray_active = 1;
    } else if (rp_sub_tray_active) {
      PostMessageW(h, WM_CLOSE, 0, 0);
    }
  } else if (msg == WM_KEYDOWN && wp == VK_ESCAPE) {
    PostMessageW(h, WM_CLOSE, 0, 0);
    return 0;
  }
  WNDPROC prev = rp_sub_tray_prev;
  if (msg == WM_DESTROY) {
    if (rp_sub_tray_mouse) {
      UnhookWindowsHookEx(rp_sub_tray_mouse);
      rp_sub_tray_mouse = NULL;
    }
    if (rp_sub_tray_hwnd == h) {
      rp_sub_tray_hwnd = NULL;
      rp_sub_tray_prev = NULL;
      rp_sub_tray_active = 0;
    }
    if (prev) SetWindowLongPtrW(h, GWLP_WNDPROC, (LONG_PTR)prev);
  }
  return prev ? CallWindowProcW(prev, h, msg, wp, lp) : DefWindowProcW(h, msg, wp, lp);
}

int32_t rp_style_tray_win(int32_t wid, double w_pt, double h_pt, int32_t px, int32_t py) {
  HWND h = (HWND)mb_app_hwnd_of((int)wid);
  if (!h) return 0;
  LONG_PTR style = GetWindowLongPtrW(h, GWL_STYLE);
  style = (style & ~(LONG_PTR)(WS_CAPTION | WS_THICKFRAME | WS_MINIMIZEBOX | WS_MAXIMIZEBOX | WS_SYSMENU)) | WS_POPUP;
  SetWindowLongPtrW(h, GWL_STYLE, style);
  LONG_PTR ex = GetWindowLongPtrW(h, GWL_EXSTYLE);
  SetWindowLongPtrW(h, GWL_EXSTYLE, (ex & ~(LONG_PTR)WS_EX_APPWINDOW) | WS_EX_TOOLWINDOW | WS_EX_TOPMOST);
  DWORD corner = 2;
  DwmSetWindowAttribute(h, 33, &corner, sizeof(corner));
  if (rp_last_affinity >= 0) rp_affinity_one(h, (LPARAM)rp_last_affinity);
  int dpi = (int)GetDpiForWindow(h);
  int w = (int)(w_pt * dpi / 96.0 + 0.5);
  int hh = (int)(h_pt * dpi / 96.0 + 0.5);
  POINT pt = {px, py};
  MONITORINFO mi = {sizeof(mi)};
  HMONITOR mon = MonitorFromPoint(pt, MONITOR_DEFAULTTONEAREST);
  RECT work = {0, 0, 1920, 1080};
  if (mon && GetMonitorInfoW(mon, &mi)) work = mi.rcWork;
  int left = px - w < work.left ? px : px - w;
  int top = py - hh < work.top ? py : py - hh;
  int max_left = work.right - w > work.left ? work.right - w : work.left;
  int max_top = work.bottom - hh > work.top ? work.bottom - hh : work.top;
  if (left < work.left) left = work.left;
  if (left > max_left) left = max_left;
  if (top < work.top) top = work.top;
  if (top > max_top) top = max_top;
  if (rp_sub_tray_hwnd != h) {
    rp_sub_tray_hwnd = h;
    rp_sub_tray_active = 0;
    rp_sub_tray_prev = (WNDPROC)SetWindowLongPtrW(h, GWLP_WNDPROC, (LONG_PTR)rp_sub_tray_proc);
  }
  if (!rp_sub_tray_mouse) {
    rp_sub_tray_mouse = SetWindowsHookExW(WH_MOUSE_LL, rp_sub_tray_mouse_proc, GetModuleHandleW(NULL), 0);
  }
  SetWindowPos(h, HWND_TOPMOST, left, top, w, hh, SWP_FRAMECHANGED | SWP_SHOWWINDOW);
  SetForegroundWindow(h);
  return 1;
}

int32_t rp_style_note_win(int32_t wid, double w_pt, double h_pt) {
  HWND h = (HWND)mb_app_hwnd_of((int)wid);
  if (!h) return 0;
  LONG_PTR style = GetWindowLongPtrW(h, GWL_STYLE);
  style = (style & ~(LONG_PTR)(WS_CAPTION | WS_THICKFRAME | WS_MINIMIZEBOX | WS_MAXIMIZEBOX | WS_SYSMENU)) | WS_POPUP;
  SetWindowLongPtrW(h, GWL_STYLE, style);
  LONG_PTR ex = GetWindowLongPtrW(h, GWL_EXSTYLE);
  SetWindowLongPtrW(h, GWL_EXSTYLE, (ex & ~(LONG_PTR)WS_EX_APPWINDOW) | WS_EX_TOOLWINDOW | WS_EX_TOPMOST | WS_EX_NOACTIVATE);
  DWORD corner = 2;
  DwmSetWindowAttribute(h, 33, &corner, sizeof(corner));
  if (rp_last_affinity >= 0) rp_affinity_one(h, (LPARAM)rp_last_affinity);
  if (rp_sub_note_hwnd != h) {
    rp_sub_note_hwnd = h;
    rp_sub_note_prev = (WNDPROC)SetWindowLongPtrW(h, GWLP_WNDPROC, (LONG_PTR)rp_sub_note_proc);
  }
  RECT work;
  SystemParametersInfoW(SPI_GETWORKAREA, 0, &work, 0);
  int dpi = (int)GetDpiForWindow(h);
  int w = (int)(w_pt * dpi / 96.0 + 0.5);
  int hh = (int)(h_pt * dpi / 96.0 + 0.5);
  int margin = MulDiv(12, dpi, 96);
  SetWindowPos(h, HWND_TOPMOST, work.right - w - margin, work.bottom - hh - margin, w, hh,
               SWP_NOACTIVATE | SWP_FRAMECHANGED);
  return 1;
}

// What was chosen in the panel told to the recorder: its window (REPLAY_RECORDER_HWND, hex) sent WM_APP + 0x51 with
// the command. Whether it was.
int32_t rp_tray_tell(int32_t command) {
  wchar_t v[32];
  DWORD n = GetEnvironmentVariableW(L"REPLAY_RECORDER_HWND", v, 32);
  if (n == 0 || n >= 32) return 0;
  HWND recorder = (HWND)(INT_PTR)wcstoll(v, NULL, 16);
  if (!IsWindow(recorder)) return 0;
  return PostMessageW(recorder, WM_APP + 0x51, (WPARAM)command, 0) ? 1 : 0;
}

// Whether this process runs from a package (installed from the Store, or a package put in by hand): it has a package
// identity (GetCurrentPackageFullName, APPMODEL_ERROR_NO_PACKAGE without one).
int32_t rp_packaged(void) {
  UINT32 n = 0;
  return GetCurrentPackageFullName(&n, NULL) == ERROR_INSUFFICIENT_BUFFER ? 1 : 0;
}

// 2 = Store MSIX, 1 = ScreenReplay-Setup installer, 0 = portable/development build
int32_t rp_install_kind(void) {
  if (rp_packaged()) return 2;
  const char *test = getenv("REPLAY_TEST_UPDATE");
  const wchar_t *sub = (test && test[0])
    ? L"Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\ScreenReplay-Test_is1"
    : L"Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\{9C4A8E17-5D2B-4E91-A763-8F10B2C5D9E4}_is1";
  HKEY k;
  if (RegOpenKeyExW(HKEY_CURRENT_USER, sub, 0, KEY_READ, &k) != ERROR_SUCCESS) return 0;
  wchar_t at[MAX_PATH * 2] = {0};
  DWORD sz = sizeof at - sizeof(wchar_t), type = 0;
  LONG r = RegQueryValueExW(k, L"InstallLocation", NULL, &type, (BYTE *)at, &sz);
  RegCloseKey(k);
  if (r != ERROR_SUCCESS || type != REG_SZ) return 0;
  size_t n = wcslen(at);
  while (n > 0 && (at[n - 1] == L'\\' || at[n - 1] == L'/')) at[--n] = 0;
  wchar_t mine[MAX_PATH * 2] = {0};
  GetModuleFileNameW(NULL, mine, MAX_PATH * 2);
  wchar_t *slash = wcsrchr(mine, L'\\');
  if (slash) *slash = 0;
  return CompareStringOrdinal(at, -1, mine, -1, TRUE) == CSTR_EQUAL ? 1 : 0;
}

int32_t rp_is_mac(void) { return 0; }
