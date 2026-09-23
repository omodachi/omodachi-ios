#import "OMVNCRemoteView.h"
#import "OMVNCClient.h"

@interface OMVNCWorker : NSObject
@property(nonatomic) OMVNCClient *client;
@property(nonatomic) dispatch_queue_t queue;
@property(nonatomic) BOOL stopped;
@property(nonatomic,weak) OMVNCRemoteView *view;
- (void)pump;
- (void)stop;
@end
@interface OMVNCRemoteView ()
@property(nonatomic) UIImageView *imageView;
@property(nonatomic) OMVNCWorker *worker;
@property(nonatomic) CGSize expectedPixels;
@property(nonatomic) CGSize framePixels;
/// The size the server says it is serving right now, which after a mid-stream
/// resize runs ahead of `framePixels` until the next complete frame lands.
@property(nonatomic) CGSize serverPixels;
@property(nonatomic,readwrite) BOOL inputReady;
@property(nonatomic) BOOL frameComplete;
@property(nonatomic) BOOL inputAuthorized;
@property(nonatomic) CGPoint lastTouch;
/// UX-2 §2, brought to this backend. Before GEST-1 this view sent a button
/// down from the first line of `touchesBegan`, so a three-finger gesture put
/// three real clicks on the host's desktop — including on the host's own bar.
@property(nonatomic,weak) UITouch *trackedTouch;
@property(nonatomic) CGPoint touchOrigin;
@property(nonatomic) BOOL pendingPress;
@property(nonatomic) BOOL pressSent;
@property(nonatomic) BOOL multiTouchSeen;
@property(nonatomic) uint64_t gestureRevision;
@property(nonatomic) CADisplayLink *firstFrameLink;
@end

/// REMOTE-6. LibVNCClient reallocated for a new server framebuffer size. This
/// runs on the decode queue, so the view is touched on the main queue only.
static void resized(void *context,int width,int height) {
    OMVNCWorker *worker=(__bridge OMVNCWorker *)context;
    dispatch_async(dispatch_get_main_queue(), ^{
        OMVNCRemoteView *view=worker.view;
        if(!view||view.worker!=worker)return;
        CGSize next=CGSizeMake(width,height);
        if(CGSizeEqualToSize(view.serverPixels,next))return;
        CGSize previous=view.serverPixels;
        view.serverPixels=next;
        // Everything the view knows about geometry is about to be one size
        // behind the server: `framePixels` still describes the image on screen
        // and `videoRect` is still computed from it, so a pointer mapped now
        // would land at half the intended place. Hold input until the first
        // complete frame at the new size re-runs the presentation tick.
        if(previous.width>0){
            [view.firstFrameLink invalidate];view.firstFrameLink=nil;
            view.frameComplete=NO;view.inputReady=NO;
            OMVNCWorker *held=view.worker;
            if(held)dispatch_async(held.queue, ^{om_vnc_release_inputs(held.client);});
            if(view.onStage)view.onStage(@"framebuffer_resized");
        }
        // Reported either way, including the opening announcement (`from` is
        // zero for that one). WayVNC usually corrects itself before the first
        // frame is ever on screen, so the size it opened at is a size nobody
        // sees — and then this is the only record that it happened at all.
        if(view.onFramebufferResized)view.onFramebufferResized(previous,next);
    });
}

