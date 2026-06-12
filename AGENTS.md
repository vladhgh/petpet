# AGENTS.md

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository.

## What this is

PetPet is a personal macOS desktop mascot: a tiny floating sprite that animates to reflect what a Codex session is doing. It's a single-user hobby project — keep changes small and direct, don't add abstraction or config layers it doesn't need.

## Commands

All control goes through `petpetctl.sh`:

```sh
./petpetctl.sh build      # recompile PetPet.swift (compiles + re-signs — see note below)
./petpetctl.sh start      # launch (nohup, logs to /tmp/petpet.log)
./petpetctl.sh restart    # stop + start (does NOT rebuild)
./petpetctl.sh stop
./petpetctl.sh status
./petpetctl.sh pet <slug> # switch sprite + auto-restart
./petpetctl.sh scale <n>  # resize + auto-restart
./petpetctl.sh state <x>  # force an animation state for testing (writes event.json)
./petpetctl.sh editor     # open the state editor (serves state-editor.html, writes states.json)
./petpetctl.sh pets       # list installed pets
```

There are no tests. To verify a change: `build` then `restart`, watch the pet, and `tail -f /tmp/petpet.log` for crashes.

**`build` must move a fresh binary into place, never overwrite in-place.** It compiles to `petpet.tmp`, code-signs it, then `mv`s it over `petpet`. Overwriting the existing inode makes the kernel's cached code signature mismatch and launchd kills the process with `OS_REASON_CODESIGNING`. Keep that pattern if you touch the build step.

## Architecture

Two halves that communicate **only through JSON files** in this directory — no sockets, no IPC. This file-based decoupling is the core design: the hook never talks to the app directly.

1. **`PetPet.swift`** — the whole GUI app (AppKit, single file, ~700 lines). It polls the JSON files every 0.2s by mtime and renders. It never writes state files; it only reads them (plus `config.json`, which it owns).

2. **`petpet-hook.py`** — translates Codex hook events into mascot state. `petpet-hook.sh` is a thin wrapper so `settings.json` can pass a stable event name (`user-prompt`, `pre`, `post`, `notify`, `stop`, `session-start`, `session-end`) while preserving stdin. The hooks are wired in `~/.Codex/settings.json`, not in this repo.

### The JSON contract (how the two halves meet)

- **`config.json`** — persistent settings: `pet`, `scale`, `x`, `y`. Written by the app (on drag/resize) and by `petpetctl`. This one is tracked in git; the other JSON files are not.
- **`event.json`** — `{"state", "sleep", "title", "status", "color", "detail", "ttl", "sleep_after"}`. Animation state + bubble card in one file. `ttl` seconds to show the card; `ttl: 0` = sticky until the next event. Optional `sleep_after`: seconds to keep the card before the pet dozes off (used by a just-finished session to linger on "Готово" before sleeping).
- **`session.json`** — the hook's per-session bookkeeping. Each session stores its own latest render (`phase`/`state`/`card`); the hook recomputes `event.json` by picking whichever session wins on `phase` priority (waiting > working > ready > finished > idle). So a session that just started or finished never steals the bubble from one still working, and the pet sleeps only when *every* session is idle.
- **`states.json`** — optional override table read by the hook: `{ "<trigger-key>": {"state","status","color","code"} }`. Each `render()` call in the hook tags itself with a trigger key (`session-start`, `user-prompt`, `Bash`, `Read`, `Grep`, `Web`, `Edit`, `Write`, `Task`, `TodoWrite`, `mcp`, `AskUserQuestion`, `ExitPlanMode`, `notify`, `stop`, `post-error`, `idle`); a present field overrides that trigger's animation/text/color (`detail` stays dynamic). Missing file or key → built-in defaults. Authored by **`state-editor.html`** (a standalone editor served by `petpet-editor.py` via `./petpetctl.sh editor`), which writes only the diff from defaults; its **▶ На петомце** button writes `event.json` for an instant on-pet preview. Gitignored.

`config.json`, `event.json`, `session.json`, `states.json`, and the compiled `petpet` binary are gitignored — they're runtime artifacts. Source under version control is `PetPet.swift`, the two hook scripts, `petpetctl.sh`, `petpet-editor.py`, and the two HTML tools (`sprite-viewer.html`, `state-editor.html`).

### Animation model

Sprites are 8-col × 9-row spritesheets reused from Codex/petdex (`~/.codex/pets/<slug>/` or `~/.petdex/pets/<slug>/`). `ANIMS` in `PetPet.swift` maps each state name to a row + per-frame timings. State resolution priority lives in `resolvedState()`: physics toss > agent state > autonomous idle behavior > plain idle. The pet does not react to plain hover (drag still moves/tosses it). When adding a state, add it to `ANIMS` *and* have the hook emit it in `event.json`. Which animation each trigger plays (plus its status text/color) can be remapped at runtime via `states.json` — see the editor under the JSON contract above. If you add a trigger key or animation, mirror it in `state-editor.html`'s `DEFAULTS`/`ANIMS` so the editor stays in sync.

Hook status text (the bubble) is in Russian — match that when editing `petpet-hook.py`.

### Disabling

Drop a file named `hooks-disabled` in this directory to make the hook no-op without editing `settings.json`.

## Задачи и бэклог

Задачи хранятся в **Apple Reminders, список «PetPet»**. Посмотреть:

```sh
remindctl list PetPet
```

Каждая задача содержит в notes: контекст (что сейчас), желаемое поведение, критерий готовности.

**Когда берёшь задачу в работу** — отметь её в Reminders как выполненную когда сделаешь:

```sh
remindctl complete <id>
```

**Когда появляется новая идея** — добавляй сразу, пока не забыл:

```sh
remindctl add --list PetPet --title "Короткое название" --notes "Контекст: ...
Что хочу: ...
Готово когда: ..."
```
