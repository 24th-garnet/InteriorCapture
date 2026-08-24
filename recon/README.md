# recon — madoriba-recon（macOS 復元パイプライン）

MDR バンドルを COLMAP モデル + LiDAR 初期点群に変換し、3DGS を学習する。

仕様: [`docs/pipeline.md`](../docs/pipeline.md) §5〜§7 / [`spec/mdr-v1.md`](../spec/mdr-v1.md)

## セットアップ

```bash
cd recon
uv venv .venv --python 3.12
uv pip install -e . --python .venv/bin/python
uv pip install pytest --python .venv/bin/python
.venv/bin/python -m pytest tests/ -q
```

conda の base 環境が有効だと `python` / `pip` の指す先が紛らわしくなるので、
`conda deactivate` してから作業する。

## 使い方

```bash
# 1. 座標変換の検証（学習前に必ず通す）
mdr2colmap verify room-xxxx.mdr --overlay /tmp/overlay

# 2. COLMAP モデル + 初期点群を書き出す
mdr2colmap convert room-xxxx.mdr -o scene

# 3. サーバ側パイプライン（前処理 + 3DGS を一括、実測 282 秒）
mdr2colmap server room-xxxx.mdr -o scene/ \
  --brush ../vendor/brush/target/release/brush

# 4. 間取り（メッシュから壁線・寸法を抽出）
mdr2colmap floorplan room-xxxx.mdr -o plan/

# 5. ツアーを開く
open -n -a MadoribaTour.app --args scene/tour.json scene/gs/*.ply
```

## 学習解像度は 640 固定

本アプリは **640 のみに対応する**。解像度を上げると品質は単調に改善するが、
5 分要件の下では 640 以外を選ぶ理由がない。ツアービューアで実際に動かして
確認した結果、640 で品質は十分と判断した。高解像度への対応は後付けの課題として
切り離している。

| 学習解像度 | 時間 | PSNR |
|---|---|---|
| **640（採用）** | **317 秒**（4 回計測、±1 秒） | 22.5 |
| 960 | 333 秒 †  | 22.75 |
| 1920 | 712 秒 †  | 22.95 |

† 960 と 1920 は別セッションでの計測で、**再計測していない。**
640 は当初 262 秒と記録していたが再現せず、後日 4 回測って 317 ± 1 秒だった
（同一シーン・`images.bin` のハッシュまで一致・GPU 排他）。
262 秒を説明できる外的要因（電源、低電力モード、他プロセス）は見つかっていない。
**同じずれが 960 と 1920 にも乗っている可能性がある。**

## ガウシアン数は 50 万

25 万との差は PSNR 0.04 dB で、ツアービューアで動かした評価は
「僅かに劣るが許容範囲」だった。25 万なら学習が 81 秒短くファイルも半分になるが、
完走実績がないため既定は 50 万に置く。`--max-splats` で変更できる。

## 3DGS の学習が確率的に落ちる

burn の融合エンジン (burn-fusion) に競合状態があり、**同一シーン・同一引数でも
落ちたり通ったりする**。実測では 408 フレームの部屋で 1 回目が 54 秒で落ち、
2 回目が 300 秒で完走した。ガウシアン数の上限とは相関しない。

```
burn_cubecl_fusion::engine::launch::output.rs:207
  called `Option::unwrap()` on a `None` value
```

**最大 3 回のリトライを入れてある**（`TRAIN_ATTEMPTS`）。落ちるのは序盤
（32〜54 秒）なので、捨てる時間は 1 分弱。1 回落ちた場合の合計は 372 秒。

burn 側に修正はなく、回避策は融合の無効化のみ (tracel-ai/burn#4347)。
融合は Brush のバックエンド型に埋め込まれているため機能フラグでは外せない。

## サーバ処理の実測

`room-c57d5e3a`（408 フレーム / 撮影 104 秒）での実測。

| | |
|---|---|
| 前処理 | 18 秒（ポーズ精密化 10.1 / 初期点群 7.8） |
| 3DGS 学習 | 300 秒 |
| **合計** | **318 秒** |

5 分要件（300 秒）を 18 秒超過するが、許容範囲として合意済み。
学習時間は部屋によって変わる（469 フレームの部屋では 317 ± 1 秒）。

## 二段構成

| | 実測 | 用途 |
|---|---|---|
| **Tier 1** テクスチャ付きメッシュ（iPad 上） | **79 秒** (PSNR 約 16) | 間取り・寸法・即時確認 |
| **Tier 2** 3DGS（Mac 上） | **318 秒** (PSNR 約 22.5) | 写実的なツアー |

Tier 1 は撮影停止後 79 秒でその場で見られる。Scaniverse の 60〜90 秒と同程度で、
先行実装 PRESTAGELiDAR が「再構築に時間がかかりすぎる」ため却下された経緯への回答。

学習設定の根拠と、採用しなかった施策の実測は
[`docs/pipeline.md`](../docs/pipeline.md) §6.3〜6.4 を参照。

## 検証を先に走らせる理由

学習に数分かけてから「なんか変」と気づくのを避けるため。
`verify` は**別フレーム間**で再投影誤差を測る。

同じフレームの深度を非投影してそのフレームに投影し返すのは往復なので、
world 変換が間違っていても誤差が打ち消えて通ってしまう。
フレーム A の点をフレーム B に投影して初めてポーズが検証される。

座標変換が正しければ数 cm、間違っていればメートル単位でずれるので判定は明快に分かれる。

## 出力形式の制約（実装で判明）

| | |
|---|---|
| `cameras.bin` / `images.bin` | **バイナリ必須。** msplat のディスパッチャが `cameras.bin` の存在で形式を判定するため、テキストは受け付けない |
| `points3D.ply` | 点群は `points3D.bin` が無ければ PLY にフォールバックする。可変長トラックを持つバイナリを書かずに済む |
| カメラ台数 | **1 フレーム = 1 台。** ARKit が intrinsics を毎フレーム再計算するため、共通化すると再投影誤差になる |
| カメラモデル | PINHOLE。ARKit は非線形レンズ歪みを補正済みなので歪み係数は不要 |

## モジュール

| | |
|---|---|
| `mdr.py` | MDR バンドルの読み込み。ARKit の生値を素直に numpy に載せるだけ |
| `colmap.py` | **座標変換の集約点。** ARKit → COLMAP の規約変換と COLMAP 書き出し |
| `pointcloud.py` | 深度の非投影 → ボクセル平均 → 外れ値除去 |
| `verify.py` | 再投影による座標変換の検証 |

座標変換を `colmap.py` に集約し、capture（iPadOS）側では一切変換しない。
capture 側で変換すると、バグが見つかったときに再撮影が必要になる。

## 学習実装

| 用途 | 実装 |
|---|---|
| 検証・研究 | gsplat-mlx（上流 gsplat と API 互換） |
| 本番組み込み | Brush（Rust、COLMAP/Nerfstudio 形式を入力に取る） |
| 速度上限の把握 | msplat（全 fused Metal shader） |

**本番採用は Phase 0 のベンチ実測後に確定する。**
前段が COLMAP 形式を吐くので、学習実装は差し替え可能。
