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
Disk and migration tests use temporary directories. Clipboard tests use a private
pasteboard, a manual clock, and a separate preferences domain. The test plan has
unit tests only. Keep `Package.resolved` in version control.

## Architecture

### Core Singletons

- **AppState.shared** (`Observables/AppState.swift`): Central UI state - selection, keyboard navigation, window focus
- **History.shared** (`Observables/History.swift`): Popup state and task coordination
- **Clipboard.shared** (`Clipboard.swift`): Timer-based clipboard monitoring (default 500ms polling)
- **Storage.shared** (`Storage.swift`): SwiftData persistence layer

### Data Flow

1. `Clipboard` polls the system pasteboard and captures plain data snapshots.
2. `ContentProcessor` extracts text and computes hashes on a worker task.
3. `HistoryService` applies duplicate rules, sorting, and data limits.
4. `HistoryRepository` saves each operation once and restores state on failure.
5. `History` publishes saved changes and requests searches on value snapshots.
6. `AppState` coordinates selection and clipboard actions.

### Key Components

- **HistoryItem** (`Models/HistoryItem.swift`): SwiftData model for copied data and stored search metadata
- **HistoryService** (`HistoryService.swift`): History operations, duplicate detection, and retention
- **ImageProcessingService** (`ImageProcessingService.swift`): Bounded thumbnail cache and OCR workers
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
- `SwiftSoup`: Local HTML text extraction without remote resource loading

See [docs/architecture.md](docs/architecture.md) for transaction rules, task
limits, migration behavior, and performance checks.

## Localization

40+ languages supported. Uses Bartycrouch for string extraction and DeepL for translation. String files organized by feature in `.lproj` folders.

## Code Style

SwiftLint configured with minimal rules (see `.swiftlint.yml`). Ignores comment line length and TODO warnings.
