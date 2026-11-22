// Independent fixture implementation. Do not use DeviceIP endian/checksum helpers.
static unsigned wire16(const uint8_t *p) { return p[0]*256u+p[1]; }
static uint32_t wire32(const uint8_t *p) { return (uint32_t)p[0]<<24|(uint32_t)p[1]<<16|(uint32_t)p[2]<<8|p[3]; }
static void wire_put16(uint8_t *p,unsigned n) { p[0]=n/256;p[1]=n; }
static void wire_put32(uint8_t *p,uint32_t n) { p[0]=n>>24;p[1]=n>>16;p[2]=n>>8;p[3]=n; }
static uint16_t wire_transport_checksum(const uint8_t *src,const uint8_t *dst,const uint8_t *tcp,size_t n,uint8_t protocol) {
    uint8_t pseudo[40]={0};memcpy(pseudo,src,16);memcpy(pseudo+16,dst,16);
    wire_put32(pseudo+32,(uint32_t)n);pseudo[39]=protocol;
    uint64_t sum=0;for(size_t i=0;i<40;i+=2)sum+=wire16(pseudo+i);
    for(size_t i=0;i<n;i+=2)sum+=((unsigned)tcp[i]<<8)+(i+1<n?tcp[i+1]:0);
    while(sum>65535)sum=(sum&65535)+(sum>>16);
    return (uint16_t)~sum;
}
static uint16_t wire_checksum(const uint8_t *src,const uint8_t *dst,const uint8_t *tcp,size_t n) {
    return wire_transport_checksum(src,dst,tcp,n,6);
}
