#include <stddef.h>

int ixStreamSynchronize(void *stream) { (void)stream; return 0; }
int ixEventSynchronize(void *event) { (void)event; return 0; }
int ixDeviceSynchronize(void) { return 0; }
int ixGraphLaunch(void *graph, void *stream) { (void)graph; (void)stream; return 0; }
