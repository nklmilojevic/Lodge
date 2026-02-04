# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Lodge is a lightweight clipboard manager for macOS written in Swift/SwiftUI. It monitors clipboard history, provides quick search, and supports pinned items with keyboard shortcuts. Requires macOS 14 (Sonoma) or higher.

## Build Commands

```bash
# Build the project
xcodebuild -scheme Lodge -configuration Debug

# Run all tests
xcodebuild test -scheme Lodge

# Open in Xcode
open Lodge.xcodeproj

# Run SwiftLint
swiftlint

# Run Periphery (unused code detection)
periphery scan
```

Tests use an in-memory database when the `enable-testing` launch argument is present (configured in the test scheme).

## Architecture

### Core Singletons

- **AppState.shared** (`Observables/AppState.swift`): Central UI state - selection, keyboard navigation, window focus
- **History.shared** (`Observables/History.swift`): Manages history items, applies search, handles sorting
- **Clipboard.shared** (`Clipboard.swift`): Timer-based clipboard monitoring (default 500ms polling)
- **Storage.shared** (`Storage.swift`): SwiftData persistence layer

### Data Flow

1. `Clipboard` polls system pasteboard, creates `HistoryItem` models
2. `Storage` persists items to SQLite via SwiftData
3. `History` loads/filters items, applies search via `Search`
4. `AppState` coordinates UI state for `ContentView` and subviews

### Key Components

- **HistoryItem** (`Models/HistoryItem.swift`): SwiftData model storing text, RTF, HTML, images, files. Has `supersedes()` logic for deduplication
- **Search** (`Search.swift`): Multi-mode search (exact, fuzzy via Fuse, regex, mixed)
- **FloatingPanel** (`FloatingPanel.swift`): Custom non-activating NSPanel for the popup UI
- **Settings panes** (`Settings/`): General, Appearance, Storage, Pins, Ignore, Advanced

### State Management

Uses Swift's `@Observable` macro pattern. Views observe singleton state objects directly - no Redux-style architecture.

### Dependencies (Swift Package Manager)

- `Defaults`: User preferences with `@Default` property wrapper
- `KeyboardShortcuts`: Global hotkey handling
- `Fuse`: Fuzzy search implementation
- `Sparkle`: Auto-updates
- `Sauce`: Keyboard utilities

## Localization

40+ languages supported. Uses Bartycrouch for string extraction and DeepL for translation. String files organized by feature in `.lproj` folders.

## Code Style

SwiftLint configured with minimal rules (see `.swiftlint.yml`). Ignores comment line length and TODO warnings.
