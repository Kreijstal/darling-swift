// Declarations the Network Swift overlay needs, written for Darling. NWPathMonitor.start(queue:)
// takes a DispatchQueue, which apps built against the iOS SDK mangle as the Objective-C class
// `So17OS_dispatch_queueC`; declaring the class here, rather than importing the Dispatch overlay,
// keeps the overlay buildable against an SDK whose ObjectiveC Clang module is not. Only the name
// matters to Swift: a queue is passed through as an object pointer and retained with objc_retain.
#ifndef DARLING_NETWORK_SHIMS_H
#define DARLING_NETWORK_SHIMS_H

__attribute__((objc_root_class))
@interface OS_dispatch_object
@end

@interface OS_dispatch_queue : OS_dispatch_object
@end

typedef unsigned long long dispatch_time_t;
dispatch_time_t dispatch_time(dispatch_time_t when, long long delta);
void dispatch_async_f(OS_dispatch_queue *queue, void *context, void (*work)(void *));
void dispatch_after_f(dispatch_time_t when, OS_dispatch_queue *queue, void *context, void (*work)(void *));

// <ifaddrs.h> and <net/if.h>, which Darling's Darwin module does not cover, under private names
// bound to the libc symbols so they cannot clash with a Darwin module that does. The layout is
// Darwin's; a sockaddr starts with its length byte, then the address family.
struct _DarlingIfaddrs {
	struct _DarlingIfaddrs *ifa_next;
	char *ifa_name;
	unsigned int ifa_flags;
	const unsigned char *ifa_addr;
	const unsigned char *ifa_netmask;
	const unsigned char *ifa_dstaddr;
	void *ifa_data;
};
int _DarlingGetifaddrs(struct _DarlingIfaddrs **list) __asm("_getifaddrs");
void _DarlingFreeifaddrs(struct _DarlingIfaddrs *list) __asm("_freeifaddrs");
unsigned int _DarlingIfNameToIndex(const char *name) __asm("_if_nametoindex");
enum { _DarlingIFF_UP = 0x1, _DarlingIFF_RUNNING = 0x40, _DarlingAF_INET = 2, _DarlingAF_INET6 = 30 };

#endif
