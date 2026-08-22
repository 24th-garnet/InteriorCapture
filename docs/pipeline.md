# madoriba / scaniverse_mimic 開発パイプライン仕様

策定日: 2026-08-21
対象ハード: iPad Pro 2020（A12Z, LiDAR）＝撮影機 / MacBook Pro M1 Max ＝復元エンジン
前提調査: `docs/scaniverse-research.md`

---

## 0. 設計の核心

内装 3DGS は本来「最悪の被写体」（白壁・無地・鏡・ガラス）だが、**LiDAR + ARKit を持つと最良のケースに反転する**。理由は 3 つ:

1. **SfM を丸ごと排除できる** — ARKit がポーズと intrinsics を確定値で返す。COLMAP は 1 部屋で 10〜40 分かかり、しかも無地の壁で失敗しやすい。ここが最大の高速化。
2. **初期点群が密でメートル正解** — 疎な SfM 点（数千〜数万）ではなく LiDAR 由来の 50〜200 万点で初期化 → densification 回数が減り収束が速い。
3. **depth supervision が効く** — 「テクスチャのない壁が崩れる」という内装 3DGS 最大の失敗モードを直接叩ける。

したがってパイプライン全体は **「ARKit の出力をいかに欠損なく Mac へ運ぶか」** に最適化する。

### 二段出力（体感速度の設計）

| | 出力 | 待ち時間 | 用途 |
|---|---|---|---|
| **Tier 1** | ARKit ライブメッシュ + 間取り | **0 秒**（撮影完了と同時） | 寸法・dollhouse・撮影中の赤い未取得表示 |
| **Tier 2a** | 3DGS 7K iter プレビュー | 2〜3 分 | ツアーの即時確認 |
| **Tier 2b** | 3DGS 30K iter 最終 | 15〜20 分（裏で継続） | 納品品質 |

Tier 2a を出した直後にビューアを開けるようにし、2b は裏で差し替える。これが「可能な限り高速」の実装上の答え。

---

## 1. コンポーネント構成

```
┌─ A. madoriba-capture (iPadOS / Swift) ─┐      ┌─ B. madoriba-recon (macOS) ─────────┐
│  ARSession                             │      │  S4 前処理（撮影と並行して逐次）      │
│   ├ S1 キーフレーム選別                 │ MDR  │   ├ 座標変換 ARKit→COLMAP           │
│   ├ S2 フレーム記録                     │ ───► │   ├ depth unproject → 初期点群       │
│   ├ S3 ストリーミング送出               │ TCP  │   └ 露出正規化                       │
│   └ ARMeshAnchor 統合 (Tier 1)          │      │  S5 3DGS 学習 (Metal)               │
│  RoomCaptureSession (RoomPlan, 別途)    │      │  S6 出力 SPZ / GLB / 間取り          │
└────────────────────────────────────────┘      └─────────────────────────────────────┘
                                                                │
                                                 ┌─ C. madoriba-tour (Viewer) ─────────┐
                                                 │  station point 制約ナビ + splat 描画  │
                                                 └─────────────────────────────────────┘
```

A と B の間の契約が **MDR バンドル仕様**（§3）。ここを先に凍結する。

---

## 2. S0: ARSession 設定（iPad）

```swift
let config = ARWorldTrackingConfiguration()
config.sceneReconstruction  = .meshWithClassification   // A12Z 可
config.frameSemantics       = [.sceneDepth]             // raw のみ。smoothed は併用しない
config.worldAlignment       = .gravity                  // ★重要
config.environmentTexturing = .none                     // 不要・負荷削減
config.planeDetection       = []                        // RoomPlan は別セッションで
config.videoFormat          = pickFormat()              // §2.2
```

### 2.1 `worldAlignment = .gravity` が必須の理由
Y 軸が重力に一致する → 床・壁が軸整合 → 間取り抽出も splat の上下も正しく出る。
`.gravityAndHeading` は磁気コンパス依存で**室内では不安定**なので使わない。

### 2.2 解像度の上限は 1920×1440（確定制約）
ARKit 6 の 4K ビデオは **iPhone 11+ または M1 iPad Pro 以降**が条件で、**A12Z は対象外**。
したがって連続フレームの上限は 4:3 の 1920×1440。これが画質の天井になる。

