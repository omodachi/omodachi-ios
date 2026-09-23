//
//  VideoDecoderRenderer.h
//  Moonlight
//
//  Created by Cameron Gutman on 10/18/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

@import AVFoundation;
@import UIKit;

#import "ConnectionCallbacks.h"

#include "Limelight.h"

typedef struct {
    uint64_t generation;
    int decodedWidth;
    int decodedHeight;
    int videoFormat;
    BOOL hasFormatDescription;
    CGRect videoRectPoints;
    BOOL layerVisible;
    BOOL viewInWindow;
    BOOL layerReadyForDisplay;
    BOOL readyObservationSupported;
    BOOL displayedPixelBufferAvailable;
    int displayedPixelBufferWidth;
    int displayedPixelBufferHeight;
    BOOL hasControlTimebase;
    double controlTimebaseRate;
    // This facade never treats readyForDisplay or a displayed pixel buffer as
    // scanout proof. scanoutConfirmed is therefore always NO/unknown here.
    BOOL scanoutConfirmed;
} VideoPresentationObservation;

typedef void (^VideoFormatDescriptionHandler)(uint64_t generation, int width, int height, int videoFormat);
typedef void (^VideoPresentationObservationHandler)(VideoPresentationObservation observation);

@interface VideoDecoderRenderer : NSObject

@property(nonatomic) uint64_t mediaGeneration;
@property(nonatomic, copy) VideoFormatDescriptionHandler formatDescriptionHandler;
@property(nonatomic, copy) VideoPresentationObservationHandler presentationObservationHandler;
/// Whether the display tick publishes an observation. Each one copies the
/// displayed pixel buffer and lays the video layer out a second time, on the
/// same main thread that submits decode units, so it runs while a consumer is
/// still waiting for geometry and stops the moment one has it. Format-description
/// and IDR observations are events, not a poll, and are always published.
/// Defaults to YES; `start` re-arms it.
@property(nonatomic) BOOL publishesObservationEachTick;
/// STREAM-1. Sample buffers handed to the display layer since this renderer
/// was created, in every build configuration. Read on the main thread, which
/// is the thread that enqueues them.
@property(nonatomic, readonly) uint64_t enqueuedFrameCount;

- (id)initWithView:(UIView*)view callbacks:(id<ConnectionCallbacks>)callbacks streamAspectRatio:(float)aspectRatio useFramePacing:(BOOL)useFramePacing;

- (void)setupWithVideoFormat:(int)videoFormat width:(int)videoWidth height:(int)videoHeight frameRate:(int)frameRate;
- (void)start;
- (void)stop;
- (void)setHdrMode:(BOOL)enabled;

// Returns dimensions from the current received CMVideoFormatDescription (SPS/PPS
// or AV1 sequence data). Request/config dimensions are deliberately excluded.
- (BOOL)getDecodedFormatDimensions:(CGSize*)dimensions videoFormat:(int*)videoFormat;
- (VideoPresentationObservation)presentationObservation;
/// Deep immutable bitmap of the CURRENT displayed pixel buffer, in memory only.
/// Independent of this renderer/layer and never a claim of physical scanout.
- (UIImage * _Nullable)copyDisplayedFrameForGeneration:(uint64_t)generation;

- (int)submitDecodeBuffer:(unsigned char *)data length:(int)length bufferType:(int)bufferType decodeUnit:(PDECODE_UNIT)du;

@end
