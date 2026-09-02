# Changelog

All notable changes to Atrium are documented here. The release workflow publishes each version's section as the GitHub release notes and embeds it in the Sparkle appcast, so the in-app update dialog shows the same notes. A release fails early if its version has no section here.

Keep each bullet on a single line: release notes render line breaks literally (both on GitHub and in the update dialog), so wrapped lines would break mid-sentence.

## 1.2.0

### Added

- Minimized windows are marked with the same diamond (◆) the Window menu uses, right before their title.

### Changed

- The selection highlight now follows what's behind the panel — gray over a bright screen, deeper and darker over a dark one, and glowing brighter instead in dark mode.
- The panel has rounder corners and a thinner, subtler edge highlight.

## 1.1.0

### Added

- Atrium now speaks Korean — the menu, Settings, and the welcome guide follow your macOS language.

### Fixed

- Alternating between Option+Tab and Option+` briefly flashed frosted glass while the panel changed size; the switch is seamless now.
- The welcome guide's illustration was slightly off-center inside its panel.

## 1.0.2

### Added

- Spotlight now finds the app by its Korean name and by what it does — 아트리움, 애트리움, 창 전환, and window switcher all match.

## 1.0.1

- Fixed: installing by COPYING the app (instead of Finder-moving it) left it running from Gatekeeper's translocated read-only path, which blocked Sparkle updates — the app now detects this at launch, clears the quarantine flag, and relaunches itself from its real location.

## 1.0.0

- Initial release: hold ⌥ and tap Tab to switch between windows — every window of every app, minimized and hidden ones included, on whichever screen your cursor is.
- Live window previews on every card, streaming in as they capture; off-screen windows (minimized, hidden, other Spaces) are pictured from the window server's retained backing store, and previews persist across relaunches.
- ⌥` scopes the switcher to the frontmost app's own windows, like the system's ⌘` but with the full panel.
- Cycle with Tab (hold to repeat, ⇧ for backwards), move with the arrow keys, hover or click with the mouse, commit with Return or by releasing ⌥, cancel with Escape.
- A clear Liquid Glass panel that adapts to light and dark mode, in the Domus family's visual language.
- First-run onboarding gates on the Accessibility permission (Screen Recording optional, for previews), and Sparkle keeps the app up to date.
