#ifndef NetToolDarwinBridge_h
#define NetToolDarwinBridge_h

#include <stdint.h>

int32_t NetToolGetIPv6InterfaceInfo(
    int32_t socketDescriptor,
    unsigned long request,
    void *buffer
);

#endif
