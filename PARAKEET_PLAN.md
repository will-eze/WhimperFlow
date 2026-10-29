# WhimperFlow on Parakeet: build plan (handover)

Written 2026-10-29 for the next session. **Built the same day** (see "Outcome" at the end). Measurements are in
`Eval/RESULTS.md` (2026-10-29 entries); the bench scripts and a copy of the clips are on the server in `jarvis:~/wf-bench/`.

## Decisions (Will, 2026-10-29)

- **Engine: Parakeet TDT 0.6B v2 on the Jarvis server**, with Apple's on-device recogniser kept as the offline
  fallback. Speed first ("a second is not bad"), then accuracy.
- **Prime Parakeet with Will's vocabulary** (dictionary terms, snippet triggers, voice-function words).
- **Finish and ship the Functions feature** (uncommitted WIP) as part of the same build.
- **Repackage the app** so it runs smoothly (one-command install, launch at login, visible engine status).
- Ships no model in the app, and nothing goes to the cloud. Audio goes only over Tailscale to Will's own server.
  This replaces ACCURACY_PLAN.md's "OS recognizer is the only sensor" rule.

Why: Apple's recogniser stops WhimperFlow with "On-device recognition for en-GB isn't downloaded" whenever macOS
reports its model missing (`Sources/WhimperFlow/Speech/SpeechService.swift:86`, hard `throw`, no fallback). It's
also half as accurate as Parakeet on Will's voice.

## Benchmark (34 clips, 970 words, Jarvis server CPU i7-9700, no GPU)

Scored with `WordErrorRate.normalize` rules. "After release" = time for the last 3 s phrase (the wait when audio
streams while talking). Will's dictations: median 10.6 s, p90 25 s (638 in `history.jsonl`).

| engine | WER | jargon | numbers | quiet | after release | 10 s clip whole |
|---|---:|---:|---:|---:|---:|---:|
| Apple on-device (raw / after pipeline) | 14.1% / 11.5% | 43% | 6% | 16% | streams | — |
| **Parakeet TDT 0.6B v2 int8** (onnx-asr) | **7.1%** | 22% | 7% | 9% | **0.24 s** | **0.38 s** |
| Whisper small greedy + vocab prompt | 5.6% | 18% | 3% | 5% | 1.25 s | ~1.4 s |
| Whisper large-v3-turbo | 6.4% | 19% | 4% | 5% | ~5.6 s | ~5.6 s |
| Moonshine base | 11.5% | 27% | 22% | 14% | 0.18 s | 0.39 s |

- Whisper can't go below ~1.1 s per pass on this CPU, because it always encodes a 30 s window. That's why it's not
  the choice.
- Parakeet writes numbers as words ("twenty-third of March"). This is likely fixed by `NumberNormalizer`, but not
  yet checked (step 1).
- No Parakeet output has been through `TranscriptProcessor` yet, so the 7.1% is raw and processed will be lower.

## Architecture

```
Mac (WhimperFlow)                                        Server (jarvis)
hotkey down ─▶ open/warm keep-alive connection
            ─▶ AudioCaptureEngine → 16 kHz mono buffer (always recorded; optional pre-roll)
talking: at each pause (VAD) or every ~15 s ─chunk─▶ jarvis-dictate@will (Python, resident Parakeet, always warm)
                                            ◀─ text ─  127.0.0.1:7020, published by `tailscale serve --https=7443`
hotkey up ─▶ last chunk only ─────────────────────▶
          ◀─ text (~0.25 s) ─ join ─▶ TranscriptProcessor (functions, dictionary, snippets, numbers) ─▶ inject
server unreachable / chunk > 2 s ─▶ Apple SFSpeechURLRecognitionRequest on the saved audio
```

- **Separate service from core** (`core/server.js` restarts on every Jarvis deploy). It uses zero Claude tokens,
  logs durations and latency only (never text), and keeps no audio after replying.
- **Recording is separate from recognition:** the audio is held until text is injected, so no engine failure loses
  a dictation.
- **Chunks are cut at pauses,** so no word is split. Context is lost across chunk boundaries, but it's tiny at 15 s.

## Vocabulary priming (Parakeet)

Parakeet takes no text prompt the way Whisper does. These are the routes to try, in order, measured on the 34
clips (jargon WER is the number to move; today it's 22%):

1. **sherpa-onnx hotwords** (contextual biasing for transducer models): load the sherpa-onnx export of
   `parakeet-tdt-0.6b-v2` (int8), `decoding_method="modified_beam_search"`, `hotwords_file` (one phrase per line,
   BPE-tokenised by sherpa), `hotwords_score` swept 1.0–3.0. **Unverified:** that sherpa-onnx's hotwords work with
   the TDT decoder and not only plain RNNT. Check its docs/issues first. Also check that beam search keeps latency
   under ~0.5 s.
2. If not: **NeMo's own phrase boosting** for TDT/RNNT (word boosting / GPU-PB, runs on CPU but needs torch +
   NeMo, a heavy install). Measure the latency cost.
