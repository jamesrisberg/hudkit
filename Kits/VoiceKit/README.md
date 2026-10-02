# VoiceKit

VoiceKit is the voice library in the HUDKit repo: wake word detection, trigger phrases, reply
voices (text to speech) and the voice settings a settings tab binds to. It is its own Swift
package at `Kits/VoiceKit`, separate from the HUDKit package at the repo root, so an app that
depends only on HUDKit resolves and builds none of VoiceKit's dependencies. It does not open
the microphone: the host feeds it audio.

```swift
.package(path: "../hudkit/Kits/VoiceKit")
.product(name: "VoiceKit", package: "VoiceKit")
```

Dependencies: [onnxruntime-swift-package-manager](https://github.com/microsoft/onnxruntime-swift-package-manager)
1.24.2 (wake models) and the vendored Kokoro package in `Kits/VoiceKit/Vendor/Kokoro`
(Apache-2.0, see its `PROVENANCE.md`), which brings [mlx-swift](https://github.com/ml-explore/mlx-swift)
0.31.3. On a cold cache an app that depends on VoiceKit fetches about 120 MB of checkouts and
68 MB of ONNX Runtime archives. VoiceKit is a library package, so it commits no
`Package.resolved`; the app pins the versions.

## Types

| Area | Types |
|---|---|
| Wake word | `WakeDetector`, `InProcessWakeDetector`, `WakeScoringEngine`, `OpenWakeWordEngine`, `WakeListener`, `WakeAudioSource`, `WakeDetection`, `WakeModel`, `WakeModels` |
| Trigger phrases | `TriggerPhraseRegistry`, `TriggerPhrase`, `TriggerMatch`, `VoiceAction` |
| Reply voices | `SpeechVoice`, `PrefetchingSpeechVoice`, `SpeechClip`, `SpeechVoiceKind`, `KokoroVoice`, `SystemVoice`, `GrokVoice`, `SpeechVoices`, `SpeechStreamer`, `SpeechStreamMetrics`, `SpeechChunker`, `SentenceSplitter`, `MarkdownSpeechFilter`, `SpeechClock`, `SystemSpeechClock`, `KokoroEngine`, `KokoroModels` |
| Models | `ModelManifest`, `ModelArtifact`, `ModelStore`, `ModelDownload` |
| Settings | `VoiceSettings`, `VoiceSecretStoring`, `KeychainVoiceSecretStore`, `InMemoryVoiceSecretStore`, `VoiceSecrets` |

## Wake word

`WakeListener` connects a `WakeAudioSource` (the host's microphone: 16 kHz mono chunks,
nominally in -1...1, at most one second each, on the main actor) to a `WakeDetector`. It arms
the detector, starts the source, feeds chunks one at a time and calls `onWake` once; it then
stays quiet, with the source still running, until `rearm()`. `stop()` stops the source, also
when it comes during a slow `source.start()`. A detector error, a non-finite sample, a source
that fails to start, or more than `WakeListener.maximumBacklogSamples` (half a second) of
audio waiting for the detector moves it to `.failed` with the source stopped; the host calls
`start()` again to resume.

`InProcessWakeDetector` scores 80 ms frames (1280 samples) with a `WakeScoringEngine`: one
detection per arm, a threshold in 0.05...0.95, and any error disarms it. Samples outside
-1...1 are clipped; non-finite samples are an error.
`OpenWakeWordEngine` is openWakeWord 0.6.0's streaming pipeline (melspectrogram, speech
embedding, keyword classifier) on ONNX Runtime, one thread.

```swift
let model = WakeModels.heyJarvis
let store = ModelStore(manifest: model.manifest, directory: model.directory(in: modelsRoot))
guard store.isReady else { return }                // store.download() when the person asks
let engine = try OpenWakeWordEngine(model: model, directory: store.directory)
let listener = WakeListener(
    detector: InProcessWakeDetector(engine: engine, phrase: model.phrase, model: model.id),
    source: microphone, threshold: settings.wakeThreshold)
listener.onWake = { detection in
    if registry.action(forPhrase: detection.phrase) == .agentTurn { startAgentTurn() }
}
await listener.start()
```

Wake models are downloaded on demand and never bundled. `WakeModels.all` lists the known
phrases; `WakeModels.model(forPhrase:)` returns nil for a phrase without a model, which
includes the default phrase "Hey Computer". "Hey Jarvis" is openWakeWord's classifier under
CC BY-NC-SA 4.0 (personal, non-commercial use): its manifest carries that notice and
`redistributable == false`.

## Trigger phrases

`TriggerPhraseRegistry` maps phrases to `VoiceAction` identifiers (`agent.turn`, or any
identifier the host resolves, such as a `machud` command). It does not know how a phrase was
heard: `action(forPhrase:)` takes the phrase a wake model reports, `match(transcript:)` finds
the phrase a transcript opens with (whole words, longest first) and returns the words after
it. Phrases compare normalized: case, accents and punctuation are ignored.
`TriggerPhraseRegistry.standard` maps "Hey Computer" to `.agentTurn`. The registry encodes as a
plain JSON list of `{phrase, action}`.

## Reply voices

`SpeechVoice` is one protocol for every voice: `speak(_:completion:)` replaces what is being
said and completes once, never after `stop()` or a newer `speak`; `onSpeakingChanged` and
`onLevel` (0...1) drive an indicator; `warmUp()` gets the voice ready without playing anything
(Kokoro loads its model and synthesizes a discarded word; other voices do nothing), returns at
once when already warm, and may be called whenever a reply is expected. A voice that can
synthesize ahead of time also conforms to `PrefetchingSpeechVoice` (`prepare(_:completion:)`
synthesizes a `SpeechClip` without playing it, several at once if asked, all cancelled by
`stop()`; `play(_:completion:)` plays one already prepared); a voice that cannot (like
`SystemVoice`) just implements `SpeechVoice`.

| Voice | Where it runs | Needs | Prefetch |
|---|---|---|---|
| `KokoroVoice` | on this Mac (Kokoro-82M on MLX, Apple silicon); audio stays in memory | the Kokoro model (`KokoroModels.manifest`, about 340 MB) | yes |
| `SystemVoice` | on this Mac (`AVSpeechSynthesizer`) | nothing; the fallback | no |
| `GrokVoice` | xAI's text to speech (`https://api.x.ai/v1/tts`); sends only the text | an xAI API key | yes |

`SpeechVoices.make(for:kokoroModelDirectory:secrets:)` builds the voice
`VoiceSettings.effectiveReplyVoice` chooses: the preferred one, or the system voice when Kokoro
is not installed or there is no Grok key.

`SpeechStreamer` speaks text that arrives in pieces: `append(_:)` each piece, `finish()` at the
end. `SpeechChunker` cuts the text into chunks so speech starts before the first sentence is
complete:

- The first chunk ends at the first clause boundary (`,` `;` `:` `—` `–`; not "1,000",
  "10:30" or "3–5") with at least 5 words before it, or at a word boundary once it has 12
  words, or, when at least 3 words have waited 400 ms with no new text, with what has arrived.
- Every later chunk is a sentence (`SentenceSplitter`: `.`, `!`, `?`, `…` followed by
  whitespace, or a line break; not after common abbreviations, initialisms such as "U.S.", a
  list number opening a sentence, or inside a decimal). A sentence longer than 160 characters
  is split at its last clause boundary within them; a run of 280 characters with no ending is
  cut at a space.
- A cut inside a sentence leaves at least 3 words on each side and never falls inside inline
  markdown; a complete sentence is a chunk whatever its length ("Sure.").

`SpeechChunker.Rules` holds those numbers. `MarkdownSpeechFilter` cleans each chunk before it is
queued: heading and list markers are dropped, emphasis markers are removed (the emphasized
words are kept), a link speaks its text, inline code is spoken as plain words, and a fenced
code block (its lines and the fence lines themselves) is skipped entirely, never spoken; a chunk
left with nothing to say is dropped. Chunks are spoken in order, one at a time. `onFinished`
reports the end or the first failure once; the stream then ignores more text until `stop()`,
which also drops the queue and cancels any synthesis in flight.

When `voice` conforms to `PrefetchingSpeechVoice`, each chunk is synthesized as soon as it is
queued, up to `prefetchDepth` (default 2) chunks ahead of the one playing, and played with
`play(_:completion:)` when its turn comes: speech is gapless while text arrives faster than it
is spoken, and when text is slower the voice pauses only between chunks. A voice that cannot
prefetch speaks each chunk with `speak(_:completion:)`. `ClipPlayback` (the clip player behind
`KokoroVoice` and `GrokVoice`) coalesces a `play()` that follows a clip's natural end into one
uninterrupted span: `onSpeakingChanged` does not flicker false-then-true at a chunk boundary,
only going false once nothing plays next.

`onChunkStarted(text, index)` and `onChunkFinished(text, index)` report each spoken chunk (its
cleaned text, numbered from 0 in the reply), so a host can reveal the reply in step with the
voice; `warmUp()` passes through to the voice. Once per reply that received text (when it
finishes, fails or is stopped) the streamer logs a `SpeechStreamMetrics` line under the app's
subsystem, category `speech`, and passes it to `onMetrics`: the time from the first text to the
first chunk queued and to the first chunk playing, the chunks played, and the underruns (a
chunk ended with the next not ready) with their total silence. Time comes from a `SpeechClock`,
`SystemSpeechClock` unless the host or a test passes another.

`KokoroVoice(modelDirectory:)` voices for one model folder share one `KokoroEngine`, so the
model loads once per process and stays loaded; a voice made for each reply starts warm.

An app that ships `KokoroVoice` must carry MLX's Metal library and Misaki's lexicons:
`hud-build.sh` copies the `mlx-swift_Cmlx.bundle` and `Misaki_Misaki.bundle` resource bundles
from the build products into `Contents/Resources` (see `docs/CONVENTIONS.md`). Without them the
process stops at the first synthesis (MLX reports "Failed to load the default metallib").

## Settings

`VoiceSettings` is `Codable` and `Equatable`:

| Key | Type | Default | Meaning |
|---|---|---|---|
| `wakeWordEnabled` | Bool | false | Listen for the wake phrase |
| `wakePhrase` | String | "Hey Computer" | The phrase to listen for |
| `wakeThreshold` | Double | 0.5 | 0.05...0.95; higher wakes less often |
| `replyVoice` | `kokoro` \| `system` \| `grok` | `kokoro` | Preferred reply voice |
| `speakReplies` | Bool | false | Speak replies; otherwise replies are text only |
| `kokoro.voice` | String | `af_heart` | A `KokoroModels.voices` id |
| `kokoro.speed` | Double | 1 | 0.5...2 |
| `system.voiceIdentifier` | String | "" | An installed macOS voice; empty is the system default |
| `system.rate` | Double | 1 | Multiplier on the default rate, 0.5...2 |
| `grok.voice` | String | `ara` | `ara`, `rex`, `sal`, `eve` or `leo` |

Decoding fills missing keys with their defaults and brings out-of-range values back into
range. Secrets are not part of it: the Grok key is stored with a `VoiceSecretStoring` under
`VoiceSecrets.grokAPIKey`. In an app that is `KeychainVoiceSecretStore(service:)`: generic
passwords readable after first unlock, on this device only; `set` throws the Keychain's
status when it refuses a change.

## Models

`ModelManifest` pins every file of a model by size and SHA-256, with its licence and whether
it may be bundled. `ModelStore` (an `ObservableObject` for a settings tab) downloads into a
folder the host chooses: files already present and verified are kept, identical files in
`seedDirectories` (another app's copy) are cloned instead of downloaded, each file is verified
before it is moved into place, and a `.verified` marker is written last; staged files an
interrupted install left behind are removed when the next install starts. Readiness
afterwards is a marker and size check. A complete folder without a marker is hashed once in
the background and marked; a file that fails that check is deleted, so the folder is not
hashed again and the next download replaces the file. `cancel()` stops a download or that
check. Downloads are `https` only, size-capped and refuse redirects to other
schemes; nothing is ever downloaded except by `download()`.

## Tests

```sh
cd Kits/VoiceKit && swift build && swift test
```

The tests use fakes for the microphone, the models, the network and
audio playback: nothing opens the microphone, reaches the network or makes a sound. Two tests
run the real models when pointed at installed files and are skipped otherwise:

| Variable | Folder | Test |
|---|---|---|
| `VOICEKIT_WAKE_MODELS` | the Hey Jarvis files | openWakeWord scores match the Python reference on a fixture |
| `VOICEKIT_KOKORO_MODELS` | an installed Kokoro folder | Kokoro synthesizes finite, audible audio offline (nothing is played) |

The Kokoro test needs MLX's Metal library, which `swift test` does not place where MLX looks,
so run it with `xcodebuild`, from `Kits/VoiceKit`:

```sh
TEST_RUNNER_VOICEKIT_WAKE_MODELS=/path/to/wake/models \
TEST_RUNNER_VOICEKIT_KOKORO_MODELS=/path/to/Kokoro-82M/<revision> \
xcodebuild test -scheme VoiceKit -destination 'platform=macOS,arch=arm64' \
  -only-testing:VoiceKitTests/RealKokoroTests -only-testing:VoiceKitTests/RealWakeModelTests
```

The vendored Misaki package has its own tests: `cd Kits/VoiceKit/Vendor/Kokoro/Packages/Misaki
&& swift test`.
