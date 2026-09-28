# VoiceKit

VoiceKit is the voice library of the HUDKit package: wake word detection, trigger phrases,
reply voices (text to speech) and the voice settings a settings tab binds to. It is a separate
product, so an app that imports only HUDKit never builds it. It does not open the microphone:
the host feeds it audio.

```swift
.package(path: "../hudkit")
.product(name: "VoiceKit", package: "hudkit")
```

Dependencies: [onnxruntime-swift-package-manager](https://github.com/microsoft/onnxruntime-swift-package-manager)
1.24.2 (wake models) and the vendored Kokoro package in `Vendor/Kokoro` (Apache-2.0, see its
`PROVENANCE.md`), which brings [mlx-swift](https://github.com/ml-explore/mlx-swift) 0.31.3.
SwiftPM resolves these for every consumer of the package, including HUDKit-only apps: about
120 MB of checkouts and 68 MB of ONNX Runtime archives on a cold cache. Only an app that
imports VoiceKit compiles them.

## Types

| Area | Types |
|---|---|
| Wake word | `WakeDetector`, `InProcessWakeDetector`, `WakeScoringEngine`, `OpenWakeWordEngine`, `WakeListener`, `WakeAudioSource`, `WakeDetection`, `WakeModel`, `WakeModels` |
| Trigger phrases | `TriggerPhraseRegistry`, `TriggerPhrase`, `TriggerMatch`, `VoiceAction` |
| Reply voices | `SpeechVoice`, `SpeechVoiceKind`, `KokoroVoice`, `SystemVoice`, `GrokVoice`, `SpeechVoices`, `SpeechStreamer`, `SentenceSplitter`, `KokoroEngine`, `KokoroModels` |
| Models | `ModelManifest`, `ModelArtifact`, `ModelStore`, `ModelDownload` |
| Settings | `VoiceSettings`, `VoiceSecretStoring`, `KeychainVoiceSecretStore`, `InMemoryVoiceSecretStore`, `VoiceSecrets` |

## Wake word

`WakeListener` connects a `WakeAudioSource` (the host's microphone: 16 kHz mono chunks in
-1...1, at most one second each, on the main actor) to a `WakeDetector`. It arms the detector,
starts the source, feeds chunks one at a time and calls `onWake` once; it then stays quiet,
with the source still running, until `rearm()`. A detector error, bad audio or a source that
fails to start moves it to `.failed`. When the detector falls more than
`WakeListener.maximumBacklog` chunks behind, the backlog is dropped and the detector re-armed.

`InProcessWakeDetector` scores 80 ms frames (1280 samples) with a `WakeScoringEngine`: one
detection per arm, a threshold in 0.05...0.95, and any error disarms it.
`OpenWakeWordEngine` is openWakeWord 0.6.0's streaming pipeline (melspectrogram, speech
embedding, keyword classifier) on ONNX Runtime, one thread.

```swift
let model = WakeModels.heyJarvis
let store = ModelStore(manifest: model.manifest, directory: model.directory(in: modelsRoot))
store.download()                                   // only when the person asks
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
`onLevel` (0...1) drive an indicator.

| Voice | Where it runs | Needs |
|---|---|---|
| `KokoroVoice` | on this Mac (Kokoro-82M on MLX, Apple silicon); audio stays in memory | the Kokoro model (`KokoroModels.manifest`, about 340 MB) |
| `SystemVoice` | on this Mac (`AVSpeechSynthesizer`) | nothing; the fallback |
| `GrokVoice` | xAI's text to speech (`https://api.x.ai/v1/tts`); sends only the text | an xAI API key |

`SpeechVoices.make(for:kokoroModelDirectory:secrets:)` builds the voice
`VoiceSettings.effectiveReplyVoice` chooses: the preferred one, or the system voice when Kokoro
is not installed or there is no Grok key.

`SpeechStreamer` speaks text that arrives in pieces: `append(_:)` each piece, `finish()` at the
end. `SentenceSplitter` cuts complete sentences (at `.`, `!`, `?`, `…` followed by whitespace,
or a line break, skipping common abbreviations and decimals) and they are spoken in order, one
at a time; `onFinished` reports the end or the first failure, and `stop()` drops the queue.

An app that ships `KokoroVoice` must carry MLX's Metal library and Misaki's lexicons: the
`mlx-swift_Cmlx.bundle` and `Misaki_Misaki.bundle` resource bundles from the build products
go in `Contents/Resources`. Without them the process stops at the first synthesis (MLX reports
"Failed to load the default metallib").

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
`VoiceSecrets.grokAPIKey` (`KeychainVoiceSecretStore(service:)` in an app).

## Models

`ModelManifest` pins every file of a model by size and SHA-256, with its licence and whether
it may be bundled. `ModelStore` (an `ObservableObject` for a settings tab) downloads into a
folder the host chooses: files already present and verified are kept, identical files in
`seedDirectories` (another app's copy) are cloned instead of downloaded, each file is verified
before it is moved into place, and a `.verified` marker is written last. Readiness afterwards
is a marker and size check. A complete folder without a marker is hashed once in the
background and marked. Downloads are `https` only, size-capped and refuse redirects to other
schemes; nothing is ever downloaded except by `download()`.

## Tests

`swift test --filter VoiceKitTests` uses fakes for the microphone, the models, the network and
audio playback: nothing opens the microphone, reaches the network or makes a sound. Two tests
run the real models when pointed at installed files and are skipped otherwise:

| Variable | Folder | Test |
|---|---|---|
| `VOICEKIT_WAKE_MODELS` | the Hey Jarvis files | openWakeWord scores match the Python reference on a fixture |
| `VOICEKIT_KOKORO_MODELS` | an installed Kokoro folder | Kokoro synthesizes finite, audible audio offline (nothing is played) |

The Kokoro test needs MLX's Metal library, which `swift test` does not place where MLX looks,
so run it with `xcodebuild`:

```sh
TEST_RUNNER_VOICEKIT_WAKE_MODELS=/path/to/wake/models \
TEST_RUNNER_VOICEKIT_KOKORO_MODELS=/path/to/Kokoro-82M/<revision> \
xcodebuild test -scheme HUDKit-Package -destination 'platform=macOS,arch=arm64' \
  -only-testing:VoiceKitTests/RealKokoroTests -only-testing:VoiceKitTests/RealWakeModelTests
```
