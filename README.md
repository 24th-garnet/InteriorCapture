# InteriorCapture

LiDAR 搭載の iPhone / iPad で**内装をスキャン**し、`.mdr` バンドルとして取り出す仕組み。
Scaniverse 相当の体験を、端末だけで完結させることを目指している。

このリポジトリが持つのは **`.mdr` の仕様と設計の記録だけ**。動くコードは別リポジトリにある。

| | リポジトリ | 公開 |
|---|---|---|
| **撮る**（madoriba capture — iPhone / iPad 撮影アプリ） | [IrwinCo/madoriba-ios](https://github.com/IrwinCo/madoriba-ios) | 非公開 |
| **使う**（平面図・編集・3D・歩行・DXF） | [24th-garnet/CaptureVisualizer](https://github.com/24th-garnet/CaptureVisualizer) | 公開 |

撮影アプリは 2026 年 10 月に `IrwinCo/madoriba-ios` へ移した。TestFlight への配信もそちらから出ている。
**ここにあった `capture/` は過去の写し**なので畳んだ（履歴は `98a9e80` 以前に残っている）。

## 構成

| ハード | 役割 |
|---|---|
| iPad Pro 2020（A12Z, LiDAR） | 撮影機。ARKit のポーズ・LiDAR 深度・RGB を記録 |
| MacBook Pro M1 Max | 復元エンジン。Metal ネイティブの 3DGS 学習 |

**A12Z での on-device 3DGS は狙わない**（Niantic 自身が Scaniverse で iPad Pro 2020 を splat 非対応にしている）。
iPad はキャプチャに専念し、復元は Mac に寄せる二段構成。

## 設計の核心

高速化の本質は 3DGS の最適化ではなく **SfM（COLMAP）の排除**にある。
ARKit がカメラポーズと intrinsics を確定値で返すため、通常パイプラインで支配的な SfM が丸ごと不要になり、
LiDAR 点群が「密でメートル正解な初期値」と「depth supervision の教師」を同時に供給する。

内装は 3DGS にとって本来最悪の被写体（白壁・無地・鏡・ガラス）だが、LiDAR + ARKit を持つと最良のケースに反転する。

### 二段出力

| | 出力 | 待ち時間 |
|---|---|---|
| Tier 1 | ARKit ライブメッシュ + 間取り | 0 秒（撮影完了と同時） |
| Tier 2a | 3DGS 7K iter プレビュー | 2〜3 分（要実測） |
| Tier 2b | 3DGS 30K iter 最終 | 15〜20 分（裏で差し替え） |

## ディレクトリ

```
spec/      MDR バンドル仕様（撮影アプリと Mac 側の唯一の契約）
tools/     ベンチマーク・変換スクリプト
docs/      設計ドキュメント
```

## ドキュメント

| | |
|---|---|
| [spec/mdr-v1.md](spec/mdr-v1.md) | **MDR バンドル仕様**。撮影側と利用側の契約 |
| [docs/pipeline.md](docs/pipeline.md) | 開発パイプライン仕様 |
| [docs/setup.md](docs/setup.md) | 開発環境セットアップ手順 |
| [docs/scaniverse-research.md](docs/scaniverse-research.md) | Scaniverse の一次調査（内装スキャン重点） |

`docs/` と `spec/` は `IrwinCo/madoriba-ios` にも同じものが入っている。
**撮影アプリから参照するのはあちら側**。ここは記録として残す。

## 経緯

| | |
|---|---|
| 2026-09 | 3DGS（recon）を畳む。Tier 1 に絞る |
| 2026-10-02 | Mac 側（平面図・編集・3D・DXF）を CaptureVisualizer へ分離 |
| 2026-10 | 撮影アプリを `IrwinCo/madoriba-ios` へ移す。Web 連携（Supabase + madoriba-web）はそちらで開発 |
