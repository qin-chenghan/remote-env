#include "/usr/local/corex-5.0.0/include/cuda_runtime_api.h"

#include <atomic>
#include <tuple>
#include <type_traits>
#include "litehost_internal.h"
template<class> struct traits;
template<class R,class...A>struct traits<R(*)(A...)>{using ret=R;using args=std::tuple<A...>;static constexpr int n=sizeof...(A);template<int I>using arg=typename std::tuple_element<I,args>::type;};
template<class R,class...A>struct traits<R(*)(A...)noexcept>:traits<R(*)(A...)>{};
using f_ixStreamSynchronize=decltype(&::ixStreamSynchronize);using t_ixStreamSynchronize=traits<f_ixStreamSynchronize>;
static_assert(t_ixStreamSynchronize::n==1,"Unexpected API arity");
extern "C" t_ixStreamSynchronize::ret wrap_ixStreamSynchronize(t_ixStreamSynchronize::arg<0> a0) __asm__("ixStreamSynchronize");
extern "C" t_ixStreamSynchronize::ret wrap_ixStreamSynchronize(t_ixStreamSynchronize::arg<0> a0){static std::atomic<f_ixStreamSynchronize>p{nullptr};auto f=p.load(std::memory_order_acquire);if(!f){f=reinterpret_cast<f_ixStreamSynchronize>(lh_next("ixStreamSynchronize"));p.store(f,std::memory_order_release);}lh_sync_enter(1);auto r=f(a0);lh_sync_leave();return r;}
static_assert(std::is_convertible<f_ixStreamSynchronize,decltype(&wrap_ixStreamSynchronize)>::value,"Wrapper type mismatch");
using f_ixEventSynchronize=decltype(&::ixEventSynchronize);using t_ixEventSynchronize=traits<f_ixEventSynchronize>;
static_assert(t_ixEventSynchronize::n==1,"Unexpected API arity");
extern "C" t_ixEventSynchronize::ret wrap_ixEventSynchronize(t_ixEventSynchronize::arg<0> a0) __asm__("ixEventSynchronize");
extern "C" t_ixEventSynchronize::ret wrap_ixEventSynchronize(t_ixEventSynchronize::arg<0> a0){static std::atomic<f_ixEventSynchronize>p{nullptr};auto f=p.load(std::memory_order_acquire);if(!f){f=reinterpret_cast<f_ixEventSynchronize>(lh_next("ixEventSynchronize"));p.store(f,std::memory_order_release);}lh_sync_enter(2);auto r=f(a0);lh_sync_leave();return r;}
static_assert(std::is_convertible<f_ixEventSynchronize,decltype(&wrap_ixEventSynchronize)>::value,"Wrapper type mismatch");
using f_ixDeviceSynchronize=decltype(&::ixDeviceSynchronize);using t_ixDeviceSynchronize=traits<f_ixDeviceSynchronize>;
static_assert(t_ixDeviceSynchronize::n==0,"Unexpected API arity");
extern "C" t_ixDeviceSynchronize::ret wrap_ixDeviceSynchronize(void) __asm__("ixDeviceSynchronize");
extern "C" t_ixDeviceSynchronize::ret wrap_ixDeviceSynchronize(void){static std::atomic<f_ixDeviceSynchronize>p{nullptr};auto f=p.load(std::memory_order_acquire);if(!f){f=reinterpret_cast<f_ixDeviceSynchronize>(lh_next("ixDeviceSynchronize"));p.store(f,std::memory_order_release);}lh_sync_enter(3);auto r=f();lh_sync_leave();return r;}
static_assert(std::is_convertible<f_ixDeviceSynchronize,decltype(&wrap_ixDeviceSynchronize)>::value,"Wrapper type mismatch");
using f_ixGraphLaunch=decltype(&::ixGraphLaunch);using t_ixGraphLaunch=traits<f_ixGraphLaunch>;
static_assert(t_ixGraphLaunch::n==2,"Unexpected API arity");
extern "C" t_ixGraphLaunch::ret wrap_ixGraphLaunch(t_ixGraphLaunch::arg<0> a0,t_ixGraphLaunch::arg<1> a1) __asm__("ixGraphLaunch");
extern "C" t_ixGraphLaunch::ret wrap_ixGraphLaunch(t_ixGraphLaunch::arg<0> a0,t_ixGraphLaunch::arg<1> a1){static std::atomic<f_ixGraphLaunch>p{nullptr};auto f=p.load(std::memory_order_acquire);if(!f){f=reinterpret_cast<f_ixGraphLaunch>(lh_next("ixGraphLaunch"));p.store(f,std::memory_order_release);}lh_graph_enter();auto r=f(a0,a1);lh_graph_leave();return r;}
static_assert(std::is_convertible<f_ixGraphLaunch,decltype(&wrap_ixGraphLaunch)>::value,"Wrapper type mismatch");
