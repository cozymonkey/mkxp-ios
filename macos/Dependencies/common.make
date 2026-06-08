# Platform knobs. Defaults preserve the original macOS behavior; iOS make files
# override these before `include common.make` (see ios-arm64.make).
PLATFORM ?= macosx
SYSROOT ?=
VERSION_MIN_FLAG ?= -mmacosx-version-min=$(MINIMUM_REQUIRED)
DEPLOYMENT_TARGET_ENV ?= MACOSX_DEPLOYMENT_TARGET=$(MINIMUM_REQUIRED)

TARGETFLAGS := $(TARGETFLAGS) $(VERSION_MIN_FLAG)
BUILD_PREFIX := ${PWD}/build-$(PLATFORM)-$(ARCH)
LIBDIR := $(BUILD_PREFIX)/lib
INCLUDEDIR := $(BUILD_PREFIX)/include
# Keep download/build trees per-platform so an iOS build can't clobber a macOS one
# (both share HOST=aarch64-apple-darwin, so key the cache on PLATFORM+ARCH instead).
DOWNLOADS ?= ${PWD}/downloads/$(PLATFORM)-$(ARCH)
NPROC := $(shell sysctl -n hw.ncpu)
# Explicitly including freetype2 dir for now. macOS is having weird issues with ft2build.h
CFLAGS := -I$(INCLUDEDIR) -I$(INCLUDEDIR)/freetype2 $(TARGETFLAGS) $(DEFINES) -O3
LDFLAGS := -L$(LIBDIR)
CC      := clang -arch $(ARCH) $(if $(strip $(SYSROOT)),-isysroot $(SYSROOT),)
PKG_CONFIG_LIBDIR := $(BUILD_PREFIX)/lib/pkgconfig
GIT := git
CLONE := $(GIT) clone -q
GITHUB := https://github.com

# need to set the build variable because Ruby is picky.
# iOS make files override RBUILD to a triple that differs from --host, so autoconf
# treats the Ruby build as a cross-compile and skips run-time (AC_RUN) probes.
ifndef RBUILD
ifeq "$(strip $(shell uname -m))" "arm64"
RBUILD := aarch64-apple-darwin
else
RBUILD := x86_64-apple-darwin
endif
endif


CONFIGURE_ENV := \
	$(DEPLOYMENT_TARGET_ENV) \
	CMAKE_POLICY_VERSION_MINIMUM=3.10 \
	PKG_CONFIG_LIBDIR=$(PKG_CONFIG_LIBDIR) \
	CC="$(CC)" CFLAGS="$(CFLAGS)" LDFLAGS="$(LDFLAGS)"

CONFIGURE_ARGS := \
	--prefix="$(BUILD_PREFIX)" \
	--host=$(HOST)

# Platform-specific cmake args. Empty on macOS (native build); iOS sets
# -DCMAKE_SYSTEM_NAME=iOS + the iphoneos sysroot so cmake cross-compiles.
CMAKE_PLATFORM_ARGS ?=

# SDL_image JPEG XL support. On by default; iOS turns it off because vendored
# libjxl builds host tools that can't install for iOS (and the game uses PNG/JPG).
IMG_JXL ?= yes

CMAKE_ARGS := \
	-DCMAKE_INSTALL_PREFIX="$(BUILD_PREFIX)" \
	-DCMAKE_PREFIX_PATH="$(BUILD_PREFIX)" \
	-DCMAKE_OSX_ARCHITECTURES=$(ARCH) \
	-DCMAKE_OSX_DEPLOYMENT_TARGET=$(MINIMUM_REQUIRED) \
	-DCMAKE_C_FLAGS="$(CFLAGS)" \
	-DCMAKE_BUILD_TYPE=Release \
	$(CMAKE_PLATFORM_ARGS)


