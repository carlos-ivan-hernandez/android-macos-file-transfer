// libmtp's header. scripts/build-libmtp.sh builds libmtp and copies its header next to this
// file (it isn't checked in, since it's generated for the libmtp version being built).
#if __has_include("libmtp.h")
#include "libmtp.h"
#else
#error "libmtp hasn't been built yet. Run ./scripts/build-libmtp.sh (build.sh runs it for you)."
#endif
