# MDR v1 — madoriba recording bundle

`schema_version: "mdr-1"`

**撮影アプリ（iOS）と Mac 側（CaptureVisualizer）の唯一の契約。** ここを変更すると両側が作り直しになる。
破壊的変更は `schema_version` を上げて検知できるようにする。

---

## 設計原則

1. **ARKit の生値をそのまま保存する。** 座標変換・単位変換・向きの正規化を capture 側で一切行わない。
   変換は Mac 側に一元化する。capture 側で変換すると、バグが見つかったときに再撮影が必要になる。
2. **画像を回転させない。** `capturedImage` はデバイスの向きに関係なく常にセンサ native（横）で、
   `intrinsics` もその向きに対応する。native のまま最後まで通す。
3. **intrinsics はフレームごとに保存する。** ARKit は OIS・手ぶれ補正・内部デジタルクロップに追随して
   毎フレーム再計算する。セッション共通の固定値として扱うと再投影誤差になる。

---

## ディレクトリ構造

```
room-<uuid>.mdr/
├── manifest.json         # セッションメタデータ
├── poses.jsonl           # 1 行 1 フレーム
├── frames/
│   ├── 000000.jpg        # RGB
│   ├── 000000.depth.zz   # 深度
│   ├── 000000.conf.zz    # 信頼度
│   ├── 000001.jpg
│   └── ...
└── mesh.ply              # ARMeshAnchor 統合メッシュ（任意）
```

### 圧縮形式について

`.zz` は **raw DEFLATE**（RFC 1951、zlib ヘッダなし）。

zstd を使わないのは、**Apple の Compression フレームワークが zstd を持たない**ため
（LZFSE / LZ4 / ZLIB / LZMA のみ）。raw DEFLATE なら iOS 側は `COMPRESSION_ZLIB` で、
Python 側は標準ライブラリ `zlib.decompress(data, wbits=-15)` で扱え、
**双方とも外部依存ゼロ**で済む。

フレーム番号は 6 桁ゼロ埋めの連番。`poses.jsonl` の `i` と一致する。

---

## manifest.json

```json
{
  "schema_version": "mdr-1",
  "session_id": "9F3A1C42-...",
  "created_at": "2026-08-23T06:12:44Z",
  "device": {
    "model": "iPad8,11",
    "os": "iPadOS 26.0",
    "has_lidar": true
  },
  "video": {
    "width": 1920,
    "height": 1440,
    "fps": 30
  },
  "depth": {
    "width": 256,
    "height": 192,
    "format": "float16",
    "unit": "meter"
  },
  "world_alignment": "gravity",
  "gravity": [0.0, -1.0, 0.0],
  "frame_count": 412,
  "duration_sec": 92.4
}
```

| フィールド | 意味 |
|---|---|
| `device.model` | `utsname.machine`（例 `iPad8,11`）。実機の素性を残す |
| `video` | `ARConfiguration.VideoFormat` の実値。**想定を書かず実測を書く** |
| `depth` | `sceneDepth.depthMap` の実解像度と形式 |
| `world_alignment` | 現在は常に `"gravity"`。`"gravityAndHeading"` は真北に揃い（**+X が東 / +Z が南**）間取り図に方位を描けるが、実測で磁気コンパスの精度が 28.8° / 27.3° と屋内では使用に耐えず撤回した（`heading` キーも同時に撤回）。読み手は両方の値を想定すること |
| `gravity` | ARKit world 座標系での重力方向。`.gravity` 整合なら概ね `[0,-1,0]` |

---

## poses.jsonl

1 行に 1 フレームの JSON オブジェクト。改行区切り。

```json
{"i":0,"t":123.456,"transform":[1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1],"intrinsics":{"fx":1590.2,"fy":1590.2,"cx":960.1,"cy":720.3},"tracking":"normal","exif":{"exposure":0.0166,"iso":320,"brightness":2.13},"conf_high_ratio":0.62,"sharpness":184.2}
```

