# mkxp-z iOS 포팅 — 작업 기록 / 결정 로그

> 목적: mkxp-z(RGSS 재구현 엔진)를 iOS arm64로 포팅해 Pokémon Essentials 기반
> 팬게임 "어나더레드"를 아이폰에서 네이티브 구동. 사이드로드(AltStore/Sideloadly) 배포.
> 이 문서는 **작업하며 내린 모든 판단과 근거, 부딪힌 함정과 해결**을 시간순/주제별로 기록한다.
> 새 결정을 내릴 때마다 여기 추가한다.

작업 브랜치: `ios-port` (clone base: `dev`). 빌드 산출물은 모두 `.gitignore` 대상.

---

## 0. 전체 전략 / 설계 원칙

- **기존 macOS 빌드를 절대 깨지 않는다.** mkxp-z의 의존성 빌드는 `macos/Dependencies/`의
  make 시스템(`arm64.make`/`x86_64.make` → `common.make`)을 쓴다. iOS는 **`common.make`를
  플랫폼 변수로 파라미터화**하고(기본값 = 현재 macOS 동작 그대로), iOS 값은 신규
  `ios-arm64.make`가 주입한다. → macOS 경로는 변수 미설정 시 100% 동일하게 동작.
- **PoC로 단계를 끊는다.** CLAUDE.md 로드맵대로 1) Ruby 단독 빌드 → 2) deps-core →
  3) fluidsynth → (이후) Xcode 앱 타겟. 각 단계 산출물을 `lipo`/`vtool`로 iOS arm64 검증.
- **"굴러가는 것 우선".** 이론상 더 깔끔한 길보다, mkxp-z가 macOS에서 이미 검증한 구성을
  따른다(예: Ruby를 정적 .a 단독이 아니라 shared dylib로 — 아래 참조).

### 환경 (확인된 사실)
- 머신: Apple Silicon(arm64) macOS, **풀 Xcode** 설치됨 → `iPhoneOS26.5.sdk`.
- 호스트 도구: ruby 2.6.10(시스템), brew로 cmake/autoconf/automake/libtool/pkg-config/meson/ninja.
- iOS deployment target: **14.0** (`-miphoneos-version-min=14.0`).

### `common.make` 파라미터화 — 도입한 knob (기본값=macOS)
| 변수 | 기본값(macOS) | iOS 값 | 용도 |
|---|---|---|---|
| `PLATFORM` | `macosx` | `iphoneos` | `build-$(PLATFORM)-$(ARCH)` 출력 디렉토리. Xcode가 `build-$(SDK_ROOT)-...`로 찾음 |
| `SYSROOT` | (빈값) | `xcrun --sdk iphoneos` | `CC`에 `-isysroot` 조건부 주입 |
| `VERSION_MIN_FLAG` | `-mmacosx-version-min` | `-miphoneos-version-min` | |
| `DEPLOYMENT_TARGET_ENV` | `MACOSX_...` | `IPHONEOS_...` | |
| `DOWNLOADS` | `downloads/$(PLATFORM)-$(ARCH)` | 〃 | **iOS/macOS 빌드 트리 분리**(둘 다 HOST=aarch64-apple-darwin이라 충돌 방지) |
| `RBUILD` | uname 기반 | `x86_64-apple-darwin` | Ruby 크로스 강제(아래) |
| `CMAKE_PLATFORM_ARGS` | (빈값) | iOS 툴체인 | cmake 크로스(아래) |
| `RUBY_*` 여러 개 | macOS 값 | iOS 값 | Ruby 빌드 세부(아래) |
| `IMG_JXL` | `yes` | `no` | SDL_image JPEG XL(아래) |

> 핵심 교훈: 변수는 `?=`(미설정 시만 기본값) 또는 `ifndef` 가드로 둬야 iOS make의 override가
> 살아남는다. `CMAKE_PLATFORM_ARGS`는 `BUILD_PREFIX`(common.make에서 나중 정의)를 참조하므로
> **recursive `=`**로 둬야 한다(`:=` 즉시확장이면 빈값으로 박힘).

---

## 1. PoC 1 — MRI Ruby 3.1 (iOS arm64)  ✅ 완료

CLAUDE.md가 "최대 난관"으로 지목한 단계. mkxp-z 포크 ruby(`github.com/mkxp-z/ruby`,
브랜치 `mkxp-z-3.1.3`)를 iphoneos SDK로 크로스컴파일.

