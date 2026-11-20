using System.Buffers;
using System.Diagnostics;
using System.Net.Http;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Microsoft.Win32;

namespace Replay.Recorder;

/// <summary>
/// Updates for standalone (non-Store) installs: checks https://screenreplay.pages.dev/dl/latest.json,
/// verifies ECDSA P-256 signature over version + setup SHA-256, downloads ScreenReplay-Setup-&lt;ver&gt;.exe
/// in the background with streaming SHA-256 verification, and runs it silently (/UPDATE) when idle or
/// when requested from Settings › About. Store MSIX builds (Packaged.Is) are updated by Microsoft Store.
/// </summary>
internal sealed class Updater : IDisposable
{
    public const string AppVersion = "0.1.13";

    private const string UninstallKey = @"Software\Microsoft\Windows\CurrentVersion\Uninstall\{9C4A8E17-5D2B-4E91-A763-8F10B2C5D9E4}_is1";
    private const string TestUninstallKey = @"Software\Microsoft\Windows\CurrentVersion\Uninstall\ScreenReplay-Test_is1";

    // ECDSA P-256 public key corresponding to vault secret 「ScreenReplay 更新签名私钥（ECDSA P-256）」
    private static readonly byte[] KeyX =
    [
        0x56, 0x1b, 0xf9, 0xf1, 0xa6, 0x07, 0xe6, 0x9f, 0x9b, 0x2a, 0x7d, 0x0a, 0x9b, 0x0c, 0xc9, 0x86,
        0x7d, 0xfc, 0xa4, 0xec, 0xe2, 0x7c, 0x05, 0x43, 0x38, 0x7f, 0xc5, 0xc1, 0x3f, 0x78, 0xa7, 0xc8
    ];

    private static readonly byte[] KeyY =
    [
        0x77, 0xec, 0x9f, 0x82, 0x82, 0x1b, 0xe5, 0xbf, 0x7e, 0xa9, 0xdb, 0x27, 0x83, 0x50, 0x6c, 0xae,
        0xba, 0x23, 0xdb, 0xf4, 0x59, 0xb9, 0x6f, 0xf8, 0x3a, 0x5c, 0xac, 0xc0, 0x4d, 0x02, 0x0e, 0xbf
    ];

    private readonly string rootDir;
    private readonly Func<bool> isReplayVisible;
    private readonly Action<string> log;
    private readonly Action<string, string> notify;
    private readonly int installKind;
    private readonly HttpClient http;

    private string state = "unasked";
    private string foundVersion = "";
    private string foundSha = "";
    private bool byHand;
    private int percent = -1;
    private string errorCode = "";
    private long lastCheckedEpoch;
    private DateTimeOffset lastTried = DateTimeOffset.MinValue;
    private DateTimeOffset readyAt = DateTimeOffset.MinValue;
    private bool readyNoted;
    private bool askedByUser;
    private string downloadedFile = "";
    private int busy;
    private bool disposed;

    public Updater(string rootDir, Func<bool> isReplayVisible, Action<string> log, Action<string, string> notify, bool wasUpdated)
    {
        this.rootDir = rootDir;
        this.isReplayVisible = isReplayVisible;
        this.log = log;
        this.notify = notify;
        installKind = DetectInstallKind();
        http = new HttpClient { Timeout = TimeSpan.FromSeconds(45) };
        http.DefaultRequestHeaders.UserAgent.ParseAdd($"ScreenReplay/{AppVersion} (Windows)");

        ReadPersistedChecked();
        if (installKind != 2)
        {
            CleanupTempDir();
            WriteState();
            if (wasUpdated)
            {
                log($"update: now running {AppVersion}");
                if (!IsTestMode())
                {
                    notify(
                        L.T($"ScreenReplay 已更新到 {AppVersion}", $"ScreenReplay updated to {AppVersion}"),
                        L.T("后台录制已继续运行。", "Background recording has resumed."));
                }
            }
        }
    }

    public int InstallKind => installKind;

    private static bool IsTestMode()
        => !string.IsNullOrWhiteSpace(Environment.GetEnvironmentVariable("REPLAY_TEST_UPDATE"));

