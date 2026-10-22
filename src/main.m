// rndis-tether: userspace RNDIS host driver for macOS.
//
// Claims the RNDIS interfaces of a USB-tethered phone via IOUSBHost, speaks the
// RNDIS protocol on its endpoints, and bridges IPv4 traffic to a utun interface.
// Since utun is layer 3, Ethernet framing, ARP and DHCP are handled here.

#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/IOMessage.h>
#import <IOUSBHost/IOUSBHost.h>
#import <SystemConfiguration/SystemConfiguration.h>

#include <arpa/inet.h>
#include <net/if_utun.h>
#include <netinet/in.h>
#include <poll.h>
#include <pthread.h>
#include <spawn.h>
#include <stdatomic.h>
#include <sys/ioctl.h>
#include <sys/kern_control.h>
#include <sys/socket.h>
#include <sys/sys_domain.h>
#include <sys/time.h>
#include <sys/uio.h>
#include <sys/wait.h>
#include <mach-o/dyld.h>
#include <sys/stat.h>
#include <unistd.h>

extern char **environ;

#pragma mark - Constants

#define RNDIS_MSG_PACKET       0x00000001
#define RNDIS_MSG_INIT         0x00000002
#define RNDIS_MSG_HALT         0x00000003
#define RNDIS_MSG_QUERY        0x00000004
#define RNDIS_MSG_SET          0x00000005
#define RNDIS_MSG_INDICATE     0x00000007
#define RNDIS_MSG_KEEPALIVE    0x00000008
#define RNDIS_MSG_COMPLETION   0x80000000

#define RNDIS_STATUS_SUCCESS   0x00000000

#define OID_802_3_PERMANENT_ADDRESS     0x01010101
#define OID_GEN_CURRENT_PACKET_FILTER   0x0001010E

#define PACKET_TYPE_DIRECTED       0x01
#define PACKET_TYPE_ALL_MULTICAST  0x04
#define PACKET_TYPE_BROADCAST      0x08

#define RNDIS_PACKET_HDR_LEN   44
#define HOST_MAX_TRANSFER      16384
#define CTRL_BUF_LEN           4096

#define ETH_HDR_LEN    14
#define ETHERTYPE_IP   0x0800
#define ETHERTYPE_ARP  0x0806

#define DHCP_DISCOVER  1
#define DHCP_OFFER     2
#define DHCP_REQUEST   3
#define DHCP_ACK       5
#define DHCP_NAK       6

#define SC_SERVICE_ID  @"rndis-tether"

#pragma mark - State

static bool g_verbose = false;
static bool g_probe = false;
static bool g_primary = true;
static atomic_bool g_stop;   // process is shutting down
static atomic_bool g_dead;   // current session is over (unplug, error, stop)

// USB session
static IOUSBHostInterface *g_ctrl, *g_data;
static IOUSBHostPipe *g_in, *g_out, *g_intr;
static uint8_t g_ctrlIfNum;
static uint16_t g_outMaxPacket;
static uint32_t g_devMaxTransfer;
static uint32_t g_reqId;
static pthread_mutex_t g_outLock = PTHREAD_MUTEX_INITIALIZER;

// Link
static uint8_t g_mac[6];
static uint8_t g_gwMac[6];
static atomic_bool g_haveGwMac;
static uint16_t g_ipId;

// Lease (network byte order addresses)
typedef struct {
    uint32_t ip, mask, router, server;
    uint32_t dns[4];
    int ndns;
    uint32_t lease;
} Lease;
static Lease g_lease;
static atomic_bool g_configured;  // tun is up, IP traffic flows

// DHCP reply handoff from the RX thread
static pthread_mutex_t g_dhcpLock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_dhcpCond = PTHREAD_COND_INITIALIZER;
static uint32_t g_xid;
static int g_dhcpType;  // 0 = nothing pending
static Lease g_dhcpReply;

// utun
static int g_tunFd = -1;
static char g_tunName[IFNAMSIZ];
static SCDynamicStoreRef g_store;
static SCDynamicStoreRef g_statusStore;
static char g_exePath[PATH_MAX];

#pragma mark - Helpers

static void logmsg(const char *fmt, ...) __printflike(1, 2);
static void logmsg(const char *fmt, ...) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    struct tm tm;
    localtime_r(&tv.tv_sec, &tm);
    char ts[32];
    strftime(ts, sizeof ts, "%H:%M:%S", &tm);
    fprintf(stderr, "[%s.%03d] ", ts, (int)(tv.tv_usec / 1000));
    va_list ap;
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
}

#define VLOG(...) do { if (g_verbose) logmsg(__VA_ARGS__); } while (0)

static void put32(uint8_t *p, uint32_t v) {
    p[0] = v; p[1] = v >> 8; p[2] = v >> 16; p[3] = v >> 24;
}

static uint32_t get32(const uint8_t *p) {
    return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24;
}

static uint16_t get16be(const uint8_t *p) { return p[0] << 8 | p[1]; }

static void put16be(uint8_t *p, uint16_t v) { p[0] = v >> 8; p[1] = v; }

static NSString *ipstr(uint32_t ip) {
    struct in_addr a = { .s_addr = ip };
    return @(inet_ntoa(a));
}

