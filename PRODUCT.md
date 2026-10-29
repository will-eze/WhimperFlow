# Product

<!-- impeccable:product-schema 1 -->

## Platform

macos (native SwiftUI/AppKit menu-bar app; not web, not iOS)

## Users

One user: Will, a second-year CS & AI student on a MacBook. He dictates in short holds of the key into chat
apps and Claude, mostly to brainstorm out loud (confirmed 2026-10-29). Long hands-free sessions and code dictation
exist but are secondary.

## Product Purpose

Hold a key, speak, release: polished text lands at the cursor of whatever app is in front. Success is that he
forgets the app is there, trusts what it typed, and can teach it a word in seconds when it gets one wrong.

## Positioning

A private, deterministic Wispr Flow: speech is recognised by Parakeet on his own Jarvis server over Tailscale,
with Apple's on-device recogniser as fallback. No cloud, no AI rewriting; every transformation after recognition
is a rule he can see and edit.

## Operating Context

- Lives in the menu bar; the user's attention is on another app while dictating, so the pop-up must be glanceable
  and never take focus.
- Brainstorming in chat/Claude means many short dictations in a row; mistakes are noticed after the text lands,
  usually a misheard name or jargon term.
- The server can be unreachable (off Tailscale, server down); the app must say which engine typed the text.

## Capabilities and Constraints

- Hold-to-talk hotkey (fn by default), quick-tap for hands-free, Escape cancels.
- Formatting pipeline: filler removal, spoken punctuation, numbers, dictionary, snippets, per-app modes
  (normal / casual / code / literal), voice functions ("flow spell …").
- History with raw vs processed text and stats; unsent recordings retried into History.
- Permissions needed: Microphone, Accessibility (hotkey + typing); Speech Recognition only for the Apple engine.
- Signed with the stable "WhimperFlow Dev" identity; installed by `make install` into /Applications.

## Brand Commitments

Name "WhimperFlow". No other committed visual identity.

## Evidence on Hand

Real history (`~/Library/Application Support/WhimperFlow`), Eval/RESULTS.md (5.4% WER server, 11.5% Apple).
No testimonials or external claims exist; never invent any.

## Product Principles

1. Pain points named by Will: setup and permissions, and teaching it words. Fix those first.
2. One home: menu bar for status and the last dictation, one main window for everything else (shown in the Dock
   while open). Confirmed 2026-10-29.
3. Correcting a mistake should start from the mistake (a History entry), not from an empty table.
4. Say plainly which engine is in use and what is missing, with the one action that fixes it.
