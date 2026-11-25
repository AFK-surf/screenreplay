// System, filesystem, clipboard, Finder, diagnostics, and AppKit window hooks for ScreenReplayViewer on macOS.
#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#include <dirent.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <pwd.h>
#include <strings.h>
#include <sys/statvfs.h>
#include <sys/sysctl.h>
#include <atomic>

#include "replay_mac_common.h"

__asm__(".linker_option \"-framework\", \"Cocoa\"");
__asm__(".linker_option \"-framework\", \"Metal\"");
__asm__(".linker_option \"-framework\", \"ImageIO\"");
__asm__(".linker_option \"-framework\", \"CoreGraphics\"");
__asm__(".linker_option \"-framework\", \"Accelerate\"");

namespace {

static void rp_wake_host(void) {
  typedef void (*wake_fn)(void);
  static wake_fn fn = nullptr;
  static bool looked = false;
  if (!looked) {
    looked = true;
    fn = (wake_fn)dlsym(RTLD_DEFAULT, "mb_host_request_frame");
  }
  if (fn) {
    if ([NSThread isMainThread]) fn();
    else dispatch_async(dispatch_get_main_queue(), ^{ fn(); });
  }
}

static NSWindow *rp_main_win(void) {
  if (!NSApp) return nil;
  for (NSWindow *w in NSApp.windows) {
    if ([NSStringFromClass(w.class) isEqualToString:@"MBWindow"]) return w;
  }
  if (NSApp.mainWindow) return NSApp.mainWindow;
  if (NSApp.keyWindow) return NSApp.keyWindow;
  for (NSWindow *w in NSApp.windows) {
    if (w.contentView != nil && ![NSStringFromClass(w.class) hasPrefix:@"NSStatusBar"]) return w;
  }
  return nil;
}

static bool rp_ends_with_ci(const char *name, const char *ext) {
  size_t nl = strlen(name), el = strlen(ext);
  return nl >= el && strcasecmp(name + nl - el, ext) == 0;
}

static moonbit_bytes_t rp_list_exts(moonbit_bytes_t dir_b, const char *const *exts, int n_exts) {
  std::string dir_s = rp_str(dir_b);
  if (dir_s.empty()) return moonbit_make_bytes(0, 0);
  std::string out;
  out.reserve(4096);
  for (int g = 0; g < n_exts; g++) {
    DIR *d = opendir(dir_s.c_str());
    if (!d) continue;
    struct dirent *ent = nullptr;
    while ((ent = readdir(d)) != nullptr) {
      const char *name = ent->d_name;
      if (name[0] == '.' && (name[1] == '\0' || (name[1] == '.' && name[2] == '\0'))) continue;
      if (!rp_ends_with_ci(name, exts[g])) continue;
      bool is_dir = false;
      if (ent->d_type == DT_DIR) {
        is_dir = true;
      } else if (ent->d_type == DT_UNKNOWN || ent->d_type == DT_LNK) {
        std::string full = dir_s + "/" + name;
        struct stat st;
        if (stat(full.c_str(), &st) != 0 || S_ISDIR(st.st_mode)) is_dir = true;
      }
      if (is_dir) continue;
      out.append(name);
      out.push_back('\n');
    }
    closedir(d);
  }
  return rp_bytes_str(out);
}

static std::string rp_self_exe_path(void) {
  uint32_t sz = 0;
  _NSGetExecutablePath(nullptr, &sz);
  if (sz == 0) return {};
  std::vector<char> buf(sz + 1, 0);
  if (_NSGetExecutablePath(buf.data(), &sz) != 0) return {};
  char resolved[PATH_MAX];
  if (realpath(buf.data(), resolved)) return std::string(resolved);
  return std::string(buf.data());
}

static bool rp_mkdirs_str(const std::string &path) {
  if (path.empty()) return false;
  std::string p = path;
  for (size_t i = 1; i < p.size(); i++) {
    if (p[i] == '/') {
      p[i] = '\0';
      mkdir(p.c_str(), 0755);
      p[i] = '/';
    }
  }
  if (mkdir(p.c_str(), 0755) != 0 && errno != EEXIST) return false;
  struct stat st;
  return stat(p.c_str(), &st) == 0 && S_ISDIR(st.st_mode);
}

// Resident / hidden startup state
static std::atomic<int32_t> rp_hides{0};
static std::atomic<int32_t> rp_shows{0};
static std::atomic<int> rp_priming{0};
static std::atomic<int> rp_show_asked{0};
static int rp_start_mode = 0;  // 0 normal, 1 hidden, 2 resident_hidden
static int32_t rp_bg_rgb_val = 0x1B1C1F;
static bool rp_swizzled_front = false;
static IMP rp_orig_make_key_front = nullptr;

static void rp_apply_bg_color(NSWindow *w) {
  if (!w) return;
  CGFloat r = ((rp_bg_rgb_val >> 16) & 0xFF) / 255.0;
  CGFloat g = ((rp_bg_rgb_val >> 8) & 0xFF) / 255.0;
  CGFloat b = (rp_bg_rgb_val & 0xFF) / 255.0;
  w.backgroundColor = [NSColor colorWithSRGBRed:r green:g blue:b alpha:1.0];
}

extern "C" void rp_resident_primed(void);

static void rp_swizzled_makeKeyAndOrderFront(id self, SEL _cmd, id sender) {
  NSWindow *w = (NSWindow *)self;
  if (rp_start_mode != 0 && [NSStringFromClass(w.class) isEqualToString:@"MBWindow"]) {
    int mode = rp_start_mode;
    rp_start_mode = 0;
    rp_apply_bg_color(w);
    if (mode == 2) {
      // Resident hidden priming: keep transparent & non-interactive while Metal draws frame 1, then orderOut.
      rp_priming.store(1);
      w.alphaValue = 0.0;
      w.ignoresMouseEvents = YES;
      [w orderBack:nil];
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (rp_priming.load()) {
          rp_resident_primed();
        }
      });
      return;
    } else {
      // Plain hidden (tray / note): keep ordered out and accessory policy.
      w.alphaValue = 0.0;
      w.ignoresMouseEvents = YES;
      [w orderOut:nil];
      return;
    }
  }
  if (rp_orig_make_key_front) {
    ((void (*)(id, SEL, id))rp_orig_make_key_front)(self, _cmd, sender);
  }
}

