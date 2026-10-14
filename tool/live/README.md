# rush live (spike)

Runs an App Inventor extension on a phone and drives its blocks from the terminal, a browser panel or an AI agent.
Tracked in #57. This is a spike: it works on a real phone, but it lives outside the CLI.

## Setup

- Linux or WSL with the Dart SDK, Rush 2.5 or newer, Python 3, and the Android SDK (`ANDROID_HOME`, default `~/Android/sdk`).
- JDK 11 for App Inventor's build server: `JAVA11_HOME`, or any `11*` JDK under sdkman.
- D8 from `~/.m2/repository/com/android/tools/r8`, which `rush build` downloads.
- App Inventor v206's build server, built once into `~/.cache/rush-e2e` by `tool/e2e/buildserver.sh` on first use.

```sh
cd tool/live/companion && rush build
cd ../host && dart compile exe live.dart -o live
cd /path/to/your/extension && /path/to/rush-cli/tool/live/host/live up
```

Run every command from the extension's project directory. `live` below means `tool/live/host/live`.

## For people

1. Plug in a phone with USB debugging on.
2. `live up` builds the extension, installs a dev app made by App Inventor's build server (only when dependencies,
   the manifest or the events change), and opens a panel at http://127.0.0.1:7465.
3. Add components and run blocks from the panel. The phone shows only your extension.
4. Save a file. The extension rebuilds, the app restarts, and the session in `live.jsonl` replays, so the phone
   comes back in the same state.

## For agents

Every command prints one JSON object. Exit codes: 0 ok, 1 failed, 2 usage, 3 no device or app.

```sh
live blocks                         # what the extension offers: methods, properties, events, option values
live reload                         # build, push, restart; errors come back as file:line:column messages
live create Media3Player Player
live create VerticalArrangement Stage
live set Stage Height -2
live call Player Create Stage
live call Player Play https://example.com/video.mp4 Title --wait IsPlayingChanged=true --timeout 15
live get Player Duration
live events --since <cursor>        # cursor comes with every reply
live screenshot                     # returns a PNG path to look at
live status                         # device, app, loaded build, session size
```

- Invalid calls are rejected before they reach the phone, with the signature, allowed options or `didYouMean`.
- A crash reports the exception with the extension's own stack frames. The step that caused it is removed from the
  session so restarts don't crash again; run `live restart` to continue.
- Waiting on an event avoids sleeps: `--wait Event` or `--wait Event=value`, starting from the cursor of the call.
