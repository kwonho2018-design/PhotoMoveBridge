# PhotoMove Bridge

PhotoMove Bridge는 iPhone에서 선택한 원본 사진/동영상을 USB 내보내기 세션 폴더로 만들고, Windows 앱에서 해당 폴더를 PC 하드 또는 외장하드의 사용자가 선택한 위치로 가져와 파일 크기와 SHA256으로 검증하는 로컬 이동 시스템입니다.

## 프로젝트 구성

- `iOS/PhotoMoveBridge/PhotoMoveBridge.xcodeproj`
  - SwiftUI iPhone 앱
  - PhotoKit 권한, 월/일 그룹 선택, 원본 리소스 추출, USB 내보내기 세션 생성, SHA256 계산, 로그 저장
  - 앱 문서 공유를 사용하므로 Windows의 Apple Devices 또는 iTunes 파일 공유에서 `PhotoMoveBridgeUSBExport` 폴더를 확인할 수 있습니다.
- `Windows/PhotoMoveBridge.Windows/PhotoMoveBridge.Windows.csproj`
  - .NET 8 WPF 앱
  - 드라이브 목록, 컴퓨터 하드/외장하드 저장 루트 선택, 쓰기 테스트, USB 내보내기 세션 폴더 가져오기, `.partial` 저장, 크기/SHA256/경로 검증, 로그 저장
- `Windows/Publish-Windows.ps1`
  - `win-x64` self-contained single-file publish와 선택적 `signtool` 코드서명을 수행합니다.
- `docs/IMPLEMENTATION.md`
  - USB 전용 출시 구조와 테스트 체크리스트

## iOS 빌드

```sh
xcodebuild -project iOS/PhotoMoveBridge/PhotoMoveBridge.xcodeproj \
  -scheme PhotoMoveBridge \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

실기기/App Store 배포 시에는 Xcode에서 Team, Bundle Identifier, Signing, App Store Connect 메타데이터를 개발자 계정에 맞게 설정하세요.

## Windows 빌드/배포

Windows 10/11 PC에 .NET 8 SDK를 설치한 뒤:

```powershell
cd Windows
.\Publish-Windows.ps1
```

코드서명 인증서가 준비되어 있으면:

```powershell
.\Publish-Windows.ps1 -CertificateThumbprint "YOUR_CERT_THUMBPRINT"
```

## 핵심 안전 규칙

- iPhone 앱은 네트워크 서버로 사진/동영상을 전송하지 않습니다.
- USB 내보내기 세션은 `PhotoMoveBridgeUSBExport/PhotoMoveBridge-YYYYMMDD-HHMMSS` 구조로 생성됩니다.
- USB 내보내기 폴더와 파일은 iCloud/iTunes 백업 제외 대상으로 표시됩니다.
- Windows 앱은 선택된 저장 루트 아래에만 최종 파일을 저장합니다.
- 가져오기 파일은 먼저 `.partial`로 저장하고, 크기와 SHA256 검증 성공 후 최종 파일명으로 rename합니다.
- 실패, 해시 불일치, 크기 불일치, 경로 오류는 성공 결과에 포함되지 않습니다.