3. Either way: **WhimperFlow's dictionary stays the final fix** (post-processing, deterministic). RESULTS.md shows
   it took Apple's jargon from 42.9% to 27.3% with 10 entries. Add entries for Parakeet's own mis-hears
   ("Wimperflow", "SF speech recognizer", "K8").

**Where the vocabulary comes from:** the Mac sends it, so the server stays stateless. `POST /dictate` takes an
optional `vocab` list, and the server caches the hotword set by hash. Build it in WhimperFlowKit from
`CustomVocabulary.phrases` (dictionary replacements + snippet triggers) plus the voice-function words (trigger
`flow`, and `spell quote literal code caps symbols stop`). Today's dictionary replacements are: WhimperFlow,
SFSpeechRecognizer, TranscriptProcessor, JSON, k8s cluster, crash looping, pull request, tokenizes
(`~/Library/Application Support/WhimperFlow/settings.json`). Patterns (the mis-hears) must **not** go in. ACCURACY_PLAN
finding 6 flagged that teaching the model the misrecognition is an own-goal.

## Build steps

1. **Scoring path (Mac, no server).** Add `--hypotheses <jsonl>` to `Sources/whimpereval/main.swift` (clip name →
   text), so the Parakeet output in `jarvis:~/wf-bench` (re-run `bench2.py nemo-parakeet-tdt-0.6b-v2 int8`) is
   scored after `TranscriptProcessor`. Confirm numbers come out as digits.
2. **Vocabulary priming experiment** (above). Record each variant in RESULTS.md. Pick the one that best cuts jargon
   WER with the after-release time still ≤ 0.5 s.
3. **Server service.** `Jarvis/server/dictate/serve.py` (stdlib `http.server` or similar, one model, one worker,
   requests queued). `POST /dictate` takes a raw 16 kHz mono WAV body plus an optional `X-Vocab-Hash` header and
   `vocab` JSON, and returns `{text, ms}`. There's also `GET /health`. Add a systemd unit `jarvis-dictate@.service`,
   a venv (`~/wf-bench/env` has onnx-asr 0.12 + onnxruntime 1.31 + soxr, so promote it to `~/jarvis/dictate-env`),
   `tailscale serve --https=7443 http://127.0.0.1:7020`, a line in `server/check.sh`, and a sudoers restart entry
   (Will runs the root commands). Test from the Mac with curl over Tailscale on all 34 clips; this measures the
   network leg.