static uint16_t ip_checksum(const uint8_t *p, size_t len) {
    uint32_t sum = 0;
    for (size_t i = 0; i + 1 < len; i += 2) sum += get16be(p + i);
    if (len & 1) sum += p[len - 1] << 8;
    while (sum >> 16) sum = (sum & 0xffff) + (sum >> 16);
    return ~sum;
}

static int run(const char *const argv[]) {
    VLOG("exec: %s ...", argv[0]);
    pid_t pid;
    int err = posix_spawn(&pid, argv[0], NULL, NULL, (char *const *)argv, environ);
    if (err) {
        logmsg("spawn %s: %s", argv[0], strerror(err));
        return -1;
    }
    int status;
    waitpid(pid, &status, 0);
    return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
}

static void deadline_after(struct timespec *ts, double seconds) {
    struct timeval now;
    gettimeofday(&now, NULL);
    double t = now.tv_sec + now.tv_usec / 1e6 + seconds;
    ts->tv_sec = (time_t)t;
    ts->tv_nsec = (long)((t - ts->tv_sec) * 1e9);
}

static double now_s(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return tv.tv_sec + tv.tv_usec / 1e6;
}

// Publishes daemon state for the menu bar app. Temporary values disappear
// when this process exits, so a missing key means the helper isn't running.
static void publish_status(NSString *state, NSDictionary *extra) {
    if (!g_statusStore) return;
    NSMutableDictionary *d = extra ? [extra mutableCopy] : [NSMutableDictionary dictionary];
    d[@"State"] = state;
    CFStringRef key = CFSTR("State:/rndis-tether/Status");
    SCDynamicStoreRemoveValue(g_statusStore, key);
    SCDynamicStoreAddTemporaryValue(g_statusStore, key, (__bridge CFPropertyListRef)d);
}

#pragma mark - RNDIS control channel

static bool ctrl_send(const uint8_t *msg, size_t len) {
    IOUSBDeviceRequest req = {
        .bmRequestType = 0x21,  // class, interface, host-to-device
        .bRequest = 0x00,       // SEND_ENCAPSULATED_COMMAND
        .wValue = 0,
        .wIndex = g_ctrlIfNum,
        .wLength = len,
    };
    NSMutableData *d = [NSMutableData dataWithBytes:msg length:len];
    NSError *err = nil;
    if (![g_ctrl sendDeviceRequest:req data:d bytesTransferred:NULL completionTimeout:5 error:&err]) {
        logmsg("SEND_ENCAPSULATED_COMMAND failed: %s", err.localizedDescription.UTF8String);
        return false;
    }
    return true;
}

// Polls GET_ENCAPSULATED_RESPONSE until a completion for `reqId` arrives.
static ssize_t ctrl_recv(uint32_t reqId, uint8_t *buf, size_t cap) {
    IOUSBDeviceRequest req = {
        .bmRequestType = 0xA1,  // class, interface, device-to-host
        .bRequest = 0x01,       // GET_ENCAPSULATED_RESPONSE
        .wValue = 0,
        .wIndex = g_ctrlIfNum,
        .wLength = cap,
    };
    for (int attempt = 0; attempt < 100 && !atomic_load(&g_dead); attempt++) {
        NSMutableData *d = [NSMutableData dataWithLength:cap];
        NSUInteger n = 0;
        NSError *err = nil;
        if (![g_ctrl sendDeviceRequest:req data:d bytesTransferred:&n completionTimeout:5 error:&err]) {
            VLOG("GET_ENCAPSULATED_RESPONSE: %s", err.localizedDescription.UTF8String);
            usleep(20000);
            continue;
        }
        if (n < 16) {  // a lone zero byte means "no response queued yet"
            usleep(20000);
            continue;
        }
        const uint8_t *p = d.bytes;
        uint32_t type = get32(p);
        if (type == RNDIS_MSG_KEEPALIVE) {
            uint8_t ack[16];
            put32(ack, RNDIS_MSG_KEEPALIVE | RNDIS_MSG_COMPLETION);
            put32(ack + 4, sizeof ack);
            put32(ack + 8, get32(p + 8));
            put32(ack + 12, RNDIS_STATUS_SUCCESS);
            ctrl_send(ack, sizeof ack);
            continue;
        }
        if (type == RNDIS_MSG_INDICATE) {
            VLOG("RNDIS indicate status 0x%08x", get32(p + 8));
            continue;
        }
        if (get32(p + 8) != reqId) {
            VLOG("dropping stale response type 0x%08x id %u", type, get32(p + 8));
            continue;
        }
        memcpy(buf, p, MIN(n, cap));
        return n;
    }
    logmsg("timed out waiting for RNDIS response %u", reqId);
    return -1;
}

// Sends a request (header + body) and returns the response length, or -1.
static ssize_t rndis_command(uint32_t type, const uint8_t *body, size_t bodyLen,
                             uint8_t *resp, size_t respCap) {
    uint8_t msg[CTRL_BUF_LEN];
    uint32_t id = ++g_reqId;
    size_t len = 12 + bodyLen;
    put32(msg, type);
    put32(msg + 4, len);
    put32(msg + 8, id);
    memcpy(msg + 12, body, bodyLen);
    if (!ctrl_send(msg, len)) return -1;
    ssize_t n = ctrl_recv(id, resp, respCap);
    if (n < 16) return -1;
    if (get32(resp) != (type | RNDIS_MSG_COMPLETION)) {
        logmsg("unexpected RNDIS response type 0x%08x", get32(resp));
        return -1;
    }
    uint32_t status = get32(resp + 12);
    if (status != RNDIS_STATUS_SUCCESS) {
        logmsg("RNDIS request 0x%08x failed with status 0x%08x", type, status);
        return -1;
    }
    return n;
}

