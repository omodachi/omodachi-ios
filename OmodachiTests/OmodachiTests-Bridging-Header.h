// The unit-test bundle is hosted by the app, so the app's Objective-C classes
// are already in the process. This header is only what lets Swift in *this*
// bundle name them. REMOTE-6 needs `OMVNCRemoteView` itself: the mid-stream
// framebuffer resize and the touch mapping that has to survive it are in the
// view and in the vendored LibVNCClient underneath it, not in anything Swift.
#import "../Omodachi/VNCRemote/OMVNCRemoteView.h"
