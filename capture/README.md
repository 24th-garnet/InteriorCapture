# capture — madoriba-capture（iPadOS 撮影アプリ）

ARKit セッションを回し、キーフレームを選別して MDR バンドルに記録し、Mac へストリーミング送出する。

仕様: [`docs/pipeline.md`](../docs/pipeline.md) §2〜§4

## 責務

- ARSession 設定（`worldAlignment = .gravity`、`sceneReconstruction = .meshWithClassification`）
- キーフレーム選別（トラッキング状態 / 並進5cm・回転5° / Laplacian 分散 / depth confidence）
- MDR バンドル書き出し（[`spec/`](../spec/) 参照）
- Bonjour `_madoriba._tcp` でのストリーミング転送＋ローカルスプールへのフォールバック
- ARMeshAnchor 統合による Tier 1 ライブメッシュ

## 原則

- **ARKit の生値をそのまま保存する。** 座標変換は一切しない（recon 側に一元化）
- **画像を回転させない。** `capturedImage` のセンサ native 向きのまま通す
- 解像度上限は **1920×1440**（A12Z は ARKit 4K 非対応）

## Phase 1 冒頭で実機確認すること

- [ ] `supportedVideoFormats` の列挙（1920×1440 @30fps があるか）
- [ ] `recommendedVideoFormatForHighResolutionFrameCapturing` が nil を返さないか（A12Z で不明）
- [ ] 3 分連続撮影時の熱スロットリング挙動
