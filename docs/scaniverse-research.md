# Scaniverse 調査メモ（内装スキャン重点）

調査日: 2026-08-21 / 出典は末尾

## 1. 製品の位置づけ

- 開発: Keith Ito の Toolbox AI → 2021 Niantic 買収 → 現在は **Niantic Spatial, Inc.** 傘下。
- iOS / Android 無料。オンデバイス処理が基本（クラウド不要・アップロード不要）。
- 2025〜2026 で「モバイル 3D スキャナ」から「空間データ取り込みサービス」へ軸足移動。
  法人向け Scaniverse for Business（2026/04）+ VPS 2.0、Plus $20/月 / Pro $50/月（クラウド処理・360度カメラ対応）。
  **個人向けの端末内スキャン（splat 無制限生成含む）は無料のまま。**

## 2. デバイス要件（mimic の下限設計に直結）

| | 要件 |
|---|---|
| iOS | iPhone 11 以降（XR/XS/XS Max/SE2・SE3 含む）、iPad は A12 以降。**splat の撮影・投稿は iPhone 12 以降のみ** |
| Android | Android 7.0+ / RAM 4GB 以上 / **ARCore Depth API 対応必須**。非対応機は splat の閲覧のみ |
| LiDAR | iPhone 12 Pro 以降・iPad Pro。**必須ではない**（非 LiDAR 機は A12 以降で photogrammetry / 深度推定にフォールバック） |

非 LiDAR 経路は連続画像から深度を推定する **ManyDepth 系**の手法（Niantic 自社研究）。

## 3. スキャンモード（ここが mimic の中核）

### 撮影モード
- **Splat（3D Gaussian Splatting）** — v3.0.0 (2024/03) で追加。端末内で学習。反射・半透明・複雑な表面に強い。編集は不可（mesh に再処理すれば可）。
- **Mesh** — 従来のポリゴン。編集・計測・各種エクスポートが可能。

### 撮影開始時のサイズ選択
`Small Object` / `Medium Object` / `Large Object` / `Area`
→ **内装（部屋・空間）は `Area`**。LiDAR レンジは**最大 5m**、レンジスライダーで調整可（v1.4.0 で可変化）。

### 処理（Processing）モード
| モード | 用途 | 備考 |
|---|---|---|
| **Speed**（旧 Standard） | 高速プレビュー | v1.7.0 で改称 |
| **Area**（旧 Ultra） | **部屋・広い空間向け・LiDAR 最高品質** | Ultra 時 3mm 再構成解像度 |
| **Detail** | 小物・人物・製品（photogrammetry ベース） | v1.7.0 追加 |

内装スキャンの標準経路は **Area サイズ → Area 処理**。

## 4. 内装スキャンの撮影手順（公式 Scan Techniques）

### 基本原則
- **常に動き続ける**。ゆっくりでもよいが停止しない。急な動きは禁止。
- 直前に撮った特徴が常にフレーム内に残るようにする（フレーム間の接続性を担保）。
- 「長くて穴だらけのスキャン」より「短くてカバレッジの強いスキャン」が良い。

### 1部屋のオーバービュー・スキャン
1. 部屋の**外周に立ち、内側にカメラを向けながら外周を歩く**。
2. 角度を変えて**3周（パス）**する:
   - 水平 → 壁・家具などの中間高さ
   - 上向き → **天井**
   - 下向き → **床**
3. 横方向（左右）に体を振る／高さ・チルト・被写体距離を変えて多視点を稼ぐ。
4. 広い部屋は overview スキャンを複数回に分割。

### 複数部屋・複数フロア
- **ドア・廊下が「構造的コネクタ」**。ここを丁寧に、ゆっくり通過して撮る。
- 各部屋のスキャンが隣室の可視特徴とオーバーラップしていること。
- 階を跨ぐときは高さ変化をゆっくり、階段を欠かさず撮る。

### 時間
- 公式サポート: **1スキャン 1〜3 分がベスト**。それ以上は逆に品質が落ちる。
- 公式 docs: **1スキャンの上限は 5 分**。
- splat は **180 秒超で処理失敗リスクの警告**が出る（近年の更新で追加）。
- 実測レビュー: 部屋 1 室のスキャンは 2 分未満で完了。

### 苦手な対象
鏡・ガラス・反射面 / 繰り返し模様 / 無特徴な面（白い壁など）。避けられない場合は**画面中央に置かない**。
照明は明るく均一が最良。屋外は曇天が影を減らせて有利。

## 5. 失敗モードと対処（公式 Troubleshoot）— mimic の UX 警告設計に流用可

| 症状 | 原因 | 対処 |
|---|---|---|
| メッシュがスカスカ | オーバーラップ不足・視点変化不足 | 高さと左右の振りを増やす、多視点で撮る |
| ローカライズ失敗 | 特徴の乏しい場所からスキャン開始 | 既撮影の・幾何が強い場所から始める |
| 部屋どうしが繋がらない | ドア・廊下のオーバーラップ不足 | 遷移をゆっくり、共有特徴を可視に保つ |
| ドリフト | ランドマークの少ない開放空間 | 安定した参照物を入れる、複数パス |
| 天井・床が欠ける | 垂直方向が撮り足りない | 上向き／下向きパスを必ず行う |
| 撮りすぎ | 新しい視点なしに同じパスを反復 | 時間より視点の多様性。狙い撃ちの短スキャンを追加 |

日本語コミュニティの実務 Tips: 端末ケースを外す（発熱対策）／レンズ清掃／被写体距離 3m 以内／**通常歩行の 1/3 程度の速度**／同じ場所を二度撮りするとメッシュが二重化しやすい／処理直後に必ず結果を検証。

## 6. 撮影中の UI フィードバック

