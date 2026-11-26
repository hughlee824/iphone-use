#import "../../Sources/AppleNativeBridge/AppleNativeBridge.m"

int main(void) { @autoreleasepool {
    if (!Load(NULL)) return 1;
    xpc_object_t hello = Encode(DiscoveryHello(), 0, NULL);
    xpc_object_t properties = xpc_dictionary_get_value(hello, "Properties");
    xpc_object_t flags = xpc_dictionary_get_value(properties, "RemoteXPCVersionFlags");
    uint64_t (*runtimeFlags)(void) = dlsym(remote, "xpc_remote_connection_get_version_flags");
    return !runtimeFlags || !flags || xpc_get_type(flags) != XPC_TYPE_UINT64
        || xpc_uint64_get_value(flags) != runtimeFlags();
}}
