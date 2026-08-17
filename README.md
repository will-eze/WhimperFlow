# WhimperFlow

System-wide voice dictation for macOS, in the spirit of Wispr Flow — hold a key,
speak, and polished text appears at your cursor in **any** app. Fully local,
fully deterministic: no cloud calls, no bundled AI models, and every formatting
decision is a rule you can see, configure, and unit-test. Speech becomes text via
macOS's built-in **on-device** recognition engine (the same one that powers
Dictation); everything after that is pure, deterministic logic.

## Features

- **Push-to-talk**: hold the hotkey (default Right ⌘), speak, release — text lands
  at your cursor. Quick-tap for hands-free mode (auto-stops after silence). Esc cancels.
- **Live HUD** with waveform and streaming transcript near the bottom of the screen.
- **Deterministic polish**: filler-word removal ("um", "you know"…), sentence
  capitalization, terminal punctuation, smart spacing against the text already
  around your cursor (read via the Accessibility API).
- **Spoken punctuation & structure**: "comma", "period", "question mark",
  "new line", "new paragraph", "open quote/close quote", "at sign",
  "underscore", 40+ mappings, plus a few emoji ("smiley face" → 🙂).
- **Numbers**: "twenty five dollars" → `$25`, "fifty percent" → `50%`,
  "three point one four" → `3.14`, "twenty fifth" → `25th` (AP style: small
  numbers stay words).
- **Personal dictionary**: teach it "jira → Jira" or "k eight s → k8s"; entries
  also bias recognition itself (Apple's `contextualStrings`).
- **Snippets**: say "insert my signature" and your saved block appears.
- **Commands**: "scratch that" (deletes the last dictation), "press enter", "press tab".
- **Per-app profiles**: Normal prose in Mail, casual (no auto-caps) in Slack,
  code mode in your editor ("snake case user account id" → `user_account_id`),
  or disable dictation per app.
- **History & stats**: searchable local history, words dictated, average WPM,
  time saved vs typing.
- **100% local**: on-device recognition is *enforced* (`requiresOnDeviceRecognition`);
  the app makes zero network requests.

## Requirements

- macOS 14+ (built on macOS 15), Apple silicon or Intel.
- Xcode Command Line Tools (Swift 6.1) — no Xcode needed.
- Dictation language downloaded: System Settings → Keyboard → Dictation
  (this provides the on-device recognition model for your language).

## Build & run

```sh
make test   # 87 unit tests for the deterministic engine
make app    # builds WhimperFlow.app (release, ad-hoc signed)
make run    # builds and launches
make record # opens Clip Recorder to record the eval clip set
make eval   # word error rate over those clips (see Eval/README.md)
```

On first launch, the Settings window opens on the Permissions tab. Grant:

1. **Microphone** — capture your voice.
2. **Speech Recognition** — the on-device engine.
3. **Accessibility** — the global hotkey and typing text into other apps
   (System Settings → Privacy & Security → Accessibility → enable WhimperFlow).

Then hold **Right ⌘** and talk. The menu-bar mic icon shows state; everything is
configurable in Settings.

> Because the bundle is ad-hoc signed, macOS re-prompts for permissions if you
> rebuild. Rebuild + re-grant Accessibility is the usual dev loop.

## Architecture

See [DESIGN.md](DESIGN.md). Short version: `WhimperFlowKit` is a pure, AppKit-free
library containing the entire text pipeline (tokenizer → fillers → spoken
punctuation → dictionary → snippets → numbers → case/mode formatting → smart
joiner) plus settings/history stores — all covered by `swift test`. The app
target wraps it with AVAudioEngine capture, `SFSpeechRecognizer` streaming
(session-chunked for unlimited length), a CGEvent-tap hotkey, pasteboard/CGEvent
text injection, and SwiftUI settings/history/HUD.

## Measuring accuracy

`make record` opens a small recorder that prompts you with a sentence, captures
you reading it, and writes the paired audio/reference files. `make eval` then
runs those clips through the real recognizer and the real pipeline and reports
word error rate, raw and processed, so accuracy changes have before/after
numbers instead of impressions. Layout and flags in
[Eval/README.md](Eval/README.md); results log in [Eval/RESULTS.md](Eval/RESULTS.md);
the roadmap it serves is [ACCURACY_PLAN.md](ACCURACY_PLAN.md).

## Determinism

Same audio → same transcript (fixed OS engine, no sampling) → same output text:
the pipeline has no randomness, no clocks, no network, and its behavior is
pinned by golden tests. What the OS recognizer hears is the only sensor; every
transformation after it is yours to inspect in Settings.
