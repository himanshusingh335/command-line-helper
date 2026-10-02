# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A zsh plugin (`clh.zsh`, sourced from `~/.zshrc`) that turns plain-English requests into shell commands using a local Ollama model. Runtime deps: `curl`, `jq`, `ollama`. There is no build step. `install.sh` checks the dependencies, pulls the model and appends the `source` line to `~/.zshrc`.

## Commands

```sh
zsh tests/test_sanitize.zsh            # unit tests, no model needed; exits 1 on any failure
./tests/eval.sh                        # sends sample requests to the real model (needs Ollama running)
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

`_clh_reset` clears all of these on every `line-init`. `_clh_precmd` is forced to the front of `precmd_functions` so that `$?` is the user's real exit code, which `::fix` needs.

**Model call pipeline.** `_clh_complete temp role content…` → prepends few-shot `_CLH_EXAMPLES` (alternating request/command pairs, converted by `_clh_example_turns`) → `_clh_chat` (builds the JSON with `jq`, POSTs to `$CLH_URL/api/chat` with `stream:false, think:false`) → `_clh_sanitize` (keeps the first non-empty line after removing code fences, a `$`/`%`/`>` prompt and backticks). Functions report errors as text on stderr and return non-zero. Widgets capture `2>&1` and show the result with `zle -M`.

**Prompt construction.** Each user message comes from a builder: `_clh_request_msg` (adds `_clh_context` with OS, cwd, the first 25 files, git branch and conda env, plus `_clh_hints`), `_clh_refine_msg` or `_clh_fix_msg`. `_clh_hints` adds targeted instructions for phrasings small models get wrong (currently "conda env in this folder" → `-p ./.conda`). The fix examples in `_CLH_EXAMPLES` use the exact wording that `_clh_fix_msg` produces. Keep the two in sync if you change that wording.

**Explain** uses its own system prompt and few-shots (`_CLH_EXPLAIN_SYSTEM`, `_CLH_EXPLAIN_EXAMPLES`). The ⚠ marker is not decided by the model. It comes from matching against `_CLH_DANGER_RE`, the same regex that colors destructive generated commands red.

**Ollama autostart.** `_clh_ensure_server` → `_clh_start_server` runs `ollama serve` only when `CLH_URL` is localhost/127.0.0.1/0.0.0.0. It detaches through `perl POSIX::setsid` so that Ctrl-C or closing the terminal doesn't kill the server, then polls `/api/version` for up to 60s. When a shell starts, a background `curl` warms the model (`CLH_WARM`).

## Conventions

- Target environment is zsh on macOS with BSD tools. The system prompt tells the model to avoid GNU-only flags, and the plugin code should avoid them too.
- Functions start with `emulate -L zsh` (plus `setopt extendedglob` where patterns need it). Internal names use the `_clh_` / `_CLH_` prefix. User config is `CLH_*`, set with `: ${VAR:=default}` defaults.
- Widgets and keybindings are registered only under `[[ -o interactive ]]`. This is why the tests can `source clh.zsh` and call functions directly.
- When you change model behavior (prompts, examples, hints, danger regex, parsing), add a check to `tests/test_sanitize.zsh` for the deterministic part, and add a case to `tests/eval.sh` for the model-dependent part.
