# InteriorCapture

LiDAR 搭載の iPhone / iPad で**内装をスキャン**し、`.mdr` バンドルとして取り出す仕組み。

このリポジトリが持つのは **`.mdr` の仕様と設計の記録だけ**。動くコードは別リポジトリにある。

| | リポジトリ | |
|---|---|---|
| **撮る** — madoriba capture（iPhone / iPad 撮影アプリ） | `IrwinCo/madoriba-ios` | 非公開 |
| **届ける・見る** — 空間ギャラリー・平面図・3D・積算・DXF | `IrwinCo/madoriba-web` | 非公開 |
| **使う** — 平面図・編集・3D・歩行・DXF（Mac アプリ） | [24th-garnet/CaptureVisualizer](https://github.com/24th-garnet/CaptureVisualizer) | 公開 |

撮影アプリは 2026 年 10 月に `IrwinCo/madoriba-ios` へ移した。TestFlight への配信もそちらから出ている。
**ここにあった `capture/` は過去の写し**なので畳んだ（履歴は `98a9e80` 以前に残っている）。

## いまの流れ

撮影から Web に届くまでが一本になっている。Mac を介さない。

```
iPhone / iPad（madoriba capture）
  ログイン（Supabase Auth・Web と同じアカウント）
  撮影 → 端末で焼き込み（mesh.glb / mesh.usdz）＋ RoomPlan（room.json）
    ① スキャンを登録          → 保存先 {会社}/{scan}/bundle/ を受け取る
    ② TUS で Storage へ送る    → manifest.json / bake.json / room.json / mesh*.glb / mesh*.usdz / thumb.jpg
                                 6MB チャンク・切れても続きから。frames（約 200MB）は送らない
    ③ 完了を知らせる          → Web 側が room.json から面積・天井高・壁/開口/家具・2D DXF を作る
    ④ 出来上がりを待つ        → アプリに「Web に反映済み（xx ㎡）」
madoriba Web
  空間ギャラリーに出る → 3D・平面図・面積・DXF → 積算 → 共有リンク
```

実測で**撮影完了から 17.3 秒で Web に反映**（5×4m の部屋）。
契約の詳細は `IrwinCo/madoriba-web` の `docs/20_IOS_WEB_SYNC.md`。

## MDR バンドル

撮影側と利用側の**唯一の契約**。ここが本リポジトリの中身。

| | |
|---|---|
| [spec/mdr-v1.md](spec/mdr-v1.md) | MDR バンドル仕様 |
| [spec/mdr-v1.schema.json](spec/mdr-v1.schema.json) | manifest のスキーマ |

## ディレクトリ

```
spec/      MDR バンドル仕様（撮影アプリと利用側の唯一の契約）
tools/     ベンチマーク・変換スクリプト
docs/      設計ドキュメント
```

`docs/` と `spec/` は `IrwinCo/madoriba-ios` にも同じものが入っている。
**撮影アプリから参照するのはあちら側**。ここは記録として残す。

---

## 設計の記録：3DGS を狙っていた頃（2026-08 〜 09）

以下は**畳んだ設計**。いまは端末の焼き込み（Tier 1）だけで、3DGS は動いていない。
判断の経緯として残す。

| ハード | 役割 |
|---|---|
| iPad Pro 2020（A12Z, LiDAR） | 撮影機。ARKit のポーズ・LiDAR 深度・RGB を記録 |
| MacBook Pro M1 Max | 復元エンジン。Metal ネイティブの 3DGS 学習 |

**A12Z での on-device 3DGS は狙わない**（Niantic 自身が Scaniverse で iPad Pro 2020 を splat 非対応にしている）。
iPad はキャプチャに専念し、復元は Mac に寄せる二段構成にしていた。

高速化の本質は 3DGS の最適化ではなく **SfM（COLMAP）の排除**にある。
ARKit がカメラポーズと intrinsics を確定値で返すため、通常パイプラインで支配的な SfM が丸ごと不要になり、
LiDAR 点群が「密でメートル正解な初期値」と「depth supervision の教師」を同時に供給する。

内装は 3DGS にとって本来最悪の被写体（白壁・無地・鏡・ガラス）だが、LiDAR + ARKit を持つと最良のケースに反転する。

| | 出力 | 待ち時間 |
|---|---|---|
| Tier 1 | ARKit ライブメッシュ + 間取り | 0 秒（撮影完了と同時） |
| Tier 2a | 3DGS 7K iter プレビュー | 2〜3 分（未実測のまま畳んだ） |
| Tier 2b | 3DGS 30K iter 最終 | 15〜20 分（同上） |

| | |
|---|---|
| [docs/pipeline.md](docs/pipeline.md) | 開発パイプライン仕様 |
| [docs/setup.md](docs/setup.md) | 開発環境セットアップ手順 |
| [docs/scaniverse-research.md](docs/scaniverse-research.md) | Scaniverse の一次調査（内装スキャン重点） |
| [docs/timing-and-quality.md](docs/timing-and-quality.md) | 時間と品質の実測 |

## 経緯

| | |
|---|---|
| 2026-09 | 3DGS（recon）を畳む。Tier 1 に絞る |
| 2026-10-02 | Mac 側（平面図・編集・3D・DXF）を CaptureVisualizer へ分離 |
| 2026-10-06 | Web 連携を入れる（Supabase Auth・TUS・自動送信）。配信は madoriba-ios から |
| 2026-11 | `capture/` を畳む。撮影アプリの正本は madoriba-ios |
