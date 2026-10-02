# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A zsh plugin (`clh.zsh`, sourced from `~/.zshrc`) that turns plain-English requests into shell commands using a local Ollama model. Runtime deps: `curl`, `jq`, `ollama`. There is no build step. `install.sh` checks the dependencies, pulls the model and appends the `source` line to `~/.zshrc`.

## Commands

```sh
zsh tests/test_sanitize.zsh            # unit tests, no model needed; exits 1 on any failure
./tests/eval.sh                        # sends sample requests to the real model (needs Ollama running)
zsh tests/bench_examples.zsh -v        # scores CLH_EXAMPLE_MODE all/keyword/embed with accept patterns
CLH_MODEL=qwen3.5:4b ./tests/eval.sh   # compare another model
```

There's no test runner and no way to filter tests. To run one case, source the plugin and call the function directly:

```sh
zsh -c 'source ./clh.zsh; _clh_sanitize "\$ docker ps"'
zsh -c 'source ./clh.zsh; local -a reply; _clh_parse "git log :: last 5"; print -l $reply'
```

`eval.sh` only prints results; nothing is asserted. Read the output to judge it. The README's model-accuracy table (~21/25 for the default model) comes from this script.

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

**Ollama autostart.** `_clh_ensure_server` → `_clh_start_server` runs `ollama serve` only when `CLH_URL` is localhost/127.0.0.1/0.0.0.0. It detaches through `perl POSIX::setsid` so that Ctrl-C or closing the terminal doesn't kill the server, then polls `/api/version` for up to 60s. When a shell starts, a background `curl` warms the model (`CLH_WARM`).

## Conventions

- Target environment is zsh on macOS with BSD tools. The system prompt tells the model to avoid GNU-only flags, and the plugin code should avoid them too.
- Functions start with `emulate -L zsh` (plus `setopt extendedglob` where patterns need it). Internal names use the `_clh_` / `_CLH_` prefix. User config is `CLH_*`, declared in `_CLH_SETTINGS` (not with `: ${VAR:=default}`).
- Widgets and keybindings are registered only under `[[ -o interactive ]]`. This is why the tests can `source clh.zsh` and call functions directly. `test_sanitize.zsh` unsets `CLH_*` and points `CLH_CONFIG_FILE` / `CLH_HISTORY_FILE` at a temp dir, so the user's saved settings and history never affect it.
- When you change model behavior (prompts, examples, hints, danger regex, parsing), add a check to `tests/test_sanitize.zsh` for the deterministic part, and add a case to `tests/eval.sh` for the model-dependent part.