# Ruby won't think it's cross-compiling unless
# the BUILD variable is set now for whatever reason,
# but 
# Ruby output/link knobs. Defaults preserve macOS (shared dylib); iOS overrides
# these to produce a static archive and to drop ext that can't run on iOS.
RUBY_SHARED_FLAG ?= --enable-shared
RUBY_OUT_EXT ?= fiddle,gdbm,win32ole,win32
RUBY_LIB ?= libruby.3.1.dylib
RUBY_POSTINSTALL ?= install_name_tool -id @rpath/libruby.3.1.dylib $(LIBDIR)/libruby.3.1.dylib
# Extra env exported in front of Ruby's ./configure (e.g. cross_compiling=yes for iOS).
RUBY_CONFIGURE_ENV_EXTRA ?=
# Source patch applied once after cloning Ruby (iOS-only fixups). No-op on macOS.
RUBY_PATCH ?= :
# Extra args appended to Ruby's `make` / `make install` (e.g. BUNDLED_GEMS= to skip
# bundled-gem C extensions that can't cross-link for iOS).
RUBY_MAKE_ARGS ?=

RUBY_CONFIGURE_ARGS := \
	--enable-install-static-library \
	$(RUBY_SHARED_FLAG) \
	--with-out-ext=$(RUBY_OUT_EXT) \
	--with-static-linked-ext \
	--disable-rubygems \
	--disable-install-doc \
	--build=$(RBUILD) \
	${EXTRA_RUBY_CONFIG_ARGS}

CONFIGURE := $(CONFIGURE_ENV) ./configure $(CONFIGURE_ARGS)
AUTOGEN   := $(CONFIGURE_ENV) ./autogen.sh $(CONFIGURE_ARGS)
CMAKE     := $(CONFIGURE_ENV) cmake .. $(CMAKE_ARGS)

default:

# Theora
libtheora: init_dirs libvorbis libogg $(LIBDIR)/libtheora.a

$(LIBDIR)/libtheora.a: $(LIBDIR)/libogg.a $(DOWNLOADS)/theora/Makefile
	cd $(DOWNLOADS)/theora; \
	make -j$(NPROC); make install

$(DOWNLOADS)/theora/Makefile: $(DOWNLOADS)/theora/configure
	cd $(DOWNLOADS)/theora; \
	$(CONFIGURE) --with-ogg=$(BUILD_PREFIX) --enable-shared=false --enable-static=true --disable-examples

$(DOWNLOADS)/theora/configure: $(DOWNLOADS)/theora/autogen.sh
	cd $(DOWNLOADS)/theora; \
	./autogen.sh

$(DOWNLOADS)/theora/autogen.sh:
	$(CLONE) $(GITHUB)/xiph/theora $(DOWNLOADS)/theora

# Vorbis
libvorbis: init_dirs libogg $(LIBDIR)/libvorbis.a

$(LIBDIR)/libvorbis.a: $(LIBDIR)/libogg.a $(DOWNLOADS)/vorbis/cmakebuild/Makefile
	cd $(DOWNLOADS)/vorbis/cmakebuild; \
	make -j$(NPROC); make install

$(DOWNLOADS)/vorbis/cmakebuild/Makefile: $(DOWNLOADS)/vorbis/CMakeLists.txt
	cd $(DOWNLOADS)/vorbis; \
	mkdir cmakebuild; cd cmakebuild; \
	$(CMAKE) -DBUILD_SHARED_LIBS=no

$(DOWNLOADS)/vorbis/CMakeLists.txt:
	$(CLONE) $(GITHUB)/xiph/vorbis -b v1.3.7 $(DOWNLOADS)/vorbis


# Ogg, dependency of Vorbis
libogg: init_dirs $(LIBDIR)/libogg.a

$(LIBDIR)/libogg.a: $(DOWNLOADS)/ogg/Makefile
	cd $(DOWNLOADS)/ogg; \
	make -j$(NPROC); make install

$(DOWNLOADS)/ogg/Makefile: $(DOWNLOADS)/ogg/configure
	cd $(DOWNLOADS)/ogg; \
	$(CONFIGURE) --enable-static=true --enable-shared=false

