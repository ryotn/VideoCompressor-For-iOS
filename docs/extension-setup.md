# Extension setup for share + Live Activities

The app-side logic is implemented, but iOS requires separate extension targets for:

1. Live Activities UI (Widget Extension)
2. Share sheet intake (Share Extension)

## 1) Add Widget Extension target

1. Xcode -> File -> New -> Target -> **Widget Extension**
2. Name: `VideoCompressorLiveActivityExtension`
3. Include Live Activity support
4. Replace generated files with:
   - `VideoCompressorLiveActivityExtension/VideoCompressorLiveActivityBundle.swift`
   - `VideoCompressorLiveActivityExtension/CompressionLiveActivityWidget.swift`
5. Add `VideoCompressorForiOS/CompressionActivity.swift` to this target's membership.
6. Set extension bundle identifier (example):
   - `com.ryotn.VideoCompressorForiOS.liveactivity`

## 2) Add Share Extension target

1. Xcode -> File -> New -> Target -> **Share Extension**
2. Name: `VideoCompressorShareExtension`
3. Replace generated files with:
   - `VideoCompressorShareExtension/ShareViewController.swift`
   - `VideoCompressorShareExtension/Info.plist`
4. Add `VideoCompressorForiOS/SharedInbox.swift` to this target's membership.
5. Set extension bundle identifier (example):
   - `com.ryotn.VideoCompressorForiOS.share`
6. Ensure extension Info.plist includes:
   - `NSExtensionActivationSupportsMovieWithMaxCount = 1`

## 3) App Group capability

Add the same App Group to **all three targets**:

- `VideoCompressorForiOS`
- `VideoCompressorLiveActivityExtension`
- `VideoCompressorShareExtension`

Group ID:

- `group.com.ryotn.VideoCompressorForiOS`

## 4) URL scheme

The app URL scheme used for callback is:

- `videocompressor://import`

Already configured in app build settings (`CFBundleURLTypes`).

## 5) What is already implemented in app target

- Compression progress writes Live Activity updates from `ContentView`.
- Background compression flag is synchronized via App Group defaults.
- App polls shared inbox when active and via URL callback.
- If compressing, incoming shared video is rejected with an alert.
