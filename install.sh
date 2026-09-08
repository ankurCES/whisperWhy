#!/usr/bin/env bash
# WhisperWhy — one-line installer.
#
#   curl -fsSL https://raw.githubusercontent.com/ankurCES/whisperWhy/main/install.sh | bash
#
# What it does:
#   1. Checks macOS + Apple Silicon prerequisites (git, swiftc, cmake via Homebrew if needed)
#   2. Clones https://github.com/ankurCES/whisperWhy (or updates an existing checkout)
#   3. Builds vendored whisper.cpp (Metal), downloads a ggml model, builds + signs the app
#   4. Installs WhisperWhy.app into /Applications
#   5. Optionally pulls a small Ollama model for LLM cleanup (skip: WW_NO_OLLAMA=1)
#
# Env overrides:
#   WW_DIR=~/.whisperwhy     checkout/build location
#   WW_MODEL=base.en         whisper ggml model to fetch (tiny.en|base.en|small.en|...)
#   WW_NO_OLLAMA=1           skip Ollama model pull
#   WW_NO_BREW=1             fail instead of installing Homebrew when cmake is missing
set -euo pipefail

REPO_URL="https://github.com/ankurCES/whisperWhy.git"
INSTALL_DIR="${WW_DIR:-$HOME/.whisperwhy}"
WHISPER_MODEL="${WW_MODEL:-base.en}"
OLLAMA_MODEL="${WW_OLLAMA_MODEL:-llama3.2:3b}"

say()  { printf '\033[1;36m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  ! %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }

# --- prerequisites -----------------------------------------------------------
say "Checking prerequisites"
[ "$(uname -s)" = "Darwin" ] || die "WhisperWhy is macOS-only."
mac_ver="$(sw_vers -productVersion)"
mac_major="${mac_ver%%.*}"
[ "$mac_major" -ge 14 ] || die "macOS 14+ required (found $mac_ver)."
ok "macOS $mac_ver"

command -v git >/dev/null || die "git not found. Install Xcode Command Line Tools: xcode-select --install"
if ! command -v swiftc >/dev/null; then
  die "swiftc not found. Install Xcode or run: xcode-select --install"
fi
ok "git + Swift toolchain"

if ! command -v cmake >/dev/null; then
  if command -v brew >/dev/null; then
    say "Installing cmake via Homebrew"
    brew install cmake
  elif [ "${WW_NO_BREW:-0}" != "1" ]; then
    say "Installing Homebrew (needed for cmake)"
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    # brew shellenv for this script's lifetime
    if [ -x /opt/homebrew/bin/brew ]; then
      eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [ -x /usr/local/bin/brew ]; then
      eval "$(/usr/local/bin/brew shellenv)"
    fi
    command -v brew >/dev/null || die "Homebrew installed but not on PATH. Open a new shell and re-run."
    brew install cmake
  else
    die "cmake not found and WW_NO_BREW=1. Install cmake (brew install cmake) and re-run."
  fi
fi
ok "cmake $(cmake --version | head -1 | awk '{print $3}')"

# --- source ------------------------------------------------------------------
say "Fetching WhisperWhy source"
if [ -d "$INSTALL_DIR/.git" ]; then
  git -C "$INSTALL_DIR" pull --ff-only --quiet && ok "updated $INSTALL_DIR"
else
  git clone --depth 1 "$REPO_URL" "$INSTALL_DIR" --quiet && ok "cloned to $INSTALL_DIR"
fi
cd "$INSTALL_DIR"

# --- build -------------------------------------------------------------------
say "Building whisper.cpp (vendored, Metal)"
make whisper
ok "whisper.cpp static libs"

say "Downloading whisper model ($WHISPER_MODEL)"
make model MODEL="$WHISPER_MODEL"
ok "model ready"

say "Building WhisperWhy.app"
make
ok "build/WhisperWhy.app"

# --- install -----------------------------------------------------------------
say "Installing to /Applications"
make install
ok "/Applications/WhisperWhy.app"

# --- optional: Ollama for LLM cleanup ----------------------------------------
if [ "${WW_NO_OLLAMA:-0}" != "1" ]; then
  if command -v ollama >/dev/null; then
    say "Ollama found — pulling cleanup model ($OLLAMA_MODEL)"
    if curl -fsS --max-time 2 http://localhost:11434/api/tags >/dev/null 2>&1; then
      ollama pull "$OLLAMA_MODEL" && ok "ollama model ready" || warn "ollama pull failed; cleanup will fall back to raw transcripts"
    else
      warn "Ollama installed but not running. Start it later: 'ollama serve' then 'ollama pull $OLLAMA_MODEL'."
    fi
  else
    warn "Ollama not installed — LLM cleanup will be inactive until you install it (brew install ollama)."
    warn "WhisperWhy still works: raw whisper transcripts are pasted directly."
  fi
fi

cat <<EOF

$(printf '\033[1;32mWhisperWhy installed.\033[0m')

Launch it:        open /Applications/WhisperWhy.app
First launch grants needed:
  • Microphone              (dictation)
  • Accessibility           (paste at cursor)
  • Input Monitoring        (global hotkey)
  • Speech Recognition      (only if you switch to the Apple engine)

Dictate: hold Fn (or tap ⌘Fn to latch), speak, release — cleaned text lands
at the cursor. Tray icon (waveform) → Settings to configure engine/model.
EOF
