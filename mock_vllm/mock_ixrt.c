#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int dummy_stream[16];
static int dummy_event[16];
static int dummy_graph[16];
static int dummy_exec[16];

int ixGetDeviceCount(int *count) { *count = 4; return 0; }
int ixGetDevice(int *dev) { *dev = 0; return 0; }
int ixSetDevice(int dev) { (void)dev; return 0; }
int ixGetDeviceProperties(void *prop, int dev) { (void)dev; if (prop) memset(prop, 0, 512); return 0; }
int ixDeviceGetAttribute(int *value, int attr, int dev) { (void)attr; (void)dev; if (value) *value = 0; return 0; }
int ixDeviceGetStreamPriorityRange(int *least, int *greatest) { if (least) *least = 0; if (greatest) *greatest = 0; return 0; }
int ixGetLastError(void) { return 0; }
int ixPeekAtLastError(void) { return 0; }
const char *ixGetErrorName(int e) { (void)e; return "ixSuccess"; }
const char *ixGetErrorString(int e) { (void)e; return "mock ixrt"; }

int ixMalloc(void **ptr, size_t size) { *ptr = malloc(size ? size : 1); return 0; }
int ixFree(void *ptr) { (void)ptr; return 0; }
int ixFreeHost(void *ptr) { (void)ptr; return 0; }
int ixMemcpy(void *dst, const void *src, size_t n, int kind) { (void)kind; if (dst && src) memcpy(dst, src, n); return 0; }
int ixMemcpyAsync(void *dst, const void *src, size_t n, int kind, void *stream) { (void)kind; (void)stream; if (dst && src) memcpy(dst, src, n); return 0; }

int ixStreamCreate(void **s) { *s = dummy_stream; return 0; }
int ixStreamCreateWithFlags(void **s, unsigned flags) { (void)flags; *s = dummy_stream; return 0; }
int ixStreamCreateWithPriority(void **s, unsigned flags, int prio) { (void)flags; (void)prio; *s = dummy_stream; return 0; }
int ixStreamDestroy(void *s) { (void)s; return 0; }
int ixStreamSynchronize(void *s) { (void)s; return 0; }
int ixStreamQuery(void *s) { (void)s; return 0; }
int ixStreamWaitEvent(void *s, void *e, unsigned flags) { (void)s; (void)e; (void)flags; return 0; }
int ixStreamGetPriority(void *s, int *p) { (void)s; if (p) *p = 0; return 0; }
int ixStreamGetFlags(void *s, unsigned *p) { (void)s; if (p) *p = 0; return 0; }
int ixStreamAddCallback(void *s, void *cb, void *user, unsigned flags) { (void)s; (void)cb; (void)user; (void)flags; return 0; }

int ixEventCreateWithFlags(void **e, unsigned flags) { (void)flags; *e = dummy_event; return 0; }
int ixEventRecord(void *e, void *s) { (void)e; (void)s; return 0; }
int ixEventQuery(void *e) { (void)e; return 0; }
int ixEventSynchronize(void *e) { (void)e; return 0; }
int ixEventDestroy(void *e) { (void)e; return 0; }
int ixEventElapsedTime(float *ms, void *a, void *b) { (void)a; (void)b; if (ms) *ms = 0.0f; return 0; }

int ixLaunchKernel() { return 0; }
int ixLaunchKernelExC() { return 0; }

int ixStreamBeginCapture(void *s, int mode) { (void)s; (void)mode; return 0; }
int ixStreamEndCapture(void *s, void **graph) { (void)s; if (graph) *graph = dummy_graph; return 0; }
int ixStreamIsCapturing(void *s, int *status) { (void)s; if (status) *status = 0; return 0; }
int ixStreamGetCaptureInfo(void *s, int *status, unsigned long long *id) {
    (void)s; if (status) *status = 0; if (id) *id = 0; return 0;
}
int ixGraphInstantiate(void **exec, void *graph, void *a, void *b, void *c) {
    (void)graph; (void)a; (void)b; (void)c; if (exec) *exec = dummy_exec; return 0;
}
int ixGraphInstantiateWithFlags(void **exec, void *graph, unsigned long long flags) {
    (void)graph; (void)flags; if (exec) *exec = dummy_exec; return 0;
}
int ixGraphLaunch(void *exec, void *s) { (void)exec; (void)s; return 0; }
int ixGraphDestroy(void *g) { (void)g; return 0; }
int ixGraphExecDestroy(void *e) { (void)e; return 0; }