$(DOWNLOADS)/ogg/configure: $(DOWNLOADS)/ogg/autogen.sh
	cd $(DOWNLOADS)/ogg; ./autogen.sh

$(DOWNLOADS)/ogg/autogen.sh:
	$(CLONE) $(GITHUB)/xiph/ogg -b v1.3.6 $(DOWNLOADS)/ogg
	
# uchardet
uchardet: init_dirs $(LIBDIR)/libuchardet.a

$(LIBDIR)/libuchardet.a: $(DOWNLOADS)/uchardet/cmakebuild/Makefile
	cd $(DOWNLOADS)/uchardet/cmakebuild; \
	make -j$(NPROC); make install

$(DOWNLOADS)/uchardet/cmakebuild/Makefile: $(DOWNLOADS)/uchardet/CMakeLists.txt
	cd $(DOWNLOADS)/uchardet; \
	mkdir cmakebuild; cd cmakebuild; \
	$(CMAKE) -DBUILD_SHARED_LIBS=no -DBUILD_BINARY=OFF

$(DOWNLOADS)/uchardet/CMakeLists.txt:
	$(CLONE) https://gitlab.freedesktop.org/uchardet/uchardet -b v0.0.8 $(DOWNLOADS)/uchardet


# Pixman
pixman: init_dirs libpng $(LIBDIR)/libpixman-1.a

$(LIBDIR)/libpixman-1.a: $(DOWNLOADS)/pixman/Makefile
	cd $(DOWNLOADS)/pixman
	make -C $(DOWNLOADS)/pixman -j$(NPROC)
	make -C $(DOWNLOADS)/pixman install

$(DOWNLOADS)/pixman/Makefile: $(DOWNLOADS)/pixman/autogen.sh
	cd $(DOWNLOADS)/pixman; \
	$(AUTOGEN) --enable-static=yes --enable-shared=no \
	--disable-arm-a64-neon

$(DOWNLOADS)/pixman/autogen.sh:
	$(CLONE) https://gitlab.freedesktop.org/pixman/pixman -b pixman-0.42.2 $(DOWNLOADS)/pixman


# PhysFS

physfs: init_dirs $(LIBDIR)/libphysfs.a

$(LIBDIR)/libphysfs.a: $(DOWNLOADS)/physfs/cmakebuild/Makefile
	cd $(DOWNLOADS)/physfs/cmakebuild; \
	make -j$(NPROC); make install

$(DOWNLOADS)/physfs/cmakebuild/Makefile: $(DOWNLOADS)/physfs/CMakeLists.txt
	cd $(DOWNLOADS)/physfs; \
	mkdir cmakebuild; cd cmakebuild; \
	$(CMAKE) -DPHYSFS_BUILD_STATIC=true -DPHYSFS_BUILD_SHARED=false -DPHYSFS_BUILD_TEST=false

$(DOWNLOADS)/physfs/CMakeLists.txt:
	$(CLONE) $(GITHUB)/icculus/physfs -b release-3.2.0 $(DOWNLOADS)/physfs

# libpng
libpng: init_dirs $(LIBDIR)/libpng.a

$(LIBDIR)/libpng.a: $(DOWNLOADS)/libpng/Makefile
	cd $(DOWNLOADS)/libpng; \
	make -j$(NPROC); make install

$(DOWNLOADS)/libpng/Makefile: $(DOWNLOADS)/libpng/configure
	cd $(DOWNLOADS)/libpng; \
	$(CONFIGURE) \
	--enable-shared=no --enable-static=yes

$(DOWNLOADS)/libpng/configure:
	$(CLONE) $(GITHUB)/pnggroup/libpng -b v1.6.50 $(DOWNLOADS)/libpng

# SDL2
sdl2: init_dirs $(LIBDIR)/libSDL2.a

