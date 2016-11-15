//
//  ntp_types.h
//  TrueTime
//
//  Created by Michael Sanders on 7/11/16.
//  Copyright © 2016 Instacart. All rights reserved.
//

#ifndef NTP_TYPES_H
#define NTP_TYPES_H

#include <stdint.h>

typedef struct {
    uint16_t whole;
    uint16_t fraction;
} __attribute__((packed, aligned(1))) ntp_time32_t;

typedef struct {
    uint32_t whole;
    uint32_t fraction;
} __attribute__((packed, aligned(1))) ntp_time64_t;

typedef ntp_time64_t ntp_time_t;

typedef struct {
    uint8_t client_mode: 3;
    uint8_t version_number: 3;
    uint8_t leap_indicator: 2;

    uint8_t stratum;
    uint8_t poll;
    uint8_t precision;

    ntp_time32_t root_delay;
    ntp_time32_t root_dispersion;
    uint8_t reference_id[4];

    ntp_time_t reference_time;
    ntp_time_t originate_time;
    ntp_time_t receive_time;
    ntp_time_t transmit_time;
} __attribute__((packed, aligned(1))) ntp_packet_t;

#endif /* NTP_TYPES_H */