    private static bool IsUpdateNowTest()
        => IsTestMode() && !string.IsNullOrWhiteSpace(Environment.GetEnvironmentVariable("REPLAY_TEST_UPDATE_NOW"));

    private static string DownloadBase()
    {
        if (IsTestMode() && Environment.GetEnvironmentVariable("REPLAY_UPDATE_URL") is { Length: > 0 } custom)
        {
            return custom.EndsWith('/') ? custom : custom + "/";
        }
        return "https://screenreplay.pages.dev/dl/";
    }

    public static int DetectInstallKind()
    {
        if (Packaged.Is)
        {
            return 2;
        }
        try
        {
            var keyPath = IsTestMode() ? TestUninstallKey : UninstallKey;
            using var key = Registry.CurrentUser.OpenSubKey(keyPath);
            if (key?.GetValue("InstallLocation") is string loc && loc.Length > 0)
            {
                var a = loc.TrimEnd('\\', '/');
                var b = AppContext.BaseDirectory.TrimEnd('\\', '/');
                if (string.Equals(a, b, StringComparison.OrdinalIgnoreCase))
                {
                    return 1;
                }
            }
        }
        catch (Exception) { }
        return 0;
    }

    private string StateFilePath => Path.Combine(rootDir, "update.json");

    private string RequestFilePath => Path.Combine(rootDir, "update.request");

    private static string TempUpdateDir()
    {
        var dir = Path.Combine(Path.GetTempPath(), IsTestMode() ? "ScreenReplay-test-update" : "ScreenReplay-update");
        Directory.CreateDirectory(dir);
        return dir;
    }

    private void CleanupTempDir()
    {
        try
        {
            var dir = Path.Combine(Path.GetTempPath(), IsTestMode() ? "ScreenReplay-test-update" : "ScreenReplay-update");
            if (!Directory.Exists(dir)) return;
            foreach (var f in Directory.EnumerateFiles(dir))
            {
                try { File.Delete(f); } catch (Exception) { }
            }
        }
        catch (Exception) { }
    }

    private void ReadPersistedChecked()
    {
        try
        {
            if (!File.Exists(StateFilePath)) return;
            using var doc = JsonDocument.Parse(File.ReadAllBytes(StateFilePath));
            if (doc.RootElement.TryGetProperty("checked", out var c) && c.TryGetInt64(out var ts))
            {
                lastCheckedEpoch = ts;
            }
        }
        catch (Exception) { }
    }

    private void WriteState()
    {
        if (installKind == 2) return;
        try
        {
            var buf = new ArrayBufferWriter<byte>(256);
            using (var w = new Utf8JsonWriter(buf))
            {
                w.WriteStartObject();
                w.WriteNumber("installKind", installKind);
                w.WriteString("state", state);
                w.WriteString("version", foundVersion);
                w.WriteBoolean("byHand", byHand);
                w.WriteNumber("percent", percent);
                w.WriteString("error", errorCode);
                w.WriteNumber("checked", lastCheckedEpoch);
                w.WriteEndObject();
            }
            var tmp = StateFilePath + ".tmp";
            File.WriteAllBytes(tmp, buf.WrittenSpan.ToArray());
            File.Move(tmp, StateFilePath, overwrite: true);
        }
        catch (Exception) { }
    }

