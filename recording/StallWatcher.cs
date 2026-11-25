namespace Replay.Recording;

internal enum StallAction
{
    None,
    Renew,
    Restart,
}

internal sealed class StallWatcher
{
    public const long StallWindow = 20_000_000;
    public const long RenewInterval = 300_000_000;
    public const long FailRetryDelay = 50_000_000;

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

    public void NoteRenewStarted(long nowHns)
    {
        lastRenew = nowHns;
    }

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
