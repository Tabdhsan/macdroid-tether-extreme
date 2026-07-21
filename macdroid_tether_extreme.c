// macdroid-tether-extreme — Userspace RNDIS-to-utun bridge for Android USB
// tethering on macOS. A userspace replacement for the dead HoRNDIS kext;
// works on Apple Silicon with no kernel extension and no SIP changes.
//
// Usage: sudo ./macdroid-tether-extreme [--default-route] [--mtu <n>]
// Requires: libusb (brew install libusb)
// License: MIT

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include <unistd.h>
#include <signal.h>
#include <pthread.h>
#include <errno.h>
#include <arpa/inet.h>
#include <net/if.h>
#include <sys/socket.h>
#include <sys/ioctl.h>
#include <sys/kern_control.h>
#include <sys/sys_domain.h>
#include <net/if_utun.h>
#include <libusb-1.0/libusb.h>

// ============================================================
// RNDIS Protocol
// ============================================================

#define RNDIS_MSG_INIT          0x00000002
#define RNDIS_MSG_INIT_C        0x80000002
#define RNDIS_MSG_QUERY         0x00000004
#define RNDIS_MSG_QUERY_C       0x80000004
#define RNDIS_MSG_SET           0x00000005
#define RNDIS_MSG_SET_C         0x80000005
#define RNDIS_MSG_PACKET        0x00000001

#define RNDIS_MAJOR_VERSION     1
#define RNDIS_MINOR_VERSION     0
#define RNDIS_MAX_XFER          0x4000

#define OID_802_3_PERMANENT_ADDRESS     0x01010101
#define OID_GEN_CURRENT_PACKET_FILTER   0x0001010E

#define RNDIS_FILTER_DIRECTED       0x00000001
#define RNDIS_FILTER_MULTICAST      0x00000002
#define RNDIS_FILTER_ALL_MULTICAST  0x00000004
#define RNDIS_FILTER_BROADCAST      0x00000008

#define CDC_SEND_ENCAP  0x00
#define CDC_GET_ENCAP   0x01

#define USB_TIMEOUT     5000
#define BUF_SIZE        0x4000

#pragma pack(push, 1)

struct rndis_init {
    uint32_t msg_type;
    uint32_t msg_len;
    uint32_t request_id;
    uint32_t major;
    uint32_t minor;
    uint32_t max_xfer;
};

struct rndis_init_c {
    uint32_t msg_type;
    uint32_t msg_len;
    uint32_t request_id;
    uint32_t status;
    uint32_t major;
    uint32_t minor;
    uint32_t device_flags;
    uint32_t medium;
    uint32_t max_pkts;
    uint32_t max_xfer;
    uint32_t pkt_align;
    uint32_t reserved[2];
};

struct rndis_query {
    uint32_t msg_type;
    uint32_t msg_len;
    uint32_t request_id;
    uint32_t oid;
    uint32_t len;
    uint32_t offset;
    uint32_t reserved;
};

struct rndis_query_c {
    uint32_t msg_type;
    uint32_t msg_len;
    uint32_t request_id;
    uint32_t status;
    uint32_t len;
    uint32_t offset;
};

struct rndis_set {
    uint32_t msg_type;
    uint32_t msg_len;
    uint32_t request_id;
    uint32_t oid;
    uint32_t len;
    uint32_t offset;
    uint32_t reserved;
};

struct rndis_set_c {
    uint32_t msg_type;
    uint32_t msg_len;
    uint32_t request_id;
    uint32_t status;
};

struct rndis_data_hdr {
    uint32_t msg_type;
    uint32_t msg_len;
    uint32_t data_offset;
    uint32_t data_len;
    uint32_t oob_offset;
    uint32_t oob_len;
    uint32_t num_oob;
    uint32_t ppi_offset;
    uint32_t ppi_len;
    uint32_t reserved[2];
};

struct eth_hdr {
    uint8_t  dst[6];
    uint8_t  src[6];
    uint16_t type;
};

struct arp_pkt {
    uint16_t hw_type;
    uint16_t proto;
    uint8_t  hw_len;
    uint8_t  proto_len;
    uint16_t opcode;
    uint8_t  sender_mac[6];
    uint8_t  sender_ip[4];
    uint8_t  target_mac[6];
    uint8_t  target_ip[4];
};

struct ip_hdr {
    uint8_t  ver_ihl;
    uint8_t  tos;
    uint16_t tot_len;
    uint16_t id;
    uint16_t frag;
    uint8_t  ttl;
    uint8_t  proto;
    uint16_t checksum;
    uint32_t saddr;
    uint32_t daddr;
};

struct udp_hdr {
    uint16_t sport;
    uint16_t dport;
    uint16_t len;
    uint16_t checksum;
};

struct dhcp_pkt {
    uint8_t  op;
    uint8_t  htype;
    uint8_t  hlen;
    uint8_t  hops;
    uint32_t xid;
    uint16_t secs;
    uint16_t flags;
    uint32_t ciaddr;
    uint32_t yiaddr;
    uint32_t siaddr;
    uint32_t giaddr;
    uint8_t  chaddr[16];
    uint8_t  sname[64];
    uint8_t  file[128];
    uint32_t cookie;
};

#pragma pack(pop)

#define DHCP_COOKIE     0x63538263
#define DHCP_DISCOVER   1
#define DHCP_OFFER      2
#define DHCP_REQUEST    3
#define DHCP_ACK        5

#define ETH_IP          0x0008
#define ETH_ARP         0x0608
#define ETH_IPV6        0xDD86

#define ARP_REQUEST     0x0100
#define ARP_REPLY       0x0200

