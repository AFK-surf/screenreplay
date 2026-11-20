using System.Buffers.Binary;
using System.IO.Compression;
using System.Runtime.InteropServices;
using System.Text;

namespace Replay.Recorder;

/// <summary>
/// A program's icon written as a PNG, for the replay window's timeline: the icon Windows shows for the file
/// (ExtractAssociatedIcon, at the system's icon size, as System.Drawing's Icon.ExtractAssociatedIcon gave it), its
/// pixels with their own alpha, or with its mask's where the icon has none (an old icon of 24 bits).
/// </summary>
internal static class AppIconPng
{
    [StructLayout(LayoutKind.Sequential)]
    private struct IconInfo
    {
        public int IsIcon;
        public int HotspotX;
        public int HotspotY;
        public IntPtr Mask;
        public IntPtr Color;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct BitmapObject
    {
        public int Type;
        public int Width;
        public int Height;
        public int WidthBytes;
        public ushort Planes;
        public ushort BitsPixel;
        public IntPtr Bits;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct BitmapInfoHeader
    {
        public int Size;
        public int Width;
        public int Height;
        public ushort Planes;
        public ushort BitCount;
        public uint Compression;
        public uint SizeImage;
        public int XPelsPerMeter;
        public int YPelsPerMeter;
        public uint ClrUsed;
        public uint ClrImportant;
        // (room for the two colours of a 1-bit bitmap, which GetDIBits may write after the header)
        public ulong Colors;
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr ExtractAssociatedIconW(IntPtr instance, StringBuilder path, ref ushort index);

    [DllImport("user32.dll")]
    private static extern bool GetIconInfo(IntPtr icon, out IconInfo info);

    [DllImport("user32.dll")]
    private static extern bool DestroyIcon(IntPtr icon);

    [DllImport("gdi32.dll")]
    private static extern int GetObjectW(IntPtr obj, int size, out BitmapObject bitmap);

    [DllImport("gdi32.dll")]
    private static extern int GetDIBits(IntPtr dc, IntPtr bitmap, uint start, uint lines, byte[] bits, ref BitmapInfoHeader info, uint usage);

    [DllImport("gdi32.dll")]
    private static extern bool DeleteObject(IntPtr obj);

    [DllImport("user32.dll")]
    private static extern IntPtr GetDC(IntPtr hwnd);

    [DllImport("user32.dll")]
    private static extern int ReleaseDC(IntPtr hwnd, IntPtr dc);

    /// <summary>`exe`'s icon written to `file`; false when it has none that can be read.</summary>
    public static bool Save(string exe, string file)
    {
        ushort index = 0;
        var icon = ExtractAssociatedIconW(IntPtr.Zero, new StringBuilder(exe, 260), ref index);
        if (icon == IntPtr.Zero)
        {
            return false;
        }

        try
        {
            if (!GetIconInfo(icon, out var info))
            {
                return false;
            }

            try
            {
                // (a monochrome icon, without colours: none of today's programs, passed over)
                if (info.Color == IntPtr.Zero || GetObjectW(info.Color, Marshal.SizeOf<BitmapObject>(), out var bitmap) == 0)
                {
                    return false;
                }

                var w = bitmap.Width;
                var h = bitmap.Height;
                var pixels = Bits(info.Color, w, h);
                var mask = Bits(info.Mask, w, h);
                if (pixels is null)
                {
                    return false;
                }

                var hasAlpha = false;
                for (var i = 3; i < pixels.Length; i += 4)
                {
                    if (pixels[i] != 0)
                    {
                        hasAlpha = true;
                        break;
                    }
                }

                var rgba = new byte[pixels.Length];
                for (var i = 0; i < pixels.Length; i += 4)
                {
                    rgba[i] = pixels[i + 2];
                    rgba[i + 1] = pixels[i + 1];
                    rgba[i + 2] = pixels[i];
                    // the mask white where the icon is transparent
                    rgba[i + 3] = hasAlpha ? pixels[i + 3] : mask is not null && mask[i] != 0 ? (byte)0 : (byte)255;
                }

                WritePng(file, w, h, rgba);
                return true;
            }
            finally
            {
                DeleteObject(info.Color);
                DeleteObject(info.Mask);
            }
        }
        finally
        {
            DestroyIcon(icon);
        }
    }

    /// <summary>A bitmap's top `h` rows as 32-bit BGRA pixels, top row first (null when they cannot be read).</summary>
    private static byte[]? Bits(IntPtr bitmap, int w, int h)
    {
        if (bitmap == IntPtr.Zero)
        {
            return null;
        }

        var header = new BitmapInfoHeader
        {
            Size = 40,
            Width = w,
            Height = -h,
            Planes = 1,
            BitCount = 32,
        };
        var bits = new byte[w * h * 4];
        var dc = GetDC(IntPtr.Zero);
        try
        {
            // DIB_RGB_COLORS
            return GetDIBits(dc, bitmap, 0, (uint)h, bits, ref header, 0) == h ? bits : null;
        }
        finally
        {
            ReleaseDC(IntPtr.Zero, dc);
        }
    }

    private static void WritePng(string file, int w, int h, byte[] rgba)
    {
        var header = new byte[13];
        BinaryPrimitives.WriteInt32BigEndian(header, w);
        BinaryPrimitives.WriteInt32BigEndian(header.AsSpan(4), h);
        // 8 bits a channel, RGBA; deflate, the filters' set, no interlace
        header[8] = 8;
        header[9] = 6;
        var raw = new MemoryStream();
        using (var z = new ZLibStream(raw, CompressionLevel.Optimal, leaveOpen: true))
        {
            for (var y = 0; y < h; y++)
            {
                // (each row without a filter)
                z.WriteByte(0);
                z.Write(rgba, y * w * 4, w * 4);
            }
        }

        using var output = File.Create(file);
        output.Write([0x89, (byte)'P', (byte)'N', (byte)'G', 0x0D, 0x0A, 0x1A, 0x0A]);
        Chunk(output, "IHDR", header);
        Chunk(output, "IDAT", raw.ToArray());
        Chunk(output, "IEND", []);
    }

    private static void Chunk(Stream output, string type, byte[] data)
    {
        Span<byte> number = stackalloc byte[4];
        BinaryPrimitives.WriteInt32BigEndian(number, data.Length);
        output.Write(number);
        var typeBytes = Encoding.ASCII.GetBytes(type);
        output.Write(typeBytes);
        output.Write(data);
        var crc = Crc(Crc(0xFFFFFFFFu, typeBytes), data) ^ 0xFFFFFFFFu;
        BinaryPrimitives.WriteUInt32BigEndian(number, crc);
        output.Write(number);
    }

    private static readonly uint[] CrcTable = Enumerable.Range(0, 256).Select(n =>
    {
        var c = (uint)n;
        for (var k = 0; k < 8; k++)
        {
            c = (c & 1) != 0 ? 0xEDB88320u ^ (c >> 1) : c >> 1;
        }

        return c;
    }).ToArray();

    private static uint Crc(uint crc, byte[] bytes)
    {
        foreach (var b in bytes)
        {
            crc = CrcTable[(crc ^ b) & 0xFF] ^ (crc >> 8);
        }

        return crc;
    }
}
