//
//  OmodachiMediaFacade.m
//  Moonlight
//
//  Copyright (c) 2026 Omodachi contributors. All rights reserved.
//

#import "OmodachiMediaFacade.h"

#import "Connection.h"
#import "ConnectionCallbacks.h"
#include "Limelight.h"


static NSLock *OmodachiOwnerLock;
static OmodachiMediaFacade *OmodachiActiveOwner;
static dispatch_once_t OmodachiOwnerOnce;

static void OmodachiEnsureOwnerLock(void)
{
    dispatch_once(&OmodachiOwnerOnce, ^{
        OmodachiOwnerLock = [[NSLock alloc] init];
    });
}

@interface OmodachiMediaFacade () <ConnectionCallbacks>
@property(nonatomic, weak, readwrite) UIView *view;
@property(nonatomic, weak, readwrite, nullable) id<OmodachiMediaFacadeDelegate> delegate;
@property(nonatomic, readwrite) uint64_t generation;
@property(nonatomic, readwrite) OmodachiMediaLifecycleState lifecycleState;
@end

@implementation OmodachiMediaFacade {
    StreamConfiguration *_configuration;
    VideoDecoderRenderer *_renderer;
    Connection *_connection;
    OmodachiMediaLifecycleGate *_gate;
    NSOperationQueue *_ownerQueue;
    OmodachiInputReleaseHandler _inputReleaseHandler;
    BOOL _invalidated;
}

@synthesize view = _view;
@synthesize delegate = _delegate;
@synthesize generation = _generation;
@synthesize lifecycleState = _lifecycleState;

- (instancetype)initWithView:(UIView *)view
                configuration:(StreamConfiguration *)configuration
                     delegate:(id<OmodachiMediaFacadeDelegate>)delegate
{
    NSParameterAssert(view != nil);
    NSParameterAssert(configuration != nil);

    self = [super init];
    if (self) {
        _view = view;
        _configuration = configuration;
        _delegate = delegate;
        _gate = [[OmodachiMediaLifecycleGate alloc] init];
        _ownerQueue = [[NSOperationQueue alloc] init];
        _ownerQueue.maxConcurrentOperationCount = 1;
        _ownerQueue.name = @"org.omodachi.media-facade.owner";
        _lifecycleState = OmodachiMediaLifecycleStateIdle;

        OmodachiEnsureOwnerLock();
        [OmodachiOwnerLock lock];
        if (OmodachiActiveOwner == nil) {
            OmodachiActiveOwner = self;
        }
        [OmodachiOwnerLock unlock];
    }
    return self;
}

// Active owner is strongly retained until invalidate's actual-stop completion.
// A forgotten invalidate leaks the owner safely rather than allowing a second
// common-c session while callbacks/decoder threads remain alive.
+ (BOOL)isProcessIdle {
    OmodachiEnsureOwnerLock();
    [OmodachiOwnerLock lock];
    OmodachiMediaFacade *owner = OmodachiActiveOwner;
    BOOL idle = owner == nil || (owner->_lifecycleState == OmodachiMediaLifecycleStateIdle && owner->_connection == nil);
    [OmodachiOwnerLock unlock];
    return idle;
}

- (BOOL)isActiveOwner
{
    OmodachiEnsureOwnerLock();
    [OmodachiOwnerLock lock];
    BOOL active = (OmodachiActiveOwner == self);
    [OmodachiOwnerLock unlock];
    return active;
}

- (BOOL)fail:(NSError **)error code:(NSInteger)code description:(NSString *)description
{
    if (error != NULL) {
        *error = [NSError errorWithDomain:OmodachiMediaLifecycleErrorDomain
                                     code:code
                                 userInfo:@{NSLocalizedDescriptionKey: description}];
    }
    return NO;
}

- (void)syncToMainQueue:(dispatch_block_t)block
{
    if ([NSThread isMainThread]) {
        block();
    }
    else {
        dispatch_sync(dispatch_get_main_queue(), block);
    }
}

