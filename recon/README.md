# recon — madoriba-recon（macOS 復元パイプライン）

MDR バンドルを受け取り、前処理して 3DGS を学習し、SPZ / GLB / 間取りを出力する。

仕様: [`docs/pipeline.md`](../docs/pipeline.md) §5〜§7

## 責務

- MDR 受信（Bonjour リスナ）と、フレーム到着ごとの逐次前処理
- 座標変換 ARKit → COLMAP（`c2w @ diag(1,-1,-1,1)` して逆行列）
- depth の intrinsics スケールと confidence マスク
- LiDAR 点群の生成（unproject → voxel downsample 2cm → 外れ値除去）
- exif からの露出正規化
- COLMAP text model の書き出し
- 3DGS 学習（7K プレビュー → 30K 最終）
- SPZ / GLB 出力

## 実装方針

| 用途 | 実装 |
|---|---|
| 検証・研究 | gsplat-mlx（上流 gsplat と API 互換） |
| 本番組み込み | Brush（Rust、COLMAP/Nerfstudio 形式を入力に取る） |

**本番採用は Phase 0 のベンチ実測後に確定する。**
前段は COLMAP text model を吐く設計にしてあるので、学習実装は差し替え可能。
