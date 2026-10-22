# Spectrum Party — secure online prototype

A Japanese, responsive Spectrum/Wavelength-inspired party game. This version uses Supabase RPCs for server-validated room actions and keeps the unrevealed target in a separate table that browser clients cannot read directly.

## Requirements

- Node.js LTS
- A Supabase project
- GitHub + Vercel for deployment (optional until local testing passes)

## 1. Configure Supabase

1. Create a project at https://supabase.com/.
2. Open **SQL Editor → New query**.
3. Copy the entire `supabase/schema.sql` file into the editor and click **Run**.
4. In the Supabase project Connect / API settings, copy the Project URL and the **publishable key** (or legacy anon key). Never use a secret/service-role key in the browser.

## 2. Configure the app locally

1. Copy `.env.example` to `.env.local`.
2. Fill in `VITE_SUPABASE_URL` and `VITE_SUPABASE_PUBLISHABLE_KEY` (or use `VITE_SUPABASE_ANON_KEY` for a legacy anon key).
3. In a terminal opened in this project folder, run:

   ```cmd
   npm.cmd install
   npm.cmd run dev
   ```

4. Open the URL printed by Vite, usually http://localhost:5173.

## 3. Test multiplayer

1. Open the local URL in two different browsers or one normal and one private window.
2. In the first, create a room. Copy the four-character room code.
3. In the second, enter a different name and join that code.
4. Send the code to friends after deploying. Game state is polled from Supabase every 1.5 seconds.

## 4. Deploy to Vercel

1. Upload this folder to a GitHub repository.
2. Import the repository at https://vercel.com/.
3. In Vercel Project → Settings → Environment Variables, add:
   - `VITE_SUPABASE_URL`
   - `VITE_SUPABASE_PUBLISHABLE_KEY` (or `VITE_SUPABASE_ANON_KEY`)
4. Redeploy after adding environment variables.
5. Test with two devices.

## Security and scope

- The public game state contains no unrevealed target.
- Direct browser writes to the game table are revoked. State mutations run through SECURITY DEFINER PostgreSQL functions that check room membership, phase, host permissions, clue-giver permissions, and scoring.
- Secret targets are in a separate RLS-enabled table with no client grants. `spectrum_get_room` returns the target only to the current clue-giver during the clue phase.
- This is still a small, unauthenticated party-game prototype, not a hardened commercial service. Player IDs are generated in the browser and act as room capabilities; someone who steals a player's ID could impersonate them. There is no moderation, account system, rate limiting, or automatic stale-room cleanup. Do not use it for sensitive data or expose secrets. For a public launch, add Supabase Auth, server-issued membership tokens, rate limiting, and room expiry.
- All connected clients poll every 1.5 seconds. This is intentionally simple; Supabase Realtime can be added for lower latency and larger rooms.

## 5-round match and ranking

Each game ends automatically after the fifth reveal. The final screen sorts players by total score (descending); ties share the same rank. The host can start another five-round match and reset scores. Re-run the updated `supabase/schema.sql` in the SQL Editor if you used an earlier version.

## Screen flow

1. Login: enter a nickname (guest login, **not** Supabase Auth).
2. Lobby: create/join a room, share its code, and wait for at least two players. Only the host can start.
3. Game: five rounds, then total-score ranking. Host can restart, returning everyone to the waiting room.

If updating an existing Supabase project, run the new `supabase/schema.sql` again. Existing rooms created before the update may need to be recreated.

Leaving a room removes the player server-side and clears the saved browser session. See the reconnect/leave section below.

## Individual answers (new)

After the clue-giver sends a hint, **every other player gets their own 0–100 slider and numeric input**. Each response is stored separately in `spectrum_player_guesses` and can only be submitted once per player and round. While guessing, other players can see only who has answered (not their numbers); their own submitted number stays visible to them via a private RPC field. The clue-giver waits.

When **all eligible players** have answered, the server automatically changes the phase to the reveal waiting screen. Only the host can publish the answer. The server then awards **individual points** based on absolute distance to the hidden target: within 3 → 4 points, 7 → 3, 12 → 2, 20 → 1, otherwise 0. The clue-giver does not score that round. After 5 rounds, results are sorted by each player's total score.

### IMPORTANT: Existing Supabase database

Run the *entire updated* `supabase/schema.sql` in SQL Editor again before trying this version. The migration adds the `spectrum_player_guesses` table and replaces the RPC functions. Create a **new room** after updating because old rooms use a different public state structure. Deploy the updated web files only after applying SQL. A stale backend still expects one shared guess and will not support this feature.

