#import "Audio/OMAudioController.h"
#import "OMRemoteGestures.h"
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
NS_ASSUME_NONNULL_BEGIN
typedef void (^OMRemoteEventHandler)(NSString *json);
/// UIKit input carries the identity captured when the gesture/key began.
/// The receiver translates events; OMRemoteClient remains the sole C sender.
@protocol OMRemoteInputReceiver <NSObject>
- (void)updateViewport:(CGSize)viewport videoRect:(CGRect)rect streamPixels:(CGSize)pixels NS_SWIFT_NAME(update(viewport:videoRect:streamPixels:));
- (void)activateGeneration:(uint64_t)generation geometryEpoch:(uint64_t)epoch leaseSerial:(uint64_t)serial NS_SWIFT_NAME(activate(generation:geometryEpoch:leaseSerial:));
- (void)deactivateGeneration:(uint64_t)generation geometryEpoch:(uint64_t)epoch leaseSerial:(uint64_t)serial NS_SWIFT_NAME(deactivate(generation:geometryEpoch:leaseSerial:));
- (void)pointerPhase:(NSInteger)phase point:(CGPoint)point generation:(uint64_t)generation geometryEpoch:(uint64_t)epoch leaseSerial:(uint64_t)serial NS_SWIFT_NAME(pointer(phase:point:generation:geometryEpoch:leaseSerial:));
- (void)hardwarePointerPhase:(NSInteger)phase button:(NSInteger)button point:(CGPoint)point generation:(uint64_t)generation geometryEpoch:(uint64_t)epoch leaseSerial:(uint64_t)serial NS_SWIFT_NAME(hardwarePointer(phase:button:point:generation:geometryEpoch:leaseSerial:));
- (void)touchpadPhase:(NSInteger)phase point:(CGPoint)point generation:(uint64_t)generation geometryEpoch:(uint64_t)epoch leaseSerial:(uint64_t)serial NS_SWIFT_NAME(touchpad(phase:point:generation:geometryEpoch:leaseSerial:));
- (void)scrollPhase:(NSInteger)phase delta:(CGPoint)delta generation:(uint64_t)generation geometryEpoch:(uint64_t)epoch leaseSerial:(uint64_t)serial NS_SWIFT_NAME(scroll(phase:delta:generation:geometryEpoch:leaseSerial:));
- (void)latchModifiers:(unsigned char)mask generation:(uint64_t)generation geometryEpoch:(uint64_t)epoch leaseSerial:(uint64_t)serial NS_SWIFT_NAME(latch(modifiers:generation:geometryEpoch:leaseSerial:));
- (void)clickButton:(NSInteger)button generation:(uint64_t)generation geometryEpoch:(uint64_t)epoch leaseSerial:(uint64_t)serial NS_SWIFT_NAME(click(button:generation:geometryEpoch:leaseSerial:));
- (void)keyUsage:(unsigned short)usage down:(BOOL)down generation:(uint64_t)generation geometryEpoch:(uint64_t)epoch leaseSerial:(uint64_t)serial NS_SWIFT_NAME(key(usage:down:generation:geometryEpoch:leaseSerial:));
- (void)cancelInputsGeneration:(uint64_t)generation geometryEpoch:(uint64_t)epoch leaseSerial:(uint64_t)serial NS_SWIFT_NAME(cancel(generation:geometryEpoch:leaseSerial:));
- (void)insertText:(NSString *)text generation:(uint64_t)generation geometryEpoch:(uint64_t)epoch leaseSerial:(uint64_t)serial NS_SWIFT_NAME(text(_:generation:geometryEpoch:leaseSerial:));
@end

@class OMRemoteRenderView;