// ============================================================
// Global state
// ============================================================

static volatile sig_atomic_t running = 1;

static libusb_device_handle *udev = NULL;
static int ctrl_iface = 0;
static int data_iface = 1;
static uint8_t ep_in  = 0x81;
static uint8_t ep_out = 0x01;
static uint32_t req_id = 1;

static uint8_t my_mac[6];
static uint8_t gw_mac[6];
static uint32_t my_ip;
static uint32_t gw_ip;
static uint32_t mask;
static uint32_t dns;

static int utun_fd = -1;
static char utun_name[IFNAMSIZ];
static bool use_default_route = false;
static char saved_gw[64] = "";     // default gateway that existed before we started
static char phone_gw[64] = "";     // the phone's gateway (our desired default)
static int mtu_override = 1500;
static volatile int guard_stop = 0;
static char test_ip[64] = "";      // extra host route via phone (test mode), for throughput measurement

static void on_signal(int s) { (void)s; running = 0; }

#define MAC_FMT "%02x:%02x:%02x:%02x:%02x:%02x"
#define MAC_ARG(m) (m)[0],(m)[1],(m)[2],(m)[3],(m)[4],(m)[5]
#define IP_FMT  "%d.%d.%d.%d"
#define IP_ARG(ip) ((ip)&0xff),(((ip)>>8)&0xff),(((ip)>>16)&0xff),(((ip)>>24)&0xff)

// ============================================================
// RNDIS USB commands
// ============================================================

#define RNDIS_MSG_KEEPALIVE     0x00000008
#define RNDIS_MSG_KEEPALIVE_C   0x80000008
#define RNDIS_MSG_INDICATE      0x00000007

static pthread_mutex_t ctrl_lock = PTHREAD_MUTEX_INITIALIZER;

static int ctrl_send(void *msg, int len) {
    return libusb_control_transfer(udev,
        LIBUSB_REQUEST_TYPE_CLASS | LIBUSB_RECIPIENT_INTERFACE,
        CDC_SEND_ENCAP, 0, ctrl_iface, msg, len, USB_TIMEOUT);
}

static int ctrl_recv(void *buf, int max) {
    return libusb_control_transfer(udev,
        LIBUSB_REQUEST_TYPE_CLASS | LIBUSB_RECIPIENT_INTERFACE | LIBUSB_ENDPOINT_IN,
        CDC_GET_ENCAP, 0, ctrl_iface, buf, max, USB_TIMEOUT);
}

// Handle unsolicited device->host messages: answer keepalives, log status
static void handle_unsolicited(uint8_t *msg, int len) {
    if (len < 12) return;
    uint32_t *w = (uint32_t *)msg;

    if (w[0] == RNDIS_MSG_KEEPALIVE) {
        uint32_t reply[4] = { RNDIS_MSG_KEEPALIVE_C, 16, w[2], 0 };
        ctrl_send(reply, 16);
        printf("  [rndis: answered device keepalive id=%u]\n", w[2]);
    } else if (w[0] == RNDIS_MSG_INDICATE) {
        uint32_t status = (len >= 16) ? w[3] : 0;
        printf("  [rndis: INDICATE_STATUS 0x%08x %s]\n", status,
               status == 0x4001000B ? "(media connect)" :
               status == 0x4001000C ? "(media disconnect)" : "");
    } else {
        printf("  [rndis: unsolicited msg type=0x%08x len=%d]\n", w[0], len);
    }
}

// Send a command, drain the response queue until we see the expected
// completion type; answer any unsolicited messages along the way.
static int rndis_cmd(void *cmd, int cmd_len, uint32_t expect_type, void *resp, int resp_max) {
    pthread_mutex_lock(&ctrl_lock);

    int r = ctrl_send(cmd, cmd_len);
    if (r < 0) {
        fprintf(stderr, "RNDIS send failed: %s\n", libusb_error_name(r));
        pthread_mutex_unlock(&ctrl_lock);
        return -1;
    }

    uint8_t buf[512];
    for (int i = 0; i < 25; i++) {
        r = ctrl_recv(buf, sizeof(buf));
        if (r >= 12) {
            uint32_t type = *(uint32_t *)buf;
            if (type == expect_type) {
                int copy = r < resp_max ? r : resp_max;
                memcpy(resp, buf, copy);
                pthread_mutex_unlock(&ctrl_lock);
                return copy;
            }
            handle_unsolicited(buf, r);
            continue;
        }
        usleep(20000);
    }
    pthread_mutex_unlock(&ctrl_lock);
    fprintf(stderr, "RNDIS response timeout (wanted 0x%08x)\n", expect_type);
    return -1;
}

// Called by the interrupt poller when device signals RESPONSE_AVAILABLE
static void drain_ctrl_queue(void) {
    pthread_mutex_lock(&ctrl_lock);
    for (int i = 0; i < 4; i++) {
        uint8_t buf[512];
        int r = ctrl_recv(buf, sizeof(buf));
        if (r < 12) break;
        handle_unsolicited(buf, r);
    }
    pthread_mutex_unlock(&ctrl_lock);
}

static int rndis_init(void) {
    struct rndis_init msg = {
        .msg_type = RNDIS_MSG_INIT,
        .msg_len  = sizeof(msg),
        .request_id = req_id++,
        .major = RNDIS_MAJOR_VERSION,
        .minor = RNDIS_MINOR_VERSION,
        .max_xfer = RNDIS_MAX_XFER,
    };
    struct rndis_init_c resp;
    int r = rndis_cmd(&msg, sizeof(msg), RNDIS_MSG_INIT_C, &resp, sizeof(resp));
    if (r < 0) return -1;
    if (resp.status != 0) {
        fprintf(stderr, "RNDIS init rejected: 0x%x\n", resp.status);
        return -1;
    }
    printf("  RNDIS init OK (max_xfer=%u)\n", resp.max_xfer);
    return 0;
}

