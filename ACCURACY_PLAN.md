# WhimperFlow Accuracy Plan

Goal: close as much of the gap to Wispr Flow's perceived accuracy as possible while
keeping the core constraint intact — **deterministic app logic, no shipped AI models,
no cloud**. OS-provided on-device recognizers remain the "sensor"; everything the app
does with their output stays pure, rule-based Swift pinned by golden tests.

Framing: Wispr's edge = big server ASR + domain fine-tune + LLM cleanup + personalization.
The first two we can't have; the last one is *easier* for a single user than for Wispr,
and that's where most of this plan lives.

Current baseline (2026-07-19): on-device `SFSpeechRecognizer` (macOS 15.5, M1 Air),
custom LM compiled from dictionary + snippet triggers (`CustomLanguageModel.swift`),
silence-aware session rotation, token pipeline (`TranscriptProcessor` → filler removal,
spoken punctuation, dictionary, snippets, casing, numbers), 71 Swift Testing tests.

---

## 2026-07-21 review — live-path findings and the current track plan

A full read of the app turned up several accuracy losses that are **structurally
invisible to `whimpereval`**, because the harness scores pre-recorded files and
these only happen while the hotkey is held. Phases 0–5 below still stand; this
section is what runs first.

### Findings (read from the code; not all demonstrated yet)

1. **Session rotation commits a partial and cancels the task**
   (`SpeechService.swift:156`). `commitPartial()` runs before the outgoing
   session's final result, and `task.cancel()` precedes `endAudio()`, so every
   dictation past 35s discards both the in-flight audio and the recognizer's
   end-of-session retro-correction for that whole chunk. Partials are measurably
   worse than finals. Fix: `endAudio()` first, service the old task until
   `isFinal`, commit *that*, and overlap the new session.
2. **Data race on `request` / `active` / `finishing`.** `append(buffer:)` runs on
   the audio thread and reads state written on main, so buffers can be dropped or
   appended to a dead request around rotation and finish.
3. **The recognizer is fed the raw hardware format** (`AudioCaptureEngine.swift:34`).
   On a multichannel input the recognizer gets a multichannel buffer, and
   `normalizedLevel` reads channel 0 only — so a quiet channel 0 reads as silence
   and breaks VAD, rotation, and hands-free auto-stop at once. Same class as the
   voice-processing bug. Fix: explicit `AVAudioConverter` to mono 16 kHz, with a
   downmix rather than picking channel 0.
4. **First-word clipping — no pre-roll.** `AVAudioEngine.start()` costs 100–300 ms
   and happens on hotkey-down, so the onset of the first word is routinely lost.
   Fix: ~800 ms ring buffer flushed into the request at session start, which needs
   the engine kept warm. **Decided: a setting, default off** — warming the mic
   keeps the macOS recording indicator lit, which should be opt-in.
5. **Fixed VAD threshold.** `level > 0.12` (≈ −44.6 dB) is hardcoded in
   `SpeechService.swift:81` and `DictationController.swift:64`. On a quiet or
   far-field mic real speech never crosses it, so hands-free auto-stops
   mid-sentence. An adaptive noise floor is deterministic and testable.
6. **The custom LM is taught the misrecognitions.** `CustomVocabulary.phrases`
   feeds the LM `entry.pattern` as well as `entry.replacement` — biasing the
   recognizer *toward* producing "whimper fluid" so the dictionary can fix it.
   Possibly net-positive, possibly an own-goal; now testable.
7. **Two recognizer signals go unused.** `result.transcriptions` (N-best) and
   `SFTranscriptionSegment.confidence` / `alternativeSubstrings` are discarded.
   Reranking N-best by "how many known vocabulary terms does this hypothesis
   contain" is a pure, golden-testable function aimed squarely at jargon.

### Tracks (approved 2026-07-21, order A → B → C)

**Track A — measurement unblock.**
- [x] **A1. Bundle `whimpereval`.** `make eval` now builds `whimpereval.app`
      (`Resources/EvalInfo.plist`, bundle id `com.whimperflow.eval`) and launches
      it via `open -W`, writing the report to `Eval/last-run.md`. Also added
      `--streaming`, which replays clips through the buffer API the app actually
      uses. **This is what made the custom LM measurable** — see RESULTS.md.
      `make eval-cli` keeps the old unbundled run.
- [ ] **A2. Grow the clip set** 24 → ~60, adding takes >40s (to exercise finding 1),
      a far-field/noisy condition, and quiet-mic takes. Needs your voice:
      `make record`. 46 total errors today means ±1 clip moves the headline.
