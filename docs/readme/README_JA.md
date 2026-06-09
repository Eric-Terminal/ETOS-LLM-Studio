# ETOS LLM Studio

![Swift](https://img.shields.io/badge/Swift-FA7343?style=flat-square&logo=swift&logoColor=white)
![Platform](https://img.shields.io/badge/Platform-iOS%20%7C%20watchOS-blue?style=flat-square&logo=apple&logoColor=white)
![License](https://img.shields.io/badge/License-GPLv3-0052CC?style=flat-square)
![Build](https://img.shields.io/badge/Build-Passing-44CC11?style=flat-square)

**iOS と Apple Watch で動作するネイティブ AI クライアントです。OpenAI、Anthropic Claude、Google Gemini、端末上の GGUF / llama.cpp モデルに対応し、MCP ツール呼び出し、Agent Skills（スキルパック）、ローカル RAG メモリ、Worldbook、Daily Pulse、アプリロックと SQLCipher フルディスク暗号化、CloudKit / WatchConnectivity によるデバイス間同期、Siri ショートカットを備えています。**

[簡體中文](../../README.md) | [English](README_EN.md) | [Traditional Chinese](README_ZH_HANT.md) | [Русский](README_RU.md)

---

## 📸 スクリーンショット

| | |
|:---:|:---:|
| <img src="../../assets/screenshots/screenshot-01.png" width="300"> | <img src="../../assets/screenshots/screenshot-02.png" width="300"> |

---

## 👋 はじめに

学校生活はけっこう退屈で、普段から AI に聞きたいことが次々に出てきます。当時 App Store にある AI アプリは、値段が高すぎるか、機能が物足りなすぎるかのどちらかで、とくに Watch 側はなおさらでした。なので、いっそ自分で作ることにしました。

最初は 1,800 行しかなく、API Key もハードコーディングしていた雑な試作でしたが、今では **641 個の Swift ソースファイルと 226,381 行の Swift コード**（プロジェクト内 Swift のみ。llama.cpp サブモジュールと VitePress ドキュメントサイトの依存は含みません）を持つプロジェクトにまで育ちました。「ETOS LLM Studio」という名前は少し大げさかもしれませんが、本質的には LLM アプリの境界を探るための私の実験場です。

いまでは単なる Watch アプリではなく、iOS 側もクラウドモデル、ローカル GGUF ウェイト、ツール、記憶、Worldbook、Daily Pulse を管理しやすい形へ少しずつ育てています。さらに、両プラットフォームは内蔵の同期エンジンでデータを共有できます。

普段の生活では主に Mac と Apple Watch を使っているので、iPhone 側にはまだ磨き込みたい部分もありますが、これからも少しずつ改善していくつもりです。

### 主な機能

#### チャットとモデル

*   **両プラットフォーム向けネイティブ体験**：iOS と Apple Watch にネイティブ対応し、全体のデザインは揃えつつ、画面サイズごとに操作感を最適化しています。iOS のセッション一覧はカード型レイアウトで、フォルダとセッションが分かれて並び、横向き時には固定 2 カラムのサイドバーに自動切り替わります。
*   **会話管理の強化**：会話全文検索、ヒット箇所プレビュー、メッセージ番号ジャンプ、フォルダ分類、Finder 風のカラフルなタグ、クイックフィルタ、ネスト移動、一括操作、全画面の会話管理入口、会話単位のデバイス間送信に対応し、会話履歴は無限スクロール読み込みに変更しました。
*   **マルチモデル対応**：OpenAI Chat、OpenAI Responses、Anthropic（Claude）、Google（Gemini）などの API 形式にネイティブ対応し、アプリ内でプロバイダ／モデルを管理できます。プロバイダは長押しドラッグで並び替えでき、プロバイダ配下の全モデルに対する並列数指定つき一括接続テストにも対応します。
*   **端末上のローカルモデル**：GGUF ウェイトを取り込み、「ローカルモデル」プロバイダとして利用できます。実行は llama.cpp の C ABI ブリッジ経由で行い、ストリーミング出力、GGUF Jinja chat template、ローカルツール呼び出し解析、思考内容解析、ローカル Embedding モデルルーティング、バックグラウンド detached completion に対応します。
*   **ローカルモデル高度調整**：GGUF ウェイトごとにコンテキスト長、出力上限、GPU レイヤー数、batch / ubatch、KV offload、flash attention、seed、サンプラーチェーン、grammar、反復ペナルティ、チャットテンプレート透過などを必要に応じて上書きできます。よく使う llama.cpp-style CLI パラメータのインポート、モデルキャッシュ切り替え、iOS 高メモリ制限にも対応しています。
*   **高度なリクエスト設定**：カスタムヘッダー、パラメータ式、構造化リクエスト制御、Key/Value Payload 編集、生 JSON リクエストボディ、リクエストプレビューに対応し、互換 API や特殊なモデルも扱いやすくしています。
*   **メッセージ正規表現ルール**：送受信メッセージをルールで一括書き換えでき、複数ルールを設定で管理し、プロバイダ画面から素早く開けます。
*   **単一 AI 返信の書き直し**：履歴内の特定の AI 返信だけを書き直せます。同じメッセージの別バージョンを参照しながら、会話全体を再実行せずに局所調整できます。
*   **モデル料金と費用見積もり**：モデルごとにローカル価格（段階価格区間を含む）を設定でき、トークン使用量に応じて各メッセージのコストを自動計算します。
*   **マルチモーダルと画像生成**：音声、画像、ファイル添付の送信に対応。画像は専用 OCR チャネルを通せるほか、ファイル添付は送信前にテキスト化され、画像生成入口はアシスタント画像アルバムに整理されました。
*   **会話インポート / エクスポート**：ETOS / `.elsbackup`、Cherry Studio、RikkaHub、Kelivo、ChatBox、ChatGPT conversations からの取り込みと、PDF / Markdown / TXT への書き出しに対応しています。
*   **音声入力（STT）**：`SFSpeechRecognizer` のストリーミング認識に対応し、iOS / watchOS の録音フローはチャット入力欄に内蔵されました。リアルタイム文字起こし、音声の直接送信、認識結果の入力欄への反映に対応します。
*   **音声読み上げ（TTS）**：システム TTS、クラウド TTS、自動フォールバックに対応し、TTS モデルと再生パラメータを個別に設定できます。
*   **並列セッションリクエスト**：セッションごとに独立したリクエスト状態を保持し、セッション単位のキャンセル、バックグラウンド完了通知、通知からの該当チャットへのジャンプに対応します。

#### 表示と閲覧体験

*   **表示システムのカスタマイズ**：カスタムフォント（WOFF / WOFF2）、フォントスケール、フォントスロット優先順、吹き出し／文字色設定、チャット配色プロファイル、時刻に応じた配色自動切り替え、アシスタント吹き出しの無効化に対応しています。
*   **ローカル性能モニタ**：iOS でローカルモデルを使っている間、入力欄の上に CPU、Metal、メモリ使用量を表示できます。パネルは折りたたみ、ドラッグ、タッチ透過、位置記憶に対応します。
*   **バブルツールバー**：チャットバブルの下にカスタマイズ可能なツールバーを表示でき、1 行横スクロール、外枠ボーダーの無効化、iOS と watchOS で別々の既定項目（ユーザー／アシスタント別）、watchOS でのドラッグ並び替えに対応します。
*   **フォントフォールバック戦略**：段落単位 / 文字単位のフォールバック範囲を切り替えでき、多言語混在や記号表示の安定性を高めます。
*   **思考とツールタイムライン**：思考のローリングプレビュー、カスタム/レスポンシブなプレビュー高さ、ストリーミング中の全文思考非表示、思考時間表示、非同期思考サマリー、ツール呼び出しのつながったタイムライン、エラー再試行の継続実行、複数バージョンの返信切り替えに対応します。ツール承認は行／列レイアウトのオプションを備えたネイティブな質問シートに刷新されました。
*   **Markdown / コード表示の強化**：構文ハイライト、コピー完了フィードバック、折りたたみ、iOS コードプレビュー、Mermaid 描画、SwiftMath 数式、引用ブロック左ライン、ストリーミング末尾文字のフェードイン、シマー演出に対応しています。
*   **watchOS 画像閲覧**：Markdown 画像と生成画像のプレビューが Digital Crown のズームとドラッグに対応し、小さな画面でもしっかり画像を見られます。

#### ツールと自動化

*   **ツールセンター + 拡張ツール**：MCP / Shortcuts / 組み込みローカルツール / カスタム JavaScript ツール / Agent Skills と組み込みの `getSystemTime` などを一元管理し、出所と用途ごとの分類、チャットでのツール切り替え、承認ポリシー、セッション単位の有効化、カテゴリ分け、ツール詳細ページに対応します。
*   **Agent Skills スキルパック**：ローカルフォルダ、GitHub リポジトリリンク、GitHub raw / ネストフォルダ、デフォルトブランチ、隠しフォルダからスキルパックを取り込めます。スキルリソースは複数のテキストエンコーディング読み込み、大容量テキストのチャンク化、ドキュメント抽出、画像 OCR に対応し、スキルのメタデータはオンデマンド有効化のためモデルに公開されます。
*   **構造化質問ツール（`ask_user_input`）**：1 問ずつの段階回答、単一/複数選択の排他ルール、自由入力、前の質問へ戻る操作に対応します。
*   **カスタム JavaScript ツール**：分離式 JS 実行と AI 生成スクリプトツールに対応します。スクリプトは `CustomJSTools` 専用ディレクトリに保存され、作成前に検証され、通常のツールと同じように有効化、無効化、承認ポリシー設定ができます。
*   **拡張ツール機能の拡充**：システム時刻、SQLite の CRUD、Web カード表示、入力欄への差し込み、サンドボックスファイル操作、フィードバックチケット自動送信ツールを内蔵しています。
*   **サンドボックスファイルツール**：検索、分割読み込み、差分確認、部分編集、移動 / コピー / 削除などのファイル操作を行えます。
*   **MCP ツール呼び出し**：公式 Swift [Model Context Protocol](https://modelcontextprotocol.io) SDK を基盤に、Streamable HTTP / SSE 伝送、再接続、タイムアウト、ハンドシェイク制御、メタデータ更新、リソース／テンプレート／プロンプト読み込み、能力交渉に対応します。サーバーのドラッグ並び替え、ツール単位の有効化/承認ポリシー、組み込みサーバーの削除と復元、チャット公開トグルによる遅延自動接続にも対応します。
*   **組み込み MCP サーバー**：検索、ローカルアプリツール、個人データの MCP サーバーを内蔵しています。個人データサーバーは、ツールが実際に呼ばれたタイミングで HealthKit、カレンダー、リマインダー権限を必要分だけ要求します。
*   **Siri ショートカット**：Shortcuts フレームワークと統合されており、ショートカットから AI を呼び出したり、カスタムツールや URL Scheme ルーティングを利用できます。
*   **アプリ内ファイル管理**：サンドボックス内ファイルを直接閲覧・管理できるファイルマネージャを内蔵し、プレーンテキストファイルはその場でプレビューできます。

#### 記憶と知識整理

*   **ローカル RAG メモリ**：Embedding はクラウド API または登録済みのローカル Embedding モデルを利用できますが、**ベクトルデータベース自体は SQLite 上で完全にローカル動作**します。テキスト分割、埋め込み進捗表示、記憶編集、単一メモリの再埋め込み、検索時刻送信制御、能動検索ツールにも対応しています。
*   **GRDB 関係データ永続化**：コア永続化を JSON から GRDB + SQLite に移行し、会話、設定、MCP、Worldbook、記憶、フィードバック、ショートカット、使用量分析、グローバルプロンプトなどをカバーしています。土台として SQLCipher のフルディスク物理暗号化を任意で有効化できます。
*   **Worldbook**：SillyTavern の Lorebook に近い仕組みで、背景設定管理、条件トリガー、セッション単位の分離送信、system 注入、URL インポートに対応します。SillyTavern との互換性として、複数本の同時注入、注入バジェット制御、フィールド分離をさらに改善しました。
*   **幅広い形式互換**：PNG naidata、JSON トップレベル配列、`character_book` 形式の Worldbook を扱えます。
*   **リクエストログと速度分析**：独立したリクエストログ、ペイロード詳細ページの展開、リクエスト本文の平文記録を切り替えるトグル、詳細な Token 集計、ストリーミング応答速度グラフを備えています。
*   **使用量分析**：テキストリクエスト、モデルランキング、Token とキャッシュ Token を記録し、iOS / watchOS 両方のダッシュボード、緑色ヒートマップ、キャッシュヒット率、デバイス間同期を提供します。今日の傾向は時間単位で分割され、モデル別の Token トレンドグラフ、占有率分析、全期間レンジに対応します。
*   **高度なレンダリング**：Markdown レンダラを内蔵し、コードハイライト、表、LaTeX 数式を表示できます。

#### Daily Pulse の先回りブリーフィング

*   **Daily Pulse**：その日に見ておく価値がありそうな内容を、先にカードとして整理して提示します。
*   **Pulse タスク運用**：カードをそのまま追跡タスクに変換でき、未完了タスクは日をまたいで残り、次回の Pulse 生成にも使われます。
*   **フィードバック履歴の学習**：高評価、低評価、非表示、保存といった反応が長期的な好みとして蓄積され、今後の結果に影響します。
*   **朝の通知と会話継続**：定時通知、通知クイックアクション、セッション保存、会話継続に対応し、iOS と watchOS の両方で流れをつなげられます。

#### セキュリティ・同期・運用

*   **アプリロック**：Keychain に保存される PBKDF2 マスターパスワードと生体認証（Face ID / Touch ID）の二重保護に対応します。パスワード変更時の旧パスワード検証や、ロック時のアンロック画面自動表示にも対応し、iOS／watchOS の両方で利用できます。
*   **データベース全体の暗号化**：SQLCipher によりコア SQLite データベースを物理層で暗号化します。暗号化マイグレーション、新パスワード検証、暗号化サブデータベースからの読み込みに対応し、アプリ内ファイルブラウザやデバッグツールとも完全に互換です。
*   **スナップショットのバックアップと暗号化**：SQLite Online Backup API でオフラインのデータベーススナップショット（FTS は剥離）を構築でき、フルスナップショットモードに対応します。シンプルパスワードと PBKDF2 の 2 モードによる AES-256-GCM 暗号化に加え、バイナリ `.elsbackup` のアップロードと安全な復元フローを提供します。
*   **デバイス間同期**：iOS ↔ watchOS の同期エンジンを内蔵し、プロバイダ設定、会話、会話タグ、Worldbook、ツール設定、Daily Pulse、使用量分析、ユーザープロファイル、グローバルプロンプトなどを自動共有します。Manifest/Delta の差分同期、WatchConnectivity の高速チャネル、iCloud ローミング同期、オフラインでのセッションフォーク分離、同一メッセージのリトライ版履歴マージに対応します。
*   **マルチチャネルのクラウドバックアップ**：ETOS パッケージのエクスポート／インポート、`.elsbackup` スナップショットインポート、watch 側フルインポート、CloudKit 伝送（APNs サイレントプッシュによるバックグラウンド同期トリガーを含む）、iCloud Drive のバックアップ書き出し／読み込み、起動時バックアップと破損時自己修復、AWS S3 / Cloudflare R2 などの S3 互換オブジェクトストレージへの署名付きスナップショットアップロード、リモートスナップショット閲覧、クラウドからのダウンロード復元に対応します。
*   **AppConfigStore 設定ハブ**：`@AppStorage` を完全に置き換え、すべての実行時設定が GRDB の永続化、実行時読み取りキャッシュ、メインスレッドへディスパッチされるバックグラウンド非同期書き込みを経由します。これによりメインスレッド I/O や複数端末間での設定ずれを防ぎます。旧 UserDefaults 設定の一回限りの移行にも対応します。
*   **更新タイムライン**：バックエンド不要のバージョントラッキング。Build 情報とキャッシュからリリースタイムラインをローカルで再構築し、AI 要約は Markdown でレンダリングします。iOS ではバッチ表示、watchOS では 2 階層ページに分けて閲覧できます。
*   **アプリ内フィードバックアシスタント**：フィードバック分類、環境情報の収集、Git コミットハッシュ、PoW 送信フロー、チケット内コメント、参照コミットから更新タイムラインへのジャンプ、配布チャネル情報のアップロード、デバイス間同期をサポートします。
*   **ネットワークプロキシ**：グローバル / プロバイダ単位の HTTP(S) / SOCKS プロキシ（認証付き）をサポートします。
*   **フィードバックセンターと通知強化**：チケット内コメント、開発者バッジ表示、状態自動更新、高優先度ローカル通知から詳細への遷移をサポートします。
*   **LAN デバッグ**：LAN デバッグクライアントに加え、Go 版 TUI デバッグツールと内蔵 Web コンソールを備えています。Bonjour 自動発見、ファイル / SQLite / Provider / モデル高度設定 / MCP 管理、アプリ設定編集、OpenAI リクエストキャプチャに対応します。
*   **ドキュメントサイト**：VitePress 製のドキュメントサイトを新設し、インストール、初回チャット、プロバイダ設定、UI ツアー、モジュール解説、設計ドキュメント、利用ヒントを網羅しています。
*   **ローカライズ**：英語、簡体字中国語、繁体字中国語（香港）、日本語、ロシア語、フランス語、スペイン語、アラビア語の 8 言語に対応し、アプリ内で言語を切り替えられます。

---

## 💸 料金とオープンソースについて

正直に言うと、最初は無料ソフトにしたいと思っていました。
ですが、Apple Developer Program の年間 99 ドルという費用は、学生の私にとってはやはり軽くありません。

その後、ある投資家の方がこの費用を立て替えてくれましたが、その代わりにソフトの売上で返済していくことになりました（しかも取り分もあります）。そのため App Store 版では象徴的な金額をいただいています。これは「7日ごとに再署名しなくてよくなる便利さ」と一緒に、開発継続を少し支えてもらう形だと思ってもらえれば嬉しいです。

**それでも、オープンソースだけは譲れません。**

なのでルールはシンプルです。
1.  **手軽さがほしい / 応援したい**：App Store 版をどうぞ。いわゆる「コーラ代」をありがとうございます。
2.  **自分で触りたい / 無料で使いたい**：コードはここにあります。GPLv3 です。Mac と Xcode があれば、**機能差なしで自分でビルドしてインストールできます**。
3.  **最新バージョンを先に試したい**：TestFlight はこちら 👉 [https://testflight.apple.com/join/d4PgF4CK](https://testflight.apple.com/join/d4PgF4CK)

技術は共有されるべきです。ちょっとした価格の壁で、同じようにコードへ興味を持つ人が近づけなくなるのは嫌でした。

---

## 🛠️ 技術スタック

*   **言語**: Swift 6, C / C++（llama.cpp ブリッジ層）
*   **UI**: SwiftUI
*   **アーキテクチャ**: MVVM + Protocol Oriented Programming
*   **データ**: GRDB + SQLite + SQLCipher（中核永続化、ローカルベクトルDB、任意のフルディスク物理暗号化）, JSON（インポート / エクスポートと互換フォーマット）
*   **設定**: AppConfigStore（`@AppStorage` を置き換え、GRDB 永続化 + 実行時キャッシュ + バックグラウンド非同期書き込み）
*   **セキュリティ**: SQLCipher フルディスク暗号化、Keychain PBKDF2 マスターパスワード、LocalAuthentication 生体認証、AES-256-GCM スナップショット暗号化
*   **ネットワークと伝送**: URLSession（API リクエスト）, Streamable HTTP / SSE（MCP 伝送）, WatchConnectivity / CloudKit / APNs サイレントプッシュ（デバイス間とクラウド伝送）, WebSocket / HTTP Polling（LAN デバッグ）
*   **AI プロトコル**: Model Context Protocol（公式の [swift-sdk](https://github.com/modelcontextprotocol/swift-sdk) を基盤）, OpenAI Chat / Responses, Anthropic Messages, Gemini API, ローカル `local-llama-cpp` プロバイダ
*   **ローカル推論**: llama.cpp / GGUF, Swift ↔ C ABI ↔ C++ ブリッジ, CMake + Ninja で事前ビルドする `libetos-llama.a`, Accelerate / Metal（watchOS 実行時は CPU パス固定）
*   **システム連携**: Siri Shortcuts, WatchConnectivity, CloudKit, UserNotifications, BackgroundTasks（iOS）, LocalAuthentication, Speech / AVFoundation
*   **ドキュメントサイト**: VitePress / Teek（ドキュメントサイトのみで使用。README の規模指標にはその依存を含めません）
*   **依存管理**: Swift Package Manager（現在の明示的依存は `GRDB.swift`（Eric-Terminal fork）、`SQLCipher.swift`、`swift-sdk`（MCP）、`swift-markdown-ui`、`SwiftMath`、`ZIPFoundation`、`Cepheus`（watchOS サードパーティキーボード）。推移的依存として `networkimage`、`swift-cmark`、`eventsource`、`swift-nio` などを含みます）+ llama.cpp Git submodule + CMake/Ninja 静的ライブラリビルドスクリプト

---

## 🏗️ プロジェクト構成

このプロジェクトは、プラットフォーム非依存の ETOSCore フレームワークと、各プラットフォーム専用のビュー層からなる二層構造です。最新のリファクタで `Config/AppConfigStore` 設定ハブを導入して `@AppStorage` を全面的に置き換え、さらに `LocalLLM` / `LocalLLMBridge` により端末上の GGUF 推論を既存のチャットライフサイクルへ接続しました。MCP、同期/インポート、LAN デバッグ、会話タグも独立モジュールとして整理しています。現在最大の Swift ファイルは約 1,540 行（`Sync/WatchSyncManager.swift`）で、ローカルモデル管理、同期エンジン、ツールセンターは今後も少しずつ軽くしていく重めのモジュールです。

```
ETOSCore/ETOSCore/                         ← プラットフォーム非依存の業務ロジック（293 個の Swift ソースファイル）
├── AppTool/                            ← ローカルツール、カスタム JS ツール、ask_user_input、SQLite とサンドボックスファイル系ツール
├── Attachments/                        ← ファイル添付のテキスト抽出
├── Chat/                               ← チャットモデル、メッセージバージョン、エクスポート、描画状態
│   └── Service/                        ← ChatService のリクエスト編成、応答解析、リトライ、ツール、記憶と Worldbook 注入
├── Config/                             ← AppConfigStore 設定ハブ、キー定義、旧 UserDefaults マイグレーション
├── ConfigLoader/                       ← Provider 設定、SQLite ストレージ、背景画像と単発ダウンロード状態
├── Core/                               ← コアモデル、JSONValue、リクエストボディ制御、共通基盤
├── DailyPulse/                         ← Daily Pulse の生成、フィルタリング、配信、フィードバック、タスクデータ
├── Feedback/                           ← アプリ内フィードバックアシスタント、環境採取、DTO、ローカル保存
├── Font/                               ← カスタムフォントライブラリ、フォントルーティング、フォールバック範囲
├── LocalDebugServer/                   ← LAN デバッグクライアント、Web コンソール、ファイル / SQLite / Provider コマンド、リクエストキャプチャ
├── LocalLLM/                            ← ローカル GGUF モデル記録、プロバイダブリッジ、パラメータマッピング、Swift 推論入口
├── LocalLLMBridge/                      ← llama.cpp C ABI / C++ ブリッジ層と静的ライブラリリンク境界
├── Math/                               ← LaTeX / 数式レンダリングエンジン
├── MCP/                                ← MCP クライアント、組み込みサーバー、サーバーストレージ、Streamable HTTP / SSE 伝送（公式 swift-sdk ベース）
├── Memory/ + SimilaritySearch/         ← ローカル RAG、Embedding、チャンク化、SQLite ベクトル検索
├── Parsing/                            ← リクエストヘッダーとパラメータ式のパーサ
├── Persistence/                        ← GRDB のメイン／補助 DB、マイグレーション、起動時バックアップ、メディアとファイル保存
├── Providers/                          ← Provider モデル、プロキシ設定、OpenAI / Anthropic / Gemini アダプタ
├── Security/                           ← アプリロックの状態機械、PBKDF2 マスターパスワード、データベース暗号化管理
├── Shortcuts/                          ← Siri ショートカット、URL ルータ、インポートと実行中継
├── Skills/                             ← Agent Skills のインポート、解析、GitHub 取得、リソース読み込み、ポリシー
├── Snapshot/                           ← オフラインデータベーススナップショット構築、AES-256-GCM 暗号化、安全な復元
├── Storage/                            ← サンドボックスファイル閲覧、ストレージ統計、キャッシュ整理
├── Sync/                               ← WatchConnectivity 高速チャネル / CloudKit / iCloud ローミング / Manifest / Delta / iCloud Drive / S3 とサードパーティインポート
├── System/                             ← グローバルプロンプト、通知、お知らせ、ログ、音声認識、OCR、更新タイムライン
├── TTS/                                ← システム／クラウド読み上げ、キュー再生、設定、プリセット
├── UI/                                 ← クロスプラットフォーム UI コンポーネント（アプリロック画面、マーキー文字など）
├── UsageAnalytics/                     ← 使用量イベント、ダッシュボード、時間単位トレンド、モデル別 Token 占有率
└── Worldbook/                          ← Worldbook モデル、インポート／エクスポート、SQLite ストレージ、トリガーエンジン

ETOS LLM Studio/ETOS LLM Studio iOS App/    ← iOS ビュー層（133 個の Swift ソースファイル）
ETOS LLM Studio/ETOS LLM Studio Watch App/  ← watchOS ビュー層（111 個の Swift ソースファイル）
ETOSCore/ETOSCoreTests/                         ← ETOSCore 層テスト（102 個の Swift ソースファイル）
```

クラウドモデルのデータフローは `View → ChatViewModel → ChatService.shared → Provider Adapter → LLM API` です。ローカルモデルのデータフローは `View → ChatViewModel → ChatService.shared → LocalLLMEngine → LocalLLMBridge → libetos-llama.a / llama.cpp` です。セッション、ツール、記憶、Worldbook、使用量分析、同期データは ETOSCore 層サービスと GRDB / SQLite ストレージにより一元的に管理されます。

---

## 🚀 ビルドガイド

自分でビルドする場合は次の通りです。

1.  **プロジェクトとサブモジュールを Clone**:
    ```bash
    git clone --recurse-submodules https://github.com/Eric-Terminal/ETOS-LLM-Studio.git
    cd ETOS-LLM-Studio
    ```
2.  **必要環境**:
    *   Xcode 26.0+
    *   watchOS 26.0+ SDK
    *   CMake + Ninja（なければ `brew install cmake ninja`）
    *   （環境が完全に一致しない場合は、自分で互換性を調整してください）
3.  **最初のビルド手順：llama.cpp 静的ライブラリを生成**:
    Xcode はビルド段階で llama.cpp を毎回コンパイルしません。ETOSCore は事前生成済みの `libetos-llama.a` をリンクします。実機 / Release を使う場合は先に実行します。
    ```bash
    CONFIGURATION=Release SDK_NAME=iphoneos PLATFORM_NAME=iphoneos ARCHS=arm64 scripts/build-llama-static-library.sh --parallel
    CONFIGURATION=Release SDK_NAME=watchos PLATFORM_NAME=watchos ARCHS="arm64 arm64_32" scripts/build-llama-static-library.sh --parallel
    ```
    ローカル Debug シミュレータだけなら次を使えます。
    ```bash
    CONFIGURATION=Debug SDK_NAME=iphonesimulator PLATFORM_NAME=iphonesimulator ARCHS=arm64 scripts/build-llama-static-library.sh --parallel
    CONFIGURATION=Debug SDK_NAME=watchsimulator PLATFORM_NAME=watchsimulator ARCHS=arm64 scripts/build-llama-static-library.sh --parallel
    ```
    生成物は `Dependencies/llama-build/products/<platform>-<configuration>/libetos-llama.a` に置かれます。スクリプトは CMake Generator として Ninja を使い、Ninja 自体が並列ビルドします。`--parallel` を付けるとローカル CPU 数を明示的に CMake へ渡し、`--parallel=8`、`--jobs 8`、`-j8` でタスク数も指定できます。スクリプトは stamp で再ビルドの要否を判断し、最終ライブラリ生成後に中間ビルドディレクトリを整理します。Xcode が `library 'etos-llama' not found`、`file not found: libetos-llama.a`、または llama.cpp シンボル不足を報告した場合は、現在の SDK / Configuration に合うコマンドをもう一度実行してください。
4.  **プロジェクトを開く**:
    `ETOS LLM Studio.xcworkspace` を開いてください（xcodeproj ではなく **workspace** です）。
    初回起動時に Swift Package 依存関係が自動で解決・取得されます。
5.  **実行**:
    iOS App を実行する場合は `ETOS LLM Studio App` Scheme を選びます。watchOS を単独でデバッグする場合だけ `ETOS LLM Studio Watch App` Scheme を選び、デバイス（またはシミュレータ）を接続して Command + R を押します。
6.  **設定**:
    起動後は設定画面で API Key を追加してください。可能であれば「LAN デバッグ」機能を使って、用意済みの JSON 設定ファイルを `Documents/Providers/` に直接プッシュするのがおすすめです（Apple Watch 上で API Key を手入力したい人は、たぶんあまりいません）。

---

## 📬 連絡先

*   **開発者**: Eric Terminal
*   **Email**: ericterminal@gmail.com
*   **GitHub**: [Eric-Terminal](https://github.com/Eric-Terminal)

---

この README は 2026 年 6 月 9 日に更新されました（`cb7bf431` 以降のコミットを基準）。プロジェクトの更新速度はかなり速いので、README が追いついていない場合はコミット履歴のほうが正確です。
