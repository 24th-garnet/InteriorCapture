# vendor/ への修正パッチ

`vendor/` は gitignore しているため、外部リポジトリへの修正はここにパッチとして残す。

## 適用

```bash
cd vendor/msplat && git apply ../../tools/patches/msplat-imwrite-32bpp.patch
cmake --build build -j
```

## msplat-imwrite-32bpp.patch

**症状**: `msplat --val-render <dir>` が 0 バイトの一時ファイル（`.7000.png-XXXX`）
しか残さず、PNG が 1 枚も書き出されない。エラーも出ない。

**原因**: `imwriteRGB` が `CGBitmapContextCreate` に **24bpp RGB**
（`kCGImageAlphaNone` + 3 bytes/pixel）を渡していた。Core Graphics は
RGB 色空間でこの構成を受け付けず NULL を返すため、以降の `CGImageRef` も NULL になり、
`CGImageDestinationFinalize` が何も書かずに終わる。戻り値を見ていないので無音で失敗する。

**修正**: 32bpp（`kCGImageAlphaNoneSkipLast`）にパディングして渡す。
あわせて `ctx` / `dest` / `Finalize` の失敗を検出して stderr に出すようにした。

学習結果を目視評価するのに必須なので、上流に取り込まれるまではこのパッチを当てて使う。
