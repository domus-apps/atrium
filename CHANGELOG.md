# Changelog

All notable changes to Atrium are documented here. The release workflow publishes each version's section as the GitHub release notes and embeds it in the Sparkle appcast, so the in-app update dialog shows the same notes. A release fails early if its version has no section here.

Keep each bullet on a single line: release notes render line breaks literally (both on GitHub and in the update dialog), so wrapped lines would break mid-sentence.

## 1.0.0

- Initial release: hold ⌥ and tap Tab to switch between windows — every window of every app, minimized and hidden ones included, on whichever screen your cursor is.
- Live window previews on every card, streaming in as they capture; off-screen windows (minimized, hidden, other Spaces) are pictured from the window server's retained backing store, and previews persist across relaunches.
- ⌥` scopes the switcher to the frontmost app's own windows, like the system's ⌘` but with the full panel.
- Cycle with Tab (hold to repeat, ⇧ for backwards), move with the arrow keys, hover or click with the mouse, commit with Return or by releasing ⌥, cancel with Escape.
- A clear Liquid Glass panel that adapts to light and dark mode, in the Domus family's visual language.
- First-run onboarding gates on the Accessibility permission (Screen Recording optional, for previews), and Sparkle keeps the app up to date.
