using Windows.ApplicationModel;
using Windows.ApplicationModel.Activation;

namespace Replay.Recorder;

/// <summary>What differs when ScreenReplay is installed as an MSIX package (from the Microsoft Store): starting with
/// Windows by the package's startup task (packaging/AppxManifest.xml, its TaskId) instead of a Run key.</summary>
internal static class Packaged
{
    public const string StartupTaskId = "ScreenReplayAtSignIn";

    /// <summary>Whether this process runs from a package (it has a package identity).</summary>
    public static readonly bool Is = HasIdentity();

    private static bool HasIdentity()
    {
        try
        {
            return Package.Current?.Id != null;
        }
        catch
        {
            return false;
        }
    }

    [System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
    private static extern int RegisterApplicationRestart(string? commandLine, int flags);

    /// <summary>Started again, in the background, when the Store updates the package: an update stops the running
    /// app, and without this background recording would stay off till the next sign-in. Not after a crash, a hang
    /// or a restart of Windows (the startup task's).</summary>
    public static void RestartAfterUpdate(Action<string> log)
    {
        if (!Is)
        {
            return;
        }

        // RESTART_NO_CRASH | RESTART_NO_HANG | RESTART_NO_REBOOT: an update alone
        var hr = RegisterApplicationRestart("--background", 1 | 2 | 8);
        if (hr != 0)
        {
            log($"restart after update not registered: 0x{hr:x8}");
        }
    }

    /// <summary>Whether Windows started it at sign-in by the startup task (as the Run key's --background says
    /// unpackaged): it then starts hidden, the replay window not opened.</summary>
    public static bool StartedAtSignIn()
    {
        if (!Is)
        {
            return false;
        }

        try
        {
            return AppInstance.GetActivatedEventArgs()?.Kind == ActivationKind.StartupTask;
        }
        catch
        {
            return false;
        }
    }

    /// <summary>The startup task turned on or off as the settings say. Off by the person in Windows' own settings
    /// (DisabledByUser) it is left so: only they can turn it on again there.</summary>
    public static async Task SetStartupAsync(bool on, Action<string> log)
    {
        try
        {
            var task = await StartupTask.GetAsync(StartupTaskId);
            if (on)
            {
                if (task.State == StartupTaskState.Disabled)
                {
                    var now = await task.RequestEnableAsync();
                    log("startup task: " + now);
                }
                else if (task.State != StartupTaskState.Enabled)
                {
                    log("startup task left " + task.State);
                }
            }
            else if (task.State == StartupTaskState.Enabled)
            {
                task.Disable();
                log("startup task: disabled");
            }
        }
        catch (Exception ex)
        {
            log("startup task failed: " + ex.Message);
        }
    }
}