### 결정: shared dylib 채택 (정적 .a 단독 포기)
- 처음엔 CLAUDE.md 가정대로 `--disable-shared`(정적 .a)로 시도했으나, **정적 단독 빌드는
  `--with-static-linked-ext` + LTO 조합에서 최종 `ruby` 실행파일 링크가 깨짐**
  (ext의 `Init_*` 심볼 미해결, `-bundle_loader` 누락 등).
- mkxp-z의 macOS 빌드는 `--enable-shared`로 `libruby.3.1.dylib`을 만들고 엔진이
  `@rpath/libruby.3.1.dylib`로 링크한다(검증된 경로). **iOS도 동일 구성으로 전환** →
  한 번에 빌드 성공. 정적 `.a`도 부산물로 같이 나옴(`--enable-install-static-library`).
- iOS 사이드로드는 앱 번들 `Frameworks/`에 **서명된 dylib 임베드**로 해결(2단계에서 처리).
- 산출물: `libruby.3.1.dylib`(12MB, platform IOS / minos 14.0, install_name `@rpath/...`),
  `libruby.3.1-static.a`(18MB). `nm`으로 `_ruby_init/_ruby_setup/_rb_eval_string` 확인.

### 부딪힌 함정 4가지 (전부 해결)
1. **build==host면 autoconf가 크로스 인식 못 함** → iOS 바이너리를 호스트에서 실행하려다
   `Error 77 (cannot run C compiled programs)`. **해결: `RBUILD=x86_64-apple-darwin`**로
   `--build`≠`--host`(aarch64-apple-darwin) 만들어 강제 크로스. 컴파일러는 그대로
   `clang -arch arm64 -isysroot <iOS>`라 build 트리플은 크로스 감지용 힌트일 뿐.
2. **iOS SDK엔 `<sys/vnode.h>` 없음** (`dir.c`가 `__APPLE__` 가드로 무조건 include).
   dir.c는 `vtype`/`vtagtype` enum(`VREG`/`VDIR`/`VLNK`, `VT_HFS`/`VT_CIFS` 등 — getattrlist
   반환값과 비교)만 쓴다. **해결: `RUBY_PATCH`로 `TARGET_OS_IPHONE`에서 두 enum을 직접 정의**,
   비-iOS Apple은 실제 헤더 include. enum 값은 XNU 커널 ABI 그대로(순서 중요).
3. **iOS SDK엔 `<sys/random.h>` 없음**(심볼 `getentropy`는 libSystem에 존재) →
   `random.c`에서 암시적 선언 에러. **해결: `RUBY_PATCH`로 `HAVE_SYS_RANDOM_H` 없을 때
   `__APPLE__`면 `extern int getentropy(void*, size_t);` 프로토타입 선언** 추가.
4. **번들 gem(rbs/debug)의 동적 `.bundle` 확장이 크로스 링크 실패**(miniruby 경로 참조).
   게임 런타임엔 불필요. **해결: `RUBY_PATCH`로 `gems/bundled_gems` 비움**(+ 이미 추출된
   `.bundle/gems` 제거). `BUNDLED_GEMS=` make 변수로는 안 막혔음(추출분이 build-ext로 잡힘).

기타: iOS는 fork/exec·tty 없음, JIT(W^X) 금지 → `--disable-jit-support`,
`--with-out-ext=fiddle,gdbm,win32ole,win32,pty,syslog,readline,dbm`,
`--with-baseruby=$(which ruby)`(호스트 2.6.10). OpenSSL은 `ios64-xcrun` 타겟으로 빌드.

> 재현 시: 실패한 빌드 트리를 두고 재시도하면 `mkdir` 충돌·configure 캐시 문제가 생기니,
> 설정을 바꿨으면 ruby는 `make distclean`, cmake류는 `rm -rf <pkg>/cmakebuild` 후 재시도.

---

## 2. deps-core 나머지 라이브러리 (iOS arm64)  ✅ 완료

`libtheora libvorbis pixman libpng physfs uchardet sdl2 sdl2image sdlsound sdl2ttf openal`
(+ 의존 libogg/freetype) + openssl + ruby = **23개 .a (47MB), 전부 platform IOS 검증**.

