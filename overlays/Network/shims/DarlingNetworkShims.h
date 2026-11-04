// Declarations the Network Swift overlay needs, written for Darling.
#ifndef DARLING_NETWORK_SHIMS_H
#define DARLING_NETWORK_SHIMS_H

#include <objc/NSObject.h>

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
char *_DarlingIfIndexToName(unsigned int index, char *name) __asm("_if_indextoname");
enum { _DarlingIFF_UP = 0x1, _DarlingIFF_RUNNING = 0x40, _DarlingAF_INET = 2, _DarlingAF_INET6 = 30 };

// <netinet/tcp.h>'s socket options, Darwin's values.
enum {
	_DarlingTCP_NODELAY = 0x01,
	_DarlingTCP_MAXSEG = 0x02,
	_DarlingTCP_NOPUSH = 0x04,
	_DarlingTCP_NOOPT = 0x08,
	_DarlingTCP_KEEPALIVE = 0x10,
	_DarlingTCP_CONNECTIONTIMEOUT = 0x20,
	_DarlingTCP_KEEPINTVL = 0x101,
	_DarlingTCP_KEEPCNT = 0x102,
};

// <sys/filio.h>'s FIONREAD, Darwin's value.
static const unsigned long _DarlingFIONREAD = 0x4004667fUL;

// Security's TLS objects, declared the way SEC_OBJECT_DECL declares them, so Swift imports
// sec_protocol_options_t as the protocol type the SDK's interface names
// (So23OS_sec_protocol_options_p).
@protocol OS_sec_protocol_options <NSObject>
@end
typedef NSObject<OS_sec_protocol_options> *__attribute__((objc_independent_class)) sec_protocol_options_t;
@protocol OS_sec_protocol_metadata <NSObject>
@end
typedef NSObject<OS_sec_protocol_metadata> *__attribute__((objc_independent_class)) sec_protocol_metadata_t;
// Network.framework's own endpoint object, for NWEndpoint.opaque.
@protocol OS_nw_endpoint <NSObject>
@end
typedef NSObject<OS_nw_endpoint> *__attribute__((objc_independent_class)) nw_endpoint_t;

// libnetwork's TLS (darling_tls.m): the options object Security's sec_protocol_options_*
// functions configure, and a libtls client session over a connected socket.
sec_protocol_options_t _Nonnull _DarlingNWTLSCreateOptions(void) __asm("_nw_tls_create_options")
	__attribute__((ns_returns_retained));
typedef struct darling_nw_tls *darling_nw_tls_t;
darling_nw_tls_t _Nullable darling_nw_tls_create(sec_protocol_options_t _Nonnull options, int fd,
	const char *_Nullable host, int *_Nonnull status);
int darling_nw_tls_handshake(darling_nw_tls_t _Nonnull tls);
void darling_nw_tls_verify(darling_nw_tls_t _Nonnull tls, void (^_Nonnull done)(_Bool trusted));
long darling_nw_tls_read(darling_nw_tls_t _Nonnull tls, void *_Nonnull buffer, unsigned long length);
long darling_nw_tls_write(darling_nw_tls_t _Nonnull tls, const void *_Nonnull buffer, unsigned long length);
const char *_Nonnull darling_nw_tls_error(darling_nw_tls_t _Nonnull tls);
sec_protocol_metadata_t _Nonnull darling_nw_tls_copy_metadata(darling_nw_tls_t _Nonnull tls)
	__attribute__((ns_returns_retained));
void darling_nw_tls_free(darling_nw_tls_t _Nullable tls);
enum { _DarlingTLS_WANT_POLLIN = -2, _DarlingTLS_WANT_POLLOUT = -3 };

#endif
