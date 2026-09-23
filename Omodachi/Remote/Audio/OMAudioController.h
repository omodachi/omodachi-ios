#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSNotificationName const OMAudioStateDidChange;
/// Implementation must be nonblocking, accept only its current live session,
/// and bound its queue to <= 3 frames (60 ms). No default network transport.
@protocol OMMicrophoneTransport <NSObject>
- (BOOL)isAvailableForGeneration:(uint64_t)generation;
/// Completion is asynchronous and means the server accepted begin. Capture
/// must not start before YES. Acknowledgement reports server queue acceptance,
/// never local enqueue. channelOpen=NO also reports disconnection/fatal error.
- (void)beginGeneration:(uint64_t)generation sampleRate:(NSUInteger)rate channels:(NSUInteger)channels samplesPerFrame:(NSUInteger)samples completion:(void (^)(BOOL accepted))completion acknowledgement:(void (^)(BOOL accepted, BOOL channelOpen))acknowledgement;
/// Exactly 1920 bytes mono signed int16 little endian, 48 kHz / 20 ms.
/// BOOL is CHANNEL VIABILITY ONLY: YES may mean queued OR bounded local drop.
/// NO means stop capture. Neither result reports frame delivery. Only the
/// acknowledgement callback may report server queue acceptance.
- (BOOL)acceptPCM:(NSData *)pcm generation:(uint64_t)generation sequence:(uint64_t)sequence sampleTime:(uint64_t)sampleTime;
- (void)endGeneration:(uint64_t)generation;
@end
@interface OMAudioController : NSObject
@property(class, nonatomic, readonly) OMAudioController *shared;
/// This constructor is for preference-only unit tests; never opens audio devices.
- (instancetype)initWithDefaults:(NSUserDefaults *)defaults;
- (NSDictionary<NSString *, id> *)preferencesForHost:(NSString *)host;
- (void)setPlaybackEnabled:(BOOL)enabled muted:(BOOL)muted volume:(double)volume forHost:(NSString *)host;
/// Authoritative host preference snapshot; only affects the next stream launch.
- (void)applyHostPlaybackDefault:(BOOL)enabled forHost:(NSString *)host;
- (void)sessionDidConnectGeneration:(uint64_t)generation;
- (void)playbackDeviceDidClose;
- (BOOL)hostPlaybackForHost:(NSString *)host;
- (NSDictionary<NSString *, id> *)snapshotForHost:(NSString *)host;
/// Main-thread lifecycle, invoked by the existing media client.
- (void)beginSessionForHost:(NSString *)host generation:(uint64_t)generation;
- (void)endSession;
/// Audio device thread: restores our intended session category after SDL opens.
- (BOOL)restoreAudioSession;
/// Audio decode thread. Gain/mute affects this app's PCM only.
- (void)processPlaybackPCM:(int16_t *)samples count:(NSUInteger)count;
/// No permission/capture side effects until explicitly called by a user action.
- (void)requestMicrophoneEnabled:(BOOL)enabled;
/// Stop active/pending transport on temporary inactivity; never auto-resume it.
- (void)suspendMicrophoneForInactivity;
- (void)selectInputUID:(NSString *)uid;
- (void)installMicrophoneTransport:(nullable id<OMMicrophoneTransport>)transport;
@end
NS_ASSUME_NONNULL_END
