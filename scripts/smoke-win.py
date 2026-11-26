import ctypes
import ctypes.wintypes as wt
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
try:
    ctypes.windll.shcore.SetProcessDpiAwareness(2)
except Exception:
    pass

ROOT = Path(__file__).resolve().parent.parent
EXE = ROOT / "out" / "ScreenReplayViewer.exe"

kernel32 = ctypes.windll.kernel32
user32 = ctypes.windll.user32
psapi = ctypes.windll.psapi

JOB_OBJECT_LIMIT_PROCESS_MEMORY = 0x00000100
JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000
JobObjectExtendedLimitInformation = 9

WM_KEYDOWN, WM_KEYUP, WM_CHAR = 0x0100, 0x0101, 0x0102
WM_MOUSEMOVE, WM_LBUTTONDOWN, WM_LBUTTONUP = 0x0200, 0x0201, 0x0202
WM_RBUTTONDOWN, WM_RBUTTONUP = 0x0204, 0x0205
MK_LBUTTON = 0x0001
VK_RETURN, VK_ESCAPE, VK_HOME = 0x0D, 0x1B, 0x24


class IO_COUNTERS(ctypes.Structure):
    _fields_ = [(n, ctypes.c_uint64) for n in (
        "ReadOperationCount", "WriteOperationCount", "OtherOperationCount",
        "ReadTransferCount", "WriteTransferCount", "OtherTransferCount",
    )]


class JOBOBJECT_BASIC_LIMIT_INFORMATION(ctypes.Structure):
    _fields_ = [
        ("PerProcessUserTimeLimit", ctypes.c_int64),
        ("PerJobUserTimeLimit", ctypes.c_int64),
        ("LimitFlags", wt.DWORD),
        ("MinimumWorkingSetSize", ctypes.c_size_t),
        ("MaximumWorkingSetSize", ctypes.c_size_t),
        ("ActiveProcessLimit", wt.DWORD),
        ("Affinity", ctypes.c_size_t),
        ("PriorityClass", wt.DWORD),
        ("SchedulingClass", wt.DWORD),
    ]


class JOBOBJECT_EXTENDED_LIMIT_INFORMATION(ctypes.Structure):
    _fields_ = [
        ("BasicLimitInformation", JOBOBJECT_BASIC_LIMIT_INFORMATION),
        ("IoInfo", IO_COUNTERS),
        ("ProcessMemoryLimit", ctypes.c_size_t),
        ("JobMemoryLimit", ctypes.c_size_t),
        ("PeakProcessMemoryUsed", ctypes.c_size_t),
        ("PeakJobMemoryUsed", ctypes.c_size_t),
    ]


class PROCESS_MEMORY_COUNTERS_EX(ctypes.Structure):
    _fields_ = [
        ("cb", wt.DWORD),
        ("PageFaultCount", wt.DWORD),
        ("PeakWorkingSetSize", ctypes.c_size_t),
        ("WorkingSetSize", ctypes.c_size_t),
        ("QuotaPeakPagedPoolUsage", ctypes.c_size_t),
        ("QuotaPagedPoolUsage", ctypes.c_size_t),
        ("QuotaPeakNonPagedPoolUsage", ctypes.c_size_t),
        ("QuotaNonPagedPoolUsage", ctypes.c_size_t),
        ("PagefileUsage", ctypes.c_size_t),
        ("PeakPagefileUsage", ctypes.c_size_t),
        ("PrivateUsage", ctypes.c_size_t),
    ]


class RECT(ctypes.Structure):
    _fields_ = [("left", wt.LONG), ("top", wt.LONG), ("right", wt.LONG), ("bottom", wt.LONG)]


def make_capped_job(limit_mb=1536):
    kernel32.CreateJobObjectW.restype = wt.HANDLE
    hjob = kernel32.CreateJobObjectW(None, None)
    assert hjob, "CreateJobObjectW failed"
    info = JOBOBJECT_EXTENDED_LIMIT_INFORMATION()
    info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_PROCESS_MEMORY | JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
    info.ProcessMemoryLimit = limit_mb * 1024 * 1024
    ok = kernel32.SetInformationJobObject(
        hjob, JobObjectExtendedLimitInformation, ctypes.byref(info), ctypes.sizeof(info)
    )
    assert ok, f"SetInformationJobObject failed: {ctypes.GetLastError()}"
    return hjob


def get_mem_mb(hproc):
    pmc = PROCESS_MEMORY_COUNTERS_EX()
    pmc.cb = ctypes.sizeof(pmc)
    if psapi.GetProcessMemoryInfo(hproc, ctypes.byref(pmc), pmc.cb):
        return pmc.PrivateUsage / (1024 * 1024), pmc.WorkingSetSize / (1024 * 1024)
    return -1.0, -1.0