4. **`TranscriptionBackend` protocol** (WhimperFlow target): `ServerBackend` (URLSession, keep-alive, 2 s per chunk
   timeout, server URL in settings) and `AppleBackend` (today's `SpeechService`, fallback only, no hard stop).
   `DictationController` owns the audio, sends chunks, joins the text, falls back per chunk, then runs
   `TranscriptProcessor` once on the joined text (functions can span chunks).
5. **Audio path.** `AVAudioConverter` → 16 kHz mono with a real downmix (ACCURACY_PLAN finding 3). Chunk cuts come
   from the existing adaptive VAD. Optional pre-roll setting, default off (finding 4: it keeps the mic indicator lit).
6. **whimpereval `--backend server`**, then a dated RESULTS.md entry. Target: processed WER ≤ 5.6% (Whisper+vocab),
   ≤ 0.5 s after release.
7. **Settings + HUD:** engine (Server with Apple fallback / Apple only), server URL, a "Test connection" button, and a
   small HUD marker when the Apple fallback produced the text.

## Functions feature (finish and ship)

State: uncommitted in the WhimperFlow repo. New files are `Engine/VoiceFunction.swift`, `Engine/FunctionSegmenter.swift`,
`Engine/FunctionFormatters.swift`, `UI/Settings/FunctionsSettingsView.swift`, plus `Tests/.../VoiceFunctionTests.swift`.
Modified: TranscriptProcessor, FlowSettings, SettingsRootView, AppDelegate, Makefile, DESIGN.md. What it does
(DESIGN.md): `flow spell|quote|literal|code|caps|symbols … flow stop` spans that change how the enclosed speech is
transcribed. The trigger is configurable, doubling it escapes, spans auto-close at the end, and there's a
`triggerVariants` list for mis-hears.

To do:
1. `swift test`. Fix failures, then read the diff for anything half-done (none of the new files has a TODO).
2. Recheck `triggerVariants` against **Parakeet's** mis-hears, not Apple's. Record a few function clips
   (`make record`) and add them to Eval.
3. Add the function words to the hotword list (vocabulary priming above).
4. Commit it on its own, before the Parakeet work, so the two can be told apart.

## Repackaging (runs smoothly)

Found 2026-10-29:
- `/Applications/WhimperFlow.app` is a **26 Aug build**. The source has moved on (the Functions WIP), so Will runs a
  stale copy.
- `launchAtLogin: false`. After a restart there's no dictation until the app is opened by hand.
- A new `SFSpeechRecognizer` is created per dictation, with a hard fail on the on-device check (the screenshot bug).
- Signing: the Makefile already supports a stable self-signed identity (`make signing-identity`, `WhimperFlow Dev`).
  The installed copy has a real signature, not ad-hoc, so permissions should survive rebuilds signed the same way.

Changes:
1. **`make install`:** release build → sign with `WhimperFlow Dev` → quit the running copy → replace
   `/Applications/WhimperFlow.app` → relaunch. Show version + build date in Settings → About.
2. **Launch at login on by default** (SMAppService; the existing toggle can turn it off).
3. **Menu-bar status dot:** green = server reachable, amber = Apple fallback only, red = no engine. It checks
   `/health` on wake, on network change and every 60 s while idle.
4. **The custom LM compile** (measured worth ~1 word in 363) runs only when the Apple fallback is first needed,
   not at launch.

## Done when

- Processed WER ≤ 5.6% on the 34 clips and ≤ 0.5 s from hotkey-up to text, measured from the Mac over Tailscale.
- Pulling the network mid-dictation still produces text (Apple fallback), and nothing is lost.
- `make install` gives a launch-at-login app with the Functions feature, and all tests pass.
- Docs: RESULTS.md entries; DESIGN.md engine section; Jarvis `CLAUDE.md` (diagram + new service) and
  `server/RECOVERY.md` (service restore). Commit both repos.

## Risks

- sherpa-onnx hotwords may not support TDT. Then the NeMo route costs a heavy install, or the dictionary has to
  carry jargon alone.
- Server RAM: Parakeet int8 is ~1 GB resident, alongside resident Whisper/Kokoro/embeddings (13 GB total, ~10 GB
  available on 29 Oct). Check `free -g` after the service starts.
- Hallucinated text on silent chunks: drop chunks with no speech per VAD, before sending.
- Offline: Apple fallback. If that gets used a lot, consider Parakeet on the Mac itself (FluidAudio / CoreML,
  ~600 MB model on an 8 GB machine).

## Outcome (2026-10-29, built)

Done when → met: processed WER **5.4%** (≤ 5.6%) and **~0.3 s p90** after release (≤ 0.5 s) from the Mac;
network pulled mid-dictation still produces the full text (Apple fallback); `make install` gives a launch-at-login
app with Functions; 175 tests pass. Changes from the plan, all measured (RESULTS.md):

- **No vocabulary priming.** sherpa-onnx hotwords work with TDT but never helped (no change at 1.5–3, garbled
  from 4). NeMo boosting skipped: the misses are spellings (dictionary) or mis-hears (boosting can't help). Three
  dictionary entries added instead. The server takes no `vocab`; it stays stateless.
- **onnx-asr, not sherpa-onnx**: faster on 6–15 s chunks. Greedy decoding.
- **Port 7030, not 7020** (Edith owns 7020). `tailscale serve --https=7443`.
- **Chunks 4–8 s** (cut at the first 0.3 s pause after 4 s; hard cut at 8 s): 6–15 s gave p90 0.55 s.
- **Timeout** per chunk 2 s + 0.1 s per second of audio; after one server failure the rest of the dictation goes
  straight to Apple. A recording neither engine reads is saved (`Unsent/`) and transcribed into History later.
- **Custom LM** compiles only when the Apple-only engine is selected (the file-based fallback ignores it).
- Not done: `triggerVariants` against Parakeet's mis-hears. No eval clip says a voice function yet, so this needs
  Will to record a few (`make record`, e.g. "flow spell n g i n x", "flow quote ship it flow stop") and run
  `whimpereval --backend server --verbose`; add whatever Parakeet hears for "flow" to `triggerVariants`. Pre-roll setting not added (finding 4: off is
  right; nothing asked for it).

Will's root steps (once): install `jarvis-dictate@.service`, `sudo tailscale serve --bg --https=7443
http://127.0.0.1:7030`, sudoers restart line. Until then the app shows amber and uses Apple.
