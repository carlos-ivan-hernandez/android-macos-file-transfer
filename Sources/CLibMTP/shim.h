// libmtp's header, from the copy scripts/build-libmtp.sh builds into .deps/. It's included by
// a path relative to this file, which works the same in every build system (newer ones don't
// always pass header search flags on to the step that scans module dependencies).
#if __has_include("../../.deps/include/libmtp.h")
#include "../../.deps/include/libmtp.h"
#else
#error "libmtp hasn't been built yet. Run ./scripts/build-libmtp.sh (build.sh runs it for you)."
#endif
