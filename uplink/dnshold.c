// dnshold — make a resolver the Mac's first-choice DNS for exactly as long as
// this process lives.
//
// The values are written with SCDynamicStoreAddTemporaryValue, so configd
// deletes them the moment our session closes: normal exit, Ctrl+C, crash, or
// kill -9. Nothing is ever left behind pointing at a dead resolver.
//
// The DNS entry is a supplemental resolver with an empty match domain and a
// low match order, which outranks every other resolver (Tailscale's included)
// for all names. Search domains are passed through so short tailnet names
// (`ssh cloudy`) still expand.
//
// Usage: sudo dnshold <iface> <iface-ip> <dns-ip> [search-domain ...]

#include <stdio.h>
#include <signal.h>
#include <unistd.h>
#include <SystemConfiguration/SystemConfiguration.h>

#define SERVICE_ID  "mooch-uplink"
#define MATCH_ORDER 100     // lower wins; Tailscale sits around 101400

static volatile sig_atomic_t running = 1;
static void on_signal(int s) { (void)s; running = 0; }

static CFStringRef str(const char *s) {
    return CFStringCreateWithCString(NULL, s, kCFStringEncodingUTF8);
}

static CFArrayRef str_array(const char **v, int n) {
    CFMutableArrayRef a = CFArrayCreateMutable(NULL, n, &kCFTypeArrayCallBacks);
    for (int i = 0; i < n; i++) {
        CFStringRef s = str(v[i]);
        CFArrayAppendValue(a, s);
        CFRelease(s);
    }
    return a;
}

int main(int argc, char **argv) {
    if (argc < 4) {
        fprintf(stderr, "usage: %s <iface> <iface-ip> <dns-ip> [search-domain ...]\n", argv[0]);
        return 2;
    }
    const char *iface = argv[1], *ifip = argv[2], *dnsip = argv[3];

    SCDynamicStoreRef store = SCDynamicStoreCreate(NULL, CFSTR("dnshold"), NULL, NULL);
    if (!store) { fprintf(stderr, "dnshold: SCDynamicStoreCreate failed\n"); return 1; }

    // IPv4 entity: ties the service to our utun AND makes it the primary
    // service (Router + OverridePrimary, as VPN clients do). Without a primary
    // service macOS reports "no network" whenever Wi-Fi is off, and apps that
    // ask first (Chrome: ERR_INTERNET_DISCONNECTED) refuse to even try —
    // although packets would flow fine. The resulting 0/0 route via the utun
    // is harmless: sing-box's more-specific routes already cover everything.
    CFMutableDictionaryRef v4 = CFDictionaryCreateMutable(NULL, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFArrayRef addrs = str_array(&ifip, 1);
    const char *mask = "255.255.255.252";
    CFArrayRef masks = str_array(&mask, 1);
    CFStringRef ifname = str(iface);
    CFStringRef router = str(ifip);
    int one = 1;
    CFNumberRef onen = CFNumberCreate(NULL, kCFNumberIntType, &one);
    CFDictionarySetValue(v4, kSCPropNetIPv4Addresses, addrs);
    CFDictionarySetValue(v4, kSCPropNetIPv4SubnetMasks, masks);
    CFDictionarySetValue(v4, kSCPropInterfaceName, ifname);
    CFDictionarySetValue(v4, kSCPropNetIPv4Router, router);
    CFDictionarySetValue(v4, kSCPropNetOverridePrimary, onen);

    // DNS entity: match everything, ahead of everyone.
    CFMutableDictionaryRef dns = CFDictionaryCreateMutable(NULL, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFArrayRef servers = str_array(&dnsip, 1);
    const char *empty = "";
    CFArrayRef match = str_array(&empty, 1);
    int order = MATCH_ORDER;
    CFNumberRef ordern = CFNumberCreate(NULL, kCFNumberIntType, &order);
    CFArrayRef orders = CFArrayCreate(NULL, (const void **)&ordern, 1, &kCFTypeArrayCallBacks);
    CFDictionarySetValue(dns, kSCPropNetDNSServerAddresses, servers);
    CFDictionarySetValue(dns, kSCPropNetDNSSupplementalMatchDomains, match);
    CFDictionarySetValue(dns, kSCPropNetDNSSupplementalMatchOrders, orders);
    if (argc > 4) {
        CFArrayRef search = str_array((const char **)&argv[4], argc - 4);
        CFDictionarySetValue(dns, kSCPropNetDNSSearchDomains, search);
        CFRelease(search);
    }

    CFStringRef k4  = CFSTR("State:/Network/Service/" SERVICE_ID "/IPv4");
    CFStringRef kdn = CFSTR("State:/Network/Service/" SERVICE_ID "/DNS");
    if (!SCDynamicStoreAddTemporaryValue(store, k4, v4) ||
        !SCDynamicStoreAddTemporaryValue(store, kdn, dns)) {
        // AddTemporaryValue fails if the key already exists (e.g. a stale
        // non-temporary copy); clear and retry once.
        SCDynamicStoreRemoveValue(store, k4);
        SCDynamicStoreRemoveValue(store, kdn);
        if (!SCDynamicStoreAddTemporaryValue(store, k4, v4) ||
            !SCDynamicStoreAddTemporaryValue(store, kdn, dns)) {
            fprintf(stderr, "dnshold: could not register (%s) — are you root?\n",
                    SCErrorString(SCError()));
            return 1;
        }
    }
    printf("dnshold: %s is first-choice DNS via %s (released when this process exits)\n", dnsip, iface);
    fflush(stdout);

    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);
    signal(SIGHUP, on_signal);
    while (running) pause();

    SCDynamicStoreRemoveValue(store, kdn);
    SCDynamicStoreRemoveValue(store, k4);
    CFRelease(store);
    return 0;
}