$(LIBDIR)/libSDL2.a: $(DOWNLOADS)/sdl2/cmakebuild/Makefile
	cd $(DOWNLOADS)/sdl2/cmakebuild; \
	make -j$(NPROC); make install

$(DOWNLOADS)/sdl2/cmakebuild/Makefile: $(DOWNLOADS)/sdl2/CMakeLists.txt
	cd $(DOWNLOADS)/sdl2; \
	mkdir cmakebuild; cd cmakebuild; \
	$(CMAKE) -DBUILD_SHARED_LIBS=no

$(DOWNLOADS)/sdl2/CMakeLists.txt:
	$(CLONE) $(GITHUB)/mkxp-z/SDL $(DOWNLOADS)/sdl2 -b mkxp-z-2.28.1
	
# SDL_image
sdl2image: init_dirs sdl2 $(LIBDIR)/libSDL2_image.a

$(LIBDIR)/libSDL2_image.a: $(DOWNLOADS)/sdl2_image/cmakebuild/Makefile
	cd $(DOWNLOADS)/sdl2_image/cmakebuild; \
	make -j$(NPROC); make install

$(DOWNLOADS)/sdl2_image/cmakebuild/Makefile: $(DOWNLOADS)/sdl2_image/CMakeLists.txt
	cd $(DOWNLOADS)/sdl2_image; mkdir -p cmakebuild; cd cmakebuild; \
	$(CMAKE) \
	-DBUILD_SHARED_LIBS=no \
	-DSDL2IMAGE_JPG_SAVE=yes \
	-DSDL2IMAGE_PNG_SAVE=yes \
	-DSDL2IMAGE_PNG_SHARED=no \
	-DSDL2IMAGE_JPG_SHARED=no \
	-DSDL2IMAGE_JXL=$(IMG_JXL) \
	-DSDL2IMAGE_JXL_SHARED=no \
	-DSDL2IMAGE_BACKEND_IMAGEIO=no \
	-DSDL2IMAGE_VENDORED=yes
	

$(DOWNLOADS)/sdl2_image/CMakeLists.txt:
	$(CLONE) $(GITHUB)/mkxp-z/SDL_image $(DOWNLOADS)/sdl2_image -b mkxp-z; \
	cd $(DOWNLOADS)/sdl2_image; \
	./external/download.sh


# SDL_sound
sdlsound: init_dirs sdl2 libogg libvorbis $(LIBDIR)/libSDL2_sound.a

$(LIBDIR)/libSDL2_sound.a: $(DOWNLOADS)/sdl_sound/cmakebuild/Makefile
	cd $(DOWNLOADS)/sdl_sound/cmakebuild; \
	make -j$(NPROC); make install

$(DOWNLOADS)/sdl_sound/cmakebuild/Makefile: $(DOWNLOADS)/sdl_sound/CMakeLists.txt
	cd $(DOWNLOADS)/sdl_sound; mkdir -p cmakebuild; cd cmakebuild; \
	$(CMAKE) \
	-DSDLSOUND_BUILD_SHARED=false \
	-DSDLSOUND_BUILD_TEST=false \
	-DSDLSOUND_DECODER_COREAUDIO=false

$(DOWNLOADS)/sdl_sound/CMakeLists.txt:
	$(CLONE) $(GITHUB)/mkxp-z/SDL_sound $(DOWNLOADS)/sdl_sound -b git

	
# SDL2 (ttf)
sdl2ttf: init_dirs sdl2 freetype $(LIBDIR)/libSDL2_ttf.a

$(LIBDIR)/libSDL2_ttf.a: $(DOWNLOADS)/sdl2_ttf/Makefile
	cd $(DOWNLOADS)/sdl2_ttf; \
	make -j$(NPROC); make install

$(DOWNLOADS)/sdl2_ttf/Makefile: $(DOWNLOADS)/sdl2_ttf/configure
	cd $(DOWNLOADS)/sdl2_ttf; \
	$(CONFIGURE) --enable-static=true --enable-shared=false $(SDL2_TTF_FLAGS)