- `supportedVideoFormats` を実機で列挙し、1920×1440 @30fps を選ぶ。**60fps は使わない**（A12Z の熱予算を食うだけで、キーフレーム選別後の枚数は変わらない）
- `captureHighResolutionFrame`（12MP 静止画）は `recommendedVideoFormatForHighResolutionFrameCapturing` が **A12Z で nil を返す可能性がある**。Phase 1 の最初に実機確認。使えるなら station point でのみ高解像度ショットを撮り、splat の教師に混ぜる

### 2.3 画像の向きは一切回さない
`capturedImage` は**デバイスの向きに関係なく常にセンサ native（横）**で来て、`intrinsics` もその向きに対応する。
→ **native 向きのまま最後まで通す。回転処理を挟まない。** 座標系バグの最大の発生源を回避できる。

---

## 3. S1〜S2: キーフレーム選別と記録（MDR バンドル仕様）

### 3.1 なぜ全フレームを保存しないか
30fps 全保存は容量の無駄なだけでなく**有害**。同一視点の重複フレームは 3DGS の densification を歪め、floater を増やす。

### 3.2 採用条件（AND）

| # | 条件 | 意図 |
|---|---|---|
| 1 | `camera.trackingState == .normal` | `.limited` のポーズは信用しない |
| 2 | 前回採用から **並進 ≥ 5 cm** または **回転 ≥ 5°** | 視点の多様性を確保 |
| 3 | Laplacian 分散 ≥ 直近 30 枚の中央値 × 0.6 | **モーションブラー除去**（室内の最大の敵） |
| 4 | depth confidence `.high` の画素比 ≥ 30% | 初期点群の質を担保 |

条件 3 は Y プレーンを 1/4 に縮小してから計算（vImage）。CPU 負荷を抑える。

**目標: 実効 3〜6 fps、1 部屋 90 秒で 300〜500 枚。** Scaniverse の「1〜3 分」ガイドラインと整合する。

### 3.3 フレームごとの記録内容

| 項目 | 型・形式 | 実サイズ |
|---|---|---|
| RGB | JPEG q=92, 1920×1440（VideoToolbox の HW エンコーダ） | ~450 KB |
| `camera.transform` | float32[16] camera→world（ARKit 規約のまま保存） | 64 B |
| `camera.intrinsics` | float32[9]（1920×1440 基準） | 36 B |
| depth | `sceneDepth.depthMap` 256×192 Float32 → float16 + raw DEFLATE | ~40 KB |
| confidence | 256×192 UInt8 (0/1/2) + raw DEFLATE | ~2 KB |
| exif | ExposureTime / ISOSpeedRatings / BrightnessValue（iOS 16+ の `ARFrame.exifData`） | 12 B |
| timestamp | float64 | 8 B |
| trackingState | u8 | 1 B |

→ **約 500 KB/frame、400 枚で ~200 MB/部屋**

**変換はしない。ARKit の生の値をそのまま保存する。** 座標変換は Mac 側（S4）に集約する — iPad 側で変換すると、バグったときに再撮影が必要になる。

### 3.4 セッション全体

- `ARMeshAnchor` 統合メッシュ（頂点・法線・面・`ARMeshClassification`）→ PLY
- 重力ベクトル、開始時刻、デバイス識別、ARKit バージョン、選んだ videoFormat
- `ARWorldMap`（任意、セッション再開・追い撮り用）

### 3.5 ディレクトリレイアウト

```
room-<uuid>.mdr/
├── manifest.json         # セッションメタ・スキーマ版
├── poses.jsonl           # 1 行 1 フレーム（ポーズ + intrinsics + exif）
├── frames/
│   ├── 000000.jpg
│   ├── 000000.depth.zz   # float16 256x192 + raw DEFLATE
│   ├── 000000.conf.zz
│   └── ...
└── mesh.ply              # ARMeshAnchor 統合（Tier 1）
```

**確定した仕様は [`spec/mdr-v1.md`](../spec/mdr-v1.md) にある。以降はそちらが正。**

実装時に当初案から変えた点が 2 つある。

- **ポーズを `poses.bin`（固定長バイナリ）ではなく JSONL にした。** 400 フレームで 160KB と
  容量が無視でき、デバッグ時に目視・grep できる利点が勝る。
