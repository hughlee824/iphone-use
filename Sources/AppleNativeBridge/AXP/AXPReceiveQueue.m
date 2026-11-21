#import "AXPReceiveQueue.h"
#import <stdint.h>
static const NSUInteger PacketLimit=20*1024*1024,QueueLimit=40*1024*1024,ObservationLimit=40*1024*1024,CountLimit=128;
@implementation ASAXReaderTarget {
 NSMutableArray<NSData *> *_packets;
 NSUInteger _queuedBytes,_observationBytes,_peakQueuedBytes,_peakPacketCount;
 uint64_t _totalReceived;
 BOOL _active,_totalSaturated;
 NSString *_failure;
}
- (instancetype)init {if((self=[super init]))_packets=[NSMutableArray new];return self;}
- (NSNumber *)hostAPIVersion{return @7;}
- (void)checkFailure {if(_failure)[NSException raise:@"AXReceiveBudget" format:@"AX response budget exceeded: %@",_failure];}
- (void)processDataFromRemoteDevice:(NSData *)data {
 @synchronized(self){
  if(_failure)return;
  if(![data isKindOfClass:NSData.class]){_failure=@"invalid_data_type";return;}
  NSUInteger n=data.length;
  if(n>UINT64_MAX-_totalReceived){_totalReceived=UINT64_MAX;_totalSaturated=YES;}else _totalReceived+=n;
  if(n>PacketLimit){_failure=@"packet_bytes";return;}
  if(_packets.count>=CountLimit){_failure=@"queue_packets";return;}
  if(n>QueueLimit-_queuedBytes){_failure=@"queue_bytes";return;}
  if(_active&&n>ObservationLimit-_observationBytes){_failure=@"observation_bytes";return;}
  [_packets addObject:[data copy]];_queuedBytes+=n;if(_active)_observationBytes+=n;
  _peakQueuedBytes=MAX(_peakQueuedBytes,_queuedBytes);_peakPacketCount=MAX(_peakPacketCount,_packets.count);
 }
}
- (void)checkHealth { @synchronized(self){ [self checkFailure]; } }
- (void)beginObservation {
 @synchronized(self){
  [self checkFailure];
  if(_active){_failure=@"observation_already_active";[self checkFailure];}
  // Charge pre-existing packets too; resetting a request must not launder queued data.
  if(_queuedBytes>ObservationLimit){_failure=@"observation_backlog";[self checkFailure];}
  _observationBytes=_queuedBytes;_active=YES;
 }
}
- (NSData *)takePacket {
 @synchronized(self){
  [self checkFailure];if(!_packets.count)return nil;
  NSData *data=_packets.firstObject;_queuedBytes-=data.length;[_packets removeObjectAtIndex:0];return data;
 }
}
- (NSDictionary *)budgetMetrics {
 @synchronized(self){return @{@"queuedBytes":@(_queuedBytes),@"queuedPackets":@(_packets.count),@"observationBytes":@(_observationBytes),@"observationActive":@(_active),@"totalReceivedBytes":@(_totalReceived),@"totalSaturated":@(_totalSaturated),@"peakQueuedBytes":@(_peakQueuedBytes),@"peakQueuedPackets":@(_peakPacketCount),@"failure":_failure?:NSNull.null};}
}
- (NSDictionary *)finishObservation {
 @synchronized(self){
  [self checkFailure];if(!_active){_failure=@"observation_not_active";[self checkFailure];}
  _active=NO;return [self budgetMetrics];
 }
}
@end
