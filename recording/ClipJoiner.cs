using System.Runtime.InteropServices;
using Vortice.MediaFoundation;

namespace Replay.Recording;

/// <summary>A piece of a clip: a segment's file, where its first moment lands in the clip (100 ns from the first
/// part's start), and the stretch of it kept (100 ns into the file: from, to).</summary>
public sealed record ClipPart(string Path, long OffsetHns, long TrimStartHns, long EndHns);

/// <summary>
/// Segments joined into one MP4 without encoding again: each file's samples read as they are (Media Foundation's
/// source reader, nothing decoded) and written in turn to one sink writer, their times moved to the clip's. The clip
/// starts on the keyframe at or before the moment asked for, so its first frame is whole.
/// </summary>
public static class ClipJoiner
{
    private const int AnyStream = unchecked((int)0xFFFFFFFE);

    /// <summary>The last <paramref name="length"/> of <paramref name="segments"/> (oldest first) saved to
    /// <paramref name="output"/> (written under a temporary name, renamed when complete). 0 when it was saved; else an
    /// HRESULT or -1 (nothing to save).</summary>
    public static int SaveLast(IReadOnlyList<Segment> segments, TimeSpan length, string output)
    {
        if (segments.Count == 0)
        {
            return -1;
        }

        var last = segments[^1];
        var from = last.EndUtc - length;
        // only the newest run of one picture size (what was recorded at another size cannot be joined to it as it is)
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

    /// <summary>The parts joined into <paramref name="output"/>. 0 when it was written; else the HRESULT that stopped it.</summary>
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

                    // from the keyframe at or before the moment asked for: found by seeking there and reading the
                    // first frame, then the file read again from that frame's time, its sound with it
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
}

/// <summary>What Media Foundation can decode here.</summary>
public static class Decoders
{
    private static readonly Lazy<bool> hevc = new(() => Has(Native.VideoFormat_HEVC));

    /// <summary>Whether an HEVC decoder is installed (a GPU's, or the HEVC Video Extensions): what the replay window
    /// needs to show and re-encode an HEVC recording. Asked once.</summary>
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