### cmake 크로스 설정 (`CMAKE_PLATFORM_ARGS`, iOS만)
- `-DCMAKE_SYSTEM_NAME=iOS` — cmake를 크로스 모드로(런타임 프로브 스킵, iphoneos 툴체인 선택).
- **`-DCMAKE_SYSTEM_PROCESSOR=arm64` 필수** — 빠지면 `CMAKE_SYSTEM_PROCESSOR`가 빈 문자열이
  되어 libjxl 등의 `if(... ${VAR} MATCHES ...)` 구문이 문법 에러로 깨진다.
- `-DCMAKE_OSX_SYSROOT=$(SYSROOT)`.
- **`-DCMAKE_FIND_ROOT_PATH=$(BUILD_PREFIX)` + 모든 `*_MODE=BOTH`** — 크로스 모드에서
  `find_package()`가 기본적으로 sysroot만 뒤져 우리가 빌드한 libogg/freetype 등을 못 찾는다.
  ROOT_PATH에 우리 prefix를 넣고 모든 모드를 `BOTH`로(host prefix도 탐색) 해야 찾는다.

### 라이브러리별 함정
- **physfs**: 테스트 실행파일 `test_physfs`(MACOSX_BUNDLE)를 iOS에 install하려다 실패 →
  `-DPHYSFS_BUILD_TEST=false`.
- **uchardet**: CLI 툴을 install하려다 실패 → `-DBUILD_BINARY=OFF`.
- **sdl2image / libjxl**: vendored libjxl이 iOS에 CLI 툴(cjxl/djxl)을 빌드·install하려다 실패.
  게임은 PNG/JPG만 쓰므로 **`IMG_JXL` knob으로 iOS는 JXL=no**. (위 SYSTEM_PROCESSOR 수정으로
  libjxl `if`문은 넘겼지만 툴 install이 또 막혀, 아예 끄는 게 깔끔.)
- **openal**: "Could NOT find DBus/PulseAudio/ALSA/..."는 Linux 오디오 백엔드 스킵일 뿐
  (iOS는 CoreAudio). 정상 빌드됨.

> 공통: 실패한 cmake 패키지를 재시도할 땐 `rm -rf downloads/iphoneos-arm64/<pkg>/cmakebuild`
> (make 규칙이 `mkdir cmakebuild`를 `-p` 없이 하는 경우 충돌나기 때문).

---

## ⚠️ 환경 한계 — 이 에이전트(샌드박스)에선 fluidsynth 체인 빌드 불가

fluidsynth 체인을 코드화한 뒤 실제 빌드를 시도하다 **결정적 환경 제약**을 발견:

- **이 에이전트 실행 환경은 "갓 컴파일된 네이티브 바이너리"를 실행하지 못한다**(커널/AMFI
  레벨에서 멈춤; 코드서명·샌드박스 비활성화로도 해결 안 됨). 검증: trivial `int main(){return 0;}`
  를 `cc`로 빌드해 실행하면 무한 멈춤, `timeout`조차 못 죽임(D-state).
- **deps-core/Ruby가 성공한 이유**: 전부 **크로스컴파일**이라 빌드 중 타겟/헬퍼 바이너리를
  실행하지 않았다(Ruby도 BASERUBY=시스템 ruby 사용).
- **glib(meson)·fluidsynth가 막히는 이유**: meson은 컴파일러 sanity check로 **빌드머신
  네이티브 바이너리를 컴파일해서 실행**하고, fluidsynth도 빌드 중 테이블 생성기 등 헬퍼
  바이너리를 실행한다 → 이 환경에서 멈춘다. 코드/설정 문제가 아니다.
- **결론**: fluidsynth 체인은 **완전히 코드화**(아래) 했고 드라이런·cross-file 생성까지
  검증했다. **실제 빌드는 일반 터미널(바이너리 실행 가능한 환경)에서 `make fluidsynth
  -f ios-arm64.make` 한 줄로 돌리면 된다.** 거기서 wrap libffi의 CFI 이슈가 재현되면 아래
  메모대로 대응.

> 함의: 향후 어떤 빌드든 "빌드 중 네이티브 헬퍼 실행"이 필요하면 이 머신에선 막힌다.
> 크로스컴파일(실행 안 함) 위주의 작업만 여기서 끝까지 가능.