$(DOWNLOADS)/sdl2_ttf/configure: $(DOWNLOADS)/sdl2_ttf/autogen.sh
	cd $(DOWNLOADS)/sdl2_ttf; ./autogen.sh

$(DOWNLOADS)/sdl2_ttf/autogen.sh:
	$(CLONE) $(GITHUB)/mkxp-z/SDL_ttf $(DOWNLOADS)/sdl2_ttf -b mkxp-z

# Freetype (dependency of SDL2_ttf)
freetype: init_dirs $(LIBDIR)/libfreetype.a

$(LIBDIR)/libfreetype.a: $(DOWNLOADS)/freetype/Makefile
	cd $(DOWNLOADS)/freetype; \
	make -j$(NPROC); make install

$(DOWNLOADS)/freetype/Makefile: $(DOWNLOADS)/freetype/configure
	cd $(DOWNLOADS)/freetype; \
	$(CONFIGURE) --enable-static=true --enable-shared=false

$(DOWNLOADS)/freetype/configure: $(DOWNLOADS)/freetype/autogen.sh
	cd $(DOWNLOADS)/freetype; ./autogen.sh

$(DOWNLOADS)/freetype/autogen.sh:
	$(CLONE) $(GITHUB)/mkxp-z/freetype2 $(DOWNLOADS)/freetype

# OpenAL
openal: init_dirs libogg $(LIBDIR)/libopenal.a

$(LIBDIR)/libopenal.a: $(DOWNLOADS)/openal/cmakebuild/Makefile
	cd $(DOWNLOADS)/openal/cmakebuild; \
	make -j$(NPROC); make install

$(DOWNLOADS)/openal/cmakebuild/Makefile: $(DOWNLOADS)/openal/CMakeLists.txt
	cd $(DOWNLOADS)/openal; mkdir cmakebuild; cd cmakebuild; \
	$(CMAKE) -DLIBTYPE=STATIC -DALSOFT_EXAMPLES=no -DALSOFT_UTILS=no $(OPENAL_FLAGS)

$(DOWNLOADS)/openal/CMakeLists.txt:
	$(CLONE) $(GITHUB)/kcat/openal-soft -b 1.24.3 $(DOWNLOADS)/openal

# OpenSSL
openssl: init_dirs $(LIBDIR)/libssl.a
$(LIBDIR)/libssl.a: $(DOWNLOADS)/openssl/Makefile
	cd $(DOWNLOADS)/openssl; \
	$(CONFIGURE_ENV) make -j$(NPROC); make install_sw

$(DOWNLOADS)/openssl/Makefile: $(DOWNLOADS)/openssl/Configure
	cd $(DOWNLOADS)/openssl; \
	$(CONFIGURE_ENV) ./Configure $(OPENSSL_FLAGS) \
	no-shared \
	--prefix="$(BUILD_PREFIX)" \
	--openssldir="$(BUILD_PREFIX)"

$(DOWNLOADS)/openssl/Configure:
	$(CLONE) $(GITHUB)/openssl/openssl $(DOWNLOADS)/openssl --single-branch --branch openssl-3.0.12 --depth 1

# Standard ruby
ruby: init_dirs openssl $(LIBDIR)/$(RUBY_LIB)

$(LIBDIR)/$(RUBY_LIB): $(DOWNLOADS)/ruby/Makefile
	cd $(DOWNLOADS)/ruby; \
	$(CONFIGURE_ENV) make -j$(NPROC) $(RUBY_MAKE_ARGS); $(CONFIGURE_ENV) make install $(RUBY_MAKE_ARGS)
	$(RUBY_POSTINSTALL)