### Quick 3-user scenario test

1. Log in on three different browsers/devices, join a new room, and start.
2. Host (as clue-giver in round 1) sends a hint.
3. Players B and C each see their own slider. B submits 25; C should remain able to choose their own answer. B sees `1 / 2` and the number 25 on their own screen.
4. C submits 80; all devices go to reveal waiting. B and C cannot change their votes.
5. Host publishes answer. Check B/C's separate predictions and scores. Test the next round, another clue-giver, and the final ranking after round 5.

The app still uses temporary guest IDs rather than account-based identity: for fully public commercial hosting, add authentication and abuse protection. Browser reload restores the saved player ID and room from localStorage. The game polls the backend every 1.5 seconds.

The initial target is generated by PostgreSQL on room creation (the legacy `p_target` argument is ignored for compatibility).

## Scoring update

Exact guess (distance 0): 5 points; distances 1–3: 4; 4–7: 3; 8–12: 2; 13–20: 1; 21+: 0. The clue-giver earns the rounded arithmetic mean of all guessers’ round points, with .5 rounded up. This is calculated inside the server-side reveal transaction. Re-run `supabase/schema.sql` in the Supabase SQL Editor to update the RPC.

## ブランド更新

ゲーム名を「ドノヘン？」に変更しました。ログイン・ロビー・ゲーム・最終ランキングの文字やカラーパレットを統一し、SVG favicon を追加しました。採点と Supabase schema.sql は前バージョンから変更していません。以前のプロジェクトに上書きする場合、`.env.local` はそのまま保持してください。

## 画面遷移（3画面）

1. 入口画面：ニックネーム入力＋「部屋を作る」または「コードで参加」。
2. 待機部屋：ルームコード、参加者、ホストを表示。2人以上集まるとホストが「5ラウンドのゲームを開始」を押せる。
3. ゲーム画面：ホストが開始すると参加者全員に反映。ヒント→各自予想→結果→全5戦のランキング。

既存のSupabase `schema.sql` はホスト専用 `start` アクションと `lobby` 状態を含みます。既に直近版をセットアップ済みならSQLの再実行は不要です。

## お題100種類（厳選版）

元の200種類から、具体的なヒントを出しやすい100種類を厳選しました。`src/prompts.ts` がゲーム内データで、全一覧は `お題一覧_100種類.md` にあります。両者は同じ内容・順番です。左右の文言は元データから変更していません。

`promptHistory` を使った候補除外と、サーバー側の重複チェックを維持しているため、同じ5戦ではお題が重複しません。お題データ・説明書の更新に加え、ビルドを通すための型設定を修正しました（tsconfig.app.json に vite/client を追加、tsconfig.node.json の未対応オプション erasableSyntaxOnly を削除）。依存関係を固定する package-lock.json も追加しています。入口画面から接続設定とメール認証なしの説明文を削除しました。通信・採点・退出・復帰・SQL処理は変更していません。既に途中退出・復帰版のSQLを適用済みなら、この更新によるSQL再実行は不要です。新しいルームで開始してください。

## 途中退出とリロード復帰

- 同じブラウザの通常タブで再読込すると localStorage の保存済みルームコード・プレイヤーIDを使って自動復帰します。点数・回答状態・ヒント役・ホスト権限をサーバーから再取得します。
- 「ルームから退出する」はDB側で参加者を削除し、ブラウザ内の復帰情報を削除します。退出後は同じIDでは復帰できません。
- ホストが退出したときは、残った参加者の先頭にホスト権限が移動します。
- ヒント役が回答前または回答中に退出した場合、そのラウンドのみやり直しになります（進行中の回答は破棄）。
- 回答者が途中退出した場合、残った回答者が全員回答済みなら発表待ちへ進みます。
- 残り1人になると待機部屋に戻ります。再開時には5戦を最初から開始し、得点はリセットされます。
- ブラウザを閉じただけでは「退出」扱いにしません。通信切断を即時に退出と判定すると、再読込時の復帰ができなくなるためです。
- **新しいSQLファイルをSupabase SQL Editorで全実行してください。**
- 注意：ゲストIDをブラウザに保存する方式であり、アカウント認証ではありません。ブラウザのデータ消去・シークレットモード終了・別端末からのアクセスでは復帰できません。また本番向けには本人確認・一定期間不在の自動処理・ルーム期限管理が必要です。


