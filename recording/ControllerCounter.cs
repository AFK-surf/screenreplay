namespace Replay.Recording;

/// <summary>
/// One game controller's readings, one after another, made into counts for <see cref="InputActivity"/>: its buttons
/// pressed (released, then pressed), its switches (a d-pad, a hat) pushed to another place than the one before, and how
/// far its sticks and triggers went (each axis' change, 0…1 its whole travel, from where it last counted; under
/// <see cref="Deadzone"/> of that left out: a resting stick's noise and drift). Never which button or where. The reading is written into
/// <see cref="Buttons"/>, <see cref="Switches"/> and <see cref="Axes"/>, then <see cref="Take"/> compares it with the
/// one before (it stays as it was: a reading is written whole): nothing allocated as it goes.
/// </summary>
public sealed class ControllerCounter
{
    /// <summary>The least change of an axis between two readings that counts.</summary>
    public const double Deadzone = 0.02;

    private readonly bool[] lastButtons;
    private readonly int[] lastSwitches;
    private readonly double[] lastAxes;
    private bool primed;

    public ControllerCounter(int buttons, int switches, int axes)
    {
        Buttons = new bool[buttons];
        Switches = new int[switches];
        Axes = new double[axes];
        lastButtons = new bool[buttons];
        lastSwitches = new int[switches];
        lastAxes = new double[axes];
    }

    /// <summary>The reading now: each button down or not.</summary>
    public bool[] Buttons { get; }

    /// <summary>The reading now: each switch's place (0 at rest).</summary>
    public int[] Switches { get; }

    /// <summary>The reading now: each axis, 0…1.</summary>
    public double[] Axes { get; }

    /// <summary>What changed since the reading before: presses (buttons and switches) and the axes' travel. The first
    /// reading only sets where things are.</summary>
    public (int Presses, double Travel) Take()
    {
        var presses = 0;
        var travel = 0.0;
        if (primed)
        {
            for (var i = 0; i < Buttons.Length; i++)
            {
                if (Buttons[i] && !lastButtons[i])
                {
                    presses++;
                }
            }

            for (var i = 0; i < Switches.Length; i++)
            {
                if (Switches[i] != lastSwitches[i] && Switches[i] != 0)
                {
                    presses++;
                }
            }

            // (an axis measured from where it last counted, not from the reading before: a pad sending 250 readings a
            // second moves under the deadzone between any two of them)
            for (var i = 0; i < Axes.Length; i++)
            {
                var d = Math.Abs(Axes[i] - lastAxes[i]);
                if (d >= Deadzone)
                {
                    travel += d;
                    lastAxes[i] = Axes[i];
                }
            }
        }
        else
        {
            Axes.CopyTo(lastAxes, 0);
        }

        primed = true;
        // (the reading kept as the one before; the next is written over this one)
        Buttons.CopyTo(lastButtons, 0);
        Switches.CopyTo(lastSwitches, 0);
        return (presses, travel);
    }
}
