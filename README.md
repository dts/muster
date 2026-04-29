# Muster

<p align="center">
  <img src="Muster-macOS/Assets.xcassets/AppIcon.appiconset/icon_256.png" alt="Muster" width="128" height="128">
</p>

A native macOS app for managing git repositories. Muster keeps a synced master copy of each repo and lets you spin up isolated checkouts instantly — no waiting for clones, no fighting over branches.

## Why Muster?

Working on multiple features or reviews at once means juggling branches, stashing changes, or maintaining multiple clones. Muster solves this by separating the "source of truth" from your working directories:

- **Master copies** live in `~/.muster/repos/` and stay synced with remote
- **Checkouts** are instant local clones in `~/muster/<repo>/<name>/` — each with its own branch and terminal
- **Dependencies** install from cache (offline `pnpm i`), so new checkouts are ready in seconds

## Features

- **Add repositories** via SSH URL — cloning runs in the background
- **Create named checkouts** on any branch (existing or new)
- **Embedded terminal** per checkout with status indicators (idle/busy)
- **Auto-sync** keeps master copies up to date
- **Offline deps** — checkouts install from the master's cached `node_modules`
- **Drag to reorder** checkouts in the sidebar
- **Branch monitoring** — sidebar reflects current branch in real-time

## Quick Start

1. **Add a repository**: Click `+` or press `⌘N`, paste the SSH URL
2. **Create a checkout**: Right-click the repo → New Checkout, give it a name and branch
3. **Start working**: Click the checkout to open its terminal

Each checkout is fully isolated — switch between features, reviews, or experiments without touching your other work.

## Directory Structure

```
~/.muster/                    # Hidden — internal data
├── repos/                    # Master copies (auto-synced)
└── config.json

~/muster/                     # Visible — your workspaces
└── <repo>/<checkout>/        # Working directories
```

## Building

### Prerequisites

- Xcode 15.3+ (Swift 5.10)
- macOS 14.0+ (Sonoma)
- SSH keys configured for GitHub/GitLab

### Option A: Using xcodegen (recommended)

```bash
brew install xcodegen
cd /path/to/muster/the-core
xcodegen generate
open Muster.xcodeproj
```

### Option B: Manual Xcode Setup

1. Open Xcode → File → New → Project → macOS App, name it "Muster"
2. File → Add Package Dependencies → Add Local → select this directory
3. Drag `Muster-macOS/*.swift` files into your project
4. In target settings:
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
└── Operations/                # Background operation tracking
```

## Terminal Status Integration

Muster uses OSC 99 escape codes to show terminal state in the sidebar. The indicator colors are:

- **Green** — idle, ready for input
- **Orange** — busy running a command
- **Red** — waiting for permission (e.g., a tool approval prompt)

To enable basic idle/busy indicators, add to your `.zshrc`:

```zsh
muster_preexec() { printf '\e]99;muster;state=busy\a' }
muster_precmd() { printf '\e]99;muster;state=idle\a' }
autoload -Uz add-zsh-hook
add-zsh-hook preexec muster_preexec
add-zsh-hook precmd muster_precmd
```

Tools that prompt for permission can send `state=permission` to show the red indicator.
