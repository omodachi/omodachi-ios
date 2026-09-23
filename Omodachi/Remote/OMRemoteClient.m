#import "OMRemoteClient.h"
#import <os/log.h>
#import "OmodachiMediaFacade.h"
#import "CryptoManager.h"
#import "PairManager.h"
#import "Utils.h"
#import <libxml/parser.h>
#import <libxml/tree.h>
@class OMRemoteRenderView;
#if DEBUG
// PAIR-1: the Moonlight leg of Sunshine pairing, traced where it actually runs.
// Certificate fingerprints are public material; the PIN itself is never logged.
static void OMPairTrace(NSString *format, ...) {
    va_list args; va_start(args, format);
    NSString *line=[[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    os_log_info(os_log_create("app.omodachi", "pairing"), "pair.%{public}s", line.UTF8String);
}
#else
static void OMPairTrace(NSString *format, ...) {}
#endif
// INPUT-2: the input gate, traced where it is decided. Six conditions decide
// whether a touch leaves this device; without this the only observable is that
// nothing arrives on the host. Nothing here carries user content.
#if DEBUG
static void OMInputTrace(NSString *format, ...) {
    va_list args; va_start(args, format);
    NSString *line=[[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    os_log_info(os_log_create("app.omodachi", "input"), "remote.input %{public}s", line.UTF8String);
}
#else
static void OMInputTrace(NSString *format, ...) {}
#endif
@interface OMRemotePairCallbacks : NSObject <PairCallback>
@property(nonatomic, copy) void (^pin)(NSString *);
@property(nonatomic, copy) void (^success)(NSData *);
@property(nonatomic, copy) void (^failure)(void);
@property(nonatomic, copy) void (^already)(void);
@end
@implementation OMRemotePairCallbacks
- (void)startPairing:(NSString *)PIN { self.pin(PIN); }
- (void)pairSuccessful:(NSData *)cert { self.success(cert); }
- (void)pairFailed:(NSString *)message { self.failure(); }
- (void)alreadyPaired { self.already(); }
@end
@interface OMRemoteClient () <OmodachiMediaFacadeDelegate>
- (void)requestPanel:(NSString *)source;
- (NSString *)gateState;

@property(nonatomic, readwrite) uint64_t generation;
@property(nonatomic, readwrite) uint64_t leaseSerial;
@property(nonatomic, readwrite) uint64_t geometryEpoch;
@end
@interface OMRemoteRenderView () <UIKeyInput, UIGestureRecognizerDelegate>
@property(nonatomic, weak) OMRemoteClient *client;
@property(nonatomic) BOOL inputEnabled;
@property(nonatomic) BOOL touchpadMode;
@property(nonatomic) BOOL multiTouchIdentityValid;
@property(nonatomic) uint64_t multiGeneration;
@property(nonatomic) uint64_t multiEpoch;
@property(nonatomic) uint64_t multiSerial;
@property(nonatomic, strong) UIPanGestureRecognizer *scrollPan;
@property(nonatomic, strong) UILongPressGestureRecognizer *touchpadDrag;
@property(nonatomic) CGRect videoRect;
@property(nonatomic) CGSize streamPixels;
@property(nonatomic, weak) UITouch *trackedTouch;
@property(nonatomic) uint64_t touchGeneration;
@property(nonatomic) uint64_t touchEpoch;
@property(nonatomic) uint64_t touchSerial;
@property(nonatomic) uint64_t gestureRevision;
@property(nonatomic) BOOL pendingPress;
/// UX-2 §2: this touch cycle has had more than one finger in it. It latches
/// until the next cycle starts, so a deferred press can never outlive the
/// gesture that disqualified it.
@property(nonatomic) BOOL multiTouchSeen;
@property(nonatomic) CGPoint touchOrigin;
@property(nonatomic) NSInteger hardwareButton;
@property(nonatomic, strong) UIView *hardwareInputView;
@property(nonatomic) BOOL softwareKeyboard;
@property(nonatomic, strong) UITapGestureRecognizer *keyboardTap;
@property(nonatomic, strong) UITapGestureRecognizer *rightClickTap;
@property(nonatomic) BOOL preserveKeyboardOnRelease;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSArray<NSNumber *> *> *pressIdentity;
- (void)releaseInputs;
- (BOOL)accessibilityOpenPanel:(UIAccessibilityCustomAction *)action;
@end
@implementation OMRemoteClient {
    OMRemoteRenderView *_renderView;
    NSString *_host;
    NSString *_certAccount;
    NSOperationQueue *_network;
    HttpManager *_http;
    PairManager *_pair;
    OmodachiMediaFacade *_media;
    // STREAM-1: once a second while a stream runs, what the connection counted.
    NSTimer *_statsTimer;
    uint64_t _statsEnqueued;
    NSString *_codec;
    uint64_t _requestRevision;
    BOOL _pairing;
    BOOL _stopping;
    BOOL _frameReported;
    // Why the last presentation observation was not good enough to call a frame.
    NSString *_frameBlocker;
    BOOL _viewportGeometryReady;
    // Mirrors the renderer's display-tick observation policy, so the gate is
    // only crossed when it actually changes.
    BOOL _observingPresentation;
    BOOL _connected;
    // INPUT-2: what the session wants, kept apart from what the media leg can
    // honour. The six conditions below arrive in no fixed order, so a want
    // expressed before the last one lands must survive until it does.
    BOOL _inputDesired;
    // While input is wanted and every condition holds but UIKit has not caught
    // up, the display tick is re-armed until this time, and no longer.
    CFTimeInterval _inputRetryDeadline;
    BOOL _sentTouch;
    NSMutableDictionary<NSNumber *, NSNumber *> *_sentKeys;
    NSMutableSet<NSNumber *> *_sentButtons;
    NSMutableArray<void (^)(BOOL)> *_stopWaiters;
}
- (instancetype)initWithHost:(NSString *)host {
    if ((self = [super init])) {
        _host=[host copy]; _appTitle=@"Desktop"; _httpsPort=0; _certAccount=[@"server.cert:" stringByAppendingString:host.lowercaseString];
        _network=[NSOperationQueue new]; _network.maxConcurrentOperationCount=1; _network.name=@"com.omodachi.sunshine.network";
        _stopWaiters=[NSMutableArray new]; _sentKeys=[NSMutableDictionary new]; _sentButtons=[NSMutableSet new];
        _renderView=[[OMRemoteRenderView alloc] initWithFrame:CGRectZero];
        _renderView.client=self; _renderView.backgroundColor=UIColor.blackColor;
        _renderView.accessibilityIdentifier=@"remote-native-video";
        _renderView.isAccessibilityElement=YES;
        _renderView.accessibilityLabel=@"Remote desktop";
        _renderView.accessibilityValue=@"waiting-for-video";
        _renderView.accessibilityTraits=UIAccessibilityTraitAllowsDirectInteraction;
        _renderView.accessibilityCustomActions=@[[[UIAccessibilityCustomAction alloc] initWithName:@"Open Panel" target:_renderView selector:@selector(accessibilityOpenPanel:)]];
    } return self;
}
- (uint64_t)advanceRequest { @synchronized(self) { return ++_requestRevision; } }
- (BOOL)requestCurrent:(uint64_t)revision { @synchronized(self) { return revision==_requestRevision; } }
- (void)setActiveHTTP:(HttpManager *)http { @synchronized(self) { _http=http; } }
- (UIView *)renderView { return _renderView; }
- (BOOL)inputReady { return [self acceptInputGeneration:_generation geometryEpoch:_geometryEpoch leaseSerial:_leaseSerial releasing:NO]; }
/// The six conditions the gate is made of, in one line, so a refusal can be
/// read as "which one was not true yet" rather than "input is off".
- (NSString *)gateState {
    return [NSString stringWithFormat:@"gen=%llu epoch=%llu serial=%llu want=%d geometry=%d lifecycle=%ld connected=%d frame=%d stopping=%d media=%d enabled=%d",
            (unsigned long long)_generation, (unsigned long long)_geometryEpoch, (unsigned long long)_leaseSerial,
            _inputDesired, _viewportGeometryReady, _media ? (long)_media.lifecycleState : -1,
            _connected, _frameReported, _stopping, _media != nil, _renderView.inputEnabled];
}
- (BOOL)supportsNativeTouch { return _connected && !_forcesAbsolutePointer && (LiGetHostFeatureFlags() & LI_FF_PEN_TOUCH_EVENTS) != 0; }
- (BOOL)softwareKeyboardRequested { return _renderView.softwareKeyboard; }
- (BOOL)touchpadMode { return _renderView.touchpadMode; }
- (void)setTouchpadMode:(BOOL)enabled {
    if (_renderView.touchpadMode==enabled) return;
    // Release the old gesture/button identity before changing its semantics.
    [self releaseInputs];
    _renderView.touchpadMode=enabled;
    // Revalidate the current presented frame against the standing want; never
    // reopen input that a Panel, lease transition or rotation closed.
    [self applyInputState];
}
- (NSString *)currentClientCertificateSHA256 {
    @try {
        NSData *publicCertificate = [CryptoManager readCertFromFile];
        if (publicCertificate.length == 0) return nil;
        NSData *der = [CryptoManager pemToDer:publicCertificate];
        if (der.length == 0) return nil;
        NSData *digest = [[[CryptoManager alloc] init] SHA256HashData:der];
        if (digest.length != 32) return nil;
        const unsigned char *bytes = digest.bytes;
        NSMutableString *hex = [NSMutableString stringWithCapacity:64];
        for (NSUInteger i=0; i<digest.length; i++) [hex appendFormat:@"%02x", bytes[i]];
        return hex;
    } @catch (NSException *exception) {
        // A missing/unreadable current public identity is an unavailable input,
        // never a reason to create or replace identity during lease acquisition.
        return nil;
    }
}
- (BOOL)beginLease { if (!self.idle) return NO; [self advanceRequest]; _generation=0; _geometryEpoch=0; _frameReported=NO; _viewportGeometryReady=NO; _observingPresentation=YES; _connected=NO; _inputDesired=NO; _inputRetryDeadline=0; _leaseSerial++; return YES; }
- (BOOL)idle { return _media==nil && !_stopping && [OmodachiMediaFacade isProcessIdle]; }
- (void)event:(NSString *)type values:(NSDictionary *)values {
    NSAssert(NSThread.isMainThread,@"Remote events are main-thread owned");
    NSMutableDictionary *event=[values mutableCopy]; event[@"type"]=type; event[@"generation"]=@(_generation); event[@"lease_serial"]=@(_leaseSerial); event[@"geometry_epoch"]=@(_geometryEpoch);
    event[@"monotonic_seconds"]=@(NSProcessInfo.processInfo.systemUptime);
    NSData *data=[NSJSONSerialization dataWithJSONObject:event options:0 error:nil];
    if (_eventHandler && data) _eventHandler([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]);
}
- (HttpManager *)newHTTP {
    [CryptoManager generateKeyPairUsingSSL];
    return [[HttpManager alloc] initWithAddress:_host httpsPort:_httpsPort serverCert:[CryptoManager readCryptoObject:_certAccount]];
}
- (HttpResponse *)serverInfo:(HttpManager *)http {
    HttpResponse *info=[HttpResponse new];
    [http executeRequestSynchronously:[HttpRequest requestForResponse:info withUrlRequest:[http newServerInfoRequest:false] fallbackError:401 fallbackRequest:[http newHttpServerInfoRequest]]];
    OMPairTrace(@"serverinfo host=%@ https_port=%d ok=%d status=%ld message=%@ PairStatus=%@ state=%@ appversion=%@ HttpsPort=%@",
                _host, (int)_httpsPort, (int)[info isStatusOk], (long)info.statusCode, info.statusMessage,
                [info getStringTag:@"PairStatus"], [info getStringTag:@"state"],
                [info getStringTag:@"appversion"], [info getStringTag:@"HttpsPort"]);
    return info;
}
- (void)inspectHost {
    if (_media || _stopping) return;
    uint64_t revision=[self advanceRequest];
    [self event:@"discovering" values:@{}];
    [_network addOperationWithBlock:^{
        @try {
            HttpManager *http=[self newHTTP]; [self setActiveHTTP:http]; HttpResponse *info=[self serverInfo:http];
            BOOL paired=[info isStatusOk] && [[info getStringTag:@"PairStatus"] isEqualToString:@"1"] && [CryptoManager readCryptoObject:self->_certAccount]!=nil;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (revision!=self->_requestRevision) return;
                if (![info isStatusOk]) [self event:@"error" values:@{@"message":@"无法连接电脑端串流服务，请检查电脑地址及局域网访问。"}];
                else [self event:paired?@"paired":@"unpaired" values:@{@"busy":@([[info getStringTag:@"state"] hasSuffix:@"_SERVER_BUSY"])}];
            });
        } @catch (NSException *exception) {
            dispatch_async(dispatch_get_main_queue(), ^{ if (revision==self->_requestRevision) [self event:@"error" values:@{@"message":@"The media identity could not be stored securely."}]; });
        }
    }];
}
- (void)pairHost { [self pairHostRenewing:NO]; }
- (void)pairHostRenewing:(BOOL)renewing {
    OMPairTrace(@"moonlight.pair_host_enter renewing=%d media=%d pairing=%d stopping=%d cert=%@ cert_account=%@ server_cert_stored=%d",
                renewing, _media!=nil, _pairing, _stopping, [self currentClientCertificateSHA256], _certAccount,
                [CryptoManager readCryptoObject:_certAccount]!=nil);
    if (_media || _pairing || _stopping) return;
    _pairing=YES;
    uint64_t revision=[self advanceRequest];
    [self event:@"pairing" values:@{@"renewing":@(renewing)}];
    [_network addOperationWithBlock:^{
        @try {
            if (![self requestCurrent:revision]) return;
            HttpManager *http=[self newHTTP]; [self setActiveHTTP:http];
            OMRemotePairCallbacks *callbacks=[OMRemotePairCallbacks new];
            callbacks.pin=^(NSString *pin) { OMPairTrace(@"moonlight.pin_issued cert=%@", [self currentClientCertificateSHA256]); dispatch_async(dispatch_get_main_queue(), ^{ if ([self requestCurrent:revision]) [self event:@"pin" values:@{@"pin":pin}]; }); };
            callbacks.success=^(NSData *cert) { OMPairTrace(@"moonlight.pair_successful cert=%@", [self currentClientCertificateSHA256]);
                // Preserve an identity genuinely approved before cancellation,
                // but a late callback never changes the current UI or starts media.
                [CryptoManager writeCryptoObject:self->_certAccount data:cert];
                dispatch_async(dispatch_get_main_queue(), ^{ if ([self requestCurrent:revision]) { self->_pairing=NO; [self event:@"paired" values:@{}]; } });
            };
            callbacks.failure=^{ OMPairTrace(@"moonlight.pair_failed"); dispatch_async(dispatch_get_main_queue(), ^{ if ([self requestCurrent:revision]) { self->_pairing=NO; [self event:@"error" values:@{@"message":@"电脑端尚未完成批准，请在电脑端串流服务输入 PIN 后重试。"}]; } }); };
            // `alreadyPaired` is its own answer, never a silent end: the fork
            // holding this certificate is not the same fact as the host holding
            // a binding for this device, and only the caller knows which of the
            // two it was waiting for.
            callbacks.already=^{ OMPairTrace(@"moonlight.already_paired renewing=%d server_cert_stored=%d", renewing, [CryptoManager readCryptoObject:self->_certAccount]!=nil); dispatch_async(dispatch_get_main_queue(), ^{ if ([self requestCurrent:revision]) { self->_pairing=NO; [self event:@"already_paired" values:@{@"renewing":@(renewing)}]; } }); };
            PairManager *pair=[[PairManager alloc] initWithManager:http clientCert:[CryptoManager readCertFromFile] callback:callbacks];
            // Sunshine exposes no unpair on the streaming ports (it lives on the
            // password-protected web API), so the fork's side cannot be dropped
            // from here. Asking for the exchange anyway is what registers the
            // request the operator has to approve.
            pair.renewing=renewing;
            self->_pair=pair;
            if ([self requestCurrent:revision]) [pair start];
            self->_pair=nil;
        } @catch (NSException *exception) {
            dispatch_async(dispatch_get_main_queue(), ^{ if ([self requestCurrent:revision]) { self->_pairing=NO; [self event:@"error" values:@{@"message":@"电脑端批准未完成，请检查电脑端提示后重试。"}]; } });
        }
    }];
}
- (NSString *)desktopID:(HttpManager *)http {
    HttpResponse *apps=[HttpResponse new];
    [http executeRequestSynchronously:[HttpRequest requestForResponse:apps withUrlRequest:[http newAppListRequest]]];
    if (![apps isStatusOk] || apps.data.length>1048576) return nil;
    xmlDocPtr doc=xmlReadMemory(apps.data.bytes,(int)apps.data.length,NULL,NULL,XML_PARSE_NONET|XML_PARSE_NOERROR|XML_PARSE_NOWARNING);
    if (!doc) return nil; NSString *result=nil;
    xmlNode *root=xmlDocGetRootElement(doc);
    for (xmlNode *node=root?root->children:NULL;node;node=node->next) {
        if (node->type!=XML_ELEMENT_NODE || xmlStrcmp(node->name,BAD_CAST "App")) continue;
        NSString *title=nil,*appID=nil;
        for (xmlNode *child=node->children;child;child=child->next) {
            xmlChar *text=xmlNodeGetContent(child);
            if (text) {
                if (!xmlStrcmp(child->name,BAD_CAST "AppTitle")) title=[NSString stringWithUTF8String:(char *)text];
                if (!xmlStrcmp(child->name,BAD_CAST "ID")) appID=[NSString stringWithUTF8String:(char *)text];
                xmlFree(text);
            }
        }
        if (title && [title caseInsensitiveCompare:self.appTitle]==NSOrderedSame && appID.length) { result=appID; break; }
    }
    xmlFreeDoc(doc); return result;
}
- (void)startWidth:(int)width height:(int)height fps:(int)fps bitrate:(int)bitrate codec:(NSString *)codec generation:(uint64_t)generation {
    if (!self.idle || width<64 || height<64 || width>4096 || height>4096 || generation<=_generation) return;
    // STREAM-1: the codec is core's plan, negotiated against what the fork
    // serves. Declare exactly that one: the fork compares the launch's codec
    // with the prepared profile, and a client that offered both would be
    // handed HEVC by a fork that was prepared for H.264.
    _codec=[codec isEqualToString:@"hevc"]?@"hevc":@"h264";
    _renderView.accessibilityValue=@"waiting-for-video";
    _generation=generation; _frameReported=NO; _viewportGeometryReady=NO; _frameBlocker=nil; _observingPresentation=YES; _inputDesired=NO; _inputRetryDeadline=0; uint64_t revision=[self advanceRequest];
    [self releaseInputs]; OMInputTrace(@"condition start %@", [self gateState]); [self event:@"launching" values:@{}];
    [_network addOperationWithBlock:^{
        HttpManager *http=[self newHTTP]; [self setActiveHTTP:http]; HttpResponse *info=[self serverInfo:http]; NSString *failure=nil;
        StreamConfiguration *config=[StreamConfiguration new];
        if (![info isStatusOk]) failure=@"电脑端串流服务未响应，请确认服务正在运行。";
        else if (![[info getStringTag:@"PairStatus"] isEqualToString:@"1"] || ![CryptoManager readCryptoObject:self->_certAccount]) failure=@"请先在电脑端批准此设备，再连接 Omodachi Remote。";
        else {
            config.host=self->_host; config.serverCert=[CryptoManager readCryptoObject:self->_certAccount];
            config.appVersion=[info getStringTag:@"appversion"]; config.gfeVersion=[info getStringTag:@"GfeVersion"];
            config.serverCodecModeSupport=[[info getStringTag:@"ServerCodecModeSupport"] intValue];
            config.width=width; config.height=height; config.frameRate=MIN(60,MAX(30,fps)); config.bitRate=MIN(40000,MAX(1000,bitrate));
            config.supportedVideoFormats=[self->_codec isEqualToString:@"hevc"]?VIDEO_FORMAT_H265:VIDEO_FORMAT_H264; config.audioConfiguration=AUDIO_CONFIGURATION_STEREO;
            config.riKey=[Utils randomBytes:16]; config.riKeyId=arc4random(); config.useFramePacing=YES; config.optimizeGameSettings=NO; config.playAudioOnPC=[[OMAudioController shared] hostPlaybackForHost:self->_host];
            BOOL resume=[[info getStringTag:@"state"] hasSuffix:@"_SERVER_BUSY"];
            NSString *desktopID=[self desktopID:http];
            config.appID=desktopID;
            if (resume && ![desktopID isEqualToString:[info getStringTag:@"currentgame"]]) failure=@"电脑端正在串流其他应用，请先结束该串流再连接 Remote。";
            if (!config.appID.length) failure=@"电脑端串流服务尚未配置桌面入口。";
            else if (!failure && [self requestCurrent:revision]) {
                HttpResponse *launch=[HttpResponse new];
                [http executeRequestSynchronously:[HttpRequest requestForResponse:launch withUrlRequest:[http newLaunchOrResumeRequest:resume?@"resume":@"launch" config:config]]];
                NSString *ok=[launch getStringTag:resume?@"resume":@"gamesession"];
                if (![launch isStatusOk] || !ok.length || [ok isEqualToString:@"0"]) failure=@"电脑端未能启动串流，请断开其他串流客户端后重试。";
                else config.rtspSessionUrl=[launch getStringTag:@"sessionUrl0"];
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (revision!=self->_requestRevision) return;
            if (failure) { [self event:@"error" values:@{@"message":failure}]; return; }
#if DEBUG
            // PERF-1: the numbers Moonlight is actually given, once per start.
            os_log_info(os_log_create("app.omodachi", "perf"),
                        "remote.stream_configuration width=%{public}d height=%{public}d frame_rate=%{public}d bit_rate=%{public}d video_formats=0x%{public}x",
                        config.width, config.height, config.frameRate, config.bitRate, config.supportedVideoFormats);
#endif
            self->_media=[[OmodachiMediaFacade alloc] initWithView:self.renderView configuration:config delegate:self];
            __weak OMRemoteClient *weak=self;
            [self->_media setInputReleaseHandler:^(uint64_t gen){ [weak releaseInputs]; }];
            NSError *error;
            [[OMAudioController shared] beginSessionForHost:self->_host generation:generation];
            if (![self->_media startWithGeneration:generation error:&error]) { [[OMAudioController shared] endSession]; [self event:@"error" values:@{@"message":@"A previous media connection has not finished stopping."}]; return; }
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,15*NSEC_PER_SEC),dispatch_get_main_queue(), ^{
                if (self->_generation==generation && self->_media && !self->_frameReported && !self->_stopping) {
                    // The deadline says which check never passed, so a stream
                    // that decodes but is never presented can be told apart
                    // from one that never decoded at all.
                    NSString *blocker=self->_frameBlocker.length?self->_frameBlocker:@"no presentation was ever observed";
                    [self event:@"error" values:@{@"message":[NSString stringWithFormat:@"The stream did not provide a verifiable displayed frame before the deadline (%@).",blocker],@"blocker":blocker}]; [self stopWithCompletion:^(BOOL stopped){}];
                }
            });
        });
    }];
}
/// STREAM-1. The connection's own one-second window, read on the main thread
/// once a second for as long as this generation is the running one. Nothing
/// here changes the stream; the controller decides what the numbers mean.
- (void)startStatsForGeneration:(uint64_t)generation {
    [self stopStats];
    _statsEnqueued=0;
    __weak OMRemoteClient *weak=self;
    _statsTimer=[NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *timer) {
        OMRemoteClient *strong=weak;
        if (!strong || strong->_generation!=generation || !strong->_media || strong->_stopping) { [timer invalidate]; return; }
        [strong publishStats];
    }];
}
- (void)stopStats { [_statsTimer invalidate]; _statsTimer=nil; }
- (void)publishStats {
    OmodachiStreamStats stats;
    if (![_media copyStreamStats:&stats] || stats.windowSeconds<=0) return;
    uint64_t enqueued=stats.enqueuedFrames>=_statsEnqueued?stats.enqueuedFrames-_statsEnqueued:0;
    BOOL first=_statsEnqueued==0; _statsEnqueued=stats.enqueuedFrames;
    NSMutableDictionary *values=[@{@"window":@(stats.windowSeconds),@"total_frames":@(stats.totalFrames),
        @"received_frames":@(stats.receivedFrames),@"network_dropped_frames":@(stats.networkDroppedFrames),
        @"host_latency_ms":@(stats.hostProcessingLatencyTenthsMs/10.0),
        @"codec":(stats.videoFormat&VIDEO_FORMAT_MASK_H265)?@"hevc":@"h264"} mutableCopy];
    // The first reading has no previous count to difference against.
    if (!first) values[@"rendered_frames"]=@(enqueued);
    if (stats.rttKnown) { values[@"rtt_ms"]=@(stats.rttMs); values[@"rtt_variance_ms"]=@(stats.rttVarianceMs); }
    [self event:@"stats" values:values];
}
- (void)stopWithCompletion:(void (^)(BOOL))completion {
    [self stopStats];
    [[OMAudioController shared] endSession];
    [self advanceRequest]; [self releaseInputs];
    HttpManager *http;
    @synchronized(self) { http=_http; }
    [http cancelPendingRequests];
    _pairing=NO;
    if (!_media) { completion([OmodachiMediaFacade isProcessIdle]); return; }
    _connected=NO; _frameReported=NO; _viewportGeometryReady=NO; _observingPresentation=YES; _inputDesired=NO; _inputRetryDeadline=0; _renderView.accessibilityValue=@"stopping";
    [_stopWaiters addObject:[completion copy]]; if (_stopping) return; _stopping=YES;
    OMInputTrace(@"condition stopping=1 %@", [self gateState]);
    [self applyInputState];
    [self event:@"stopping" values:@{}]; NSError *error;
    BOOL accepted=[_media invalidateWithCompletion:^(NSError *error){
        BOOL stopped=error==nil; if (stopped) { self->_media=nil; self->_stopping=NO; self->_renderView.accessibilityValue=@"stopped"; }
        [self event:stopped?@"stopped":@"stop_failed" values:@{@"old_connection_stopped":@(stopped),@"inputs_released":@YES,@"gestures_cancelled":@YES}];
        NSArray *callbacks=[self->_stopWaiters copy]; [self->_stopWaiters removeAllObjects];
        for (void (^callback)(BOOL) in callbacks) callback(stopped);
    } error:&error];
    if (!accepted) [self event:@"stop_failed" values:@{@"message":@"Media stop was not accepted; input remains disabled."}];
    uint64_t generation=_generation;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC),dispatch_get_main_queue(), ^{
        if (self->_stopping && self->_generation==generation) {
            [self event:@"stop_failed" values:@{@"message":@"Media is still stopping. A new connection remains blocked until cleanup completes."}];
            NSArray *callbacks=[self->_stopWaiters copy]; [self->_stopWaiters removeAllObjects]; for (void (^callback)(BOOL) in callbacks) callback(NO);
        }
    });
}
- (void)setGeometryEpoch:(uint64_t)epoch generation:(uint64_t)generation {
    // Candidate identity may be configured before start, while old input is frozen.
    if (_renderView.inputEnabled || generation < _generation) return;
    _geometryEpoch=epoch;
}
- (BOOL)acceptInputGeneration:(uint64_t)generation geometryEpoch:(uint64_t)epoch leaseSerial:(uint64_t)serial releasing:(BOOL)releasing {
    if (generation!=_generation || epoch!=_geometryEpoch || serial!=_leaseSerial) return NO;
    if (releasing) return _media != nil;
    return _renderView.inputEnabled && _viewportGeometryReady && _media.lifecycleState == OmodachiMediaLifecycleStateRunning && _connected && _frameReported && !_stopping;
}
/// The want, not the act. `generation` exists to discard a call made for a
/// session this client has already left behind; it must never discard a legal
/// want for the session that is running, so the answer is stored and applied
/// rather than evaluated once and forgotten.
- (void)setInputEnabled:(BOOL)enabled generation:(uint64_t)generation {
    OMInputTrace(@"want enabled=%d call_generation=%llu %@", enabled, (unsigned long long)generation, [self gateState]);
    if (generation!=_generation) {
        OMInputTrace(@"want-discarded reason=other-generation call_generation=%llu %@", (unsigned long long)generation, [self gateState]);
        // A want belonging to another session still closes the gate on this
        // one: whoever asked is no longer looking at the frame we are showing.
        if (!enabled) { _inputDesired=NO; _inputRetryDeadline=0; [self releaseInputs]; }
        return;
    }
    _inputDesired=enabled;
    if (!enabled) _inputRetryDeadline=0;
    [self applyInputState];
}
/// INPUT-2: the whole decision as a function of its inputs, so the order the
/// six conditions arrive in can be tested without a media stack.
+ (BOOL)inputAllowedForDesired:(BOOL)desired geometryReady:(BOOL)geometryReady lifecycle:(NSInteger)lifecycle
                     connected:(BOOL)connected frameReported:(BOOL)frameReported stopping:(BOOL)stopping hasMedia:(BOOL)hasMedia {
    return desired && geometryReady && hasMedia && lifecycle == (NSInteger)OmodachiMediaLifecycleStateRunning
        && connected && frameReported && !stopping;
}
/// Input is a state, not an event: every one of the six conditions calls this
/// when it moves, and this is the only place that decides.
- (void)applyInputState {
    _renderView.keyboardAllowed=(_media != nil && !_stopping && _connected && _frameReported);
    BOOL allowed=[OMRemoteClient inputAllowedForDesired:_inputDesired geometryReady:_viewportGeometryReady
                                              lifecycle:_media ? (NSInteger)_media.lifecycleState : -1
                                              connected:_connected frameReported:_frameReported
                                               stopping:_stopping hasMedia:_media != nil];
    if (!allowed) {
        if (_inputDesired && !_renderView.inputEnabled) OMInputTrace(@"waiting reason=%@ %@", [self gateBlocker], [self gateState]);
        [self releaseInputs]; return;
    }
    VideoPresentationObservation current=[_media presentationObservation];
    // A historical first-frame flag alone cannot authorize fresh UIKit input
    // after a resize, view removal, or candidate replacement.
    if (current.generation!=_generation || !current.hasFormatDescription || !current.layerVisible || !current.viewInWindow || !current.layerReadyForDisplay || !current.displayedPixelBufferAvailable || current.displayedPixelBufferWidth!=current.decodedWidth || current.displayedPixelBufferHeight!=current.decodedHeight) {
        // Every condition holds and UIKit has not caught up yet. Re-arm the
        // display tick for a bounded while so the next one is tried, instead of
        // waiting for a Panel toggle that may never come.
        [self armInputRetry];
        OMInputTrace(@"waiting reason=presentation-recheck format=%d visible=%d in_window=%d ready=%d buffer=%d %@",
                     current.hasFormatDescription, current.layerVisible, current.viewInWindow,
                     current.layerReadyForDisplay, current.displayedPixelBufferAvailable, [self gateState]);
        [self releaseInputs]; return;
    }
    _inputRetryDeadline=0;
    if (!_renderView.inputEnabled) {
        _renderView.videoRect=current.videoRectPoints;
        _renderView.streamPixels=CGSizeMake(current.decodedWidth,current.decodedHeight);
        [_inputReceiver updateViewport:_renderView.bounds.size videoRect:_renderView.videoRect streamPixels:_renderView.streamPixels];
        [_inputReceiver activateGeneration:_generation geometryEpoch:_geometryEpoch leaseSerial:_leaseSerial];
        OMInputTrace(@"enabled video_rect=%@ stream_pixels=%@ %@", NSStringFromCGRect(_renderView.videoRect), NSStringFromCGSize(_renderView.streamPixels), [self gateState]);
    }
    _renderView.inputEnabled=YES;
    [_renderView becomeFirstResponder];
}
/// Bounded, because a view that is legitimately off screen must not hold the
/// display tick open for the rest of the session (PERF-1).
- (void)armInputRetry {
    CFTimeInterval now=CACurrentMediaTime();
    if (_inputRetryDeadline==0) _inputRetryDeadline=now+2.0;
    if (now<=_inputRetryDeadline) [self setObservingPresentation:YES];
}
/// The first condition that is not true yet. Order is the order in which they
/// normally arrive, so the name is the one worth acting on.
- (NSString *)gateBlocker {
    if (!_media) return @"no-media";
    if (_stopping) return @"stopping";
    if (!_connected) return @"not-connected";
    if (_media.lifecycleState != OmodachiMediaLifecycleStateRunning) return @"lifecycle-not-running";
    if (!_frameReported) return @"no-frame-reported";
    if (!_viewportGeometryReady) return @"geometry-not-ready";
    return @"none";
}
- (void)releaseInputs {
    if (_renderView.inputEnabled) OMInputTrace(@"released %@", [self gateState]);
    _renderView.keyboardAllowed=(_media != nil && !_stopping && _connected && _frameReported);
    [_inputReceiver deactivateGeneration:_generation geometryEpoch:_geometryEpoch leaseSerial:_leaseSerial];
    [self releaseHeldGeneration:_generation geometryEpoch:_geometryEpoch leaseSerial:_leaseSerial];
    _renderView.inputEnabled=NO; [_renderView releaseInputs];
}
- (void)sendTouchPhase:(NSInteger)phase x:(int)x y:(int)y width:(int)width height:(int)height generation:(uint64_t)generation geometryEpoch:(uint64_t)epoch leaseSerial:(uint64_t)serial {
    BOOL releasing=phase==2 || phase==3;
    if (![self acceptInputGeneration:generation geometryEpoch:epoch leaseSerial:serial releasing:releasing]) return;
    if (!self.supportsNativeTouch || width!=(int)_renderView.streamPixels.width || height!=(int)_renderView.streamPixels.height || width<1 || height<1 || x<0 || y<0 || x>=width || y>=height) return;
    OMInputTrace(@"sent kind=touch phase=%ld x=%d y=%d width=%d height=%d fx=%.5f fy=%.5f", (long)phase, x, y, width, height, (float)x/width, (float)y/height);
    if (phase!=0 && !_sentTouch) return;
    uint8_t type=phase==0 ? LI_TOUCH_EVENT_DOWN : phase==1 ? LI_TOUCH_EVENT_MOVE : phase==2 ? LI_TOUCH_EVENT_UP : LI_TOUCH_EVENT_CANCEL;
    if (LiSendTouchEvent(type,0,(float)x/width,(float)y/height,releasing?0:1,0,0,LI_ROT_UNKNOWN)==0) _sentTouch=!releasing;
}
- (void)sendAbsoluteX:(int)x y:(int)y width:(int)width height:(int)height generation:(uint64_t)generation geometryEpoch:(uint64_t)epoch leaseSerial:(uint64_t)serial {
    if (![self acceptInputGeneration:generation geometryEpoch:epoch leaseSerial:serial releasing:NO]) return;
    if (width!=(int)_renderView.streamPixels.width || height!=(int)_renderView.streamPixels.height || width<1 || height<1 || width>32767 || height>32767 || x<0 || y<0 || x>=width || y>=height) return;
    OMInputTrace(@"sent kind=absolute x=%d y=%d width=%d height=%d fx=%.5f fy=%.5f", x, y, width, height, (float)x/width, (float)y/height);
    LiSendMousePositionEvent((short)x,(short)y,(short)width,(short)height);
}
- (void)sendRelativeX:(int)x y:(int)y generation:(uint64_t)generation geometryEpoch:(uint64_t)epoch leaseSerial:(uint64_t)serial {
    if (![self acceptInputGeneration:generation geometryEpoch:epoch leaseSerial:serial releasing:NO]) return;
    LiSendMouseMoveEvent((short)MAX(-32768,MIN(32767,x)),(short)MAX(-32768,MIN(32767,y)));
}
- (void)sendButton:(int)button down:(BOOL)down generation:(uint64_t)generation geometryEpoch:(uint64_t)epoch leaseSerial:(uint64_t)serial {
    if (![self acceptInputGeneration:generation geometryEpoch:epoch leaseSerial:serial releasing:!down] || button<BUTTON_LEFT || button>BUTTON_RIGHT) return;
    if (!down && ![_sentButtons containsObject:@(button)]) return;
    if (down && [_sentButtons containsObject:@(button)]) return;
    if (LiSendMouseButtonEvent(down?BUTTON_ACTION_PRESS:BUTTON_ACTION_RELEASE,button)==0) {
        if (down) [_sentButtons addObject:@(button)]; else [_sentButtons removeObject:@(button)];
    }
}
- (void)sendKey:(unsigned short)key down:(BOOL)down modifiers:(unsigned char)modifiers generation:(uint64_t)generation geometryEpoch:(uint64_t)epoch leaseSerial:(uint64_t)serial {
    if (![self acceptInputGeneration:generation geometryEpoch:epoch leaseSerial:serial releasing:!down] || key>255) return;
    if (!down && !_sentKeys[@(key)]) return;
    if (down && _sentKeys[@(key)]) return;
    // Stock KeyboardSupport marks normalized Win32 VKs with 0x8000.
    if (LiSendKeyboardEvent2((short)(0x8000|key),down?KEY_ACTION_DOWN:KEY_ACTION_UP,(char)modifiers,0)==0) {
        if (down) _sentKeys[@(key)]=@(modifiers); else [_sentKeys removeObjectForKey:@(key)];
    }
}
- (void)sendScrollVertical:(short)vertical horizontal:(short)horizontal generation:(uint64_t)generation geometryEpoch:(uint64_t)epoch leaseSerial:(uint64_t)serial {
    if (![self acceptInputGeneration:generation geometryEpoch:epoch leaseSerial:serial releasing:NO]) return;
    if (vertical) LiSendHighResScrollEvent(vertical);
    if (horizontal) LiSendHighResHScrollEvent(horizontal);
}
- (void)latchModifierMask:(unsigned char)mask {
    if (!_renderView.inputEnabled) return;
    [_inputReceiver latchModifiers:mask generation:_generation geometryEpoch:_geometryEpoch leaseSerial:_leaseSerial];
}
- (void)sendShortcutUsage:(unsigned short)usage {
    if (!_renderView.inputEnabled) return;
    [_inputReceiver keyUsage:usage down:YES generation:_generation geometryEpoch:_geometryEpoch leaseSerial:_leaseSerial];
    [_inputReceiver keyUsage:usage down:NO generation:_generation geometryEpoch:_geometryEpoch leaseSerial:_leaseSerial];
}
- (void)sendTextData:(NSData *)data generation:(uint64_t)generation geometryEpoch:(uint64_t)epoch leaseSerial:(uint64_t)serial {
    if (![self acceptInputGeneration:generation geometryEpoch:epoch leaseSerial:serial releasing:NO] || data.length==0 || data.length>65536) return;
    LiSendUtf8TextEvent(data.bytes,(unsigned int)data.length);
}
- (void)releaseHeldGeneration:(uint64_t)generation geometryEpoch:(uint64_t)epoch leaseSerial:(uint64_t)serial {
    if (generation!=_generation || epoch!=_geometryEpoch || serial!=_leaseSerial) return;
    // This is the one ledger of keys/buttons actually submitted to common-c.
    // Release is allowed while ordinary input is frozen, before interrupt/stop.
    for (NSNumber *key in [_sentKeys.allKeys sortedArrayUsingSelector:@selector(compare:)])
        LiSendKeyboardEvent2((short)(0x8000|key.unsignedShortValue),KEY_ACTION_UP,0,0);
    if (_sentTouch) {
        LiSendTouchEvent(LI_TOUCH_EVENT_CANCEL,0,0,0,0,0,0,LI_ROT_UNKNOWN);
        _sentTouch=NO;
    }
    for (NSNumber *button in _sentButtons) LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE,button.intValue);
    [_sentKeys removeAllObjects]; [_sentButtons removeAllObjects];
}
- (void)requestPanel:(NSString *)source {
    [self releaseInputs];
    [self event:@"panel_request" values:@{@"source":source}];
    if (_panelHandler) _panelHandler(source);
}
- (void)showKeyboard { [_renderView presentSoftwareKeyboard:YES]; }
- (void)hideKeyboard { [_renderView presentSoftwareKeyboard:NO]; }
// A-43. Moonlight's own convention is a three-finger tap, and the convention is
// a toggle: the gesture that summoned the keyboard is the gesture that puts it
// away. The overlay button calls exactly this, so the two entries cannot drift.
// `presentSoftwareKeyboard:` is the single place that raises or dismisses it and
// it already carries INPUT-2's gate (raising needs `inputEnabled`, dismissing
// never does), so these three entries inherit the gate rather than re-stating it.
- (BOOL)toggleKeyboard { return [_renderView presentSoftwareKeyboard:!_renderView.softwareKeyboard]; }
- (void)mediaFacade:(OmodachiMediaFacade *)facade didStartGeneration:(uint64_t)generation { if (facade==_media && generation==_generation && !_stopping) { _connected=YES; OMInputTrace(@"condition connected=1 %@", [self gateState]); [self applyInputState]; [[OMAudioController shared] sessionDidConnectGeneration:generation]; [self event:@"connected" values:@{}]; [self startStatsForGeneration:generation]; } }
- (void)mediaFacade:(OmodachiMediaFacade *)facade didStartStage:(NSString *)stageName generation:(uint64_t)generation { if (facade==_media && generation==_generation && !_stopping) [self event:@"stage" values:@{@"stage":stageName}]; }
- (void)mediaFacade:(OmodachiMediaFacade *)facade didFailStage:(NSString *)stageName errorCode:(int)errorCode portTestFlags:(int)flags generation:(uint64_t)generation {
    if (facade!=_media || generation!=_generation || _stopping) return;
    [self event:@"error" values:@{@"message":@"The media connection failed during setup.",@"code":@(errorCode),@"stage":stageName}]; [self stopWithCompletion:^(BOOL stopped){}];
}
- (void)mediaFacade:(OmodachiMediaFacade *)facade didTerminateUnexpectedlyForGeneration:(uint64_t)generation errorCode:(int)errorCode {
    if (facade!=_media || generation!=_generation || _stopping) return;
    [self event:@"error" values:@{@"message":@"The remote stream ended.",@"code":@(errorCode)}]; [self stopWithCompletion:^(BOOL stopped){}];
}
- (void)mediaFacade:(OmodachiMediaFacade *)facade didReceiveDecodedWidth:(int)width height:(int)height videoFormat:(int)format generation:(uint64_t)generation {
    if (facade==_media && generation==_generation && !_stopping) [self event:@"decoded_format" values:@{@"width":@(width),@"height":@(height),@"format":@(format)}];
}
- (void)mediaFacade:(OmodachiMediaFacade *)facade didObservePresentation:(VideoPresentationObservation)o {
    if (facade!=_media || o.generation!=_generation || _stopping) return;
    // Nothing here is per-frame work. Geometry only moves when the viewport,
    // the decoded size or the layer does, and every one of those paths goes
    // through invalidateViewportGeometry or a fresh start, which re-arms the
    // observation. Once the geometry is latched the display tick stops
    // publishing, so this delegate is not called again until it is unlatched.
    if (_frameReported && _viewportGeometryReady) {
        // Geometry is latched; the only reason left to keep the tick is a want
        // UIKit has not been able to honour yet, and that reason is bounded.
        [self applyInputState];
        if (_renderView.inputEnabled || _inputRetryDeadline==0) [self setObservingPresentation:NO];
        return;
    }
    _renderView.videoRect=o.videoRectPoints; _renderView.streamPixels=CGSizeMake(o.decodedWidth,o.decodedHeight);
    [_inputReceiver updateViewport:_renderView.bounds.size videoRect:_renderView.videoRect streamPixels:_renderView.streamPixels];
    [self publishFrame:o type:(!_frameReported ? @"first_frame" : @"frame_observation")];
}
/// The display tick's observation copies the displayed pixel buffer and lays
/// the video layer out again on the main thread. It is how the first frame and
/// a new geometry are detected, and it costs nothing the rest of the time.
- (void)setObservingPresentation:(BOOL)observing {
    if (_observingPresentation==observing) return;
    _observingPresentation=observing;
    [_media setPublishesObservationEachTick:observing];
}
- (void)invalidateViewportGeometry {
    _viewportGeometryReady=NO; _inputRetryDeadline=0;
    OMInputTrace(@"condition geometry=0 reason=viewport-invalidated %@", [self gateState]);
    [self setObservingPresentation:YES];
    // Layout invalidation releases every host latch/gesture, but must not hide
    // the keyboard that caused the layout change in the first place. The want
    // survives: the next latched geometry is what reopens input.
    _renderView.preserveKeyboardOnRelease=YES; [self applyInputState]; _renderView.preserveKeyboardOnRelease=NO;
}
- (UIImage *)copyDisplayedFrame {
    if (!_media || !_frameReported || _stopping) return nil;
    return [_media copyDisplayedFrameForGeneration:_generation];
}
- (void)observeCurrentFrame {
    if (!_media || _stopping) return;
    // An explicit request is answered from a fresh observation, and re-arms the
    // tick if this one is not good enough to latch.
    [self setObservingPresentation:YES];
    [self publishFrame:[_media presentationObservation] type:@"frame_observation"];
}
- (void)publishFrame:(VideoPresentationObservation)o type:(NSString *)type {
    if (o.generation!=_generation || _stopping || !_media) return;
    // Displayed-buffer observation is stronger than enqueue/ready, but is not physical scanout proof.
    NSString *blocker=nil;
    if (!o.hasFormatDescription) blocker=@"no format description";
    else if (!o.layerVisible) blocker=@"display layer not visible";
    else if (!o.viewInWindow) blocker=@"view not in a window";
    // The displayed buffer can be real while SwiftUI has not sized the canvas
    // yet. Latching that observation would report a first frame drawn into a
    // zero rectangle, and because the latch is one-way nothing would ever
    // publish the real geometry afterwards.
    else if (CGRectIsEmpty(o.videoRectPoints) || _renderView.bounds.size.width<1 || _renderView.bounds.size.height<1)
        blocker=@"the video layer has no area on screen yet";
    else if (!o.layerReadyForDisplay) blocker=@"display layer not ready for display";
    else if (!o.displayedPixelBufferAvailable) blocker=@"no displayed pixel buffer";
    else if (o.displayedPixelBufferWidth!=o.decodedWidth || o.displayedPixelBufferHeight!=o.decodedHeight)
        blocker=[NSString stringWithFormat:@"displayed %dx%d does not match decoded %dx%d",
                 o.displayedPixelBufferWidth,o.displayedPixelBufferHeight,o.decodedWidth,o.decodedHeight];
    if (blocker) { _frameBlocker=blocker; return; }
    _frameBlocker=nil;
    _frameReported=YES; _viewportGeometryReady=YES;
    OMInputTrace(@"condition frame=1 geometry=1 type=%@ %@", type, [self gateState]);
    // The geometry this session was waiting for is latched: from here the
    // display tick has nothing left to report until something invalidates it.
    [self setObservingPresentation:NO];
    // The latch is the last of the six in the ordinary order, so this is where
    // a want that has been waiting for it becomes input.
    [self applyInputState];
    _renderView.accessibilityValue=[NSString stringWithFormat:@"displayed-buffer:%dx%d:generation:%llu",o.decodedWidth,o.decodedHeight,(unsigned long long)o.generation];
    [self event:type values:@{@"width":@(o.decodedWidth),@"height":@(o.decodedHeight),@"x":@(o.videoRectPoints.origin.x),@"y":@(o.videoRectPoints.origin.y),@"video_width":@(o.videoRectPoints.size.width),@"video_height":@(o.videoRectPoints.size.height),@"viewport_width":@(_renderView.bounds.size.width),@"viewport_height":@(_renderView.bounds.size.height),@"format_description_observed":@YES,@"display_layer_ready":@YES,@"frame_presented":@YES,@"scanout_confirmed":@NO}];
}
@end
@implementation OMRemoteRenderView
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self=[super initWithFrame:frame])) {
        self.multipleTouchEnabled=YES; _pressIdentity=[NSMutableDictionary new];
        UIHoverGestureRecognizer *hover=[[UIHoverGestureRecognizer alloc] initWithTarget:self action:@selector(hover:)];
        [self addGestureRecognizer:hover];
        // UX-2 §2. The edge pan that summoned a panel is gone. A-59 rev 5
        // abolished it — "边缘 pan 整体取消" — but the recogniser was still
        // registered and still called `requestPanel`, which made it the one
        // touch on the picture that could put a panel up by accident.
        _scrollPan=[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(scroll:)];
        _scrollPan.minimumNumberOfTouches=2; _scrollPan.maximumNumberOfTouches=2;
        _scrollPan.delegate=self; _scrollPan.cancelsTouchesInView=YES; [self addGestureRecognizer:_scrollPan];
        UITapGestureRecognizer *rightClick=[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(rightClick:)];
        rightClick.numberOfTouchesRequired=2; rightClick.delegate=self;
        [rightClick requireGestureRecognizerToFail:_scrollPan]; [self addGestureRecognizer:rightClick];
        _rightClickTap=rightClick;
        _touchpadDrag=[[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(touchpadDrag:)];
        _touchpadDrag.minimumPressDuration=0.35; _touchpadDrag.allowableMovement=4;
        _touchpadDrag.cancelsTouchesInView=NO; _touchpadDrag.delegate=self; [self addGestureRecognizer:_touchpadDrag];
        _hardwareInputView=[[UIView alloc] initWithFrame:CGRectZero];
        // A-43. Three fingers, Moonlight's convention. The two-finger right
        // click has to wait for it: a three-finger tap whose third finger lands
        // a frame late is otherwise recognised as a right click, which is why
        // the gesture read as "没办法在 remote 里唤出键盘" rather than as a
        // missing feature.
        UITapGestureRecognizer *keyboard=[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(keyboard:)];
        keyboard.numberOfTouchesRequired=3; keyboard.cancelsTouchesInView=YES;
        [rightClick requireGestureRecognizerToFail:keyboard];
        [self addGestureRecognizer:keyboard];
        _keyboardTap=keyboard;
    } return self;
}
- (BOOL)canBecomeFirstResponder { return YES; }
- (BOOL)hasText { return YES; }
- (UIView *)inputView { return _softwareKeyboard ? nil : _hardwareInputView; }
- (NSArray<UIKeyCommand *> *)keyCommands {
    UIKeyCommand *panel=[UIKeyCommand keyCommandWithInput:@"m" modifierFlags:UIKeyModifierCommand|UIKeyModifierShift action:@selector(openPanelCommand:)];
    panel.discoverabilityTitle=@"Open Panel"; panel.wantsPriorityOverSystemBehavior=YES;
    // A-59 rev 5 / review #10: the hardware keyboard's two aliases for the two
    // icons on the host's own bar.
    UIKeyCommand *settings=[UIKeyCommand keyCommandWithInput:@"," modifierFlags:UIKeyModifierCommand|UIKeyModifierShift action:@selector(openSettingsCommand:)];
    settings.discoverabilityTitle=@"Open Settings"; settings.wantsPriorityOverSystemBehavior=YES;
    return @[panel, settings];
}
- (void)openPanelCommand:(UIKeyCommand *)command { [self.client requestPanel:@"keyboard"]; }
- (void)openSettingsCommand:(UIKeyCommand *)command { [self.client requestPanel:@"keyboard_settings"]; }
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer shouldReceiveTouch:(UITouch *)touch {
    return touch.type!=UITouchTypeIndirectPointer;
}
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)recognizer {
    if (recognizer==_touchpadDrag) return _inputEnabled && _touchpadMode && _trackedTouch!=nil && _touchOrigin.x>=24;
    return _inputEnabled;
}
- (BOOL)accessibilityOpenPanel:(UIAccessibilityCustomAction *)action { [self.client requestPanel:@"accessibility"]; return YES; }
- (void)scroll:(UIPanGestureRecognizer *)gesture {
    if (!_inputEnabled || !_multiTouchIdentityValid) return;
    NSInteger phase=gesture.state==UIGestureRecognizerStateBegan ? 0 : gesture.state==UIGestureRecognizerStateChanged ? 1 : 2;
    CGPoint delta=[gesture translationInView:self]; [gesture setTranslation:CGPointZero inView:self];
    [self.client.inputReceiver scrollPhase:phase delta:delta generation:_multiGeneration geometryEpoch:_multiEpoch leaseSerial:_multiSerial];
    if (phase==2) _multiTouchIdentityValid=NO;
}
- (void)rightClick:(UITapGestureRecognizer *)gesture {
    if (gesture.state!=UIGestureRecognizerStateRecognized || !_inputEnabled || !_multiTouchIdentityValid) return;
    [self.client.inputReceiver clickButton:3 generation:_multiGeneration geometryEpoch:_multiEpoch leaseSerial:_multiSerial];
    _multiTouchIdentityValid=NO;
}
- (void)touchpadDrag:(UILongPressGestureRecognizer *)gesture {
    if (!_inputEnabled || !_touchpadMode || !_trackedTouch) return;
    if (gesture.state==UIGestureRecognizerStateBegan) { [self beginPendingPress]; [self.client.inputReceiver touchpadPhase:4 point:[_trackedTouch locationInView:self] generation:_touchGeneration geometryEpoch:_touchEpoch leaseSerial:_touchSerial]; }
    else if (gesture.state==UIGestureRecognizerStateCancelled || gesture.state==UIGestureRecognizerStateFailed) [self.client.inputReceiver touchpadPhase:3 point:CGPointZero generation:_touchGeneration geometryEpoch:_touchEpoch leaseSerial:_touchSerial];
}
/// GEST-1 §2. Every touch on the picture goes past the one arbiter, which is
/// the only thing that knows what three fingers mean. The Objective-C side
/// gathers positions and forwards the verdict; it holds no threshold of its own.
- (void)reportGesturePhase:(OMRemoteTouchPhase)phase event:(UIEvent *)event {
    id<OMRemoteGestureArbitrating> arbiter=self.client.gestureArbiter;
    // INPUT-2's gate covers the gestures too: a picture that may not send a
    // tap may not switch the host's workspace either.
    if (!arbiter || !_inputEnabled) return;
    NSMutableArray<NSNumber *> *points=[NSMutableArray array];
    for (UITouch *touch in event.allTouches) {
        if (touch.phase==UITouchPhaseEnded||touch.phase==UITouchPhaseCancelled) continue;
        if (touch.type==UITouchTypeIndirectPointer) continue;
        CGPoint location=[touch locationInView:self];
        [points addObject:@(location.x)]; [points addObject:@(location.y)];
    }
    OMRemoteGesture recognised=[arbiter reportPhase:phase coordinates:points timestamp:event.timestamp];
    if (recognised!=OMRemoteGestureNone && recognised!=OMRemoteGestureKeyboard && self.client.gestureHandler)
        self.client.gestureHandler(recognised);
}
- (void)keyboard:(UITapGestureRecognizer *)gesture {
    if (gesture.state!=UIGestureRecognizerStateRecognized) return;
    // A-62 / A-64. UIKit's tolerance for a three-finger tap is wide enough to
    // call the tail of a swipe a tap. The arbiter decided what this cycle was
    // the moment a threshold was crossed, and that decision wins.
    id<OMRemoteGestureArbitrating> arbiter=self.client.gestureArbiter;
    if (arbiter && !arbiter.keyboardTapConfirmed) return;
    // UX-2 §2. A-62: three fingers are the keyboard and **only** the keyboard.
    // Nothing here asks for a panel, and the press this cycle would otherwise
    // have sent to the host is already withheld by `multiTouchSeen`.
    BOOL up=[self presentSoftwareKeyboard:!_softwareKeyboard];
    if (self.client.keyboardHandler) self.client.keyboardHandler(up);
}
/// The one place the soft keyboard is raised or dismissed. What gates *raising*
/// it is `keyboardAllowed` — a live session — never `inputEnabled`. MERGE-1
/// found the difference the hard way: A-43's overlay button is only reachable
/// while the overlay is open, and INPUT-2's `inputReady` is false exactly then
/// (`isStreaming && retainedFrame == nil && !panelVisible`), so gating on the
/// input state made that button unable to do the one thing it exists for.
/// Dismissing is never gated, or a keyboard left up by a lost lease could not
/// be put away.
- (BOOL)presentSoftwareKeyboard:(BOOL)wanted {
    if (wanted && !_keyboardAllowed) {
        OMInputTrace(@"keyboard refused wanted=1 reason=no-live-session %@", [self.client gateState]);
        return _softwareKeyboard;
    }
    BOOL previous=_softwareKeyboard;
    _softwareKeyboard=wanted;
    if (wanted) {
        // REMOTE-2 item 3. Order matters and so does the answer. `reloadInputViews`
        // is a no-op on a view that is not the first responder, so the responder
        // has to be taken first; and `becomeFirstResponder` can legitimately fail
        // — no window, or a responder that will not resign — in which case no
        // keyboard is coming and the button must not light up as if one were.
        // MERGE-1 §6.3 is what an unchecked return looks like from outside:
        // "按钮点了、状态亮了、键盘没上来".
        BOOL first=self.isFirstResponder || [self becomeFirstResponder];
        if (!first) {
            _softwareKeyboard=previous;
            OMInputTrace(@"keyboard refused wanted=1 reason=not-first-responder window=%d interaction=%d %@",
                         self.window != nil, self.isUserInteractionEnabled, [self.client gateState]);
            return _softwareKeyboard;
        }
        [self reloadInputViews];
        OMInputTrace(@"keyboard raised first_responder=1 %@", [self.client gateState]);
    } else {
        [self reloadInputViews];
        [self resignFirstResponder];
        OMInputTrace(@"keyboard dismissed %@", [self.client gateState]);
    }
    return _softwareKeyboard;
}
- (void)insertText:(NSString *)text {
    if (_inputEnabled) [self.client.inputReceiver insertText:text generation:self.client.generation geometryEpoch:self.client.geometryEpoch leaseSerial:self.client.leaseSerial];
}
- (void)deleteBackward {
    if (!_inputEnabled) return;
    [self.client.inputReceiver keyUsage:UIKeyboardHIDUsageKeyboardDeleteOrBackspace down:YES generation:self.client.generation geometryEpoch:self.client.geometryEpoch leaseSerial:self.client.leaseSerial];
    [self.client.inputReceiver keyUsage:UIKeyboardHIDUsageKeyboardDeleteOrBackspace down:NO generation:self.client.generation geometryEpoch:self.client.geometryEpoch leaseSerial:self.client.leaseSerial];
}
- (void)releaseInputs {
    _trackedTouch=nil; _pendingPress=NO; _multiTouchIdentityValid=NO; _gestureRevision++;
    [_pressIdentity removeAllObjects];
    // The keyboard follows the session, not the gate: closing input because the
    // Panel opened must not take away a keyboard the user just asked for.
    if (!_preserveKeyboardOnRelease && !_keyboardAllowed) { _softwareKeyboard=NO; [self resignFirstResponder]; }
}
- (void)hover:(UIHoverGestureRecognizer *)gesture {
    if (!_inputEnabled || (gesture.state!=UIGestureRecognizerStateBegan && gesture.state!=UIGestureRecognizerStateChanged)) return;
    [self.client.inputReceiver hardwarePointerPhase:1 button:1 point:[gesture locationInView:self] generation:self.client.generation geometryEpoch:self.client.geometryEpoch leaseSerial:self.client.leaseSerial];
}
- (void)pointerPhase:(NSInteger)phase touch:(UITouch *)touch {
    if (touch.type==UITouchTypeIndirectPointer) [self.client.inputReceiver hardwarePointerPhase:phase button:_hardwareButton point:[touch locationInView:self] generation:_touchGeneration geometryEpoch:_touchEpoch leaseSerial:_touchSerial];
    else if (_touchpadMode) [self.client.inputReceiver touchpadPhase:phase point:[touch locationInView:self] generation:_touchGeneration geometryEpoch:_touchEpoch leaseSerial:_touchSerial];
    else [self.client.inputReceiver pointerPhase:phase point:[touch locationInView:self] generation:_touchGeneration geometryEpoch:_touchEpoch leaseSerial:_touchSerial];
}
- (void)beginPendingPress {
    if (!_pendingPress || !_trackedTouch || !_inputEnabled) return;
    // UX-2 §2, now stated in two places that must agree: this view's own latch
    // and the arbiter's, which is the one the VNC backend uses. A unit test
    // asserts they answer the same thing for the same touch cycle.
    id<OMRemoteGestureArbitrating> arbiter=self.client.gestureArbiter;
    if (_multiTouchSeen || (arbiter && !arbiter.singleTouchAllowed)) { _pendingPress=NO; return; }
    if (_touchpadMode) [self.client.inputReceiver touchpadPhase:0 point:_touchOrigin generation:_touchGeneration geometryEpoch:_touchEpoch leaseSerial:_touchSerial];
    else [self.client.inputReceiver pointerPhase:0 point:_touchOrigin generation:_touchGeneration geometryEpoch:_touchEpoch leaseSerial:_touchSerial];
    _pendingPress=NO;
}
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    // INPUT-2: the refusal a person experiences as "the tap did nothing".
    if (!_inputEnabled) { OMInputTrace(@"touch-refused %@", [self.client gateState]); return; }
    [self reportGesturePhase:OMRemoteTouchPhaseBegan event:event];
    OMInputTrace(@"touch-accepted touchpad=%d %@", _touchpadMode, [self.client gateState]);
    if (event.allTouches.count>1) {
        _multiTouchSeen=YES;
        _multiTouchIdentityValid=event.allTouches.count==2;
        _multiGeneration=self.client.generation; _multiEpoch=self.client.geometryEpoch; _multiSerial=self.client.leaseSerial;
        if (_trackedTouch && !_pendingPress) [self pointerPhase:3 touch:_trackedTouch];
        _trackedTouch=nil; _pendingPress=NO; _gestureRevision++; return;
    }
    _multiTouchIdentityValid=NO;
    _multiTouchSeen=NO;
    _trackedTouch=touches.anyObject; _touchOrigin=[_trackedTouch locationInView:self];
    _touchGeneration=self.client.generation; _touchEpoch=self.client.geometryEpoch; _touchSerial=self.client.leaseSerial;
    if (_trackedTouch.type==UITouchTypeIndirectPointer) {
        _hardwareButton=(event.buttonMask & UIEventButtonMaskSecondary) ? 3 : (event.buttonMask & (1 << 2)) ? 2 : 1;
        _pendingPress=NO; _gestureRevision++;
        [self pointerPhase:0 touch:_trackedTouch]; return;
    }
    _pendingPress=YES;
    uint64_t revision=++_gestureRevision;
    // UX-2 §2. Defer a single pointer press so a multi-finger gesture does not
    // first click whatever is under the first finger. 80 ms was not enough:
    // the fingers of a three-finger tap on an 11" iPad land further apart than
    // that, and when they did the press had already gone out — which on the
    // host is a real touch-down, and a touch-down on Omarchy's own bar opens
    // Omarchy's own menu. That is the "键盘出来了，菜单也出来了" Leo saw: the
    // gesture never asked for a panel, it asked for a click it should not have
    // sent. `multiTouchSeen` latches for the whole cycle, so a finger that
    // lands after the timer cannot be overtaken by it either.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,130*NSEC_PER_MSEC),dispatch_get_main_queue(), ^{
        if (self->_gestureRevision==revision) [self beginPendingPress];
    });
}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self reportGesturePhase:OMRemoteTouchPhaseMoved event:event];
    if (!_trackedTouch || ![touches containsObject:_trackedTouch]) return;
    CGPoint point=[_trackedTouch locationInView:self];
    if (_pendingPress && hypot(point.x-_touchOrigin.x,point.y-_touchOrigin.y)>4) [self beginPendingPress];
    if (!_pendingPress) [self pointerPhase:1 touch:_trackedTouch];
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self reportGesturePhase:OMRemoteTouchPhaseEnded event:event];
    if (!_trackedTouch || ![touches containsObject:_trackedTouch]) return;
    [self beginPendingPress];
    if (!_pendingPress) [self pointerPhase:2 touch:_trackedTouch];
    _trackedTouch=nil; _pendingPress=NO; _gestureRevision++;
}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    // The keyboard tap recogniser cancels the touches it claims, so this is
    // also the ordinary end of a three-finger cycle, not only an interruption.
    [self reportGesturePhase:OMRemoteTouchPhaseCancelled event:event];
    if (_trackedTouch && !_pendingPress) [self pointerPhase:3 touch:_trackedTouch];
    _trackedTouch=nil; _pendingPress=NO; _gestureRevision++;
}
- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    if (!_inputEnabled) return;
    // Modifiers precede ordinary keys when UIKit delivers them in one set.
    NSArray<UIPress *> *ordered=[presses.allObjects sortedArrayUsingComparator:^NSComparisonResult(UIPress *a,UIPress *b){ BOOL am=a.key.keyCode>=0xE0, bm=b.key.keyCode>=0xE0; return am==bm ? NSOrderedSame : am ? NSOrderedAscending : NSOrderedDescending; }];
    for (UIPress *press in ordered) {
        if (!press.key || _pressIdentity[@(press.key.keyCode)]) continue;
        if (press.key.keyCode==UIKeyboardHIDUsageKeyboardM &&
            (press.key.modifierFlags & (UIKeyModifierCommand|UIKeyModifierShift)) == (UIKeyModifierCommand|UIKeyModifierShift)) {
            [self.client requestPanel:@"keyboard"]; return;
        }
        NSArray *identity=@[@(self.client.generation),@(self.client.geometryEpoch),@(self.client.leaseSerial)];
        _pressIdentity[@(press.key.keyCode)]=identity;
        [self.client.inputReceiver keyUsage:(unsigned short)press.key.keyCode down:YES generation:[identity[0] unsignedLongLongValue] geometryEpoch:[identity[1] unsignedLongLongValue] leaseSerial:[identity[2] unsignedLongLongValue]];
    }
}
- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    for (UIPress *press in presses) {
        NSArray *identity=_pressIdentity[@(press.key.keyCode)]; if (!identity) continue;
        [self.client.inputReceiver keyUsage:(unsigned short)press.key.keyCode down:NO generation:[identity[0] unsignedLongLongValue] geometryEpoch:[identity[1] unsignedLongLongValue] leaseSerial:[identity[2] unsignedLongLongValue]];
        [_pressIdentity removeObjectForKey:@(press.key.keyCode)];
    }
}
- (void)pressesCancelled:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    [self.client.inputReceiver cancelInputsGeneration:self.client.generation geometryEpoch:self.client.geometryEpoch leaseSerial:self.client.leaseSerial];
    [_pressIdentity removeAllObjects];
}
@end