static void frame(void *context,const uint8_t *bytes,int width,int height) {
    OMVNCWorker *worker=(__bridge OMVNCWorker *)context;
    NSData *data=[NSData dataWithBytes:bytes length:(NSUInteger)width*height*4];
    CGDataProviderRef provider=CGDataProviderCreateWithCFData((__bridge CFDataRef)data);
    CGColorSpaceRef color=CGColorSpaceCreateDeviceRGB();
    CGImageRef image=CGImageCreate(width,height,8,32,width*4,color,kCGBitmapByteOrder32Big|kCGImageAlphaLast,provider,NULL,false,kCGRenderingIntentDefault);
    UIImage *uiImage=[UIImage imageWithCGImage:image];
    CGImageRelease(image);CGColorSpaceRelease(color);CGDataProviderRelease(provider);
    dispatch_async(dispatch_get_main_queue(), ^{
        OMVNCRemoteView *view=worker.view;
        if(!view||view.worker!=worker)return;
        // REMOTE-6. WayVNC shows a client two sizes: the compositor's logical
        // size in ServerInit and the owned output's buffer pixels from the
        // first NewFBSize rect onwards. `expectedPixels` is the larger of the
        // two the host named, so it stays a ceiling and never a prediction —
        // a frame bigger than the output itself is still a protocol error.
        if(view.expectedPixels.width>0&&(width>view.expectedPixels.width||height>view.expectedPixels.height)){
            if(view.onStage)view.onStage(@"frame_size_unexpected");
            if(view.onDisconnected)view.onDisconnected(@"VNC framebuffer is larger than the host output.");
            return;
        }
        // A frame at a size the view has not caught up with is the resize
        // landing. Presenting it re-runs the whole first-frame path, so the
        // canvas re-aspect-fits and the parent is told the new geometry.
        if(view.framePixels.width>0&&(width!=view.framePixels.width||height!=view.framePixels.height)){
            [view.firstFrameLink invalidate];view.firstFrameLink=nil;
            view.frameComplete=NO;view.inputReady=NO;
        }
        if(!view.frameComplete&&view.onStage)view.onStage(@"frame_decoded");
        view.imageView.image=uiImage;view.framePixels=CGSizeMake(width,height);
        [view setNeedsLayout];[view layoutIfNeeded];
        if(!view.frameComplete&&!view.firstFrameLink){
            view.firstFrameLink=[CADisplayLink displayLinkWithTarget:view selector:@selector(frameDisplayTick:)];
            [view.firstFrameLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
        }
    });
}
@implementation OMVNCWorker
- (instancetype)init { if((self=[super init]))_queue=dispatch_queue_create("omodachi.vnc.decode",DISPATCH_QUEUE_SERIAL);return self; }
- (void)pump {
    if(self.stopped||!self.client)return;
    if(!om_vnc_pump(self.client,10000)){
        // LibVNCClient's own last line, so a stream that stops names its reason
        // instead of collapsing into "connection closed".
        NSString *reason=[NSString stringWithFormat:@"rfb_stream_ended: %s",om_vnc_last_message()];
        self.stopped=YES;om_vnc_destroy(self.client);self.client=NULL;
        dispatch_async(dispatch_get_main_queue(), ^{
            OMVNCRemoteView *v=self.view;if(v.worker!=self)return;
            v.inputReady=NO;if(v.onDisconnected)v.onDisconnected(reason);
        });return;
    }
    dispatch_async(self.queue, ^{[self pump];});
}
- (void)stop { dispatch_async(self.queue, ^{self.stopped=YES;if(self.client){om_vnc_destroy(self.client);self.client=NULL;}}); }
@end
@implementation OMVNCRemoteView
- (instancetype)initWithFrame:(CGRect)rect {
    if((self=[super initWithFrame:rect])){
        self.backgroundColor=UIColor.blackColor;
        _imageView=[[UIImageView alloc] initWithFrame:self.bounds];_imageView.contentMode=UIViewContentModeScaleAspectFit;
        [self addSubview:_imageView];self.multipleTouchEnabled=YES;
        // A-43. Three fingers, the same convention the Sunshine backend uses.
        // `multipleTouchEnabled` has to be YES for the recogniser to ever see a
        // third touch; the single-touch pointer path below still reads
        // `touches.anyObject`, so pointer behaviour is unchanged.
        UITapGestureRecognizer *keyboard=[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(keyboardTap:)];
        keyboard.numberOfTouchesRequired=3;[self addGestureRecognizer:keyboard];
    }return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];self.imageView.frame=self.bounds;
    if(self.window&&!self.frameComplete&&self.imageView.image&&self.framePixels.width>0&&!self.firstFrameLink){
        self.firstFrameLink=[CADisplayLink displayLinkWithTarget:self selector:@selector(frameDisplayTick:)];
        [self.firstFrameLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    }
}
- (void)didMoveToWindow {[super didMoveToWindow];if(self.window)[self setNeedsLayout];}
- (void)frameDisplayTick:(CADisplayLink *)link {
    [link invalidate];self.firstFrameLink=nil;
    if(!self.worker||self.framePixels.width<=0)return;
    if(!self.window||self.bounds.size.width<=0||self.bounds.size.height<=0){
        if(self.onStage)self.onStage(@"frame_waiting_for_canvas");
        return;
    }
    self.frameComplete=YES;self.inputReady=self.inputAuthorized;
    if(self.onFramePresented)self.onFramePresented(self.framePixels,[self videoRect]);
}
- (void)expectPixels:(CGSize)pixels {
    [self.firstFrameLink invalidate];self.firstFrameLink=nil;
    OMVNCWorker *worker=self.worker;
    if(worker)dispatch_async(worker.queue, ^{om_vnc_release_inputs(worker.client);});
    self.frameComplete=NO;self.inputAuthorized=NO;self.inputReady=NO;self.expectedPixels=pixels;
    self.framePixels=CGSizeZero;self.serverPixels=CGSizeZero;
}
- (void)connectLoopbackPort:(uint16_t)port expectedPixels:(CGSize)pixels {
    [self disconnect];[self expectPixels:pixels];
    OMVNCWorker *worker=[OMVNCWorker new];worker.view=self;self.worker=worker;
    if(self.onStage)self.onStage(@"rfb_handshake");
    dispatch_async(worker.queue, ^{
        worker.client=om_vnc_create(frame,resized,(__bridge void *)worker);
        if(!worker.client||!om_vnc_connect(worker.client,port)){
            if(worker.client){om_vnc_destroy(worker.client);worker.client=NULL;}
            dispatch_async(dispatch_get_main_queue(), ^{if(self.worker==worker){NSString *reason=[NSString stringWithFormat:@"rfb_init_failed: %s",om_vnc_last_message()];if(self.onDisconnected)self.onDisconnected(reason);}});return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{if(self.worker==worker&&self.onStage)self.onStage(@"rfb_connected");});
        [worker pump];
    });
}
/// The aspect-fit rectangle UIImageView actually draws the framebuffer into.
- (CGRect)videoRect {
    if(self.framePixels.width<=0||self.framePixels.height<=0)return CGRectZero;
    CGFloat scale=MIN(self.bounds.size.width/self.framePixels.width,self.bounds.size.height/self.framePixels.height);
    if(scale<=0)return CGRectZero;
    CGFloat width=self.framePixels.width*scale,height=self.framePixels.height*scale;
    return CGRectMake((self.bounds.size.width-width)/2,(self.bounds.size.height-height)/2,width,height);
}
- (UIImage *)snapshotImage {return self.imageView.image;}
- (void)setInputEnabled:(BOOL)enabled {
    self.inputAuthorized=enabled;self.inputReady=enabled&&self.frameComplete;
    if(!enabled){
        [self resignFirstResponder];
        OMVNCWorker *worker=self.worker;if(worker)dispatch_async(worker.queue, ^{om_vnc_release_inputs(worker.client);});
    }
}
- (void)disconnect { [self disconnectWithCompletion:^{}]; }
- (void)disconnectWithCompletion:(void (^)(void))completion {
    [self.firstFrameLink invalidate];self.firstFrameLink=nil;self.inputAuthorized=NO;self.frameComplete=NO;self.inputReady=NO;
    OMVNCWorker *worker=self.worker;self.worker=nil;
    if(!worker){completion();return;}
    dispatch_async(worker.queue, ^{
        worker.stopped=YES;
        if(worker.client){om_vnc_destroy(worker.client);worker.client=NULL;}
        dispatch_async(dispatch_get_main_queue(),completion);
    });
}
- (void)sendKeysym:(uint32_t)keysym down:(BOOL)down {
    if(!self.inputReady||!self.worker)return;OMVNCWorker *worker=self.worker;
    dispatch_async(worker.queue, ^{if(!worker.stopped)om_vnc_key(worker.client,keysym,down);});
}
- (void)sendPointerAtViewPoint:(CGPoint)point buttons:(int)buttons {
    if(!self.inputReady||!self.worker||self.framePixels.width<=0)return;
    CGRect video=[self videoRect];
    if(CGRectIsEmpty(video)||!CGRectContainsPoint(video,point))return;
    // REMOTE-6. Round rather than truncate, and clamp to the framebuffer. At
    // the device's own pixels one canvas point is about two framebuffer
    // pixels, so truncation is a systematic half-point bias toward the origin
    // on both axes; rounding keeps the error symmetric and under one point at
    // both of WayVNC's sizes. The clamp is what lets the far edge be reached:
    // the right-hand column rounds to exactly `width`, which the RFB client
    // rejects as out of range.
    CGFloat scale=video.size.width/self.framePixels.width;
    int x=(int)lround((point.x-video.origin.x)/scale),y=(int)lround((point.y-video.origin.y)/scale);
    x=MAX(0,MIN(x,(int)self.framePixels.width-1));
    y=MAX(0,MIN(y,(int)self.framePixels.height-1));
    OMVNCWorker *worker=self.worker;
    dispatch_async(worker.queue, ^{if(!worker.stopped)om_vnc_pointer(worker.client,x,y,buttons);});
}
/// GEST-1 §2. The Sunshine picture's arbiter, on this picture. Objective-C
/// gathers the finger positions and forwards the verdict; every threshold and
/// every alias is in `Remote/RemoteGesturePolicy.swift`.
- (void)reportGesturePhase:(OMRemoteTouchPhase)phase event:(UIEvent *)event {
    id<OMRemoteGestureArbitrating> arbiter=self.gestureArbiter;
    if(!arbiter||!self.inputReady)return;
    NSMutableArray<NSNumber *> *points=[NSMutableArray array];
    for(UITouch *touch in event.allTouches){
        if(touch.phase==UITouchPhaseEnded||touch.phase==UITouchPhaseCancelled)continue;
        if(touch.type==UITouchTypeIndirectPointer)continue;
        CGPoint location=[touch locationInView:self];
        [points addObject:@(location.x)];[points addObject:@(location.y)];
    }
    OMRemoteGesture recognised=[arbiter reportPhase:phase coordinates:points timestamp:event.timestamp];
    if(recognised!=OMRemoteGestureNone&&recognised!=OMRemoteGestureKeyboard&&self.onGesture)self.onGesture(recognised);
}
- (BOOL)pointerPressWithheld { return self.pendingPress||self.multiTouchSeen; }
/// UX-2 §2's deferral, the Sunshine window and the Sunshine rule: the button
/// does not go down until 130 ms have passed without a second finger, or the
/// finger has moved far enough to be a drag.
- (void)beginPendingPress {
    if(!self.pendingPress||!self.trackedTouch)return;
    id<OMRemoteGestureArbitrating> arbiter=self.gestureArbiter;
    if(self.multiTouchSeen||(arbiter&&!arbiter.singleTouchAllowed)){self.pendingPress=NO;return;}
    self.pendingPress=NO;self.pressSent=YES;
    [self sendPointerAtViewPoint:self.touchOrigin buttons:1];
}
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self reportGesturePhase:OMRemoteTouchPhaseBegan event:event];
    if(event.allTouches.count>1){
        self.multiTouchSeen=YES;
        self.trackedTouch=nil;self.pendingPress=NO;self.gestureRevision++;
        return;
    }
    self.multiTouchSeen=NO;self.pressSent=NO;
    self.trackedTouch=touches.anyObject;
    self.lastTouch=[self.trackedTouch locationInView:self];
    self.touchOrigin=self.lastTouch;
    self.pendingPress=YES;
    uint64_t revision=++self.gestureRevision;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,130*NSEC_PER_MSEC),dispatch_get_main_queue(), ^{
        if(self.gestureRevision==revision)[self beginPendingPress];
    });
}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self reportGesturePhase:OMRemoteTouchPhaseMoved event:event];
    if(!self.trackedTouch||![touches containsObject:self.trackedTouch])return;
    CGPoint point=[self.trackedTouch locationInView:self];
    self.lastTouch=point;
    if(self.pendingPress&&hypot(point.x-self.touchOrigin.x,point.y-self.touchOrigin.y)>4)[self beginPendingPress];
    if(!self.pendingPress&&self.pressSent)[self sendPointerAtViewPoint:point buttons:1];
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self reportGesturePhase:OMRemoteTouchPhaseEnded event:event];
    if(!self.trackedTouch||![touches containsObject:self.trackedTouch])return;
    [self beginPendingPress];
    if(self.pressSent)[self sendPointerAtViewPoint:self.lastTouch buttons:0];
    self.trackedTouch=nil;self.pendingPress=NO;self.pressSent=NO;self.gestureRevision++;
}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self reportGesturePhase:OMRemoteTouchPhaseCancelled event:event];
    if(self.pressSent)[self sendPointerAtViewPoint:self.lastTouch buttons:0];
    self.trackedTouch=nil;self.pendingPress=NO;self.pressSent=NO;self.gestureRevision++;
}