def find_hwnd_for_pid(pid, timeout=15.0):
    t0 = time.time()
    while time.time() - t0 < timeout:
        found = []

        @ctypes.WINFUNCTYPE(wt.BOOL, wt.HWND, wt.LPARAM)
        def cb(hwnd, lp):
            if not user32.IsWindowVisible(hwnd):
                return True
            p = wt.DWORD(0)
            user32.GetWindowThreadProcessId(hwnd, ctypes.byref(p))
            if p.value == pid:
                r = RECT()
                user32.GetClientRect(hwnd, ctypes.byref(r))
                if r.right > 100 and r.bottom > 100:
                    found.append(hwnd)
            return True

        user32.EnumWindows(cb, 0)
        if found:
            return found[0]
        time.sleep(0.15)
    return 0


def lp_xy(x, y):
    return ((int(y) & 0xFFFF) << 16) | (int(x) & 0xFFFF)


def click_pt(hwnd, x, y, wait=0.45):
    user32.PostMessageW(hwnd, WM_MOUSEMOVE, 0, lp_xy(x, y))
    time.sleep(0.05)
    user32.PostMessageW(hwnd, WM_LBUTTONDOWN, MK_LBUTTON, lp_xy(x, y))
    time.sleep(0.05)
    user32.PostMessageW(hwnd, WM_LBUTTONUP, 0, lp_xy(x, y))
    time.sleep(wait)


def rclick_pt(hwnd, x, y, wait=0.45):
    user32.PostMessageW(hwnd, WM_MOUSEMOVE, 0, lp_xy(x, y))
    time.sleep(0.05)
    user32.PostMessageW(hwnd, WM_RBUTTONDOWN, 0x0002, lp_xy(x, y))
    time.sleep(0.05)
    user32.PostMessageW(hwnd, WM_RBUTTONUP, 0, lp_xy(x, y))
    time.sleep(wait)


def drag_pt(hwnd, x0, y0, x1, y1, steps=10, wait=0.45):
    user32.PostMessageW(hwnd, WM_MOUSEMOVE, 0, lp_xy(x0, y0))
    time.sleep(0.05)
    user32.PostMessageW(hwnd, WM_LBUTTONDOWN, MK_LBUTTON, lp_xy(x0, y0))
    time.sleep(0.05)
    for i in range(1, steps + 1):
        nx = int(x0 + (x1 - x0) * i / steps)
        ny = int(y0 + (y1 - y0) * i / steps)
        user32.PostMessageW(hwnd, WM_MOUSEMOVE, MK_LBUTTON, lp_xy(nx, ny))
        time.sleep(0.025)
    user32.PostMessageW(hwnd, WM_LBUTTONUP, 0, lp_xy(x1, y1))
    time.sleep(wait)


def send_key(hwnd, vk, ch=None, wait=0.45):
    user32.PostMessageW(hwnd, WM_KEYDOWN, vk, 0)
    if ch is not None:
        user32.PostMessageW(hwnd, WM_CHAR, ord(ch), 0)
    time.sleep(0.05)
    user32.PostMessageW(hwnd, WM_KEYUP, vk, 0)
    time.sleep(wait)


def ffprobe_json(p: Path):
    r = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration,size:stream=codec_type,codec_name,width,height", "-of", "json", str(p)],
        capture_output=True, text=True, check=True,
    )
    return json.loads(r.stdout)