static int rndis_query_mac(uint8_t *mac_out) {
    struct rndis_query msg = {
        .msg_type = RNDIS_MSG_QUERY,
        .msg_len  = sizeof(msg),
        .request_id = req_id++,
        .oid = OID_802_3_PERMANENT_ADDRESS,
        .len = 0,
        .offset = 20,
    };
    uint8_t resp[256];
    int r = rndis_cmd(&msg, sizeof(msg), RNDIS_MSG_QUERY_C, resp, sizeof(resp));
    if (r < 0) return -1;

    struct rndis_query_c *qc = (struct rndis_query_c *)resp;
    if (qc->status != 0) {
        fprintf(stderr, "MAC query failed: 0x%x\n", qc->status);
        return -1;
    }
    memcpy(mac_out, resp + 8 + qc->offset, 6);
    return 0;
}

// Query a 4-byte OID value (returns -1 on failure)
static int rndis_query_u32(uint32_t oid, uint32_t *out) {
    struct rndis_query msg = {
        .msg_type = RNDIS_MSG_QUERY,
        .msg_len  = sizeof(msg),
        .request_id = req_id++,
        .oid = oid,
        .len = 0,
        .offset = 20,
    };
    uint8_t resp[256];
    int r = rndis_cmd(&msg, sizeof(msg), RNDIS_MSG_QUERY_C, resp, sizeof(resp));
    if (r < 0) return -1;
    struct rndis_query_c *qc = (struct rndis_query_c *)resp;
    if (qc->status != 0 || qc->len < 4) return -1;
    memcpy(out, resp + 8 + qc->offset, 4);
    return 0;
}

static int rndis_set_filter(void) {
    struct {
        struct rndis_set hdr;
        uint32_t filter;
    } msg = {
        .hdr = {
            .msg_type = RNDIS_MSG_SET,
            .msg_len  = sizeof(msg),
            .request_id = req_id++,
            .oid = OID_GEN_CURRENT_PACKET_FILTER,
            .len = 4,
            .offset = 20,
        },
        .filter = RNDIS_FILTER_DIRECTED | RNDIS_FILTER_BROADCAST | RNDIS_FILTER_ALL_MULTICAST,
    };
    struct rndis_set_c resp;
    int r = rndis_cmd(&msg, sizeof(msg), RNDIS_MSG_SET_C, &resp, sizeof(resp));
    if (r < 0) return -1;
    if (resp.status != 0) {
        fprintf(stderr, "Set filter failed: 0x%x\n", resp.status);
        return -1;
    }
    return 0;
}

// ============================================================
// USB bulk I/O wrappers
// ============================================================

static int usb_read(uint8_t *buf, int len) {
    int actual = 0;
    int r = libusb_bulk_transfer(udev, ep_in, buf, len, &actual, 1000);
    if (r == LIBUSB_ERROR_TIMEOUT) return 0;
    if (r == LIBUSB_ERROR_NO_DEVICE) return -2;
    if (r < 0) return -1;
    return actual;
}

static int usb_write(uint8_t *buf, int len) {
    int actual = 0;
    int r = libusb_bulk_transfer(udev, ep_out, buf, len, &actual, USB_TIMEOUT);
    if (r < 0) return -1;
    return actual;
}

// ============================================================
// Send raw Ethernet frame via RNDIS
// ============================================================

static int rndis_send_eth(uint8_t *frame, int frame_len) {
    uint8_t buf[BUF_SIZE];
    struct rndis_data_hdr *hdr = (struct rndis_data_hdr *)buf;
    int total = sizeof(*hdr) + frame_len;
    if (total > BUF_SIZE) return -1;

    memset(hdr, 0, sizeof(*hdr));
    hdr->msg_type    = RNDIS_MSG_PACKET;
    hdr->msg_len     = total;
    hdr->data_offset = sizeof(*hdr) - 8;
    hdr->data_len    = frame_len;
    memcpy(buf + sizeof(*hdr), frame, frame_len);

    return usb_write(buf, total);
}

// ============================================================
// Receive Ethernet frame from RNDIS (strips RNDIS header)
// ============================================================

// A single USB transfer may contain MULTIPLE concatenated RNDIS packets.
// Keep leftover state between calls so every packet is delivered.
static uint8_t rx_buf[BUF_SIZE];
static int rx_len = 0;
static int rx_off = 0;

static int rndis_recv_eth(uint8_t *frame_out, int max_len) {
    for (;;) {
        // Try to consume the next message from the current buffer
        while (rx_off + (int)sizeof(struct rndis_data_hdr) <= rx_len) {
            struct rndis_data_hdr *hdr = (struct rndis_data_hdr *)(rx_buf + rx_off);
            int msg_len = hdr->msg_len;

            if (msg_len < (int)sizeof(struct rndis_data_hdr) ||
                rx_off + msg_len > rx_len) {
                break;  // malformed/truncated: drop remainder
            }

            int frame_off = rx_off + 8 + hdr->data_offset;
            int frame_len = hdr->data_len;
            rx_off += msg_len;

            if (hdr->msg_type != RNDIS_MSG_PACKET) continue;
            if (frame_len <= 0 || frame_off + frame_len > rx_len) continue;
            if (frame_len > max_len) continue;

            memcpy(frame_out, rx_buf + frame_off, frame_len);
            return frame_len;
        }

        // Buffer exhausted: read the next USB transfer
        rx_off = 0;
        rx_len = usb_read(rx_buf, sizeof(rx_buf));
        if (rx_len <= 0) return rx_len;
    }
}

