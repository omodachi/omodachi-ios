#import <CoreImage/CoreImage.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreGraphics/CoreGraphics.h>

/// Renders an independent bounded bitmap synchronously. Never saves/transmits
/// pixels; the returned image remains valid after the decoder buffer is freed.
CGImageRef _Nullable OMCreateIndependentDisplayedFrame(CVPixelBufferRef _Nonnull pixel,
    size_t expectedWidth, size_t expectedHeight, CIContext * _Nonnull context) CF_RETURNS_RETAINED;
