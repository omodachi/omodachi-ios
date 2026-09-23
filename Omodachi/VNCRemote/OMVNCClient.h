#ifndef OM_VNC_CLIENT_H
#define OM_VNC_CLIENT_H
#include <stdint.h>
#include <stddef.h>
typedef struct OMVNCClient OMVNCClient;
/// Pixels are copied RGBA8, valid only during callback. delivered only once all
/// pixels of a new framebuffer have been initialized by actual server updates.
typedef void (*OMVNCFrame)(void *context, const uint8_t *rgba, int width, int height);
/// REMOTE-6. The server changed the size of the framebuffer it serves, and
/// LibVNCClient has just reallocated for the new one. WayVNC 0.10.1 does this
/// once per session on a scale-2 output: it opens at the compositor's logical
/// size and corrects itself to the output's buffer pixels one update in. The
/// callback fires on the decode queue with the size that is now authoritative,
/// including the very first allocation, and no pixels are valid until the next
/// OMVNCFrame. It is not an error and the stream continues.
typedef void (*OMVNCResize)(void *context, int width, int height);
OMVNCClient *om_vnc_create(OMVNCFrame frame, OMVNCResize resize, void *context);
/// loopbackPort must be an App-owned authenticated SSH forwarding listener.
int om_vnc_connect(OMVNCClient *, uint16_t loopbackPort);
int om_vnc_pump(OMVNCClient *, unsigned timeoutMicroseconds);
int om_vnc_pointer(OMVNCClient *, int x, int y, int buttonMask);
int om_vnc_key(OMVNCClient *, uint32_t keysym, int down);
void om_vnc_release_inputs(OMVNCClient *);
void om_vnc_destroy(OMVNCClient *);
/// LibVNCClient's own last log line, so a failed handshake names its reason
/// instead of collapsing into "could not connect". Never contains input.
const char *om_vnc_last_message(void);
#endif
