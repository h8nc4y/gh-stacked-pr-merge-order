# gh Stacked PR Merge Order（日本語完全版）

これは [`SKILL.md`](../SKILL.md)（英語・正典）の日本語完全版です。内容が食い違う
場合は英語版を優先し、修正 PR で両方を同期してください。

stacked PR のスタック — #A ← #B ← #C のように、子 PR の base が前段 PR の
head branch になっている連鎖 — を GitHub CLI で統合するとき、GitHub にスタック
の一部を auto-close させないための手順です。核心の危険: gh CLI / API 経由で
base branch を削除すると、子孫 PR が retarget されずにまとめて close されること
があり、そうして close された PR は retarget も reopen もできません。予防が
全てです。

## いつ使うか

- スタック最下段の PR を `gh pr merge --delete-branch` で merge したら、branch
  が消えた瞬間に子 PR が勝手に close された。
- `gh pr edit <n> --base <default>` が `Cannot change the base branch of a
  closed pull request` で失敗する。
- GitHub が自動 close した PR に対して `gh pr reopen <n>` が失敗する
  （例: `Could not open the pull request`）。
- これから PR の連鎖を gh CLI で統合するので、上記を全部回避できる順序を
  知りたい。
- branch protection 付きリポジトリで merge を「実行した」のに、branch 削除の
  後に PR が merged ではなく closed になっていた。
- docs 用の stacked PR に、無関係な feature commit が混ざっていた。

## なぜ起きるか

base branch が「どのように消えたか」で、その branch を base とする PR の扱い
が変わります（2026年7月時点の観測 — GitHub 側の挙動は変わる可能性があります）:

- **Web UI** から削除（merge 後の「Delete branch」ボタン）すると、子孫 PR は
  リポジトリの default branch へ自動で retarget される。
- **gh CLI / API** 経由で削除（`gh pr merge --delete-branch` を含む）すると、
  子孫 PR は retarget されずに close される挙動が観測されている。

この形で auto-close された PR は、その場では復旧不可能です（実測）:

- `gh pr edit <n> --base <default>` は `Cannot change the base branch of a
  closed pull request` で拒否される。
- `gh pr reopen <n>` も拒否される。

したがって規律は予防的です: **open な PR が base として使っている branch を、
決して消さないこと。**

## 安全な merge 順序

スタック #A ← #B ← #C を対象とします（#A の base は default branch、#B の
base は #A の head branch、#C の base は #B の head branch）。`<default>` は
`main` と決めつけず、`gh repo view <owner>/<name> --json defaultBranchRef -q
.defaultBranchRef.name` で取得してください。

また、最初の merge の前にリポジトリの自動削除設定を確認します:

```bash
gh repo view <owner>/<name> --json deleteBranchOnMerge
```

`deleteBranchOnMerge` が `true` の場合、`--delete-branch` を付けなくても
merge のたびにサーバ側が head branch を削除するため、以下の逐次手順では
最初の merge の時点で base branch が失われます。その場合は、何かを merge
する *前に* 全子孫を default branch へ retarget する（後述の一括着地の
順序）か、統合の間だけこの設定を一時的に無効化してください。auto-delete
が base を消したときに GitHub が子孫 PR をどう扱うかは、ここでは未検証
（untested）です — 依存しないでください。

1. 最下段の PR を **`--delete-branch` を付けずに** merge する:

   ```bash
   gh pr merge <A> --repo <owner>/<name> --merge
   ```

   merge 方式（`--merge` / `--squash` / `--rebase`）はリポジトリの流儀に
   合わせてください。重要なのは `--delete-branch` を付けないことです。

2. 次の操作へ進む前に、merge が本当に成立したことを確認する:

   ```bash
   gh pr view <A> --repo <owner>/<name> --json state,mergedAt
   ```

   `"state": "MERGED"` を必須とします。branch protection 付きリポジトリでは
   絶対に省略しないでください（後述のタイミング罠を参照）。

3. 次の PR を default branch へ retarget する:

   ```bash
   gh pr edit <B> --repo <owner>/<name> --base <default>
   ```

4. retarget 後に mergeable を確認する:

   ```bash
   gh pr view <B> --repo <owner>/<name> --json mergeable,mergeStateStatus
   ```

   `mergeable` が `CONFLICTING` なら、head branch 上でローカルに解消する:

   ```bash
   git fetch origin
   git switch <B-head-branch>
   git merge origin/<default>     # 衝突を解消して commit
   git push origin <B-head-branch>
   ```

