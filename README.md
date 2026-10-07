# Notch HUD

A Dynamic Island–style HUD around the MacBook notch for [Claude Code](https://claude.com/claude-code).
See at a glance what your sessions are doing, and answer their questions and permission requests
without switching back to the terminal.

- One glyph on each side of the notch: what the lead session is doing and how far along it is.
- Click it for every session: your prompts and Claude's replies, tasks, subagents at work.
- Questions and permission requests ring a bell; answer them right in the island.
- Type the next prompt in a session's card; stop a turn; jump to the session's terminal tab.

> **Disclaimer.** This mod is entirely AI-generated. I built it for myself, and I am not a developer,
> so expect rough edges. Any contributions — issues, fixes, ideas, pull requests — are welcome.
> Notch HUD is an independent project, not made or endorsed by Anthropic.

## Requirements

- macOS 15 or later on Apple Silicon (M1 or newer).
- Claude Code with plugin support.

On other systems (Windows, Linux, Intel Macs, older macOS) the mod installs, shows a one-time
notice and then does nothing: Claude Code works as usual.

## Install

```sh
claude plugin marketplace add skuvshin0v/notch-hud
claude plugin install notch-hud@skuvshin0v
```

Start a new Claude Code session (or restart the ones you have open). The mod launches the app at
the start of each session if it is not already running. It works in the terminal, in VS Code, and in
the Code tab of the Claude desktop app.

Update: `claude plugin marketplace update skuvshin0v`, then restart your sessions.

## Using it

**Collapsed**, the island is one glyph on each side of the notch and never changes width.

| Left: the lead session's state | Right: its progress |
| --- | --- |
| 🔔 needs you | `?` a question · 🔒 a permission waiting |
| the tool it is using (✎ edit, terminal, 🔍 search, 🌐 web, 👥 subagent…) | a ring for its tasks · `…` while it thinks |
| ⚠ error · ⏹ stopped · ✓ done | |

Small dots on the left glyph: orange or red when the session's usage limit passes 80% or 95%,
green when a session finished that you have not opened yet. After 30 seconds with nothing going on,
the island settles into a still, dim ✳︎.

**Open** it with a click. One row per session, the most recent event on top; click a row for its card:
the last five exchanges, Claude's reply rendered as Markdown (tables open in their own window), the
error that ended a turn, a slash command's output, tasks and subagents. Close it with ×, a click on
the empty header, a click anywhere else, or Esc.

- **Questions and permissions** asked while you are away from the session's app go to the island.
  The terminal shows an "Answer here" button to take one back.
- **Reply** in a session's card; while Claude works, the prompt is sent when the turn ends. Drafts are
  kept per session.
- **Stop** (on hover) ends the running turn, like Esc in the terminal.
- **↗** brings forward the session's app; in Terminal and iTerm2 it selects the session's tab (macOS
  asks for Automation permission once). Background sessions (`/bg`, agents) have no tab to jump to.
- **Hide** a session (👁 on hover) until it next needs you.
- **Settings** (gear): always show the island, always send questions to it, sounds, language
  (English / Русский), show hidden sessions, quit. There is no menu bar icon.

## What it does on your Mac

- The mod and the app talk through files in `~/.claude/notch-hud/` (session state, your answers,
  follow-up prompts, Stop, the app's heartbeat). Nothing leaves your machine; neither part makes
  network requests of its own.
- The app is a small native SwiftUI app shipped inside the plugin (`plugin/notch-hud/app`). It is
  built from `widget/Sources/main.swift` and ad-hoc signed, not notarized by Apple. Installing through
  Claude Code (git) does not quarantine it, so macOS opens it without a warning.
- If the app is not running, the mod changes nothing about how Claude Code behaves.

## Uninstall

```sh
claude plugin uninstall notch-hud@skuvshin0v
claude plugin marketplace remove skuvshin0v
```

Then quit the app (Settings → Quit) and, if you like, remove `~/.claude/notch-hud/`.

## How it works

| Part | Where | What it does |
| --- | --- | --- |
| Mod `notch-hud` | `plugin/notch-hud/hooks/register.tsx` | Claude Code function hooks: publishes the session state, routes `AskUserQuestion` and permission requests to the app, takes answers, prompts and Stop back |
| App Notch HUD | `widget/Sources/main.swift` | The island: a borderless panel at the notch, above the menu bar |

```
~/.claude/notch-hud/
  sessions/<sid>.json         session state (the mod, heartbeat every 5 s)
  answers/<sid>/<ask>.json    an answer to a question or permission (the app)
  inbox/<sid>.json            a prompt typed in the app
  stop/<sid>                  Stop pressed in the app
  presence.json               the app's heartbeat, the frontmost app, sessions you are away from
  limits.json                 the account's usage windows (the mod)
```

## Contributing

Issues and pull requests are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE)