// ============================================================
// IP checksum
// ============================================================

static uint16_t ip_checksum(void *data, int len) {
    uint32_t sum = 0;
    uint16_t *p = data;
    while (len > 1) { sum += *p++; len -= 2; }
    if (len == 1) sum += *(uint8_t *)p;
    while (sum >> 16) sum = (sum & 0xffff) + (sum >> 16);
    return ~sum;
}

// ============================================================
// DHCP client (minimal)
// ============================================================

static uint32_t dhcp_xid;

static int build_dhcp_frame(uint8_t *buf, int type, uint32_t offered_ip, uint32_t server_ip) {
    memset(buf, 0, 400);
    struct eth_hdr *eth = (struct eth_hdr *)buf;
    memset(eth->dst, 0xff, 6);
    memcpy(eth->src, my_mac, 6);
    eth->type = ETH_IP;

    struct ip_hdr *ip = (struct ip_hdr *)(buf + 14);
    ip->ver_ihl = 0x45;
    ip->ttl = 64;
    ip->proto = 17;
    ip->saddr = 0;
    ip->daddr = 0xffffffff;

    struct udp_hdr *udp = (struct udp_hdr *)(buf + 34);
    udp->sport = htons(68);
    udp->dport = htons(67);

    struct dhcp_pkt *dhcp = (struct dhcp_pkt *)(buf + 42);
    dhcp->op = 1;
    dhcp->htype = 1;
    dhcp->hlen = 6;
    dhcp->xid = dhcp_xid;
    dhcp->flags = htons(0x8000);
    memcpy(dhcp->chaddr, my_mac, 6);
    dhcp->cookie = DHCP_COOKIE;

    uint8_t *opt = buf + 42 + sizeof(struct dhcp_pkt);
    *opt++ = 53; *opt++ = 1; *opt++ = type;

    if (type == DHCP_REQUEST) {
        *opt++ = 50; *opt++ = 4;
        memcpy(opt, &offered_ip, 4); opt += 4;
        *opt++ = 54; *opt++ = 4;
        memcpy(opt, &server_ip, 4); opt += 4;
    }

    *opt++ = 55; *opt++ = 3; *opt++ = 1; *opt++ = 3; *opt++ = 6;
    *opt++ = 255;

    int dhcp_len = (int)(opt - (buf + 42));
    if (dhcp_len < 300) dhcp_len = 300;

    int udp_len = 8 + dhcp_len;
    udp->len = htons(udp_len);

    int ip_len = 20 + udp_len;
    ip->tot_len = htons(ip_len);
    ip->checksum = 0;
    ip->checksum = ip_checksum(ip, 20);

    return 14 + ip_len;
}

static bool parse_dhcp_response(uint8_t *frame, int len, int expected_type,
                                uint32_t *out_ip, uint32_t *out_gw,
                                uint32_t *out_mask, uint32_t *out_dns,
                                uint32_t *out_server) {
    if (len < 14 + 20 + 8 + (int)sizeof(struct dhcp_pkt)) return false;

    struct eth_hdr *eth = (struct eth_hdr *)frame;
    if (eth->type != ETH_IP) return false;

    struct ip_hdr *ip = (struct ip_hdr *)(frame + 14);
    if (ip->proto != 17) return false;

    struct udp_hdr *udp = (struct udp_hdr *)(frame + 14 + (ip->ver_ihl & 0xf) * 4);
    if (ntohs(udp->sport) != 67 || ntohs(udp->dport) != 68) return false;

    int ip_hdr_len = (ip->ver_ihl & 0xf) * 4;
    struct dhcp_pkt *dhcp = (struct dhcp_pkt *)(frame + 14 + ip_hdr_len + 8);
    if (dhcp->xid != dhcp_xid) return false;
    if (dhcp->cookie != DHCP_COOKIE) return false;

    *out_ip = dhcp->yiaddr;
    memcpy(gw_mac, eth->src, 6);

    uint8_t *opt = (uint8_t *)dhcp + sizeof(struct dhcp_pkt);
    uint8_t *end = frame + len;
    int msg_type = -1;

    while (opt < end && *opt != 255) {
        if (*opt == 0) { opt++; continue; }
        uint8_t code = *opt++;
        if (opt >= end) break;
        uint8_t olen = *opt++;
        if (opt + olen > end) break;

        switch (code) {
        case 53: msg_type = opt[0]; break;
        case 1:  memcpy(out_mask, opt, 4); break;
        case 3:  memcpy(out_gw, opt, 4); break;
        case 6:  memcpy(out_dns, opt, 4); break;
        case 54: memcpy(out_server, opt, 4); break;
        }
        opt += olen;
    }

    return msg_type == expected_type;
}

