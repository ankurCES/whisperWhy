# WhisperWhy

Local dictation for macOS, notch style — a free, fully-local take on
[Wispr Flow](https://wisprflow.ai.com)/[FreeFlow](https://github.com/zachlatta/freeflow)
with the [codenotch](https://github.com/vinzdg/codenotch) top-of-screen status pill.

Hold **Fn** (or tap **⌘Fn** to latch) anywhere in macOS, speak, release —
your words are transcribed **on-device by whisper.cpp (Metal)**, cleaned up by
a **local LLM** (Ollama by default), and pasted into whatever text field the
cursor is in. No audio, transcript, or text ever leaves the machine.

![flow](docs/flow.svg)

## Features

| | |
|---|---|
| **Local STT** | whisper.cpp (ggml models, Metal accelerated) or Apple on-device Speech |
| **LLM cleanup** | Filler removal, grammar, punctuation via any OpenAI-compatible endpoint — Ollama, LM Studio, llama.cpp server, Groq, OpenAI |
| **Paste anywhere** | Synthetic ⌘V at the focused cursor; clipboard is snapshotted and restored; transient pasteboard markers keep clipboard managers from recording dictation |
| **Hotkey** | Global Fn hold-to-talk; ⌘ latches tap-mode (FreeFlow behavior); Esc cancels |
| **Notch UI** | Borderless non-activating panel pinned top-center: idle → recording (pulse + timer) → transcribing → cleaning → result flash |
| **Tray icon** | Status item menu: Settings, model download, quit |
| **Keyboard-layout aware** | ⌘V resolves the V key via the current input source (non-ANSI layouts work) |

## Build & run

Requirements: macOS 14+, Xcode or CLT, CMake (`brew install cmake`), an
internet connection once to fetch the model.

```bash
make whisper            # clone + build vendored whisper.cpp (Metal on)
make model              # download ggml-base.en (~148 MB) into models/
make                    # swiftc → build/WhisperWhy.app (ad-hoc signed)
make run                # launch
```

Other targets: `make smoke` (transcribe a bundled sample through the real
model, no GUI), `make test` (unit tests), `make typecheck`, `make model
MODEL=small.en`.

First launch grants: Microphone, Accessibility + Input Monitoring (hotkey and
paste), and Speech Recognition if you enable the Apple engine.

## Configure

Ollama is the default cleanup provider (`http://localhost:11434`,
`llama3.2:3b` — any model works):

```bash
ollama pull llama3.2:3b
```

Point `llmBaseURL` at any OpenAI-compatible server (`/v1` is appended
automatically). To disable LLM cleanup entirely, toggle it off in Settings —
raw whisper output is pasted as-is.

## Architecture

```
Sources/
  App.swift                  @main SwiftUI shim
  AppDelegate.swift          tray menu, wiring, lifetime
  HotkeyManager.swift        CGEvent tap: Fn hold / ⌘ latch / Esc cancel
  AudioRecorder.swift        AVAudioEngine → 16 kHz mono PCM WAV
  WhisperSTT.swift           whisper.cpp C interop (module map)
  AppleSpeechService.swift   on-device SFSpeechRecognizer fallback
  LLMCleanupService.swift    OpenAI-compatible /chat/completions cleanup
  TranscriptCore.swift       pure: finalize text, WAV decode (unit-tested)
  PasteService.swift         clipboard snapshot → ⌘V → restore
  DictationController.swift  pipeline orchestration
  NotchPanel.swift           borderless non-activating NSPanel
  NotchWindowController.swift top-center placement, state sizing
  NotchViewModel/RootView    pill states + SwiftUI chrome
  SettingsStore/View         UserDefaults-backed settings + SwiftUI form
```

Pipeline: `hotkey → record → WAV → whisper → (LLM cleanup) → pasteboard → ⌘V`.
`make smoke` proves the STT half without a GUI; `make test` covers the pure
cores; `ollama` + curl proves the cleanup half.

## Attribution

Design ideas and mechanisms borrowed with gratitude from
[FreeFlow](https://github.com/zachlatta/freeflow) (event-tap hotkeys, paste
pipeline, transient pasteboard markers, keyboard-layout key resolution) and
[codenotch](https://github.com/vinzdg/codenotch) (non-activating notch panel,
top-center placement, status item). whisper.cpp by
[ggml-org](https://github.com/ggml-org/whisper.cpp).

## License

MIT
