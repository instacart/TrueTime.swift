//
//  uptime.c
//  NetworkTime
//
//  Created by Michael Sanders on 7/11/16.
//  Copyright © 2016 Instacart. All rights reserved.
//

#include "uptime.h"
#include <assert.h>

int uptime(struct timeval *__nonnull tv) {
    assert(tv != NULL);
    struct timeval now;
    int ret = gettimeofday(&now, NULL);
    if (ret != 0) {
        return ret;
    }

    struct timeval boottime;
    int mib[] = {CTL_KERN, KERN_BOOTTIME};
    size_t size = sizeof(boottime);
    ret = sysctl(mib, 2, &boottime, &size, NULL, 0);
    if (ret == 0) {
        tv->tv_sec = now.tv_sec - boottime.tv_sec;
        tv->tv_usec = now.tv_usec - boottime.tv_usec;
    }
    return ret;
}
