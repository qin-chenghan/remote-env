#define _GNU_SOURCE
#include <stdint.h>
#include <stdatomic.h>
#include <time.h>
#include <dlfcn.h>
#include <stdio.h>
#include <unistd.h>
#include "litehost_internal.h"
typedef struct {
 uint64_t start_ns,end_ns,thread_cpu_ns,sync_ns,stream_sync_ns,event_sync_ns,other_sync_ns;
 uint64_t sync_calls,stream_sync_calls,event_sync_calls,other_sync_calls,graph_launch_calls;
} result_t;
typedef struct {result_t r;uint64_t cpu_start,sync_start;unsigned sync_depth,graph_depth,kind;int active;} state_t;
static __thread state_t state;
static uint64_t ns(clockid_t c){struct timespec t;if(clock_gettime(c,&t))_exit(126);return (uint64_t)t.tv_sec*1000000000ULL+t.tv_nsec;}
int litehost_abi_version(void){return 1;}
const char*litehost_build_version(void){return "0.4.0-compat";}
int litehost_begin(void){if(state.active||state.sync_depth||state.graph_depth)return -1;state=(state_t){0};state.cpu_start=ns(CLOCK_THREAD_CPUTIME_ID);state.r.start_ns=ns(CLOCK_MONOTONIC);state.active=1;return 0;}
int litehost_end(result_t*r){if(!r||!state.active||state.sync_depth||state.graph_depth)return -1;state.r.end_ns=ns(CLOCK_MONOTONIC);state.r.thread_cpu_ns=ns(CLOCK_THREAD_CPUTIME_ID)-state.cpu_start;state.active=0;*r=state.r;return 0;}
void lh_sync_enter(unsigned kind){if(state.active&&state.sync_depth++==0){state.sync_start=ns(CLOCK_MONOTONIC);state.kind=kind;}}
void lh_sync_leave(void){if(!state.active||!state.sync_depth||--state.sync_depth)return;uint64_t d=ns(CLOCK_MONOTONIC)-state.sync_start;state.r.sync_ns+=d;state.r.sync_calls++;if(state.kind==1){state.r.stream_sync_ns+=d;state.r.stream_sync_calls++;}else if(state.kind==2){state.r.event_sync_ns+=d;state.r.event_sync_calls++;}else{state.r.other_sync_ns+=d;state.r.other_sync_calls++;}}
void lh_graph_enter(void){if(state.active&&state.graph_depth++==0)state.r.graph_launch_calls++;}
void lh_graph_leave(void){if(state.active&&state.graph_depth)--state.graph_depth;}
void*lh_next(const char*n){void*p=dlsym(RTLD_NEXT,n);if(!p){fprintf(stderr,"[litehost] missing RTLD_NEXT symbol: %s\n",n);_exit(127);}return p;}
#define FN0(n,k) int n(void){static _Atomic(int(*)(void))ptr=NULL;int(*f)(void)=atomic_load_explicit(&ptr,memory_order_acquire);if(!f){f=(int(*)(void))lh_next(#n);atomic_store_explicit(&ptr,f,memory_order_release);}lh_sync_enter(k);int r=f();lh_sync_leave();return r;}
#define FN1(n,k) int n(void*a){static _Atomic(int(*)(void*))ptr=NULL;int(*f)(void*)=atomic_load_explicit(&ptr,memory_order_acquire);if(!f){f=(int(*)(void*))lh_next(#n);atomic_store_explicit(&ptr,f,memory_order_release);}lh_sync_enter(k);int r=f(a);lh_sync_leave();return r;}
#define FN2(n) int n(void*a,void*b){static _Atomic(int(*)(void*,void*))ptr=NULL;int(*f)(void*,void*)=atomic_load_explicit(&ptr,memory_order_acquire);if(!f){f=(int(*)(void*,void*))lh_next(#n);atomic_store_explicit(&ptr,f,memory_order_release);}lh_graph_enter();int r=f(a,b);lh_graph_leave();return r;}
FN0(cudaDeviceSynchronize,3) FN0(cudaThreadSynchronize,3)
FN1(cudaStreamSynchronize,1) FN1(cudaEventSynchronize,2)
FN1(cudaStreamSynchronize_ptsz,1) FN1(cudaEventSynchronize_ptsz,2)
FN2(cudaGraphLaunch) FN2(cudaGraphLaunch_ptsz)
FN0(cuCtxSynchronize,3) FN1(cuStreamSynchronize,1) FN1(cuEventSynchronize,2)
FN1(cuStreamSynchronize_ptsz,1) FN2(cuGraphLaunch) FN2(cuGraphLaunch_ptsz)
