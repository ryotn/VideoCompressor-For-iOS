# VideoCompressor-For-iOS

動画圧縮くんのiOS版です（iOS 17以降対応）。

## 概要

Android版 [VideoCompressor](https://github.com/ryotn/VideoCompressor) と同じく、端末上の動画を選択して圧縮するアプリです。
圧縮処理は Apple 公式フレームワーク（`AVFoundation` / `PhotosUI` / `Photos`）のみを利用し、ffmpeg などの外部プラグインには依存しません。

## 実装済み機能

- PhotosPicker で動画を選択
- 元動画情報の表示（サイズ / 長さ / 解像度 / 動画・音声ビットレート）
- **簡単モード**: 目標ファイルサイズ (MB) 指定で推定設定を自動計算
- **詳細モード**: コーデック / 動画・音声ビットレート / 解像度 / フレームレート / 音声削除の指定
- 推定圧縮後サイズ・推定圧縮率の表示
- `AVAssetExportSession` を使った動画圧縮
- 圧縮進捗表示
- 圧縮後サイズ表示
- 圧縮結果の共有（ShareLink）
- 圧縮結果を写真ライブラリへ保存

## UIイメージ

![UIイメージ](docs/ui-screenshot.png)

## 開発要件

- 言語: Swift
- UI: SwiftUI
- 対応OS: iOS 17+
