using System.Runtime.InteropServices;
using Vortice.MediaFoundation;

namespace Replay.Recording;

public sealed record ClipPart(string Path, long OffsetHns, long TrimStartHns, long EndHns);

public static class ClipJoiner
{
    private const int AnyStream = unchecked((int)0xFFFFFFFE);

    public static int SaveLast(IReadOnlyList<Segment> segments, TimeSpan length, string output)
    {
        if (segments.Count == 0)
        {
            return -1;
        }

        var last = segments[^1];
        var from = last.EndUtc - length;
        var parts = new List<Segment>();
        for (var i = segments.Count - 1; i >= 0; i--)
        {
            var s = segments[i];
            if (s.EndUtc <= from || s.Width != last.Width || s.Height != last.Height)
            {
                break;
            }

            parts.Insert(0, s);
        }

        if (parts.Count == 0)
        {
            return -1;
        }

        var first = parts[0].StartUtc;
        var plan = parts.Select((p, i) => new ClipPart(
            p.Path,
            (p.StartUtc - first).Ticks,
            i == 0 ? Math.Max(0, (from - p.StartUtc).Ticks) : 0,
            (long)(p.DurationMs * 10_000))).ToList();
        var partial = output + ".partial.mp4";
        var result = Join(plan, partial);
        if (result == 0)
        {
            try
            {
                File.Move(partial, output, overwrite: false);
            }
            catch (Exception ex)
            {
                result = ex.HResult != 0 ? ex.HResult : -2;
            }
        }

        if (result != 0)
        {
            try
            {
                File.Delete(partial);
            }
            catch (Exception)
            {
            }
        }

        return result;
    }

    public static int Join(IReadOnlyList<ClipPart> parts, string output)
    {
        if (parts.Count == 0)
        {
            return -1;
        }

        try
        {
            Gpu.StartMediaFoundation();
            IMFSinkWriter? writer = null;
            int videoOut = -1, audioOut = -1;
            long shift = 0;
            try
            {
                for (var p = 0; p < parts.Count; p++)
                {
                    var part = parts[p];
                    using var reader = MediaFactory.MFCreateSourceReaderFromURL(part.Path, null);
                    int video = -1, audio = -1;
                    for (var s = 0; s < 8; s++)
                    {
                        IMFMediaType type;
                        try
                        {
                            type = reader.GetNativeMediaType(s, 0);
                        }
                        catch (SharpGen.Runtime.SharpGenException)
                        {
                            break;
                        }

                        using (type)
                        {
                            var major = type.GetGUID(Native.MT_MAJOR_TYPE);
                            if (major == Native.MediaType_Video && video < 0)
                            {
                                video = s;
                            }
                            else if (major == Native.MediaType_Audio && audio < 0)
                            {
                                audio = s;
                            }
                        }
                    }

                    if (video < 0)
                    {
                        continue;
                    }

                    if (writer is null)
                    {
                        using var attrs = MediaFactory.MFCreateAttributes(1);
                        attrs.Set(Native.TRANSCODE_CONTAINERTYPE, Native.TranscodeContainerType_MPEG4);
                        writer = MediaFactory.MFCreateSinkWriterFromURL(output, null, attrs);
                        using (var type = reader.GetNativeMediaType(video, 0))
                        {
                            videoOut = writer.AddStream(type);
                            writer.SetInputMediaType(videoOut, type, null);
                        }

                        if (audio >= 0)
                        {
                            using var type = reader.GetNativeMediaType(audio, 0);
                            audioOut = writer.AddStream(type);
                            writer.SetInputMediaType(audioOut, type, null);
                        }

                        writer.BeginWriting();
                    }

                    // (MF_SOURCE_READER_ALL_STREAMS, the same value as ANY_STREAM)
                    reader.SetStreamSelection(AnyStream, false);
                    reader.SetStreamSelection(video, true);
                    if (audio >= 0 && audioOut >= 0)
                    {
                        reader.SetStreamSelection(audio, true);
                    }

                    long start = 0;
                    if (part.TrimStartHns > 0)
                    {
                        reader.SetCurrentPosition(part.TrimStartHns);
                        using var key = reader.ReadSample(video, SourceReaderControlFlag.None, out _, out var keyFlags, out var keyTime);
                        if (key is not null && (keyFlags & SourceReaderFlag.EndOfStream) == 0)
                        {
                            start = Math.Min(keyTime, part.TrimStartHns);
                        }

                        reader.SetCurrentPosition(start);
                    }

                    if (p == 0)
                    {
                        shift = part.OffsetHns + start;
                    }

                    var videoDone = false;
                    var audioDone = audio < 0 || audioOut < 0;
                    while (!videoDone || !audioDone)
                    {
                        using var sample = reader.ReadSample(AnyStream, SourceReaderControlFlag.None, out var stream, out var flags, out var time);
                        var isVideo = stream == video;
                        if ((flags & SourceReaderFlag.EndOfStream) != 0)
                        {
                            if (isVideo)
                            {
                                videoDone = true;
                            }
                            else if (stream == audio)
                            {
                                audioDone = true;
                            }

                            continue;
                        }

                        if (sample is null || (isVideo ? videoDone : audioDone))
                        {
                            continue;
                        }

                        if (time >= part.EndHns)
                        {
                            if (isVideo)
                            {
                                videoDone = true;
                            }
                            else
                            {
                                audioDone = true;
                            }

                            continue;
                        }

                        if (time < start)
                        {
                            continue;
                        }

                        sample.SampleTime = part.OffsetHns + time - shift;
                        writer!.WriteSample(isVideo ? videoOut : audioOut, sample);
                    }
                }

                if (writer is null)
                {
                    return -1;
                }

                writer.Finalize();
                writer.Dispose();
                writer = null;
                PatchHev1ToHvc1(output);
                return 0;
            }
            finally
            {
                writer?.Dispose();
            }
        }
        catch (Exception ex)
        {
            return ex.HResult != 0 ? ex.HResult : -3;
        }
    }