5. #B を merge し（ここでも `--delete-branch` なし）、`MERGED` を確認して
   から、#C 以降も同様に「retarget → 確認 → merge」を繰り返す。

6. head branch の削除は、スタックの **全 PR** が `MERGED` になった後に、
   各 branch を base としても head としても使う open PR が残っていない
   ことを確認してから、まとめて行う（head 側の確認は、自動 MERGED 判定
   から漏れて open のままの PR を捕まえるため）:

   ```bash
   gh pr list --repo <owner>/<name> --base <branch> --state open   # 空であること
   gh pr list --repo <owner>/<name> --head <branch> --state open   # 空であること
   git push origin --delete <A-head> <B-head> <C-head>
   ```

経験則:

- スタックの内側では `--delete-branch` は禁止。他の PR が base に使っていない
  単発 PR でだけ使ってよい。
- 変更は一度にひとつ: merge のたびに state を確認してから、次の retarget や
  削除に進む。

## 代替手順: retarget 先行の一括着地

スタック全体を merge 1回で着地させる、実測済みの変種です:

1. まず、スタック内の open な PR を下から順に全て default branch へ retarget
   する: 各 PR に `gh pr edit <n> --repo <owner>/<name> --base <default>`。
2. tip の PR（スタック全 commit を head branch に含む最上段）だけを merge
   する — `--delete-branch` なしで。
3. GitHub が「他の PR の head commit が base に含まれた」ことを検出し、
   それらの PR を自動的に `MERGED` にする（2026年7月時点の観測）。

向いている場面: 純粋に加算的なスタック（各 PR の head が祖先の commit を
すべて含む）で、CI 1回・merge 1回で済ませたいとき。

注意点:

- retarget すると中間 PR の表示 diff が「default branch との累積 diff」に
  変わるため、その PR を見ているレビュアーには diff の形が変わって見える。
- 自動 `MERGED` 判定には、スタックの commit が default branch の祖先に
  なることが必要なので、tip は merge commit（`--merge`）で merge すること。
  `--squash` / `--rebase` では元の commit は祖先にならないため、包含 PR の
  自動判定は期待できない — これは git の意味論からの導出であり、実測は
  していない（untested）。
- merge queue との相互作用: untested。

## auto-close されてしまったら

まず失われたものを特定します: `"state": "CLOSED"` かつ `"mergedAt": null`
の PR は、内容が merge されないまま close されたものです。reopen は不可能
なので、supersede（後継 PR）で復旧します。

どの branch が消えたかは経路次第です。スタック内の branch 削除で close
された場合、消えたのは通常その PR の *base* branch で、head branch は
残っています。後述の branch protection 罠の場合、消えたのはその PR
*自身の head* です。何かを作る前に必ず確認します:

```bash
git ls-remote --heads origin <head-branch>   # ref が表示されること
```

head branch まで消えていたら、まずローカル clone か reflog から push で
復元します。その上で supersedes PR を作成します:

```bash
gh pr create --repo <owner>/<name> --head <same-head-branch> --base <default> \
  --title "<original title>" \
  --body "Supersedes #<closed-number>.

<original body>"
```

- 本文に `Supersedes #<closed-number>` と書くこと。close された PR の
  タイムラインから後継が辿れるようになります。
- レビュー承認は引き継がれません。リポジトリがレビュー必須なら再依頼して
  ください。
- 新 PR は上記の安全な順序で着地させます。

## branch protection のタイミング罠

branch protection（必須ステータスチェック）付きのリポジトリでは、チェック
完了前に試みた merge は成立しません — そしてスクリプトやループの中では、
その拒否を見落としやすい。現場で観測された危険な連鎖: merge 試行（拒否・
見落とし）→ branch 削除 → まだ open だった PR が auto-close。

規則: **merge → `MERGED` を確認 → それから削除**。ループ内でも毎回:

```bash
gh pr merge <n> --repo <owner>/<name> --merge
gh pr view <n> --repo <owner>/<name> --json state,mergedAt   # MERGED を必須に
# head branch の削除はこの後、かつスタック全体が着地してから
```