static int do_dhcp(void) {
    dhcp_xid = 0x42424242;

    uint8_t frame[600];
    uint8_t recv[BUF_SIZE];
    uint32_t offered_ip = 0, server_ip = 0;
    uint32_t r_gw = 0, r_mask = 0, r_dns = 0;

    for (int attempt = 0; attempt < 4 && !offered_ip && running; attempt++) {
        int flen = build_dhcp_frame(frame, DHCP_DISCOVER, 0, 0);
        printf("  Sending DHCP Discover (attempt %d)...\n", attempt + 1);
        if (rndis_send_eth(frame, flen) < 0) return -1;

        for (int i = 0; i < 8 && running; i++) {
            int n = rndis_recv_eth(recv, sizeof(recv));
            if (n == -2) return -2;  // device gone
            if (n <= 0) continue;
            struct eth_hdr *dbg_eth = (struct eth_hdr *)recv;
            printf("  [rx %d bytes, ethertype=0x%04x, src=" MAC_FMT "]\n",
                   n, ntohs(dbg_eth->type), MAC_ARG(dbg_eth->src));
            if (parse_dhcp_response(recv, n, DHCP_OFFER, &offered_ip, &r_gw, &r_mask, &r_dns, &server_ip)) {
                printf("  Got DHCP Offer: ip=" IP_FMT "\n", IP_ARG(offered_ip));
                break;
            }
        }
    }
    if (!offered_ip) { fprintf(stderr, "  No DHCP offer received\n"); return -1; }

    int flen = build_dhcp_frame(frame, DHCP_REQUEST, offered_ip, server_ip);
    printf("  Sending DHCP Request...\n");
    if (rndis_send_eth(frame, flen) < 0) return -1;

    for (int i = 0; i < 100 && running; i++) {
        int n = rndis_recv_eth(recv, sizeof(recv));
        if (n == -2) return -2;
        if (n <= 0) continue;
        uint32_t ack_ip = 0, ack_srv = 0;
        if (parse_dhcp_response(recv, n, DHCP_ACK, &ack_ip, &r_gw, &r_mask, &r_dns, &ack_srv)) {
            my_ip = ack_ip;
            gw_ip = r_gw;
            mask  = r_mask;
            dns   = r_dns;
            printf("  DHCP ACK: ip=" IP_FMT " gw=" IP_FMT " mask=" IP_FMT " dns=" IP_FMT "\n",
                   IP_ARG(my_ip), IP_ARG(gw_ip), IP_ARG(mask), IP_ARG(dns));
            printf("  Gateway MAC: " MAC_FMT "\n", MAC_ARG(gw_mac));
            return 0;
        }
    }
    fprintf(stderr, "No DHCP ACK received\n");
    return -1;
}

// ============================================================
// ARP handler
// ============================================================

static void handle_arp(uint8_t *frame, int len) {
    if (len < 14 + (int)sizeof(struct arp_pkt)) return;
    struct arp_pkt *arp = (struct arp_pkt *)(frame + 14);

    if (arp->opcode != ARP_REQUEST) return;

    uint32_t target;
    memcpy(&target, arp->target_ip, 4);
    if (target != my_ip) return;

    uint8_t reply[64];
    struct eth_hdr *eth = (struct eth_hdr *)reply;
    memcpy(eth->dst, arp->sender_mac, 6);
    memcpy(eth->src, my_mac, 6);
    eth->type = ETH_ARP;

    struct arp_pkt *ra = (struct arp_pkt *)(reply + 14);
    ra->hw_type   = htons(1);
    ra->proto     = htons(0x0800);
    ra->hw_len    = 6;
    ra->proto_len = 4;
    ra->opcode    = ARP_REPLY;
    memcpy(ra->sender_mac, my_mac, 6);
    memcpy(ra->sender_ip, &my_ip, 4);
    memcpy(ra->target_mac, arp->sender_mac, 6);
    memcpy(ra->target_ip, arp->sender_ip, 4);

    rndis_send_eth(reply, 14 + sizeof(struct arp_pkt));
}

// ============================================================
// utun
// ============================================================

static int open_utun(void) {
    int fd = socket(PF_SYSTEM, SOCK_DGRAM, SYSPROTO_CONTROL);
    if (fd < 0) { perror("utun socket"); return -1; }

    struct ctl_info ci = {0};
    strlcpy(ci.ctl_name, UTUN_CONTROL_NAME, sizeof(ci.ctl_name));
    if (ioctl(fd, CTLIOCGINFO, &ci) < 0) { perror("utun ctl_info"); close(fd); return -1; }

    struct sockaddr_ctl sc = {
        .sc_len     = sizeof(sc),
        .sc_family  = AF_SYSTEM,
        .ss_sysaddr = AF_SYS_CONTROL,
        .sc_id      = ci.ctl_id,
        .sc_unit    = 0,
    };

    for (int unit = 10; unit < 30; unit++) {
        sc.sc_unit = unit;
        if (connect(fd, (struct sockaddr *)&sc, sizeof(sc)) == 0) {
            snprintf(utun_name, sizeof(utun_name), "utun%d", unit - 1);
            printf("  Opened %s\n", utun_name);
            return fd;
        }
    }

    perror("utun connect");
    close(fd);
    return -1;
}