static void rp_install_start_hidden_hook(int mode) {
  rp_start_mode = mode;
  if (!rp_swizzled_front) {
    rp_swizzled_front = true;
    Method m = class_getInstanceMethod([NSWindow class], @selector(makeKeyAndOrderFront:));
    if (m) {
      rp_orig_make_key_front = method_setImplementation(m, (IMP)rp_swizzled_makeKeyAndOrderFront);
    }
  }
}

}  // namespace

@interface RPResidentDelegate : NSObject <NSWindowDelegate>
@property(nonatomic, strong) id<NSWindowDelegate> forwardDelegate;
@property(nonatomic) BOOL wasHidden;
@end

@implementation RPResidentDelegate
- (BOOL)respondsToSelector:(SEL)aSelector {
  return [super respondsToSelector:aSelector] || [self.forwardDelegate respondsToSelector:aSelector];
}
- (id)forwardingTargetForSelector:(SEL)aSelector {
  return self.forwardDelegate;
}
- (BOOL)windowShouldClose:(NSWindow *)w {
  [w orderOut:nil];
  self.wasHidden = YES;
  rp_hides.fetch_add(1);
  rp_play_release();
  rp_aac_release_all();
  rp_thumb_release();
  rp_frame_release();
  return NO;
}
- (void)windowDidBecomeKey:(NSNotification *)notification {
  NSWindow *w = notification.object;
  if (rp_priming.load()) {
    rp_show_asked.store(1);
    rp_priming.store(0);
    w.alphaValue = 1.0;
    w.ignoresMouseEvents = NO;
    rp_shows.fetch_add(1);
    rp_wake_host();
  } else if (self.wasHidden) {
    self.wasHidden = NO;
    w.alphaValue = 1.0;
    w.ignoresMouseEvents = NO;
    rp_shows.fetch_add(1);
    rp_wake_host();
  }
  if ([self.forwardDelegate respondsToSelector:@selector(windowDidBecomeKey:)]) {
    [self.forwardDelegate windowDidBecomeKey:notification];
  }
}
@end

static RPResidentDelegate *rp_res_delegate = nil;

