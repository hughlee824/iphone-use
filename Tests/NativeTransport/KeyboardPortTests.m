#import "DeviceServiceTransport.h"
#import <sys/socket.h>
#import <unistd.h>
#import <assert.h>

// The production helper and descriptor receiver run in separate processes. Only
// the provider that would normally contact MobileDevice/RSD is substituted.
@implementation ASDeviceServiceTransport {
    BOOL _refusePasteboard, _mediaStarted;
    int _hidPeer, _boardPeer;
}
- (instancetype)initWithUDID:(NSString *)device sessionLifetime:(BOOL)sessionLifetime {
    assert(sessionLifetime);
    if ((self = [super init])) {
        _hidPeer = _boardPeer = -1;
        _refusePasteboard = [device isEqual:@"refuse"];
    }
    return self;
}
- (ASKeyboardMediaEndpoint *)openKeyboardMedia {
    assert(!_mediaStarted); _mediaStarted = YES;
    return (ASKeyboardMediaEndpoint *)self;
}
- (int)openKeyboardService:(BOOL)pasteboard {
    assert(_mediaStarted);
    if (pasteboard && _refusePasteboard)
        @throw [NSException exceptionWithName:@"Test" reason:@"Pasteboard unavailable" userInfo:nil];
    int pair[2]; assert(socketpair(AF_UNIX, SOCK_STREAM, 0, pair) == 0);
    if (pasteboard) _boardPeer = pair[1]; else _hidPeer = pair[1];
    assert(write(pair[1], pasteboard ? "p" : "h", 1) == 1);
    return pair[0];
}
- (BOOL)close {
    // The client can still dispatch on the original HID socket after it opens
    // the pasteboard, including when that second service refuses to open.
    char key = 0;
    assert(read(_hidPeer, &key, 1) == 1 && key == 'V');
    close(_hidPeer);
    if (_boardPeer >= 0) close(_boardPeer);
    return YES;
}
@end

int main(int argc, char **argv) { @autoreleasepool {
    assert(argc == 3);
    if (strcmp(argv[1], "provider") == 0)
        return ASProvideKeyboardPort(@(argv[2]), ^NSString *(ASKeyboardMediaEndpoint *media) {
            assert(media != nil); return nil;
        }, ^BOOL{ return YES; }) ? 0 : 1;
    NSError *error = nil;
    assert(write(STDIN_FILENO, "H", 1) == 1);
    int hid = ASReceiveKeyboardPort(STDIN_FILENO, &error);
    char marker = 0;
    assert(hid >= 0 && read(hid, &marker, 1) == 1 && marker == 'h');
    assert(write(STDIN_FILENO, "P", 1) == 1);
    int board = ASReceiveKeyboardPort(STDIN_FILENO, &error);
    if (strcmp(argv[2], "refuse") == 0) {
        assert(board < 0 && [error.localizedDescription isEqual:@"Pasteboard unavailable"]);
    } else {
        assert(board >= 0 && read(board, &marker, 1) == 1 && marker == 'p');
        close(board);
    }
    assert(write(hid, "V", 1) == 1);
    close(hid);
    return 0;
}}
