#import <UIKit/UIKit.h>
#import "../Remote/OMRemoteGestures.h"
NS_ASSUME_NONNULL_BEGIN
/// Native framebuffer view; no WebView and no navigation/Panel ownership.
@interface OMVNCRemoteView : UIView <UIKeyInput>
/// Decoded framebuffer pixels and the rectangle they were drawn into.
@property(nonatomic,copy,nullable) void (^onFramePresented)(CGSize pixels, CGRect videoRect);
/// REMOTE-6. WayVNC changed the framebuffer size mid-stream. The old picture
/// stays on screen and input is held until the first complete frame at the new
/// size, which then arrives through `onFramePresented` like any other.
@property(nonatomic,copy,nullable) void (^onFramebufferResized)(CGSize from, CGSize to);
@property(nonatomic,copy,nullable) void (^onStage)(NSString *stage);
@property(nonatomic,copy,nullable) void (^onDisconnected)(NSString *reason);
@property(nonatomic,readonly) BOOL inputReady;
@property(nonatomic,readonly,nullable) UIImage *snapshotImage;
- (void)setInputEnabled:(BOOL)enabled;
/// Port is the loopback side of the existing authenticated SSH forward.
- (void)connectLoopbackPort:(uint16_t)port expectedPixels:(CGSize)pixels;
/// Call before a host resize. Retains the old image but disables inputs.
- (void)expectPixels:(CGSize)pixels;
- (void)sendKeysym:(uint32_t)keysym down:(BOOL)down;
/// A-43. The same soft keyboard as the Sunshine backend: a three-finger tap
/// toggles it, and so does the overlay button. Answers whether it is up.
- (BOOL)toggleKeyboard;
- (void)hideKeyboard;
@property(nonatomic,readonly) BOOL softwareKeyboardVisible;
/// GEST-1 §2. The same arbiter the Sunshine picture uses, so the two backends
/// cannot drift: one state machine, one set of thresholds, one alias table.
@property(nonatomic,strong,nullable) id<OMRemoteGestureArbitrating> gestureArbiter;
/// A-64. A picture gesture was recognised. The keyboard is not reported here;
/// this view toggles it itself (A-62).
@property(nonatomic,copy,nullable) void (^onGesture)(OMRemoteGesture gesture);
/// UX-2 §2, for the test that pins the latch to both backends.
@property(nonatomic,readonly) BOOL pointerPressWithheld;
- (void)sendPointerAtViewPoint:(CGPoint)point buttons:(int)buttons;
- (void)disconnect;
- (void)disconnectWithCompletion:(void (^)(void))completion;
@end
NS_ASSUME_NONNULL_END
