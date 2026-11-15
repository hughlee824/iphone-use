// Bounded active IPv6/TCP client for one owned CoreDeviceProxy tunnel.
// No host listener, routing, system interface or semantic request replay.
// All state is owned by one worker; the enclosing helper enforces its lifetime.
#include "DeviceIP.h"
#include <sys/socket.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <stdatomic.h>
#include <stdio.h>
#define RX 65536u
#define TX 16384u
#define FLOWS 4
#define FRAGS 4
#define MIN(a,b) ((a)<(b)?(a):(b))
#define SYN 2
#define ACK 16
#define FIN 1
#define RST 4
struct Flow {
    int fd;
    uint16_t local, remote, mss, wnd;
    uint32_t una, next, rnext, base, wlseq, wlack, finseq, rfinseq;
    uint32_t cwnd, ssthresh, ca, recover;
    bool recovering;
    uint64_t timer, persist, born, sampleAt, lastDataAt;
    uint32_t initialWindow;
    uint32_t srtt, variance, rto, sampleEnd, persistDelay;
    bool sampling, measured;
    unsigned retries, duplicates;
    bool established, eof, fin, finacked, rfin, shut, dead;
    size_t txlen, sent;
    uint8_t tx[TX], rx[RX], present[RX];
};
struct Fragment {
    bool used, last;
    uint32_t id;
    uint64_t born;
    size_t total, have, high;
    uint8_t bytes[65535], present[65535];
};
struct RejectedFragment { bool used; uint32_t id; uint64_t until; };
struct DeviceIP {
    uint8_t local[16], remote[16];
    DeviceIPOutput output; void *context;
    bool failed; size_t count; uint64_t flowLifetime;
    unsigned packets, fragmented, reassembled, retransmits;
    struct Flow flows[FLOWS];
    struct Fragment fragments[FRAGS];
    struct RejectedFragment rejected[64];
};
#ifdef DEVICE_IP_TESTING
static uint64_t test_now;
static uint64_t now(void) { return test_now; }
#else
static uint64_t now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t); return (uint64_t)t.tv_sec*1000+t.tv_nsec/1000000; }
#endif
static uint16_t r16(const uint8_t *p) { return (uint16_t)p[0]*256+p[1]; }
static uint32_t r32(const uint8_t *p) { return (uint32_t)r16(p)*65536+r16(p+2); }
static void w16(uint8_t *p,uint16_t v) { p[0]=v>>8;p[1]=v; }
static void w32(uint8_t *p,uint32_t v) { w16(p,v>>16);w16(p+2,v); }
static bool before(uint32_t a,uint32_t b) { return (int32_t)(a-b)<0; }
static uint16_t checksum(const uint8_t *src,const uint8_t *dst,const uint8_t *tcp,size_t n) {
    uint32_t s=(uint32_t)n+6;
    for(size_t i=0;i<16;i+=2) s+=r16(src+i)+r16(dst+i);
    for(size_t i=0;i<n;i+=2) s+=(uint16_t)tcp[i]*256+(i+1<n?tcp[i+1]:0);
    while(s>>16) s=(s&65535)+(s>>16);
    return (uint16_t)~s;
}
static void close_flow(struct Flow *f) { if(f->fd>=0) close(f->fd); f->fd=-1; f->dead=true; }
static bool emit(DeviceIP *s,struct Flow *f,uint32_t seq,uint8_t flags,const uint8_t *data,size_t n) {
    uint8_t p[1280]={0}; size_t h=(flags&SYN)?24:20;
    if(n>1200) return false;
    p[0]=0x60;w16(p+4,h+n);p[6]=6;p[7]=64;
    memcpy(p+8,s->local,16);memcpy(p+24,s->remote,16);
    w16(p+40,f->local);w16(p+42,f->remote);w32(p+44,seq);w32(p+48,f->rnext);
    p[52]=(h/4)<<4;p[53]=flags;w16(p+54,(uint16_t)(65535-(f->rnext-f->base)));
    if(flags&SYN) {p[60]=2;p[61]=4;w16(p+62,1200);}
    if(n) { memcpy(p+40+h,data,n); f->lastDataAt=now(); }
    w16(p+56,checksum(s->local,s->remote,p+40,h+n));
    #ifdef TRACE_TCP
    fprintf(stderr,"TX seq=%u ack=%u flags=%u len=%zu win=%u base=%u\n",seq,f->rnext,flags,n,r16(p+54),f->base);
#endif
    if(!s->output(s->context,p,40+h+n)) s->failed=true;
    return !s->failed;
}
static void ack(DeviceIP *s,struct Flow *f) { emit(s,f,f->next,ACK,NULL,0); }
DeviceIP *device_ip_create(const uint8_t local[16],const uint8_t remote[16],DeviceIPOutput output,void *context) {
    static atomic_bool once;
    if(!local||!remote||!output||atomic_exchange(&once,true)) return NULL;
    DeviceIP *s=calloc(1,sizeof(*s)); if(!s) return NULL;
    memcpy(s->local,local,16);memcpy(s->remote,remote,16);s->output=output;s->context=context;s->flowLifetime=22000;
    for(unsigned i=0;i<FLOWS;i++) s->flows[i].fd=-1;
    return s;
}
void device_ip_use_session_lifetime(DeviceIP *s) { if(s && !s->count) s->flowLifetime=0; }
bool device_ip_open(DeviceIP *s,int fd,uint16_t port) {
    if(!s||fd<0||!port||s->count==FLOWS||s->failed) {if(fd>=0)close(fd);return false;}
    int flags=fcntl(fd,F_GETFL),yes=1;
    if(flags<0||fcntl(fd,F_SETFL,flags|O_NONBLOCK)||setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&yes,sizeof(yes))) {close(fd);return false;}
    struct Flow *f=&s->flows[s->count++];f->fd=fd;f->remote=port;
    // One process/tunnel lifetime. Never reuse a local tuple, even after a flow closes.
    f->local=(uint16_t)(49152+s->count*1024+arc4random_uniform(1024));
    f->una=arc4random();f->next=f->una+1;f->mss=1200;
    f->cwnd=2400;f->ssthresh=65535;f->born=f->timer=now();
    f->rto=f->persistDelay=1000;f->sampling=true;f->sampleAt=now();f->sampleEnd=f->next;
    return emit(s,f,f->una,SYN,NULL,0);
}
static void sample_rtt(struct Flow *f,uint32_t acknowledgement) {
    if(!f->sampling||before(acknowledgement,f->sampleEnd))return;
    uint32_t elapsed=(uint32_t)(now()-f->sampleAt);
    if(!f->measured){f->srtt=elapsed;f->variance=elapsed/2;f->measured=true;}
    else {
        uint32_t delta=f->srtt>elapsed?f->srtt-elapsed:elapsed-f->srtt;
        f->variance=(3*f->variance+delta)/4;f->srtt=(7*f->srtt+elapsed)/8;
    }
    f->rto=f->srtt+(f->variance?4*f->variance:1);
    if(f->rto<1000)f->rto=1000;
    if(f->rto>60000)f->rto=60000;
    f->sampling=false;
}
static void retransmit(DeviceIP *s,struct Flow *f) {
    s->retransmits++;f->sampling=false;
    if(!f->established) emit(s,f,f->una,SYN,NULL,0);
    else if(f->sent) emit(s,f,f->una,ACK|8,f->tx,MIN(f->sent,f->mss));
    else if(f->fin&&!f->finacked) emit(s,f,f->finseq,ACK|FIN,NULL,0);
}
static void tcp_input(DeviceIP *s,const uint8_t *p,size_t n) {
    if(n<20||checksum(s->remote,s->local,p,n)) return;
    size_t h=(p[12]>>4)*4; if(h<20||h>n) return;
    uint8_t flags=p[13];uint32_t seq=r32(p+4),a=r32(p+8);size_t len=n-h;
    struct Flow *f=NULL;
    for(size_t i=0;i<s->count;i++) if(s->flows[i].local==r16(p+2)&&s->flows[i].remote==r16(p)) f=&s->flows[i];
    if(!f||f->dead) return;
#ifdef TRACE_TCP
    fprintf(stderr,"RX seq=%u ack=%u flags=%u len=%zu want=%u una=%u next=%u wnd=%u sent=%zu tx=%zu\n",seq,a,flags,len,f->rnext,f->una,f->next,r16(p+14),f->sent,f->txlen);
#endif
    uint16_t mss=1200;
    for(size_t i=20;i<h;) {
        uint8_t kind=p[i];if(!kind)break;if(kind==1){i++;continue;}
        if(i+1>=h||p[i+1]<2||i+p[i+1]>h)return;
        if(kind==2) {if(p[i+1]!=4||!r16(p+i+2))return;mss=MIN(mss,r16(p+i+2));}
        i+=p[i+1];
    }
    if(!f->established) {
        if((flags&(RST|ACK))==(RST|ACK)&&a==f->next) {close_flow(f);return;}
        if((flags&(SYN|ACK|FIN|RST))!=(SYN|ACK)||a!=f->next||len)return;
        sample_rtt(f,a);if(f->retries&&f->rto<3000)f->rto=3000;
        f->established=true;f->recovering=false;f->una=a;f->rnext=f->base=seq+1;f->mss=mss;f->initialWindow=(f->retries?1:2)*mss;f->cwnd=f->initialWindow;f->lastDataAt=now();
        f->wnd=r16(p+14);f->wlseq=seq;f->wlack=a;f->timer=now();f->retries=0;ack(s,f);return;
    }
    uint32_t win=65535-(f->rnext-f->base), span=(uint32_t)len+!!(flags&FIN)+!!(flags&SYN);
    bool valid=win? (span? (!before(seq,f->rnext)&&seq-f->rnext<win)||(!before(seq+span-1,f->rnext)&&seq+span-1-f->rnext<win) : !before(seq,f->rnext)&&seq-f->rnext<win) : !span&&seq==f->rnext;
    if(!valid) {if(!(flags&RST))ack(s,f);return;}
    if(flags&RST) {if(f->finacked&&f->rfin&&f->rnext==f->rfinseq+1)return; if(seq==f->rnext)close_flow(f);else ack(s,f);return;}
    if(flags&SYN) {ack(s,f);return;}
    if(!(flags&ACK))return;
    if(before(f->next,a)) {ack(s,f);return;}
    uint16_t oldwindow=f->wnd;
    if(!before(a,f->una)) {
        if(before(f->wlseq,seq)||(f->wlseq==seq&&!before(a,f->wlack))) {
            f->wnd=r16(p+14);f->wlseq=seq;f->wlack=a;
            if(f->wnd)f->persistDelay=1000;
        }
        if(before(f->una,a)) {
            sample_rtt(f,a);
            size_t progress=(uint32_t)(a-f->una), data=MIN(progress,f->sent);
            if(data) {f->txlen-=data;f->sent-=data;memmove(f->tx,f->tx+data,f->txlen);}
            if(f->fin&&a==f->finseq+1)f->finacked=true;
            f->una=a;f->timer=now();f->retries=0;f->duplicates=0;
            if(f->cwnd<f->ssthresh) f->cwnd+=MIN(data,f->mss);
            else {f->ca+=data;if(f->ca>=f->cwnd){f->ca-=f->cwnd;f->cwnd+=f->mss;}}
            f->cwnd=MIN(f->cwnd,TX);
            if(f->recovering){if(!before(a,f->recover))f->recovering=false;else if(f->sent)retransmit(s,f);}
        } else if(!len&&!(flags&FIN)&&f->sent&&oldwindow==f->wnd) {
            if(++f->duplicates==3) {
                f->ssthresh=MIN(TX,(uint32_t)(f->sent/2));if(f->ssthresh<2*f->mss)f->ssthresh=2*f->mss;
                f->cwnd=f->mss;f->recover=f->next;f->recovering=true;retransmit(s,f);f->timer=now();
            }
        }
    }
    if(flags&32) {s->failed=true;return;} // Urgent data is outside this client contract.
    // Retain out-of-order bytes in a fixed receive ring; trim duplicates and overlap.
    for(size_t i=0;i<len;i++) {
        uint32_t at=seq+(uint32_t)i;
        if(before(at,f->rnext)||at-f->rnext>=win||f->shut||(f->rfin&&!before(at,f->rfinseq))) continue;
        size_t index=at%RX;
        if(!f->present[index]) {f->rx[index]=p[h+i];f->present[index]=1;}
    }
    if((flags&FIN)&&!f->rfin&&!before(seq+(uint32_t)len,f->rnext)&&seq+(uint32_t)len-f->rnext<win) {
        f->rfin=true;f->rfinseq=seq+(uint32_t)len;
    }
    while(f->rnext-f->base<65535&&(!f->rfin||before(f->rnext,f->rfinseq))&&f->present[f->rnext%RX]) f->rnext++;
    if(f->rfin&&f->rnext==f->rfinseq)f->rnext++;
    if(len||(flags&FIN))ack(s,f);
}
static void reject_fragment(DeviceIP *s,struct Fragment *f) {
    // Keep denied IDs separately: they must not pin the payload reassembly pool.
    for(size_t i=0;i<64;i++) {
        struct RejectedFragment *r=&s->rejected[i];
        if(!r->used||now()>=r->until){r->used=true;r->id=f->id;r->until=now()+60000;memset(f,0,sizeof(*f));return;}
    }
    // Never forget a live denial to admit potentially overlapping bytes.
    s->failed=true;
}
static void fragment_input(DeviceIP *s,const uint8_t *p,size_t n) {
    if(n<8||p[0]!=6)return;
    size_t off=r16(p+2)&0xfff8, len=n-8;bool more=p[3]&1;
    if(!len||off+len>65535||(more&&len%8))return;
    if(!off&&!more) {tcp_input(s,p+8,len);return;}
    uint32_t id=r32(p+4);
    for(size_t i=0;i<64;i++)if(s->rejected[i].used&&s->rejected[i].id==id&&now()<s->rejected[i].until)return;
    struct Fragment *f=NULL,*empty=NULL,*oldest=NULL;
    for(unsigned i=0;i<FRAGS;i++) {
        struct Fragment *q=&s->fragments[i];
        if(q->used&&now()-q->born>=60000)memset(q,0,sizeof(*q));
        if(q->used&&q->id==id)f=q;
        if(!q->used&&!empty)empty=q;
        if(q->used&&(!oldest||q->born<oldest->born))oldest=q;
    }
    if(!f){
        // Under resource pressure discard the oldest incomplete datagram; TCP may retransmit it.
        // Denied IDs have separate bounded metadata; never reuse them before expiry.
        if(!empty){if(!oldest)return;memset(oldest,0,sizeof(*oldest));empty=oldest;}
        f=empty;f->used=true;f->id=id;f->born=now();}
    if((f->last&&off+len>f->total)||(!more&&((f->last&&f->total!=off+len)||f->high>off+len))) {reject_fragment(s,f);return;}
    // RFC 8200: overlapping IPv6 fragments discard the entire datagram.
    for(size_t i=off;i<off+len;i++)if(f->present[i]){reject_fragment(s,f);return;}
    memcpy(f->bytes+off,p+8,len);memset(f->present+off,1,len);f->have+=len;
    if(off+len>f->high)f->high=off+len;
    if(!more){f->last=true;f->total=off+len;}
    if(f->last&&f->have==f->total){s->reassembled++;tcp_input(s,f->bytes,f->total);memset(f,0,sizeof(*f));}
}
bool device_ip_input(DeviceIP *s,const void *raw,size_t n) {
    if(!s||!raw||n<40||n>65535)return false;
    const uint8_t *p=raw;
    if(p[0]>>4!=6||40+(size_t)r16(p+4)!=n)return false;
    if(memcmp(p+8,s->remote,16)||memcmp(p+24,s->local,16))return true;
    s->packets++;
    if(p[6]==6)tcp_input(s,p+40,n-40);
    else if(p[6]==44){s->fragmented++;fragment_input(s,p+40,n-40);}
    // No routing, IPv4, UDP, ICMP, or extension-header chains in this experiment.
    return !s->failed;
}
bool device_ip_tick(DeviceIP *s) {
    if(!s||s->failed)return false;
    uint64_t t=now();
    for(size_t i=0;i<s->count;i++) {
        struct Flow *f=&s->flows[i];if(f->dead)continue;
        if(s->flowLifetime && t-f->born>=s->flowLifetime){s->failed=true;return false;}
        if(f->una!=f->next&&t-f->timer>=f->rto) {
            if(++f->retries>4){s->failed=true;return false;}
            f->ssthresh=MIN(TX,(uint32_t)(f->sent/2));if(f->ssthresh<2*f->mss)f->ssthresh=2*f->mss;
            f->cwnd=f->mss;f->duplicates=0;f->recover=f->next;f->recovering=true;retransmit(s,f);f->timer=t;f->rto=MIN(60000,f->rto*2);
        }
        if(!f->established)continue;
        uint32_t edge=f->rnext;if(f->rfin&&edge==f->rfinseq+1)edge--;
        if(before(f->base,edge)) {
            size_t index=f->base%RX,n=MIN(edge-f->base,RX-index);
            ssize_t k=send(f->fd,f->rx+index,n,0);
            if(k>0){memset(f->present+index,0,k);f->base+=(uint32_t)k;if(!(f->rfin&&f->rnext==f->rfinseq+1))ack(s,f);}
            else if(k<0&&errno!=EAGAIN&&errno!=EINTR){emit(s,f,f->next,RST|ACK,NULL,0);close_flow(f);continue;}
        }
        if(f->rfin&&f->base==f->rfinseq&&f->rnext==f->rfinseq+1&&!f->shut) {
            shutdown(f->fd,SHUT_WR);f->shut=true;f->base++; // FIN consumes sequence space, not buffer bytes.
        }
        if(!f->eof&&f->txlen<TX) {
            ssize_t k=recv(f->fd,f->tx+f->txlen,TX-f->txlen,0);
            if(k>0)f->txlen+=k;else if(!k)f->eof=true;
            else if(errno!=EAGAIN&&errno!=EINTR){emit(s,f,f->next,RST|ACK,NULL,0);close_flow(f);continue;}
        }
        if(f->una==f->next&&t-f->lastDataAt>f->rto) {
            f->cwnd=MIN(f->cwnd,f->initialWindow);f->ca=0;
        }
        uint32_t limit=MIN(f->wnd,f->cwnd);
        while(!f->recovering&&f->sent<f->txlen&&f->sent<limit) {
            size_t n=MIN(f->txlen-f->sent,MIN(f->mss,limit-f->sent));
            if(f->una==f->next){f->timer=t;f->sampling=true;f->sampleAt=t;f->sampleEnd=f->next+(uint32_t)n;}
            emit(s,f,f->next,ACK|8,f->tx+f->sent,n);f->sent+=n;f->next+=(uint32_t)n;
        }
        if(!f->wnd&&(f->txlen||(f->eof&&!f->fin))&&f->una==f->next&&t-f->persist>=f->persistDelay) {
            // Probe just before SND.NXT; never consume new byte/sequence on a zero-window probe.
            emit(s,f,f->next-1,ACK,NULL,0);f->persist=t;f->persistDelay=MIN(60000,f->persistDelay*2);
        }
        if(f->eof&&!f->txlen&&!f->fin&&f->wnd) {
            f->fin=true;f->finseq=f->next;f->timer=t;
            emit(s,f,f->next++,FIN|ACK,NULL,0);
        }
        // Keep tuple/state until destroy so a lost final ACK can be repeated.
    }
    return !s->failed;
}
void device_ip_destroy(DeviceIP *s) {
    if(!s)return;
#ifdef DEVICE_IP_DIAGNOSTICS
    fprintf(stderr,"transport packets=%u fragments=%u reassembled=%u retransmits=%u flows=%zu failed=%d\n",s->packets,s->fragmented,s->reassembled,s->retransmits,s->count,s->failed);
#endif
    for(size_t i=0;i<s->count;i++)close_flow(&s->flows[i]);
    free(s);
}