static bool rndis_init(void) {
    uint8_t body[12], resp[CTRL_BUF_LEN];
    put32(body, 1);      // major version
    put32(body + 4, 0);  // minor version
    put32(body + 8, HOST_MAX_TRANSFER);
    ssize_t n = rndis_command(RNDIS_MSG_INIT, body, sizeof body, resp, sizeof resp);
    if (n < 40) return false;
    g_devMaxTransfer = get32(resp + 36);
    logmsg("RNDIS %u.%u, device max transfer %u bytes, %u packets/transfer",
           get32(resp + 16), get32(resp + 20), g_devMaxTransfer, get32(resp + 32));
    return true;
}

static ssize_t rndis_query(uint32_t oid, uint8_t *out, size_t cap) {
    uint8_t body[16], resp[CTRL_BUF_LEN];
    put32(body, oid);
    put32(body + 4, 0);   // input buffer length
    put32(body + 8, 20);  // input buffer offset (from RequestID)
    put32(body + 12, 0);  // DeviceVcHandle
    ssize_t n = rndis_command(RNDIS_MSG_QUERY, body, sizeof body, resp, sizeof resp);
    if (n < 24) return -1;
    uint32_t len = get32(resp + 16), off = get32(resp + 20);
    if (8 + off + len > (size_t)n || len > cap) return -1;
    memcpy(out, resp + 8 + off, len);
    return len;
}

static bool rndis_set32(uint32_t oid, uint32_t value) {
    uint8_t body[20], resp[CTRL_BUF_LEN];
    put32(body, oid);
    put32(body + 4, 4);
    put32(body + 8, 20);
    put32(body + 12, 0);
    put32(body + 16, value);
    return rndis_command(RNDIS_MSG_SET, body, sizeof body, resp, sizeof resp) >= 16;
}

#pragma mark - Ethernet TX

static bool send_frame(const uint8_t *frame, size_t len) {
    size_t total = RNDIS_PACKET_HDR_LEN + len;
    if (g_devMaxTransfer && total > g_devMaxTransfer) {
        VLOG("dropping oversized frame (%zu bytes)", len);
        return false;
    }
    // A transfer that is an exact multiple of the max packet size would need a
    // zero-length packet to terminate; pad with one byte instead, as Linux does.
    bool pad = g_outMaxPacket && total % g_outMaxPacket == 0;
    NSMutableData *d = [NSMutableData dataWithLength:total + pad];
    uint8_t *p = d.mutableBytes;
    put32(p, RNDIS_MSG_PACKET);
    put32(p + 4, total);
    put32(p + 8, RNDIS_PACKET_HDR_LEN - 8);  // data offset
    put32(p + 12, len);                     // data length
    memcpy(p + RNDIS_PACKET_HDR_LEN, frame, len);

    pthread_mutex_lock(&g_outLock);
    NSError *err = nil;
    BOOL ok = [g_out sendIORequestWithData:d bytesTransferred:NULL completionTimeout:2 error:&err];
    pthread_mutex_unlock(&g_outLock);
    if (!ok) VLOG("bulk out failed: %s", err.localizedDescription.UTF8String);
    return ok;
}

static void eth_header(uint8_t *f, const uint8_t *dst, uint16_t type) {
    memcpy(f, dst, 6);
    memcpy(f + 6, g_mac, 6);
    put16be(f + 12, type);
}

#pragma mark - DHCP

static void dhcp_send(int type, uint32_t requestedIp, uint32_t serverId) {
    uint8_t f[600] = {0};
    static const uint8_t bcast[6] = {0xff, 0xff, 0xff, 0xff, 0xff, 0xff};
    eth_header(f, bcast, ETHERTYPE_IP);

    uint8_t *ip = f + ETH_HDR_LEN, *udp = ip + 20, *bp = udp + 8;
    bp[0] = 1;  // BOOTREQUEST
    bp[1] = 1;  // Ethernet
    bp[2] = 6;
    memcpy(bp + 4, &g_xid, 4);
    put16be(bp + 10, 0x8000);  // ask for broadcast replies
    memcpy(bp + 28, g_mac, 6);
    static const uint8_t magic[4] = {99, 130, 83, 99};
    memcpy(bp + 236, magic, 4);

    uint8_t *o = bp + 240;
    *o++ = 53; *o++ = 1; *o++ = type;
    *o++ = 61; *o++ = 7; *o++ = 1; memcpy(o, g_mac, 6); o += 6;
    *o++ = 57; *o++ = 2; put16be(o, 1500); o += 2;
    *o++ = 55; *o++ = 5; *o++ = 1; *o++ = 3; *o++ = 6; *o++ = 51; *o++ = 54;
    if (requestedIp) { *o++ = 50; *o++ = 4; memcpy(o, &requestedIp, 4); o += 4; }
    if (serverId) { *o++ = 54; *o++ = 4; memcpy(o, &serverId, 4); o += 4; }
    *o++ = 255;
    size_t bpLen = MAX((size_t)(o - bp), 300);  // pad to the BOOTP minimum

    put16be(udp, 68);
    put16be(udp + 2, 67);
    put16be(udp + 4, 8 + bpLen);
    // UDP checksum is optional over IPv4; left as zero.

    ip[0] = 0x45;
    put16be(ip + 2, 20 + 8 + bpLen);
    put16be(ip + 4, g_ipId++);
    ip[8] = 64;
    ip[9] = IPPROTO_UDP;
    memset(ip + 16, 0xff, 4);  // 255.255.255.255; source stays 0.0.0.0
    put16be(ip + 10, ip_checksum(ip, 20));

    send_frame(f, ETH_HDR_LEN + 20 + 8 + bpLen);
}

