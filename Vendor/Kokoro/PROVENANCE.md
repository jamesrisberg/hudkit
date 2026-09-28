# Kokoro native runtime

Vendored from https://github.com/mweinbach/kokoro-swift at
`20bf04c506e913ff129d7d2229398180ba24c690` (Apache-2.0; see LICENSE), by way of Archibald's
`Vendor/Kokoro` at `1273e24`. Includes its Misaki English grapheme-to-phoneme implementation
and lexicons. Package.swift is reduced to the library product; MLX is pinned to 0.31.3.
VoiceKit uses VoiceLoader with downloads disabled. Model installation is explicit and managed
separately by VoiceKit's `ModelStore`. No text or audio leaves the machine during Kokoro
inference.

Local patch: EnglishG2P supplies letter-name pronunciations for unknown Latin words after
dictionary/compound resolution, instead of dropping them when unk is empty. The words
"Archibald" and "Kokoro" have explicit fallback pronunciations. Regression tests live in the
Misaki package and run with `swift test` in that directory.