#pragma mark - A-43 soft keyboard

- (BOOL)canBecomeFirstResponder { return YES; }
- (BOOL)hasText { return YES; }
- (BOOL)softwareKeyboardVisible { return self.isFirstResponder; }
- (void)keyboardTap:(UITapGestureRecognizer *)gesture {
    if(gesture.state!=UIGestureRecognizerStateRecognized)return;
    // A-62 / A-64: the arbiter already decided whether this cycle was a tap.
    id<OMRemoteGestureArbitrating> arbiter=self.gestureArbiter;
    if(arbiter&&!arbiter.keyboardTapConfirmed)return;
    [self toggleKeyboard];
}
- (BOOL)toggleKeyboard {
    if(self.isFirstResponder){[self resignFirstResponder];return NO;}
    if(!self.inputReady)return NO;
    [self becomeFirstResponder];return self.isFirstResponder;
}
- (void)hideKeyboard { [self resignFirstResponder]; }
/// RFB keysyms: for the Latin-1 range the keysym *is* the code point, which is
/// what every printable character typed on the soft keyboard is. Anything
/// outside it is sent as the X11 Unicode keysym (`0x01000000 + code point`),
/// the encoding RFB 3.8 §7.4.4 names for exactly this case.
- (void)insertText:(NSString *)text {
    for(NSUInteger index=0;index<text.length;){
        NSRange range=[text rangeOfComposedCharacterSequenceAtIndex:index];
        uint32_t code=[[text substringWithRange:range] characterAtIndex:0];
        if(range.length==2){
            unichar high=[text characterAtIndex:range.location],low=[text characterAtIndex:range.location+1];
            code=0x10000+((high-0xD800)<<10)+(low-0xDC00);
        }
        uint32_t keysym=code==10||code==13?0xFF0D:code<0x100?code:0x01000000+code;
        [self sendKeysym:keysym down:YES];[self sendKeysym:keysym down:NO];
        index=NSMaxRange(range);
    }
}
- (void)deleteBackward {
    [self sendKeysym:0xFF08 down:YES];[self sendKeysym:0xFF08 down:NO];
}
- (void)dealloc {[_worker stop];}
@end
