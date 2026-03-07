# ETOS LLM Studio

![Swift](https://img.shields.io/badge/Swift-FA7343?style=flat-square&logo=swift&logoColor=white)
![Platform](https://img.shields.io/badge/Platform-iOS%20%7C%20watchOS-blue?style=flat-square&logo=apple&logoColor=white)
![License](https://img.shields.io/badge/License-GPLv3-0052CC?style=flat-square)
![Build](https://img.shields.io/badge/Build-Passing-44CC11?style=flat-square)

**iOS と Apple Watch で動作するネイティブ AI クライアント。OpenAI・Anthropic Claude・Google Gemini など複数のモデルプロバイダに対応し、ローカル RAG メモリ、MCP ツール呼び出し、Worldbook、Siri ショートカットなどを搭載しています。**

[簡體中文](../../README.md) | [English](README_EN.md) | [Traditional Chinese](README_ZH_HANT.md)

---

## 📸 スクリーンショット

| | |
|:---:|:---:|
| <img src="../../assets/screenshots/screenshot-01.png" width="300"> | <img src="../../assets/screenshots/screenshot-02.png" width="300"> |
| <img src="../../assets/screenshots/screenshot-03.png" width="300"> | <img src="../../assets/screenshots/screenshot-04.png" width="300"> |
| <img src="../../assets/screenshots/screenshot-05.png" width="300"> | <img src="../../assets/screenshots/screenshot-06.png" width="300"> |

---

## 👋 はじめに

学校生活は結構退屈で、普段から AI に聞きたいことがたくさんありました。
当時、App Store にある AI アプリは、値段が異常に高いか、機能が制限されすぎている（特に Watch 側）かのどちらかだったので、いっそ自分で作ってしまおうと思いました。

最初はわずか 1,800 行のコードで API Key もハードコーディングしていた粗末なバージョンでしたが、今では 155 個の Swift ソースファイルと 73,000 行超（Shared/iOS/watchOS とテストコードを含む）まで成長しました。"ETOS LLM Studio" という名前は少し大げさに聞こえるかもしれませんが、本質的には私が大規模言語モデル（LLM）アプリの可能性を探求するための実験場です。

現在では単なる Watch アプリにとどまらず、iOS 版のフル機能バージョンも実装しました。これでスマホでの設定管理やチャットもずっと快適になるはずです。

ただ、家族の方針であまりスマホを使わせてもらえないため、私は主に Mac と Watch を使用しています。その結果、スマホでの体験は……少し言いにくい部分があるかもしれませんが、できる限り最適化していくつもりです。私のコンピュータのシミュレータで iPhone を動かすのは本当に重いんです。

### 主な機能
*   **デュアルプラットフォーム・ネイティブ体験**：iOS と Apple Watch にネイティブ対応し、各画面サイズ向けに UI を最適化。
*   **マルチモデル対応**：OpenAI・Anthropic (Claude)・Google (Gemini) の API 形式にネイティブ対応。プロバイダ/モデル管理に加え、カスタムヘッダー・パラメータ式・生 JSON リクエストボディにも対応。
*   **ツールセンター + 拡張ツール**：MCP / Shortcuts / ローカルツールを統合管理。ツール有効化、承認戦略、セッション単位設定に加え、サンドボックスファイルツール（検索、分割読込、差分確認、部分編集、移動/コピー/削除）を提供。
*   **ローカル RAG (記憶)**：Embedding はクラウド API を使える一方、**ベクトル DB は完全ローカル (SQLite)**。分割、埋め込み進捗可視化、記憶編集、能動的な記憶検索ツールをサポート。
*   **MCP ツール呼び出し**：リモート [Model Context Protocol](https://modelcontextprotocol.io) に対応。MCP クライアント、Streamable HTTP/SSE 伝送、サーバ設定管理、再接続/タイムアウト/ハンドシェイク/能力交渉などの互換処理を実装。
*   **Worldbook**：SillyTavern の Lorebook に近い仕組み。条件発火、セッション分離送信、system 注入、URL インポートに対応し、PNG naidata / JSON トップレベル配列 / character_book 互換。
*   **リクエストログと速度分析**：独立したリクエストログ、詳細な Token 集計、ストリーミング応答速度の詳細グラフを搭載。
*   **ストレージ管理の強化**：アプリ内でサンドボックスファイルを閲覧・管理できるファイルマネージャを内蔵。
*   **Siri ショートカット**：Shortcuts フレームワーク統合。カスタムツールと URL Scheme ルーティングに対応。
*   **アプリ内フィードバックアシスタント**：フィードバック分類、環境情報収集、PoW 送信チェーン、デバイス間同期をサポート。
*   **マルチモーダル**：音声・画像入力に対応し、AI 画像生成もサポート。
*   **デバイス間同期**：iOS ↔ watchOS 同期エンジンで、プロバイダ設定・会話・Worldbook・ツール設定を自動同期。
*   **高度なレンダリング**：Markdown レンダラ内蔵。コードハイライト、表、LaTeX 数式に対応。
*   **LAN デバッグ**：PC ブラウザからアプリ内ファイル管理やリアルタイムデバッグログ確認が可能。
*   **ローカライズ**：英語、簡体字中国語、繁体字中国語（香港）、日本語に対応。

---

## 💸 料金とオープンソースについて

正直なところ、最初は無料ソフトにするつもりでした。
しかし、Apple Developer Program の年間 99 ドルという費用は、学生の私にとっては少し厳しいものでした。

その後、ある投資家の方がこの費用を立て替えてくれましたが、その代償として、ソフトウェアの収益でこの投資を返済（さらに利益分配も）することになりました。そのため、App Store 版では象徴的な料金をいただいています。これは借金返済のための「クラウドファンディング」であり、同時に「7日ごとの再署名が不要になる」便利サービスを買うものだと思っていただければ幸いです。

**しかし、オープンソースは私の譲れない一線です。**

現在のルールはシンプルです：
1.  **手間を省きたい/応援したい**：App Store でお会いしましょう。「コーラ代」をありがとうございます。
2.  **いじくり回したい/無料で使いたい**：コードはここにあります。GPLv3 ライセンスです。Mac と Xcode をお持ちなら、**完全に自分でコンパイルしてインストールできます。機能に違いは一切ありません**。

技術は共有されるべきです。数千円程度の壁が、同じようにコードに興味を持つあなたの邪魔をすることがあってはならないと思っています。

---

## 🛠️ 技術スタック

*   **言語**: Swift 6
*   **UI**: SwiftUI
*   **アーキテクチャ**: MVVM + Protocol Oriented Programming
*   **データ**: SQLite (ローカルベクトルストア), JSON (設定の永続化)
*   **ネットワーク**: URLSession (API リクエスト), Streamable HTTP/SSE (MCP 伝送)
*   **AI プロトコル**: Model Context Protocol (MCP)
*   **統合**: Siri Shortcuts, WatchConnectivity (デバイス間同期)
*   **依存管理**: Swift Package Manager（現在の明示的依存は `swift-markdown-ui`。推移的依存に `networkimage` と `swift-cmark` を含む）

---

## 🚀 コンパイルガイド

自分でビルドする場合：

1.  **プロジェクトを Clone**:
    ```bash
    git clone https://github.com/Eric-Terminal/ETOS-LLM-Studio.git
    ```
2.  **環境要件**:
    *   Xcode 26.0+
    *   watchOS 26.0+ SDK
3.  **プロジェクトを開く**:
    `ETOS LLM Studio.xcworkspace` を開いてください（xcodeproj ではなく **workspace**）。
    初回起動時に Swift Package 依存関係が自動で解決・取得されます。
4.  **実行**:
    `ETOS LLM Studio Watch App` または `ETOS LLM Studio iOS App` ターゲットを選び、デバイス（またはシミュレータ）を接続して Command + R を押します。
5.  **設定**:
    起動後、設定画面で API Key を追加してください。「LAN デバッグ」機能を使用して、作成した JSON 設定ファイルを `Documents/Providers/` ディレクトリに直接プッシュすることをお勧めします（Apple Watch の画面で API Key をポチポチ入力したい人なんていますか？）。

---

## 📬 連絡先

*   **開発者**: Eric Terminal
*   **Email**: ericterminal@gmail.com
*   **GitHub**: [Eric-Terminal](https://github.com/Eric-Terminal)

---

この README は 2026年3月7日（7907e83 の後）に改訂されました。ソフトウェアの更新は頻繁に行われる可能性があり、README が常に最新であるとは限りません。
