# Private-marker scanner hardening

## 目的と影響

公開前の private-marker scan が、攻撃的または壊れた Git metadata、外部を指す
link、巨大入力、子 process の暴走によって「一部しか読めていないのに成功」と
判定しないことを正本要件とする。変更対象は scanner、process containment、
self-test、OSS readiness validation、CI matrix であり、stacked PR の利用手順や
skill 本文の意味は変更しない。

## 詳細設計

- caller から継承した全 `GIT_*` と Git config、hook、filter、attribute、
  transport、replace object、lazy fetch の影響を child process から除外する。
  既知・未知、値あり・空文字のいずれも同じく隔離する。
- Git repository では index blob と現在の regular worktree snapshot の和集合を
  scan する。intent-to-add、staged-only、unstaged-only、missing worktree を区別し、
  conflict、gitlink、symlink、reparse ancestor、root mismatch は fail closed とする。
- `git ls-files --stage` と `--debug` の raw bytes を snapshot 構築後と scan 後に
  再取得し、byte-level drift があれば成功を返さない。blob は 1 回の bounded
  `git cat-file --batch` stream で読む。
- Git が使えない非 repository fallback も hidden/dotfile を含める。
  scan root または ancestor の root-level `.git` file/directory は Git probe の
  曖昧さとして fail closed にする。fallback traversal 内の nested `.git`
  directory と leaf `.git` file、`node_modules`、`.cache` は control metadata
  として path segment 単位で除外し、内容や外部 target を follow しない。
  その他の link/reparse は曖昧なまま通さない。
- `.env` variants、`.pem`、`.key`、`.npmrc`、single-dot hidden name、
  extensionless text を候補に含める。local marker 設定は strict UTF-8、
  size/count/length 制限付きで読み、tracked または linked configuration を拒否する。
- entry、path segment、target、file bytes、total bytes、line、regex match、
  finding、Git process、stdout/stderr、deadline を有限にする。表示 path は
  control、bidi/format、logical line separator を escape し、実 OS newline と
  prefix を含めた 16 KiB の serialized byte cap 内で report を生成する。
- Windows は suspended child process を `CreateProcessW` で起動し、kill-on-close
  Job へ割り当て、標準入出力の必要 handle だけを継承させてから resume する。
  Job 割当または resume 前の失敗でも terminate/job close と wait の成否を確認し、
  suspended PID を残さない。
  POSIX は外部 `setsid` または gated `libc setsid(2)` で process group を作り、
  `kill(2)` の errno を確認して cleanup 完了を判定する。`$env:OS` は信用せず
  .NET runtime の platform 判定を使う。
- 日本語意図コメントを含む PowerShell source は UTF-8 with BOM とし、
  `.editorconfig` と readiness validator の先頭 3 bytes 検査で契約を固定する。

## 受け入れ条件と test plan

- Windows PowerShell 5.1 と PowerShell 7 で full self-test、readiness validation、
  repository scan が成功する。
- official Ubuntu PowerShell で同じ 3 command が成功する。macOS 実機は未確認で
  よいが、外部 `setsid` がない fallback を synthetic test で強制する。
- hostile nonexistent `-Path` は固定 code だけを出力し、raw absolute path、
  control/bidi/line separator を stdout/stderr へ漏らさない。
- ambient/unknown/present-empty `GIT_*`、index/worktree drift、ITA、conflict、
  link/reparse/gitlink、sensitive filename、hidden fallback、10 回の即時 descendant
  race、output/runtime caps を synthetic fixture で再現する。
- synthetic assign/resume failure では target PID の消滅、sentinel 非生成、
  bounded completion を確認する。
- CI は `windows-latest` と `ubuntu-latest` を 25 分で打ち切り、Windows job は
  PowerShell 7 と 5.1 の双方を実行する。
- AST parse、YAML parse、`git diff --check`、Gitleaks、Semgrep が成功する。

## Handoff

実装完了時は branch の source hash と staged tree hash を固定し、編集を止めて
P1/P2/P3 の独立 review を受ける。review で P1/P2/P3 が 0 になるまで commit、
push、PR、merge は行わない。検証済み OS/engine と未確認の macOS 実機を最終報告
で分ける。