@interface OMRemoteClient : NSObject
@property(nonatomic, readonly) OMRemoteRenderView *renderView;
@property(nonatomic, copy, nullable) OMRemoteEventHandler eventHandler;
/// UX-2 §2 / A-59. Who asked for a panel from inside the picture. The only
/// callers left are the two hardware aliases and VoiceOver's custom action —
/// no touch gesture summons anything (A-62).
@property(nonatomic, copy, nullable) void (^panelHandler)(NSString *source);
/// UX-2 §2 / A-62. What the three-finger tap did to the keyboard, so the bar's
/// keyboard quick action reports the keyboard that is actually on screen
/// rather than the last one it was asked for.
@property(nonatomic, copy, nullable) void (^keyboardHandler)(BOOL visible);
/// GEST-1 / A-64. The arbiter of what three fingers on the picture mean. Set
/// by the backend driver; without one the picture has the pointer gestures and
/// the keyboard tap it always had.
@property(nonatomic, strong, nullable) id<OMRemoteGestureArbitrating> gestureArbiter;
/// A-64. One of the picture's own gestures was recognised. The keyboard is not
/// reported here — it has `keyboardHandler`, because it is this device's own
/// switch and resolves to nothing on the host (A-62).
@property(nonatomic, copy, nullable) void (^gestureHandler)(OMRemoteGesture gesture);
@property(nonatomic, readonly) BOOL idle;
@property(nonatomic, readonly) BOOL inputReady;
@property(nonatomic, readonly) BOOL supportsNativeTouch;
@property(nonatomic, readonly) BOOL softwareKeyboardRequested;
@property(nonatomic) BOOL touchpadMode;
/// The Sunshine app the managed fork publishes for the owned output, taken from
/// the host connection document rather than guessed.
@property(nonatomic, copy) NSString *appTitle;
/// 0 keeps Moonlight's default ports.
@property(nonatomic) int httpsPort;
@property(nonatomic, readonly) uint64_t generation;
@property(nonatomic, readonly) uint64_t leaseSerial;
@property(nonatomic, readonly) uint64_t geometryEpoch;
@property(nonatomic, weak, nullable) id<OMRemoteInputReceiver> inputReceiver;
- (instancetype)initWithHost:(NSString *)host;
/// Lowercase SHA-256 of this app's existing client public certificate in DER.
/// Reads the same public certificate used by the existing media client. Does
/// not generate/replace identity or read a private key/host certificate.
- (nullable NSString *)currentClientCertificateSHA256 NS_SWIFT_NAME(currentClientCertificateSHA256());
- (BOOL)beginLease;
- (void)inspectHost;
- (void)pairHost;
/// `renewing` asks for the certificate exchange even when the fork already
/// holds this client's certificate. The fork can hold it while the host holds
/// no binding for this device; Moonlight would then answer `alreadyPaired`
/// without ever issuing `getservercert`, so nothing would appear for the
/// operator to approve. Sunshine exposes no unpair on its streaming ports, so
/// asking anyway is the only way to make that request exist.
- (void)pairHostRenewing:(BOOL)renewing;
/// `codec` is the session profile's (`h264` or `hevc`); exactly that one is
/// offered to the host. While the stream runs a `stats` event is emitted once
/// a second (STREAM-1).
- (void)startWidth:(int)width height:(int)height fps:(int)fps bitrate:(int)bitrate codec:(NSString *)codec generation:(uint64_t)generation NS_SWIFT_NAME(start(width:height:fps:bitrate:codec:generation:));
- (void)stopWithCompletion:(void (^)(BOOL stopped))completion;
/// INPUT-2: the standing want. It is remembered and re-applied whenever any of
/// the six conditions moves, so a want expressed before the last one arrived is
/// honoured when it does. `generation` only discards a want for another session.
- (void)setInputEnabled:(BOOL)enabled generation:(uint64_t)generation;
/// The gate's whole decision as a pure function of its inputs, exposed so the
/// order the conditions arrive in can be tested without a media stack.
+ (BOOL)inputAllowedForDesired:(BOOL)desired geometryReady:(BOOL)geometryReady lifecycle:(NSInteger)lifecycle
                     connected:(BOOL)connected frameReported:(BOOL)frameReported stopping:(BOOL)stopping hasMedia:(BOOL)hasMedia
    NS_SWIFT_NAME(inputAllowed(desired:geometryReady:lifecycle:connected:frameReported:stopping:hasMedia:));
