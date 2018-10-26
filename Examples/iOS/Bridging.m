//
//  Bridging.m
//  TrueTime-iOS
//
//  Created by Michael Sanders on 1/2/18.
//  Copyright © 2018 Instacart. All rights reserved.
//

@import TrueTime;

@interface Bridging : NSObject
@end

@implementation Bridging

- (void)testBridging {
    TrueTimeClient *client = [TrueTimeClient sharedInstance];
    [client startWithPool:@[(id)[NSURL URLWithString:@"time.apple.com"]] port: 123];

    NSDate *now = [[client referenceTime] now];
    NSLog(@"True time: %@", now);
    [client fetchIfNeededWithSuccess:^(NTPReferenceTime *referenceTime) {
        NSLog(@"True time: %@", [referenceTime now]);
    } failure:^(NSError *error) {
        NSLog(@"Error! %@", error);
    }];
}

@end
