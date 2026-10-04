# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A shell plugin that turns plain-English requests into shell commands using a local Ollama model. Runtime deps: `curl`, `jq`, `ollama`. There is no build step. It comes in self-contained versions, one file per shell:

- `clh.zsh`: zsh on macOS, the reference version.
- `clh.bash`: bash 4+ on Linux, WSL and Git Bash. A function-by-function port with the same names, so the two files read side by side.
- `clh.ps1`: PowerShell (Windows first). Same function names, but no curl/jq: `Invoke-RestMethod`, `ConvertTo-Json`, and the example ranking reimplemented in PowerShell. Its prompts, examples, fix examples and danger regex are PowerShell-specific.

Installers: `install.sh` (POSIX sh, so it runs piped from curl under dash/ash/bash 3.2) detects the platform (`uname`), package manager and login shell, installs missing deps and Ollama, pulls the model and writes a `# >>> command-line-helper >>>` block into `~/.zshrc`/`~/.bashrc`, replacing an earlier block or the old-style `source` line. Without a checkout next to it, it downloads the repo tarball to `~/.local/share/clh/src`. `install-bash.sh` is a shim for `install.sh --shell bash`. `install.ps1` does the same for `$PROFILE`; it runs everything in a child scriptblock and throws instead of `exit` because `irm | iex` runs it in the user's session, and off Windows it calls `install.sh --ollama-only`. Test hooks: `CLH_OS`, `CLH_SRC_URL`, `CLH_OLLAMA_SCRIPT`.

A change to behavior in one version usually belongs in the others too.

## Commands

```sh
tests/run.sh                              # unit tests for zsh, bash and PowerShell + version sync; exits 1 on any failure
tests/run.sh unit zsh                     # one shell (zsh, bash, powershell)
tests/run.sh eval                         # sample requests through every version (needs Ollama running on the host)
CLH_MODEL=qwen3.5:4b tests/run.sh eval zsh  # compare another model (CLH_MODEL, CLH_EXAMPLE_MODE, CLH_EMBED_MODEL are passed through)
tests/run.sh bench -v                     # zsh only: scores CLH_EXAMPLE_MODE all/keyword/embed with accept patterns
tests/run.sh all                          # unit, eval and bench
tests/run.sh install                      # installers in stock distro images + install.ps1 on pwsh (fake Ollama)
tests/run.sh install --real               # adds a real Ollama install + model pull in Debian (~2 GB)
```

All tests, evals and benches run in Linux containers (Docker/OrbStack). The host only needs Docker, plus Ollama for eval/bench. The containers reach Ollama at `http://host.docker.internal:11434`. Each shell has a folder for its platform and an image in `tests/docker/`:

- `tests/zsh/` (macOS): `test.zsh`, `eval.zsh`, `bench_examples.zsh` in `clh-zsh`. The tools in the image are GNU, but nothing executes generated commands. A `sw_vers` shim makes `_clh_context` report macOS. The tests must stay portable between BSD and GNU, so use `zstat`, not `stat -f`.
- `tests/bash/` (Linux): `test.sh`, `eval.sh` in `clh-bash` (Debian, bash 5).
- `tests/powershell/` (Windows): `test.ps1`, `eval.ps1` in `clh-pwsh` (pwsh 7 on Linux). `eval.ps1` loads `clh.ps1` with `_ClhIsWindows` forced to true, so the model gets the Windows prompt. No container runs real Windows or Windows PowerShell 5.1: Windows containers need a Windows host, and dockur/windows needs KVM, which Docker on macOS lacks. Behavior specific to 5.1 has to be checked on a Windows machine.

The pwsh image is built from the official tarball for the host's architecture, because Microsoft's image is amd64-only and .NET segfaults under qemu on Apple Silicon. It also has zsh and jq, so `tests/test_sync.zsh` runs there, with zsh, bash 5 and pwsh side by side. That script compares `_clh_dump_data` output across versions: setting names/types/non-path defaults everywhere, and the request and fix examples between zsh and bash. It also feeds the zsh examples and a fixed history to `clh.ps1` and checks that it selects exactly what the jq ranking selects (keyword and all modes). System prompts differ per platform on purpose and are not compared.

`tests/install/` holds the installer tests. `check.sh` runs under plain `sh` in stock images (nothing preinstalled) and installs from the read-only checkout, re-runs, migrates an old-style hook, installs piped with a local tarball, and uninstalls. `fake-ollama` replaces Ollama (`serve` sets a flag, `list` fails until then, `pull` records the model); `fake-ollama-install.sh` stands in for Ollama's script and checks for the tools that script needs. The macOS path runs in `clh-install-macos` (Debian, `CLH_OS=macos`, `fake-brew`). Arch runs as linux/amd64 with pacman's `DisableSandbox`, which containers need.

