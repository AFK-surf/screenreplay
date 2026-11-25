using Windows.ApplicationModel;
using Windows.ApplicationModel.Activation;

namespace Replay.Recorder;

internal static class Packaged
{
    public const string StartupTaskId = "ScreenReplayAtSignIn";

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
