#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// DUO-1. A foldable's hinge, as iOS 27.1 reports it (`UIHingeInteraction`).
/// `Unavailable` is "this device, or this OS, has no hinge to report".
typedef NS_ENUM(NSInteger, OMHingeState) {
    OMHingeStateUnavailable = 0,
    OMHingeStateClosed = 1,
    OMHingeStatePartiallyOpen = 2,
    OMHingeStateFullyOpen = 3,
};

/// Adds a hinge observer to `view` and calls `changed` with the hinge's state
/// now and on every change. Returns NO, and never calls `changed`, where the
/// SDK the App was built with or the OS it runs on has no hinge API (before
/// iOS 27.1), so a build made with Xcode 27.0 still compiles and simply sees
/// no hinge.
BOOL OMObserveHinge(UIView *view, void (^changed)(OMHingeState state));

NS_ASSUME_NONNULL_END