- (BOOL)startWithGeneration:(uint64_t)generation error:(NSError **)error
{
    if (![self isActiveOwner]) {
        return [self fail:error code:20 description:@"another media facade owns the process-wide stock connection"];
    }
    if (_invalidated) {
        return [self fail:error code:21 description:@"media facade has been invalidated"];
    }

    NSError *gateError = nil;
    if (![_gate beginStartForGeneration:generation error:&gateError]) {
        if (error != NULL) *error = gateError;
        return NO;
    }

    _generation = generation;
    _lifecycleState = OmodachiMediaLifecycleStateStarting;
    NSAssert([NSThread isMainThread], @"Media lifecycle is main-thread owned");
    _renderer = [[VideoDecoderRenderer alloc] initWithView:_view callbacks:self
        streamAspectRatio:(float)_configuration.width / MAX(1, _configuration.height)
        useFramePacing:_configuration.useFramePacing];
    _renderer.mediaGeneration = generation;
    __weak OmodachiMediaFacade *weakSelf = self;
    _renderer.formatDescriptionHandler = ^(uint64_t gen, int width, int height, int format) {
        [weakSelf dispatchDecodedDimensionsForGeneration:gen width:width height:height videoFormat:format];
    };
    _renderer.presentationObservationHandler = ^(VideoPresentationObservation observation) {
        [weakSelf dispatchPresentationObservation:observation];
    };
    // DrDecoderSetup/DrStart own renderer setup and start exactly once.
    _connection = [[Connection alloc] initWithConfig:_configuration renderer:_renderer connectionCallbacks:self generation:generation];
    [_ownerQueue addOperation:_connection];
    return YES;
}

- (BOOL)stopWithCompletion:(OmodachiMediaCompletion)completion error:(NSError **)error {
    NSAssert([NSThread isMainThread], @"Media lifecycle is main-thread owned");
    if (![self isActiveOwner]) return [self fail:error code:20 description:@"another media owner is active"];
    if (_lifecycleState == OmodachiMediaLifecycleStateIdle) { if (completion) completion(nil); return YES; }
    if (_lifecycleState == OmodachiMediaLifecycleStateStopping) return [self fail:error code:22 description:@"media is still stopping"];
    uint64_t generation = _generation;
    if (![_gate beginStopForGeneration:generation error:error]) return NO;
    _lifecycleState = OmodachiMediaLifecycleStateStopping;
    // Release real held input while the input channel still exists, before interrupt.
    if (_inputReleaseHandler) _inputReleaseHandler(generation);
    [_connection terminateWithCompletion:^(uint64_t stoppedGeneration) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (stoppedGeneration != self->_generation || self->_lifecycleState != OmodachiMediaLifecycleStateStopping) return;
            [self finishStopForGeneration:stoppedGeneration completion:completion error:NULL];
        });
    }];
    return YES;
}

- (void)finishStopForGeneration:(uint64_t)generation
                     completion:(OmodachiMediaCompletion)completion
                          error:(NSError **)error
{
    [self syncToMainQueue:^{
        [self->_renderer stop];
    }];


    NSError *gateError = nil;
    if (![_gate completeStopForGeneration:generation inputReleased:YES error:&gateError]) {
        if (error != NULL) {
            *error = gateError;
        }
        if (completion != nil) {
            completion(gateError);
        }
        return;
    }

    _lifecycleState = OmodachiMediaLifecycleStateIdle;
    _connection = nil;
    _renderer = nil;
    if ([_delegate respondsToSelector:@selector(mediaFacade:didFinishStoppingGeneration:)]) {
        [_delegate mediaFacade:self didFinishStoppingGeneration:generation];
    }
    if (completion != nil) {
        completion(nil);
    }
}

- (BOOL)invalidateWithCompletion:(OmodachiMediaCompletion)completion error:(NSError **)error
{
    if (_invalidated) {
        if (completion != nil) {
            completion(nil);
        }
        return YES;
    }
    _invalidated = YES;

    if (_lifecycleState == OmodachiMediaLifecycleStateIdle) {
        OmodachiEnsureOwnerLock();
        [OmodachiOwnerLock lock];
        if (OmodachiActiveOwner == self) {
            OmodachiActiveOwner = nil;
        }
        [OmodachiOwnerLock unlock];
        if (completion != nil) {
            completion(nil);
        }
        return YES;
    }

    return [self stopWithCompletion:^(NSError *stopError) {
        OmodachiEnsureOwnerLock();
        [OmodachiOwnerLock lock];
        if (OmodachiActiveOwner == self) {
            OmodachiActiveOwner = nil;
        }
        [OmodachiOwnerLock unlock];
        if (completion != nil) {
            completion(stopError);
        }
    } error:error];
}

