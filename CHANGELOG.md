# Changelog

Notable changes to Farol. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Copy and paste through the Edit menu. Pasting text that could run commands shows a confirmation first.
- Files copied in Finder paste as shell-escaped paths.
- A program asking to read or set the clipboard needs your approval.
- CI runs the style check on every push and pull request.

### Fixed

- The Farol config file now ends with a newline, so settings appended by hand stay on their own line.

## First commits

The groundwork before any release:

- libghostty embedded in a native macOS window
- Session sidebar with shortcuts and an attention light
- Themes with live previews, and settings inside the window
- App icon, `make install` and the style check
