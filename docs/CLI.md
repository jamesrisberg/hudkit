# MacHUD app CLIs

Every MacHUD app ships a small command-line client named after its repo (`scratch`, `sift`,
`stash`, `tallyhud`, ...) that sends one command over the app's control socket and prints the
JSON reply. `machud` does the same for MacHUD itself and can drive every app through MacHUD. The
socket protocol underneath is specified in [CONTRACT.md](CONTRACT.md#socket).

## Where the CLI lives

| | |
|---|---|
| Source | `Sources/<Product>CLI/main.swift`, an executable target depending on HUDKit |
| In the bundle | `<Product>.app/Contents/Helpers/<repo>`: `hud-build.sh` copies the `<Product>CLI` product there, named after the manifest's `socket`. Not `Contents/MacOS`, where `sift` and `Sift` would be the same file on a case-insensitive volume |
| Dev build | `build/<Product>.app/Contents/Helpers/<repo>` after `./build.sh` |
| On PATH | `./install.sh` (`hud-install.sh`) symlinks `/Applications/<Product>.app/Contents/Helpers/<repo>` into the first writable directory that is on `PATH`, trying `/opt/homebrew/bin`, `/usr/local/bin`, `~/bin`, `~/.local/bin`, then the rest of `PATH` in order. It prints `Installed ... and <link>`, or warns when no directory qualifies |

An app with nothing worth a CLI may omit the target; `hud-build.sh` then ships no helper.

## Grammar

```
<repo> <command> [key=value | word] ...
```

The first argument is the socket command (`hello`, `state`, `help`, `quit`, `panel`, `settings`,
`action`, and in apps with menu bar consolidation `menu`, `menu-invoke`) or an app shorthand. The rest become the request's `args` through
`HUDSocketClient.parseArguments`:

| Argument | Becomes | Example |
|---|---|---|
| `key=value` | `"key": "value"`, split at the first `=` (the value may contain `=`) | `text=a=b` → `"text": "a=b"` |
| `word` (no `=`) | `"word": "1"` | `panel show` → `"show": "1"` |
| the first bare word | also `"_": "<word>"` | `action bump by=2` → `{"_": "bump", "bump": "1", "by": "2"}` |
| a repeated key | the last one wins | |

Everything is a string. The router reads `_` as the sub-verb: `panel show id=main` is `panel`
with `action=show`, `action bump` is the action `bump`, `settings set k=v` is a set (see
[CONTRACT.md](CONTRACT.md#verbs)). Quote values with spaces or shell metacharacters:
`text="two words"`, `"paths=/a b.png|/c.png"`.

`subscribe` cannot be sent through this path (the client reads one reply and exits); apps offer
`watch` instead (below).

## Output and exit codes

`HUDSocketClient.runCLI(path:arguments:appName:)` does the sending:

- stdout: the reply, pretty-printed JSON with sorted keys. There is no `--json` flag and no other
  format: the output is always JSON (a few app shorthands print something else, noted below).
- It waits for the reply without a client-side timeout; the server answers
  `{"ok": false, "error": "timeout"}` after 90 s.

| Exit | When |
|---|---|
| 0 | the reply has `"ok": true` |
| 1 | the reply has `"ok": false` (printed on stdout); the app is not running (stderr: `<repo> is not running (no socket at <path>)`); a socket path over 103 bytes (stderr: `<repo>: socket path too long (<n> bytes, the limit is 103): <path>; use a shorter socket name`); a reply that is not JSON; any other socket error (stderr: `<repo>: <error>`) |
| 2 | usage: no command (the usage text goes to stderr) |

`-h`/`--help` prints the usage to stderr and exits 0 in every family CLI.

```sh
scratch hello > /dev/null && echo up || echo "down or error"
```

## Environment

| Variable | Effect |
|---|---|
| `<REPO>_SOCKET` | socket **name** to use instead of `<repo>` (`SCRATCH_SOCKET=scratch-test` → `~/Library/Application Support/MacHUD/sockets/scratch-test.sock`); set it to the same value the isolated app was started with. Stash also accepts an absolute path |

The app's other isolation variables (`<REPO>_HOME`, `<REPO>_NO_HOTKEYS`, `HUD_NO_ANNOUNCE`) do
not affect the CLI (a CLI has no manifest and never announces itself).

## Common commands (every app)

```sh
tallyhud hello                            # contract handshake: hudkit, app, name, version, panels, verbs
tallyhud state                            # {panels: [{id, visible, mode, badge?, status?}]}
tallyhud help                             # registered commands
tallyhud panel show id=main               # also hide, toggle
tallyhud panel show id=main from=bottom anchor=600,6,44,44 reason=hover
tallyhud panel frame id=main x=100 y=100 w=320 h=160
tallyhud panel mode id=main parked edge=left peek=12   # also full, compact
tallyhud settings get                     # all settings
tallyhud settings get key=greeting
tallyhud settings set showCount=false greeting="Hi there"
tallyhud settings schema
tallyhud action bump by=2                 # the long form of any app verb
tallyhud action name=bump by=2            # the same, as MacHUD sends it
tallyhud menu                             # the status menu, if the app set menuProvider
tallyhud menu-invoke id=0 title="Show/Hide TallyHUD"
tallyhud quit
```

## Per-app shorthands

Each CLI rewrites a few commands before `runCLI`. The template's `settings get|set` rewrite
(`settings set k=v` → `settings action=set k=v`) is redundant but harmless: the router reads the
bare word too.

### Template and TallyHUD (the worked example)

```sh
tallyhud say text="hi there"      # action name=say text="hi there"; empty text restores the greeting
tallyhud bump                     # action name=bump (adds the defaultStep setting)
tallyhud bump 5                   # action name=bump by=5
tallyhud reset                    # action name=reset
```

### Scratch (hover; notes)

```sh
echo "some text" | scratch append           # onto the Inbox pad under a timestamp (stdin when no text=)
scratch append text="one line" show=1       # show=1 flashes the panel without taking focus
git diff | scratch new title="the diff"     # a new pad; stdin is read when piped and no text=
scratch list                                # pads, pinned first; list query=<text> searches
scratch get id=inbox                        # one pad with its body (JSON)
scratch body id=inbox                       # just the body, raw text on stdout (not JSON)
scratch open id=<pad id>                    # select it and show the panel
scratch clear id=<pad id>                   # empty it, keep the pad
scratch panel mode id=pad compact
scratch watch                               # stream state events (Ctrl-C to stop)
```

`append`, `new`, `open`, `list`, `get`, `body`, `clear` map to `action name=<verb>` (`body` is
`get` printing only the body). `append` without `text=` and without piped stdin exits 2. Text
over about 900,000 bytes is refused before sending (the server's line limit is 1,000,000). A
leading `ctl` is ignored (`scratch ctl hello`), as in every family CLI except the template's and
MechaHUD's.

### Sift (windowed; file browser)

```sh
sift action navigate path=~/Downloads       # `action <verb>` → `action name=<verb>`
sift action reveal path=~/Downloads/report.pdf
sift action send path=~/Downloads/a.pdf,~/Downloads/b.pdf target=Documents copy=1
sift panel mode id=browser compact          # dock mode
sift watch
```

A leading `~` in any `key=value` value is expanded, also in each comma-separated part (the shell
does not expand `path=~/x`). A leading `ctl` is ignored.

### Stash (hover; clipboard history)

```sh
stash copy some words        # puts "some words" on the clipboard; prints nothing, exit 0
echo hi | stash copy         # stdin when no text is given
stash list                   # history, newest first (action name=list); list limit=20
stash paste 2                # copy clip 2 (1 = newest) and paste it into the frontmost app
stash search invoice march   # action name=search q="invoice march"
stash pin 3                  # also delete 3, clear, clear all=1
stash watch
```

`copy` talks to the socket itself and prints only errors. `paste`, `list`, `search`, `pin`,
`delete`, `clear` map to `action name=<verb>`, a bare number becoming `index=`. `STASH_SOCKET`
may be a name or an absolute path.

### watch

Scratch, Sift, Stash, ffmpegHUD, magickHUD and serversHUD have `watch [events=state]` (the
template and MechaHUD do not): it subscribes and prints each event as one compact JSON line with
sorted keys until the app quits (exit 0) or Ctrl-C:

```
{"event":"state","panels":[{"badge":"1","id":"pad","mode":"full","status":"Untitled","visible":false}]}
{"event":"state","panels":[{"badge":"1","id":"pad","mode":"full","status":"Untitled","visible":true}]}
```

## Raw socket with nc

No CLI needed: one JSON line in, one out (macOS `nc` supports `-U`).

```sh
S="$HOME/Library/Application Support/MacHUD/sockets/scratch.sock"
echo '{"command":"hello"}' | nc -U "$S"
echo '{"command":"panel","args":{"action":"show","id":"pad"}}' | nc -U "$S"
echo '{"command":"action","args":{"name":"append","text":"from nc"}}' | nc -U "$S"
echo '{"command":"action","args":{"name":"drop","paths":"/tmp/a%20b.txt|/tmp/c.txt"}}' | nc -U "$S"
{ echo '{"command":"subscribe","args":{"events":"state"}}'; sleep 30; } | nc -U "$S"   # stream for 30 s
```

Replies are compact and unordered; pipe through `python3 -m json.tool` or `jq` to read them. Send
every arg value as a JSON string.

## Writing an app's CLI

The template's `Sources/<Product>CLI/main.swift` is the pattern: a usage string, the socket name
from `<REPO>_SOCKET`, a `switch` that rewrites shorthands into `action name=<verb> ...`, then

```swift
exit(HUDSocketClient.runCLI(path: HUDSocket.path(for: socketName), arguments: arguments, appName: "<repo>"))
```

Rules: shorthands only rename or fill in arguments (the app does the work); keep `--help`
current; read stdin only when it is piped (`isatty(0) == 0`) and the value is missing; for a
streaming command use `HUDSocketClient(path:).subscribe(events:onEvent:onClose:)` and
`dispatchMain()`. [AGENT-GUIDE.md](AGENT-GUIDE.md#47-the-cli) has a complete example.

## machud

`machud` is MacHUD's CLI (a zsh script in the MacHUD repo, linked onto PATH by MacHUD's
install). It runs `MacHUD.app/Contents/MacOS/MacHUD ctl <command> [key=value ...]`, which sends
the command to MacHUD's control socket `/tmp/machud-<uid>.sock` (or `MACHUD_SOCKET`). Same
grammar, same JSON output, same exit codes (0 ok, 1 error or not running, 2 usage).
`machud --help` prints MacHUD's full API reference (`docs/API.md`); `machud help` lists the
running app's commands; `machud --launch` starts MacHUD if needed.

The commands an app developer uses:

```sh
machud apps                                        # discovered apps: health, reachable, panels, failures
machud apps rescan                                 # scan again (builds normally announce themselves)
machud apps announce path=$PWD/build/TallyHUD.app  # register a bundle now (hud-build.sh does this)
machud apps forget path=$PWD/build/TallyHUD.app    # and take it back out
machud apps menu id=TallyHUD                       # the app's status menu as MacHUD hosts it
machud apps launch id=TallyHUD                     # by bundle id or name; launches without activating
machud apps quit id=TallyHUD                       # sends quit over its socket
machud panels                                      # every panel; app panels are <bundle id>/<panel id>
machud panel show id=xyz.machud.tallyhud/main      # forwarded to the app (launching it if needed)
machud panel mode id=xyz.machud.tallyhud/main mode=parked edge=left
machud summon id=TallyHUD                          # show where it was last dismissed
machud dismiss id=TallyHUD
machud tooldock                                    # the dock: buttons, frames, positions
machud tooldock drop id=TallyHUD paths=/tmp/a.txt,/tmp/b.txt   # as if files were dropped on the button
machud tooldock snapshot path=/tmp/dock.png        # the dock strip as a PNG
machud settings-window show tab=TallyHUD activate=0
machud capture name=Desk hud=only                  # save the HUD (dock + app panels) as a loadout
machud apply loadout=Desk
```

With `MACHUD_SOCKET` set, `machud` talks to that (isolated) instance instead of the user's; see
[AGENT-GUIDE.md](AGENT-GUIDE.md#9-register-with-a-running-machud). `MACHUD_APP` picks the
binary the script runs (default `/Applications/MacHUD.app`, then `~/Applications`, then the
repo's `build/`).
