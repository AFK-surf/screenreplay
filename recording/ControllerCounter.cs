namespace Replay.Recording;

public sealed class ControllerCounter
{
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

    public bool[] Buttons { get; }

    public int[] Switches { get; }

    public double[] Axes { get; }

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

            // Measure axis delta from last counted position, not previous reading; 250 Hz pads move below deadzone per sample.
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
        Buttons.CopyTo(lastButtons, 0);
        Switches.CopyTo(lastSwitches, 0);
        return (presses, travel);
    }
}
