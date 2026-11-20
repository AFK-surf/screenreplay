# Third-party notices

ScreenReplay uses the following components:

| Component | Used for | License |
|---|---|---|
| .NET runtime | the recorder | MIT |
| C#/WinRT (WinRT.Runtime, Microsoft.Windows.SDK.NET) | Windows APIs from .NET | MIT |
| Microsoft Edge WebView2 (its loader only) | linked into the replay window by mbui's Windows host; the window opens no web view | Microsoft Software License Terms (redistributable) |
| Media Foundation, Windows Graphics Capture, WASAPI | capture, encoding, sound | part of Windows |
| MoonBit core library | the replay window | Apache-2.0 |
| mbui and still.fail app components | the replay window's UI | MIT (see `site/licenses.txt` for mbui and its included components) |
| Vortice.Windows (Vortice.DirectX, .DXGI, .Direct3D11, .MediaFoundation), Vortice.Mathematics | the recorder's Direct3D 11 and Media Foundation calls | MIT |
| SharpGen.Runtime, SharpGen.Runtime.COM | COM calls under Vortice.Windows | MIT |