- [x] **A3. Exact-match metric** alongside WER, since WER normalization strips
      `£ % .` and hides number/punctuation formatting. Baseline: **5/24 exact.**

**Track B — live-path fixes.** Findings 1–5. Self-contained, no determinism risk.

**Track C — vocabulary generalization.**
- C1. Fuzzy/phonetic dictionary matching, so you stop hand-enumerating every
  misrecognition variant ("recognisable" *and* "recogniser" as separate entries).
- C2. N-best rescoring by vocabulary hits (finding 7), after probing that the
  signal exists on-device.
- C3. Then Phase 1's corpus LM and Phase 2's learned corrections below.

Phase 3 (macOS 26 `SpeechAnalyzer`) stays deferred, as the baseline argues.

---

## Phase 0 — Measure first (prerequisite for everything else)

You can't tune what you can't score. Build a tiny offline evaluation harness before
touching accuracy levers, so every later phase has a before/after number.

- [ ] **Personal test set.** Record ~20–30 short clips of your own dictation
      (real sentences you'd actually dictate: prose, emails, technical talk with your
      jargon). Store under `Eval/clips/` as `name.wav` + `name.txt` (the text you
      *meant*) — layout and tips in `Eval/README.md`. Contents are gitignored.
      **Only remaining Phase 0 item; needs your voice.** `make record` opens
      Clip Recorder (`Sources/WhimperRecorder`), which prompts you sentence by
      sentence, records each take, and writes the paired `.wav`/`.txt` so the
      names can't drift. Ships with a starter set (prose / email / jargon /
      numbers) that you're meant to edit into your own sentences.
- [x] **`whimpereval` CLI** — SwiftPM executable target (`Sources/whimpereval`).
      Feeds each clip through `SFSpeechURLRecognitionRequest` with
      `requiresOnDeviceRecognition = true` and the same custom-LM configuration the
      app uses, runs the result through `TranscriptProcessor`, and prints per-clip +
      aggregate **raw** and **processed** WER as a markdown table. Flags: `--clips`,
      `--locale`, `--settings-dir`, `--no-lm` (measures what the LM is worth),
      `--verbose` (word-level diff per clip).
- [x] WER computation (word-level Levenshtein) lives in
      `WhimperFlowKit/Eval/WordErrorRate.swift` as pure functions with their own
      tests. `WordAlignment.align` is the reusable diff primitive Phase 2 needs.
- [x] The phrase set taught to the custom LM moved to
      `WhimperFlowKit/Settings/CustomVocabulary.swift` so the app and the harness
      can't drift apart on what recognition is biased toward — a measured WER only
      means something if the two agree. Phase 1's corpus phrases plug in here.
- [x] Record baseline numbers in `Eval/RESULTS.md` (date, OS, recognizer, WER).
      **Baseline: 12.7% WER** over 24 clips / 363 words (M1 Air, macOS 15.5,
      en-GB, custom LM off because the dictionary is empty).

Acceptance: **met** — `make eval` prints a WER table (`make eval ARGS="--verbose"`
to pass flags). Verified end-to-end on synthetic `say`-generated clips, custom-LM
path included.

### What the baseline says (2026-07-19)

Full analysis in `Eval/RESULTS.md`. The short version, which **changes the
ordering below**:

| category | words | WER | share of all errors |
|---|---:|---:|---:|
| jargon | 77 | 42.9% | 72% |
| email | 110 | 6.4% | 15% |
| numbers | 69 | 5.8% | 9% |
| prose | 107 | 1.9% | 4% |

- Vocabulary is the whole problem: jargon is 21% of the words and 72% of the
  errors. Prose at 1.9% means the recognizer is fine on ordinary speech.
- `raw WER == processed WER` on all 24 clips — the pipeline currently changes
  nothing measurable, because the dictionary and snippets are empty and so the
  custom LM is never built. Phases 1–2 have their full headroom intact.
- **So: do Phases 1–2, not Phase 3.** A newer recognizer would mostly improve
  the part that already works.

### Finding: the ≥2s trailing-silence cliff

A clip ending in ≥2 seconds of silence makes `SFSpeechURLRecognitionRequest`
return an **empty** final result — the whole utterance is discarded. Verified by
appending pure silence to one good clip: 0s and 1s → 0.0% WER, 2s/3s/4s → 100%.
Independent of gain, locale, and container format. It cost 4.7 points of the
first baseline (17.4% → 12.7% once handled).

