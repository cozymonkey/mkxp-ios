# iOS arm64 (device) dependency build for mkxp-z.
#
# Base: arm64.make, retargeted from the macOS SDK to the iphoneos SDK.
# All the heavy lifting (build rules) lives in common.make; this file just sets
# the platform knobs it consumes (PLATFORM/SYSROOT/VERSION_MIN_FLAG/...).
#
# PoC 1 scope: only `make openssl` and `make ruby` are expected to work here.
# The cmake-based libs (sdl2, physfs, ...) still need iOS toolchain handling in
# common.make and are out of scope for this file for now.
#
# Requires full Xcode (not just Command Line Tools) so the iphoneos SDK exists:
#   sudo xcode-select -s /Applications/Xcode.app
#   xcrun --sdk iphoneos --show-sdk-path   # must print a path

ARCH := arm64
PLATFORM := iphoneos
HOST := aarch64-apple-darwin
MINIMUM_REQUIRED := 14.0

SYSROOT := $(shell xcrun --sdk iphoneos --show-sdk-path)
VERSION_MIN_FLAG := -miphoneos-version-min=$(MINIMUM_REQUIRED)
DEPLOYMENT_TARGET_ENV := IPHONEOS_DEPLOYMENT_TARGET=$(MINIMUM_REQUIRED)

# OpenSSL 3.0.12 ships a self-contained iOS arm64 target that resolves the SDK
# and compiler through xcrun. If it fights common.make's CC, fall back to
# `ios64-cross` and export CROSS_COMPILE/CROSS_TOP instead.
OPENSSL_FLAGS := ios64-xcrun

# Vendored libjxl can't cross-build for iOS (builds host CLI tools); game uses PNG/JPG.
IMG_JXL := no

# cmake cross-compile to iOS: CMAKE_SYSTEM_NAME=iOS flips cmake into cross mode
# (skips run-time probes, picks the iphoneos toolchain). Pin the sysroot explicitly.
# In cross mode find_package() only searches the sysroot by default, so point
# CMAKE_FIND_ROOT_PATH at our prefix and allow searching it (BOTH) for the libs
# we build (libogg, freetype, ...) instead of only the SDK.
# Recursive (=) so $(BUILD_PREFIX), defined later in common.make, expands at use time.
CMAKE_PLATFORM_ARGS = \
	-DCMAKE_SYSTEM_NAME=iOS \
	-DCMAKE_SYSTEM_PROCESSOR=arm64 \
	-DCMAKE_OSX_SYSROOT=$(SYSROOT) \
	-DCMAKE_FIND_ROOT_PATH=$(BUILD_PREFIX) \
	-DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=BOTH \
	-DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=BOTH \
	-DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH \
	-DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=BOTH

# ---------------------------------------------------------------------------
# Ruby (the hard part). Build a shared libruby.3.1.dylib, matching mkxp-z's proven
# macOS configuration (the engine links @rpath/libruby.3.1.dylib). A static-only
# build hits broken static-ext / LTO final-link paths under iOS cross-compile;
# the dylib is embedded + code-signed into the app bundle's Frameworks at phase 2.
# iOS can't fork/exec, has no tty, and forbids JIT (W^X), so drop those ext + JIT.
# RUBY_SHARED_FLAG / RUBY_LIB / RUBY_POSTINSTALL keep their common.make defaults
# (--enable-shared, libruby.3.1.dylib, install_name_tool -id @rpath/...).
RUBY_OUT_EXT := fiddle,gdbm,win32ole,win32,pty,syslog,readline,dbm

# Make --build differ from --host (both would be aarch64-apple-darwin otherwise) so
# autoconf detects a cross-compile and skips AC_RUN probes that would try to execute
# iOS binaries on the host. The compiler stays `clang -arch arm64 -isysroot <iOS>`,
# so the build triple is only a cross-detection hint, not a real target.
RBUILD := x86_64-apple-darwin
RUBY_CONFIGURE_ENV_EXTRA := cross_compiling=yes
EXTRA_RUBY_CONFIG_ARGS := \
	--with-baseruby=$(shell which ruby) \
	--disable-jit-support

# iOS SDK fixups for headers/symbols that exist on macOS but not iOS:
#  - dir.c includes <sys/vnode.h> under a bare __APPLE__ guard; iOS lacks it and
#    only needs the vtype/vtagtype enums.
#  - random.c needs a getentropy prototype (symbol exists, <sys/random.h> doesn't).
#  - empty bundled_gems: their .bundle C extensions can't cross-link against a
#    static libruby and the embedded game runtime doesn't use them.
RUBY_PATCH := \
	perl -0pi -e 's|\# include <sys/vnode\.h>|#include <TargetConditionals.h>\n# if TARGET_OS_IPHONE\nenum vtype { VNON, VREG, VDIR, VBLK, VCHR, VLNK, VSOCK, VFIFO, VBAD, VSTR, VCPLX };\nenum vtagtype { VT_NON, VT_UFS, VT_NFS, VT_MFS, VT_MSDOSFS, VT_LFS, VT_LOFS, VT_FDESC, VT_PORTAL, VT_NULL, VT_UMAP, VT_KERNFS, VT_PROCFS, VT_AFS, VT_ISOFS, VT_UNION, VT_HFS, VT_ZFS, VT_DEVFS, VT_WEBDAV, VT_UDF, VT_AFP, VT_CDDA, VT_CIFS, VT_OTHER };\n# else\n#  include <sys/vnode.h>\n# endif|' $(DOWNLOADS)/ruby/dir.c && \
	perl -0pi -e 's|\# if defined\(HAVE_SYS_RANDOM_H\)\n\#  include <sys/random\.h>\n\# endif|# if defined(HAVE_SYS_RANDOM_H)\n#  include <sys/random.h>\n# elif defined(__APPLE__)\nextern int getentropy(void *, size_t); /* iOS SDK ships no <sys/random.h> */\n# endif|' $(DOWNLOADS)/ruby/random.c && \
	sed -i '' '/^[^#]/d' $(DOWNLOADS)/ruby/gems/bundled_gems

# NOTE (expected iteration): with cross_compiling=yes, Ruby's configure will ask
# for AC_TRY_RUN results it can't run on the host. Feed the failing ones back as
# `ac_cv_*=...` cache vars here until configure completes. This is the known
# "며칠 소요 가능" risk from CLAUDE.md — drive it from the actual error log.

include common.make