- **ライブ・メッシング表示**（撮れているかその場で分かる）。メッシュが patchy・ぶれる＝品質不足のサイン。
- **未取得領域の「赤」表示** — 赤が消えるまで撮る、が実質的な完了条件。
  ただしレビュー曰く「赤が消えた＝十分な点が取れた、とは限らない」。
- Overlay 表示の ON/OFF トグルあり（黒ドット等の可視化を消せる）。

## 7. 編集・計測・書き出し

- **編集**: クロップ（パン／ズーム対応）、回転、露出・コントラスト・シャープネスの非破壊調整。
- **計測**: v1.4.2 で距離計測ツール追加、計測入り画像の共有可。
- **エクスポート**
  - Mesh: `OBJ` / `FBX` / `GLB` / `USDZ` / `STL`
  - 点群: `PLY` / `LAS`（位置情報を保存していればジオリファレンス付き）
  - 3DGS: `PLY` / `SPZ`
- 共有: 限定リンク、SNS 用動画（MP4、v4.0.5 以降ウォーターマーク付与）、Web 埋め込み、グローバルマップ投稿、Sketchfab。
- 既存 mesh スキャンは `…` → Reprocess Scan → Splat で splat 化できる。

## 8. SPZ フォーマット

- Niantic が **MIT ライセンスで OSS 化**（2024末）。「3D Gaussian splat の JPG」。
- 列指向レイアウト（position は position 同士…）＋固定小数点量子化 → gzip。
- **PLY 比で約 1/10**（250MB PLY → 約 25MB）。SPZ 4 で更に軽量化。
- 実装: C++ / Python / WebAssembly(TS)。`github.com/nianticlabs/spz`

## 9. mimic 実装で押さえるべき技術対応表

| Scaniverse の機能 | iOS 側の実装候補 |
|---|---|
| LiDAR メッシュ生成 | ARKit `ARWorldTrackingConfiguration.sceneReconstruction = .meshWithClassification` → `ARMeshAnchor`（近いものほど細かくテッセレート、床/壁/天井/窓/座面を分類） |
| 深度取得 | `ARFrame.sceneDepth`（LiDAR）/ `smoothedSceneDepth` |
| 非 LiDAR 経路 | photogrammetry、または単眼深度推定（ManyDepth 相当） |
| 5m レンジ制限 | 深度値のクリップ＋TSDF ボリュームの切り詰め |
| ライブ・メッシング表示 | RealityKit / Metal で `ARMeshAnchor` ジオメトリを毎フレーム描画 |
| 未取得領域の赤表示 | ボクセル／セルごとのカバレッジ集計を色で可視化 |
| **間取り（madoriba 本題）** | **RoomPlan**: `RoomCaptureView`／`RoomCaptureSession` → `CapturedRoom`（壁・ドア・窓・開口・家具を ML 検出）。`StructureBuilder` で複数 `CapturedRoom` を `CapturedStructure` に統合（MultiRoom API, WWDC23）。USDZ 書き出し |
| Android | ARCore Depth API（Raw/Full Depth） |

**設計上の要点**: Scaniverse は「見た目の 3D キャプチャ」に強く、**構造化された間取り（壁・開口の抽出、CAD 連携）は弱い**というのが 2026 時点の一般評価。madoriba が間取り生成を狙うなら、
**Scaniverse 型の撮影 UX（外周歩行 + 3パス + 赤い未取得領域 + Area 処理）× RoomPlan 型の構造抽出**、というハイブリッドが素直。

## 10. 精度の現実

- 部屋規模の点群は「間取り作成・寸法計測には十分な精度」（実測レビュー）。ただし**スキャンが大きくなるほど精度は落ちる**。
- ミリ単位が要る測量業務には不適。日本の国交省ガイドライン準拠でもなく、認証済み座標も持たない。

## 出典

- [Scan Techniques for Scaniverse — Niantic Spatial](https://www.nianticspatial.com/docs/scaniverse/techniques/)
- [Troubleshooting Scaniverse Scans — Niantic Spatial](https://www.nianticspatial.com/docs/scaniverse/troubleshoot/)
- [Scaniverse Release Notes](https://www.nianticspatial.com/en/capture/scaniverse-release-notes)
- [How to use Scaniverse 3D Scanner for iOS and Android](https://dev.scaniverse.com/support)
- [Mapping the World For Machines with Scaniverse](https://www.nianticspatial.com/en/blog/scaniverse)
- [Open-sourcing .SPZ](https://dev.scaniverse.com/news/spz-gaussian-splat-open-source-file-format) / [nianticlabs/spz](https://github.com/nianticlabs/spz) / [SPZ 4](https://www.nianticspatial.com/blog/spz4)
- [Scaniverse Review — Structural Basics](https://www.structuralbasics.com/scaniverse-review/)
- [Scaniverse — radiancefields.com](https://radiancefields.com/platforms/scaniverse)
- [【非公式】Scaniverseの使い方全てまとめました — note/iwama](https://note.com/iwamah1/n/nc8a5427157ef)
- [Scaniverseを解説〜土木・建設の測量実務でも使えるの？ — デジコン](https://digital-construction.jp/column/630)
- [Scaniverse法人向け拡張版 / VPS 2.0 — ゲームメーカーズ](https://gamemakers.jp/article/2026_04_08_135220/)
- [Introducing RoomPlan — Apple Developer](https://developer.apple.com/augmented-reality/roomplan) / [Explore enhancements to RoomPlan (WWDC23)](https://developer.apple.com/videos/play/wwdc2023/10192/)
- [Polycam vs Scaniverse 2026](https://www.skyebrowse.com/news/posts/polycam-vs-scaniverse) / [Best 3D Room Scanner Apps 2026](https://www.skyebrowse.com/news/posts/3d-room-scanner)
