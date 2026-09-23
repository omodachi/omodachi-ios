#include "OMVNCClient.h"
#include <rfb/rfbclient.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <stdio.h>

static char om_vnc_message[256];
static void om_vnc_log(const char *format, ...) {
    va_list arguments; va_start(arguments, format);
    vsnprintf(om_vnc_message, sizeof(om_vnc_message), format, arguments);
    va_end(arguments);
    size_t length = strlen(om_vnc_message);
    while (length > 0 && (om_vnc_message[length-1] == '\n' || om_vnc_message[length-1] == '\r')) om_vnc_message[--length] = 0;
}
const char *om_vnc_last_message(void) { return om_vnc_message; }

struct OMVNCClient {
    rfbClient *client;
    OMVNCFrame frame;
    OMVNCResize resize;
    void *context;
    uint8_t *coverage;
    uint8_t *pixels;
    size_t missing;
    int ready, x, y, buttons;
    uint32_t held[64];
    int heldCount;
};
static char tag;
static OMVNCClient *owner(rfbClient *c) { return rfbClientGetClientData(c,&tag); }
static rfbBool allocate(rfbClient *c) {
    OMVNCClient *v=owner(c);
    if(c->width<=0||c->height<=0||c->width>8192||c->height>8192||((size_t)c->width*c->height)>16777216) return FALSE;
    size_t pixels=(size_t)c->width*c->height;
    free(c->frameBuffer);free(v->coverage);
    c->frameBuffer=calloc(pixels,4);v->pixels=c->frameBuffer;v->coverage=calloc(pixels,1);
    v->missing=pixels;v->ready=0;
    if(!c->frameBuffer||!v->coverage)return FALSE;
    // REMOTE-6. LibVNCClient calls this once for ServerInit and again for every
    // NewFBSize. Input is refused until `ready` is set again by a complete
    // update, so the size the caller maps against is never a stale one.
    if(v->resize)v->resize(v->context,c->width,c->height);
    return TRUE;
}
static void rectangle(rfbClient *c,int x,int y,int w,int h) {
    OMVNCClient *v=owner(c);
    if(x<0||y<0||w<0||h<0||x+w>c->width||y+h>c->height)return;
    for(int row=y;row<y+h;row++)for(int col=x;col<x+w;col++) {
        size_t n=(size_t)row*c->width+col;
        if(!v->coverage[n]){v->coverage[n]=1;v->missing--;}
        c->frameBuffer[n*4+3]=255;
    }
}
static void finished(rfbClient *c) {
    OMVNCClient *v=owner(c);
    if(v->missing==0) {
        v->ready=1;
        if(v->frame)v->frame(v->context,c->frameBuffer,c->width,c->height);
    } else {
        // Resize may arrive alone; request initialization, never present garbage.
        SendFramebufferUpdateRequest(c,0,0,c->width,c->height,FALSE);
    }
}
OMVNCClient *om_vnc_create(OMVNCFrame frame,OMVNCResize resize,void *context) {
    rfbClientLog=om_vnc_log;rfbClientErr=om_vnc_log;om_vnc_message[0]=0;
    OMVNCClient *v=calloc(1,sizeof(*v));if(!v)return NULL;
    v->client=rfbGetClient(8,3,4);if(!v->client){free(v);return NULL;}
    v->frame=frame;v->resize=resize;v->context=context;
    rfbClient *c=v->client;rfbClientSetClientData(c,&tag,v);
    c->MallocFrameBuffer=allocate;c->GotFrameBufferUpdate=rectangle;c->FinishedFrameBufferUpdate=finished;
    c->canHandleNewFBSize=TRUE;c->appData.encodingsString="raw hextile";
    c->format.bitsPerPixel=32;c->format.depth=24;c->format.bigEndian=FALSE;c->format.trueColour=TRUE;
    c->format.redMax=c->format.greenMax=c->format.blueMax=255;
    c->format.redShift=0;c->format.greenShift=8;c->format.blueShift=16;
    const uint32_t auth[]={rfbSecTypeNone};SetClientAuthSchemes(c,auth,1);
    c->connectTimeout=15;c->readTimeout=15;
    return v;
}
int om_vnc_connect(OMVNCClient *v,uint16_t port) {
    if(!v||!v->client||!port)return 0;
    free(v->client->serverHost);v->client->serverHost=strdup("127.0.0.1");v->client->serverPort=port;
    if(!rfbInitClient(v->client,NULL,NULL)){v->client=NULL;return 0;}return 1;
}
int om_vnc_pump(OMVNCClient *v,unsigned micros) {
    if(!v||!v->client)return 0;
    int n=WaitForMessage(v->client,micros);
    return n<0?0:n==0?1:HandleRFBServerMessage(v->client);
}
int om_vnc_pointer(OMVNCClient *v,int x,int y,int mask) {
    if(!v||!v->client||!v->ready||x<0||y<0||x>=v->client->width||y>=v->client->height)return 0;
    v->x=x;v->y=y;v->buttons=mask;return SendPointerEvent(v->client,x,y,mask);
}
int om_vnc_key(OMVNCClient *v,uint32_t key,int down) {
    if(!v||!v->client||!v->ready)return 0;
    int index=-1;for(int i=0;i<v->heldCount;i++)if(v->held[i]==key)index=i;
    if(down&&index<0){if(v->heldCount>=64)return 0;v->held[v->heldCount++]=key;}
    else if(!down&&index>=0)v->held[index]=v->held[--v->heldCount];
    return SendKeyEvent(v->client,key,down);
}
void om_vnc_release_inputs(OMVNCClient *v) {
    if(!v||!v->client)return;
    if(v->buttons)SendPointerEvent(v->client,v->x,v->y,0);
    for(int i=0;i<v->heldCount;i++)SendKeyEvent(v->client,v->held[i],FALSE);
    v->buttons=0;v->heldCount=0;
}
void om_vnc_destroy(OMVNCClient *v) {
    if(!v)return;
    if(v->client){
        om_vnc_release_inputs(v);
        v->client->frameBuffer=NULL;rfbClientCleanup(v->client);
    }
    free(v->pixels);free(v->coverage);free(v);
}