extern "C" {

int32_t rp_is_mac(void) { return 1; }

int32_t rp_square_window(void) { return 0; }

int32_t rp_launch(moonbit_bytes_t path) {
  @autoreleasepool {
    std::string s = rp_str(path);
    if (s.empty()) return 0;
    if (rp_env_set("REPLAY_NO_LAUNCH")) return 1;
    NSString *ns = [NSString stringWithUTF8String:s.c_str()];
    if (!ns || ns.length == 0) return 0;
    if ([ns hasPrefix:@"http://"] || [ns hasPrefix:@"https://"] || [ns hasPrefix:@"mailto:"] ||
        ([ns rangeOfString:@"://"].location != NSNotFound && ![ns hasPrefix:@"/"])) {
      NSURL *u = [NSURL URLWithString:ns];
      if (!u) return 0;
      return [[NSWorkspace sharedWorkspace] openURL:u] ? 1 : 0;
    }
    if (![[NSFileManager defaultManager] fileExistsAtPath:ns]) return 0;
    NSURL *u = [NSURL fileURLWithPath:ns];
    return u && [[NSWorkspace sharedWorkspace] openURL:u] ? 1 : 0;
  }
}

// Returns 0 on success, non-zero error code on failure (matching replay_win.c:65 SHFileOperationW).
int32_t rp_recycle(moonbit_bytes_t path) {
  @autoreleasepool {
    std::string s = rp_str(path);
    if (s.empty()) return 2;
    NSString *ns = [NSString stringWithUTF8String:s.c_str()];
    if (!ns) return 2;
    NSError *err = nil;
    BOOL ok = [[NSFileManager defaultManager] trashItemAtURL:[NSURL fileURLWithPath:ns]
                                            resultingItemURL:nil
                                                       error:&err];
    if (ok) return 0;
    int32_t code = err ? (int32_t)err.code : 1;
    return code != 0 ? code : 1;
  }
}

int32_t rp_take_request(moonbit_bytes_t path) {
  std::string s = rp_str(path);
  if (s.empty()) return 0;
  return unlink(s.c_str()) == 0 ? 1 : 0;
}

moonbit_bytes_t rp_list(moonbit_bytes_t dir) {
  static const char *const exts[] = {".mp4"};
  return rp_list_exts(dir, exts, 1);
}

moonbit_bytes_t rp_list_clips(moonbit_bytes_t dir) {
  static const char *const exts[] = {".mp4", ".gif"};
  return rp_list_exts(dir, exts, 2);
}

double rp_size(moonbit_bytes_t path) {
  std::string s = rp_str(path);
  if (s.empty()) return -1.0;
  struct stat st;
  if (stat(s.c_str(), &st) != 0 || S_ISDIR(st.st_mode)) return -1.0;
  return (double)st.st_size;
}

double rp_modified(moonbit_bytes_t path) {
  std::string s = rp_str(path);
  if (s.empty()) return -1.0;
  struct stat st;
  if (stat(s.c_str(), &st) != 0 || S_ISDIR(st.st_mode)) return -1.0;
  return (double)st.st_mtimespec.tv_sec * 1000.0 + (double)st.st_mtimespec.tv_nsec / 1e6;
}

moonbit_bytes_t rp_read(moonbit_bytes_t path, double offset, int32_t length) {
  if (length <= 0) return moonbit_make_bytes(0, 0);
  std::string s = rp_str(path);
  if (s.empty()) return moonbit_make_bytes(0, 0);
  int fd = open(s.c_str(), O_RDONLY);
  if (fd < 0) return moonbit_make_bytes(0, 0);
  struct stat st;
  if (fstat(fd, &st) != 0 || S_ISDIR(st.st_mode)) {
    close(fd);
    return moonbit_make_bytes(0, 0);
  }
  int64_t off = (int64_t)offset;
  if (off < 0) off = 0;
  int64_t rem = (int64_t)st.st_size - off;
  if (rem <= 0) {
    close(fd);
    return moonbit_make_bytes(0, 0);
  }
  if ((int64_t)length > rem) length = (int32_t)rem;
  moonbit_bytes_t b = moonbit_make_bytes(length, 0);
  int32_t total = 0;
  while (total < length) {
    ssize_t got = pread(fd, b + total, (size_t)(length - total), (off_t)(off + total));
    if (got < 0) {
      if (errno == EINTR) continue;
      break;
    }
    if (got == 0) break;
    total += (int32_t)got;
  }
  close(fd);
  if (total == length) return b;
  return rp_bytes_from(b, (size_t)total);
}

int32_t rp_write(moonbit_bytes_t path, moonbit_bytes_t data) {
  std::string s = rp_str(path);
  if (s.empty()) return 0;
  int32_t len = data ? Moonbit_array_length(data) : 0;
  return rp_write_file_raw(s.c_str(), data, len > 0 ? (size_t)len : 0) ? 1 : 0;
}

int32_t rp_mkdirs(moonbit_bytes_t path) {
  return rp_mkdirs_str(rp_str(path)) ? 1 : 0;
}

int32_t rp_append(moonbit_bytes_t path, moonbit_bytes_t data) {
  std::string s = rp_str(path);
  if (s.empty()) return 0;
  int fd = open(s.c_str(), O_WRONLY | O_CREAT | O_APPEND, 0644);
  if (fd < 0) return 0;
  int32_t len = data ? Moonbit_array_length(data) : 0;
  const uint8_t *p = (const uint8_t *)data;
  size_t off = 0, want = len > 0 ? (size_t)len : 0;
  bool ok = true;
  while (off < want) {
    ssize_t put = write(fd, p + off, want - off);
    if (put < 0) {
      if (errno == EINTR) continue;
      ok = false;
      break;
    }
    off += (size_t)put;
  }
  close(fd);
  return ok ? 1 : 0;
}

// Move `from` to `to` without replacing an existing target (matching MoveFileExW without MOVEFILE_REPLACE_EXISTING).
int32_t rp_rename(moonbit_bytes_t from, moonbit_bytes_t to) {
  std::string a = rp_str(from), b = rp_str(to);
  if (a.empty() || b.empty()) return 0;
  if (renamex_np(a.c_str(), b.c_str(), RENAME_EXCL) == 0) return 1;
  if (errno == ENOTSUP || errno == EINVAL) {
    struct stat st;
    if (lstat(b.c_str(), &st) == 0) return 0;
    return rename(a.c_str(), b.c_str()) == 0 ? 1 : 0;
  }
  return 0;
}

void rp_delete(moonbit_bytes_t path) {
  std::string s = rp_str(path);
  if (!s.empty()) unlink(s.c_str());
}

moonbit_bytes_t rp_exe_dir(void) {
  std::string exe = rp_self_exe_path();
  size_t slash = exe.find_last_of('/');
  if (slash != std::string::npos) exe.resize(slash);
  return rp_bytes_str(exe);
}

double rp_dir_size(moonbit_bytes_t dir) {
  std::string dir_s = rp_str(dir);
  if (dir_s.empty()) return -1.0;
  DIR *d = opendir(dir_s.c_str());
  if (!d) return -1.0;
  double total = 0.0;
  struct dirent *ent = nullptr;
  while ((ent = readdir(d)) != nullptr) {
    const char *name = ent->d_name;
    if (name[0] == '.' && (name[1] == '\0' || (name[1] == '.' && name[2] == '\0'))) continue;
    std::string full = dir_s + "/" + name;
    struct stat st;
    if (stat(full.c_str(), &st) == 0 && !S_ISDIR(st.st_mode)) {
      total += (double)st.st_size;
    }
  }
  closedir(d);
  return total;
}

int32_t rp_can_write(moonbit_bytes_t dir) {
  std::string dir_s = rp_str(dir);
  if (!rp_mkdirs_str(dir_s)) return 0;
  std::string probe = dir_s + "/.replay-write-probe";
  int fd = open(probe.c_str(), O_WRONLY | O_CREAT | O_TRUNC, 0600);
  if (fd < 0) return 0;
  close(fd);
  unlink(probe.c_str());
  return 1;
}

double rp_disk_free(moonbit_bytes_t dir) {
  std::string p = rp_str(dir);
  while (!p.empty()) {
    struct statvfs vfs;
    if (statvfs(p.c_str(), &vfs) == 0) {
      return (double)vfs.f_bavail * (double)vfs.f_frsize;
    }
    size_t slash = p.find_last_of('/');
    if (slash == std::string::npos) break;
    if (slash == 0) {
      struct statvfs root_vfs;
      if (statvfs("/", &root_vfs) == 0) return (double)root_vfs.f_bavail * (double)root_vfs.f_frsize;
      break;
    }
    p.resize(slash);
  }
  return -1.0;
}

int32_t rp_local_offset(void) {
  @autoreleasepool {
    return (int32_t)([[NSTimeZone localTimeZone] secondsFromGMTForDate:[NSDate date]] / 60);
  }
}

double rp_now(void) {
  struct timespec ts;
  clock_gettime(CLOCK_REALTIME, &ts);
  double real = (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1e6;
  static int asked = 0;
  static double shift = 0.0;
  if (!asked) {
    asked = 1;
    const char *v = getenv("REPLAY_NOW");
    if (v && v[0]) shift = atof(v) - real;
  }
  return real + shift;
}

void rp_reveal(moonbit_bytes_t path) {
  @autoreleasepool {
    if (rp_env_set("REPLAY_NO_LAUNCH") || getenv("MBUI_SCRIPT") || getenv("MBUI_DRIVE") || getenv("MBUI_DRIVE_B64")) return;
    std::string s = rp_str(path);
    if (s.empty()) return;
    NSString *ns = [NSString stringWithUTF8String:s.c_str()];
    if (!ns || ![[NSFileManager defaultManager] fileExistsAtPath:ns]) return;
    [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[[NSURL fileURLWithPath:ns]]];
  }
}

int32_t rp_copy_text(moonbit_bytes_t text) {
  std::string s = rp_str(text);
  const char *test_out = getenv("REPLAY_TEST_COPY_TEXT");
  if (test_out && test_out[0]) {
    return rp_write_file_raw(test_out, s.data(), s.size()) ? 1 : 0;
  }
  if (rp_env_set("REPLAY_NO_CLIPBOARD")) return 0;
  @autoreleasepool {
    NSString *ns = [NSString stringWithUTF8String:s.c_str()];
    if (!ns) return 0;
    __block BOOL ok = NO;
    void (^work)(void) = ^{
      NSPasteboard *pb = [NSPasteboard generalPasteboard];
      [pb clearContents];
      ok = [pb setString:ns forType:NSPasteboardTypeString];
    };
    if ([NSThread isMainThread]) work();
    else dispatch_sync(dispatch_get_main_queue(), work);
    return ok ? 1 : 0;
  }
}

int32_t rp_copy_file(moonbit_bytes_t path) {
  std::string s = rp_str(path);
  if (s.empty()) return 0;
  const char *test_out = getenv("REPLAY_TEST_COPY_FILE");
  if (test_out && test_out[0]) {
    return rp_write_file_raw(test_out, s.data(), s.size()) ? 1 : 0;
  }
  if (rp_env_set("REPLAY_NO_CLIPBOARD")) return 0;
  @autoreleasepool {
    NSString *ns = [NSString stringWithUTF8String:s.c_str()];
    if (!ns) return 0;
    NSURL *u = [NSURL fileURLWithPath:ns];
    if (!u) return 0;
    __block BOOL ok = NO;
    void (^work)(void) = ^{
      NSPasteboard *pb = [NSPasteboard generalPasteboard];
      [pb clearContents];
      ok = [pb writeObjects:@[u]];
    };
    if ([NSThread isMainThread]) work();
    else dispatch_sync(dispatch_get_main_queue(), work);
    return ok ? 1 : 0;
  }
}

moonbit_bytes_t rp_pick_folder(void) {
  const char *canned = getenv("REPLAY_TEST_PICK_FOLDER");
  if (canned) return rp_bytes_str(std::string(canned));
  if (rp_env_set("REPLAY_NO_CLIPBOARD") || getenv("MBUI_SCRIPT")) return moonbit_make_bytes(0, 0);
  @autoreleasepool {
    if (!NSApp) return moonbit_make_bytes(0, 0);
    __block std::string chosen;
    void (^work)(void) = ^{
      NSOpenPanel *panel = [NSOpenPanel openPanel];
      panel.canChooseDirectories = YES;
      panel.canChooseFiles = NO;
      panel.canCreateDirectories = YES;
      panel.allowsMultipleSelection = NO;
      if ([panel runModal] == NSModalResponseOK && panel.URL.path) {
        chosen = panel.URL.path.UTF8String ?: "";
      }
    };
    if ([NSThread isMainThread]) work();
    else dispatch_sync(dispatch_get_main_queue(), work);
    return rp_bytes_str(chosen);
  }
}

int32_t rp_launch_recorder(void) {
  const char *no_rec = getenv("REPLAY_NO_RECORDER");
  if (no_rec && no_rec[0]) return 0;
  @autoreleasepool {
    std::string exe = rp_self_exe_path();
    size_t slash = exe.find_last_of('/');
    if (slash == std::string::npos) return 0;
    std::string dir = exe.substr(0, slash);
    NSFileManager *fm = [NSFileManager defaultManager];

    // Check sibling binary ScreenReplay in Contents/MacOS/ or build output dir
    NSString *binPath = [NSString stringWithUTF8String:(dir + "/ScreenReplay").c_str()];
    if (binPath && [fm isExecutableFileAtPath:binPath]) {
      NSTask *task = [[NSTask alloc] init];
      task.executableURL = [NSURL fileURLWithPath:binPath];
      task.arguments = @[@"--background"];
      NSError *err = nil;
      return [task launchAndReturnError:&err] ? 1 : 0;
    }

    // Check app bundles relative to helper/viewer bundle locations
    NSArray<NSString *> *bundleCandidates = @[
      [NSString stringWithUTF8String:(dir + "/ScreenReplay.app").c_str()],
      [NSString stringWithUTF8String:(dir + "/../../../ScreenReplay.app").c_str()],
      [NSString stringWithUTF8String:(dir + "/../../../../ScreenReplay.app").c_str()],
    ];
    for (NSString *cand in bundleCandidates) {
      NSString *stdPath = cand.stringByStandardizingPath;
      BOOL isDir = NO;
      if (stdPath && [fm fileExistsAtPath:stdPath isDirectory:&isDir] && isDir) {
        NSTask *task = [[NSTask alloc] init];
        task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/open"];
        task.arguments = @[@"-g", @"-a", stdPath, @"--args", @"--background"];
        NSError *err = nil;
        return [task launchAndReturnError:&err] ? 1 : 0;
      }
    }
    return 0;
  }
}

moonbit_bytes_t rp_windows_version(void) {
  char ver[64] = {0};
  char build[64] = {0};
  size_t ver_len = sizeof(ver) - 1;
  size_t build_len = sizeof(build) - 1;
  bool got_ver = sysctlbyname("kern.osproductversion", ver, &ver_len, nullptr, 0) == 0 && ver[0] != '\0';
  bool got_build = sysctlbyname("kern.osversion", build, &build_len, nullptr, 0) == 0 && build[0] != '\0';
  if (got_ver && got_build) {
    char combined[160];
    snprintf(combined, sizeof(combined), "macOS %s (Build %s)", ver, build);
    return rp_bytes_str(combined);
  }
  @autoreleasepool {
    NSString *os = NSProcessInfo.processInfo.operatingSystemVersionString ?: @"?";
    return rp_bytes_str(os.UTF8String ?: "?");
  }
}

moonbit_bytes_t rp_gpu(void) {
  @autoreleasepool {
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    if (dev && dev.name.length > 0) {
      return rp_bytes_str(dev.name.UTF8String ?: "?");
    }
    return rp_bytes_str("?");
  }
}

int32_t rp_packaged(void) { return 0; }

int32_t rp_install_kind(void) {
  const char *test = getenv("REPLAY_TEST_UPDATE");
  if (test && test[0]) return 1;
  std::string exe = rp_self_exe_path();
  if (exe.rfind("/Applications/ScreenReplay.app/", 0) == 0) return 1;
  const char *home = getenv("HOME");
  if (home && home[0]) {
    std::string user_apps = std::string(home) + "/Applications/ScreenReplay.app/";
    if (exe.rfind(user_apps, 0) == 0) return 1;
  }
  return 0;
}

int32_t rp_system_light(void) {
  @autoreleasepool {
    if (NSApp) {
      NSAppearanceName match = [NSApp.effectiveAppearance bestMatchFromAppearancesWithNames:@[
        NSAppearanceNameAqua, NSAppearanceNameDarkAqua
      ]];
      if (match) return [match isEqualToString:NSAppearanceNameAqua] ? 1 : 0;
    }
    NSString *style = [[NSUserDefaults standardUserDefaults] stringForKey:@"AppleInterfaceStyle"];
    return (style && [style caseInsensitiveCompare:@"Dark"] == NSOrderedSame) ? 0 : 1;
  }
}

int32_t rp_system_chinese(void) {
  @autoreleasepool {
    NSString *first = [NSLocale preferredLanguages].firstObject;
    return (first && [first hasPrefix:@"zh"]) ? 1 : 0;
  }
}

int32_t rp_animations_off(void) {
  @autoreleasepool {
    return [[NSWorkspace sharedWorkspace] accessibilityDisplayShouldReduceMotion] ? 1 : 0;
  }
}

int32_t rp_fullscreen(int32_t on) {
  @autoreleasepool {
    NSWindow *w = rp_main_win();
    bool full = w && ((w.styleMask & NSWindowStyleMaskFullScreen) != 0);
    if (on < 0) return full ? 1 : 0;
    if (!w) return 0;
    if ((on != 0) != full) {
      [w toggleFullScreen:nil];
      full = !full;
    }
    return full ? 1 : 0;
  }
}

void rp_window_dark(int32_t on) {
  @autoreleasepool {
    NSWindow *w = rp_main_win();
    if (!w) return;
    w.appearance = [NSAppearance appearanceNamed:on ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];
  }
}

void rp_hide_from_capture(int32_t on) {
  @autoreleasepool {
    if (!NSApp) return;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    NSWindowSharingType want = on ? NSWindowSharingNone : NSWindowSharingReadOnly;
#pragma clang diagnostic pop
    for (NSWindow *w in NSApp.windows) {
      if (w.sharingType != want) w.sharingType = want;
    }
  }
}

void rp_hide_cursor(void) {
  @autoreleasepool {
    if (!NSApp) return;
    [NSCursor setHiddenUntilMouseMoves:YES];
  }
}

void rp_system_menu(double x, double y) {
  (void)x;
  (void)y;
}

int32_t rp_window_state(void) {
  @autoreleasepool {
    NSWindow *w = rp_main_win();
    if (!w) return 0;
    int32_t st = 0;
    if (NSApp.isActive && w.isKeyWindow) st |= 1;
    if (w.isMiniaturized) st |= 2;
    if (w.isVisible && !rp_priming.load() && w.alphaValue > 0.01) st |= 4;
    return st;
  }
}

int32_t rp_window_shown(void) {
  @autoreleasepool {
    NSWindow *w = rp_main_win();
    return (w && w.isVisible && !rp_priming.load() && w.alphaValue > 0.01) ? 1 : 0;
  }
}

void rp_set_bg_rgb(int32_t rgb) {
  rp_bg_rgb_val = rgb;
  @autoreleasepool {
    NSWindow *w = rp_main_win();
    if (w) rp_apply_bg_color(w);
  }
}

void rp_start_hidden(void) {
  rp_install_start_hidden_hook(1);
}

void rp_start_resident_hidden(void) {
  rp_install_start_hidden_hook(2);
}

void rp_resident_primed(void) {
  @autoreleasepool {
    if (!rp_priming.exchange(0)) return;
    NSWindow *w = rp_main_win();
    if (!w) return;
    if (rp_show_asked.load()) {
      w.alphaValue = 1.0;
      w.ignoresMouseEvents = NO;
      [w makeKeyAndOrderFront:nil];
      rp_shows.fetch_add(1);
      rp_wake_host();
      return;
    }
    [w orderOut:nil];
    w.alphaValue = 1.0;
    w.ignoresMouseEvents = NO;
    if (rp_res_delegate) rp_res_delegate.wasHidden = YES;
  }
}

void rp_resident_hidden(void) {}

int32_t rp_stay_resident(void) {
  @autoreleasepool {
    NSWindow *w = rp_main_win();
    if (!w) return 0;
    if (rp_res_delegate) return 1;
    rp_res_delegate = [[RPResidentDelegate alloc] init];
    rp_res_delegate.forwardDelegate = w.delegate;
    rp_res_delegate.wasHidden = !w.isVisible || rp_priming.load() != 0;
    w.delegate = rp_res_delegate;

    // Listen for distributed notification from ScreenReplay menu bar host to reveal resident window instantaneously.
    [[NSDistributedNotificationCenter defaultCenter]
        addObserverForName:@"dev.pengx17.screenreplay.openViewer"
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(__unused NSNotification *note) {
                  NSWindow *win = rp_main_win();
                  if (!win) return;
                  rp_priming.store(0);
                  win.alphaValue = 1.0;
                  win.ignoresMouseEvents = NO;
                  if (win.isMiniaturized) [win deminiaturize:nil];
                  BOOL wasOut = !win.isVisible || (rp_res_delegate && rp_res_delegate.wasHidden);
                  if (rp_res_delegate) rp_res_delegate.wasHidden = NO;
                  [win makeKeyAndOrderFront:nil];
                  [NSApp activate];
                  if (wasOut) {
                    rp_shows.fetch_add(1);
                    rp_wake_host();
                  }
                }];
    return 1;
  }
}

int32_t rp_alt_arrows(void) { return 1; }

int32_t rp_window_turns(void) {
  int32_t h = rp_hides.load() & 0x7FFF;
  int32_t s = rp_shows.load() & 0xFFFF;
  return (h << 16) | s;
}

int32_t rp_tray_window(double w_pt, double h_pt) {
  @autoreleasepool {
    NSWindow *w = rp_main_win();
    if (!w) return 0;
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    w.styleMask = NSWindowStyleMaskBorderless | NSWindowStyleMaskFullSizeContentView;
    w.level = NSPopUpMenuWindowLevel;
    w.hasShadow = YES;
    w.hidesOnDeactivate = YES;
    [w setContentSize:NSMakeSize(w_pt, h_pt)];
    return 1;
  }
}

void rp_tray_primed(void) {
  @autoreleasepool {
    NSWindow *w = rp_main_win();
    if (!w) return;
    if (!NSApp.isActive) [w orderOut:nil];
    w.alphaValue = 1.0;
    w.ignoresMouseEvents = NO;
  }
}

void rp_tray_hide(void) {
  @autoreleasepool {
    NSWindow *w = rp_main_win();
    if (w) [w orderOut:nil];
  }
}

int32_t rp_tray_tell(int32_t command) {
  @autoreleasepool {
    const char *root_env = getenv("REPLAY_ROOT");
    std::string root;
    if (root_env && root_env[0]) {
      root = root_env;
    } else {
      NSString *appSup = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
      if (appSup) root = std::string(appSup.UTF8String) + "/ScreenReplay";
    }
    bool wrote = false;
    if (!root.empty()) {
      rp_mkdirs_str(root);
      char buf[32];
      int n = snprintf(buf, sizeof(buf), "%d\n", (int)command);
      wrote = rp_write_file_raw((root + "/tray.command").c_str(), buf, (size_t)n);
    }
    [[NSDistributedNotificationCenter defaultCenter]
        postNotificationName:@"dev.pengx17.screenreplay.trayCommand"
                      object:nil
                    userInfo:@{@"command" : @(command)}
          deliverImmediately:YES];
    return wrote ? 1 : 0;
  }
}

int32_t rp_note_window(double w_pt, double h_pt, int32_t cloaked) {
  @autoreleasepool {
    NSWindow *w = rp_main_win();
    if (!w) return 0;
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    w.styleMask = NSWindowStyleMaskBorderless | NSWindowStyleMaskFullSizeContentView;
    w.level = NSStatusWindowLevel;
    w.hasShadow = YES;
    w.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;
    if (cloaked || rp_env_set("REPLAY_NOTE_UNSEEN")) {
      w.alphaValue = 0.0;
      w.ignoresMouseEvents = YES;
    }
    NSScreen *scr = w.screen ?: NSScreen.mainScreen;
    NSRect vis = scr ? scr.visibleFrame : NSMakeRect(0, 0, 1440, 900);
    CGFloat margin = 12.0;
    NSRect frame = NSMakeRect(NSMaxX(vis) - w_pt - margin, NSMinY(vis) + margin, w_pt, h_pt);
    [w setFrame:frame display:YES];
    [w orderFrontRegardless];
    return 1;
  }
}

void rp_note_hide(void) {
  @autoreleasepool {
    NSWindow *w = rp_main_win();
    if (w) [w orderOut:nil];
  }
}

void rp_note_reveal(void) {
  @autoreleasepool {
    if (rp_env_set("REPLAY_NOTE_UNSEEN")) return;
    NSWindow *w = rp_main_win();
    if (!w) return;
    w.alphaValue = 1.0;
    w.ignoresMouseEvents = NO;
  }
}

int32_t rp_tray_req_seq_get(void) { return 0; }
int32_t rp_tray_req_x_get(void) { return 0; }
int32_t rp_tray_req_y_get(void) { return 0; }
int32_t rp_note_req_seq_get(void) { return 0; }
void rp_prepare_popup(int32_t kind) { (void)kind; }
int32_t rp_style_tray_win(int32_t wid, double w_pt, double h_pt, int32_t px, int32_t py) {
  (void)wid; (void)w_pt; (void)h_pt; (void)px; (void)py;
  return 0;
}
int32_t rp_style_note_win(int32_t wid, double w_pt, double h_pt) {
  (void)wid; (void)w_pt; (void)h_pt;
  return 0;
}

}  // extern "C"