For interactive checks, run the shell inside `tmux` in the container (`tmux send-keys`, `tmux capture-pane -p`). pwsh queries the cursor position, so a raw pty without a terminal emulator hangs.

There's no way to filter tests within a suite. To run one case, source the plugin and call the function directly (in the container: `docker run --rm -v $PWD:/clh clh-zsh zsh -c '…'`):

```sh
zsh -c 'source ./clh.zsh; _clh_sanitize "\$ docker ps"'
zsh -c 'source ./clh.zsh; local -a reply; _clh_parse "git log :: last 5"; print -l $reply'
```

The evals only print results; nothing is asserted. Read the output to judge it. The README's model-accuracy table (~21/25 for the default model) comes from `tests/zsh/eval.zsh`.

## Architecture (all in `clh.zsh`)

**Line classification → mode.** `_clh_parse` reads `$BUFFER` and sets `reply=(mode args…)`: `fix`, `explain <cmd>`, `new <request>`, `refine <cmd> <change>` or `run`. The prefix is `$CLH_PREFIX` (default `::`). For refine, the prefix needs whitespace on both sides, so `echo a::b` still runs normally, and the last ` :: ` on the line is the split point. The Enter widget `_clh_accept_line` dispatches on this mode.

**ZLE widgets & state.** Enter, Tab and Ctrl-N are rebound (`_clh_accept_line`, `_clh_tab`, `_clh_next`). Each one falls back to the default behavior (`.accept-line`, `expand-or-complete`, `down-line-or-history`) unless a generated command is pending. Pending state is held in globals:
- `_CLH_PENDING`: a generated command is on the line.
- `_CLH_TURNS`: the role/content pairs that produced it, ending in `assistant <cmd>`. Refine and Ctrl-N continue this conversation. Refine replaces the last assistant turn with the current buffer, so manual edits to the command are kept.
- `_CLH_SEEN`: commands already suggested, so Ctrl-N can ask for a different one.
- `_CLH_REQUEST`: the plain-English request behind the pending command (empty for `::fix` and for refining a typed command).

**Learning.** When Enter runs a pending command that has a `_CLH_REQUEST`, the pair (request, buffer as edited) goes into `_CLH_LEARN_PAIR`. `_clh_reset` does not clear it. `_clh_precmd` passes it to `_clh_learn` only if the exit status is 0. `_clh_learn` skips commands that match `_CLH_DANGER_RE`, appends JSON lines to `$CLH_HISTORY_FILE`, and dedupes/trims to `CLH_HISTORY_MAX` once the file grows past it.

`_clh_reset` clears all of these on every `line-init`. `_clh_precmd` is forced to the front of `precmd_functions` so that `$?` is the user's real exit code, which `::fix` needs.

**Model call pipeline.** `_clh_complete temp query role content…` → prepends few-shots from `_clh_select_examples query` → `_clh_chat` (builds the JSON with `jq`, POSTs to `$CLH_URL/api/chat` with `stream:false, think:false`) → `_clh_sanitize` (keeps the first non-empty line after removing code fences, a `$`/`%`/`>` prompt and backticks). `_clh_select_examples` builds a pool with `_clh_pool` (learned pairs, then the built-in `_CLH_EXAMPLES`), scores it with `_clh_rank_keyword` (IDF word overlap, written in jq in `_CLH_JQ_LIB`) or `_clh_rank_embed` (`/api/embed`, vectors cached in `embed-cache.jsonl` next to the history file), and picks examples according to `CLH_EXAMPLE_MODE`. `all` (the default) keeps every built-in example first and unchanged, so Ollama can reuse its prompt cache; learned matches go after them. `_CLH_FIX_EXAMPLES` are added when the last message ends with `_CLH_FIX_TAIL`. Functions report errors as text on stderr and return non-zero. Widgets capture `2>&1` and show the result with `zle -M`.

**Prompt construction.** Each user message comes from a builder: `_clh_request_msg` (adds `_clh_context` with OS, cwd, the first 25 files, git branch and conda env, plus `_clh_hints`), `_clh_refine_msg` or `_clh_fix_msg`. `_clh_hints` adds targeted instructions for phrasings small models get wrong (currently "conda env in this folder" → `-p ./.conda`). The fix examples in `_CLH_FIX_EXAMPLES` use the exact wording that `_clh_fix_msg` produces. Keep the two in sync if you change that wording.

**Settings and the `clh` command.** `_CLH_SETTINGS` (name, type, default, description) is the single list of user settings: it sets defaults at load, drives `clh set` validation (`_clh_check_value`: bool, int, str or `a|b|c`), and the help/config output. Load order: values set to a non-default before sourcing are recorded in `_CLH_PRESET` and win; then `$CLH_CONFIG_FILE` (written by `_clh_save_setting`) is sourced; then defaults fill the rest. `clh` dispatches to `_clh_help`, `_clh_config`, `_clh_settings_ui` (read/vared loop), `_clh_set`, `_clh_reset_setting`, `_clh_history`, `_clh_forget`. `_clh_parse` maps `::help`/`::settings` to mode `clh`, which replaces the buffer with `clh <word>` and accepts it. To add a setting, add one row to `_CLH_SETTINGS`; the help page, `clh config` and validation pick it up.