- (void)setInputReleaseHandler:(OmodachiInputReleaseHandler)handler
{
    _inputReleaseHandler = [handler copy];
}

- (BOOL)getDecodedFormatDimensions:(CGSize *)dimensions videoFormat:(int *)videoFormat
{
    if (_renderer == nil) return NO;
    return [_renderer getDecodedFormatDimensions:dimensions videoFormat:videoFormat];
}

- (BOOL)copyStreamStats:(OmodachiStreamStats *)stats
{
    NSAssert(NSThread.isMainThread, @"Stream statistics are main-thread owned");
    // `LiGetEstimatedRttInfo` is only defined between LiStartConnection and
    // LiStopConnection. Running is entered on this thread after the start
    // callback and left on this thread before terminate is issued, so it is
    // exactly that window.
    if (stats == NULL || _connection == nil || _renderer == nil
        || _lifecycleState != OmodachiMediaLifecycleStateRunning) return NO;
    video_stats_t window;
    if (![_connection getVideoStats:&window]) return NO;
    memset(stats, 0, sizeof(*stats));
    stats->windowSeconds = window.endTime - window.startTime;
    stats->totalFrames = window.totalFrames;
    stats->receivedFrames = window.receivedFrames;
    stats->networkDroppedFrames = window.networkDroppedFrames;
    stats->hostProcessingLatencyTenthsMs = window.framesWithHostProcessingLatency > 0
        ? window.totalHostProcessingLatency / window.framesWithHostProcessingLatency : 0;
    uint32_t rtt = 0, variance = 0;
    stats->rttKnown = LiGetEstimatedRttInfo(&rtt, &variance) ? YES : NO;
    stats->rttMs = rtt;
    stats->rttVarianceMs = variance;
    stats->enqueuedFrames = _renderer.enqueuedFrameCount;
    CGSize ignored;
    int format = 0;
    if ([_renderer getDecodedFormatDimensions:&ignored videoFormat:&format]) stats->videoFormat = format;
    return YES;
}

- (UIImage *)copyDisplayedFrameForGeneration:(uint64_t)generation {
    NSAssert(NSThread.isMainThread, @"Frame copy is main-thread owned");
    if (generation != _generation || !_renderer) return nil;
    return [_renderer copyDisplayedFrameForGeneration:generation];
}

- (void)setPublishesObservationEachTick:(BOOL)enabled
{
    NSAssert([NSThread isMainThread], @"Observation policy is main-thread owned");
    _renderer.publishesObservationEachTick = enabled;
}

- (VideoPresentationObservation)presentationObservation
{
    if (_renderer == nil) {
        VideoPresentationObservation observation;
        memset(&observation, 0, sizeof(observation));
        observation.generation = _generation;
        return observation;
    }
    return [_renderer presentationObservation];
}

- (void)dispatchDecodedDimensionsForGeneration:(uint64_t)generation
                                         width:(int)width
                                        height:(int)height
                                  videoFormat:(int)videoFormat
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if (generation != self->_generation || self->_lifecycleState == OmodachiMediaLifecycleStateIdle) {
            return;
        }
        if ([self->_delegate respondsToSelector:@selector(mediaFacade:didReceiveDecodedWidth:height:videoFormat:generation:)]) {
            [self->_delegate mediaFacade:self didReceiveDecodedWidth:width height:height videoFormat:videoFormat generation:generation];
        }
    });
}

- (void)dispatchPresentationObservation:(VideoPresentationObservation)observation
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if (observation.generation != self->_generation || self->_lifecycleState == OmodachiMediaLifecycleStateIdle) {
            return;
        }
        if ([self->_delegate respondsToSelector:@selector(mediaFacade:didObservePresentation:)]) {
            [self->_delegate mediaFacade:self didObservePresentation:observation];
        }
    });
}

#pragma mark - ConnectionCallbacks

- (void)connectionStarted
{
    uint64_t generation = _generation;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSError *gateError = nil;
        if (![self->_gate markRunningForGeneration:generation error:&gateError]) {
            return;
        }
        self->_lifecycleState = OmodachiMediaLifecycleStateRunning;
        if ([self->_delegate respondsToSelector:@selector(mediaFacade:didStartGeneration:)]) {
            [self->_delegate mediaFacade:self didStartGeneration:generation];
        }
    });
}