static void dhcp_input(const uint8_t *frame, const uint8_t *bp, size_t len) {
    if (len < 240 || bp[0] != 2 || memcmp(bp + 4, &g_xid, 4) || memcmp(bp + 28, g_mac, 6)) return;
    if (get16be(bp + 236) != 0x6382 || get16be(bp + 238) != 0x5363) return;

    Lease l = {0};
    memcpy(&l.ip, bp + 16, 4);
    int type = 0;
    for (size_t i = 240; i < len && bp[i] != 255;) {
        uint8_t opt = bp[i];
        if (opt == 0) { i++; continue; }
        if (i + 1 >= len) break;
        uint8_t olen = bp[i + 1];
        const uint8_t *v = bp + i + 2;
        if (i + 2 + olen > len) break;
        switch (opt) {
        case 53: if (olen >= 1) type = v[0]; break;
        case 1: if (olen >= 4) memcpy(&l.mask, v, 4); break;
        case 3: if (olen >= 4) memcpy(&l.router, v, 4); break;
        case 54: if (olen >= 4) memcpy(&l.server, v, 4); break;
        case 51: if (olen >= 4) l.lease = ntohl(*(uint32_t *)v); break;
        case 6:
            for (int k = 0; k + 4 <= olen && l.ndns < 4; k += 4) memcpy(&l.dns[l.ndns++], v + k, 4);
            break;
        }
        i += 2 + olen;
    }
    if (!type) return;
    VLOG("DHCP message type %d from %s", type, ipstr(l.server).UTF8String);

    // The phone is our only neighbour; its MAC is the next hop for everything.
    memcpy(g_gwMac, frame + 6, 6);
    atomic_store(&g_haveGwMac, true);

    pthread_mutex_lock(&g_dhcpLock);
    g_dhcpType = type;
    g_dhcpReply = l;
    pthread_cond_broadcast(&g_dhcpCond);
    pthread_mutex_unlock(&g_dhcpLock);
}

static int dhcp_exchange(int type, uint32_t requestedIp, uint32_t serverId, Lease *out, double timeout) {
    pthread_mutex_lock(&g_dhcpLock);
    g_dhcpType = 0;
    pthread_mutex_unlock(&g_dhcpLock);

    dhcp_send(type, requestedIp, serverId);

    struct timespec ts;
    deadline_after(&ts, timeout);
    pthread_mutex_lock(&g_dhcpLock);
    while (!g_dhcpType && !atomic_load(&g_dead))
        if (pthread_cond_timedwait(&g_dhcpCond, &g_dhcpLock, &ts) == ETIMEDOUT) break;
    int got = g_dhcpType;
    if (got) *out = g_dhcpReply;
    pthread_mutex_unlock(&g_dhcpLock);
    return got;
}

static bool dhcp_acquire(Lease *out) {
    g_xid = arc4random();
    for (int attempt = 0; !atomic_load(&g_dead); attempt++) {
        Lease offer;
        if (dhcp_exchange(DHCP_DISCOVER, 0, 0, &offer, 3) != DHCP_OFFER) {
            if (attempt % 5 == 4) logmsg("no DHCP offer yet; is USB tethering enabled on the phone?");
            continue;
        }
        Lease ack;
        int got = dhcp_exchange(DHCP_REQUEST, offer.ip, offer.server, &ack, 3);
        if (got == DHCP_ACK) {
            if (!ack.mask) ack.mask = htonl(0xffffff00);
            if (!ack.router) ack.router = ack.server;
            if (!ack.ndns) ack.dns[ack.ndns++] = ack.router;
            if (!ack.lease) ack.lease = 3600;
            *out = ack;
            return true;
        }
        VLOG("DHCP REQUEST got %d instead of ACK", got);
    }
    return false;
}

#pragma mark - ARP

