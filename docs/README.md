# HUDKit docs

Reading order for building a MacHUD app: AGENT-GUIDE, then CONTRACT, CLI and CONVENTIONS as
needed ([../llms.txt](../llms.txt) lists the same).

| Document | What it covers |
|---|---|
| [AGENT-GUIDE.md](AGENT-GUIDE.md) | The playbook for building a MacHUD app (for AI agents and people): decide, scaffold, the file map, a complete worked example (TallyHUD), hover vs windowed, `--snapshot`, isolation, the verification sequence, registering with MacHUD, pitfalls, definition of done |
| [CONTRACT.md](CONTRACT.md) | The canonical MacHUD app contract (0.1): manifest schema, socket location and framing, every verb with request/reply/error examples, `subscribe` events, settings schema, `docks.json`, hover/windowed behaviour and MacHUD's timings, file drops, what MacHUD guarantees, the compliance checklist |
| [CLI.md](CLI.md) | The `<repo>` CLIs: where they live, argument grammar, output and exit codes, `<REPO>_SOCKET`, each app's shorthands, raw `nc -U`, and `machud` |
| [CONVENTIONS.md](CONVENTIONS.md) | The layout every MacHUD app repo follows: names, targets, resources, env isolation, build/install shims, README sections, versions, commits, starting a new app, and where the current apps differ |
| [VOICEKIT.md](VOICEKIT.md) | VoiceKit, the voice product: wake word, trigger phrases, reply voices, voice settings, model downloads, and how its tests run |
| [../README.md](../README.md) | HUDKit itself: the types an app gets, the contract in brief, the dock, the settings schema, the glass chrome |
| [../CHANGELOG.md](../CHANGELOG.md) | HUDKit's releases |
| [../scripts/](../scripts) | `hud-build.sh`, `hud-install.sh`, `hud-new-app.sh`, `hud-icon.sh`, `hud-ci.yml` (usage in each script's header) |
| [../Templates/App](../Templates/App) | The app template `hud-new-app.sh` instantiates |
| [../.claude/skills/hudkit-app/SKILL.md](../.claude/skills/hudkit-app/SKILL.md) | The Claude Code skill: the condensed playbook and verification commands |