- (void)connectionTerminated:(int)errorCode
{
    uint64_t generation = _generation;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (generation != self->_generation || self->_lifecycleState == OmodachiMediaLifecycleStateStopping || self->_lifecycleState == OmodachiMediaLifecycleStateIdle) {
            return;
        }
        if ([self->_delegate respondsToSelector:@selector(mediaFacade:didTerminateUnexpectedlyForGeneration:errorCode:)]) {
            [self->_delegate mediaFacade:self didTerminateUnexpectedlyForGeneration:generation errorCode:errorCode];
        }
    });
}

- (void)stageStarting:(const char *)stageName
{
    NSString *name = stageName != NULL ? [NSString stringWithUTF8String:stageName] : @"";
    uint64_t generation = _generation;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (generation != self->_generation || self->_lifecycleState == OmodachiMediaLifecycleStateIdle) return;
        if ([self->_delegate respondsToSelector:@selector(mediaFacade:didStartStage:generation:)]) {
            [self->_delegate mediaFacade:self didStartStage:name generation:generation];
        }
    });
}

- (void)stageComplete:(const char *)stageName
{
    NSString *name = stageName != NULL ? [NSString stringWithUTF8String:stageName] : @"";
    uint64_t generation = _generation;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (generation != self->_generation || self->_lifecycleState == OmodachiMediaLifecycleStateIdle) return;
        if ([self->_delegate respondsToSelector:@selector(mediaFacade:didCompleteStage:generation:)]) {
            [self->_delegate mediaFacade:self didCompleteStage:name generation:generation];
        }
    });
}

- (void)stageFailed:(const char *)stageName withError:(int)errorCode portTestFlags:(int)portTestFlags
{
    NSString *name = stageName != NULL ? [NSString stringWithUTF8String:stageName] : @"";
    uint64_t generation = _generation;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (generation != self->_generation || self->_lifecycleState == OmodachiMediaLifecycleStateIdle) return;
        if ([self->_delegate respondsToSelector:@selector(mediaFacade:didFailStage:errorCode:portTestFlags:generation:)]) {
            [self->_delegate mediaFacade:self didFailStage:name errorCode:errorCode portTestFlags:portTestFlags generation:generation];
        }
    });
}

- (void)launchFailed:(NSString *)message { (void)message; }
- (void)rumble:(unsigned short)controllerNumber lowFreqMotor:(unsigned short)lowFreqMotor highFreqMotor:(unsigned short)highFreqMotor { (void)controllerNumber; (void)lowFreqMotor; (void)highFreqMotor; }
- (void)connectionStatusUpdate:(int)status { (void)status; }
- (void)setHdrMode:(bool)enabled { (void)enabled; }
- (void)rumbleTriggers:(uint16_t)controllerNumber leftTrigger:(uint16_t)leftTrigger rightTrigger:(uint16_t)rightTrigger { (void)controllerNumber; (void)leftTrigger; (void)rightTrigger; }
- (void)setMotionEventState:(uint16_t)controllerNumber motionType:(uint8_t)motionType reportRateHz:(uint16_t)reportRateHz { (void)controllerNumber; (void)motionType; (void)reportRateHz; }
- (void)setControllerLed:(uint16_t)controllerNumber r:(uint8_t)r g:(uint8_t)g b:(uint8_t)b { (void)controllerNumber; (void)r; (void)g; (void)b; }
- (void)videoContentShown { /* legacy enqueue/unhide only; never present proof */ }

- (void)videoFormatDescriptionReceivedForGeneration:(uint64_t)generation width:(int)width height:(int)height videoFormat:(int)videoFormat
{
    (void)generation; (void)width; (void)height; (void)videoFormat;
}

- (void)videoFrameEnqueuedForGeneration:(uint64_t)generation width:(int)width height:(int)height presentConfirmed:(BOOL)presentConfirmed
{
    // Enqueue/unhide is intentionally not a present/scanout acknowledgement.
    // The renderer already emits its best-effort ready/displayed-pixel-buffer
    // observation; preserve the callback as a legacy no-op at this boundary.
    (void)generation; (void)width; (void)height; (void)presentConfirmed;
}

@end
