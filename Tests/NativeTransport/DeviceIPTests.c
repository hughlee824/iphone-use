#define DEVICE_IP_TESTING
// Deterministic packet/clock fixtures; no device, network listener or third-party test peer.
#include "../../Sources/DeviceIP/DeviceIP.c"
#include <assert.h>
#include "WireFixture.h"
static bool bulk_capture;
static uint8_t packets[128][1280];static size_t packet_sizes[128],packet_count;
static uint8_t out[1280];static size_t outlen;static unsigned outputs;
static bool capture(void *ctx,const void *p,size_t n){(void)ctx;assert(n>=60&&n<=sizeof(out));assert(wire16((const uint8_t *)p+4)+40==n);assert(wire_checksum((const uint8_t *)p+8,(const uint8_t *)p+24,(const uint8_t *)p+40,n-40)==0);memcpy(out,p,n);outlen=n;outputs++;if(bulk_capture){assert(packet_count<128);memcpy(packets[packet_count],p,n);packet_sizes[packet_count++]=n;}return true;}
static uint8_t local[16]={0xfd,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1},remote[16]={0xfd,0,0,0,0,0,0,0,0,0,0,0,0,0,0,2};
static DeviceIP *stack;static struct Flow *flow;static int app;static bool slow_handshake, lost_syn;
static size_t packet(uint8_t *p,uint32_t seq,uint32_t a,uint8_t flags,uint16_t win,const char *data,size_t len){
    memset(p,0,60+len);p[0]=0x60;wire_put16(p+4,20+len);p[6]=6;p[7]=64;
    memcpy(p+8,remote,16);memcpy(p+24,local,16);wire_put16(p+40,flow->remote);wire_put16(p+42,flow->local);
    wire_put32(p+44,seq);wire_put32(p+48,a);p[52]=0x50;p[53]=flags;wire_put16(p+54,win);
    if(len)memcpy(p+60,data,len);wire_put16(p+56,wire_checksum(remote,local,p+40,20+len));return 60+len;
}
static void incoming(uint32_t seq,uint32_t a,uint8_t flags,uint16_t win,const char *data,size_t len){
    uint8_t p[65535];size_t n=packet(p,seq,a,flags,win,data,len);assert(device_ip_input(stack,p,n));
}
static bool session_lifetime;
static void setup(uint32_t seq){
    int fds[2];assert(!socketpair(AF_UNIX,SOCK_STREAM,0,fds));app=fds[1];fcntl(app,F_SETFL,O_NONBLOCK);
    stack=device_ip_create(local,remote,capture,NULL);assert(stack);if(session_lifetime)device_ip_use_session_lifetime(stack);assert(device_ip_open(stack,fds[0],2345));flow=&stack->flows[0];
    if(lost_syn){test_now=1001;assert(device_ip_tick(stack));}
    if(slow_handshake)test_now=800;
    incoming(seq-1,flow->next,SYN|ACK,65535,NULL,0);assert(flow->established&&flow->rnext==seq);
}
static void read_exact(const char *expected,size_t len){
    char got[256];size_t received=0;
    for(unsigned tries=0;tries<10&&received<len;tries++){assert(device_ip_tick(stack));ssize_t n=recv(app,got+received,sizeof(got)-received,0);if(n>0)received+=n;else assert(n<0&&errno==EAGAIN);}
    assert(received==len&&!memcmp(got,expected,len));
}
static void frag(const uint8_t *tcp,size_t off,size_t len,bool more,uint32_t id){
    uint8_t p[65535]={0};p[0]=0x60;wire_put16(p+4,8+len);p[6]=44;p[7]=64;
    memcpy(p+8,remote,16);memcpy(p+24,local,16);p[40]=6;wire_put16(p+42,(uint16_t)off|more);wire_put32(p+44,id);memcpy(p+48,tcp+off,len);
    assert(device_ip_input(stack,p,48+len));
}
static size_t datagrams;
static void capture_udp(void *context,uint16_t source,const uint8_t *data,size_t count) {
    (void)context;
    assert(source==12000 && count==8 && !memcmp(data,"keyboard",8));datagrams++;
}
static void test_udp(void) {
    uint8_t p[56]={0};p[0]=0x60;wire_put16(p+4,16);p[6]=17;p[7]=64;
    memcpy(p+8,remote,16);memcpy(p+24,local,16);wire_put16(p+40,12000);wire_put16(p+42,50123);
    wire_put16(p+44,16);memcpy(p+48,"keyboard",8);
    wire_put16(p+46,wire_transport_checksum(remote,local,p+40,16,17));
    assert(device_ip_input(stack,p,sizeof(p)) && !datagrams);
    device_ip_receive_udp(stack,50123,capture_udp);
    assert(device_ip_input(stack,p,sizeof(p)) && datagrams==1);
    p[48]^=1;assert(device_ip_input(stack,p,sizeof(p)) && datagrams==1);p[48]^=1;
    device_ip_receive_udp(stack,50124,capture_udp);
    assert(device_ip_input(stack,p,sizeof(p)) && datagrams==1);
    device_ip_receive_udp(stack,50123,capture_udp);
    uint8_t chunk[56]={0};memcpy(chunk,p,40);chunk[6]=44;chunk[40]=17;
    wire_put32(chunk+44,123);wire_put16(chunk+42,8);memcpy(chunk+48,p+48,8);
    assert(device_ip_input(stack,chunk,sizeof(chunk)) && datagrams==1);
    wire_put16(chunk+42,1);memcpy(chunk+48,p+40,8);
    assert(device_ip_input(stack,chunk,sizeof(chunk)) && datagrams==2);
}
int main(int argc,char **argv){
    assert(argc==2);const char *mode=argv[1];slow_handshake=!strcmp(mode,"slow-rtt");lost_syn=!strcmp(mode,"syn-window");session_lifetime=!strncmp(mode,"session-",8);setup(!strcmp(mode,"wrap")?UINT32_MAX-3:100);
    uint32_t start=flow->rnext,a=flow->next;
    if(!strcmp(mode,"session-udp")){ test_udp();
    }else if(!strcmp(mode,"overlap")||!strcmp(mode,"wrap")){
        incoming(start,a,ACK,65535,"abcd",4);
        incoming(start+2,a,ACK,65535,"cdefgh",6);
        incoming(start,a,ACK,65535,"abcdefgh",8);
        read_exact("abcdefgh",8);assert(flow->rnext==start+8);
    }else if(!strcmp(mode,"reorder")){
        incoming(start+4,a,ACK,65535,"efgh",4);assert(flow->rnext==start);
        incoming(start,a,ACK,65535,"abcd",4);read_exact("abcdefgh",8);
    }else if(!strcmp(mode,"fragments")){
        uint8_t p[128];size_t n=packet(p,start,a,ACK,65535,"abcdefgh",8)-40;
        frag(p+40,24,n-24,false,42);assert(flow->rnext==start);
        frag(p+40,0,24,true,42);read_exact("abcdefgh",8);
    }else if(!strcmp(mode,"fragment-overlap")){
        uint8_t p[128];packet(p,start,a,ACK,65535,"abcdefghijklmnopqrst",20);
        frag(p+40,0,24,true,42);frag(p+40,16,24,false,42);
        assert(flow->rnext==start&&stack->rejected[0].used);
        frag(p+40,24,16,false,42);assert(flow->rnext==start);
    }else if(!strcmp(mode,"partial-ack")){
        assert(send(app,"abcdefgh",8,0)==8);assert(device_ip_tick(stack));assert(flow->sent==8);
        incoming(start,a+3,ACK,65535,NULL,0);assert(flow->sent==5&&flow->txlen==5&&!memcmp(flow->tx,"defgh",5));
        test_now=1001;assert(device_ip_tick(stack));assert(outlen==65&&wire32(out+44)==a+3&&!memcmp(out+60,"defgh",5));
        incoming(start,a+8,ACK,65535,NULL,0);assert(!flow->sent&&!flow->txlen);
    }else if(!strcmp(mode,"persist")){
        incoming(start,a,ACK,0,NULL,0);assert(send(app,"abc",3,0)==3);assert(device_ip_tick(stack));assert(flow->next==a);
        unsigned prior=outputs;test_now=1001;assert(device_ip_tick(stack));assert(outputs==prior+1&&wire32(out+44)==a-1);
        incoming(start,a,ACK,3,NULL,0);assert(device_ip_tick(stack));assert(flow->sent==3&&flow->next==a+3);
    }else if(!strcmp(mode,"reset")){
        incoming(start+1,a,RST|ACK,65535,NULL,0);assert(!flow->dead);
        incoming(start,a,RST|ACK,65535,NULL,0);assert(flow->dead);char c;assert(recv(app,&c,1,0)==0);
    }else if(!strcmp(mode,"fin")){
        incoming(start+4,a,ACK|FIN,65535,NULL,0);assert(!flow->shut);
        incoming(start,a,ACK,65535,"abcd",4);read_exact("abcd",4);char c;assert(recv(app,&c,1,0)==0);
        incoming(start+4,a,ACK|FIN,65535,NULL,0);assert(flow->rnext==start+5);
    }else if(!strcmp(mode,"closed-drain")){
        assert(!shutdown(app,SHUT_WR));assert(device_ip_tick(stack));assert(flow->fin);
        incoming(start,flow->next,ACK|FIN,65535,"abcd",4);
        incoming(start+5,flow->next,ACK|RST,65535,NULL,0);assert(!flow->dead);
        read_exact("abcd",4);unsigned count=outputs;
        for(unsigned i=0;i<4;i++)assert(device_ip_tick(stack));assert(outputs==count&&!flow->dead);
    }else if(!strcmp(mode,"window")){
        char bytes[1200];memset(bytes,42,sizeof(bytes));
        for(unsigned n=0;n<65535;){unsigned k=MIN(1200,65535-n);incoming(start+n,a,ACK,65535,bytes,k);n+=k;}
        assert(flow->rnext-start==65535&&wire16(out+54)==0);
        incoming(flow->rnext,a,ACK,65535,"X",1);assert(flow->rnext-start==65535);
        assert(device_ip_tick(stack));assert(wire16(out+54)>0);
    }else if(!strcmp(mode,"fuzz")){
        uint8_t p[2048];uint32_t rng=12345;
        for(unsigned k=0;k<10000;k++){
            size_t len=k%sizeof(p);for(size_t i=0;i<len;i++){rng=rng*1664525+1013904223;p[i]=rng>>24;}
            if(len>=40){p[0]=0x60;wire_put16(p+4,len-40);memcpy(p+8,remote,16);memcpy(p+24,local,16);p[6]=(k%2)?6:44;}
            device_ip_input(stack,p,len);
        }
        assert(flow->rnext==start);
    }else if(!strcmp(mode,"invalid")){
        uint8_t p[128];size_t n=packet(p,start,a,ACK,65535,"abc",3);
        p[60]^=1;assert(device_ip_input(stack,p,n)&&flow->rnext==start);
        p[60]^=1;p[8]^=1;assert(device_ip_input(stack,p,n)&&flow->rnext==start);
        assert(!device_ip_input(stack,p,39));assert(!device_ip_input(stack,p,n-1));
        incoming(start,a+100,ACK,65535,"abc",3);assert(flow->rnext==start);
    }else if(!strcmp(mode,"bulk")||!strcmp(mode,"bulk-loss")){
        bulk_capture=true;size_t sent=0,received=0,accepted=0,total=512*1024;uint32_t peer_seq=start,peer_right=start+65535,peer_ack=a;size_t echoed=0;bool eof=false,dropped=false,shutdown_sent=false,client_fin=false,server_fin=false;unsigned data_packets=0;
        for(unsigned step=0;step<20000&&!eof;step++){
            test_now=step;
            if(sent<total){uint8_t bytes[4096];size_t n=MIN(sizeof(bytes),total-sent);for(size_t j=0;j<n;j++)bytes[j]=(uint8_t)(sent+j);ssize_t k=send(app,bytes,n,0);if(k>0)sent+=k;else assert(errno==EAGAIN);}
            else if(!shutdown_sent){assert(!shutdown(app,SHUT_WR));shutdown_sent=true;}
            assert(device_ip_tick(stack));
            for(size_t at=0;at<packet_count;at++){
                uint8_t *p=packets[at];size_t header=(p[52]>>4)*4,len=packet_sizes[at]-40-header;uint32_t sequence=wire32(p+44);
                peer_right=wire32(p+48)+wire16(p+54);
                if(!len&&!(p[53]&FIN))continue;
                if(len&&!strcmp(mode,"bulk-loss")&&++data_packets==12){dropped=true;continue;}
                if(sequence!=a+(uint32_t)accepted){incoming(peer_seq,a+(uint32_t)accepted,ACK,65535,NULL,0);continue;}
                if(len){for(size_t j=0;j<len;j++)assert(p[40+header+j]==(uint8_t)(accepted+j));accepted+=len;peer_ack=a+(uint32_t)accepted;incoming(peer_seq,peer_ack,ACK,65535,NULL,0);}
                if(p[53]&FIN){client_fin=true;peer_ack=sequence+1;incoming(peer_seq,peer_ack,ACK,65535,NULL,0);}
            }
            packet_count=0;
            if(echoed<accepted&&before(peer_seq,peer_right)){
                char bytes[1200];size_t n=MIN(sizeof(bytes),MIN(accepted-echoed,(uint32_t)(peer_right-peer_seq)));
                for(size_t j=0;j<n;j++)bytes[j]=(char)(echoed+j);
                incoming(peer_seq,peer_ack,ACK,65535,bytes,n);echoed+=n;peer_seq+=(uint32_t)n;
            }
            if(client_fin&&echoed==accepted&&!server_fin){incoming(peer_seq,peer_ack,ACK|FIN,65535,NULL,0);peer_seq++;server_fin=true;}
            if(step>=250){uint8_t bytes[4096];ssize_t k=recv(app,bytes,sizeof(bytes),0);if(!k){eof=true;break;}if(k<0){assert(errno==EAGAIN);continue;}for(ssize_t j=0;j<k;j++)assert(bytes[j]==(uint8_t)(received+j));received+=k;}
        }
        if(!(eof&&sent==total&&accepted==total&&received==total))fprintf(stderr,"sent=%zu accepted=%zu echoed=%zu received=%zu eof=%d\n",sent,accepted,echoed,received,eof);
        assert(eof&&sent==total&&accepted==total&&received==total);
        if(!strcmp(mode,"bulk-loss"))assert(dropped);bulk_capture=false;
    }else if(!strcmp(mode,"multi-flow")){
        int apps[4]={app};struct Flow *flows[4]={flow};
        for(unsigned i=1;i<4;i++){int pair[2];assert(!socketpair(AF_UNIX,SOCK_STREAM,0,pair));apps[i]=pair[1];assert(device_ip_open(stack,pair[0],2345+i));flows[i]=&stack->flows[i];flow=flows[i];incoming(999+i*1000,flow->next,SYN|ACK,65535,NULL,0);}
        for(unsigned i=0;i<4;i++){flow=flows[i];incoming(flow->rnext,flow->next,ACK,65535,"abc",3);}
        assert(device_ip_tick(stack));for(unsigned i=0;i<4;i++){char b[3];assert(recv(apps[i],b,3,0)==3&&!memcmp(b,"abc",3));}
        flow=flows[0];incoming(flow->rnext,flow->next,RST|ACK,65535,NULL,0);
        for(unsigned i=1;i<4;i++){flow=flows[i];incoming(flow->rnext,flow->next,ACK,65535,"xyz",3);}
        assert(device_ip_tick(stack));for(unsigned i=1;i<4;i++){char b[3];assert(recv(apps[i],b,3,0)==3&&!memcmp(b,"xyz",3));close(apps[i]);}
    }else if(!strcmp(mode,"slow-rtt")){
        // RFC 6298 initial sample 800 ms => SRTT=800, RTTVAR=400, RTO=2400 ms.
        assert(send(app,"abc",3,0)==3);assert(device_ip_tick(stack));unsigned previous=outputs;
        test_now=1801;assert(device_ip_tick(stack));
        assert(outputs==previous && "must not retransmit 1001 ms after send when observed RTT requires RTO=2400 ms");
    }else if(!strcmp(mode,"fragment-pool")){
        uint8_t p[128];packet(p,start,a,ACK,65535,"abcdefgh",8);
        for(unsigned id=1;id<=4;id++){frag(p+40,0,24,true,id);frag(p+40,0,24,true,id);}
        frag(p+40,0,24,true,42);frag(p+40,24,4,false,42);read_exact("abcdefgh",8);
        // Old denied ID must remain denied after its payload slot is reused.
        packet(p,start+8,a,ACK,65535,"abcdefgh",8);
        frag(p+40,0,24,true,1);frag(p+40,24,4,false,1);assert(flow->rnext==start+8);
    }else if(!strcmp(mode,"denial-budget")){
        uint8_t p[128];packet(p,start,a,ACK,65535,"abcdefgh",8);
        for(unsigned id=1;id<=64;id++){frag(p+40,0,24,true,id);frag(p+40,0,24,true,id);}
        // Exhaustion is explicit and bounded, never evicts a live denial.
        frag(p+40,0,24,true,65);
        uint8_t q[72]={0};q[0]=0x60;q[6]=44;wire_put16(q+4,32);memcpy(q+8,remote,16);memcpy(q+24,local,16);q[40]=6;wire_put16(q+42,1);wire_put32(q+44,65);memcpy(q+48,p+40,24);
        assert(!device_ip_input(stack,q,sizeof(q)));assert(!device_ip_tick(stack));
    }else if(!strcmp(mode,"idle-window")){
        for(unsigned i=0;i<12;i++){char b[1200]={0};assert(send(app,b,sizeof(b),0)==sizeof(b));assert(device_ip_tick(stack));incoming(start,flow->next,ACK,65535,NULL,0);test_now+=10;}
        test_now+=5000;char b[8192]={0};assert(send(app,b,sizeof(b),0)==sizeof(b));uint32_t seq=flow->next;assert(device_ip_tick(stack));assert(flow->next-seq<=2400);
    }else if(!strcmp(mode,"state-sequences")){
        uint32_t rng=17,seq=start;unsigned rounds=1000;
        for(unsigned i=0;i<rounds;i++){
            rng=rng*1664525+1013904223;char data[8];for(unsigned j=0;j<8;j++)data[j]=(char)(rng>>(j%4)*8);
            incoming(seq+1,a,RST|ACK,65535,NULL,0);assert(!flow->dead);
            incoming(seq,a+999,ACK,65535,data,8);assert(flow->rnext==seq);
            incoming(seq+4,a,ACK,65535,data+4,4);
            incoming(seq,a,ACK,65535,data,4);
            incoming(seq+2,a,ACK,65535,data+2,6); // overlap and duplicate
            read_exact(data,8);seq+=8;assert(flow->rnext==seq);
            incoming(seq,a,ACK,0,NULL,0);incoming(seq,a,ACK,65535,NULL,0);
        }
        incoming(seq,a,FIN|ACK,65535,NULL,0);assert(device_ip_tick(stack));char c;assert(recv(app,&c,1,0)==0);
    }else if(!strcmp(mode,"syn-window")){
        // setup deliberately retransmitted SYN before accepting SYNACK.
        char b[2400]={0};assert(send(app,b,sizeof(b),0)==sizeof(b));assert(device_ip_tick(stack));assert(flow->sent==1200);
    }else if(!strncmp(mode,"deadline-",9)){
        unsigned seconds,losses;assert(sscanf(mode,"deadline-%u-%u",&seconds,&losses)==2);
        assert(send(app,"abcdefgh",8,0)==8);unsigned transmissions=0;bool recovered=false;
        for(test_now=0;test_now<seconds*1000;test_now++){
            unsigned previous=outputs;assert(device_ip_tick(stack));
            if(outputs>previous&&outlen==68){
                assert(wire32(out+44)==a&&!memcmp(out+60,"abcdefgh",8));transmissions++;
                if(transmissions>losses){incoming(start,a+8,ACK,65535,"abcdefgh",8);read_exact("abcdefgh",8);recovered=true;break;}
            }
        }
        unsigned recovery=(1u<<losses)-1;assert(recovered==(recovery<seconds));
        printf("deadline=%u loss=%u recovered=%d at=%llu ms transmissions=%u\n",seconds,losses,recovered,(unsigned long long)test_now,transmissions);
        // Caller deadline cancels the original stream; no new request/connection is attempted.
        device_ip_destroy(stack);char c;ssize_t n=recv(app,&c,1,0);assert(n==0||(n<0&&errno==ECONNRESET));close(app);return 0;
    }else if(!strcmp(mode,"session-idle-data")){
        const uint64_t times[]={22001,65000,300001,3600001};uint32_t seq=start;
        for(unsigned i=0;i<4;i++){test_now=times[i];assert(device_ip_tick(stack));incoming(seq,a,ACK,65535,"long",4);read_exact("long",4);seq+=4;assert(flow->rnext==seq);}
    }else if(!strcmp(mode,"session-fragment-expiry")){
        uint8_t p[128];packet(p,start,a,ACK,65535,"abcdefgh",8);
        frag(p+40,0,24,true,1);frag(p+40,0,24,true,1);test_now=65000;assert(device_ip_tick(stack));
        frag(p+40,0,24,true,1);frag(p+40,24,4,false,1);read_exact("abcdefgh",8);
    }else if(!strcmp(mode,"timeout")){
        test_now=22001;assert(!device_ip_tick(stack));
    }else if(!strcmp(mode,"cancel")){
        device_ip_destroy(stack);char c;assert(recv(app,&c,1,0)==0);close(app);puts("cancel passed");return 0;
    }else if(!strcmp(mode,"budget")){
        for(unsigned i=1;i<4;i++){int fds[2];assert(!socketpair(AF_UNIX,SOCK_STREAM,0,fds));assert(device_ip_open(stack,fds[0],2345+i));close(fds[1]);}
        int fds[2];assert(!socketpair(AF_UNIX,SOCK_STREAM,0,fds));assert(!device_ip_open(stack,fds[0],2349));char c;assert(recv(fds[1],&c,1,0)==0);close(fds[1]);
    }else assert(!"unknown test");
    device_ip_destroy(stack);close(app);printf("%s passed\n",mode);return 0;
}
