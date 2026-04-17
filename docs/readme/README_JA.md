# ETOS LLM Studio

![Swift](https://img.shields.io/badge/Swift-FA7343?style=flat-square&logo=swift&logoColor=white)
![Platform](https://img.shields.io/badge/Platform-iOS%20%7C%20watchOS-blue?style=flat-square&logo=apple&logoColor=white)
![License](https://img.shields.io/badge/License-GPLv3-0052CC?style=flat-square)
![Build](https://img.shields.io/badge/Build-Passing-44CC11?style=flat-square)

**iOS と Apple Watch で動作するネイティブ AI クライアントです。OpenAI、Anthropic Claude、Google Gemini、各種互換プロバイダに対応し、MCP ツール呼び出し、ローカル RAG メモリ、Worldbook、Daily Pulse、Siri ショートカット、デバイス間同期を備えています。**

[簡體中文](../../README.md) | [English](README_EN.md) | [Traditional Chinese](README_ZH_HANT.md) | [Русский](README_RU.md)

---

## 📸 スクリーンショット

| | |
|:---:|:---:|
| <img src="../../assets/screenshots/screenshot-01.png" width="300"> | <img src="../../assets/screenshots/screenshot-02.png" width="300"> |

---

## 👋 はじめに

学校生活はけっこう退屈で、普段から AI に聞きたいことが次々に出てきます。当時 App Store にある AI アプリは、値段が高すぎるか、機能が物足りなすぎるかのどちらかで、とくに Watch 側はなおさらでした。なので、いっそ自分で作ることにしました。

最初は 1,800 行しかなく、API Key もハードコーディングしていた雑な試作でしたが、今では **235 個の Swift ソースファイルと 118,070 行のコード**（Shared / iOS / watchOS / テストを含む）を持つプロジェクトにまで育ちました。「ETOS LLM Studio」という名前は少し大げさかもしれませんが、本質的には LLM アプリの境界を探るための私の実験場です。

いまでは単なる Watch アプリではなく、iOS 側もモデル、ツール、記憶、Worldbook、Daily Pulse を管理しやすい形へ少しずつ育てています。さらに、両プラットフォームは内蔵の同期エンジンでデータを共有できます。

普段の生活では主に Mac と Apple Watch を使っているので、iPhone 側にはまだ磨き込みたい部分もありますが、これからも少しずつ改善していくつもりです。

### 主な機能

#### チャットとモデル

*   **両プラットフォーム向けネイティブ体験**：iOS と Apple Watch にネイティブ対応し、全体のデザインは揃えつつ、画面サイズごとに操作感を最適化しています。
*   **会話管理の強化**：会話全文検索、メッセージ番号ジャンプ、フォルダ分類、一括移動、会話単位のデバイス間送信に対応しています。
*   **マルチモデル対応**：OpenAI、Anthropic（Claude）、Google（Gemini）などの API 形式にネイティブ対応し、アプリ内でプロバイダとモデルを管理できます。
*   **高度なリクエスト設定**：カスタムヘッダー、パラメータ式、生 JSON リクエストボディに対応し、互換 API や実験的な設定も扱いやすくしています。
*   **マルチモーダルと画像生成**：音声入力、画像入力、AI 画像生成をサポートします。
*   **会話インポート / エクスポート**：Cherry Studio、RikkaHub、Kelivo、ChatGPT conversations からの取り込みと、PDF / Markdown / TXT への書き出しに対応しています。
*   **音声入力（STT）**：`SFSpeechRecognizer` のストリーミング認識に対応し、録音シートでのリアルタイム文字起こしと入力欄への反映が可能です。
*   **音声読み上げ（TTS）**：システム TTS、クラウド TTS、自動フォールバックに対応し、TTS モデルと再生パラメータを個別に設定できます。

#### 表示と閲覧体験

*   **表示システムのカスタマイズ**：カスタムフォント（WOFF / WOFF2）、フォントスロット優先順、吹き出し / 文字色設定、バブルレス UI に対応しています。
*   **フォントフォールバック戦略**：段落単位 / 文字単位のフォールバック範囲を切り替えでき、多言語混在や記号表示の安定性を高めます。
*   **思考・本文プレビュー**：思考の自動プレビューが既定で有効で、手動展開の手間を減らします。
*   **Markdown / コード表示の強化**：構文ハイライト、コピー完了フィードバック、折りたたみ、iOS コードプレビュー、Mermaid 描画、引用ブロック左ラインに対応しています。

#### ツールと自動化

*   **ツールセンター + 拡張ツール**：MCP、Shortcuts、ローカルツールを一元管理し、ツール切り替え、承認ポリシー、セッション単位の有効化に対応します。
*   **Agent Skills**：ツールセンターから一元管理でき、iOS はローカルファイル、watchOS は URL ダウンロードでスキルを導入できます。
*   **構造化質問ツール（ask_user_input）**：1 問ずつの段階回答、単一/複数選択の排他ルール、自由入力、前の質問へ戻る操作に対応します。
*   **拡張ツール機能の拡充**：SQLite の CRUD、Web カード表示、フィードバックチケット自動送信ツールを追加しました。
*   **サンドボックスファイルツール**：検索、分割読み込み、差分確認、部分編集、移動 / コピー / 削除などのファイル操作を行えます。
*   **MCP ツール呼び出し**：リモート [Model Context Protocol](https://modelcontextprotocol.io) に対応し、完全な MCP クライアント、Streamable HTTP/SSE 伝送、再接続、タイムアウト、ハンドシェイク制御、能力交渉を備えています。
*   **Siri ショートカット**：Shortcuts フレームワークと統合されており、ショートカットから AI を呼び出したり、カスタムツールや URL Scheme ルーティングを利用できます。
*   **アプリ内ファイル管理**：サンドボックス内ファイルを直接閲覧・管理できるファイルマネージャを内蔵しています。

#### 記憶と知識整理

*   **ローカル RAG メモリ**：Embedding はクラウド API を利用できますが、**ベクトルデータベース自体は SQLite 上で完全にローカル動作**します。テキスト分割、埋め込み進捗表示、記憶編集、能動検索ツールにも対応しています。
*   **GRDB 関係データ永続化**：コア永続化を JSON から GRDB + SQLite に移行し、会話、設定、MCP、Worldbook、記憶、フィードバック、ショートカットなどをカバーしています。
*   **Worldbook**：SillyTavern の Lorebook に近い仕組みで、背景設定管理、条件トリガー、セッション単位の分離送信、system 注入、URL インポートに対応します。
*   **幅広い形式互換**：PNG naidata、JSON トップレベル配列、`character_book` 形式の Worldbook を扱えます。
*   **リクエストログと速度分析**：独立したリクエストログ、詳細な Token 集計、ストリーミング応答速度グラフを備えています。
*   **高度なレンダリング**：Markdown レンダラを内蔵し、コードハイライト、表、LaTeX 数式を表示できます。

#### Daily Pulse の先回りブリーフィング

*   **Daily Pulse**：その日に見ておく価値がありそうな内容を、先にカードとして整理して提示します。
*   **Pulse タスク運用**：カードをそのまま追跡タスクに変換でき、未完了タスクは日をまたいで残り、次回の Pulse 生成にも使われます。
*   **フィードバック履歴の学習**：高評価、低評価、非表示、保存といった反応が長期的な好みとして蓄積され、今後の結果に影響します。
*   **朝の通知と会話継続**：定時通知、通知クイックアクション、セッション保存、会話継続に対応し、iOS と watchOS の両方で流れをつなげられます。

#### 同期・デバッグ・運用

*   **デバイス間同期**：iOS ↔ watchOS の同期エンジンを内蔵し、プロバイダ設定、会話、Worldbook、ツール設定、Daily Pulse データなどを自動共有しつつ、Manifest/Delta 差分同期を主経路に採用しています。
*   **同期とバックアップ**：ETOS パッケージのエクスポート/インポート、watch 側フルインポート、起動時バックアップと破損時自己修復、任意 URL への POST アップロードに対応します。
*   **アプリ内フィードバックアシスタント**：フィードバック分類、環境情報収集、PoW 送信フロー、両プラットフォーム同期をサポートします。
*   **ネットワークプロキシ**：グローバル / プロバイダ単位の HTTP(S) / SOCKS プロキシ（認証付き）をサポートします。
*   **フィードバックセンターと通知強化**：チケット内コメント、開発者バッジ表示、状態自動更新、高優先度ローカル通知から詳細への遷移をサポートします。
*   **LAN デバッグ**：LAN デバッグクライアントに加え、Go 版デバッグサービスと内蔵 Web コンソールでブラウザからファイル/会話を管理できます。
*   **ローカライズ**：英語、簡体字中国語、繁体字中国語（香港）、日本語、ロシア語、フランス語、スペイン語、アラビア語の 8 言語に対応しています。

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

*   **言語**: Swift 6
*   **UI**: SwiftUI
*   **アーキテクチャ**: MVVM + Protocol Oriented Programming
*   **データ**: GRDB + SQLite（会話 / 設定 / 記憶などの中核永続化とローカルベクトルDB）, JSON（インポート / エクスポートと互換フォーマット）
*   **ネットワークと伝送**: URLSession（API リクエスト）, Streamable HTTP / SSE（MCP 伝送）, WebSocket / HTTP Polling（LAN デバッグ）
*   **AI プロトコル**: Model Context Protocol (MCP)
*   **システム連携**: Siri Shortcuts, WatchConnectivity, UserNotifications, BackgroundTasks（iOS）
*   **依存管理**: Swift Package Manager（現在の明示的依存は `GRDB.swift` と `swift-markdown-ui`。推移的依存として `networkimage` と `swift-cmark` を含みます）

---

## 🏗️ プロジェクト構成

このプロジェクトは、プラットフォーム非依存の Shared フレームワークと、各プラットフォーム専用のビュー層からなる二層構造です。

```
Shared/Shared/                  ← プラットフォーム非依存の業務ロジック（87 個の Swift ソースファイル）
├── ChatService.swift            ← セッション、メッセージ、モデル選択、リクエスト編成を管理する中核シングルトン
├── APIAdapter.swift             ← OpenAI / Anthropic / Gemini など向け API アダプタ層
├── Models.swift                 ← コアデータモデル
├── Persistence.swift            ← ストレージ入口、移行起動、ライフサイクル調整
├── PersistenceGRDBStore.swift   ← GRDB 関係データ永続化の中核実装
├── DailyPulse.swift             ← Daily Pulse エンジン、カード、フィードバック、タスクデータ
├── DailyPulseDeliveryCoordinator.swift ← 朝の通知、配信状態、準備ウィンドウの調整
├── Memory/                      ← 記憶サブシステム（分割、埋め込み、保存）
├── SimilaritySearch/            ← ローカルベクトルデータベース（SQLite）
├── MCP/                         ← Model Context Protocol クライアントと伝送層
├── Feedback/                    ← アプリ内フィードバックアシスタント（収集、署名、保存、送信）
├── Worldbook/                   ← Worldbook エンジン、インポート、エクスポート
├── Sync/                        ← iOS ↔ watchOS 同期エンジン
├── TTS/                         ← 音声読み上げの再生、設定、プリセット
├── Shortcuts/                   ← Siri ショートカットと URL ルータ統合
├── AppToolManager.swift         ← ローカルツールとツールカタログの制御
├── StorageBrowserSupport.swift  ← ファイル閲覧・管理サポート
└── LocalDebugServer.swift       ← LAN デバッグクライアント

ETOS LLM Studio/ETOS LLM Studio iOS App/    ← iOS ビュー層（44 個の Swift ソースファイル）
ETOS LLM Studio/ETOS LLM Studio Watch App/  ← watchOS ビュー層（47 個の Swift ソースファイル）
Shared/SharedTests/                         ← Shared 層テスト（54 個の Swift ソースファイル）
```

データフローは `View → ChatViewModel → ChatService.shared → APIAdapter → LLM API` で、UI 更新は Combine の Subjects によって駆動されます。

---

## 🚀 ビルドガイド

自分でビルドする場合は次の通りです。

1.  **プロジェクトを Clone**:
    ```bash
    git clone https://github.com/Eric-Terminal/ETOS-LLM-Studio.git
    ```
2.  **必要環境**:
    *   Xcode 26.0+
    *   watchOS 26.0+ SDK
    *   （環境が完全に一致しない場合は、自分で互換性を調整してください）
3.  **プロジェクトを開く**:
    `ETOS LLM Studio.xcworkspace` を開いてください（xcodeproj ではなく **workspace** です）。
    初回起動時に Swift Package 依存関係が自動で解決・取得されます。
4.  **実行**:
    `ETOS LLM Studio Watch App` または `ETOS LLM Studio iOS App` ターゲットを選び、デバイス（またはシミュレータ）を接続して Command + R を押します。
5.  **設定**:
    起動後は設定画面で API Key を追加してください。可能であれば「LAN デバッグ」機能を使って、用意済みの JSON 設定ファイルを `Documents/Providers/` に直接プッシュするのがおすすめです（Apple Watch 上で API Key を手入力したい人は、たぶんあまりいません）。

---

## 📬 連絡先

*   **開発者**: Eric Terminal
*   **Email**: ericterminal@gmail.com
*   **GitHub**: [Eric-Terminal](https://github.com/Eric-Terminal)

---

この README は 2026 年 4 月 18 日（31d1e21 の後）に更新されました。プロジェクトの更新速度はかなり速いので、README が追いついていない場合はコミット履歴のほうが正確です。