| フィールド | 型 | 意味 |
|---|---|---|
| `i` | int | フレーム番号。`frames/%06d.*` と対応 |
| `t` | float | `ARFrame.timestamp`（秒） |
| `transform` | float[16] | `ARFrame.camera.transform`。**camera→world**、**列優先（column-major）**。ARKit / simd の並びそのまま |
| `intrinsics` | object | `ARFrame.camera.intrinsics` を `fx` `fy` `cx` `cy` に分解したもの。`video.width/height` 基準 |
| `tracking` | string | `normal` \| `limited` \| `notAvailable` |
| `exif.exposure` | float | ExposureTime（秒） |
| `exif.iso` | float | ISOSpeedRatings |
| `exif.brightness` | float | BrightnessValue |
| `conf_high_ratio` | float | `confidenceMap` が `.high` の画素比（0〜1） |
| `sharpness` | float | Laplacian 分散。キーフレーム選別の記録 |

> **なぜ `intrinsics` を配列にしないか。** 3×3 を float[9] で持つと行優先／列優先の取り違えが起きる。
> 対称に近い行列なので**転置しても計算が通ってしまい**、症状が「なんとなくズレる」になって
> 発見が遅れる。`fx/fy/cx/cy` の名前付きにすればこの曖昧さは原理的に消える。
>
> ⚠️ 一方 `transform` は 4×4 で自然な分解がないため配列のまま。**列優先**（simd `float4x4` の
> メモリ並びそのもの）と決める。Mac 側の読み込みは `reshape(4,4).T` になる。ここはテストで守る。

`tracking != "normal"` のフレームは**そもそも記録しない**（キーフレーム選別で落とす）が、
念のためフィールドとして残す。

---

## frames/NNNNNN.jpg

- `ARFrame.capturedImage`（`kCVPixelFormatType_420YpCbCr8BiPlanarFullRange`）を BGRA 経由で JPEG 化
- 解像度は `manifest.video` と一致（1920×1440）
- 品質 92
- **センサ native の向きのまま。回転・EXIF Orientation の付与をしない**

## frames/NNNNNN.depth.zz

- `ARFrame.sceneDepth.depthMap`（`kCVPixelFormatType_DepthFloat32`、256×192）
- Float32 → **float16 に変換**して raw バイト列にし、raw DEFLATE 圧縮
- 行優先、パディングなし。サイズは `256*192*2 = 98,304` バイト（圧縮前）
- 単位はメートル。値はカメラからの**深度**（Z 距離）であって光線距離ではない

float16 で足りる理由: LiDAR の実用レンジは 5m までで、float16 の 5m 付近の刻みは約 2.4mm。
LiDAR 自体の精度がこれより粗いので情報を失わない。容量は半減する。

## frames/NNNNNN.conf.zz

- `ARFrame.sceneDepth.confidenceMap`（`kCVPixelFormatType_OneComponent8`、256×192）
- `ARConfidenceLevel` の raw 値をそのまま。`0 = low` / `1 = medium` / `2 = high`
- raw バイト列を raw DEFLATE 圧縮。サイズは `256*192 = 49,152` バイト（圧縮前）

> ⚠️ 値域は実機で必ず確認する（`DeviceProbe`）。仕様上は 0〜2 だが、
> 実装によっては 1〜3 として観測されるという報告がある。ズレていたらこの仕様書を先に直す。

## mesh.ply

`ARMeshAnchor` を統合したメッシュ。binary PLY。
頂点座標は ARKit world 座標系（右手系、X 右 / Y 上 / Z 後、重力整合）。

Tier 1（間取り・寸法・dollhouse）用。3DGS の学習には使わない。

---

## 深度と RGB の対応

深度マップは RGB と**同一の FOV**（センタークロップではない）。
したがって Mac 側では intrinsics を単純スケールすれば対応が取れる:

```
fx_d = fx * 256/1920    cx_d = cx * 256/1920
fy_d = fy * 192/1440    cy_d = cy * 192/1440
```

---

## 容量の目安

| | 1 フレーム | 400 フレーム |
|---|---|---|
| JPEG | ~450 KB | ~180 MB |
| depth (.zz) | ~40 KB | ~16 MB |
| conf (.zz) | ~2 KB | ~0.8 MB |
| poses.jsonl | ~400 B | ~160 KB |
| **計** | **~500 KB** | **~200 MB** |

---

## 変更履歴

- **mdr-1** (2026-08-23) — 初版。`docs/pipeline.md` §3 を具体化。
  ポーズの格納を固定長バイナリ（`poses.bin`）から JSONL に変更した。
  400 フレームで 160KB と容量が無視できる一方、デバッグ時に目視・grep できる利点が勝るため。
