# MicBridge

macOS のノイズキャンセリング済みマイク音声を、[BlackHole](https://github.com/ExistentialAudio/BlackHole) などの仮想オーディオデバイスへ橋渡しするためのメニューバー常駐アプリ。

## 何を解決するか

Web ベースの会議ツールでエコーキャンセリングを有効にすると、macOS のマイクノイズキャンセリングが無効化されてしまう。一方で Web 会議ツール側のノイキャンは実用に耐えないため、以下のワークフローで macOS のノイキャンを保持したい。

1. 物理マイク（macOS のノイキャン適用済み）→ 仮想マイク（BlackHole）へルーティング
2. Web 会議ツール側は仮想マイクを入力として選択
3. Web 会議ツールのエコキャンは「すでにノイキャン済みの音声」を受け取ることになる

MicBridge はこの「物理マイク → 仮想マイク」の橋渡しに専用化した最小構成アプリ。

## 主な機能

- 入力デバイス / 出力デバイス（仮想マイク） / モニターデバイスを独立に選択
- ブリッジ ON/OFF、ミュート、モニター ON/OFF をメニューバーから即操作
- グローバルショートカット
  - ミュート トグル: `⌃⌥⇧M`（変更可）
  - モニター オン/オフ: `⌃⌥⇧N`（変更可）
- 選択したデバイスが外れて再接続された時に自動で選択を復元
- Mac 起動時の自動起動

## 必要環境

- macOS 14 以降
- [BlackHole](https://github.com/ExistentialAudio/BlackHole) など仮想オーディオデバイス

## セットアップ

### 1. BlackHole をインストール

```bash
brew install --cask blackhole-2ch
```

### 2. リポジトリを clone してビルド

```bash
git clone https://github.com/hori-design/micbridge.git
cd micbridge

xcodebuild -project MicBridge.xcodeproj \
  -scheme MicBridge \
  -configuration Release \
  -derivedDataPath build \
  build
```

初回は Swift Package の解決で数分かかる。

### 3. `/Applications` へ配置して起動

```bash
cp -R build/Build/Products/Release/MicBridge.app /Applications/
open /Applications/MicBridge.app
```

初回起動時に macOS がマイクへのアクセスを求めるので許可する。

## 使い方

メニューバーのマイクアイコンをクリック。

1. `入力デバイス` に物理マイク
2. `出力デバイス（仮想マイクへ）` に `BlackHole 2ch`
3. `モニター出力` にスピーカー / ヘッドフォン（自分の声を確認したい場合）
4. `ブリッジを開始`
5. Web 会議ツールの入力デバイスを `BlackHole 2ch` に切り替える

## ライセンス

MIT
