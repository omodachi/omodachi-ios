//
//  OmodachiMediaFacade.h
//  Moonlight
//
//  Copyright (c) 2026 Omodachi contributors. All rights reserved.
//  Derived integration helper for the Moonlight Stream client; keep the
//  upstream Moonlight license and attribution when redistributing.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreMedia/CoreMedia.h>

#import "OmodachiMediaLifecycleGate.h"
#import "StreamConfiguration.h"
#import "VideoDecoderRenderer.h"

@class OmodachiMediaFacade;

NS_ASSUME_NONNULL_BEGIN

typedef void (^OmodachiInputReleaseHandler)(uint64_t generation);

/// STREAM-1. One second of the connection as moonlight-common-c counted it,
/// plus the round trip it estimates and the frames the renderer enqueued.
/// Decode time is not here: AVSampleBufferDisplayLayer decodes internally and
/// reports no per-frame timing, so there is nothing honest to put in it.
typedef struct {
    double windowSeconds;
    int totalFrames;
    int receivedFrames;
    int networkDroppedFrames;
    /// Sunshine's own encode latency, averaged over the window, in 0.1 ms. 0 = not reported.
    int hostProcessingLatencyTenthsMs;
    BOOL rttKnown;
    uint32_t rttMs;
    uint32_t rttVarianceMs;
    /// Cumulative since this facade's renderer was created.
    uint64_t enqueuedFrames;
    int videoFormat;
} OmodachiStreamStats;
typedef void (^OmodachiMediaCompletion)(NSError * _Nullable error);

@protocol OmodachiMediaFacadeDelegate <NSObject>
@optional
- (void)mediaFacade:(OmodachiMediaFacade *)facade didStartGeneration:(uint64_t)generation;
- (void)mediaFacade:(OmodachiMediaFacade *)facade
 didReceiveDecodedWidth:(int)width
              height:(int)height
        videoFormat:(int)videoFormat
         generation:(uint64_t)generation;
- (void)mediaFacade:(OmodachiMediaFacade *)facade
 didObservePresentation:(VideoPresentationObservation)observation;
- (void)mediaFacade:(OmodachiMediaFacade *)facade
 didFinishStoppingGeneration:(uint64_t)generation;
- (void)mediaFacade:(OmodachiMediaFacade *)facade
 didTerminateUnexpectedlyForGeneration:(uint64_t)generation
              errorCode:(int)errorCode;
- (void)mediaFacade:(OmodachiMediaFacade *)facade
 didStartStage:(NSString *)stageName
       generation:(uint64_t)generation;
- (void)mediaFacade:(OmodachiMediaFacade *)facade
 didCompleteStage:(NSString *)stageName
          generation:(uint64_t)generation;
- (void)mediaFacade:(OmodachiMediaFacade *)facade
 didFailStage:(NSString *)stageName
        errorCode:(int)errorCode
   portTestFlags:(int)portTestFlags
       generation:(uint64_t)generation;
@end

/// A single-owner, serial lifecycle boundary around stock Moonlight's common-c
/// connection and AVSampleBufferDisplayLayer renderer. It owns media ordering;
/// it does not perform pairing, output management, or product UI work.
@interface OmodachiMediaFacade : NSObject

+ (BOOL)isProcessIdle;

@property(nonatomic, weak, readonly) UIView *view;
@property(nonatomic, weak, readonly, nullable) id<OmodachiMediaFacadeDelegate> delegate;
@property(nonatomic, readonly) uint64_t generation;
@property(nonatomic, readonly) OmodachiMediaLifecycleState lifecycleState;

- (instancetype)initWithView:(UIView *)view
                configuration:(StreamConfiguration *)configuration
                     delegate:(nullable id<OmodachiMediaFacadeDelegate>)delegate NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Starts one generation. The method only validates and queues start; the
/// delegate receives didStartGeneration after common-c reports connectionStarted.
- (BOOL)startWithGeneration:(uint64_t)generation error:(NSError * _Nullable * _Nullable)error;

/// Completion runs after LiStopConnection() returned, the renderer was stopped,
/// and the input-release handler returned. NSOperation finished is not used as
/// a quiesced signal.
- (BOOL)stopWithCompletion:(nullable OmodachiMediaCompletion)completion
                     error:(NSError * _Nullable * _Nullable)error;

/// Stops the current generation if needed and releases this process-wide owner.
- (BOOL)invalidateWithCompletion:(nullable OmodachiMediaCompletion)completion
                           error:(NSError * _Nullable * _Nullable)error;

- (void)setInputReleaseHandler:(nullable OmodachiInputReleaseHandler)handler;

- (BOOL)getDecodedFormatDimensions:(CGSize *)dimensions videoFormat:(int * _Nullable)videoFormat;
- (VideoPresentationObservation)presentationObservation;
/// Whether the renderer's display tick keeps publishing observations. A
/// consumer that has already latched the geometry it was waiting for turns this
/// off; anything that invalidates that geometry turns it back on.
- (void)setPublishesObservationEachTick:(BOOL)enabled;
- (nullable UIImage *)copyDisplayedFrameForGeneration:(uint64_t)generation;
/// STREAM-1. NO until the first complete one-second window exists, or once the
/// connection is gone. Main thread.
- (BOOL)copyStreamStats:(OmodachiStreamStats *)stats;

@end

NS_ASSUME_NONNULL_END
