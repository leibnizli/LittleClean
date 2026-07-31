# Plan: "Installed Tools" informational section (display-only, no cleanup)

## Goal
Add a top-level, expandable, **display-only** row "Installed Tools" to the table.
It auto-detects non-system package managers/runtimes from `$PATH` and lists their
installed modules (names only). No checkbox, no Finder button, no uninstall — pure info.
Nesting supported (e.g. Homebrew → Formulae / Casks → names).

## 1. Data model — `CategoryItem`
- Add `var isDisplayOnly: Bool = false`.
- Display-only items use `cleanType = .none` and are skipped by existing
  `isCleanable` / `collectCleanableSelected` (already `.none`-aware), so they
  can never be cleaned or selected. No changes needed in selection helpers.

## 2. UI — `ContentView` table cells
- **Path column**: if `item.isDisplayOnly`, render
  `Image(systemName: item.iconName).foregroundColor(item.iconColor)` instead of
  the checkbox `Button`. (Replaces the disabled grey square with a tool icon.)
- **Finder column**: hide the magnifying-glass `Button` when `item.isDisplayOnly`.
- Size column: empty for display-only rows. Counts go in `note` (renders inline,
  e.g. `Homebrew (42 formulae, 7 casks)`).

## 3. New scan — `scanInstalledTools() -> [CategoryItem]`
Runs on a background thread. Returns ONE top-level display-only node
"Installed Tools" (note: "read-only") with children per detected manager.

### Detect non-system PATH dirs
- Parse `$PATH`, drop system dirs: `/usr/bin`, `/bin`, `/usr/sbin`, `/sbin`,
  `/System/*`, `/Library/*`, `/usr/libexec`, `/usr/lib/*`, `/AppleInternal`,
  Xcode toolchain dirs. Dedupe, keep existing dirs.

### Per-manager module lists (name only; shell out, parse stdout)
Detected by checking the manager binary is in PATH (reuse `isBinaryInPATH`):
| Manager | Command | Parse |
|---|---|---|
| Homebrew | `brew list --formula` / `--cask` | one name per line → two sub-groups "Formulae (N)", "Casks (M)" |
| npm (global) | `npm ls -g --depth=0 --parseable` | basename of each line ≠ root |
| pnpm (global) | `pnpm ls -g --parseable` (fallback: list `pnpm root -g`) | basenames |
| Yarn (global) | `yarn global list --depth=0` | regex name before `@` |
| Cargo | `cargo install --list` | lines `^(\S+) v` |
| Ruby gems | `gem list --local` | token before ` (` |
| Go | `go env GOPATH` → list `<GOPATH>/bin` | binary names |
| Pipx | `pipx list --short` | one app per line |

Each manager → display-only parent node (icon + color) with module-name leaves.
If a manager's command fails/empty, fall back to listing binaries in its bin dir.

### Catch-all "Other PATH tools"
For non-system PATH dirs **not** owned by a detected manager
(e.g. brew owns `/opt/homebrew/bin` + `/usr/local/bin`; cargo owns `~/.cargo/bin`;
go owns `GOPATH/bin`; pipx owns `~/.local/bin`; etc.), create one display-only
child per dir named by the path, with binary names as leaves. Ensures *all*
non-system bins are represented without duplicating manager-owned dirs.

All nodes: `cleanType = .none`, `isDisplayOnly = true`, `sizeBytes = 0`.

## 4. Wire into scan — two-phase (keep existing list snappy)
- `performScan` unchanged for phase 1 (existing rules) → sets `categories`,
  `isScanning = false`.
- Then call new `loadInstalledToolsAsync()`: background `scanInstalledTools()`,
  merge into `categories` on main when ready.
- Re-entry/staleness guard via a `toolsLoadToken: Int` — each scan increments it;
  a pending merge only applies if its token still matches and `!isScanning`.
  Prevents duplicate/stale appends across rescans.

## 5. Build & verify
`xcodebuild -project LittleClean.xcodeproj -scheme LittleClean build`.

## Out of scope
- Sizes/versions (user chose name-only).
- Uninstall / cleanup actions for this section.
- Lazy on-expand loading (Table API computes children upfront; background
  two-phase load covers responsiveness instead).
