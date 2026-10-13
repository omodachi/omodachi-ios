#import "OMHinge.h"

BOOL OMObserveHinge(UIView *view, void (^changed)(OMHingeState state)) {
#if __has_include(<UIKit/UIHingeInteraction.h>)
    if (@available(iOS 27.1, *)) {
        UIHingeInteraction *interaction = [[UIHingeInteraction alloc] initWithUpdateHandler:^(UIHingeInteraction *hingeInteraction, UIHingeInteractionUpdate *update) {
            UIHinge *hinge = update.hinge;
            if (hinge == nil) { changed(OMHingeStateUnavailable); return; }
            switch (hinge.status) {
                case UIHingeStatusClosed: changed(OMHingeStateClosed); break;
                case UIHingeStatusPartiallyOpen: changed(OMHingeStatePartiallyOpen); break;
                case UIHingeStatusFullyOpen: changed(OMHingeStateFullyOpen); break;
                default: changed(OMHingeStateUnavailable); break;
            }
        }];
        [view addInteraction:interaction];
        return YES;
    }
#endif
    return NO;
}
