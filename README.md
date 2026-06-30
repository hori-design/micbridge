# MicBridge

macOS のノイズキャンセリング済みマイク音声を、仮想オーディオデバイス（BlackHole など）へ橋渡しするための最小構成メニューバーアプリ。

## 何を解決するか

Web ベースの会議ツールでエコーキャンセリングを有効にすると、macOS のマイクノイズキャンセリングが無効化される。しかし Web 会議ツール側のノイキャンは実用に耐えないため、以下のワークフローで macOS のノイキャンを保持したい。

1. 物理マイク（macOS のノイキャン適用済み）→ 仮想マイク（BlackHole）へルーティング
2. Web 会議ツール側は仮想マイクを入力として選択
3. Web 会議ツールのエコキャンは「すでにノイキャン済みの音声」を受け取ることになる

MicBridge はこの「物理マイク → 仮想マイク」の橋渡しに専用化した、ミキシング機能を持たないアプリ。

## 必要環境

- macOS 14 以降
- Xcode 15 以降（開発時）
- [BlackHole](https://github.com/ExistentialAudio/BlackHole) など仮想オーディオデバイス（別途インストール）

## セットアップ手順

### 1. BlackHole をインストール

```bash
brew install --cask blackhole-2ch
```

（既にインストール済みなら不要）

### 2. Xcode でプロジェクトを開く

```bash
open MicBridge.xcodeproj
```

初回起動時、Xcode が KeyboardShortcuts の Swift Package を自動解決する（数分かかる場合あり）。

### 3. 署名設定

Xcode で `MicBridge` ターゲット → `Signing & Capabilities` を開き、自分の Apple Developer チームを選択（無料の Personal Team でも可）。

### 4. ビルドして実行

`⌘R` で実行。メニューバーにマイクアイコンが表示される。

## 使い方

1. メニューバーのマイクアイコンをクリック
2. `入力デバイス` に物理マイク（例: 内蔵マイク / USB マイク）を選択
3. `出力デバイス（仮想マイクへ）` に `BlackHole 2ch` を選択
4. `モニター出力` に自分のスピーカー / ヘッドフォンを選択（オプション、自分の声を確認したい場合）
5. `ブリッジを開始` を押す
6. Web 会議ツール（Zoom, Google Meet 等）の入力デバイスとして `BlackHole 2ch` を選択

### ミュート

- メニューバー → `ミュート`
- グローバルショートカット: デフォルトは `⌃⌥⇧M`（設定画面で変更可）
- アイコンが `mic.slash.fill` に変わる
- 実装は `AVAudioMixerNode` のボリュームを 0 にするだけで、ルーティング自体は維持している。クリックノイズが出ない

### 設定画面

メニューバー → `設定…` または `⌘,` で SwiftUI の設定画面が開く。

## 実装メモ

### オーディオパイプライン

3 つの `AVAudioEngine` を並列で使用:

- `inputEngine`: 入力デバイスからキャプチャ（`installTap`）
- `outputEngine`: `AVAudioPlayerNode → AVAudioMixerNode → outputNode（仮想マイクデバイス）`
- `monitorEngine` (optional): 同上、モニター出力デバイスへ

キャプチャした `AVAudioPCMBuffer` を outputEngine と monitorEngine の各 playerNode に `scheduleBuffer` で流し込む。単一の `AVAudioEngine` では入力と出力を別々のデバイスに指定できないため、複数エンジンで対応。

各エンジンの `inputNode.audioUnit` / `outputNode.audioUnit` に対して `kAudioOutputUnitProperty_CurrentDevice` を `AudioUnitSetProperty` で設定してデバイスを固定している（[MicBridge/Audio/AudioBridge.swift](MicBridge/Audio/AudioBridge.swift) を参照）。

### ミュート

`outputEngine.mainMixerNode.outputVolume` を 0 に切り替えるだけ。ルーティング（node 間の接続）は維持されるため、再有効化時にクリックノイズや不連続が発生しない。

### 明示的にスコープ外

- 高度なミキシング（複数入力、EQ、ゲイン）
- 仮想オーディオデバイスの自作（HAL Plugin）
- 現状は BlackHole など既存の仮想デバイスの利用を前提

## ディレクトリ構成

```
MicBridge/
├── App/          # SwiftUI App エントリと NSApplicationDelegate
├── Audio/        # AVAudioEngine ブリッジと Core Audio デバイス列挙
├── State/        # 中央 ObservableObject（AppState）
├── UI/           # NSStatusItem メニューバーと SwiftUI 設定画面
└── Info.plist / MicBridge.entitlements / Assets.xcassets
```

## 権限

初回起動時に macOS がマイクへのアクセス許可を求める。拒否すると `システム設定 > プライバシーとセキュリティ > マイク` で MicBridge を許可する必要がある。

## ライセンス

MIT（予定）
