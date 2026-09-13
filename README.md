# cubew_replay_hub

[cubew](https://github.com/itachiwalker/cubew)（ルービックキューブアプリ）の「リプレイ共有」機能用の、リプレイデータ保存・中継サーバです。Supabase (PostgreSQL) 上で動作し、このリポジトリはそのスキーマ定義（マイグレーション）のみを管理します。アプリ本体のコード（`my_cube-base.html`）とはライフサイクルが異なるため、別リポジトリとして分離しています。

## 仕組み

- ユーザーがアプリ側で「リプレイをシェア」すると、リプレイデータのSHA-256ハッシュ（先頭16文字）を計算し、`upsert_replay` RPCで保存
- 共有URLは `https://<アプリのURL>/#s=<16文字のhash>` の形式（連番IDは公開URLに含めない。ハッシュそのものが検索キー）
- リンクを開いた側は `get_replay` RPCでハッシュから直接データを取得
- 保存から30日経過したデータは `pg_cron` により毎日自動削除
- `anon`ロールにはテーブルへの直接アクセス権限を一切与えず、RPC関数の実行権限のみを付与（Supabaseの REST API は Origin ベースのアクセス制限機能を持たないため、これが唯一の実効的な防御ライン）

設計の背景・検討経緯は、開発チャット（Claude.ai）側のログを参照してください。

## ディレクトリ構成

```
supabase/
├── config.toml           # `supabase init` で生成された設定（ローカル開発用。通常は編集不要）
└── migrations/
    └── *_initial_replay_schema.sql   # テーブル・RLS・RPC関数・pg_cronジョブ一式
```

## デプロイ方法

このリポジトリは、Supabaseの「GitHub連携」機能（Project Settings → Integrations → GitHub）に接続されています。`main`ブランチへのpush/mergeで、`supabase/migrations/`配下の未適用マイグレーションが自動的に本番プロジェクトへ適用されます。

**重要**: 一度マイグレーション運用に乗せた後は、Supabaseダッシュボードの SQL Editor で直接スキーマを変更しないでください。マイグレーション履歴とズレて`db push`が失敗する原因になります。スキーマを変更する場合は、必ず新しいマイグレーションファイルを追加してください。

```bash
# ローカルで新しいマイグレーションを作る場合
supabase migration new <変更内容がわかる名前>
# 中身を書いたら、コミットしてpushするだけで自動デプロイされる
```

## RPC API（フロントエンド向け契約）

### `upsert_replay(p_hash text, p_data jsonb) returns jsonb`

リプレイを保存する。戻り値の`status`で結果を判定する:

| status | 意味 |
|---|---|
| `ok` | 保存成功（新規、または既存の完全一致データを再利用）。`hash`フィールドに16文字のhashが入る |
| `collision` | 同じhashで別データが既に存在（天文学的低確率の衝突）。保存されない |
| `invalid_hash` / `invalid_data` | 入力値の形式が不正 |

### `get_replay(p_hash text) returns jsonb`

`p_hash`（16文字の16進数文字列）に対応するリプレイデータを返す。存在しなければ`null`。

---

フロントエンド側の実装（ハッシュ生成・呼び出しロジック、9言語対応のエラーメッセージ）は、アプリ本体側リポジトリの `replay-share-client.js` を参照してください。