def make_fixture(fix_dir: Path):
    buf = fix_dir / "Buffer"
    buf.mkdir(parents=True, exist_ok=True)
    now_ms = int(time.time() * 1000) - 120_000
    specs = [
        ("testsrc2=size=1280x720:rate=30", 440, 0),
        ("smptebars=size=1280x720:rate=30", 554, 15_000),
    ]
    for src, freq, off_ms in specs:
        t_ms = now_ms + off_ms
        lt = time.localtime(t_ms / 1000.0)
        stem = time.strftime("%Y%m%d-%H%M%S", lt) + f"-{t_ms % 1000:03d}"
        mp4 = buf / f"{stem}.mp4"
        subprocess.run(
            [
                "ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
                "-f", "lavfi", "-i", src,
                "-f", "lavfi", "-i", f"sine=frequency={freq}:sample_rate=48000",
                "-t", "15", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-g", "30",
                "-c:a", "aac", "-b:a", "96k", "-movflags", "+faststart", str(mp4),
            ],
            check=True,
        )
        (buf / f"{stem}.json").write_text(json.dumps({"durationMs": 15000, "fps": 30}), encoding="utf-8")
        (buf / f"{stem}.levels").write_bytes(bytes([120] * 150))
        (buf / f"{stem}.input").write_bytes(bytes([40] * 150))

    (fix_dir / "apps.jsonl").write_text(
        "\n".join([
            json.dumps({"at": now_ms, "app": "Code"}),
            json.dumps({"at": now_ms + 15000, "app": "Chrome"}),
        ]) + "\n",
        encoding="utf-8",
    )
    (fix_dir / "windows.jsonl").write_text(
        json.dumps({
            "at": now_ms, "sx": 0, "sy": 0, "sw": 1280, "sh": 720,
            "wins": [{"hwnd": 101, "owner": 0, "process": "Code", "title": "VS Code", "x": 40, "y": 40, "w": 620, "h": 620, "state": 0}],
        }) + "\n",
        encoding="utf-8",
    )
    (fix_dir / "settings.json").write_text(
        json.dumps({"enabled": False, "windowMinutes": 120, "maxGB": 10, "consent": {"version": 1, "at": now_ms}}),
        encoding="utf-8",
    )
    (fix_dir / "viewer.json").write_text(
        json.dumps({"appearance": "dark", "language": "zh", "hide_from_capture": False, "volume": 0.5}),
        encoding="utf-8",
    )
    (fix_dir / "state.json").write_text(
        json.dumps({"at": int(time.time() * 1000), "recording": False, "statusCode": "disabled", "width": 1280, "height": 720}),
        encoding="utf-8",
    )


def wait_for_file(directory: Path, pattern: str, timeout=25.0):
    t0 = time.time()
    while time.time() - t0 < timeout:
        hits = [p for p in directory.glob(pattern) if ".partial." not in p.name]
        if hits:
            return sorted(hits, key=lambda p: p.stat().st_mtime)[-1]
        time.sleep(0.35)
    return None