**근본 원인 (2026-06-08 확정)**: Claude Code 샌드박스가 아니라 **머신 자체**다. 순정
Terminal.app에서도 trivial `int main(){return 0;}`가 실행 즉시 멈춤. `systemextensionsctl list`로
범인 확인: **`com.nprotect.nosfw` (nProtect / 잉카인터넷, 한국 기업/금융 맥 보안 에이전트)** 의
endpoint system extension이 새 실행파일의 exec을 가로채 hang. 회사 관리 정책이라 임의로 못 끄는
경우가 많음. → fluidsynth/glib 같은 "빌드 중 네이티브 헬퍼 실행" 빌드는 nProtect 없는 머신
(개인 맥/CI/클라우드 맥)에서 수행해야 함. 크로스컴파일 deps(Ruby/deps-core)·Xcode iOS 앱 빌드는
영향 없음(타겟 바이너리는 iPhone/시뮬레이터에서 실행).

## 3. fluidsynth (iOS arm64) — ✅ 코드화 완료 / ⏸ 실제 빌드는 일반 환경에서

MIDI BGM(`soundfont.sf2`)용. mkxp-z는 macOS용 prebuilt `Frameworks/libfluidsynth.dylib`만
갖고 있고 소스 빌드 make 타겟이 없다 → iOS용을 새로 만들어야 함.

### 조사 결과 (확정)
- prebuilt는 **fluidsynth 2.1.5** + **glib 정적 링크(심볼 숨김)** 인 self-contained dylib
  (otool -L에 glib 의존 없음, nm에 g_ 외부심볼 없음, 하지만 strings에 glib 흔적 있음, 1MB).
- mkxp-z는 fluidsynth 함수 **17개 최소 API만** 사용(new/delete_settings·synth,
  settings_set*, synth_noteon/off·cc·program_change·pitch_bend·channel_pressure·
  sfload·system_reset·write_s 등). 전부 1.x/2.x 공통.
- mkxp-z 사용 방식: meson `shared_fluid`(기본 true) = **빌드타임에 fluidsynth 심볼 직접
  동적링크**. false면 `SDL_LoadObject`로 런타임 dlopen(MIDI 옵션화). 어느 쪽이든 **실제
  재생엔 iOS용 libfluidsynth가 필요**.

### 결정: glib을 meson으로 빌드(libffi/pcre2는 meson wrap으로)
- fluidsynth 2.x는 **glib 하드의존**(1.x도 마찬가지). glib은 libffi(gobject용)+pcre2 의존.
- **libffi를 autotools로 직접 빌드 시도 → 실패**: arm64 `sysv.S`가
  `.cfi_adjust_cfa_offset (수식)`을 방출하는데 iOS Mach-O 어셈블러가 "invalid CFI advance_loc
  expression"으로 거부. configure 캐시변수 `libffi_cv_as_cfi_pseudo_op=no`로도 안 막힘
  (어셈블리가 무조건 CFI 방출). libffi autotools는 iOS에서 악명 높은 지점.
- **전환: glib을 meson으로 빌드하며 `--wrap-mode=forcefallback`로 libffi/pcre2/proxy-libintl/
  zlib을 meson subproject로 자동 처리.** wrapdb의 libffi wrap은 Apple 패치를 포함하므로
  CFI 문제를 우회할 가능성이 높다(검증 중). glib 2.78.4 사용(wrap 전부 존재 확인).
- **meson cross-file 함정**: host_machine을 `system=darwin, cpu_family=aarch64`로만 두면
  빌드머신과 동일해 meson이 크로스로 인식 못 하고 **iOS sanity 바이너리를 호스트에서
  실행하려다 무한정 멈춤**(Ruby의 build==host와 같은 부류). **해결: cross-file
  `[properties] needs_exe_wrapper = true`** 로 호스트 바이너리 실행 자체를 금지.
- glib 빌드 옵션: `--default-library=static -Dtests=false -Dnls=disabled -Dlibmount=disabled
  -Dselinux=disabled -Dman=false -Dglib_debug=disabled` (introspection 옵션은 2.78.4에 없음,
  g-ir-scanner 부재로 자동 비활성).

### 코드화 완료 (common.make / ios-arm64.make)
- `glib`(meson) + `fluidsynth`(cmake) 타겟 추가. `make fluidsynth -f ios-arm64.make`로 빌드.
- glib: `meson setup --cross-file=<생성된 ios-arm64.cross> --default-library=static
  --wrap-mode=forcefallback -Dtests=false -Dnls=disabled -Dlibmount=disabled
  -Dselinux=disabled -Dman=false -Dglib_debug=disabled` → `ninja install`.
- meson cross-file은 `ios-arm64.make`가 빌드 시 생성(`$(BUILD_PREFIX)/ios-arm64.cross`,
  SYSROOT가 동적이므로). `needs_exe_wrapper=true` 포함.
