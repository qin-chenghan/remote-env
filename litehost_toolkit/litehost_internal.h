#pragma once
#ifdef __cplusplus
extern "C" {
#endif
__attribute__((visibility("hidden"))) void lh_sync_enter(unsigned);
__attribute__((visibility("hidden"))) void lh_sync_leave(void);
__attribute__((visibility("hidden"))) void lh_graph_enter(void);
__attribute__((visibility("hidden"))) void lh_graph_leave(void);
__attribute__((visibility("hidden"))) void*lh_next(const char*);
#ifdef __cplusplus
}
#endif
