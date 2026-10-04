#!/bin/sh
# Writes synthetic speech for the wake evaluation (WakeEvaluationTests) into <folder>:
#   <folder>/positives/   "Hey Jarvis" in several system voices and rates
#   <folder>/confusables/ phrases that sound a little like it, which must not wake
# `say -o` renders to a file and plays nothing. Files are 16 kHz mono 16-bit WAV; the evaluation
# pads them with silence through VOICEKIT_WAKE_EVAL_PAD_SECONDS. A voice that is not installed
# falls back to another one, so a rendering identical to an earlier one is removed: the files left
# are distinct audio. Some voices (the slow renderings of Daniel, Moira, Rishi, Tessa) differ
# slightly from one run to the next, so scores are comparable between runs only on the same files.
#
#   Tests/WakeEval/make-synthetic.sh /tmp/wake-eval-synthetic
set -eu
folder=${1:?usage: make-synthetic.sh <output folder>}
mkdir -p "$folder/positives" "$folder/confusables"

voices='Samantha
Daniel
Karen
Moira
Tessa
Rishi
Kathy
Fred
Ralph
Albert
Eddy (English (US))
Flo (English (UK))
Reed (English (US))
Sandy (English (US))
Shelley (English (UK))
Rocko (English (US))
Grandpa (English (US))'

render() { # voice rate phrase output
    say -v "$1" -r "$2" -o "$4" --file-format=WAVE --data-format=LEI16@16000 "$3"
}

slug() { printf '%s' "$1" | tr -c 'A-Za-z0-9\n' '-' | sed 's/--*/-/g; s/-$//'; }

printf '%s\n' "$voices" | while IFS= read -r voice; do
    for rate in 100 140 175 220 280; do
        render "$voice" "$rate" "Hey Jarvis" "$folder/positives/hey-jarvis-$(slug "$voice")-$rate.wav"
    done
done

# Near misses, in the voices that sound most natural, at the default rate.
for voice in Samantha Daniel Karen Moira; do
    for phrase in "Hey Travis" "Hey Harvest" "Hey Doris" "Hey Javier" "Hey service" \
        "They are viz" "Hey, are you ready" "Hey Harvey"; do
        render "$voice" 175 "$phrase" "$folder/confusables/$(slug "$phrase")-$voice.wav"
    done
done

seen=$(mktemp)
for file in "$folder"/positives/*.wav "$folder"/confusables/*.wav; do
    sum=$(shasum "$file" | cut -d' ' -f1)
    if grep -q "$sum" "$seen"; then rm "$file"; else echo "$sum" >> "$seen"; fi
done
rm "$seen"