Now handled in `AudioSupport.SilenceTrimmer` (tested): `whimpereval` trims a temp
copy before recognition, Clip Recorder trims in place on save.

**Answered — and it was a real bug.** `SpeechProbe` (`make probe`) replayed a
clip through the streaming `SFSpeechAudioBufferRecognitionRequest` the app uses:
0s/1s/1.5s trailing silence transcribe fine, **2s+ returns an empty final result
while a partial still held the complete sentence**. `SpeechService` trusted that
final, so pausing ~2s before releasing the hotkey silently discarded the
dictation. Fixed via `WhimperFlowKit.TranscriptAccumulator` (an empty
transcription can never overwrite recognized text), with a regression test.

Two environment facts learned along the way, both worth remembering:
- The buffer-based request fails with `kAFAssistantErrorDomain 1107` and zero
  callbacks unless a live `AVAudioEngine` capture session runs in the same
  process — even inside a signed bundle.
- `prepareCustomLanguageModel` fails intermittently (kLSRErrorDomain 400) on
  vocabulary that compiles fine moments later. The app and the harness both used
  to give up after one attempt and run with no model at all; both now retry.

## Phase 1 progress — dictionary first pass (done)

Ten dictionary entries derived from the baseline's jargon errors took
**12.7% → 9.4% WER (26% relative)** with no pipeline code changes, and moved
nothing outside the jargon category. Entries are live in `settings.json`.

**Caveat on measurement:** `whimpereval --no-lm` produces byte-identical output
to running with the custom LM attached, because an unbundled CLI doesn't own the
client identifier `prepareCustomLanguageModel` binds to. So 9.4% is the text
pipeline alone; the LM's recognition-biasing upside is real in the app but not
in that number. To measure it, `whimpereval` needs to run from a bundle launched
via LaunchServices, the way `SpeechProbe` does — worth doing before the corpus
work, so Phase 1's main lever is actually observable.

## Phase 1 — Corpus-driven custom LM (biggest software win on current OS)

Today the custom LM only sees dictionary entries + snippet triggers, each with a flat
`count: 10`. Feed it a real personal corpus instead.

- [ ] **Corpus ingestion.** New Kit component `CorpusExtractor`: given user-supplied
      plain-text files (a folder the user drops exported emails / notes / README
      prose into, e.g. `~/Library/Application Support/WhimperFlow/corpus/`), emit:
      - unigram/2–3-gram phrase counts of frequent word sequences (pure Swift,
        deterministic, testable);
      - a proper-noun/jargon list (tokens that are OOV-looking: mixed case, digits,
        not in a small common-words list).
- [ ] **Extend `CustomLanguageModelStore`.** `phrases(from:)` grows a second source:
      corpus-derived `phraseCount`s with real counts (scaled/capped), and
      `SFCustomLanguageModelData` custom-pronunciation entries
      (`CustomPronunciation`) for jargon that the recognizer keeps mangling
      (e.g. product names, "k8s"-style terms). Keep the content-hash caching —
      hash must now include corpus digest.
- [ ] **Settings + UI.** `FlowSettings` gains `corpusEnabled: Bool?` (optional for
      JSON back-compat, per existing convention) and the Dictionary settings pane
      gains a "Personal corpus" section: choose folder, show phrase/pronunciation
      counts, "Rebuild" button.
- [ ] Re-run Phase 0 eval; log delta in `Eval/RESULTS.md`.

Acceptance: measurable WER drop on jargon-heavy clips; recompile only when corpus
digest changes; Kit stays AppKit-free.

## Phase 2 — Deterministic self-correction loop

Replicate Wispr's "learns from your edits" personalization as a pure lookup table.
Same misrecognitions recur constantly for a single speaker.

- [ ] **Correction capture.** In the History window, add per-entry "Correct…" edit:
      user fixes what should have been injected. Store pairs
      `(recognized phrase → corrected phrase)` in a new `CorrectionStore`
      (Kit, JSON-persisted next to `history.json`).
- [ ] **Rule derivation.** Kit function that diffs recognized vs corrected text
      (word-level LCS diff — reuse the WER machinery from Phase 0) and extracts
      minimal replacement pairs. A pair is *promoted* to an active rule once seen
      N times (default 2) or when the user explicitly confirms — avoids
      one-off-context corrections becoming global rules.
- [ ] **Pipeline integration.** Promoted rules feed the existing
      `DictionaryReplacer`/`PhraseMatcher` stage (they are just generated
      `DictionaryEntry`s), so ordering, verbatim semantics, and tests all come for
      free. They also flow into the custom LM via Phase 1's phrase source, closing
      the loop (bias recognition, not just post-fix).