# -std=gnu99 is needed with GCC 15 and higher (which default to gnu23), for Ruby versions that aren't valid C23.
# Ruby versions that are valid C23 are 3.2.9+, 3.3.9+, 3.4.5+, and 3.5.0+.
$(DOWNLOADS)/ruby/Makefile: $(DOWNLOADS)/ruby/configure
	cd $(DOWNLOADS)/ruby; \
	export $(CONFIGURE_ENV); \
	export CFLAGS="-std=gnu99 -flto=full -DRUBY_FUNCTION_NAME_STRING=__func__ $$CFLAGS"; \
	export LDFLAGS="-flto=full $$LDFLAGS"; \
	$(RUBY_CONFIGURE_ENV_EXTRA) ./configure $(CONFIGURE_ARGS) $(RUBY_CONFIGURE_ARGS) $(RUBY_FLAGS)

$(DOWNLOADS)/ruby/configure: $(DOWNLOADS)/ruby/configure.ac
	cd $(DOWNLOADS)/ruby; autoreconf -i

$(DOWNLOADS)/ruby/configure.ac:
	$(CLONE) $(GITHUB)/mkxp-z/ruby $(DOWNLOADS)/ruby --single-branch -b mkxp-z-3.1.3 --depth 1;
	sed -i '' '/: $${PRELOADENV=DYLD_INSERT_LIBRARIES}/g' $(DOWNLOADS)/ruby/configure.ac
	$(RUBY_PATCH)

# ==== fluidsynth + glib (iOS only) ====
# macOS ships a prebuilt Frameworks/libfluidsynth.dylib (fluidsynth 2.1.5 with glib
# statically linked); iOS builds its own. fluidsynth 2.x hard-depends on glib, which we
# build with meson, letting it pull libffi/pcre2/proxy-libintl/zlib as subprojects
# (--wrap-mode=forcefallback). Output: a self-contained libfluidsynth.dylib that the
# engine links via @rpath (mkxp-z's shared_fluid path).
#
# IMPORTANT: meson and fluidsynth COMPILE-AND-RUN build-time helper binaries (meson's
# compiler sanity checks, fluidsynth's table generator, etc.). Build this chain in an
# environment that can execute freshly-built native binaries (a normal shell). Sandboxed
# CI/agent environments that block exec of new binaries will hang here.

GLIB_VERSION ?= 2.78.4
FLUIDSYNTH_VERSION ?= v2.3.5

# Homebrew Python 3.12+ dropped stdlib distutils (PEP 632), but glib's bundled
# gdbus-codegen still does `import distutils.version`. meson runs codegen under its
# own interpreter (ignores native-file python), so we inject a minimal shim that
# provides distutils.version.LooseVersion via PYTHONPATH. macOS builds don't use
# the glib target, so this is iOS-only in practice.
GLIB_PYTHONPATH ?= ${PWD}/pyshim
# Force-fallback only the deps the iOS SDK lacks (libffi/pcre2/intl/gvdb). zlib and
# iconv resolve from the SDK — crucially this drops the bundled zlib 1.2.11 wrap,
# whose zutil.h treats TARGET_OS_MAC (set on iOS too) as classic Mac OS and #defines
# fdopen to NULL, colliding with the SDK's fdopen() prototype.
GLIB_MESON_WRAP ?= --force-fallback-for=libffi,libpcre2-8,proxy-libintl,gvdb
# Post-clone source patch hook (iOS make sets this to fix gspawn's libproc.h use).
GLIB_PATCH ?= :
# Post-clone source patch hook for fluidsynth (iOS make drops AppKit/Carbon, which
# fluidsynth's FindGLib2.cmake hardcodes for all Apple targets but iOS lacks).
FLUIDSYNTH_PATCH ?= :

# glib (meson). MESON_CROSS_FILE is generated by the iOS make ($(IOS_MESON_CROSS)).
glib: init_dirs $(LIBDIR)/libglib-2.0.a

$(LIBDIR)/libglib-2.0.a: $(DOWNLOADS)/glib/mesonbuild/build.ninja
	cd $(DOWNLOADS)/glib/mesonbuild; PYTHONPATH=$(GLIB_PYTHONPATH) ninja; PYTHONPATH=$(GLIB_PYTHONPATH) ninja install

