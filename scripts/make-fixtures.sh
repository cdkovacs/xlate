#!/bin/zsh
# Builds synthetic test clips (16 kHz mono float WAV) plus expected text.
# Each .txt holds "<language>|<text>". Output is gitignored.
set -e
cd "${0:A:h}/.."
OUT=fixtures/out
TMP=$(mktemp -d)
trap 'rm -rf $TMP' EXIT
mkdir -p $OUT

clip() { # name voice lang text
  say -v $2 -o $TMP/$1.aiff "$4"
  afconvert -f WAVE -d LEI16@16000 -c 1 $TMP/$1.aiff $TMP/$1.wav
  afconvert -f WAVE -d LEF32@16000 -c 1 $TMP/$1.wav $OUT/$1.wav
  print -r -- "$3|$4" > $OUT/$1.txt
}

clip pt_1 Luciana portuguese "Ainda precisamos confirmar a data do deploy com o cliente."
clip pt_2 Luciana portuguese "Acho que dá pra fechar isso até quinta se os testes passarem."
clip pt_3 Luciana portuguese "Vamos fazer o deploy depois da sprint review."
clip pt_4 Luciana portuguese "Todo mundo viu o e-mail que eu mandei ontem à tarde?"
clip pt_5 Luciana portuguese "O banco de dados caiu de novo e ninguém sabe por quê."
clip en_1 Samantha english "Can everyone see my screen right now?"
clip en_2 Samantha english "Let's move the release to next Tuesday."
clip en_3 Samantha english "I'll send the notes after the meeting."

# switch.wav: pt_1, 1 s silence, en_2, 1 s silence, pt_2
python3 - $TMP/switch.wav $TMP/pt_1.wav $TMP/en_2.wav $TMP/pt_2.wav <<'PY'
import sys, wave
out, parts = sys.argv[1], sys.argv[2:]
silence = b"\0\0" * 16000
data = silence.join(wave.open(p, "rb").readframes(10**9) for p in parts)
w = wave.open(out, "wb")
w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000)
w.writeframes(data)
PY
afconvert -f WAVE -d LEF32@16000 -c 1 $TMP/switch.wav $OUT/switch.wav
print -r -- "mixed|$(cut -d'|' -f2 $OUT/pt_1.txt) / $(cut -d'|' -f2 $OUT/en_2.txt) / $(cut -d'|' -f2 $OUT/pt_2.txt)" > $OUT/switch.txt
ls $OUT
