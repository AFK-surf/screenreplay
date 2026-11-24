using System.Diagnostics;
using System.Runtime.InteropServices;

namespace Replay.Recorder;

/// <summary>
/// What the recorder tells of what was just pressed (a clip saved, a moment marked, a save that failed) as a card of
/// the app's own by the tray (the user, 2026-11-18: 「托盘save后感觉需要有个通知啥的，现在啥都没有」, then
/// 「做自己的保存卡片」): the replay window's program run with REPLAY_NOTE (app/note_card.mbt), at the foot of the screen,
/// never taking the focus, gone by itself. One is kept warm (REPLAY_NOTE=warm: started, drawn once unseen, hidden) so
/// it shows the moment it is asked: started only then it took a second to come up, by when a clip was saved already
/// and the line shown while saving was never seen (the user: 「我没看到这个啊？」). What it is to show is written to
/// note.json beside the buffer ({"id","mode","path","text","warn"}) and its window told (WM_APP + 0x53); the clip, once
/// saved, written to the same ask. One shown at a time: a new one ends the one before. Shown whatever Windows'
/// do-not-disturb says, as it answers the user's own press. Where none can be started, false: the icon's balloon instead.
/// </summary>
internal sealed class NoteCard(string exe, string root, Func<(int Pid, IntPtr Window)?> findReplay, Action<string> log) : IDisposable
{
    [DllImport("user32.dll")]
    private static extern bool PostMessageW(IntPtr hwnd, uint msg, IntPtr wp, IntPtr lp);

    private readonly object gate = new();
    private Process? shown;
    private bool shownInProcess;
    private int id = (int)(DateTimeOffset.UtcNow.ToUnixTimeSeconds() % 1_000_000);
    private (string Mode, string Path, string Text, bool Warn) asked;

    private string NoteFile => Path.Combine(root, "note.json");

    /// <summary>Let go of (the recorder quits): none started again after.</summary>
    private bool disposed;

    /// <summary>Whether `pid` is a fallback standalone card's (not the resident replay window's).</summary>
    public bool Owns(int pid)
    {
        lock (gate)
        {
            try
            {
                return shown is { HasExited: false } && shown.Id == pid;
            }
            catch (InvalidOperationException)
            {
                return false;
            }
        }
    }

    /// <summary>No-op: note cards are hosted in-process inside the single resident ScreenReplayViewer.exe.</summary>
    public void Warm() { }

    /// <summary>No-op: the resident viewer is renewed as a whole by RecorderApp.RenewReplayIfHidden.</summary>
    public void Renew() { }

    /// <summary>A clip being saved: the card shown at once, one quiet line (the user: 「saving过程我觉得应该降低打扰」);
    /// grown to the clip's card by Saved; a failure's line (Text) takes its place.</summary>
    public bool Saving() => Ask("saved", "", "", false);

    /// <summary>The clip saved at `path` told to the card Saving showed; one closed meanwhile by its close button left
    /// closed. False where none could be shown: the caller says it another way.</summary>
    public bool Saved(string path)
    {
        lock (gate)
        {
            if (shownInProcess && asked.Mode == "saved")
            {
                asked = ("saved", path, "", false);
                var wrote = Write();
                if (findReplay() is { } found && found.Window != IntPtr.Zero)
                {
                    PostMessageW(found.Window, 0x8000 + 0x53, IntPtr.Zero, IntPtr.Zero);
                }
                return wrote;
            }

            if (shown is { HasExited: true } && asked.Mode == "saved")
            {
                return true;
            }

            if (shown is not null && asked.Mode == "saved")
            {
                asked = ("saved", path, "", false);
                return Write();
            }
        }

        return Ask("saved", path, "", false);
    }

    /// <summary>One line, already in the user's language; `warning` with the amber mark.</summary>
    public bool Text(string text, bool warning) => Ask("text", "", text, warning);

    private bool Ask(string mode, string path, string text, bool warning)
    {
        lock (gate)
        {
            if (disposed)
            {
                return false;
            }

            Kill(shown);
            shown = null;
            shownInProcess = false;
            id++;
            asked = (mode, path, text, warning);
            Write();

            if (findReplay() is { } found && found.Window != IntPtr.Zero &&
                PostMessageW(found.Window, 0x8000 + 0x53, IntPtr.Zero, IntPtr.Zero))
            {
                shownInProcess = true;
                log($"note card: {mode} shown (in-process), pid {found.Pid}");
                return true;
            }

            shown = Start(mode, path, text, warning);
            log($"note card: {mode} shown (fallback), pid {shown?.Id}");
            return shown is not null;
        }
    }

    /// <summary>The ask as it is now into note.json, written whole then moved in.</summary>
    private bool Write()
    {
        try
        {
            var json = "{\"id\":" + id + ",\"mode\":" + Json(asked.Mode) + ",\"path\":" + Json(asked.Path) + ",\"text\":" +
                Json(asked.Text) + ",\"warn\":" + (asked.Warn ? "true" : "false") + "}";
            var part = NoteFile + ".part";
            File.WriteAllText(part, json);
            File.Move(part, NoteFile, overwrite: true);
            return true;
        }
        catch (Exception ex)
        {
            log("note card: not told: " + ex.Message);
            return false;
        }
    }

    // (written by hand, as the recorder writes its other files: the trimmed Store build has no reflection-based
    // serializer to call)
    private static string Json(string s) => RecorderApp.Json(s);

    private Process? Start(string mode, string path, string text, bool warning)
    {
        try
        {
            var info = new ProcessStartInfo(exe) { UseShellExecute = false, WorkingDirectory = Path.GetDirectoryName(exe)! };
            info.Environment["REPLAY_NOTE"] = mode;
            info.Environment["REPLAY_NOTE_PATH"] = path;
            info.Environment["REPLAY_NOTE_TEXT"] = text;
            info.Environment["REPLAY_NOTE_WARN"] = warning ? "1" : "0";
            info.Environment["REPLAY_ROOT"] = root;
            // (beside the replay window's run and the tray's panel, never handed to either)
            info.Environment["MBUI_WINDOW"] = "note";
            // (it plays no video, its clip's picture an image: mbui's video device and decoders' threads not made for
            // it, 12 MB of the GPU's memory, 15 MB and 9 threads of its own)
            info.Environment["MBUI_NO_VIDEO_GPU"] = "1";
            info.Environment.Remove("REPLAY_TRAY");
            info.Environment.Remove("REPLAY_RESIDENT");
            info.Environment.Remove("REPLAY_HIDDEN");
            var started = Process.Start(info);
            // (ended with the recorder however it ends: ChildJob)
            ChildJob.Hold(started);
            return started;
        }
        catch (Exception ex)
        {
            log("note card: not started: " + ex.Message);
            return null;
        }
    }

    private static void Kill(Process? p)
    {
        try
        {
            if (p is { HasExited: false })
            {
                p.Kill();
            }
        }
        catch (Exception)
        {
        }

        p?.Dispose();
    }

    public void Dispose()
    {
        lock (gate)
        {
            disposed = true;
            Kill(shown);
            shown = null;
            shownInProcess = false;
        }
    }
}
