# KiraRaki — Contour Studio

Apple Silicon向けのリアルタイム輪郭表現ツール。SwiftUIのMacアプリとOBSのフィルタ／独立ソースから、共通のC++・Metalエンジンを操作します。

カメラ・動画・OBSのソース／シーンを入力に、外輪郭・内部特徴・テクスチャ・動きからカラフルな線を生成します。処理と保存はローカルで行います。

## 起動

必要環境: Apple Silicon、macOS 14以降、Xcode、CMake 3.24以降。OBS連携のビルド基準はOBS Studio 32.2.2です。

```sh
scripts/build.sh --obs
scripts/service.sh start
scripts/install-obs.sh
open build/KiraRaki.app
```

`--obs`はOBSとSIMDeのヘッダを`.deps/`へ取得します。OBS本体は`/Applications/OBS.app`を使用します。既存のOBSソースは`KIRA_OBS_SOURCE`で指定できます。アプリだけなら`--obs`を省略できます。

OBSの再起動後、「KiraRaki 輪郭フィルタ」または「KiraRaki 線画ソース」を追加してください。既存のプラグインがある場合、インストールスクリプトはバックアップしてから更新します。

`scripts/service.sh`は開発用のユーザーLaunchAgentを登録します。停止・解除は`scripts/service.sh stop`です。アプリ内の「サービスを登録 / 接続」は同梱LaunchAgentをSMAppServiceで登録します。macOSが承認を求めた場合はログイン項目で有効にしてください。開発用登録とSMAppService登録は併用せず、切り替える前に開発用登録を停止してください。

再ビルド前にKiraRakiを終了し、`scripts/service.sh stop`でヘルパーを停止してください。実行中のバイナリやシェーダーを置き換えない運用にします。

## 操作

- **シンプル表示**: 入力、プレビュー、線幅、変形強度、描画密度、色、プリセット、録画、書き出し。
- **詳細 → 描画**: 稲妻・有機線・グリッチ・断片線のON/OFFと混合、解析方式、領域の重み、発生位置、追従、寿命、変化・更新頻度、発光、残像、パレット、シード、プリセット補間。
- **詳細 → 音 / MIDI**: 動画音声／OBSミックス／無音、RMS・低中高域・アタックの自由マッピング、ゲイン、範囲、アタック／リリース、反転、MIDI Learn。
- **詳細 → 接続**: 操作するOBS項目、入力ソース／シーン、音声ミックス1〜6、プレビュー対象、負荷適応と状態表示。

変化・更新頻度を下げると、線の変形・断片・配置の変化がゆっくりになります。対象への追従と、色相の変化速度は別に調整できます。描画密度は候補曲線の弧長に対する目標比率です。画面のピクセル占有率ではありません。

OBSのフィルタは追加先のソース／シーンを解析します。独立ソースは参照元を指定するか、Macアプリで開いているカメラ／動画の結果を使います。後者ではMacアプリ側の入力を動かしておいてください。循環参照は拒否します。

| ショートカット | 操作 |
| --- | --- |
| Space | エフェクトON/OFF |
| ⌘Space | 再生／一時停止 |
| ⌘O | 動画を開く |
| ⌘R | 録画開始／停止 |
| ⇧⌘R | ランダム生成 |
| 1〜4 | 内蔵プリセット |

プリセットは`~/Library/Application Support/KiraRaki/`、MIDI割当はアプリのユーザー設定に保存します。

## 保存と再現

| 形式 | 用途 |
| --- | --- |
| H.264 / MP4 | 合成動画。アルファなし |
| ProRes 4444 / MOV | 高品質の透過動画 |
| HEVC with Alpha / MOV | 省容量の透過動画。利用先の対応が必要 |

透過素材は出力を「透明 / RGBA」にしてください。リアルタイム録画と、動画を1フレームずつ処理するオフライン書き出しに対応します。オフライン書き出しは一時ファイルで完了させてから保存先へ反映します。

録画時には同じ場所に`.kirareplay/`を作り、プリセット、操作／MIDIによる変更、PTS、シード、入力SHA-256、モデル情報を保存します。カメラ／OBSでは加工前の映像もProRes 422 HQで保存します。動画ファイルでは原本を参照し、OBS音声を組み合わせる場合は音声を含むクリーン映像を別途保存します。保存容量と帯域は録画中に表示します。

「操作ログから再現…」で`.kirareplay/`を選ぶと、録画区間と変更イベントを再適用します。未完了の録画、欠落が記録されたクリーン映像、入力ハッシュの不一致は書き出しを止めます。OS・Vision・GPU・ライブ時のフレーム欠落によるピクセル差は許容し、厳密なピクセル一致は保証しません。

## 実装と確認範囲

詳細は[開発仕様](docs/architecture.md)と[動作確認記録](docs/verification.md)を参照してください。1080p/30fps・OBS合成出力までp95 200ms以下は実機評価の目標です。画面の遅延は内部推定値で、外部基準による実測値ではありません。

AI処理はmacOS内蔵Visionの前景インスタンスマスクと人物セグメンテーションを使います。物体のクラス分類は行いません。外部Core MLモデルの配信・更新UI、解析キャッシュによる厳密な再現はこの版に含めていません。

## 開発用CLI

```sh
cli=build/KiraRaki.app/Contents/MacOS/KiraRakiCLI
"$cli" status
"$cli" demo --frames 12 --output build/demo.mp4 --tone
"$cli" record-demo --frames 12 --output build/recording.mp4
"$cli" export --input input.mov --output output.mov --codec prores4444 --mode 2
```

`export`は`--preset preset.json`、`--events session.kirareplay/events.jsonl`、`--mute`を指定できます。`--mode`は0=合成、1=黒背景、2=透明です。CLIは既存の動画を上書きしません。