    /// <summary>Polls update.request from the viewer UI and runs periodic auto-update checks.</summary>
    public void Poll(bool autoUpdateEnabled, bool startedOverMinuteAgo)
    {
        if (disposed || installKind == 2) return;
        if (IsTestMode() && string.IsNullOrWhiteSpace(Environment.GetEnvironmentVariable("REPLAY_UPDATE_URL"))) return;

        // 1. Handle explicit UI action from Settings > About
        if (File.Exists(RequestFilePath))
        {
            string req = "";
            try
            {
                req = File.ReadAllText(RequestFilePath).Trim();
                File.Delete(RequestFilePath);
            }
            catch (Exception) { }

            if (req == "check")
            {
                _ = CheckAsync(userAsked: true);
                return;
            }
            if (req == "update")
            {
                if (state == "ready")
                {
                    InstallNow();
                }
                else if (state == "found" && !byHand)
                {
                    askedByUser = true;
                    _ = DownloadAsync();
                }
                else if (state == "fetching")
                {
                    askedByUser = true;
                }
                return;
            }
        }

        // 2. Background automatic update (only for Setup installs when autoUpdate is enabled)
        if (installKind != 1 || !(autoUpdateEnabled || IsUpdateNowTest())) return;
        if (!startedOverMinuteAgo && !IsUpdateNowTest()) return;
        if (Volatile.Read(ref busy) != 0) return;

        if (state == "ready")
        {
            TryInstallWhenIdle();
            return;
        }
        if (state == "found" && !byHand)
        {
            askedByUser = false;
            _ = DownloadAsync();
            return;
        }

        var nowEpoch = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        var due = IsUpdateNowTest()
            ? lastTried == DateTimeOffset.MinValue
            : (nowEpoch - lastCheckedEpoch >= 86400 || lastCheckedEpoch > nowEpoch + 60) &&
              (DateTimeOffset.UtcNow - lastTried >= TimeSpan.FromHours(1));
        if (due)
        {
            _ = CheckAsync(userAsked: false);
        }
    }

    private async Task CheckAsync(bool userAsked)
    {
        if (Interlocked.CompareExchange(ref busy, 1, 0) != 0) return;
        try
        {
            if (state == "ready") return;
            askedByUser = userAsked;
            lastTried = DateTimeOffset.UtcNow;
            state = "checking";
            errorCode = "";
            WriteState();

            var url = DownloadBase() + "latest.json";
            if (!IsUrlAllowed(url))
            {
                Fail("bad_url");
                return;
            }

            using var resp = await http.GetAsync(url, HttpCompletionOption.ResponseContentRead).ConfigureAwait(false);
            if (!resp.IsSuccessStatusCode)
            {
                Fail("http");
                return;
            }

            var bytes = await resp.Content.ReadAsByteArrayAsync().ConfigureAwait(false);
            using var doc = JsonDocument.Parse(bytes);
            var root = doc.RootElement;
            var ver = GetString(root, "version").Trim().ToLowerInvariant();
            if (!IsPlainVersion(ver))
            {
                log("update: latest.json has invalid version");
                Fail("bad_manifest");
                return;
            }

            lastCheckedEpoch = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
            if (!IsNewer(ver, AppVersion))
            {
                log($"update: {AppVersion} is up to date");
                state = "latest";
                foundVersion = "";
                WriteState();
                return;
            }

            var sha = GetString(root, "setup_sha256").Trim().ToLowerInvariant();
            var sig = GetString(root, "signature").Trim().ToLowerInvariant();
            var signedOk = IsPlainSha256(sha) && VerifyReleaseSignature(ver, sha, sig);

            foundVersion = ver;
            foundSha = sha;
            // Only Setup installs (installKind == 1) with a valid ECDSA signature auto-install; others open website
            byHand = installKind != 1 || !signedOk;
            state = "found";
            percent = -1;
            log($"update: found {ver} (signed={signedOk}, installKind={installKind})");
            WriteState();

            if (!userAsked && !byHand)
            {
                Interlocked.Exchange(ref busy, 0);
                await DownloadAsync().ConfigureAwait(false);
                return;
            }
        }
        catch (Exception ex)
        {
            log("update: check failed: " + ex.Message);
            Fail("network");
        }
        finally
        {
            Interlocked.Exchange(ref busy, 0);
        }
    }