static int configure_utun(void) {
    char ip_str[INET_ADDRSTRLEN], gw_str[INET_ADDRSTRLEN], mask_str[INET_ADDRSTRLEN];
    inet_ntop(AF_INET, &my_ip, ip_str, sizeof(ip_str));
    inet_ntop(AF_INET, &gw_ip, gw_str, sizeof(gw_str));
    inet_ntop(AF_INET, &mask, mask_str, sizeof(mask_str));

    char cmd[256];
    // MTU 1400 leaves headroom for a VPN running ON the phone (WireGuard/NordLynx
    // etc. add ~60-80B). Without this, full 1500B packets get black-holed.
    snprintf(cmd, sizeof(cmd), "ifconfig %s inet %s %s netmask %s mtu %d up",
             utun_name, ip_str, gw_str, mask_str, mtu_override);
    printf("  %s\n", cmd);
    if (system(cmd) != 0) { fprintf(stderr, "ifconfig failed\n"); return -1; }

    if (use_default_route) {
        // Remember the existing default gateway so we can restore it on exit
        FILE *fp = popen("route -n get default 2>/dev/null | awk '/gateway:/{print $2}'", "r");
        if (fp) {
            if (fgets(saved_gw, sizeof(saved_gw), fp))
                saved_gw[strcspn(saved_gw, "\n")] = 0;
            pclose(fp);
        }
        if (saved_gw[0])
            printf("  (saving current default gateway %s for restore on exit)\n", saved_gw);

        snprintf(phone_gw, sizeof(phone_gw), "%s", gw_str);
        system("route -n delete default >/dev/null 2>&1");
        snprintf(cmd, sizeof(cmd), "route -n add default %s", gw_str);
        printf("  %s\n", cmd);
        system(cmd);
    } else {
        // Safe test route(s) only: send specific IPs via the phone, leaving the
        // machine's default route (Wi-Fi etc.) untouched. 1.1.1.1 is always
        // added for a quick ping; --test-ip adds a throughput target too.
        snprintf(cmd, sizeof(cmd), "route add 1.1.1.1 %s", gw_str);
        printf("  %s\n", cmd);
        system(cmd);
        if (test_ip[0]) {
            snprintf(cmd, sizeof(cmd), "route add %s %s", test_ip, gw_str);
            printf("  %s\n", cmd);
            system(cmd);
        }
        printf("\n  Test with:  ping 1.1.1.1%s%s\n",
               test_ip[0] ? "   (throughput target routed: " : "",
               test_ip[0] ? test_ip : "");
        printf("  (run with --default-route to route ALL traffic via the phone)\n");
    }

    if (dns) {
        char dns_str[INET_ADDRSTRLEN];
        inet_ntop(AF_INET, &dns, dns_str, sizeof(dns_str));
        if (use_default_route) {
            // Register the phone's DNS with the system resolver (like VPN clients do)
            char scmd[512];
            snprintf(scmd, sizeof(scmd),
                "printf 'd.init\\nd.add Addresses * %s\\nd.add InterfaceName %s\\n"
                "set State:/Network/Service/macdroid_tether/IPv4\\n"
                "d.init\\nd.add ServerAddresses * %s\\n"
                "set State:/Network/Service/macdroid_tether/DNS\\nquit\\n' | scutil",
                ip_str, utun_name, dns_str);
            system(scmd);
            printf("  DNS registered with system resolver: %s\n", dns_str);
        } else {
            printf("  DNS: %s\n", dns_str);
        }
    }

    return 0;
}

// macOS ranks Wi-Fi above a utun, so it re-installs the Wi-Fi default route on
// every network change. This guard reasserts the phone as the default route
// whenever something else has stolen it — so the USB path stays primary and the
// user can safely turn Wi-Fi off.
static void *route_guard_thread(void *arg) {
    (void)arg;
    char iface[64];
    char cmd[128];
    while (running && !guard_stop) {
        iface[0] = 0;
        FILE *fp = popen("route -n get default 2>/dev/null | awk '/interface:/{print $2}'", "r");
        if (fp) {
            if (fgets(iface, sizeof(iface), fp))
                iface[strcspn(iface, "\n")] = 0;
            pclose(fp);
        }
        // If the default route isn't already on our utun, take it back.
        if (strcmp(iface, utun_name) != 0 && phone_gw[0]) {
            system("route -n delete default >/dev/null 2>&1");
            snprintf(cmd, sizeof(cmd), "route -n add default %s >/dev/null 2>&1", phone_gw);
            system(cmd);
        }
        for (int i = 0; i < 20 && running && !guard_stop; i++) usleep(100000); // ~2s
    }
    return NULL;
}

// ============================================================
// Interrupt endpoint poller (keeps link alive)
// ============================================================

static volatile int intr_stop = 0;

static void *interrupt_poll_thread(void *arg) {
    (void)arg;
    uint8_t buf[16];
    while (running && !intr_stop) {
        int actual = 0;
        int r = libusb_interrupt_transfer(udev, 0x82, buf, sizeof(buf), &actual, 2000);
        if (r == LIBUSB_ERROR_NO_DEVICE) break;   // device unplugged/re-enumerated
        if (r < 0 && r != LIBUSB_ERROR_TIMEOUT) usleep(100000);
        if (actual >= 8 && *(uint32_t *)buf == 1) {
            // RESPONSE_AVAILABLE: fetch and handle whatever is queued
            drain_ctrl_queue();
        }
    }
    return NULL;
}

// ============================================================
// Packet pump threads
// ============================================================

static void *usb_to_utun_thread(void *arg) {
    (void)arg;
    uint8_t frame[BUF_SIZE];
    uint8_t pkt[BUF_SIZE];

    while (running) {
        int n = rndis_recv_eth(frame, sizeof(frame));
        if (n <= 0) continue;
        if (n < 14) continue;

        struct eth_hdr *eth = (struct eth_hdr *)frame;

        if (eth->type == ETH_ARP) {
            handle_arp(frame, n);
            continue;
        }

        int af;
        if (eth->type == ETH_IP) af = AF_INET;
        else if (eth->type == ETH_IPV6) af = AF_INET6;
        else continue;

        int payload_len = n - 14;
        uint32_t af_net = htonl(af);
        memcpy(pkt, &af_net, 4);
        memcpy(pkt + 4, frame + 14, payload_len);

        ssize_t w = write(utun_fd, pkt, 4 + payload_len);
        if (w < 0 && errno != EAGAIN)
            perror("utun write");
    }
    return NULL;
}