- [ ] **Management UI.** Section in Dictionary settings listing learned rules with
      enable/disable/delete; everything inspectable, nothing hidden.
- [ ] Golden tests: diff extraction, promotion thresholds, round-trip persistence.

Acceptance: correcting the same misrecognition twice makes the third occurrence come
out right, verifiably in tests and in the eval harness.

## Phase 3 — macOS 26 upgrade: `SpeechAnalyzer`/`SpeechTranscriber` (biggest overall win)

**Decision point — requires OS upgrade from 15.5.** The macOS 26 `SpeechAnalyzer` API
is a newer-generation OS-provided on-device model (the one behind Notes/Voice Memos):
long-form aware, much better punctuation, dramatically faster, competitive with
Whisper-large-class on clean speech. Still Apple-downloaded via `AssetInventory`, so
the "no shipped models, no cloud" constraint holds unchanged.

- [ ] Pre-work (can do now, on 15.5): introduce a `Recognizer` protocol in the app
      layer that `SpeechService` implements, so the transcriber backend is swappable
      and the controller/pipeline don't care which engine produced the transcript.
- [ ] After upgrade: `SpeechAnalyzerService` implementing the protocol —
      `SpeechTranscriber` module, `AssetInventory` model install flow (replaces the
      Siri-toggle saga; verify with an updated `speechcheck`), volatile-results
      handling mapped onto the existing partial/final flow, vocabulary customization
      wired to Phase 1's corpus output.
- [ ] Keep `SFSpeechRecognizer` as fallback backend behind a setting; session
      rotation likely becomes unnecessary (SpeechAnalyzer is long-form) — gate it
      per backend.
- [ ] Re-run eval on both backends; record the head-to-head in `Eval/RESULTS.md`.

Acceptance: same hotkey→inject flow, new backend selectable in settings, WER
head-to-head documented. Watch: API is macOS 26+, so `#available` guards and the
Package.swift platform floor need care (CLT-only build — verify the macOS 26 SDK
ships with the CLT before committing to this phase).

## Phase 4 — Audio-in hygiene (cheap, real-world WER)

- [ ] **Input health check.** On session start, compute capture RMS for the first
      ~300 ms (plumbing exists via `speech.noteLevel`); if near-silent, show a HUD
      warning naming the active input device — catches the VP-style silent-stream
      class of failure before it reads as "bad accuracy".
- [ ] **Per-device settings.** Remember preferred input device + input gain hint in
      settings; warn when dictating on the built-in mic from far away (low RMS but
      not silent).
- [ ] Non-software: use one decent external mic at a fixed distance; re-record the
      Phase 0 clip set with it and compare — this bounds how much WER is acoustics.

## Phase 5 — Sentence-repair ceiling (explicitly deferred)

Rules can't semantically rewrite run-ons/restarts ("what I— what I mean is…").
Options if it ever matters enough:

- Bounded rule additions that stay deterministic: repeated-word collapse
  ("the the" → "the"), false-start pruning when a token sequence is immediately
  restated (conservative, golden-tested) — worth doing.
- Apple Foundation Models framework (macOS 26, on-device, offline) could do real
  rewrite — but it is **nondeterministic** and therefore a deliberate constraint
  change, off by default, decided separately. Not part of this plan.

---

## Order & effort

| Phase | Depends on | Effort | Expected impact |
|---|---|---|---|
| 0 Eval harness | — | S | enables everything |
| 1 Corpus LM | 0 | M | high (jargon/proper nouns) |
| 2 Self-correction | 0 (uses 1's LM hook) | M | high, compounds over time |
| 3 SpeechAnalyzer | OS upgrade decision | M–L | highest single win |
| 4 Audio hygiene | — | S | medium, prevents regressions |
| 5 Sentence repair | — | S (rules only) | low–medium |

Suggested sequence: **0 → 1 → 2**, with 4 slotted in anytime; take the Phase 3
OS-upgrade decision once 0–2 numbers show where the residual errors are (if residual
WER is mostly recognizer-level, upgrade; if it's vocabulary-level, phases 1–2 already
fixed it).

## Invariants (do not violate in any phase)

- No network calls anywhere in the dictation path.
- No models shipped in the app bundle; only OS-provided assets.
- All new text-transform logic lives in `WhimperFlowKit`, AppKit-free, covered by
  golden tests (`swift test`).
- Every personalization artifact (corpus phrases, learned rules) is user-visible,
  user-editable, and stored as plain JSON under Application Support.
