#include <stdio.h>
#include <libusb-1.0/libusb.h>

int main(void) {
    libusb_context *ctx;
    libusb_init(&ctx);

    libusb_device **devs;
    ssize_t cnt = libusb_get_device_list(ctx, &devs);

    for (ssize_t i = 0; i < cnt; i++) {
        struct libusb_device_descriptor desc;
        libusb_get_device_descriptor(devs[i], &desc);

        if (desc.idVendor != 0x04e8)
            continue;

        printf("Samsung device: VID=%04x PID=%04x class=%d/%d/%d\n",
               desc.idVendor, desc.idProduct, desc.bDeviceClass,
               desc.bDeviceSubClass, desc.bDeviceProtocol);

        struct libusb_config_descriptor *config;
        libusb_get_active_config_descriptor(devs[i], &config);

        printf("  %d interfaces:\n", config->bNumInterfaces);
        for (int j = 0; j < config->bNumInterfaces; j++) {
            const struct libusb_interface *iface = &config->interface[j];
            for (int k = 0; k < iface->num_altsetting; k++) {
                const struct libusb_interface_descriptor *alt = &iface->altsetting[k];
                printf("  iface %d alt %d: class=%d sub=%d proto=%d endpoints=%d\n",
                       alt->bInterfaceNumber, alt->bAlternateSetting,
                       alt->bInterfaceClass, alt->bInterfaceSubClass,
                       alt->bInterfaceProtocol, alt->bNumEndpoints);
                for (int e = 0; e < alt->bNumEndpoints; e++) {
                    const struct libusb_endpoint_descriptor *ep = &alt->endpoint[e];
                    printf("    EP 0x%02x: %s, max_packet=%d\n",
                           ep->bEndpointAddress,
                           (ep->bEndpointAddress & 0x80) ? "IN" : "OUT",
                           ep->wMaxPacketSize);
                }
            }
        }
        libusb_free_config_descriptor(config);
    }

    libusb_free_device_list(devs, 1);
    libusb_exit(ctx);
    return 0;
}