- (void)setGeometryEpoch:(uint64_t)epoch generation:(uint64_t)generation;
/// Operator-only (DEBUG, Simulator, explicit launch argument): pretend the host
/// advertises no pen/touch events, so a direct-touch tap takes the absolute
/// pointer path instead of the native touch one. It exists because
/// `hyprctl cursorpos` follows the pointer and not the touchscreen, so the
/// INPUT-1 landing measurement cannot otherwise be repeated from the client.
@property(nonatomic) BOOL forcesAbsolutePointer;
- (void)sendTouchPhase:(NSInteger)phase x:(int)x y:(int)y width:(int)width height:(int)height generation:(uint64_t)generation geometryEpoch:(uint64_t)epoch leaseSerial:(uint64_t)serial NS_SWIFT_NAME(sendTouch(phase:x:y:width:height:generation:geometryEpoch:leaseSerial:));
- (void)sendAbsoluteX:(int)x y:(int)y width:(int)width height:(int)height generation:(uint64_t)generation geometryEpoch:(uint64_t)epoch leaseSerial:(uint64_t)serial NS_SWIFT_NAME(sendAbsolute(x:y:width:height:generation:geometryEpoch:leaseSerial:));
- (void)sendRelativeX:(int)x y:(int)y generation:(uint64_t)generation geometryEpoch:(uint64_t)epoch leaseSerial:(uint64_t)serial NS_SWIFT_NAME(sendRelative(x:y:generation:geometryEpoch:leaseSerial:));
- (void)sendButton:(int)button down:(BOOL)down generation:(uint64_t)generation geometryEpoch:(uint64_t)epoch leaseSerial:(uint64_t)serial NS_SWIFT_NAME(sendButton(_:down:generation:geometryEpoch:leaseSerial:));
- (void)sendKey:(unsigned short)key down:(BOOL)down modifiers:(unsigned char)modifiers generation:(uint64_t)generation geometryEpoch:(uint64_t)epoch leaseSerial:(uint64_t)serial NS_SWIFT_NAME(sendKey(_:down:modifiers:generation:geometryEpoch:leaseSerial:));
- (void)sendTextData:(NSData *)data generation:(uint64_t)generation geometryEpoch:(uint64_t)epoch leaseSerial:(uint64_t)serial NS_SWIFT_NAME(sendText(_:generation:geometryEpoch:leaseSerial:));
- (void)releaseHeldGeneration:(uint64_t)generation geometryEpoch:(uint64_t)epoch leaseSerial:(uint64_t)serial NS_SWIFT_NAME(releaseHeld(generation:geometryEpoch:leaseSerial:));
- (void)observeCurrentFrame;
/// Ordinary media frame retention only; no disk write or external capture.
- (nullable UIImage *)copyDisplayedFrame NS_SWIFT_NAME(copyDisplayedFrame());
/// Close the local input latch until a new visible-frame geometry is observed.
- (void)invalidateViewportGeometry;
- (void)showKeyboard;
/// A-43. The soft keyboard is a toggle, not a one-way door: the same three
/// finger tap and the same overlay button put it away again. Answers whether
/// the keyboard is up afterwards, so the controller can publish it.
- (BOOL)toggleKeyboard;
- (void)hideKeyboard;
- (void)latchModifierMask:(unsigned char)mask;
- (void)sendShortcutUsage:(unsigned short)usage;
- (void)sendScrollVertical:(short)vertical horizontal:(short)horizontal generation:(uint64_t)generation geometryEpoch:(uint64_t)epoch leaseSerial:(uint64_t)serial NS_SWIFT_NAME(sendScroll(vertical:horizontal:generation:geometryEpoch:leaseSerial:));
- (void)releaseInputs;
@end
/// The view the stream is drawn into, and the only thing in this app that takes
/// UIKit input for it.
///
/// REMOTE-2 item 3 exposes the keyboard half here. Raising the soft keyboard
/// takes two things — a live session (`keyboardAllowed`) and a view UIKit will
/// actually make first responder — and MERGE-1 §6.3 could only see the first,
/// because `presentSoftwareKeyboard:` ignored what `becomeFirstResponder`
/// answered and reported success either way. With both readable the rule is
/// assertable against a real window and no media stack.
@interface OMRemoteRenderView : UIView
/// A-43: whether there is a session to type into. This is *not* the input gate
/// — the overlay's keyboard button is pressed while the overlay is open, and
/// the overlay being open is exactly what closes that gate.
@property(nonatomic) BOOL keyboardAllowed;
/// Whether the soft keyboard is up. Never a want: it is what UIKit did.
@property(nonatomic, readonly) BOOL softwareKeyboard;
/// Raise or dismiss it; answers with the state actually reached.
- (BOOL)presentSoftwareKeyboard:(BOOL)wanted;
/// A-43: three fingers, Moonlight's convention. The two-finger right click is
/// required to fail before it, or a third finger landing a frame late reads as
/// a right click.
@property(nonatomic, readonly) UITapGestureRecognizer *keyboardTap;
@property(nonatomic, readonly) UITapGestureRecognizer *rightClickTap;
@end

NS_ASSUME_NONNULL_END
