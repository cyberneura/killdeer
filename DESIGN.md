# Killdeer — Design Document

## 概要
macOS メニューバーアプリ。暴走したプロセス（特に AI エージェントの孤児 Chrome Helper）を検知して警告し、簡単に Kill できる。

## 名前
**Killdeer** — 北米の鳥。警戒心が強く「警報を出す」特性 + 名前に `kill` が入っている。

## オーナー
cyberneura

## 技術スタック
- **Swift (SwiftUI MenuBarExtra + AppKit)** — macOS 専用、クロスプラットフォーム不要。温度・ファン取得には IOKit/SMC/IOReport の C/Objective-C API が必要で、Tauri では FFI が増える。Swift なら FFI 無しで直接叩ける。
- **Tauri は採用しない** — アイドル約 80MB の WKWebView を抱える、温度/ファンに FFI が要る、macOS 専用でクロスプラットフォームの利点が効かない。
- **Deployment**: Developer ID + notarization (App Sandbox 非対応、Mac App Store 不可)
- **常駐**: SMAppService の Login Item

## MVP 機能 (優先実装)
1. **プロセス監視**: 1秒周期のスコアリングによる検知 (CPU 閾値 + 孤児プロセス加点、単独判定は誤検知を避ける)
2. **メニューバーアイコン変化**: 正常 = 通常 / 警告 = 色変化
3. **2段階 Kill**: SIGTERM → 猶予 → SIGKILL (PID 再利用対策で proc start time も照合)
4. **プロセス詳細表示**: プロセスの役割・引数
5. **「孤児 Chrome を一括掃除」ボタン**: 最も使われる機能
6. **システム状況の表示**: CPU 使用率と温度をメニュー内に表示
7. **Activity Monitor を開く**: 詳細を見たくなった時の逃げ道

## 次点機能
- 除外ルール (プロセス名・パターンで無視)
- Kill 履歴のログ
- 閾値設定 UI
- Slack 転送

## やらないこと (設計判断)
- **自動 Kill** — 誤検知で作業を壊すリスク大
- **ファン回転数** — Stats で代替可、差別化点にならない
- **タブ情報取得** — Accessibility (TCC) が必要で急に面倒になる
- **App Sandbox** — 温度/ファン取得と互換性が悪い

## 権限
- 同一ユーザープロセスの列挙と kill: 特別な権限不要 (Full Disk Access / Accessibility 不要)
- 温度取得: sudo も entitlement も不要。IOHIDEventSystemClient (private API) で
  AppleVendor usage page のセンサーを読む。public API ではないので機種差・将来互換性の
  リスクがある。取得できない場合はメニューから温度の表示だけが消え、CPU 使用率は残る

## 技術的注意点
- **孤児 Chrome 検出**: `--remote-debugging-port` はブラウザ本体側、renderer 単独では見えない。親が生きたまま renderer だけ高負荷もあり。孤児化は「強い加点要素」に留める
- **プロセス管理**: AppKit の NSWorkspace または sysinfo 相当の Swift 実装でプロセス列挙。kill は `kill(pid, SIGTERM)` → 猶予 → `kill(pid, SIGKILL)`
- **温度センサー**: センサー名は機種依存。`tdie` を含むものが SoC のダイ温度で、その最大値を出す。
  `tdie` を持たない機種では種類を問わず最も高い値を出すので、SSD やバッテリーの温度が出ることがある。
  無効値 (-1.9 等) を返すセンサーが混ざるので範囲で弾く。1センサーにつき1往復かかるため
  (39個で約44ms、ダイ16個なら約14ms)、読む対象を起動時に絞る
- **CPU 使用率**: `host_statistics(HOST_CPU_LOAD_INFO)` の累積 tick 差分。公開 API
- **参照実装**: exelban/Stats (Swift) or lablup/all-smi (Rust, IOReport+SMC, sudoless)
- **macsmc crate は使わない** — 最終更新 2020-07、Apple Silicon 発売前

## 進め方
1. まず小さな CLI で「孤児 Chrome の検出と一括 kill」だけを作り、どのくらいの頻度で当たるか実測する
2. 価値が確認できたら、その判定ロジックを SwiftUI MenuBarExtra に載せる
3. ファン回転数はやらない