# App Store 심사 노트 (App Review Notes)

> App Store Connect → 앱 버전 → **"App 심사 정보 > 메모(Notes)"** 칸에 아래 영문 노트를 붙여넣으세요.
> 데모 계정은 필요 없습니다(로그인/서버 없음). 한국어 설명은 참고용입니다.

---

## 1. 핵심 요지 (심사관이 알아야 할 것)

- 이 앱은 **로컬 전용** 유틸리티입니다. 사진/동영상을 **개발자 서버, 클라우드, 네트워크로 전송하지 않습니다.**
- 선택한 원본을 앱의 Documents 폴더 안 `PhotoMoveBridgeUSBExport/<세션>` 으로 복사(내보내기)합니다.
- 사용자는 USB 케이블로 Windows에 연결해, Windows의 Apple Devices/iTunes **파일 공유**에서 그 폴더를 PC/외장하드로 가져갑니다(선택적, 앱 외부 단계).
- iPhone 사진 삭제는 **전적으로 사용자 선택**이며, 삭제 시 iOS 시스템 표준 삭제 확인 창이 뜹니다.

## 2. Windows PC 없이도 전체 기능을 심사할 수 있습니다 (중요)

검증/삭제 단계는 Windows 가져오기 성공을 **사용자가 직접 확인(attestation)** 하는 방식이라, 심사관은 **iPhone만으로** 전체 플로우를 끝까지 시연할 수 있습니다:

1. **권한** 탭 → "사진 접근 권한 요청" → 전체 또는 제한 접근 허용
2. **사진** 탭 → 월/일/개별 항목 선택 (1장만 선택해도 됨)
3. **이동** 탭 → "USB 내보내기 만들기" → 진행률이 끝나면 상태가 "복사됨"
   - (선택) iPhone을 Mac/PC Finder에 연결하면 파일 공유에 `PhotoMoveBridgeUSBExport` 폴더가 보입니다.
4. **이동** 탭 → "USB 내보내기 결과" → **"Windows 가져오기 검증"** 섹션의
   **"Windows 가져오기·검증 완료로 표시"** 버튼 탭 → 상태가 "삭제 가능"으로 바뀜
5. 같은 화면 **"삭제 가능"** → "복사 완료된 항목만 iPhone에서 삭제" → 확인 토글 →
   "iPhone 사진 보관함에서 삭제" → **iOS 시스템 삭제 확인 창**에서 삭제 완료

> 4번 버튼은 실제 Windows 연결을 요구하지 않습니다. "PC 가져오기를 끝냈음"을 사용자가
> 확인하는 안전 장치이므로, 심사 환경에서 PC 없이도 삭제 경로를 그대로 검증할 수 있습니다.

## 3. 영문 심사 노트 (붙여넣기용)

```
PhotoMove Bridge is a LOCAL-ONLY utility. It does NOT transmit photos or videos
to developer servers, cloud services, or over any network. There is no account
and no login.

What it does:
1. Reads selected original photos/videos via PhotoKit (with the user's permission).
2. Copies the selected originals into the app's own Documents folder as a dated
   "USB export" session (PhotoMoveBridgeUSBExport/<session>), with a manifest and
   per-file SHA-256.
3. The user connects the iPhone to a Windows PC by USB and copies that folder from
   the Apple Devices / iTunes "File Sharing" area to a PC/external drive using our
   optional companion desktop app. This step happens OUTSIDE the iOS app.
4. Only AFTER the user confirms the PC import succeeded, the app lets the user
   delete the already-copied items from the iPhone library. Deletion always shows
   the standard iOS system delete confirmation.

REVIEWING WITHOUT A WINDOWS PC (full path is testable on iPhone alone):
- Permission tab: grant photo access.
- Photos tab: select one or more items.
- Move tab: tap "USB 내보내기 만들기" (Create USB export). Status becomes "복사됨"
  (Copied).
- Move tab > "USB 내보내기 결과" (Results): under "Windows 가져오기 검증" tap
  "Windows 가져오기·검증 완료로 표시" (Mark as verified). This is a user attestation
  and does NOT require an actual PC, so the delete path is fully testable here.
- "삭제 가능" (Deletable) section: tap delete, toggle the confirmation, then delete.
  iOS shows its own system delete confirmation.

Privacy:
- The app does not collect data or transmit photos/videos to developer servers,
  cloud services, or over any network. Users may manually export selected files
  to their own Windows PC via USB file sharing.
- No third-party SDKs/analytics.
- App-internal logs/cache are stored in Application Support (not user-facing).
- Export files in Documents are excluded from iCloud/iTunes backup.

Export compliance: the app only uses SHA-256 hashing (exempt). Info.plist sets
ITSAppUsesNonExemptEncryption = false.
```

## 4. 예상 반려 사유와 대응

| 가이드라인 | 우려 | 대응 |
| --- | --- | --- |
| 2.1 앱 완성도 | 삭제 기능이 동작하지 않는 것처럼 보임 | 위 2번 플로우로 PC 없이 삭제까지 시연 가능하도록 수정됨 |
| 4.2 최소 기능 | 컴패니언 앱 의존 | iOS 단독으로도 "원본을 날짜별 폴더로 내보내 파일 공유로 추출" 가능. 심사 노트에 단독 가치 명시 |
| 5.1.1 데이터 접근 | 사진 권한/삭제 목적 | 권한 설명 문자열에 삭제 목적 명시(아래 참고), 삭제는 시스템 확인 창 사용 |
| 수출 규정 | 암호화 사용 | SHA-256만 사용(면제), `ITSAppUsesNonExemptEncryption=false` |

## 5. (선택) 데모 영상

PC가 필요한 라운드트립을 보여주려면 30~60초 화면 녹화를 첨부하면 더 안전합니다:
iPhone 내보내기 → Finder/Apple Devices 파일 공유에서 폴더 확인 → Windows 가져오기/검증 →
iPhone "검증 완료로 표시" → 삭제. (필수는 아님)
