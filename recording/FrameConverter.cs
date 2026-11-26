using Vortice;
using Vortice.Direct3D11;
using Vortice.DXGI;

namespace Replay.Recording;

internal sealed class FrameConverter : IDisposable
{
    private readonly Gpu gpu;
    private readonly ID3D11VideoDevice videoDevice;
    private readonly ID3D11VideoContext videoContext;
    private readonly int outWidth, outHeight, frameRate;
    private ID3D11VideoProcessorEnumerator? enumerator;
    private ID3D11VideoProcessor? processor;
    private int inWidth, inHeight;
    private ID3D11Texture2D? inputTexture;
    private ID3D11VideoProcessorInputView? inputView;
    private readonly Dictionary<IntPtr, ID3D11VideoProcessorOutputView> outputViews = new();
    private HdrToSdr? hdr;

    public FrameConverter(Gpu gpu, int outWidth, int outHeight, int frameRate)
    {
        this.gpu = gpu;
        this.outWidth = outWidth;
        this.outHeight = outHeight;
        this.frameRate = frameRate;
        videoDevice = gpu.Device.QueryInterface<ID3D11VideoDevice>();
        videoContext = gpu.Context.QueryInterface<ID3D11VideoContext>();
    }

    private void Prepare(int width, int height)
    {
        if (processor is not null && width == inWidth && height == inHeight)
        {
            return;
        }

        DropProcessor();
        inWidth = width;
        inHeight = height;
        var desc = new VideoProcessorContentDescription
        {
            InputFrameFormat = VideoFrameFormat.Progressive,
            InputFrameRate = new Rational((uint)frameRate, 1),
            InputWidth = (uint)width,
            InputHeight = (uint)height,
            OutputFrameRate = new Rational((uint)frameRate, 1),
            OutputWidth = (uint)outWidth,
            OutputHeight = (uint)outHeight,
            // PlaybackNormal instead of OptimalQuality: auto-processing is disabled below, and OptimalQuality causes NVIDIA D3D11 to allocate extra internal reference/scratch surfaces at 4K.
            Usage = VideoUsage.PlaybackNormal,
        };
        videoDevice.CreateVideoProcessorEnumerator(ref desc, out enumerator).CheckError();
        videoDevice.CreateVideoProcessor(enumerator!, 0, out processor).CheckError();

        var scale = Math.Min((double)outWidth / width, (double)outHeight / height);
        var w = Math.Min(outWidth, (int)Math.Round(width * scale));
        var h = Math.Min(outHeight, (int)Math.Round(height * scale));
        var x = (outWidth - w) / 2;
        var y = (outHeight - h) / 2;
        videoContext.VideoProcessorSetStreamFrameFormat(processor!, 0, VideoFrameFormat.Progressive);
        videoContext.VideoProcessorSetStreamSourceRect(processor!, 0, true, new RawRect(0, 0, width, height));
        videoContext.VideoProcessorSetStreamDestRect(processor!, 0, true, new RawRect(x, y, x + w, y + h));
        videoContext.VideoProcessorSetOutputTargetRect(processor!, true, new RawRect(0, 0, outWidth, outHeight));
        videoContext.VideoProcessorSetOutputBackgroundColor(processor!, false, new VideoColor { Rgba = new VideoColorRgba { R = 0, G = 0, B = 0, A = 1 } });
        videoContext.VideoProcessorSetStreamAutoProcessingMode(processor!, 0, false);
        using (var context1 = videoContext.QueryInterfaceOrNull<ID3D11VideoContext1>())
        {
            if (context1 is not null)
            {
                context1.VideoProcessorSetStreamColorSpace1(processor!, 0, ColorSpaceType.RgbFullG22NoneP709);
                context1.VideoProcessorSetOutputColorSpace1(processor!, ColorSpaceType.YcbcrStudioG22LeftP709);
            }
            else
            {
                videoContext.VideoProcessorSetStreamColorSpace(processor!, 0, new VideoProcessorColorSpace());
                videoContext.VideoProcessorSetOutputColorSpace(processor!, new VideoProcessorColorSpace());
            }
        }
    }

    public ID3D11Texture2D Convert(ID3D11Texture2D source, int width, int height, DisplayColor display, ID3D11Texture2D target, uint slice)
    {
        if (source.Description.Format == Format.R16G16B16A16_Float)
        {
            hdr ??= new HdrToSdr(gpu);
            source = hdr.Convert(source, width, height, display);
        }

        Prepare(width, height);
        if (inputView is null || inputTexture is null || inputTexture.NativePointer != source.NativePointer)
        {
            inputView?.Dispose();
            inputTexture?.Dispose();
            inputTexture = null;
            videoDevice.CreateVideoProcessorInputView(source, enumerator!, new VideoProcessorInputViewDescription
            {
                FourCC = 0,
                ViewDimension = VideoProcessorInputViewDimension.Texture2D,
                Texture2D = new Texture2DVideoProcessorInputView { MipSlice = 0, ArraySlice = 0 },
            }, out inputView).CheckError();
            // AddRef source so its COM pointer cannot be recycled while the cached inputView holds it.
            source.AddRef();
            inputTexture = new ID3D11Texture2D(source.NativePointer);
        }

        var key = target.NativePointer + (nint)slice;
        if (!outputViews.TryGetValue(key, out var outputView))
        {
            var desc = target.Description;
            var viewDesc = desc.ArraySize > 1
                ? new VideoProcessorOutputViewDescription
                {
                    ViewDimension = VideoProcessorOutputViewDimension.Texture2DArray,
                    Texture2DArray = new Texture2DArrayVideoProcessorOutputView { MipSlice = 0, FirstArraySlice = slice, ArraySize = 1 },
                }
                : new VideoProcessorOutputViewDescription
                {
                    ViewDimension = VideoProcessorOutputViewDimension.Texture2D,
                    Texture2D = new Texture2DVideoProcessorOutputView { MipSlice = 0 },
                };
            videoDevice.CreateVideoProcessorOutputView(target, enumerator!, viewDesc, out outputView).CheckError();
            outputViews[key] = outputView!;
        }

        var stream = new VideoProcessorStream { Enable = true, InputSurface = inputView };
        videoContext.VideoProcessorBlt(processor!, outputView!, 0, 1, [stream]).CheckError();
        return source;
    }

    private void DropProcessor()
    {
        inputView?.Dispose();
        inputView = null;
        inputTexture?.Dispose();
        inputTexture = null;
        foreach (var view in outputViews.Values)
        {
            view.Dispose();
        }

        outputViews.Clear();
        processor?.Dispose();
        processor = null;
        enumerator?.Dispose();
        enumerator = null;
    }

    public void Dispose()
    {
        DropProcessor();
        hdr?.Dispose();
        videoContext.Dispose();
        videoDevice.Dispose();
    }
}
