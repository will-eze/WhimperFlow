# WhimperFlow — Design Document

A faithful, fully local reproduction of **Wispr Flow** for macOS: hold a key, speak,
and polished text appears in whatever app you're using. No cloud calls, no bundled
AI models, and every line of app logic is **deterministic** — same input, same output,
always.

## 1. Research summary

Wispr Flow (wisprflow.ai) is a system-wide dictation utility whose defining traits are:

- **Works in every app** — text lands at the cursor of the frontmost application
  (Slack, Mail, VS Code, browsers…), not in its own window.
- **Push-to-talk UX** — hold a key (default `fn`), speak, release; a small floating
  HUD shows recording state. A toggle mode allows hands-free dictation.
- **"Polished" output** — filler words removed, punctuation and capitalization
  applied, numbers formatted, so rambled speech reads like written prose.
- **Personal dictionary** — user-taught words/names are both *recognized* better and
  *spelled* correctly on output.
- **Snippets** — spoken trigger phrases expand to canned text (signatures, addresses).
- **Per-app awareness** — different formatting styles per target app (casual for chat,
  code-friendly for editors).
- **Command phrases** — "scratch that", "new paragraph", etc.
- **History & stats** — past dictations, words dictated, estimated time saved.
- Marketed accuracy ≈97–99% on clean audio (i.e., modern on-device engines are in
  the same league).

## 2. The determinism constraint

Speech → text requires a recognition engine; there is no such thing as a high-accuracy
model-free recognizer. Per the agreed architecture decision:

- **Recognition**: macOS's built-in **on-device** Speech framework
  (`SFSpeechRecognizer` with `requiresOnDeviceRecognition = true`). We ship no model,
  send no audio anywhere; the OS engine is treated as a sensor, like the camera.
- **Everything WhimperFlow itself does is deterministic**: the entire
  transcript-processing pipeline is pure functions over strings driven by
  user-editable rule tables. No sampling, no randomness, no network. The unit-test
  suite pins the behavior.
- Recognition *biasing* is also deterministic configuration: dictionary terms are fed
  to the engine via `SFSpeechRecognitionRequest.contextualStrings` (Apple's supported
  vocabulary-boost mechanism, ≤100 phrases).

## 3. Architecture

Two SwiftPM targets plus a test target. Kit is AppKit-free and 100% unit-testable.

```
┌────────────────────────────  WhimperFlow (executable, AppKit/SwiftUI)  ─────┐
│ AppDelegate / StatusBarController      SettingsWindow (SwiftUI panes)      │
│ HotkeyMonitor (CGEventTap)             HistoryWindow (SwiftUI)             │
│ AudioCaptureEngine (AVAudioEngine)     HUDPanel (floating NSPanel)         │
│ SpeechService (SFSpeechRecognizer)     PermissionsManager                  │
│ TextInjector (pasteboard / CGEvent)    SoundCues                           │
│                 DictationController (orchestrator, state machine)          │
└──────────────────────────────────┬─────────────────────────────────────────┘
                                   │ depends on
┌──────────────────────────────────▼──────────  WhimperFlowKit (pure logic) ─┐
│ FlowSettings (Codable) + SettingsStore (JSON persistence, observable)     │
│ TranscriptProcessor pipeline:                                             │
│   Tokenizer → CommandInterpreter → FillerRemover → SpokenPunctuation      │
│   → DictionaryReplacer → SnippetExpander → NumberNormalizer               │
│   → CaseFormatter (normal/casual/code modes) → Joiner (smart spacing)     │
│ AppProfiles (bundle-id → formatting mode)                                 │
│ HistoryStore (JSONL) + DictationStats                                     │
└───────────────────────────────────────────────────────────────────────────┘
```

### Dictation data flow

1. `HotkeyMonitor` sees the configured key go down → `DictationController.begin()`.
2. `AudioCaptureEngine` starts an `AVAudioEngine` input tap → PCM buffers flow to
   both `SpeechService` (recognition) and the HUD (RMS level → waveform).
3. `SpeechService` streams partial transcripts (shown live in the HUD). On-device
   only; `contextualStrings` seeded from the dictionary + snippet triggers.
   Sessions auto-restart at ~50 s of audio so hands-free mode can run indefinitely
   (results are stitched).
