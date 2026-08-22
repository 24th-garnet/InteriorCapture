# capture — madoriba-capture（iPadOS 撮影アプリ）

ARKit セッションを回し、キーフレームを選別して MDR バンドルに記録する。

仕様: [`docs/pipeline.md`](../docs/pipeline.md) §2〜§4 / [`spec/mdr-v1.md`](../spec/mdr-v1.md)

## ビルド

`.xcodeproj` は `project.yml` から生成する（生成物なのでコミットしない）。

```bash
brew install xcodegen
cd capture
xcodegen generate
open MadoribaCapture.xcodeproj
```

Xcode の Signing & Capabilities で Team を選ぶ。実機へは USB-C で転送する。

コンパイル確認だけなら署名不要:

```bash
xcodebuild -project MadoribaCapture.xcodeproj -scheme MadoribaCapture \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  build CODE_SIGNING_ALLOWED=NO
```

## 設計原則

1. **ARKit の生値をそのまま保存する。** 座標変換は recon 側に一元化する。
   capture 側で変換すると、バグが見つかったときに再撮影が必要になる。
2. **画像を回転させない。** `capturedImage` は常にセンサ native の向きで、
   `intrinsics` もその向きに対応する。native のまま通すことで座標系バグを原理的に避ける。
3. 解像度上限は **1920×1440**（A12Z は ARKit 4K 非対応。4K は iPhone 11+ / M1 iPad Pro 以降）。

## セッション設定

- `worldAlignment = .gravity` — Y 軸が重力に一致し床・壁が軸整合になる。
  `.gravityAndHeading` は磁気コンパス依存で**室内では不安定**なので使わない
- `sceneReconstruction = .meshWithClassification`
- `frameSemantics = [.sceneDepth]` — 生の深度のみ。smoothed は併用しない（A12Z の負荷）
- 30fps 固定。60fps は熱予算を食うだけで、キーフレーム選別後の枚数は変わらない

## キーフレーム選別

30fps 全保存は容量の無駄なだけでなく**有害**。同一視点の重複は 3DGS の
densification を歪めて floater を増やす。狙いは実効 3〜6fps。

| 条件 | 意図 |
|---|---|
| `trackingState == .normal` | 信用できないポーズを捨てる |
| 並進 5cm または回転 5° 以上 | 視点の多様性 |
| Laplacian 分散 ≥ 直近中央値 × 0.6 | **モーションブラー除去**（室内の最大の敵） |
| `.high` の信頼度画素が 30% 以上 | 初期点群の質 |

シャープネスの基準は棄却フレームも含めて更新する。部屋全体が一様に暗い場合に
基準まで一緒に下がらないと、全フレームが落ちてしまうため。

## 取り出し

`UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace` により、
Documents がファイル App の「このiPad内」に出る。AirDrop / USB で Mac にコピーする。

ストリーミング転送（Phase 4）を実装するまではこれが唯一の取り出し口。1 部屋 ~200MB。

## 実機で確認すること

アプリ右上の ⓘ から `DeviceProbe` の結果を見る。起動時にコンソールにも出る。

- [ ] `supportedVideoFormats` に 1920×1440 @30fps があるか
- [ ] `recommendedVideoFormatForHighResolutionFrameCapturing` が nil でないか
      （**A12Z では nil の可能性がある**。nil なら 12MP 静止画の混ぜ込みは諦める。致命的ではない）
- [ ] `confidenceMap` の実際の値域（仕様上は 0/1/2 だが 1..3 と観測されるという報告がある）
- [ ] 深度マップの実解像度（256×192 の想定）
- [ ] 3 分連続撮影での実効 fps と `thermalState` の推移

想定とズレていたら、コードより先に [`spec/mdr-v1.md`](../spec/mdr-v1.md) を直す。

## 既知の割り切り

JPEG エンコードを ARSession のデリゲートキュー（専用シリアルキュー）で同期実行している。
キーフレームは実効 3〜6fps なので 30fps の入力に対して余裕があり、詰まって落ちるのは
どのみち捨てるフレームなので実害がない。A12Z で追いつかないと分かったら、
バッファをコピーして別キューに逃がす。