static void arp_input(const uint8_t *f, size_t len) {
    if (len < ETH_HDR_LEN + 28) return;
    const uint8_t *a = f + ETH_HDR_LEN;
    if (get16be(a) != 1 || get16be(a + 2) != ETHERTYPE_IP || a[4] != 6 || a[5] != 4) return;
    uint16_t op = get16be(a + 6);
    uint32_t spa, tpa;
    memcpy(&spa, a + 14, 4);
    memcpy(&tpa, a + 24, 4);

    if (spa && spa == g_lease.router) {
        memcpy(g_gwMac, a + 8, 6);
        atomic_store(&g_haveGwMac, true);
    }
    if (op != 1 || !g_lease.ip || tpa != g_lease.ip) return;

    uint8_t r[ETH_HDR_LEN + 28];
    eth_header(r, a + 8, ETHERTYPE_ARP);
    uint8_t *p = r + ETH_HDR_LEN;
    put16be(p, 1);
    put16be(p + 2, ETHERTYPE_IP);
    p[4] = 6;
    p[5] = 4;
    put16be(p + 6, 2);  // reply
    memcpy(p + 8, g_mac, 6);
    memcpy(p + 14, &g_lease.ip, 4);
    memcpy(p + 18, a + 8, 6);
    memcpy(p + 24, &spa, 4);
    send_frame(r, sizeof r);
    VLOG("answered ARP from %s", ipstr(spa).UTF8String);
}

#pragma mark - RX path

static void eth_input(const uint8_t *f, size_t len) {
    if (len < ETH_HDR_LEN) return;
    uint16_t type = get16be(f + 12);
    if (type == ETHERTYPE_ARP) {
        arp_input(f, len);
        return;
    }
    if (type != ETHERTYPE_IP || len < ETH_HDR_LEN + 20) return;

    const uint8_t *ip = f + ETH_HDR_LEN;
    size_t ihl = (ip[0] & 0x0f) * 4;
    size_t iplen = get16be(ip + 2);  // frames may carry Ethernet padding
    if ((ip[0] >> 4) != 4 || ihl < 20 || iplen < ihl || iplen > len - ETH_HDR_LEN) return;

    if (ip[9] == IPPROTO_UDP && iplen >= ihl + 8 && get16be(ip + ihl + 2) == 68) {
        dhcp_input(f, ip + ihl + 8, iplen - ihl - 8);
        return;
    }
    if (!atomic_load(&g_configured)) return;

    uint32_t af = htonl(AF_INET);
    struct iovec iov[2] = {{&af, 4}, {(void *)ip, iplen}};
    if (writev(g_tunFd, iov, 2) < 0) VLOG("tun write: %s", strerror(errno));
}

static void *rx_thread(void *arg) {
    NSMutableData *buf = [NSMutableData dataWithLength:HOST_MAX_TRANSFER];
    while (!atomic_load(&g_dead)) {
        @autoreleasepool {
            NSUInteger n = 0;
            NSError *err = nil;
            if (![g_in sendIORequestWithData:buf bytesTransferred:&n completionTimeout:0 error:&err]) {
                if (!atomic_load(&g_dead)) logmsg("bulk in failed: %s", err.localizedDescription.UTF8String);
                atomic_store(&g_dead, true);
                break;
            }
            // One transfer may carry several RNDIS packet messages back to back.
            const uint8_t *p = buf.bytes;
            size_t off = 0;
            while (off + RNDIS_PACKET_HDR_LEN <= n) {
                uint32_t type = get32(p + off), msgLen = get32(p + off + 4);
                if (type != RNDIS_MSG_PACKET || msgLen < RNDIS_PACKET_HDR_LEN || off + msgLen > n) break;
                uint32_t dataOff = get32(p + off + 8), dataLen = get32(p + off + 12);
                if (8 + dataOff + dataLen <= msgLen) eth_input(p + off + 8 + dataOff, dataLen);
                off += msgLen;
            }
        }
    }
    return NULL;
}

#pragma mark - TX path (utun -> USB)

static void *tun_thread(void *arg) {
    uint8_t buf[4 + 1500 + 64];
    uint8_t frame[ETH_HDR_LEN + 1500 + 64];
    struct pollfd pfd = { .fd = g_tunFd, .events = POLLIN };
    while (!atomic_load(&g_dead)) {
        if (poll(&pfd, 1, 500) <= 0) continue;
        ssize_t n = read(g_tunFd, buf, sizeof buf);
        if (n <= 4) continue;
        if (ntohl(*(uint32_t *)buf) != AF_INET || !atomic_load(&g_haveGwMac)) continue;
        @autoreleasepool {
            eth_header(frame, g_gwMac, ETHERTYPE_IP);
            memcpy(frame + ETH_HDR_LEN, buf + 4, n - 4);
            send_frame(frame, ETH_HDR_LEN + n - 4);
        }
    }
    return NULL;
}

#pragma mark - utun and system configuration

static bool tun_open(void) {
    int fd = socket(PF_SYSTEM, SOCK_DGRAM, SYSPROTO_CONTROL);
    if (fd < 0) {
        logmsg("utun socket: %s (are you root?)", strerror(errno));
        return false;
    }
    struct ctl_info info = {0};
    strlcpy(info.ctl_name, UTUN_CONTROL_NAME, sizeof info.ctl_name);
    if (ioctl(fd, CTLIOCGINFO, &info) < 0) {
        logmsg("CTLIOCGINFO: %s", strerror(errno));
        close(fd);
        return false;
    }
    struct sockaddr_ctl sc = {
        .sc_len = sizeof sc,
        .sc_family = AF_SYSTEM,
        .ss_sysaddr = AF_SYS_CONTROL,
        .sc_id = info.ctl_id,
        .sc_unit = 0,  // let the kernel pick utunN
    };
    if (connect(fd, (struct sockaddr *)&sc, sizeof sc) < 0) {
        logmsg("utun connect: %s (are you root?)", strerror(errno));
        close(fd);
        return false;
    }
    socklen_t len = sizeof g_tunName;
    getsockopt(fd, SYSPROTO_CONTROL, UTUN_OPT_IFNAME, g_tunName, &len);
    g_tunFd = fd;
    return true;
}

