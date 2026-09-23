#import "OMDisplayedFrameCopy.h"
CGImageRef OMCreateIndependentDisplayedFrame(CVPixelBufferRef pixel, size_t expectedWidth, size_t expectedHeight, CIContext *context) {
    if (!pixel || !context) return NULL;
    size_t width = CVPixelBufferGetWidth(pixel), height = CVPixelBufferGetHeight(pixel);
    if (width != expectedWidth || height != expectedHeight || width < 64 || height < 64 || width > 4096 || height > 4096) return NULL;
    CIImage *source = [CIImage imageWithCVPixelBuffer:pixel];
    CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGImageRef bitmap = [context createCGImage:source fromRect:CGRectMake(0,0,width,height)
        format:kCIFormatRGBA8 colorSpace:colorSpace deferred:NO];
    CGColorSpaceRelease(colorSpace);
    return bitmap;
}
