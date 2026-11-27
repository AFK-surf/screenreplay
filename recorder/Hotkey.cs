namespace Replay.Recorder;

// A global shortcut as settings.json keeps it ("Ctrl+Alt+R"): the same names the viewer's shortcut field writes
// (native/replay_win.c rp_hotkey_take). "" is no shortcut.
internal static class Hotkey
{
    public static bool TryParse(string spec, out uint modifiers, out uint key)
    {
        modifiers = 0;
        key = 0;
        if (string.IsNullOrWhiteSpace(spec))
        {
            return false;
        }

        var parts = spec.Split('+', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length < 2)
        {
            return false;
        }

        for (var i = 0; i < parts.Length - 1; i++)
        {
            switch (parts[i].ToLowerInvariant())
            {
                case "ctrl": modifiers |= 0x2; break;
                case "alt": modifiers |= 0x1; break;
                case "shift": modifiers |= 0x4; break;
                case "win" or "cmd": modifiers |= 0x8; break;
                default: return false;
            }
        }

        if ((modifiers & 0xB) == 0)
        {
            return false;
        }

        key = KeyOf(parts[^1]);
        return key != 0;
    }

    private static uint KeyOf(string name)
    {
        if (name.Length == 1)
        {
            var c = char.ToUpperInvariant(name[0]);
            return c is >= 'A' and <= 'Z' or >= '0' and <= '9' ? (uint)c : 0;
        }

        if (name.Length is 2 or 3 && (name[0] is 'F' or 'f') && int.TryParse(name[1..], out var f) && f is >= 1 and <= 24)
        {
            return (uint)(0x70 + f - 1);
        }

        if (name.Length == 4 && name.StartsWith("Num", StringComparison.OrdinalIgnoreCase) && name[3] is >= '0' and <= '9')
        {
            return (uint)(0x60 + name[3] - '0');
        }

        return name.ToLowerInvariant() switch
        {
            "space" => 0x20,
            "pageup" => 0x21,
            "pagedown" => 0x22,
            "end" => 0x23,
            "home" => 0x24,
            "left" => 0x25,
            "up" => 0x26,
            "right" => 0x27,
            "down" => 0x28,
            "insert" => 0x2D,
            "delete" => 0x2E,
            "pause" => 0x13,
            "printscreen" => 0x2C,
            _ => 0,
        };
    }
}
