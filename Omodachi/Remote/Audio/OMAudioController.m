#import "OMAudioController.h"
#import "OMAudioPCM.h"
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import <math.h>
NSNotificationName const OMAudioStateDidChange = @"OMAudioStateDidChange";

@implementation OMAudioController {
    NSUserDefaults *_defaults;
    NSString *_host, *_status, *_captureRoute;
    uint64_t _generation, _authorization, _sequence;
    BOOL _active, _connected, _capturing, _accepted, _transportBegun, _suspended, _tapInstalled;
    BOOL _permissionGrantedAwaitingActive;
    float _gain;
    NSTimeInterval _lastAccepted;
    AVAudioEngine *_engine;
    AVAudioConverter *_converter;
    NSMutableData *_pending;
    id<OMMicrophoneTransport> _transport;
    NSMutableArray *_observers;
}
+ (instancetype)shared {
    static OMAudioController *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [[self alloc] initWithDefaults:NSUserDefaults.standardUserDefaults]; [instance observeLifecycle]; });
    return instance;
}
- (instancetype)initWithDefaults:(NSUserDefaults *)defaults {
    if ((self = [super init])) { _defaults = defaults; _gain = 1; _status = @"off"; _observers = [NSMutableArray new]; }
    return self;
}
- (NSString *)key:(NSString *)host { return [@"remote.audio.v1." stringByAppendingString:[[host stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] lowercaseString]]; }
- (NSDictionary *)preferencesForHost:(NSString *)host {
    NSDictionary *saved = [_defaults dictionaryForKey:[self key:host]] ?: @{};
    double volume = saved[@"volume"] ? [saved[@"volume"] doubleValue] : 1;
    if (!isfinite(volume)) volume = 1;
    return @{@"enabled": saved[@"enabled"] ?: @YES, @"muted": saved[@"muted"] ?: @NO,
             @"volume": @(fmin(1, fmax(0, volume))), @"hostPlayback": saved[@"hostPlayback"] ?: @NO,
             @"hostPlaybackKnown": saved[@"hostPlaybackKnown"] ?: @NO, @"inputUID": saved[@"inputUID"] ?: @""};
}
- (void)setPlaybackEnabled:(BOOL)enabled muted:(BOOL)muted volume:(double)volume forHost:(NSString *)host {
    NSMutableDictionary *p = [[self preferencesForHost:host] mutableCopy];
    p[@"enabled"] = @(enabled); p[@"muted"] = @(muted); p[@"volume"] = @(isfinite(volume) ? fmin(1, fmax(0, volume)) : 1);
    [_defaults setObject:p forKey:[self key:host]];
    @synchronized(self) { if ([[self key:_host ?: @""] isEqual:[self key:host]]) _gain = enabled && !muted ? [p[@"volume"] floatValue] : 0; }
    [self changed];
}
- (void)applyHostPlaybackDefault:(BOOL)enabled forHost:(NSString *)host {
    NSMutableDictionary *p = [[self preferencesForHost:host] mutableCopy]; p[@"hostPlayback"] = @(enabled); p[@"hostPlaybackKnown"] = @YES; [_defaults setObject:p forKey:[self key:host]]; [self changed];
}
- (void)sessionDidConnectGeneration:(uint64_t)generation { @synchronized(self) { if (_active && _generation == generation) _connected = YES; } [self changed]; }
- (void)playbackDeviceDidClose {
    uint64_t authorization; @synchronized(self) { authorization = _authorization; }
    dispatch_async(dispatch_get_main_queue(), ^{ if (!self->_capturing && authorization == self->_authorization) [AVAudioSession.sharedInstance setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil]; });
}
- (BOOL)hostPlaybackForHost:(NSString *)host { return [[self preferencesForHost:host][@"hostPlayback"] boolValue]; }
- (void)changed { dispatch_async(dispatch_get_main_queue(), ^{ [NSNotificationCenter.defaultCenter postNotificationName:OMAudioStateDidChange object:self]; }); }
- (NSDictionary *)snapshotForHost:(NSString *)host {
    AVAudioSession *session = AVAudioSession.sharedInstance;
    NSMutableArray *inputs = [NSMutableArray new];
    // Only enumerate available recording routes after explicit capture activation.
    if (_capturing) for (AVAudioSessionPortDescription *p in session.availableInputs) [inputs addObject:@{@"uid": p.UID, @"name": p.portName}];
    NSString *output = [[session.currentRoute.outputs valueForKey:@"portName"] componentsJoinedByString:@", "];
    @synchronized(self) {
        BOOL current = _active && [[self key:host] isEqual:[self key:_host ?: @""]];
        BOOL recent = _accepted && NSProcessInfo.processInfo.systemUptime - _lastAccepted < 0.25;
        return @{@"active": @(current), @"capturing": @(current && _capturing), @"accepted": @(current && recent),
                 @"microphoneAvailable": @(current && _connected && [_transport isAvailableForGeneration:_generation]),
                 @"status": current ? ([_status isEqual:@"transport-accepted"] && !recent ? @"waiting-for-accepted-frame" : _status) : @"off", @"output": output.length ? output : @"System default", @"inputs": inputs};
    }
}
- (void)beginSessionForHost:(NSString *)host generation:(uint64_t)generation {
    NSAssert(NSThread.isMainThread, @"Audio lifecycle uses main thread");
    [self endSession];
    NSDictionary *p = [self preferencesForHost:host];
    @synchronized(self) { _host = [host copy]; _generation = generation; _active = YES; _connected = NO; _suspended = NO; _gain = [p[@"enabled"] boolValue] && ![p[@"muted"] boolValue] ? [p[@"volume"] floatValue] : 0; }
    [self changed];
}
- (void)endSession {
    [self stopMicrophone:@"off"];
    @synchronized(self) { _active = NO; _connected = NO; _gain = 0; _host = nil; _generation = 0; }
    [self changed];
}
- (void)processPlaybackPCM:(int16_t *)samples count:(NSUInteger)count {
    float gain;
    @synchronized(self) { gain = _suspended ? 0 : _gain; }
    OMAudioApplyGain(samples, count, gain);
}
- (BOOL)restoreAudioSession {
    BOOL capture;
    @synchronized(self) { capture = _capturing; }
    AVAudioSession *session = AVAudioSession.sharedInstance;
    NSError *error;
    BOOL ok = [session setCategory:capture ? AVAudioSessionCategoryPlayAndRecord : AVAudioSessionCategoryPlayback
                         mode:capture ? AVAudioSessionModeVoiceChat : AVAudioSessionModeDefault
                      options:capture ? AVAudioSessionCategoryOptionAllowBluetoothHFP : AVAudioSessionCategoryOptionMixWithOthers error:&error];
    if (ok) ok = [session setActive:YES error:&error];
    if (!ok) dispatch_async(dispatch_get_main_queue(), ^{ [self stopMicrophone:@"audio-session-error"]; });
    return ok;
}
- (void)installMicrophoneTransport:(id<OMMicrophoneTransport>)transport {
    NSAssert(NSThread.isMainThread, @"Transport lifecycle uses main thread");
    [self stopMicrophone:@"off"]; _transport = transport; [self changed];
}
- (NSString *)routeSignature {
    AVAudioSessionRouteDescription *route = AVAudioSession.sharedInstance.currentRoute;
    return [NSString stringWithFormat:@"%@|%@", [[route.inputs valueForKey:@"UID"] componentsJoinedByString:@","], [[route.outputs valueForKey:@"UID"] componentsJoinedByString:@","]];
}
- (BOOL)headphoneOutput {
    for (AVAudioSessionPortDescription *p in AVAudioSession.sharedInstance.currentRoute.outputs) {
        if ([p.portType isEqual:AVAudioSessionPortHeadphones] || [p.portType isEqual:AVAudioSessionPortBluetoothHFP] || [p.portType isEqual:AVAudioSessionPortBluetoothA2DP]) return YES;
    }
    return NO;
}
- (void)requestMicrophoneEnabled:(BOOL)enabled {
    NSAssert(NSThread.isMainThread, @"Microphone user actions use main thread");
    if (!enabled) { [self stopMicrophone:@"off"]; return; }
    if (_capturing || [_status isEqual:@"permission-pending"] || [_status isEqual:@"transport-pending"]) return;
    if (!_active || !_connected || ![_transport isAvailableForGeneration:_generation]) { _status = @"host-uplink-unavailable"; [self changed]; return; }
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    // SDL downlink is not in AVAudioEngine's voice-processing reference path.
    // Until physical AEC evidence exists, never allow built-in-speaker duplex.
    if (![self headphoneOutput]) { _status = @"headphones-required"; [self changed]; return; }
    uint64_t request = ++_authorization, generation = _generation;
    _permissionGrantedAwaitingActive = NO;
    _status = @"permission-pending"; [self changed];
    [AVAudioApplication requestRecordPermissionWithCompletionHandler:^(BOOL granted) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (request != self->_authorization || generation != self->_generation || !self->_active) return;
            if (!granted) { self->_status = @"permission-denied"; [self changed]; return; }
            // Permission UI can finish while the app is still inactive. Keep
            // only this explicit, current user request; no audio channel exists.
            if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) { self->_permissionGrantedAwaitingActive = YES; return; }
            [self beginMicrophoneTransport];
        });
    }];
}
- (void)suspendMicrophoneForInactivity {
    if (_capturing || _transportBegun) [self stopMicrophone:@"interrupted-enable-again"];
    // A permission-only request has no capture or host sink to pause. Its
    // callback remains fenced by authorization/generation and active app state.
}
- (void)beginMicrophoneTransport {
    if (!_active || !_connected || UIApplication.sharedApplication.applicationState != UIApplicationStateActive || ![_transport isAvailableForGeneration:_generation] || ![self headphoneOutput]) { [self stopMicrophone:@"host-or-route-unavailable"]; return; }
    _permissionGrantedAwaitingActive = NO;
    uint64_t request = _authorization, generation = _generation;
    _transportBegun = YES; _status = @"transport-pending"; [self changed];
    __weak OMAudioController *weak = self;
    [_transport beginGeneration:generation sampleRate:48000 channels:1 samplesPerFrame:960 completion:^(BOOL accepted) {
        dispatch_async(dispatch_get_main_queue(), ^{
            OMAudioController *self = weak;
            if (!self || request != self->_authorization || generation != self->_generation || !self->_active) return;
            if (!accepted || UIApplication.sharedApplication.applicationState != UIApplicationStateActive) { [self stopMicrophone:@"host-uplink-unavailable"]; return; }
            [self startMicrophone];
        });
    } acknowledgement:^(BOOL accepted, BOOL channelOpen) {
        dispatch_async(dispatch_get_main_queue(), ^{
            OMAudioController *self = weak;
            if (!self || request != self->_authorization || generation != self->_generation || !self->_active) return;
            if (!channelOpen) { [self stopMicrophone:@"transport-rejected"]; return; }
            if (!accepted) { @synchronized(self) { self->_accepted = NO; self->_status = @"waiting-for-accepted-frame"; } [self changed]; return; }
            if (!self->_capturing) return;
            @synchronized(self) { self->_accepted = YES; self->_lastAccepted = NSProcessInfo.processInfo.systemUptime; self->_status = @"transport-accepted"; }
            [self changed];
        });
    }];
}
- (void)startMicrophone {
    if (![_transport isAvailableForGeneration:_generation] || ![self headphoneOutput]) { [self stopMicrophone:@"host-or-route-unavailable"]; return; }
    @synchronized(self) { _capturing = YES; _accepted = NO; _sequence = 0; }
    if (![self restoreAudioSession]) { [self stopMicrophone:@"audio-session-error"]; return; }
    NSString *uid = [self preferencesForHost:_host][@"inputUID"];
    if (uid.length) for (AVAudioSessionPortDescription *port in AVAudioSession.sharedInstance.availableInputs) if ([port.UID isEqual:uid]) [AVAudioSession.sharedInstance setPreferredInput:port error:nil];
    if (![self headphoneOutput]) { [self stopMicrophone:@"headphones-required"]; return; }
    _engine = [AVAudioEngine new];
    AVAudioInputNode *input = _engine.inputNode;
    // Voice processing is optional protection, not a claim of SDL echo cancellation.
    NSError *error;
    if (![input setVoiceProcessingEnabled:YES error:&error]) { [self stopMicrophone:@"voice-processing-unavailable"]; return; }
    if (![self headphoneOutput]) { [self stopMicrophone:@"headphones-required"]; return; }
    AVAudioFormat *source = [input outputFormatForBus:0];
    AVAudioFormat *target = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatInt16 sampleRate:48000 channels:1 interleaved:YES];
    if (source.sampleRate <= 0 || source.channelCount == 0) { [self stopMicrophone:@"input-unavailable"]; return; }
    _converter = [[AVAudioConverter alloc] initFromFormat:source toFormat:target];
    _pending = [NSMutableData new];
    if (!_converter) { [self stopMicrophone:@"conversion-failed"]; return; }
    uint64_t authorization = _authorization, generation = _generation;
    __weak OMAudioController *weak = self;
    [input installTapOnBus:0 bufferSize:960 format:source block:^(AVAudioPCMBuffer *buffer, AVAudioTime *when) {
        [weak consumeBuffer:buffer authorization:authorization generation:generation];
    }];
    _tapInstalled = YES;
    [_engine prepare];
    if (![_engine startAndReturnError:&error]) { [self stopMicrophone:@"capture-start-failed"]; return; }
    _captureRoute = [self routeSignature];
    _status = @"waiting-for-accepted-frame"; [self changed];
}
- (void)consumeBuffer:(AVAudioPCMBuffer *)buffer authorization:(uint64_t)authorization generation:(uint64_t)generation {
    // Audio tap is serial. The lock prevents a frame crossing session revocation.
    @synchronized(self) {
        if (!_capturing || authorization != _authorization || !_active) return;
        NSUInteger capacity = (NSUInteger)ceil(buffer.frameLength * 48000.0 / buffer.format.sampleRate) + 32;
        if (capacity > 16384) return; // bounded allocation for an unexpected route format
        AVAudioPCMBuffer *out = [[AVAudioPCMBuffer alloc] initWithPCMFormat:_converter.outputFormat frameCapacity:(AVAudioFrameCount)capacity];
        __block BOOL supplied = NO;
        NSError *error;
        AVAudioConverterOutputStatus result = [_converter convertToBuffer:out error:&error withInputFromBlock:^AVAudioBuffer *(AVAudioPacketCount count, AVAudioConverterInputStatus *status) {
            if (supplied) { *status = AVAudioConverterInputStatus_NoDataNow; return nil; }
            supplied = YES; *status = AVAudioConverterInputStatus_HaveData; return buffer;
        }];
        if (result == AVAudioConverterOutputStatus_Error || error) { dispatch_async(dispatch_get_main_queue(), ^{ if (authorization == self->_authorization) [self stopMicrophone:@"conversion-failed"]; }); return; }
        [_pending appendBytes:out.int16ChannelData[0] length:out.frameLength * 2];
        while (_pending.length >= 1920) {
            NSData *frame = [_pending subdataWithRange:NSMakeRange(0, 1920)];
            [_pending replaceBytesInRange:NSMakeRange(0, 1920) withBytes:NULL length:0];
            uint64_t seq = _sequence++;
            if (!OMAudioValidPCMFrame(frame.length, generation, _generation, _active && _capturing)) return;
            BOOL channelViable = [_transport acceptPCM:frame generation:_generation sequence:seq sampleTime:seq * 960];
            if (!channelViable) { _accepted = NO; _capturing = NO; dispatch_async(dispatch_get_main_queue(), ^{ if (authorization == self->_authorization) [self stopMicrophone:@"transport-rejected"]; }); return; }
            // A viable channel may deliberately drop this frame. Only the asynchronous
            // transport acknowledgement may update accepted/lastAccepted.
        }
    }
}
- (void)stopMicrophone:(NSString *)status {
    AVAudioEngine *engine; BOOL hadCapture;
    @synchronized(self) { hadCapture = _capturing || _engine != nil; ++_authorization; _permissionGrantedAwaitingActive = NO; _capturing = NO; _accepted = NO; engine = _engine; _engine = nil; _status = status; }
    if (engine) { [engine stop]; if (_tapInstalled) [engine.inputNode removeTapOnBus:0]; }
    _tapInstalled = NO;
    @synchronized(self) {
        if (_transportBegun) [_transport endGeneration:_generation];
        _transportBegun = NO; _converter = nil; _pending = nil;
    }
    if (hadCapture && _active) [self restoreAudioSession];
    [self changed];
}
- (void)selectInputUID:(NSString *)uid {
    if (!_capturing || !_host) return;
    for (AVAudioSessionPortDescription *port in AVAudioSession.sharedInstance.availableInputs) if ([port.UID isEqual:uid]) {
        NSMutableDictionary *p = [[self preferencesForHost:_host] mutableCopy]; p[@"inputUID"] = uid; [_defaults setObject:p forKey:[self key:_host]];
        [self stopMicrophone:@"input-changed-enable-again"]; [self changed]; return;
    }
}
- (void)observeLifecycle {
    __weak OMAudioController *weak = self;
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    for (NSNotificationName name in @[AVAudioSessionInterruptionNotification, AVAudioSessionRouteChangeNotification, AVAudioSessionMediaServicesWereResetNotification, UIApplicationDidEnterBackgroundNotification]) {
        id observer = [center addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            OMAudioController *self = weak; if (!self) return;
            BOOL route = [note.name isEqual:AVAudioSessionRouteChangeNotification];
            // Category changes during our explicit activation are expected.
            if (route && self->_capturing && [self->_captureRoute isEqual:[self routeSignature]]) { [self changed]; return; }
            if (route && [note.userInfo[AVAudioSessionRouteChangeReasonKey] unsignedIntegerValue] == AVAudioSessionRouteChangeReasonCategoryChange) { [self changed]; return; }
            if ([note.name isEqual:AVAudioSessionInterruptionNotification] && [note.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue] == AVAudioSessionInterruptionTypeEnded) {
                @synchronized(self) { self->_suspended = NO; } if (self->_active) [self restoreAudioSession]; [self changed]; return;
            }
            if (!route) @synchronized(self) { self->_suspended = YES; }
            [self stopMicrophone:route ? @"route-changed-enable-again" : @"interrupted-enable-again"];
        }];
        [_observers addObject:observer];
    }
    [_observers addObject:[center addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
        OMAudioController *self = weak; if (!self) return;
        @synchronized(self) { self->_suspended = NO; }
        if (self->_active) [self restoreAudioSession];
        if (self->_permissionGrantedAwaitingActive && self->_active && self->_connected && [self->_status isEqual:@"permission-pending"]) [self beginMicrophoneTransport];
        [self changed];
    }]];
}
- (void)dealloc { for (id observer in _observers) [NSNotificationCenter.defaultCenter removeObserver:observer]; }
@end
