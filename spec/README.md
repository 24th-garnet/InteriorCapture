# spec — MDR バンドル仕様

**撮影アプリと Mac 側（CaptureVisualizer）の唯一の契約。** ここが動くと両側が作り直しになる。

| | |
|---|---|
| [`mdr-v1.md`](mdr-v1.md) | 仕様本体。**これが正** |
| [`mdr-v1.schema.json`](mdr-v1.schema.json) | `manifest.json` と `poses.jsonl` の JSON Schema |

## 凍結済みの決定事項

1. **MDR v1 の構造** — `mdr-v1.md`。破壊的変更は `schema_version` を上げる
2. **ARKit の生値をそのまま保存する** — 座標変換は Mac 側の `coords.py` に一元化。
   capture 側で変換すると、バグが見つかったときに再撮影が必要になる
3. **画像は native 向きのまま扱う** — `capturedImage` と `intrinsics` の向きが対応しているため
4. **`intrinsics` は名前付き（fx/fy/cx/cy）** — float[9] だと行優先/列優先を取り違えても
   計算が通ってしまい、症状が「なんとなくズレる」になって発見が遅れる
5. **`transform` は列優先** — simd `float4x4` のメモリ並びそのまま。Mac 側は `reshape(4,4).T`

残る未凍結: 3DGS 実装の本番採用（Phase 0 のベンチ実測後）。

## 概算

1 フレーム ~500 KB（JPEG 450 KB + depth 40 KB + conf 2 KB + ポーズ等）
1 部屋 300〜500 フレーム = **~200 MB**