static void tun_close(void) {
    if (g_tunFd >= 0) close(g_tunFd);
    g_tunFd = -1;
}

static bool net_configure(const Lease *l) {
    NSString *ip = ipstr(l->ip), *gw = ipstr(l->router);
    const char *ifconfig[] = {"/sbin/ifconfig", g_tunName, "inet", ip.UTF8String, gw.UTF8String,
                              "netmask", "255.255.255.255", "mtu", "1500", "up", NULL};
    if (run(ifconfig) != 0) return false;

    // Publishing the service in the dynamic store makes configd treat it like
    // any other network: it installs the default route and DNS resolvers.
    // Temporary values vanish automatically if this process dies.
    g_store = SCDynamicStoreCreate(NULL, CFSTR("rndis-tether"), NULL, NULL);
    if (!g_store) return false;
    NSMutableArray *dns = [NSMutableArray array];
    for (int i = 0; i < l->ndns; i++) [dns addObject:ipstr(l->dns[i])];
    NSMutableDictionary *v4 = [@{
        @"Addresses": @[ip],
        @"DestAddresses": @[gw],
        @"SubnetMasks": @[@"255.255.255.255"],
        @"Router": gw,
        @"InterfaceName": @(g_tunName),
    } mutableCopy];
    if (g_primary) v4[@"OverridePrimary"] = @1;
    NSDictionary *dnsDict = @{@"ServerAddresses": dns};
    NSString *base = [@"State:/Network/Service/" stringByAppendingString:SC_SERVICE_ID];
    BOOL ok =
        SCDynamicStoreAddTemporaryValue(g_store, (__bridge CFStringRef)[base stringByAppendingString:@"/IPv4"],
                                        (__bridge CFPropertyListRef)v4) &&
        SCDynamicStoreAddTemporaryValue(g_store, (__bridge CFStringRef)[base stringByAppendingString:@"/DNS"],
                                        (__bridge CFPropertyListRef)dnsDict);
    if (!ok) logmsg("SCDynamicStore: %s", SCErrorString(SCError()));
    return ok;
}

static void net_unconfigure(void) {
    if (!g_store) return;
    NSString *base = [@"State:/Network/Service/" stringByAppendingString:SC_SERVICE_ID];
    SCDynamicStoreRemoveValue(g_store, (__bridge CFStringRef)[base stringByAppendingString:@"/IPv4"]);
    SCDynamicStoreRemoveValue(g_store, (__bridge CFStringRef)[base stringByAppendingString:@"/DNS"]);
    CFRelease(g_store);
    g_store = NULL;
}

#pragma mark - Device discovery

static NSNumber *reg_number(io_service_t svc, CFStringRef key) {
    CFTypeRef v = IORegistryEntryCreateCFProperty(svc, key, kCFAllocatorDefault, 0);
    return CFBridgingRelease(v);
}

static io_service_t find_control_interface(void) {
    // Standard RNDIS (Android) and the CDC-ACM vendor variant some devices use.
    static const int classes[][3] = {{0xE0, 0x01, 0x03}, {0x02, 0x02, 0xFF}, {0xEF, 0x04, 0x01}};
    for (size_t i = 0; i < sizeof classes / sizeof classes[0]; i++) {
        CFMutableDictionaryRef m = [IOUSBHostInterface
            createMatchingDictionaryWithVendorID:nil productID:nil bcdDevice:nil interfaceNumber:nil
                              configurationValue:nil interfaceClass:@(classes[i][0])
                               interfaceSubclass:@(classes[i][1]) interfaceProtocol:@(classes[i][2])
                                           speed:nil productIDArray:nil];
        io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, m);
        if (svc) return svc;
    }
    return 0;
}

static io_service_t find_sibling_interface(io_service_t ctrl, int ifNum) {
    io_registry_entry_t parent = 0;
    if (IORegistryEntryGetParentEntry(ctrl, kIOServicePlane, &parent) != KERN_SUCCESS) return 0;
    io_iterator_t it = 0;
    io_service_t found = 0;
    if (IORegistryEntryGetChildIterator(parent, kIOServicePlane, &it) == KERN_SUCCESS) {
        io_service_t child;
        while (!found && (child = IOIteratorNext(it))) {
            if (IOObjectConformsTo(child, "IOUSBHostInterface") &&
                [reg_number(child, CFSTR("bInterfaceNumber")) intValue] == ifNum)
                found = child;
            else
                IOObjectRelease(child);
        }
        IOObjectRelease(it);
    }
    IOObjectRelease(parent);
    return found;
}

