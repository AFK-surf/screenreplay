namespace Replay.Recording;

internal enum StallAction
{
    None,
    Renew,
    Restart,
}

/// <summary>
/// Tracks whether the active screen capture has stopped delivering new frames despite input or foreground/desktop
/// activity, decides when to attempt a lightweight capture renewal, and escalates to a full recorder/GPU restart
/// when repeated renewals fail or stall again without producing live frames.
/// </summary>
internal sealed class StallWatcher
{
    public const long StallWindow = 20_000_000;      // 2 s after first poke with no new frame
    public const long RenewInterval = 300_000_000;   // at most once per 30 s
    public const long FailRetryDelay = 50_000_000;   // retry sooner (5 s) after a failed renewal before escalating

    private long lastFrames;
    private long lastFrameAt;
    private long lastRenew = long.MinValue / 2;
    private long pokedSince;
    private long stallRenewFrames;
    private int sourceFailures;
    private int stallStreak;
    private bool awaitingLiveFrame;

    public int SourceFailures => sourceFailures;
    public int StallStreak => stallStreak;
    public long LastFrameAt => lastFrameAt;
    public long PokedSince => pokedSince;

    public StallWatcher(long initialFrames, long nowHns)
    {
        lastFrames = initialFrames;
        lastFrameAt = nowHns;
    }

    /// <summary>Records the active capture's current frame count and latest input/foreground timestamps.</summary>
    public void Observe(long currentFrames, long nowHns, long pokedHns)
    {
        if (currentFrames != lastFrames)
        {
            lastFrames = currentFrames;
            lastFrameAt = nowHns;
            pokedSince = 0;
            sourceFailures = 0;
            if (awaitingLiveFrame && currentFrames > stallRenewFrames)
            {
                awaitingLiveFrame = false;
                stallStreak = 0;
            }
        }

        // Pin the FIRST activity timestamp after the last frame so continuous gaming input never starves the 2 s timer.
        if (pokedHns > lastFrameAt && pokedSince == 0)
        {
            pokedSince = Math.Min(nowHns, pokedHns);
        }
    }

    /// <summary>Checks whether a stall action (lightweight renew or full restart) is due now.</summary>
    public StallAction Evaluate(long nowHns, bool canStallRenew)
    {
        if (!canStallRenew || nowHns - lastRenew < RenewInterval)
        {
            return StallAction.None;
        }

        if (pokedSince <= 0 || nowHns - pokedSince < StallWindow)
        {
            return StallAction.None;
        }

        if (awaitingLiveFrame && stallStreak >= 2)
        {
            return StallAction.Restart;
        }

        return StallAction.Renew;
    }

    /// <summary>Records that a renewal attempt (for stall or screen-on) has started.</summary>
    public void NoteRenewStarted(long nowHns)
    {
        lastRenew = nowHns;
    }

    /// <summary>Records that a pending capture delivered its first frame and replaced the active capture.</summary>
    public void NoteSwapped(long newFrames, long nowHns, bool fromStall)
    {
        lastFrames = newFrames;
        lastFrameAt = nowHns;
        pokedSince = 0;
        sourceFailures = 0;
        if (fromStall)
        {
            stallRenewFrames = newFrames;
            awaitingLiveFrame = true;
            stallStreak++;
        }
        else
        {
            awaitingLiveFrame = false;
            stallStreak = 0;
        }
    }

    /// <summary>Records that a pending capture gave no first frame within GiveUp; returns true when escalation to a
    /// full recorder/GPU restart is warranted.</summary>
    public bool NoteSourceFailed(long nowHns, bool fromStall, bool screenActive)
    {
        if (!fromStall || !screenActive)
        {
            return false;
        }

        sourceFailures++;
        if (sourceFailures >= 2)
        {
            return true;
        }

        lastRenew = nowHns - RenewInterval + FailRetryDelay;
        return false;
    }
}