protection 付きリポジトリでは、上限付きポーリングでチェック完了を待つ
（`gh pr checks <n> --repo <owner>/<name> --watch=false` を試行回数上限つき
で繰り返す）か、`gh pr merge --auto`（要件が満たされた時点で merge）で
キューイングします。ただしスタックの内側で `--auto` と `--delete-branch` を
組み合わせるのは厳禁です — 遅延実行された merge が、誰も見ていない瞬間に
子孫の base branch を消します。

罠がすでに発動していたら、その PR は内容未 merge のまま closed です:
上記の supersedes PR でそのまま復旧してください。

## 混成スタックの分割

docs / refactor 用の stacked PR に無関係な feature commit が混ざっていた
場合、混ざったまま merge せず、スタックのその場書き換えもしないこと。
分割します（この方向で実測済み。逆方向 — feature PR に docs commit が
混入 — も手順は同じだが untested）:

1. default branch から新しい branch を切る。
2. 必要な commit だけを `git cherry-pick` する。
3. その branch から新 PR を作る。
4. 旧 PR は `Superseded by #<new-number>` とコメントして close する。

紛れ込んだ commit は旧 head branch 上に未 merge のまま残り、あとで適切な
スコープの PR が拾います。

## 状態スナップショット文書の衝突

可変状態のスナップショットである文書 — handoff ノート、タスクバックログ、
ステータスボードなど — はスタックの各層で編集されがちで、retarget や merge
のほぼ毎回で衝突します。

- 機械的に「新しい側（子孫側）」を採用して解消する。
- スタック途中で中間状態を手作りしないこと。スタックを着地させてから、
  統合後の現実に同期させる docs-only PR を最後に 1 本書く。

## 禁止事項 / 停止条件

- `gh pr list --base <branch> --state open` または
  `gh pr list --head <branch> --state open` が 1 件でも PR を返す branch
  を削除しない。
- スタックの内側で `--delete-branch` を使わない（`--auto` との併用も含む）。
- auto-close された PR に `gh pr edit --base` や `gh pr reopen` を再試行して
  結果が変わることを期待しない。直ちに supersedes 復旧へ進む。
- 状態スナップショットの衝突をスタック途中で中間状態の創作によって解消
  しない。新しい側を採用し、同期は最後に行う。
- 同一失敗クラスが 3 回試して改善しないなら、停止して報告する。コスト・
  secret・credential の停止条件は常に優先される。

## 完了チェックリスト

- スタックの全 PR が `MERGED` を報告している:
  `gh pr view <n> --repo <owner>/<name> --json state,mergedAt`。
- 削除予定のどの branch にも、それを base または head として使う open PR
  が残っていない: `gh pr list --repo <owner>/<name> --base <branch>
  --state open` と `gh pr list --repo <owner>/<name> --head <branch>
  --state open` が両方とも空。
- head branch の削除は上記 2 つの確認の後、最後にまとめて 1 回。
- superseded / auto-closed になった各 PR に、本文で
  `Supersedes #<n>` とリンクする後継 PR がある。
- スナップショット文書がスタック中に衝突していた場合、最後の docs-only PR
  で同期済み。

## 移植性

上記のコマンドはすべて `git` と `gh` であり、POSIX シェルでも PowerShell
でもそのまま動きます。複数行 `--body` の例は POSIX の行継続を使っている
ので、PowerShell では改行を埋め込む代わりに `--body-file <file>` を使って
ください。

## 報告

- 報告の冒頭にタイムスタンプ（日付・時刻・タイムゾーン明記）を付ける。
- 含めるもの: 着地させた PR の順序と最終 state、遭遇した衝突と解消方法、
  削除した branch と削除前の証拠（`MERGED` 状態と依存 PR 一覧が空である
  こと）、実施した supersedes 復旧、未解決の不明点。
- 観測していないプラットフォーム挙動を断定しない。未確認と明記する。

## 由来

複数リポジトリ・複数の stacked PR セットを実際にエージェント運用で着地
させた経験（実地のインシデント復旧を含む）から蒸留したものです — 上記の
全ルールは、観測された failure か検証済みの復旧に遡れます。GitHub 側の
挙動（CLI/API 削除が子孫を retarget せず close する、Web UI 削除は
retarget する、一括着地後の自動 MERGED 判定）は 2026年7月時点の観測で
あり、文書化された契約ではありません。依存する前に再検証し、予告なく
変わり得るものとして扱ってください。untested と明記した項目 —
squash / rebase 方式での一括着地の挙動、merge queue との相互作用 — は
実際には試していません。
