# iOS ↔ PC 세이브 크로스플레이 플랜

어나더레드(Pokémon Essentials / mkxp-z) iOS 포팅에서 **PC와 세이브 파일을 공유**해
같은 세이브로 이어 플레이하기 위한 구현 계획.

## 배경 / 현황 (조사 완료)

- **세이브 저장 위치(현재)**: `config.cpp`의
  `customDataPath = SDL_GetPrefPath(dataPathOrg=".", dataPathApp="Pokemon Another Red")`.
  - iOS: `<app sandbox>/Library/Application Support/Pokemon Another Red/` → **iOS 파일 공유로 접근 불가**(Documents만 노출됨).
  - Windows(PC mkxp-z): `%APPDATA%/Pokemon Another Red/`.
  - 같은 엔진·Essentials·같은 `dataPathApp` → **세이브 파일 포맷 동일 = 그대로 교환 가능**.
- **파일 공유는 이미 활성화**: `Info-iOS.plist`에 `UIFileSharingEnabled=true` +
  `LSSupportsOpeningDocumentsInPlace=true` → 앱의 **Documents** 폴더가
  Files 앱(내 iPhone → Another Red) / Finder(기기 파일 공유)에 노출됨.
- 게임 에셋은 첫 실행 시 번들에서 `Documents/game/`으로 복사됨(별개).

→ **남은 작업 = iOS에서 세이브를 Library가 아니라 Documents 아래로 떨어뜨리기.**

## 구현 단계

1. **iOS용 Documents 경로 헬퍼**
   - `src/filesystem/filesystemImplApple.mm`에 `getDocumentsPath()` 추가
     (`getDefaultGameRoot`이 쓰는 `NSDocumentDirectory` 패턴 재사용), `filesystemImpl.h`에 선언.

2. **세이브 경로를 Documents로 (iOS 분기)**
   - `config.cpp`의 `customDataPath` 산정에 `#if TARGET_OS_IPHONE` 분기:
     `SDL_GetPrefPath` 대신 `<Documents>/Pokemon Another Red/`(또는 `<Documents>/Save/`).
   - 폴더 없으면 생성(`NSFileManager createDirectoryAtPath`).
   - `userConfPath`(config.cpp)도 자동으로 그 아래로 따라감 — OK.

3. **(선택) 기존 세이브 1회 마이그레이션**
   - 첫 적용 시 `Library/Application Support/Pokemon Another Red/`에 세이브가 있으면
     `Documents/...`로 복사. 아직 본격 세이브 전이면 생략 가능.

4. **검증**
   - 빌드·설치 후 인게임 저장 → **실제 세이브 파일명/경로 확인**(Essentials가 쓰는 이름; `.rxdata` 추정).
   - Files 앱에 보이는지, PC `%APPDATA%/Pokemon Another Red/`와 교환되는지 확인.

## 사용자 워크플로 (구현 후)

- **iOS → PC**: Files 앱(또는 Finder 기기 파일 공유)에서
  `Another Red/Pokemon Another Red/<세이브>`를 꺼내 PC `%APPDATA%/Pokemon Another Red/`에 복사.
- **PC → iOS**: 반대로. 같은 파일명·포맷이라 그대로 인식.

## 주의 / 함정

- Documents 세이브는 **앱 재설치해도 보존**(Documents는 안 지워짐) → 크로스플레이 + 백업 둘 다 이득.
- 세이브 폴더는 게임 에셋(`Documents/game/`)과 **분리** 권장(섞이지 않게).
- `.rxdata`는 바이너리라 OS 간 줄바꿈/인코딩 문제 없음.
- iOS 세이브 경로 변경 후 첫 실행이면 기존(있다면) 세이브가 새 위치엔 없으므로, 필요 시 3번 마이그레이션.
