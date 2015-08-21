//
//  BTRDPlusLink.m
//
//  Copyright (c) 2015 - Jeremy C. McDermond (NH6Z)

// This program is free software; you can redistribute it and/or
// modify it under the terms of the GNU General Public License
// as published by the Free Software Foundation; either version 2
// of the License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program; if not, write to the Free Software
// Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA  02111-1307, USA.


#import "BTRDPlusLink.h"

#import <arpa/inet.h>
#import <sys/ioctl.h>

#import "BTRDPlusAuthenticator.h"
#import "BTRGatewayHandler.h"
#import "BTRDataEngine.h"
#import "BTRSlowDataCoder.h"

#pragma pack(push, 1)
struct dplus_packet {
    unsigned short length;
    union {
        struct {
            char type;
            char padding;
            union {
                char state;
                char ack[4];
                struct {
                    char repeater[16];
                    char magic[8];
                } module;
            };
        } link;
        struct dstarFrame frame;
    };
};
#pragma pack(pop)

#define dplus_packet_size(a) ((a).length & 0x0FFF)

static const char DPLUS_TYPE_POLL = 0x00;
static const char DPLUS_TYPE_LINK = 0x18;
static const char DPLUS_TYPE_LINKMODULE = 0x04;

// XXX This is AMBE junk
static const char DPLUS_END_PATTERN[] = { 0x55, 0x55, 0x55, 0x55, 0xC8, 0x7A, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
static const char DPLUS_NULL_PATTERN[] = { 0x9E, 0x8D, 0x32, 0x88, 0x26, 0x1A, 0x3F, 0x61, 0xE8 };

static const struct dplus_packet linkModuleTemplate = {
    .length = 0xC01C,
    .link.type = DPLUS_TYPE_LINKMODULE,
    .link.padding = 0x00,
    .link.module.repeater = "    ",
    .link.module.magic = "DV019999"
};

static const struct dplus_packet headerTemplate = {
    .length = 0x803A,
    .frame.magic = "DSVT",
    .frame.type = 0x10,
    .frame.unknown = { 0x00, 0x00, 0x00, 0x20 },
    .frame.band = { 0x00, 0x02, 0x01 },
    .frame.id = 0,
    .frame.sequence = 0x80,
    .frame.header.flags = { 0x00, 0x00, 0x00 },
    .frame.header.myCall = "        ",
    .frame.header.urCall = "CQCQCQ  ",
    .frame.header.rpt1Call = "        ",
    .frame.header.rpt2Call = "        ",
    .frame.header.myCall2 = "    ",
    .frame.header.sum = 0xFFFF
};

static const struct dplus_packet ambeTemplate = {
    .length = 0x801D,
    .frame.magic = "DSVT",
    .frame.type = 0x20,
    .frame.unknown = { 0x00, 0x00, 0x00, 0x20 },
    .frame.band = { 0x00, 0x02, 0x01 },
    .frame.id = 0,
    .frame.sequence = 0,
    .frame.ambe.voice = { 0 },
    .frame.ambe.data = { 0 },
    .frame.ambe.endPattern = { 0 }
};


@interface BTRDPlusLink ()
@property (readonly, nonatomic) NSData *unlinkPacket;
@property (readonly, nonatomic) NSData *pollPacket;
@property (readonly, nonatomic) NSData *linkPacket;

@end

@implementation BTRDPlusLink

+(BOOL)canHandleLinkTo:(NSString*)linkTarget {
    NSString *reflector = [[linkTarget substringWithRange:NSMakeRange(0, 7)] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];

    if([BTRDPlusAuthenticator sharedInstance].reflectorList[reflector])
        return YES;
    
    return NO;
}

+(void) load {
    [BTRDataEngine registerLinkDriver:self];
}

- (id) initWithLinkTo:(NSString *)linkTarget {
    self = [super initWithLinkTo:linkTarget];
    if(self) {
        struct dplus_packet unlinkPacket = {
            .length = 0x05,
            .link.type = DPLUS_TYPE_LINK,
            .link.padding = 0x00,
            .link.state = 0x00
        };
        _unlinkPacket = [NSData dataWithBytes:&unlinkPacket length:dplus_packet_size(unlinkPacket)];
        
        struct dplus_packet pollPacket = {
            .length = 0x6003,
            .link.type = DPLUS_TYPE_POLL
        };
        _pollPacket = [NSData dataWithBytes:&pollPacket length:dplus_packet_size(pollPacket)];
        
        struct dplus_packet linkPacket = {
            .length = 0x05,
            .link.type = DPLUS_TYPE_LINK,
            .link.padding = 0x00,
            .link.state = 0x01
        };
        _linkPacket = [NSData dataWithBytes:&linkPacket length:dplus_packet_size(linkPacket)];

    }
    
    return self;
}

-(CFAbsoluteTime)pollInterval {
    return 1.0;
}

-(unsigned short)clientPort {
    return 20001;
}

-(unsigned short)serverPort {
    return 20001;
}

-(size_t)packetSize {
    return sizeof(struct dplus_packet);
}

-(void)sendPoll {
    [self sendPacket:self.pollPacket];
}

-(void)sendUnlink {
    [self sendPacket:self.unlinkPacket];
}

-(void)sendLink {
    [self sendPacket:self.linkPacket];
}

-(NSString *)getAddressForReflector:(NSString *)reflector {
    return [BTRDPlusAuthenticator sharedInstance].reflectorList[reflector];
}

-(void)processPacket:(NSData *)data {
    struct dplus_packet *incomingPacket = (struct dplus_packet *)data.bytes;
    
    switch(incomingPacket->length & 0xF000) {
        case 0x8000:
            if(strncmp(incomingPacket->frame.magic, "DSVT", 4)) {
                NSLog(@"Invalid magic on a DPlus data packet: %s", incomingPacket->frame.magic);
                return;
            }
            switch(incomingPacket->frame.type) {
                case 0x10: {
                    NSDictionary *header = @{
                                             @"rpt1Call" : call_to_nsstring(incomingPacket->frame.header.rpt1Call),
                                             @"rpt2Call" : call_to_nsstring(incomingPacket->frame.header.rpt2Call),
                                             @"myCall" : call_to_nsstring(incomingPacket->frame.header.myCall),
                                             @"myCall2" : call_to_nsstring(incomingPacket->frame.header.myCall2),
                                             @"urCall" : call_to_nsstring(incomingPacket->frame.header.urCall),
                                             @"streamId" : [NSNumber numberWithUnsignedInteger:incomingPacket->frame.id],
                                             @"time" : [NSDate date],
                                             @"message" : @""
                                             };
                    [self processHeader:header];
                    break;
                }
                case 0x20:
                    [self processAMBE:incomingPacket->frame.ambe.voice forId:incomingPacket->frame.id withSequence:incomingPacket->frame.sequence andData:incomingPacket->frame.ambe.data];
                    break;
            }
            break;
        case 0x6000:
            //  Poll packet, can ignore because the link last packet time is set in the superclass.
            break;
        case 0xC000:
        case 0x0000:
            [self processLinkPacket:incomingPacket];
            break;
        default:
            NSLog(@"Invalid flag byte 0x%02X", incomingPacket->length & 0xF000);
            break;
    }

}

- (void)processLinkPacket:(struct dplus_packet *)packet {
    switch(packet->link.type) {
        case DPLUS_TYPE_LINK:
            switch(packet->link.state) {
                case 0x00:
                    NSLog(@"DPlus reports unlinked");
                    self.linkState = UNLINKED;
                    break;
                case 0x01: {
                    NSLog(@"DPlus reports linked");
                    self.linkState = LINKING;
                    NSMutableData *linkPacket = [NSMutableData dataWithBytes:&linkModuleTemplate length:dplus_packet_size(linkModuleTemplate)];
                
                    memcpy(((struct dplus_packet *) linkPacket.bytes)->link.module.repeater, [BTRDPlusAuthenticator sharedInstance].authCall.UTF8String, [BTRDPlusAuthenticator sharedInstance].authCall.length);
                    [self sendPacket:linkPacket];
                    break;
                }
                default:
                    NSLog(@"Received unknown value for link packet: 0x%02X", packet->link.state);
                    break;
            }
            break;
        case DPLUS_TYPE_LINKMODULE:
            if(!strncmp(packet->link.module.repeater, "OKRW", 4)) {
                NSLog(@"Received ACK from repeater, we are now linked");
                self.linkState = LINKED;
            } else if(!strncmp(packet->link.module.repeater, "BUSY", 4)) {
                NSLog(@"Received NACK from repeater, link failed");
                [self unlink];
            } else {
                NSLog(@"Unknown link packet received");
            }
            break;
        case 0x0B:
            //  This is some sort of ending packet for a transmission.  Need to investigate further.
            break;
        default:
            NSLog(@"Received unknown packet type 0x%02X", packet->link.type);
            NSLog(@"Dump: %@", [NSData dataWithBytes:packet length:sizeof(struct dplus_packet)]);
            break;
    }
}


-(void) sendAMBE:(void *)data lastPacket:(BOOL)last {
    if(self.linkState != LINKED)
        return;
    
    BTRDPlusLink __weak *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        struct dplus_packet packet = {};
        
        //  If the sequence is 0, send a header packet.
        if(weakSelf.txSequence == 0) {
            NSLog(@"Sending header for stream %hu", weakSelf.txStreamId);
            memcpy(&packet, &headerTemplate, sizeof(struct dplus_packet));
            
            packet.frame.id = weakSelf.txStreamId;
            
            //  XXX This should get the global value
            strncpy(packet.frame.header.myCall, [[[[NSUserDefaults standardUserDefaults] stringForKey:@"myCall"] stringByPaddingToLength:8 withString:@" " startingAtIndex:0] cStringUsingEncoding:NSUTF8StringEncoding], sizeof(packet.frame.header.myCall));
            strncpy(packet.frame.header.myCall2, [[[[NSUserDefaults standardUserDefaults] stringForKey:@"myCall2"] stringByPaddingToLength:4 withString:@" " startingAtIndex:0] cStringUsingEncoding:NSUTF8StringEncoding], sizeof(packet.frame.header.myCall2));
            
            // NSString *rpt1Call = [NSString stringWithFormat:@"%@ D", [[[NSUserDefaults standardUserDefaults] stringForKey:@"myCall"] stringByPaddingToLength:6 withString:@" " startingAtIndex:0]];
            strncpy(packet.frame.header.rpt1Call, [[[[NSUserDefaults standardUserDefaults] stringForKey:@"myCall"] stringByPaddingToLength:8 withString:@" " startingAtIndex:0] cStringUsingEncoding:NSUTF8StringEncoding], sizeof(packet.frame.header.rpt1Call));
            
            strncpy(packet.frame.header.rpt2Call, [[weakSelf.linkTarget stringByPaddingToLength:8 withString:@" " startingAtIndex:0] cStringUsingEncoding:NSUTF8StringEncoding], sizeof(packet.frame.header.rpt2Call));

            packet.frame.header.sum = [weakSelf calculateChecksum:&packet.frame.header.flags length:(sizeof(packet.frame.header.myCall) * 4) +
                                        sizeof(packet.frame.header.myCall2) +
                                        sizeof(packet.frame.header.flags)];
            
            [weakSelf sendPacket:[NSData dataWithBytes:&packet length:dplus_packet_size(packet)]];
        }
        
        memcpy(&packet, &ambeTemplate, sizeof(struct dplus_packet));
        packet.frame.sequence = weakSelf.txSequence;
        packet.frame.id = weakSelf.txStreamId;
        memcpy(&packet.frame.ambe.voice, data, sizeof(packet.frame.ambe.voice));
        memcpy(&packet.frame.ambe.data, [[BTRDataEngine sharedInstance].slowData getDataForSequence:weakSelf.txSequence], sizeof(packet.frame.ambe.data));
        
        if(last) {
            weakSelf.txSequence = 0;
            weakSelf.txStreamId = (short) random();
            packet.frame.sequence |= 0x40;
            packet.length = 0x8020;
            memcpy(&packet.frame.ambe.endPattern, DPLUS_END_PATTERN, sizeof(packet.frame.ambe.endPattern));
            memcpy(&packet.frame.ambe.voice, DPLUS_NULL_PATTERN, sizeof(packet.frame.ambe.voice));
        } else {
            weakSelf.txSequence = (weakSelf.txSequence + 1) % 21;
        }
        
        [weakSelf sendPacket:[NSData dataWithBytes:&packet length:dplus_packet_size(packet)]];
    });
}

@end