static IOUSBHostPipe *find_pipe(IOUSBHostInterface *iface, int xferType, bool in, uint16_t *maxPacket) {
    const IOUSBConfigurationDescriptor *cfg = iface.configurationDescriptor;
    const IOUSBInterfaceDescriptor *ifd = iface.interfaceDescriptor;
    const IOUSBEndpointDescriptor *ep = NULL;
    while ((ep = IOUSBGetNextEndpointDescriptor(cfg, ifd, (const IOUSBDescriptorHeader *)ep))) {
        if ((ep->bmAttributes & 0x03) != xferType || !!(ep->bEndpointAddress & 0x80) != in) continue;
        if (maxPacket) *maxPacket = ep->wMaxPacketSize & 0x7ff;
        NSError *err = nil;
        IOUSBHostPipe *pipe = [iface copyPipeWithAddress:ep->bEndpointAddress error:&err];
        if (!pipe) logmsg("copyPipe 0x%02x: %s", ep->bEndpointAddress, err.localizedDescription.UTF8String);
        return pipe;
    }
    return nil;
}

static IOUSBHostInterface *open_interface(io_service_t svc, dispatch_queue_t q) {
    NSError *err = nil;
    IOUSBHostInterface *iface = [[IOUSBHostInterface alloc]
        initWithIOService:svc options:IOUSBHostObjectInitOptionsNone queue:q error:&err
          interestHandler:^(IOUSBHostObject *obj, uint32_t type, void *arg) {
              if (type == kIOMessageServiceIsTerminated) atomic_store(&g_dead, true);
          }];
    if (!iface) logmsg("open interface: %s", err.localizedDescription.UTF8String);
    return iface;
}

#pragma mark - Session

static void close_usb(void) {
    [g_in abortWithError:nil];
    [g_out abortWithError:nil];
    [g_intr abortWithError:nil];
    g_in = g_out = g_intr = nil;
    [g_data destroy];
    [g_ctrl destroy];
    g_data = g_ctrl = nil;
}

// Moving the app to the Trash doesn't stop a registered daemon, so the helper
// watches its own executable and shuts down once the app is gone. Replacing
// the app (an update, make install) swaps in a new file, possibly faster than
// we look; then exit with an error instead so launchd starts the new copy.
static bool g_updated;
static ino_t g_exeInode;

static bool app_removed(void) {
    struct stat st;
    if (!g_exePath[0]) return false;
    if (stat(g_exePath, &st) == 0) {
        if (st.st_ino == g_exeInode) return false;
        g_updated = true;
    }
    for (int i = 0; i < 30 && !g_updated; i++) {
        usleep(500000);
        g_updated = stat(g_exePath, &st) == 0;
    }
    logmsg(g_updated ? "app was updated; restarting" : "app was removed; shutting down");
    atomic_store(&g_stop, true);
    atomic_store(&g_dead, true);
    return true;
}

static void wait_dead(double seconds) {
    double until = now_s() + seconds;
    while (!atomic_load(&g_dead) && now_s() < until && !app_removed()) usleep(500000);
}

// Runs one device session until unplug, error, lease loss or shutdown.
static void run_session(io_service_t ctrlSvc, NSString *device) {
    atomic_store(&g_dead, false);
    atomic_store(&g_haveGwMac, false);
    atomic_store(&g_configured, false);
    memset(&g_lease, 0, sizeof g_lease);
    g_reqId = 0;
    publish_status(@"connecting", @{@"Device": device});

    dispatch_queue_t q = dispatch_queue_create("rndis-tether.usb", DISPATCH_QUEUE_SERIAL);
    g_ctrlIfNum = [reg_number(ctrlSvc, CFSTR("bInterfaceNumber")) intValue];
    io_service_t dataSvc = find_sibling_interface(ctrlSvc, g_ctrlIfNum + 1);
    if (!dataSvc) {
        logmsg("RNDIS data interface not found");
        return;
    }
    g_ctrl = open_interface(ctrlSvc, q);
    g_data = open_interface(dataSvc, q);
    IOObjectRelease(dataSvc);
    if (!g_ctrl || !g_data) {
        close_usb();
        return;
    }

    g_in = find_pipe(g_data, 2, true, NULL);
    g_out = find_pipe(g_data, 2, false, &g_outMaxPacket);
    if (!g_in || !g_out) {
        // Some devices put the endpoints on alternate setting 1.
        [g_data selectAlternateSetting:1 error:nil];
        g_in = find_pipe(g_data, 2, true, NULL);
        g_out = find_pipe(g_data, 2, false, &g_outMaxPacket);
    }
    g_intr = find_pipe(g_ctrl, 3, true, NULL);
    if (!g_in || !g_out) {
        logmsg("bulk endpoints not found");
        close_usb();
        return;
    }

    pthread_t rx = 0, tx = 0;
    if (!rndis_init()) goto out;
    if (rndis_query(OID_802_3_PERMANENT_ADDRESS, g_mac, 6) != 6) {
        logmsg("could not read MAC address");
        goto out;
    }
    logmsg("host MAC %02x:%02x:%02x:%02x:%02x:%02x",
           g_mac[0], g_mac[1], g_mac[2], g_mac[3], g_mac[4], g_mac[5]);
    if (!rndis_set32(OID_GEN_CURRENT_PACKET_FILTER,
                     PACKET_TYPE_DIRECTED | PACKET_TYPE_BROADCAST | PACKET_TYPE_ALL_MULTICAST)) {
        logmsg("could not set packet filter");
        goto out;
    }

    pthread_create(&rx, NULL, rx_thread, NULL);

    Lease l;
    if (!dhcp_acquire(&l)) goto out;
    g_lease = l;
    logmsg("lease %s/%d via %s, DNS %s, %us",
           ipstr(l.ip).UTF8String, 32 - __builtin_ctz(ntohl(l.mask) ?: 1), ipstr(l.router).UTF8String,
           ipstr(l.dns[0]).UTF8String, l.lease);

    if (g_probe) {
        atomic_store(&g_stop, true);
        goto out;
    }

    if (!tun_open()) {
        atomic_store(&g_stop, true);
        goto out;
    }
    pthread_create(&tx, NULL, tun_thread, NULL);
    if (!net_configure(&l)) goto out;
    atomic_store(&g_configured, true);
    logmsg("%s is up", g_tunName);
    publish_status(@"connected", @{
        @"Device": device,
        @"Address": ipstr(l.ip),
        @"Router": ipstr(l.router),
        @"Interface": @(g_tunName),
    });

    double leaseStart = now_s(), renewAt = leaseStart + l.lease / 2.0;
    while (!atomic_load(&g_dead)) {
        wait_dead(MAX(1, renewAt - now_s()));
        if (atomic_load(&g_dead)) break;
        Lease ack;
        int got = dhcp_exchange(DHCP_REQUEST, g_lease.ip, g_lease.server, &ack, 3);
        if (got == DHCP_ACK && ack.ip == g_lease.ip) {
            g_lease.lease = ack.lease ?: g_lease.lease;
            leaseStart = now_s();
            renewAt = leaseStart + g_lease.lease / 2.0;
            VLOG("lease renewed for %us", g_lease.lease);
        } else if (got == DHCP_NAK || got == DHCP_ACK || now_s() > leaseStart + g_lease.lease) {
            logmsg("lease lost; reconnecting");
            break;
        } else {
            renewAt = now_s() + 30;
        }
    }

out:
    atomic_store(&g_dead, true);
    atomic_store(&g_configured, false);
    net_unconfigure();
    [g_in abortWithError:nil];
    if (rx) pthread_join(rx, NULL);
    if (tx) pthread_join(tx, NULL);
    tun_close();
    close_usb();
    logmsg("session ended");
}