$(DOWNLOADS)/glib/mesonbuild/build.ninja: $(DOWNLOADS)/glib/meson.build $(MESON_CROSS_FILE)
	cd $(DOWNLOADS)/glib; rm -rf mesonbuild; \
	PKG_CONFIG_LIBDIR=$(PKG_CONFIG_LIBDIR) meson setup mesonbuild \
		$(if $(MESON_CROSS_FILE),--cross-file=$(MESON_CROSS_FILE),) \
		--prefix=$(BUILD_PREFIX) --buildtype=release \
		--default-library=static $(GLIB_MESON_WRAP) \
		-Dtests=false -Dnls=disabled -Dlibmount=disabled \
		-Dselinux=disabled -Dman=false -Dglib_debug=disabled

$(DOWNLOADS)/glib/meson.build:
	$(CLONE) https://gitlab.gnome.org/GNOME/glib -b $(GLIB_VERSION) --depth 1 $(DOWNLOADS)/glib
	$(GLIB_PATCH)

# fluidsynth (cmake). Self-contained shared dylib; glib linked statically. Audio backends
# off (mkxp-z feeds PCM via OpenAL); only the synth core is needed.
fluidsynth: init_dirs glib $(LIBDIR)/libfluidsynth.dylib

$(LIBDIR)/libfluidsynth.dylib: $(DOWNLOADS)/fluidsynth/cmakebuild/Makefile
	cd $(DOWNLOADS)/fluidsynth/cmakebuild; \
	make -j$(NPROC); make install
	install_name_tool -id @rpath/libfluidsynth.dylib $(LIBDIR)/libfluidsynth.dylib
	# Flatten the versioned-dylib symlink into a real file so Xcode's "Embed
	# Frameworks" copies an actual binary (a symlink would dangle in the app).
	cd $(LIBDIR) && cp -L libfluidsynth.dylib .fluid.real && rm -f libfluidsynth.dylib && mv .fluid.real libfluidsynth.dylib

$(DOWNLOADS)/fluidsynth/cmakebuild/Makefile: $(DOWNLOADS)/fluidsynth/CMakeLists.txt
	cd $(DOWNLOADS)/fluidsynth; mkdir -p cmakebuild; cd cmakebuild; \
	$(CMAKE) -DBUILD_SHARED_LIBS=on \
		-DCMAKE_MACOSX_BUNDLE=OFF \
		-Denable-framework=off -Denable-readline=off -Denable-sdl2=off \
		-Denable-libsndfile=off -Denable-dbus=off -Denable-jack=off \
		-Denable-pulseaudio=off -Denable-alsa=off -Denable-oss=off \
		-Denable-coreaudio=off -Denable-coremidi=off -Denable-aufile=off \
		-Denable-ipv6=off

$(DOWNLOADS)/fluidsynth/CMakeLists.txt:
	$(CLONE) $(GITHUB)/FluidSynth/fluidsynth -b $(FLUIDSYNTH_VERSION) $(DOWNLOADS)/fluidsynth
	# CMake 4.x dropped compatibility with cmake_minimum_required < 3.5; the gentables
	# host-helper subproject still declares 3.1, which aborts its configure step.
	sed -i '' 's/cmake_minimum_required(VERSION 3\.1)/cmake_minimum_required(VERSION 3.5)/' $(DOWNLOADS)/fluidsynth/src/gentables/CMakeLists.txt
	$(FLUIDSYNTH_PATCH)

# ====
init_dirs:
	@mkdir -p $(LIBDIR) $(INCLUDEDIR)

clean: clean-compiled

powerwash: clean-compiled clean-downloads

clean-downloads:
	-rm -rf $(DOWNLOADS)

clean-compiled:
	-rm -rf build-$(PLATFORM)-$(ARCH)

deps-core: libtheora libvorbis pixman libpng physfs uchardet sdl2 sdl2image sdlsound sdl2ttf openal openssl
everything: deps-core ruby
