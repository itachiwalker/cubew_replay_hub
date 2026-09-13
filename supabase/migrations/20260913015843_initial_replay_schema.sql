-- ============================================================================
-- リプレイ共有機能 - 初回マイグレーション
-- ============================================================================
-- このファイルは supabase/migrations/ 配下に置かれ、Supabase の GitHub連携
-- (Project Settings → Integrations → GitHub) によって、対象ブランチへの
-- push/merge時に自動適用される想定です。SQL Editorへの手動貼り付けは不要
-- です（むしろ、一度マイグレーション運用に乗せた後にSQL Editorで直接
-- スキーマを変更すると、マイグレーション履歴とズレる原因になるので避けて
-- ください。以後のスキーマ変更は、すべて新しいマイグレーションファイルとして
-- 追加してください）。
--
-- 設計方針まとめ（合意済みの内容）:
--   - 公開URLには "id" を含めない。SHA-256ハッシュの先頭16文字(64bit)だけを
--     公開の検索キーにする（replay_hash を PRIMARY KEY にする）。
--   - ハッシュの衝突（同じ16文字ハッシュ、でも中身のデータが違う）は
--     天文学的に低い確率だが、起きたら「保存できませんでした」という
--     エラーとして扱う（=データを上書きしない。安全側に倒す）。
--   - anon ロールには replays テーブルへの直接アクセス権限を一切与えず、
--     RPC関数の実行権限だけを与える（Supabase の REST API は Origin による
--     アクセス制限機能を持たないため、これが唯一の実効的な防御ライン）。
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. テーブル定義
-- ----------------------------------------------------------------------------
-- replay_hash: SHA-256の先頭16文字(16進数) を PRIMARY KEY として使う。
--   bigint の連番id は作らない（URLに件数が漏れる余地をそもそも無くすため）。
-- replay_data: リプレイ本体(JSON)。異常に大きいデータの投稿を防ぐため、
--   50KB を上限とする CHECK 制約を付けておく（キューブのリプレイなら
--   通常は数KB程度で収まる想定なので、十分な余裕を持たせてある）。
create table if not exists public.replays (
  replay_hash text primary key check (replay_hash ~ '^[0-9a-f]{16}$'),
  replay_data jsonb not null check (octet_length(replay_data::text) <= 51200),
  created_at  timestamptz not null default now()
);

-- 30日TTL削除ジョブ（下記4）が created_at で絞り込むため、インデックスを張っておく。
create index if not exists replays_created_at_idx on public.replays (created_at);


-- ----------------------------------------------------------------------------
-- 2. RLS / 権限
-- ----------------------------------------------------------------------------
-- RLSを有効化した上で、あえてポリシーを一切作らない。
-- → ポリシーが0件のテーブルは、テーブル所有者以外の全ロールに対して
--   デフォルトで全操作が拒否される。将来誰かが誤って GRANT してしまっても
--   このRLSが最終防波堤として機能する（多層防御）。
alter table public.replays enable row level security;

-- 念のため、テーブルへの直接権限も明示的に剥奪しておく。
-- （これにより anon / authenticated は REST API 経由で
--   /rest/v1/replays を直接叩いても何もできなくなる）
revoke all on public.replays from anon, authenticated;


-- ----------------------------------------------------------------------------
-- 3. RPC関数
-- ----------------------------------------------------------------------------

-- --- 3-1. upsert_replay: 保存処理 -------------------------------------------
-- 戻り値は jsonb で、以下のいずれかの status を返す:
--   {"status":"ok",        "hash": "<16文字のhash>"}  … 保存成功（新規 or 重複データの再利用）
--   {"status":"collision"}                              … 同じhashで別データが既に存在（天文学的低確率）
--   {"status":"invalid_hash"} / {"status":"invalid_data"} … 入力値の形式異常（不正利用対策）
--
-- INSERT ... ON CONFLICT DO NOTHING を使うことで、同時に同じリプレイが
-- 複数シェアされた場合の競合（レースコンディション）でも安全に動作する。
-- そのあとで実際にDBに入っている内容を読み直し、自分が送ったデータと
-- 一致するかどうかで ok / collision を判定している
-- （＝「新規保存できた」のか「既存データと完全に一致していた（重複）」のか
--   「既存データと食い違っている（衝突）」のかを、常に読み直した実データを
--   基準に正しく判定できる）。
create or replace function public.upsert_replay(p_hash text, p_data jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_stored_data jsonb;
begin
  if p_hash is null or p_hash !~ '^[0-9a-f]{16}$' then
    return jsonb_build_object('status', 'invalid_hash');
  end if;
  if p_data is null or octet_length(p_data::text) > 51200 then
    return jsonb_build_object('status', 'invalid_data');
  end if;

  insert into public.replays (replay_hash, replay_data)
  values (p_hash, p_data)
  on conflict (replay_hash) do nothing;

  select replay_data into v_stored_data
  from public.replays
  where replay_hash = p_hash;

  if v_stored_data = p_data then
    return jsonb_build_object('status', 'ok', 'hash', p_hash);
  else
    -- 既に別データがこのhashを占有している = 真の衝突。
    -- 自分のデータはINSERTされていない(ON CONFLICT DO NOTHINGにより
    -- 他者のデータを上書きしていない)ので、安全にエラーとして扱える。
    return jsonb_build_object('status', 'collision');
  end if;
end;
$$;

revoke all on function public.upsert_replay(text, jsonb) from public;
grant execute on function public.upsert_replay(text, jsonb) to anon;


-- --- 3-2. get_replay: 取得処理 -----------------------------------------------
-- hashそのものが主キー = 検索キーなので、「取得できた」こと自体が
-- 検証（＝改ざん・IDの当てずっぽうではない正規のデータ）を兼ねる。
-- 旧設計にあった「取得後にhashが一致するか確認する」処理は不要になった。
create or replace function public.get_replay(p_hash text)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select replay_data
  from public.replays
  where replay_hash = p_hash
  limit 1;
$$;

revoke all on function public.get_replay(text) from public;
grant execute on function public.get_replay(text) to anon;


-- ----------------------------------------------------------------------------
-- 4. 30日自動消去（pg_cron）
-- ----------------------------------------------------------------------------
-- 事前に Supabaseダッシュボード → Database → Extensions で
-- "pg_cron" を有効化しておいてください（下記commandでも有効化を試みます）。
--
-- 時刻はUTC基準です。"0 18 * * *" は 毎日 UTC 18:00 = JST 翌03:00 に実行、
-- という意味です（日本時間の深夜・アクセスが少なそうな時間帯を想定）。
create extension if not exists pg_cron;

select cron.schedule(
  'delete-old-replays',
  '0 18 * * *',
  $$ delete from public.replays where created_at < now() - interval '30 days'; $$
);

-- ジョブが正しく登録されたか確認したい場合は、以下を実行してください:
--   select * from cron.job where jobname = 'delete-old-replays';
-- 手動で今すぐ一度だけ動かして動作確認したい場合は、以下を実行してください:
--   delete from public.replays where created_at < now() - interval '30 days';
