# Muster

A native macOS app for managing git repositories with automatic sync, dependency management, and embedded terminal.

## Features

- **Repository Management**: Clone and track repositories from GitHub/GitLab via SSH
- **Auto-sync**: Master copies stay up-to-date with remote
- **Named Checkouts**: Create isolated workspaces with user-defined names
- **Offline Deps**: Checkouts install dependencies from cache (`pnpm i --frozen-lockfile --offline`)
- **Embedded Terminal**: Ghostty-powered terminal view (libghostty)

## Directory Structure

```
~/.muster/                    # Hidden - internal data
├── repos/                    # Master copies (auto-synced)
└── config.json

~/muster/                     # Visible - user workspaces
└── <repo>/<checkout>/        # Your working directories
```

## Setup

### Prerequisites

- Xcode 15.3+ (Swift 5.10)
- macOS 14.0+ (Sonoma)
- SSH keys configured for GitHub/GitLab

### Building

1. Open Xcode and create a new macOS App project named "Muster"
2. Add the MusterCore package as a local dependency
3. Copy the `Muster-macOS/` files into the app target
4. Build and run

### Option A: Using `xcodegen` (recommended)

```bash
brew install xcodegen
cd /path/to/muster
xcodegen generate
open Muster.xcodeproj
```

### Option B: Manual Xcode Setup

1. Open Xcode → File → New → Project
2. Choose "macOS App" template, name it "Muster"
3. File → Add Package Dependencies → Add Local → select this directory
4. Drag `Muster-macOS/*.swift` files into your project
5. In target settings:
   - Add MusterCore to "Frameworks and Libraries"
   - Set deployment target to macOS 14.0
   - Disable App Sandbox in Signing & Capabilities

## Architecture

```
MusterCore (Swift Package)     # Shared business logic
├── Models/                    # SwiftData models
└── Services/                  # Git, PackageManager, Path services

Muster-macOS (App Target)      # macOS UI
├── Views/                     # SwiftUI views
└── Bridging/                  # libghostty C bridge (TODO)
```

## TODO

- [ ] Phase 2: libghostty terminal integration
- [ ] Phase 4: Background sync engine with FSEvents
- [ ] Menu bar status item
- [ ] Keyboard shortcuts
