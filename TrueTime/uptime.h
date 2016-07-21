//
//  uptime.h
//  TrueTime
//
//  Created by Michael Sanders on 7/11/16.
//  Copyright © 2016 Instacart. All rights reserved.
//

#ifndef UPTIME_H
#define UPTIME_H
#include <sys/sysctl.h>

int uptime(struct timeval *__nonnull tv);

#endif /* UPTIME_H */