- **圧縮を zstd ではなく raw DEFLATE にした。** Apple の Compression フレームワークは
  zstd を持たない（LZFSE / LZ4 / ZLIB / LZMA のみ）。raw DEFLATE なら iOS は
  `COMPRESSION_ZLIB`、Python は標準ライブラリ `zlib` で、双方とも外部依存ゼロで済む。

`manifest.json` に `schema_version` を必ず入れる。ここが A/B 間の唯一の契約なので、破壊的変更を検知できるようにする。

---

## 4. S3: ストリーミング転送（撮影と並行）

「可能な限り高速」の実装上の肝。**撮影終了 = 全データ Mac 到達済み**を作る。

- **Bonjour `_madoriba._tcp` + Network.framework (NWListener / NWBrowser / NWConnection)**
- キーフレーム確定のたびに逐次送出。500 KB × 5 fps = **2.5 MB/s**。Wi-Fi 5 で余裕、AWDL ならさらに余裕
- **バックプレッシャ**: 送信キューが閾値（例 20 フレーム）を超えたらローカルディスクにスプールし後追い送信。**撮影は絶対に止めない**
- **フォールバック**: Mac 不在／切断時は全部ローカル保存 → 後で一括転送。UI 上は等価に見せる
- 転送単位はフレーム 1 件を 1 メッセージ（長さプレフィックス + manifest 断片 + ペイロード）。再送・欠番検知ができるよう連番を持たせる

---

## 5. S4: 前処理（Mac、撮影と並行して逐次）

フレーム到着ごとに実行。**撮影終了時点でほぼ完了している**状態を目指す。

### 5.1 座標変換 ARKit → COLMAP/OpenCV

もっともバグりやすい箇所なので明示する。

- **ARKit**: 右手系、X 右 / Y 上 / **Z 後ろ**（カメラは −Z を向く）。`camera.transform` は **camera→world**（ポーズ）
- **COLMAP / OpenCV**: 右手系、X 右 / Y 下 / **Z 前**（RIGHT_DOWN_FRONT）。`images.txt` は **world→camera**

```python
import numpy as np
FLIP = np.diag([1.0, -1.0, -1.0, 1.0])   # Y と Z を反転

def arkit_to_colmap(transform_arkit: np.ndarray):
    """transform_arkit: 4x4 camera->world (ARKit). returns (qvec, tvec) world->camera."""
    c2w = transform_arkit @ FLIP          # ARKit cam 軸 -> OpenCV cam 軸
    w2c = np.linalg.inv(c2w)
    R, t = w2c[:3, :3], w2c[:3, 3]
    return rotmat_to_qvec(R), t
```

`intrinsics` は 3×3 の `[[fx,0,cx],[0,fy,cy],[0,0,1]]` がそのまま OpenCV 規約なので変換不要。
COLMAP のカメラモデルは **PINHOLE**（ARKit は歪み補正済みの画像を返すので OPENCV モデルは不要）。

### 5.2 depth の整列

depth 256×192 は RGB と**同一 FOV**（センタークロップではない）。よって intrinsics を単純スケール:

```
fx_d = fx * 256/1920,  cx_d = cx * 256/1920
fy_d = fy * 192/1440,  cy_d = cy * 192/1440
```

confidence < `.high` の画素は**マスクして捨てる**。ここをケチると初期点群にノイズが乗り、floater の温床になる。

### 5.3 初期点群の生成

1. 各キーフレームの high-confidence depth を world 座標へ unproject
2. RGB から色をサンプル（depth 画素中心を RGB へ投影）
3. **voxel downsample 2 cm** で統合
4. 統計的外れ値除去（k=20, σ=2.0）

→ **1 部屋で 50〜200 万点**。これを 3DGS の初期ガウシアンにする。

### 5.4 露出正規化

室内を歩くと ARKit の自動露出が変動し、**明暗の差を 3DGS がカメラ近傍の黒/白 blob（floater）で辻褄合わせしようとする**。これが内装 3DGS の第 2 の失敗モード。

`exifData` の ExposureTime / ISO から相対 EV を計算し、学習時の per-image exposure 補正の初期値として渡す。
（3DGS 公式実装は 2024/10 に exposure compensation・depth 正則化・アンチエイリアシングを取り込み済みなので、研究ではなく既製機能として使える。）