- fluidsynth: cmake `-DBUILD_SHARED_LIBS=on` + 오디오 백엔드 전부 off(coreaudio/coremidi 포함 —
  mkxp-z가 OpenAL로 PCM을 직접 먹이므로 synth 코어만 필요) → self-contained `libfluidsynth.dylib`,
  `install_name_tool -id @rpath/libfluidsynth.dylib`. 버전 `FLUIDSYNTH_VERSION ?= v2.3.5`,
  `GLIB_VERSION ?= 2.78.4`(override 가능).

### 실제 빌드 시 남은 검증 (일반 환경에서)
- [ ] glib meson setup 통과 → wrap libffi가 CFI(`sysv.S`) 문제를 정말 피하는지 확인.
      재현되면: meson `subprojects/libffi/`의 빌드에 위 D8 CFI 회피를 적용하거나, libffi wrap
      버전을 Apple 패치 포함본으로 교체.
- [ ] fluidsynth dylib가 self-contained(glib 정적 포함, 시스템 라이브러리 외 의존 없음)인지
      `otool -L`로 확인 — macOS prebuilt처럼.
- [ ] platform IOS / minos 14.0 / arm64 검증.

---

## 결정 로그 요약 (한눈에)

| # | 결정 | 이유 |
|---|---|---|
| D1 | macOS 빌드 보존, iOS는 knob 주입 | 회귀 방지, 격리 |
| D2 | Ruby를 shared dylib로(정적 단독 포기) | 정적+LTO 최종 링크 깨짐, macOS 검증 경로와 일치 |
| D3 | RBUILD=x86_64로 크로스 강제 | build==host면 autoconf가 iOS 바이너리 실행 시도 |
| D4 | dir.c/random.c를 RUBY_PATCH로 패치 | iOS SDK에 sys/vnode.h·sys/random.h 없음 |
| D5 | bundled_gems 비움 | 동적 .bundle 확장 크로스 링크 실패, 게임에 불필요 |
| D6 | cmake에 SYSTEM_NAME=iOS + SYSTEM_PROCESSOR=arm64 + FIND_ROOT_PATH BOTH | 크로스 인식·find_package 우리 prefix 탐색 |
| D7 | physfs 테스트·uchardet CLI·sdl2image JXL 끔 | iOS에 실행파일 install 불가, 게임 불필요 |
| D8 | glib을 meson+forcefallback wrap으로 | libffi autotools가 iOS CFI 어셈블리에서 실패 |
| D9 | meson cross-file에 needs_exe_wrapper=true | 빌드==호스트 트리플이라 meson이 iOS 바이너리 실행 시도(멈춤) |
| D10 | fluidsynth 체인 코드화하되 실제 빌드는 일반 환경에 인계 | 이 에이전트 환경이 갓 빌드한 네이티브 바이너리 실행 불가(meson/fluidsynth가 필요로 함) |
| D11 | fluidsynth 오디오 백엔드 전부 off | mkxp-z가 OpenAL로 PCM 직접 출력, synth 코어만 필요 |

---

## 재현 방법 (요약)

```sh
# 사전: 풀 Xcode + brew bundle(cmake/autoconf/automake/libtool/pkg-config) + brew install meson ninja
cd macos/Dependencies
make everything -f ios-arm64.make          # deps-core + ruby (1·2단계)
# fluidsynth 체인(3단계)은 코드화 후: make fluidsynth -f ios-arm64.make
```
검증: `lipo -info build-iphoneos-arm64/lib/<lib>.a` → arm64,
`vtool -show-build <obj>` → platform IOS / minos 14.0.

산출물 위치: `macos/Dependencies/build-iphoneos-arm64/lib/` (gitignore됨).

---

## 다음 단계 (전체 로드맵 기준)
1. (진행 중) fluidsynth 완성.
2. **2단계 Xcode iOS App 타겟**: `mkxp-z.xcodeproj`에 iOS 타겟 추가, ANGLE/GLES(`-DGLES2_HEADER`),
   위 .a/dylib 링크, MiniFFI 스텁(`TARGET_OS_IPHONE`), 게임 에셋 번들, Info.plist/entitlements.
3. **3단계 MiniFFI(Win32API) 스텁** — Essentials의 소수 Win32API 호출 방어.
4. **4단계 터치 입력 오버레이** — 가상 D패드/버튼 → SDL 이벤트.
5. **5단계 사이드로드 배포**.