    private async Task DownloadAsync()
    {
        if (string.IsNullOrEmpty(foundVersion) || byHand) return;
        if (Interlocked.CompareExchange(ref busy, 1, 0) != 0) return;
        var ver = foundVersion;
        var wantSha = foundSha;
        var fileName = $"ScreenReplay-Setup-{ver}.exe";
        var dest = Path.Combine(TempUpdateDir(), fileName);
        var part = dest + ".part";
        try
        {
            var url = DownloadBase() + $"v{ver}/{fileName}";
            if (!IsUrlAllowed(url))
            {
                Fail("bad_url");
                return;
            }

            state = "fetching";
            percent = -1;
            errorCode = "";
            WriteState();
            log($"update: downloading {url}");

            using var resp = await http.GetAsync(url, HttpCompletionOption.ResponseHeadersRead).ConfigureAwait(false);
            if (!resp.IsSuccessStatusCode)
            {
                Fail("download_http");
                return;
            }

            var total = resp.Content.Headers.ContentLength ?? 0L;
            long got = 0;
            var lastReport = Environment.TickCount64;
            using var hasher = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            await using (var net = await resp.Content.ReadAsStreamAsync().ConfigureAwait(false))
            await using (var fs = new FileStream(part, FileMode.Create, FileAccess.Write, FileShare.None, 65536, useAsync: true))
            {
                var buf = new byte[65536];
                int n;
                while ((n = await net.ReadAsync(buf).ConfigureAwait(false)) > 0)
                {
                    await fs.WriteAsync(buf.AsMemory(0, n)).ConfigureAwait(false);
                    hasher.AppendData(buf, 0, n);
                    got += n;
                    var now = Environment.TickCount64;
                    if (total > 0 && now - lastReport >= 200)
                    {
                        lastReport = now;
                        percent = (int)(got * 100L / total);
                        WriteState();
                    }
                }
            }

            if (total > 0 && got != total)
            {
                try { File.Delete(part); } catch (Exception) { }
                Fail("network");
                return;
            }

            var gotSha = Convert.ToHexString(hasher.GetHashAndReset()).ToLowerInvariant();
            if (!string.Equals(gotSha, wantSha, StringComparison.Ordinal))
            {
                try { File.Delete(part); } catch (Exception) { }
                log($"update: checksum mismatch for {ver} (got {gotSha}, expected {wantSha})");
                Fail("checksum");
                return;
            }

            File.Move(part, dest, overwrite: true);
            downloadedFile = dest;
            readyAt = DateTimeOffset.UtcNow;
            readyNoted = false;
            state = "ready";
            percent = 100;
            log($"update: {ver} verified and ready at {dest}");
            WriteState();

            Interlocked.Exchange(ref busy, 0);
            if (askedByUser)
            {
                InstallNow();
            }
            else
            {
                TryInstallWhenIdle();
            }
        }
        catch (Exception ex)
        {
            try { File.Delete(part); } catch (Exception) { }
            log("update: download failed: " + ex.Message);
            Fail("download_network");
        }
        finally
        {
            Interlocked.Exchange(ref busy, 0);
        }
    }

    private void TryInstallWhenIdle()
    {
        if (state != "ready") return;
        var replayShown = isReplayVisible();
        var idleMs = GetIdleMilliseconds();
        if (!replayShown && (IsUpdateNowTest() || idleMs >= 120_000))
        {
            InstallNow();
            return;
        }
        if (!readyNoted && readyAt != DateTimeOffset.MinValue && DateTimeOffset.UtcNow - readyAt >= TimeSpan.FromDays(1))
        {
            readyNoted = true;
            notify(
                L.T($"ScreenReplay {foundVersion} 已就绪", $"ScreenReplay {foundVersion} is ready"),
                L.T("空闲时将自动更新，也可在「设置 › 关于」中立即重启更新。", "Will update automatically when idle, or restart now in Settings › About."));
        }
    }

