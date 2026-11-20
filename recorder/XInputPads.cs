using System.Runtime.InteropServices;
using Replay.Recording;

namespace Replay.Recorder;

/// <summary>
/// XInput's game controllers (an Xbox pad and those made like one, Steam Input's and other virtual pads), read with
/// XInputGetState, which answers whatever window is in front (Windows.Gaming.Input gave the background recorder
/// nothing while a game had the focus: the user, 2026-11-14). While recording: each of the four places looked at every
/// 2 s while nothing is in it (a look at an empty place is the slow one), every 100 ms while a pad is; with none,
/// only that look every 2 s. What changed between two looks goes to <see cref="InputActivity"/> as counts
/// (<see cref="ControllerCounter"/>: its 16 buttons, the d-pad among them; its sticks and triggers as 6 axes).
/// </summary>
internal sealed class XInputPads(MessageWindow window, InputActivity activity, Action<string> log) : IDisposable
{
    private const int Places = 4;

    [StructLayout(LayoutKind.Sequential)]
    private struct State
    {
        public uint Packet;
        public ushort Buttons;
        public byte LeftTrigger;
        public byte RightTrigger;
        public short LeftX;
        public short LeftY;
        public short RightX;
        public short RightY;
    }

    [DllImport("xinput1_4.dll")]
    private static extern uint XInputGetState(uint user, out State state);

    private readonly bool[] connected = new bool[Places];
    private readonly uint[] packet = new uint[Places];
    private readonly ControllerCounter[] counters = [.. Enumerable.Range(0, Places).Select(_ => new ControllerCounter(16, 0, 6))];
    private nuint probe;
    private nuint poll;
    private bool listening;
    private bool missing;

    /// <summary>Looking at the pads while recording, not otherwise.</summary>
    public bool Listening
    {
        get => listening;
        set
        {
            if (value == listening || missing)
            {
                return;
            }

            listening = value;
            if (value)
            {
                Probe();
                probe = window.Every(2000, Probe);
            }
            else
            {
                window.Stop(probe);
                probe = 0;
                Polling(false);
                Array.Clear(connected);
            }
        }
    }

    /// <summary>The empty places looked at: a pad come into one is read from then on.</summary>
    private void Probe()
    {
        try
        {
            for (var i = 0; i < Places; i++)
            {
                if (!connected[i] && XInputGetState((uint)i, out var s) == 0)
                {
                    connected[i] = true;
                    // (its first reading only sets where it is)
                    Fill(counters[i], s);
                    counters[i].Take();
                    packet[i] = s.Packet;
                    log($"controller (XInput) connected in place {i}");
                }
            }
        }
        catch (DllNotFoundException)
        {
            // (Windows without XInput 1.4: no pads of its kind)
            missing = true;
            window.Stop(probe);
            probe = 0;
            return;
        }

        Polling(Array.IndexOf(connected, true) >= 0);
    }

    private void Polling(bool on)
    {
        if (on && poll == 0)
        {
            poll = window.Every(100, Poll);
        }
        else if (!on && poll != 0)
        {
            window.Stop(poll);
            poll = 0;
        }
    }

    private void Poll()
    {
        var presses = 0;
        var travel = 0.0;
        for (var i = 0; i < Places; i++)
        {
            if (!connected[i])
            {
                continue;
            }

            if (XInputGetState((uint)i, out var s) != 0)
            {
                connected[i] = false;
                log($"controller (XInput) disconnected from place {i}");
                continue;
            }

            // (the same packet number: nothing changed)
            if (s.Packet == packet[i])
            {
                continue;
            }

            packet[i] = s.Packet;
            Fill(counters[i], s);
            var (n, t) = counters[i].Take();
            presses += n;
            travel += t;
        }

        if (presses > 0)
        {
            activity.Presses(presses, 0);
        }

        if (travel > 0)
        {
            activity.Axes(travel, 0);
        }

        Polling(Array.IndexOf(connected, true) >= 0);
    }

    /// <summary>A state as a reading: the buttons' bits, the triggers (0…255) and sticks (-32768…32767) as 0…1.</summary>
    private static void Fill(ControllerCounter c, in State s)
    {
        for (var b = 0; b < 16; b++)
        {
            c.Buttons[b] = (s.Buttons & (1 << b)) != 0;
        }

        c.Axes[0] = (s.LeftX + 32768) / 65535.0;
        c.Axes[1] = (s.LeftY + 32768) / 65535.0;
        c.Axes[2] = (s.RightX + 32768) / 65535.0;
        c.Axes[3] = (s.RightY + 32768) / 65535.0;
        c.Axes[4] = s.LeftTrigger / 255.0;
        c.Axes[5] = s.RightTrigger / 255.0;
    }

    public void Dispose()
    {
        Listening = false;
    }
}
