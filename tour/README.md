# tour — madoriba-tour（ツアービューア）

3DGS を station point 制約で歩き回るビューア。macOS 15+。

仕様: [`docs/pipeline.md`](../docs/pipeline.md) §8

## ビルドと起動

```bash
brew install xcodegen
cd tour && xcodegen generate
xcodebuild -project MadoribaTour.xcodeproj -scheme MadoribaTour \
  -configuration Release -derivedDataPath /tmp/tourbuild build

# 起動引数で直接開ける（開発中に毎回選ばずに済む）
open -a /tmp/tourbuild/Build/Products/Release/MadoribaTour.app \
  --args tour.json splat.ply
```

`tour.json` は recon で作る:

```bash
mdr2colmap tour room-xxxx.mdr -o tour.json
```

## 操作

| 操作 | 動作 |
|---|---|
| ドラッグ | 見回す |
| クリック / ↑ / W | 見ている方向へ 1 station 前進 |
| ← → / A D | その場で向きを変える |
| 下部の番号 | 任意の station へ直接移動 |

## なぜ自由飛行にしないか

**3DGS は撮影視点から離れると破綻する。** これを弱点として避けるのではなく、
制約として設計に取り込む。移動を撮影軌跡上の station に限れば
「常に撮影視点の近傍しか描画しない」＝ 3DGS が最も得意な条件だけを使うことになる。
Matterport が station point 方式を採るのも同じ理屈。

## 実装上の判断

| | 理由 |
|---|---|
| **station は空間的に重複排除する** | 撮影は外周を3パス+中央1パスするので、経路長だけで拾うと同じ物理位置に最大4重に積み重なる（実データで 21 個 → 11 個） |
| **視点高さを床+1.5m に固定** | 撮影時は手持ちで高さがばらつく。そのまま使うと station ごとに視点が上下する |
| **到着時の向きから上下の傾きを捨てる** | 撮影時は床や天井を向いていることが多く、そのままだと床を向いて始まる |
| **前進先を進行方向との角度で重み付け** | 単純な最近傍だと、後ろを向いているときに前進で後退する |
| **0.55 秒の smoothstep 補間** | 等速だと開始と停止が唐突。速すぎると酔う |
| **上下の視線を ±76 度に制限** | 真上・真下は撮影が薄く破綻しやすい |

## 依存

[MetalSplatter](https://github.com/scier/MetalSplatter) を SPM のローカル依存として使う
（`vendor/MetalSplatter`）。PLY / SPZ / .splat を直接読める。macOS 15+ を要求する。

同梱の SampleApp には視点操作が実装されていない（カメラ固定で自動回転するのみ）ため、
描画部だけを使い、カメラとナビゲーションは自前で持つ。

## iOS への移植

`TourCamera` と `TourRenderer` はプラットフォーム非依存。
`TourView.swift` の `NSViewRepresentable` と `NSEvent` 処理だけが macOS 固有なので、
iOS 版では `UIViewRepresentable` + `UIPanGestureRecognizer` に差し替える。