4. Key released → final transcript → `TranscriptProcessor.process(raw, context)`
   where context = frontmost app's formatting mode + tail of previously injected
   text (for spacing/capitalization continuity).
5. `TextInjector` places the text at the cursor: pasteboard + synthetic ⌘V with
   clipboard save/restore (long text), or `CGEventKeyboardSetUnicodeString` typing
   (short text / "type" mode). "Scratch that" deletes the last injected block with
   an exact count of backspace events.
6. `HistoryStore` records the utterance (app, duration, raw & processed text).

### Pipeline stages (all pure, all table-driven)

| Stage | Behavior |
|---|---|
| CommandInterpreter | Whole-utterance commands: "scratch that", "undo that", "new line", "new paragraph" as standalone phrases → edit ops, not text. |
| FillerRemover | Removes configurable fillers (`um`, `uh`, `erm`, `you know`…) with word-boundary matching; never inside quoted/literal mode. |
| SpokenPunctuation | "comma" → `,`, "period"/"full stop" → `.`, "new line", "open quote", "ellipsis", "at sign", 40+ mappings; only when enabled. |
| DictionaryReplacer | User pairs (`jira` → `Jira`, `k eight s` → `k8s`), longest-match-first, optional case-sensitivity. |
| SnippetExpander | Trigger phrase (e.g. "insert my signature") → stored expansion. |
| NumberNormalizer | `twenty five dollars` → `$25`, `fifty percent` → `50%`, ordinals, `x dollars and y cents`; the OS engine already digitizes most bare numbers. |
| CaseFormatter | Modes: **normal** (sentence caps, standalone `i` → `I`), **casual** (no auto-caps for chat apps), **code** ("camel case foo bar" → `fooBar`, snake/kebab/pascal/all-caps phrase operators), **literal** (verbatim). |
| Joiner | Smart spacing against preceding text: no space after `(`/newline/start, none before punctuation, collapses doubles, sentence-caps after terminal punctuation of previous injection. |

### Determinism guarantees

- No `Date()`/randomness inside the pipeline (timestamps only in history records).
- Rule tables are ordered; replacement passes are longest-match-first, left-to-right.
- Locale-stable lowercase/uppercase transforms.
- The entire pipeline is exercised by golden unit tests (`swift test`).

## 4. Permissions & app lifecycle

| Permission | Used for | API |
|---|---|---|
| Microphone | audio capture | TCC prompt on first `AVAudioEngine` start |
| Speech Recognition | `SFSpeechRecognizer` | `SFSpeechRecognizer.requestAuthorization` |
| Accessibility | global hotkey tap + synthetic keystrokes | `AXIsProcessTrustedWithOptions` |

The app is a menu-bar-only agent (`LSUIElement = YES`), with an onboarding pane
showing live permission status and deep links into System Settings. Built as a real
`.app` bundle (TCC requires one) via `make app`; ad-hoc codesigned with a stable
bundle id `com.whimperflow.app`.

## 5. Feature list (superset of the brief)

Beyond the Wispr Flow core: toggle (hands-free) mode with auto-stop on silence,
Esc-to-cancel, live partial transcript in the HUD, per-app enable/disable and
formatting profiles, code mode for editors/terminals, spoken-punctuation engine,
number/currency normalization, "scratch that", snippet library, dictionary
import/export, dictation history with search + copy + stats (words, WPM, estimated
time saved vs 45 WPM typing), sound cues, mic device picker, on-device locale picker
showing which languages support offline recognition, launch-at-login, and a
first-run onboarding checklist.

## 6. Testing

- `WhimperFlowKitTests` (Swift Testing): golden tests per pipeline stage plus
  end-to-end `process()` scenarios per mode, settings JSON roundtrip, history stats.
- App-layer services are kept thin and isolated behind protocols; the orchestrator's
  state machine logic lives in Kit where it is testable.

## 7. Build

- Swift 6.1, SwiftPM only (no Xcode project), macOS 14+ deployment.
- `make app` → release build → assembles `WhimperFlow.app` (Info.plist with usage
  descriptions, `LSUIElement`) → ad-hoc codesign.
- `make test` → unit tests. `make run` → build & launch.
