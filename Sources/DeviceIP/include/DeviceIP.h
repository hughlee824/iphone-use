#ifndef IPHONE_USE_DEVICE_IP_H
#define IPHONE_USE_DEVICE_IP_H
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
// All operations run on one owned thread; initialize once per isolated process.
// Active IPv6/TCP, at most four owned socket streams and a default 22-second lifetime. Session owners may opt into explicit teardown.
// No listening/routing or host network interfaces. Failures do not replay upper-layer requests.
typedef struct DeviceIP DeviceIP;
typedef bool (*DeviceIPOutput)(void *context, const void *packet, size_t count);
DeviceIP *device_ip_create(const uint8_t local[16], const uint8_t remote[16], DeviceIPOutput output, void *context);
// Call before opening streams; request deadlines and cancellation remain the owner's responsibility.
void device_ip_use_session_lifetime(DeviceIP *stack);
// Optional receive-only UDP endpoint inside this tunnel. Payload is borrowed for the callback.
typedef void (*DeviceIPDatagram)(void *context, uint16_t sourcePort, const uint8_t *payload, size_t length);
void device_ip_receive_udp(DeviceIP *stack, uint16_t port, DeviceIPDatagram receive);
bool device_ip_open(DeviceIP *stack, int ownedSocket, uint16_t remotePort);
bool device_ip_input(DeviceIP *stack, const void *packet, size_t count);
bool device_ip_tick(DeviceIP *stack);
void device_ip_destroy(DeviceIP *stack);
#endif