    private void InstallNow()
    {
        if (state != "ready" || string.IsNullOrEmpty(downloadedFile) || !File.Exists(downloadedFile))
        {
            Fail("install_failed");
            return;
        }
        if (Interlocked.CompareExchange(ref busy, 1, 0) != 0) return;

        FileStream? sealedHandle = null;
        try
        {
            // Keep a read+delete shared handle open so nothing can overwrite the verified binary before launch
            sealedHandle = new FileStream(downloadedFile, FileMode.Open, FileAccess.Read, FileShare.Read | FileShare.Delete);
            var verifySha = Convert.ToHexString(SHA256.HashData(sealedHandle)).ToLowerInvariant();
            if (!string.Equals(verifySha, foundSha, StringComparison.Ordinal))
            {
                sealedHandle.Dispose();
                log("update: pre-exec SHA-256 verification failed");
                Fail("checksum");
                Interlocked.Exchange(ref busy, 0);
                return;
            }

            state = "installing";
            errorCode = "";
            WriteState();
            log($"update: launching silent installer {downloadedFile}");

            var psi = new ProcessStartInfo(downloadedFile)
            {
                Arguments = "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- /UPDATE",
                UseShellExecute = true,
                WindowStyle = ProcessWindowStyle.Hidden,
            };
            var proc = Process.Start(psi);
            if (proc is null)
            {
                sealedHandle.Dispose();
                Fail("install_failed");
                Interlocked.Exchange(ref busy, 0);
                return;
            }

            // Watch in background: normally setup runs `ScreenReplay.exe --quit` and ends this process;
            // if setup exits and we are still alive, report failure and release the sealed handle.
            _ = Task.Run(async () =>
            {
                try
                {
                    await proc.WaitForExitAsync().ConfigureAwait(false);
                    var code = proc.ExitCode;
                    log($"update: installer exited ({code}) while process still running");
                    if (!disposed)
                    {
                        Fail("install_failed");
                    }
                }
                catch (Exception) { }
                finally
                {
                    proc.Dispose();
                    sealedHandle.Dispose();
                    Interlocked.Exchange(ref busy, 0);
                }
            });
        }
        catch (Exception ex)
        {
            sealedHandle?.Dispose();
            log("update: launch failed: " + ex.Message);
            Fail("install_failed");
            Interlocked.Exchange(ref busy, 0);
        }
    }

    private void Fail(string code)
    {
        state = "failed";
        errorCode = code;
        percent = -1;
        WriteState();
    }

    private static bool IsUrlAllowed(string url)
    {
        if (!Uri.TryCreate(url, UriKind.Absolute, out var uri)) return false;
        if (uri.Scheme == Uri.UriSchemeHttps) return true;
        return IsTestMode() && uri.Scheme == Uri.UriSchemeHttp && uri.Host == "127.0.0.1";
    }

    private static string GetString(JsonElement obj, string name)
        => obj.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() ?? "" : "";

    public static bool IsPlainVersion(string v)
    {
        var parts = v.Split('.');
        if (parts.Length is < 2 or > 4) return false;
        foreach (var p in parts)
        {
            if (p.Length is 0 or > 9) return false;
            foreach (var c in p)
            {
                if (c is < '0' or > '9') return false;
            }
        }
        return true;
    }

    private static bool IsPlainSha256(string h)
    {
        if (h.Length != 64) return false;
        foreach (var c in h)
        {
            if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return false;
        }
        return true;
    }

    public static bool IsNewer(string candidate, string current)
    {
        var a = candidate.Split('.');
        var b = current.Split('.');
        var n = Math.Max(a.Length, b.Length);
        for (int i = 0; i < n; i++)
        {
            int x = i < a.Length && int.TryParse(a[i], out var xv) ? xv : 0;
            int y = i < b.Length && int.TryParse(b[i], out var yv) ? yv : 0;
            if (x != y) return x > y;
        }
        return false;
    }

    public static bool VerifyReleaseSignature(string version, string setupSha, string sigHex)
    {
        if (sigHex.Length != 128) return false;
        byte[] sig;
        try
        {
            sig = Convert.FromHexString(sigHex);
        }
        catch (Exception)
        {
            return false;
        }
        var msg = Encoding.ASCII.GetBytes($"screenreplay-update\n{version}\n{setupSha.ToLowerInvariant()}\n");
        using var ecdsa = ECDsa.Create(new ECParameters
        {
            Curve = ECCurve.NamedCurves.nistP256,
            Q = new ECPoint { X = KeyX, Y = KeyY }
        });
        return ecdsa.VerifyData(msg, sig, HashAlgorithmName.SHA256, DSASignatureFormat.IeeeP1363FixedFieldConcatenation);
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct LASTINPUTINFO
    {
        public uint cbSize;
        public uint dwTime;
    }

    [DllImport("user32.dll")]
    private static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);

    private static uint GetIdleMilliseconds()
    {
        var li = new LASTINPUTINFO { cbSize = (uint)Marshal.SizeOf<LASTINPUTINFO>() };
        return GetLastInputInfo(ref li) ? unchecked((uint)Environment.TickCount - li.dwTime) : 0u;
    }

    public void Dispose()
    {
        disposed = true;
        http.Dispose();
    }
}