### 5.5 出力

COLMAP モデルを書き出す。→ **既存の 3DGS 実装がそのまま食える形にしておく**
（実装を差し替えても前段を作り直さなくて済む）。

```
scene/
├── images/            # MDR の frames/*.jpg へのシンボリックリンク
└── sparse/0/
    ├── cameras.bin    # PINHOLE、1 フレーム = 1 カメラ
    ├── images.bin
    └── points3D.ply   # LiDAR 初期点群
```

実装で分かった制約:

- **msplat はテキスト形式を受け付けない。** ディスパッチャが `cameras.bin` の存在で
  判定するため、バイナリ必須。
- ただし**点群は `points3D.bin` が無ければ `points3D.ply` にフォールバック**する。
  可変長トラックを持つ `points3D.bin` を書かずに済むので PLY を使う。
- **カメラは 1 フレーム = 1 台**にする。ARKit が intrinsics を毎フレーム再計算するため、
  セッション共通の 1 台にまとめると再投影誤差になる。

---

## 6. S5: 3DGS 学習（M1 Max）

### 6.1 実装の選択

| 用途 | 実装 | 理由 |
|---|---|---|
| **検証・研究** | **gsplat-mlx** | 上流 gsplat と API 互換 → depth loss や 2DGS の研究コードを最小変更で移植できる |
| **本番組み込み** | **Brush**（Rust + wgpu/Burn） | MCMC densification・Mip-Splatting AA を内蔵、CUDA 版 gsplat と同等品質、Mac アプリに組み込みやすい |
| **速度上限の把握** | **msplat**（全 fused Metal shader） | 最速。ただし depth supervision / MCMC が未実装なので自前追加が必要 |

### 6.2 学習設定

- 初期化: §5.3 の LiDAR 点群（ランダムでも SfM でもない）
- Loss: `L1 + SSIM` + **depth loss**（LiDAR depth 教師、confidence マスク）+ **per-image exposure 補正**
- densification: **MCMC**（ガウシアン数を上限固定できる → メモリが予測可能で破綻しない）
- アンチエイリアス: Mip-Splatting
- ガウシアン数上限: **1 部屋 150 万**

### 6.3 二段 iteration

```
7K iter  →  SPZ 書き出し  →  ビューアに即反映（Tier 2a）
   ↓ 継続
30K iter →  SPZ 差し替え（Tier 2b）
```

### 6.4 所要時間の見込み（★要実測）

msplat 実測（M4 Max, Mip-NeRF360）: `room` 7K iter = **74 秒**、`garden` 30K iter = **700 秒**（TITAN RTX の gsplat 2149 秒の約 3 倍速）。

M1 Max は M4 Max の概ね 0.55〜0.6 倍（32 vs 40 コア GPU、400 vs 546 GB/s）:

| | M4 Max 実測 | **M1 Max 推定** |
|---|---|---|
| 7K iter | 74 s | **2〜3 分** |
| 30K iter | ~700 s | **15〜20 分** |

**この推定を実測に置き換えるのが Phase 0。** 数値が大きく外れたら設計判断（iteration 数、ガウシアン上限、部屋分割の粒度）が変わる。

### 6.5 メモリ

150 万ガウシアンの学習で **8〜16 GB**。**M1 Max 32 GB 以上が必須**。16 GB 機なら上限 80 万に落とす。

---

## 7. S6: 出力形式

| 成果物 | 形式 | 用途 |
|---|---|---|
| splat | **SPZ**（MIT, PLY 比 1/10。150 万点で ~40 MB） | ツアー描画本体 |
| mesh | ARMeshAnchor 統合 → 簡略化 → GLB | 衝突判定・床・dollhouse・オクルージョン |
| 間取り | RoomPlan `CapturedRoom` / `CapturedStructure` → SVG / DXF | 2D 平面図 |
| ツアーグラフ | 撮影軌跡から station point を ~1.5 m 間隔で抽出＋隣接グラフ | ナビゲーション |

---

## 8. S7: ツアービューア

**3DGS は撮影軌跡から離れた視点で破綻する。** これは弱点ではなく制約として設計に取り込む。