def main():
    if not EXE.is_file():
        print(f"Missing {EXE}; run scripts/build-viewer.ps1 first", file=sys.stderr)
        return 1
    for tool in ("ffmpeg", "ffprobe"):
        if not shutil.which(tool):
            print(f"Missing {tool} on PATH", file=sys.stderr)
            return 1

    with tempfile.TemporaryDirectory(prefix="sr_smoke_") as td:
        tmp = Path(td)
        fix_dir = tmp / "root"
        clips_dir = tmp / "clips"
        clips_dir.mkdir(parents=True)
        copied_png = tmp / "copied.png"
        log_path = tmp / "viewer.log"

        print("1. Generating synthetic 30s fixture...", flush=True)
        make_fixture(fix_dir)

        hjob = make_capped_job(limit_mb=1536)
        env = os.environ.copy()
        env["REPLAY_ROOT"] = str(fix_dir)
        env["REPLAY_OUT"] = str(clips_dir)
        env["REPLAY_NO_RECORDER"] = "1"
        env["REPLAY_TEST_COPY_FRAME"] = str(copied_png)

        lf = open(log_path, "wb")
        proc = subprocess.Popen([str(EXE)], env=env, stdout=lf, stderr=subprocess.STDOUT)
        kernel32.AssignProcessToJobObject(hjob, int(proc._handle))

        peak_priv = [0.0]
        stop_mon = threading.Event()

        def monitor():
            while not stop_mon.is_set() and proc.poll() is None:
                priv, _ = get_mem_mb(int(proc._handle))
                if priv > peak_priv[0]:
                    peak_priv[0] = priv
                if priv > 1000.0:
                    print(f"FAIL: memory watchdog hit ({priv:.1f} MB > 1000 MB)", file=sys.stderr, flush=True)
                    proc.kill()
                    break
                time.sleep(0.15)

        threading.Thread(target=monitor, daemon=True).start()
        try:
            hwnd = find_hwnd_for_pid(proc.pid)
            assert hwnd, "Viewer window did not appear"
            user32.SetWindowPos(hwnd, 1, 0, 0, 0, 0, 0x0013)
            time.sleep(2.0)

            r = RECT()
            user32.GetClientRect(hwnd, ctypes.byref(r))
            assert r.right < 3000, f"Unexpected fullscreen client rect {r.right}x{r.bottom}"
            s = r.right / 1440.0
            px = lambda lx, ly: (int(round(lx * s)), int(round(ly * s)))

            print("2. Verifying copy frame...", flush=True)
            rclick_pt(hwnd, *px(720, 400), wait=0.5)
            click_pt(hwnd, *px(780, 452), wait=0.9)
            assert copied_png.is_file() and copied_png.stat().st_size > 1000, "Copy frame PNG missing"

            print("3. Verifying lossless MP4 export...", flush=True)
            send_key(hwnd, VK_HOME, wait=0.45)
            send_key(hwnd, ord("C"), "c", wait=0.5)
            send_key(hwnd, ord("I"), "i", wait=0.35)
            click_pt(hwnd, *px(320, 818), wait=0.4)
            send_key(hwnd, ord("O"), "o", wait=0.35)
            click_pt(hwnd, *px(1360, 878), wait=0.6)
            # Exercise 按大小 tab (regression check for size_slider OOM) then return to 原样.
            click_pt(hwnd, *px(551, 488), wait=0.6)
            click_pt(hwnd, *px(496, 438), wait=0.5)
            send_key(hwnd, VK_RETURN, wait=0.5)
            lossless = wait_for_file(clips_dir, "*.mp4", timeout=20.0)
            assert lossless, "Lossless MP4 export produced no file"
            meta = ffprobe_json(lossless)
            vstreams = [st for st in meta["streams"] if st["codec_type"] == "video"]
            assert vstreams and vstreams[0]["width"] == 1280 and vstreams[0]["height"] == 720, f"Bad lossless video: {meta}"
            print(f"   Lossless MP4 OK: {lossless.name} ({lossless.stat().st_size} B)", flush=True)

            print("4. Verifying cropped H.264 re-encode export...", flush=True)
            send_key(hwnd, VK_ESCAPE, wait=0.35)
            send_key(hwnd, ord("C"), "c", wait=0.5)
            send_key(hwnd, VK_HOME, wait=0.35)
            send_key(hwnd, ord("I"), "i", wait=0.3)
            click_pt(hwnd, *px(200, 818), wait=0.35)
            send_key(hwnd, ord("O"), "o", wait=0.3)
            click_pt(hwnd, *px(192, 878), wait=0.45)
            drag_pt(hwnd, *px(420, 220), *px(920, 520), steps=10, wait=0.5)
            click_pt(hwnd, *px(1360, 878), wait=0.7)
            before_mp4s = {p.name for p in clips_dir.glob("*.mp4")}
            send_key(hwnd, VK_RETURN, wait=0.5)
            t0 = time.time()
            cropped = None
            while time.time() - t0 < 25.0:
                new_mp4s = [p for p in clips_dir.glob("*.mp4") if p.name not in before_mp4s and ".partial." not in p.name]
                if new_mp4s:
                    cropped = new_mp4s[0]
                    break
                time.sleep(0.35)
            assert cropped, "Cropped MP4 export produced no file"
            cmeta = ffprobe_json(cropped)
            cv = [st for st in cmeta["streams"] if st["codec_type"] == "video"]
            assert cv and 100 < cv[0]["width"] < 1280 and 100 < cv[0]["height"] < 720, f"Bad cropped video: {cmeta}"
            print(f"   Cropped MP4 OK: {cropped.name} ({cv[0]['width']}x{cv[0]['height']})", flush=True)

            print("5. Verifying GIF export...", flush=True)
            send_key(hwnd, VK_ESCAPE, wait=0.35)
            send_key(hwnd, ord("C"), "c", wait=0.5)
            send_key(hwnd, VK_HOME, wait=0.35)
            send_key(hwnd, ord("I"), "i", wait=0.3)
            click_pt(hwnd, *px(140, 818), wait=0.35)
            send_key(hwnd, ord("O"), "o", wait=0.3)
            click_pt(hwnd, *px(62, 878), wait=0.4)
            click_pt(hwnd, *px(1360, 878), wait=0.6)
            click_pt(hwnd, *px(607, 488), wait=0.55)
            click_pt(hwnd, *px(942, 438), wait=1.2)
            send_key(hwnd, VK_RETURN, wait=0.5)
            gif = wait_for_file(clips_dir, "*.gif", timeout=25.0)
            assert gif, "GIF export produced no file"
            gmeta = ffprobe_json(gif)
            gv = [st for st in gmeta["streams"] if st["codec_type"] == "video"]
            assert gv and gv[0]["codec_name"] == "gif" and gv[0]["width"] == 960, f"Bad GIF: {gmeta}"
            print(f"   GIF OK: {gif.name} ({gv[0]['width']}x{gv[0]['height']}, {gif.stat().st_size} B)", flush=True)

            assert proc.poll() is None, f"Viewer exited unexpectedly with {proc.poll()}"
        finally:
            stop_mon.set()
            try:
                proc.terminate()
                proc.wait(timeout=3)
            except Exception:
                try:
                    proc.kill()
                except Exception:
                    pass
            lf.close()
            kernel32.CloseHandle(hjob)

        log_text = log_path.read_text(errors="replace")
        assert "decoded on the GPU" in log_text, f"Expected GPU decode in log:\n{log_text}"
        print(f"PASS: ScreenReplay Windows GPU smoke (peak private memory: {peak_priv[0]:.1f} MB)", flush=True)
        return 0


if __name__ == "__main__":
    sys.exit(main())
