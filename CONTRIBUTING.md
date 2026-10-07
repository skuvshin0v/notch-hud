# Contributing

Thanks for helping. Bug reports, ideas and pull requests are all welcome.

## Reporting a bug

Open an issue with the bug template. Say what you did, what you expected and what happened, and
include your macOS version, Mac model and `claude --version`. A screenshot of the island helps a lot.

## Development setup

You need macOS 15+ on Apple Silicon, Xcode Command Line Tools (`xcode-select --install`), Claude Code
and Python 3 (for the demo).

```sh
git clone https://github.com/<you>/notch-hud && cd notch-hud
./widget/build.sh                         # build the app into plugin/notch-hud/app
claude --plugin-dir plugin/notch-hud      # a Claude Code session with your local mod
```

If you also have the marketplace version installed, disable it while you work, or both will run:
`claude plugin disable notch-hud@skuvshin0v`.

Only one copy of the app runs at a time. After rebuilding, quit the running one (Settings → Quit) and
open `plugin/notch-hud/app/Notch HUD.app`.

### Trying the island without real sessions

```sh
python3 scripts/demo.py states     # every look of the island, step by step (Enter to go on)
python3 scripts/demo.py parallel   # a session finishing while another works
python3 scripts/demo.py            # questions, a permission request, a follow-up prompt
```

Type a line and press Enter during a demo to note something about the current step; notes go to
`demo-feedback.md` (ignored by git).

## Before you open a pull request

```sh
./widget/build.sh                                   # no errors and no warnings
claude plugin validate plugin/notch-hud && claude plugin validate .
claude plugin test plugin/notch-hud                 # the mod's tests
```

CI runs the same checks on every pull request.

- **Do not commit the built app** (`plugin/notch-hud/app/`). It is rebuilt for each release; binary
  changes in pull requests only cause conflicts.
- Keep one topic per pull request, and describe what changes for the user.
- Everything the app shows goes through `tr("English", "Русский")`. Text the mod writes is English;
  the app translates it in `modText`.
- The mod's API is described by the types Claude Code lays into
  `plugin/notch-hud/.claude-plugin/types/` when it loads the mod from a folder. The API is in early
  access and can change between Claude Code versions.
- Match the style of the code around your change.

## Releases

The maintainer bumps the version in `plugin/notch-hud/.claude-plugin/plugin.json`, rebuilds the app,
tags `vX.Y.Z` and publishes a GitHub release. Users update with
`claude plugin marketplace update skuvshin0v`.

By contributing you agree that your contributions are licensed under the MIT License.