- 移動は **station point に制約**（Matterport 方式）。station 間はカメラ補間で遷移、各 station では自由に見回し
- → 常に「撮影した視点の近傍」しかレンダリングしない = **3DGS が最も得意な条件だけを使う**
- 描画は splat、衝突・床・dollhouse は mesh
- Apple ネイティブなら MetalSplatter、Web なら SPZ の WASM デコーダ

### 撮影ガイドへの跳ね返り（重要）
Scaniverse 流の「外周 3 パス（水平／上向き＝天井／下向き＝床）」に加えて、
**部屋の中央をツアー導線どおりにゆっくり歩くパスを 1 本足す。**
station point はこのパス上に置く。撮影 UX の設計はビューアの設計と不可分。

---

## 9. 開発フェーズと検証ゲート

| Phase | 内容 | 完了条件（ゲート） |
|---|---|---|
| **0** | **M1 Max で msplat / gsplat-mlx をベンチ** | §6.4 の推定が実測値に置き換わる。**最初の意思決定ゲート** |
| **1** | iPad キャプチャ + MDR ローカル書き出し | 1 部屋分の `.mdr` が生成され、フレーム数・容量が §3 の想定内 |
| **2** | オフライン変換 → COLMAP model → 既存 3DGS で 1 シーン通す | **最初の絵が出る。最重要マイルストーン** |
| **3** | LiDAR 点群初期化 + depth loss + exposure 補正 | 白壁の崩れと近傍 floater が Phase 2 比で明確に改善 |
| **4** | Bonjour ストリーミング転送 | 撮影終了時点で転送完了率 100%、撮影中のフレームドロップなし |
| **5** | 7K プレビュー → 30K 継続の二段出力 | 撮影終了から**初回描画まで 5 分以内** |
| **6** | RoomPlan 統合・間取り出力 | 複数部屋が `CapturedStructure` で統合され SVG が出る |
| **7** | ツアービューア（station 制約ナビ） | 3LDK を通しでウォークスルーできる |

Phase 2 は「エンドツーエンドで初めて絵が出る」地点。**ここまで最短距離で到達することを最優先**にし、品質改善（Phase 3 以降）は後回しにする。

---

## 10. リスクと対策

| リスク | 影響 | 対策 |
|---|---|---|
| **A12Z の熱スロットリング** | 撮影が長引くと fps 低下・トラッキング劣化 | HW JPEG（VideoToolbox）を使う / 30fps 固定 / ケースを外す / **1 スキャン 3 分で強制終了**（Scaniverse の 5 分上限より保守的に） |
| **1920×1440 が解像度上限** | ツアー画質の天井 | 確定制約として受容。`captureHighResolutionFrame` が使えれば station point でのみ 12MP を混ぜる |
| **`captureHighResolutionFrame` が A12Z で nil** | 上記が使えない | Phase 1 冒頭で実機確認。ダメなら諦める（致命的ではない） |
| **モーションブラー** | splat がぼける | Laplacian 分散でキーフレーム選別（§3.2-3）。明るい環境で撮る |
| **自動露出変動 → floater** | 近傍に黒/白 blob | exposure compensation（§5.4） |
| **白壁・鏡・ガラス** | 幾何が崩れる | depth loss（§6.2）。鏡・ガラスは画面中央を避ける撮影ガイドで緩和 |
| **iPad Pro 2020 のカメラ性能** | **最大の品質ボトルネック** | パイプライン自体は成立する。写実性が絶対要件になったら撮影機を iPhone 15/16 Pro に差し替える（on-device splat も解禁される）。**A12Z での on-device 3DGS は最初から狙わない** — Niantic 自身が Scaniverse で iPad Pro 2020 を splat 非対応にしている |
| **iPadOS のサポート切れ** | 将来の開発継続性 | iPadOS 27 でも iPad Pro 2020 はサポート継続（切られたのは 2018 モデル）。当面は問題なし |

---

## 11. 凍結すべき決定事項（先に決める順）

1. **MDR バンドル仕様（§3）** — A/B 間の唯一の契約。ここが動くと両側が作り直しになる
2. **座標系の変換規約（§5.1）** — ARKit の生値を保存し、変換は Mac 側に一元化
3. **画像は native 向きのまま扱う（§2.3）**
4. **3DGS 実装の本番採用（Phase 0 の実測後に確定）**