#pragma mark - Main

static void usage(const char *argv0) {
    fprintf(stderr,
            "usage: %s [-v] [--probe] [--no-primary]\n"
            "  -v            verbose logging\n"
            "  --probe       talk to the phone and get a DHCP lease, then exit (no root needed)\n"
            "  --no-primary  don't take over the default route from other networks\n",
            argv0);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        for (int i = 1; i < argc; i++) {
            if (!strcmp(argv[i], "-v")) g_verbose = true;
            else if (!strcmp(argv[i], "--probe")) g_probe = true;
            else if (!strcmp(argv[i], "--no-primary")) g_primary = false;
            else { usage(argv[0]); return 2; }
        }
        if (!g_probe && geteuid() != 0) {
            fprintf(stderr, "%s: must run as root (or use --probe)\n", argv[0]);
            return 1;
        }

        uint32_t len = sizeof g_exePath;
        char raw[PATH_MAX];
        if (_NSGetExecutablePath(raw, &len) == 0 && !realpath(raw, g_exePath)) g_exePath[0] = 0;
        struct stat exe;
        if (g_exePath[0] && stat(g_exePath, &exe) == 0) g_exeInode = exe.st_ino;
        if (!g_probe) g_statusStore = SCDynamicStoreCreate(NULL, CFSTR("rndis-tether-status"), NULL, NULL);
        signal(SIGPIPE, SIG_IGN);
        static dispatch_source_t sigs[2];
        int signums[2] = {SIGINT, SIGTERM};
        for (int i = 0; i < 2; i++) {
            signal(signums[i], SIG_IGN);
            sigs[i] = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, signums[i], 0,
                                             dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0));
            dispatch_source_set_event_handler(sigs[i], ^{
                logmsg("shutting down");
                atomic_store(&g_stop, true);
                atomic_store(&g_dead, true);
                [g_in abortWithError:nil];
                pthread_cond_broadcast(&g_dhcpCond);
            });
            dispatch_resume(sigs[i]);
        }

        bool waiting = false;
        while (!atomic_load(&g_stop)) {
            @autoreleasepool {
                io_service_t svc = find_control_interface();
                if (!svc) {
                    if (!waiting) {
                        logmsg("waiting for an RNDIS device...");
                        publish_status(@"waiting", nil);
                    }
                    waiting = true;
                    if (g_probe) {
                        logmsg("no RNDIS device found");
                        return 1;
                    }
                    sleep(2);
                    app_removed();
                    continue;
                }
                waiting = false;
                NSString *name = CFBridgingRelease(IORegistryEntrySearchCFProperty(
                    svc, kIOServicePlane, CFSTR("USB Product Name"), kCFAllocatorDefault,
                    kIORegistryIterateRecursively | kIORegistryIterateParents));
                if (!name) name = @"phone";
                logmsg("found RNDIS device: %s", name.UTF8String);
                run_session(svc, name);
                IOObjectRelease(svc);
                if (!atomic_load(&g_stop)) sleep(2);
            }
        }
    }
    // launchd only restarts the helper after a failure (see the plist).
    return g_updated ? 75 : 0;
}