    // Renames MP4 HEVC sample entry hev1 -> hvc1 in place for QuickTime/Safari/iOS compatibility.
    internal static void PatchHev1ToHvc1(string path)
    {
        try
        {
            using var fs = new FileStream(path, FileMode.Open, FileAccess.ReadWrite, FileShare.Read);
            var len = fs.Length;
            if (len < 16)
            {
                return;
            }

            var hdr = new byte[16];
            bool ReadBox(long off, long limit, out long body, out long end, out uint type)
            {
                body = end = 0;
                type = 0;
                if (off + 8 > limit)
                {
                    return false;
                }

                fs.Position = off;
                var want = (int)Math.Min(16, limit - off);
                var got = fs.Read(hdr, 0, want);
                if (got < 8)
                {
                    return false;
                }

                var span = hdr.AsSpan(0, got);
                ulong sz = System.Buffers.Binary.BinaryPrimitives.ReadUInt32BigEndian(span[..4]);
                type = System.Buffers.Binary.BinaryPrimitives.ReadUInt32BigEndian(span.Slice(4, 4));
                long head = 8;
                if (sz == 1)
                {
                    if (got < 16)
                    {
                        return false;
                    }

                    sz = System.Buffers.Binary.BinaryPrimitives.ReadUInt64BigEndian(span.Slice(8, 8));
                    head = 16;
                }
                else if (sz == 0)
                {
                    sz = (ulong)(limit - off);
                }

                if (sz < (ulong)head || off + (long)sz > limit)
                {
                    return false;
                }

                body = off + head;
                end = off + (long)sz;
                return true;
            }

            bool FindChild(long from, long limit, uint want, out long body, out long end)
            {
                for (var off = from; ReadBox(off, limit, out body, out end, out var ty); off = end)
                {
                    if (ty == want)
                    {
                        return true;
                    }
                }

                body = end = 0;
                return false;
            }

            const uint MOOV = 0x6D6F6F76, TRAK = 0x7472616B, MDIA = 0x6D646961, MINF = 0x6D696E66,
                       STBL = 0x7374626C, STSD = 0x73747364, HEV1 = 0x68657631;
            if (!FindChild(0, len, MOOV, out var moovB, out var moovE))
            {
                return;
            }

            ReadOnlySpan<byte> hvc1 = "hvc1"u8;
            for (var off = moovB; ReadBox(off, moovE, out var tb, out var te, out var ty); off = te)
            {
                if (ty != TRAK) continue;
                if (!FindChild(tb, te, MDIA, out var mb, out var me)) continue;
                if (!FindChild(mb, me, MINF, out var nb, out var ne)) continue;
                if (!FindChild(nb, ne, STBL, out var sb, out var se)) continue;
                if (!FindChild(sb, se, STSD, out var db, out var de)) continue;
                if (db + 8 >= de) continue;
                if (!ReadBox(db + 8, de, out _, out _, out var entryType)) continue;
                if (entryType == HEV1)
                {
                    fs.Position = db + 8 + 4;
                    fs.Write(hvc1);
                }
            }
        }
        catch (Exception)
        {
        }
    }
}

public static class Decoders
{
    private static readonly Lazy<bool> hevc = new(() => Has(Native.VideoFormat_HEVC));

    public static bool Hevc => hevc.Value;

    private static unsafe bool Has(Guid subtype)
    {
        try
        {
            // MFT_REGISTER_TYPE_INFO { major, sub }
            var info = stackalloc Guid[2] { Native.MediaType_Video, subtype };
            // MFT_ENUM_FLAG_SYNCMFT | ASYNCMFT | HARDWARE | LOCALMFT | SORTANDFILTER
            if (Native.MFTEnumEx(Native.MFT_CATEGORY_VIDEO_DECODER, 0x01 | 0x02 | 0x04 | 0x10 | 0x40, (IntPtr)info, IntPtr.Zero, out var activates, out var count) < 0)
            {
                return false;
            }

            for (var i = 0; i < count; i++)
            {
                Native.Release(Marshal.ReadIntPtr(activates, i * IntPtr.Size));
            }

            Native.CoTaskMemFree(activates);
            return count > 0;
        }
        catch (Exception)
        {
            return false;
        }
    }
}