**Explain** uses its own system prompt and few-shots (`_CLH_EXPLAIN_SYSTEM`, `_CLH_EXPLAIN_EXAMPLES`). The ⚠ marker is not decided by the model. It comes from matching against `_CLH_DANGER_RE`, the same regex that colors destructive generated commands red.

**bash port specifics (`clh.bash`).** Readline can't make a `bind -x` handler decide whether the line is accepted, so Enter is a macro, `"\C-x}1\C-x}2"`. `\C-x}1` runs `_clh_accept_line`, which edits `READLINE_LINE` and rebinds `\C-x}2` to `accept-line` (run) or `redraw-current-line` (stay on the line). Tab and Ctrl-N are bound to their macros (`\C-x}3…4`, `\C-x}5…6`) only while a command is pending (`_clh_grab_keys`), then restored to the bindings recorded at load (`_CLH_ORIG_TAB/NEXT`). Routing them through a macro all the time would break readline's double-Tab detection. Bindings cover the emacs and vi-insert keymaps (Enter also covers vi-command). There is no `zle -M` and no buffer coloring: `_clh_status` (transient, `\r\e[K`) and `_clh_msg` (a line above the prompt) replace them. `_clh_precmd` is forced to the front of `PROMPT_COMMAND` (string or array), returns the saved `$?`, and also resets pending state, which stands in for zsh's `line-init`. `::fix` reads the last command with `history 1`, not `fc -ln -1`, because inside `bind -x` the latter skips the newest entry. `_CLH_OS` (linux/macos/gitbash) selects the platform rules in `_CLH_SYSTEM` and the install hints.

**PowerShell port specifics (`clh.ps1`).** State lives in `$global:` variables, and settings are `$global:CLH_*` strings. A setting is preset if `$env:CLH_X` or `$CLH_X` holds a non-default value when the file is dot-sourced. The Enter handler (`Set-PSReadLineKeyHandler`) reads the line with `GetBufferState`, edits it with `Replace`, and runs it by calling the key's original PSReadLine function through reflection (`_clh_call`). `_clh_grab_keys` binds Tab, Ctrl+N and Ctrl+C only while a command is pending and restores their built-in functions afterwards; keys bound to custom script blocks are left alone. Messages go through `_clh_msg`: clear the row, `Write-Host`, then `InvokePrompt($null, [Console]::CursorTop)` so the prompt is redrawn below the message instead of over it. The success of a command, used for learning and `::fix`, comes from `_CLH_BEFORE` (the newest `$Error` entry and history id when Enter was pressed), compared later with `Get-History`'s `ExecutionStatus`, `$Error[0]` and `$LASTEXITCODE` (native commands only). Nothing wraps `prompt`, so prompt themes don't interfere. PowerShell pitfalls this code avoids: `"$P?"` reads a variable named `P?`, so use `"${P}?"`; `[Array]::Sort(keys, items)` binds the generic overload and sorts a copy, so cast to `[Array]`/`IComparer`; functions return arrays with `, $x` so one-element and empty results survive.

**Ollama autostart.** `_clh_ensure_server` → `_clh_start_server` runs `ollama serve` only when `CLH_URL` is localhost/127.0.0.1/0.0.0.0. It detaches through `perl POSIX::setsid` (bash: `setsid -f`, else `nohup`) so that Ctrl-C or closing the terminal doesn't kill the server, then polls `/api/version` for up to 60s. When a shell starts, a background `curl` warms the model (`CLH_WARM`).

## Conventions

- Target environment is zsh on macOS with BSD tools. The system prompt tells the model to avoid GNU-only flags, and the plugin code should avoid them too.
- Functions start with `emulate -L zsh` (plus `setopt extendedglob` where patterns need it). Internal names use the `_clh_` / `_CLH_` prefix. User config is `CLH_*`, declared in `_CLH_SETTINGS` (not with `: ${VAR:=default}`).
- Widgets and keybindings are registered only under `[[ -o interactive ]]`. This is why the tests can `source clh.zsh` and call functions directly. `tests/zsh/test.zsh` unsets `CLH_*` and points `CLH_CONFIG_FILE` / `CLH_HISTORY_FILE` at a temp dir, so the user's saved settings and history never affect it.
- When you change model behavior (prompts, examples, hints, danger regex, parsing), add a check to the shell's `tests/<shell>/test.*` for the deterministic part, and add a case to its `tests/<shell>/eval.*` for the model-dependent part.
