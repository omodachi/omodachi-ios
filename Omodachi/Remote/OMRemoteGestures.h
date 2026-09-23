#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
NS_ASSUME_NONNULL_BEGIN

/// A-64 / A-62 / N-37. Everything three fingers on the picture can mean.
///
/// Study 04 §13 gives the picture's gestures to the picture: three fingers
/// left / right are the neighbouring workspace, up is the scratchpad, a pinch
/// is full screen, and one or two fingers are always the pointer. The
/// four-finger row is deleted (rev 5, review #23) because iPadOS owns it.
/// The keyboard tap (A-62) is in this list because it is decided by the same
/// arbiter — a swipe that also toggled the keyboard is the bug this enum
/// exists to make impossible.
typedef NS_ENUM(NSInteger, OMRemoteGesture) {
    OMRemoteGestureNone = 0,
    /// A-62. Local: it never goes to the host and is never "registered".
    OMRemoteGestureKeyboard = 1,
    OMRemoteGestureWorkspaceNext = 2,
    OMRemoteGestureWorkspacePrevious = 3,
    OMRemoteGestureScratchpad = 4,
    OMRemoteGestureFullScreen = 5,
};

typedef NS_ENUM(NSInteger, OMRemoteTouchPhase) {
    OMRemoteTouchPhaseBegan = 0,
    OMRemoteTouchPhaseMoved = 1,
    OMRemoteTouchPhaseEnded = 2,
    OMRemoteTouchPhaseCancelled = 3,
};

/// The one arbiter of what a touch cycle on the picture means.
///
/// GEST-1 §2: both backends own one and neither decides anything itself. The
/// Objective-C views only report touches and ask; the state machine, the
/// thresholds and the alias resolution are Swift
/// (`Remote/RemoteGesturePolicy.swift`), which is also the only thing under
/// test.
@protocol OMRemoteGestureArbitrating <NSObject>
/// N-37. Which of the four picture gestures the host has a row for right now.
/// `OMRemoteGestureKeyboard` is never in this set: it is this device's own
/// switch and does not resolve to anything on the host.
- (void)updateRegisteredGestures:(NSArray<NSNumber *> *)gestures
    NS_SWIFT_NAME(updateRegistered(gestures:));
/// One touch report. `coordinates` is x0, y0, x1, y1 … for every finger that
/// is still down, in the view's own points; `timestamp` is `UIEvent.timestamp`.
/// Answers the gesture this report *claimed*, once, or `None`.
- (OMRemoteGesture)reportPhase:(OMRemoteTouchPhase)phase
                   coordinates:(NSArray<NSNumber *> *)coordinates
                     timestamp:(double)timestamp
    NS_SWIFT_NAME(report(phase:coordinates:timestamp:));
/// UX-2 §2's latch, for both backends. NO for the rest of the cycle as soon as
/// a second finger appears, so a deferred single-finger press can never outlive
/// the multi-finger gesture that disqualified it.
@property(nonatomic, readonly) BOOL singleTouchAllowed;
/// A-62. Whether the cycle the keyboard tap recogniser just recognised really
/// was a tap and not the tail of a swipe or a pinch.
@property(nonatomic, readonly) BOOL keyboardTapConfirmed;
@end

NS_ASSUME_NONNULL_END
