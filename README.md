# LittleClean

[中文文档](README_zh.md) | English

LittleClean is a powerful and intelligent macOS cleaner and developer tool manager. It helps you reclaim valuable disk space by completely uninstalling unwanted applications and safely removing caches, logs, and leftovers, while also providing deep visibility into installed development tools and environments.

<img width="336" alt="Image" src="https://github.com/user-attachments/assets/4eb9d387-71de-4ddc-bf1e-fbeb42739c92" />
<img width="336" alt="Image" src="https://github.com/user-attachments/assets/29ff0c9b-5e2d-4d20-95d8-216b209e93a7" />
<img width="336" alt="Image" src="https://github.com/user-attachments/assets/d57b6f01-12bd-476a-aee9-b41b514e1796" />

## Installation

You can download the latest pre-compiled version from the [Releases](https://github.com/leibnizli/LittleClean/releases) page. (Requires macOS 14 or later)

Alternatively, you can clone the repository and build via Xcode.

## Features

### Uninstall Apps
Easily and completely remove unwanted applications along with their associated caches, preferences, containers, launch agents, and other leftovers. Items are moved to Trash so you can recover them if needed. Running apps are quit before uninstall. Homebrew Cask and Setapp apps are labeled in the list. LittleClean itself and protected system apps cannot be uninstalled.

You can also uninstall from Finder without opening the LittleClean window:
1. Launch LittleClean once so macOS can register its system service.
2. In Finder, select one or more `.app` bundles.
3. Choose **Services → Uninstall with LittleClean** from the context menu (or the Finder **Services** menu).
4. Review the confirmation dialog: the app bundle and related items are listed, and you can uncheck leftovers you want to keep. The `.app` itself cannot be unchecked.
5. Confirm to move the selected items to Trash. On success, no extra dialog is shown; failures still report an error.

### Safe Cleanup
LittleClean categorizes and safely cleans up unnecessary files occupying your disk. Select items and click **Clean**, or use the context menu to clean a single entry:
- **System Trash & Logs:** Empty the trash bin and clear system logs.
- **App Caches:** Clear `~/Library/Caches` to free up space.
- **Saved App State:** Remove saved application states for a fresh start.
- **Uninstalled App Leftovers:** Intelligently detect and remove leftovers in `~/Library/Application Support` for applications that have been uninstalled.
- **Container Leftovers:** Detect and remove orphaned app containers under `~/Library/Containers`.
- **Xcode Cleanup:** Clear DerivedData, iOS Simulator caches, and automatically remove unavailable simulators.
- **Home Directory Tool Caches:** Clear known developer tool caches in your home directory (for example npm, pnpm, Yarn, Bun, Deno, Gradle, Maven, and Cargo), while keeping the folders themselves.

### Deep Analysis
Read-only mode for complete visibility into development environments and disk usage. Nothing in this mode can be deleted:
- **Xcode Archives & Simulators:** Inspect Xcode Archives and simulator devices grouped by runtime version.
- **Homebrew & MacPorts:** Track Homebrew Formulae/Casks and MacPorts ports (plus MacPorts distfiles and build caches) in Installed Tools.
- **Node.js:** Exhaustively scans for Node.js installations across all major version managers (`nvm`, `fnm`, `volta`, `asdf`, `nodenv`, `n`, Homebrew, `/usr/local`, and active PATH) to find global packages.
- **Global Package Managers:** View global packages and their sizes for `npm`, `pnpm`, `Yarn`, `Cargo` (Rust), Ruby Gems, and Go.
- **Other PATH Tools:** List additional non-system binaries found on your PATH.
- **Home Directory Overview:** Enumerate non-system items under `~`. Python venv roots (`~/.virtualenvs` and similar), conda installs (`~/miniconda3` and similar), and `~/.local` (Pipx and uv tools) are expandable inline.

### Search, Navigation & More
- **Real-time Search:** Instantly filter through thousands of caches, tools, and leftovers.
- **Sortable Table:** Sort by path or size; default is largest first.
- **Reveal in Finder:** Open the exact directory or application bundle in Finder with a single click.
- **Visual Storage Indicator:** A disk usage pie chart showing used vs. free space at a glance.
- **Full Disk Access:** Detects missing Full Disk Access and can open System Settings when needed for deeper scans and cleanup.
- **Update Check:** Notices when a newer release is available on GitHub.
- **Bilingual UI:** English and Simplified Chinese.

## License
MIT