static void *utun_to_usb_thread(void *arg) {
    (void)arg;
    uint8_t pkt[BUF_SIZE];
    uint8_t frame[BUF_SIZE];

    while (running) {
        ssize_t n = read(utun_fd, pkt, sizeof(pkt));
        if (n <= 4) continue;

        uint32_t af_net;
        memcpy(&af_net, pkt, 4);
        uint32_t af = ntohl(af_net);

        struct eth_hdr *eth = (struct eth_hdr *)frame;
        memcpy(eth->dst, gw_mac, 6);
        memcpy(eth->src, my_mac, 6);

        if (af == AF_INET)       eth->type = ETH_IP;
        else if (af == AF_INET6) eth->type = ETH_IPV6;
        else continue;

        int payload_len = (int)n - 4;
        memcpy(frame + 14, pkt + 4, payload_len);

        rndis_send_eth(frame, 14 + payload_len);
    }
    return NULL;
}

// ============================================================
// USB device open
// ============================================================

static int open_device(void) {
    if (libusb_init(NULL) < 0) {
        fprintf(stderr, "libusb_init failed\n");
        return -1;
    }
    libusb_set_option(NULL, LIBUSB_OPTION_LOG_LEVEL, LIBUSB_LOG_LEVEL_ERROR);

    libusb_device **devs;
    ssize_t cnt = libusb_get_device_list(NULL, &devs);
    libusb_device *found = NULL;

    for (ssize_t i = 0; i < cnt; i++) {
        struct libusb_device_descriptor desc;
        libusb_get_device_descriptor(devs[i], &desc);

        struct libusb_config_descriptor *config;
        if (libusb_get_active_config_descriptor(devs[i], &config) < 0) continue;

        for (int j = 0; j < config->bNumInterfaces; j++) {
            const struct libusb_interface_descriptor *alt = &config->interface[j].altsetting[0];
            if ((alt->bInterfaceClass == 0xE0 && alt->bInterfaceSubClass == 1 && alt->bInterfaceProtocol == 3) ||
                (alt->bInterfaceClass == 0xEF && alt->bInterfaceSubClass == 4 && alt->bInterfaceProtocol == 1) ||
                (alt->bInterfaceClass == 0x02 && alt->bInterfaceSubClass == 2 && alt->bInterfaceProtocol == 0xFF)) {
                found = devs[i];
                ctrl_iface = alt->bInterfaceNumber;

                if (j + 1 < config->bNumInterfaces) {
                    const struct libusb_interface_descriptor *data_alt = &config->interface[j+1].altsetting[0];
                    if (data_alt->bInterfaceClass == 0x0A) {
                        data_iface = data_alt->bInterfaceNumber;
                        for (int e = 0; e < data_alt->bNumEndpoints; e++) {
                            if (data_alt->endpoint[e].bEndpointAddress & 0x80)
                                ep_in = data_alt->endpoint[e].bEndpointAddress;
                            else
                                ep_out = data_alt->endpoint[e].bEndpointAddress;
                        }
                    }
                }
                break;
            }
        }
        libusb_free_config_descriptor(config);
        if (found) break;
    }

    if (!found) {
        fprintf(stderr, "No RNDIS device found. Is USB tethering enabled?\n");
        libusb_free_device_list(devs, 1);
        return -1;
    }

    int r = libusb_open(found, &udev);
    libusb_free_device_list(devs, 1);
    if (r < 0) {
        fprintf(stderr, "libusb_open failed: %s\n", libusb_error_name(r));
        return -1;
    }

    // Detach kernel drivers — critical on macOS where CDC drivers
    // claim the interfaces and consume all bulk data
    for (int i = 0; i <= 1; i++) {
        int iface = (i == 0) ? ctrl_iface : data_iface;
        if (libusb_kernel_driver_active(udev, iface) == 1) {
            r = libusb_detach_kernel_driver(udev, iface);
            printf("  detach_kernel_driver(iface %d): %s\n", iface, libusb_error_name(r));
        }
    }

    if ((r = libusb_claim_interface(udev, ctrl_iface)) < 0) {
        fprintf(stderr, "Claim control iface %d: %s\n", ctrl_iface, libusb_error_name(r));
        return -1;
    }
    if ((r = libusb_claim_interface(udev, data_iface)) < 0) {
        fprintf(stderr, "Claim data iface %d: %s\n", data_iface, libusb_error_name(r));
        return -1;
    }

    printf("  USB: ctrl=%d data=%d ep_in=0x%02x ep_out=0x%02x\n",
           ctrl_iface, data_iface, ep_in, ep_out);

    // RNDIS data interface has a single alt setting; sending SET_INTERFACE
    // re-triggers the gadget's set_alt handler -> gether_connect -> carrier up
    r = libusb_set_interface_alt_setting(udev, data_iface, 0);
    printf("  set_alt(data, 0): %s\n", libusb_error_name(r));

    r = libusb_clear_halt(udev, ep_in);
    printf("  clear_halt(ep_in): %s\n", libusb_error_name(r));
    r = libusb_clear_halt(udev, ep_out);
    printf("  clear_halt(ep_out): %s\n", libusb_error_name(r));

    // Verify kernel drivers are detached
    for (int i = 0; i <= 1; i++) {
        int iface = (i == 0) ? ctrl_iface : data_iface;
        int active = libusb_kernel_driver_active(udev, iface);
        printf("  kernel_driver_active(iface %d): %d %s\n", iface, active,
               active == 1 ? "** STILL ACTIVE — will likely fail **" : "(good)");
    }

    return 0;
}

// ============================================================
// main
// ============================================================

static void close_device(void) {
    if (!udev) return;
    libusb_release_interface(udev, ctrl_iface);
    libusb_release_interface(udev, data_iface);
    libusb_close(udev);
    udev = NULL;
}

