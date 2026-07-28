#include "NetToolDarwinBridge.h"

#include <sys/ioctl.h>

int32_t NetToolGetIPv6InterfaceInfo(
    int32_t socketDescriptor,
    unsigned long request,
    void *buffer
) {
    return ioctl(socketDescriptor, request, buffer);
}
