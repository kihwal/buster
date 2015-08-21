//
//  BTRLinkDriverSubclass.h
//  Buster
//
//  Created by Jeremy McDermond on 8/18/15.
//  Copyright (c) 2015 NH6Z. All rights reserved.
//

#import "BTRLinkDriver.h"

#define call_to_nsstring(a) [[NSString alloc] initWithBytes:(a) length:sizeof((a)) encoding:NSUTF8StringEncoding]

NS_INLINE BOOL isSequenceAhead(uint8 incoming, uint8 counter, uint8 max) {
    uint8 halfmax = max / 2;
    
    if(counter < halfmax) {
        if(incoming <= counter + halfmax) return YES;
    } else {
        if(incoming > counter ||
           incoming <= counter - halfmax) return YES;
    }
    
    return NO;
}

#pragma pack(push, 1)
struct dstar_ambe_data {
    char voice[9];
    char data[3];
    char endPattern[6];
};
struct dstar_header_data{
    char flags[3];
    char rpt2Call[8];
    char rpt1Call[8];
    char urCall[8];
    char myCall[8];
    char myCall2[4];
    unsigned short sum;
};
struct dstarFrame {
    char magic[4];  //  "DSVT"
    char type;  //  0x20 = AMBE, 0x10 = Header
    char unknown[4]; // { 0x00, 0x00, 0x00, 0x20 }
    char band[3]; //  { 0x00, 0x02, 0x01 }
    unsigned short id;
    char sequence;
    union {
        struct dstar_ambe_data ambe;
        struct dstar_header_data header;
    };
};
#pragma pack(pop)


#define AMBE_NULL_PATTERN { 0x9E, 0x8D, 0x32, 0x88, 0x26, 0x1A, 0x3F, 0x61, 0xE8 }

@interface BTRLinkDriver ()

//
//  Methods for the subclass to override
//
-(void)processPacket:(NSData *)packet;
-(NSString *)getAddressForReflector:(NSString *)reflector;
-(void)sendPoll;
-(void)sendUnlink;
-(void)sendLink;

//
//  Utility methods for the subclasses
//
-(uint16) calculateChecksum:(void *)data length:(size_t)length;
-(void)sendPacket:(NSData *)packet;

//
//  Pass off the AMBE and Header data to the rest of the system.
//  These need to be called when the link receives AMBE and Header packets respectively.
//
-(void)processAMBE:(void *)voice forId:(unsigned short)id withSequence:(char)sequence andData:(char *)data;
-(void)processHeader:(NSDictionary *)header;

// -(void)unlink;

//
//  Override these to set the parameters in the subclass.
//
@property (nonatomic, readonly) CFAbsoluteTime pollInterval;
@property (nonatomic, readonly) unsigned short clientPort;
@property (nonatomic, readonly) unsigned short serverPort;
@property (nonatomic, readonly) size_t packetSize;

//
//  Properties subclasses might need.  You should take care of making sure linkState is correct.
//
@property (nonatomic, readwrite, copy) NSString * linkTarget;
@property (nonatomic, readwrite) enum linkState linkState;

//  XXX A bunch of this stuff can move when we're done.
@property (nonatomic) unsigned short txStreamId;
@property (nonatomic) char txSequence;

@end

@interface NSString (BTRCallsignUtils)
@property (nonatomic, readonly) NSString *paddedCall;
@property (nonatomic, readonly) NSString *callWithoutModule;

+(NSString *)stringWithCallsign:(void *)callsign;
+(NSString *)stringWithShortCallsign:(void *)callsign;

@end