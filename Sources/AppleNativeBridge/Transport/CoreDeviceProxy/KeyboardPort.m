#import "DeviceServiceTransport.h"
#import <sys/socket.h>
#import <poll.h>
#import <fcntl.h>
#import <unistd.h>

// Only connected HID and pasteboard streams cross this private socketpair. The
// helper holds the discovery channel and USB packet pump until its parent closes.
static BOOL PassPort(int control, int port) {
    char byte = 'K';
    struct iovec io = { &byte, 1 };
    union { struct cmsghdr alignment; char bytes[CMSG_SPACE(sizeof(int))]; } storage = {0};
    struct msghdr message = { .msg_iov = &io, .msg_iovlen = 1,
        .msg_control = storage.bytes, .msg_controllen = sizeof(storage.bytes) };
    struct cmsghdr *header = CMSG_FIRSTHDR(&message);
    header->cmsg_level = SOL_SOCKET; header->cmsg_type = SCM_RIGHTS; header->cmsg_len = CMSG_LEN(sizeof(int));
    memcpy(CMSG_DATA(header), &port, sizeof(port));
    return sendmsg(control, &message, 0) == 1;
}

static BOOL ReportOpenFailure(NSException *exception) {
    NSData *reason = [(exception.reason ?: @"RSD keyboard service unavailable") dataUsingEncoding:NSUTF8StringEncoding];
    size_t length = MIN(reason.length, 512);
    ssize_t written;
    do {
        written = write(STDOUT_FILENO, reason.bytes, length);
    } while (written < 0 && errno == EINTR);
    return written > 0 && (size_t)written == length;
}

BOOL ASProvideKeyboardPort(NSString *udid, NSString *(^startMedia)(ASKeyboardMediaEndpoint *), BOOL (^stopMedia)(void)) {
    ASDeviceServiceTransport *provider;
    BOOL orderly = NO, released = NO;
    @try {
        provider = [[ASDeviceServiceTransport alloc] initWithUDID:udid sessionLifetime:YES];
        BOOL openedHID = NO, openedPasteboard = NO;
        while (YES) {
            char command;
            ssize_t count = read(STDOUT_FILENO, &command, 1);
            if (count < 0 && errno == EINTR) continue;
            if (count != 1) { orderly = count == 0; break; }
            if ((command == 'H' && !openedHID) || (command == 'P' && openedHID && !openedPasteboard)) {
                alarm(command == 'H' ? 32 : 16);
                if (command == 'H') {
                    NSString *error = startMedia([provider openKeyboardMedia]);
                    if (error) @throw [NSException exceptionWithName:@"KeyboardMedia" reason:error userInfo:nil];
                }
                int port;
                @try {
                    port = [provider openKeyboardService:command == 'P'];
                } @catch (NSException *exception) {
                    if (command != 'P') @throw;
                    // Failure to open the second port must leave the original HID stream
                    // available to release keys and remove the session's keyboard.
                    openedPasteboard = YES;
                    ReportOpenFailure(exception);
                    alarm(0);
                    continue;
                }
                BOOL sent = PassPort(STDOUT_FILENO, port);
                close(port);
                if (!sent) break;
                if (command == 'H') openedHID = YES; else openedPasteboard = YES;
                alarm(0);
            } else break;
        }
    } @catch (NSException *exception) {
        // The parent receives the open error on the socket. A reported refusal
        // can still end with acknowledged media and transport cleanup.
        orderly = ReportOpenFailure(exception);
    } @finally {
        alarm(32);
        BOOL mediaStopped = stopMedia();
        released = [provider close] && mediaStopped;
    }
    return orderly && released;
}

int ASReceiveKeyboardPort(int control, NSError **error) {
    char bytes[512] = {0};
    struct iovec io = { bytes, sizeof(bytes) };
    union { struct cmsghdr alignment; char bytes[CMSG_SPACE(sizeof(int))]; } storage = {0};
    struct msghdr message = { .msg_iov = &io, .msg_iovlen = 1,
        .msg_control = storage.bytes, .msg_controllen = sizeof(storage.bytes) };
    ssize_t count = -1;
    struct pollfd poller = {control, POLLIN, 0};
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + 32;
    while (NSProcessInfo.processInfo.systemUptime < deadline) {
        int ready = poll(&poller, 1, (int)MAX(0, (deadline - NSProcessInfo.processInfo.systemUptime) * 1000));
        if (ready < 0 && errno == EINTR) continue;
        if (ready > 0) count = recvmsg(control, &message, 0);
        break;
    }
    struct cmsghdr *header = count > 0 ? CMSG_FIRSTHDR(&message) : NULL;
    if (header && header->cmsg_level == SOL_SOCKET && header->cmsg_type == SCM_RIGHTS
        && header->cmsg_len == CMSG_LEN(sizeof(int))) {
        int port; memcpy(&port, CMSG_DATA(header), sizeof(port));
        if (count == 1 && bytes[0] == 'K' && !(message.msg_flags & MSG_CTRUNC)
            && fcntl(port, F_SETFD, FD_CLOEXEC) == 0) return port;
        close(port);
    }
    NSString *reason = count > 0 && !header ? [[NSString alloc] initWithBytes:bytes length:count encoding:NSUTF8StringEncoding] : nil;
    if (error) *error = [NSError errorWithDomain:@"iPhone-use.Keyboard" code:1
        userInfo:@{NSLocalizedDescriptionKey:reason ?: @"USB/RSD keyboard tunnel failed or expired"}];
    return -1;
}