// One connection attempt: open device, RNDIS handshake, DHCP.
// Returns 0 on success (udev stays open, intr thread running), -1 to retry.
static int run_session(pthread_t *intr_thread) {
    printf("[1] Opening USB device...\n");
    if (open_device() < 0) return -1;

    rx_len = rx_off = 0;   // reset RX buffer state from any prior session
    printf("[2] RNDIS handshake...\n");
    if (rndis_init() < 0) goto fail;
    if (rndis_query_mac(my_mac) < 0) goto fail;
    printf("  MAC: " MAC_FMT "\n", MAC_ARG(my_mac));
    if (rndis_set_filter() < 0) goto fail;

    // Diagnostics: read back filter + media status + link speed
    {
        uint32_t v;
        if (rndis_query_u32(0x0001010E, &v) == 0)
            printf("  filter readback: 0x%x\n", v);
        if (rndis_query_u32(0x00010114, &v) == 0)
            printf("  media status: %s\n", v == 0 ? "CONNECTED" : "disconnected");
        if (rndis_query_u32(0x00010107, &v) == 0)
            printf("  link speed: %u (x100 bps)\n", v);
    }

    intr_stop = 0;
    pthread_create(intr_thread, NULL, interrupt_poll_thread, NULL);
    drain_ctrl_queue();

    printf("[3] DHCP...\n");
    if (do_dhcp() == 0) return 0;

    intr_stop = 1;
    pthread_join(*intr_thread, NULL);
fail:
    close_device();
    return -1;
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--default-route") == 0)
            use_default_route = true;
        else if (strcmp(argv[i], "--mtu") == 0 && i + 1 < argc)
            mtu_override = atoi(argv[++i]);
        else if (strcmp(argv[i], "--test-ip") == 0 && i + 1 < argc)
            snprintf(test_ip, sizeof(test_ip), "%s", argv[++i]);
    }
    bool probe_only = (getuid() != 0);
    if (probe_only)
        printf("(not root: probe mode — will test USB/RNDIS/DHCP but skip utun setup)\n");

    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);

    pthread_t intr_thread;
    int tries = 0;
    for (;;) {
        if (run_session(&intr_thread) == 0) break;
        tries++;
        if (!running || tries >= 20) return 1;
        printf("  (retrying in 3s... try %d/20 — you can toggle USB tethering on the phone now)\n", tries);
        sleep(3);
    }

    if (probe_only) {
        printf("\nProbe complete: RNDIS handshake and DHCP both work.\n");
        printf("Run with sudo to bring up the network interface.\n");
        running = 0;
        intr_stop = 1;
        pthread_join(intr_thread, NULL);
        close_device();
        libusb_exit(NULL);
        return 0;
    }

    printf("[4/5] Setting up network interface...\n");
    utun_fd = open_utun();
    if (utun_fd < 0) return 1;
    if (configure_utun() < 0) return 1;

    pthread_t t1, t2, guard;
    pthread_create(&t1, NULL, usb_to_utun_thread, NULL);
    pthread_create(&t2, NULL, utun_to_usb_thread, NULL);
    if (use_default_route) {
        guard_stop = 0;
        pthread_create(&guard, NULL, route_guard_thread, NULL);
        printf("[5/5] Packet pump + route guard running. Press Ctrl+C to stop.\n");
        printf("      USB is now your primary connection — Wi-Fi can be turned off.\n\n");
    } else {
        printf("[5/5] Packet pump running. Press Ctrl+C to stop.\n\n");
    }

    while (running) sleep(1);

    printf("\nShutting down cleanly...\n");
    guard_stop = 1;
    if (use_default_route) pthread_join(guard, NULL);   // stop reasserting before we tear down
    pthread_cancel(intr_thread);
    pthread_cancel(t1);
    pthread_cancel(t2);
    pthread_join(intr_thread, NULL);
    pthread_join(t1, NULL);
    pthread_join(t2, NULL);

    if (use_default_route) {
        // Restore the machine to exactly how it was.
        system("route -n delete default >/dev/null 2>&1");
        // Drop our DNS/IPv4 entries from the system resolver first...
        system("printf 'remove State:/Network/Service/macdroid_tether/IPv4\\n"
               "remove State:/Network/Service/macdroid_tether/DNS\\nquit\\n' | scutil 2>/dev/null");
        // ...then close the utun (below) — macOS reasserts the real primary
        // service's route on interface teardown. Re-add the prior gateway too,
        // as an immediate belt-and-suspenders if it's still valid.
        if (saved_gw[0]) {
            char rcmd[128];
            snprintf(rcmd, sizeof(rcmd), "route -n add default %s >/dev/null 2>&1", saved_gw);
            system(rcmd);
            printf("  restored previous default route (%s)\n", saved_gw);
        }
        printf("  removed our DNS override and default route\n");
    } else {
        system("route delete 1.1.1.1 2>/dev/null");
        if (test_ip[0]) {
            char dcmd[128];
            snprintf(dcmd, sizeof(dcmd), "route delete %s 2>/dev/null", test_ip);
            system(dcmd);
        }
    }

    if (utun_fd >= 0) close(utun_fd);
    if (udev) {
        libusb_release_interface(udev, ctrl_iface);
        libusb_release_interface(udev, data_iface);
        libusb_attach_kernel_driver(udev, ctrl_iface);
        libusb_attach_kernel_driver(udev, data_iface);
        libusb_close(udev);
    }
    libusb_exit(NULL);

    printf("Done.\n");
    return 0;
}
