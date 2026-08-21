# spec — MDR バンドル仕様

**capture と recon の唯一の契約。** ここが動くと両側が作り直しになるため、実装着手前に凍結する。

現行の記述: [`docs/pipeline.md`](../docs/pipeline.md) §3

## 凍結すべき決定事項（`docs/pipeline.md` §11）

1. MDR バンドル仕様
2. 座標系の変換規約 — ARKit の生値を保存し、変換は recon 側に一元化
3. 画像は native 向きのまま扱う
4. 3DGS 実装の本番採用（Phase 0 の実測後）

## 予定

`docs/pipeline.md` §3 の記述を、機械可読な `mdr-v1.json`（JSON Schema）として固める。
`manifest.json` の `schema_version` で破壊的変更を検知できるようにする。

## 概算

1 フレーム ~500 KB（JPEG 450 KB + depth 40 KB + conf 2 KB + ポーズ等）
1 部屋 300〜500 フレーム = **~200 MB**
