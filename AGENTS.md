# Repository Guidelines

## Project Structure & Module Organization

Lark Peek is a Swift 6 package targeting macOS 14+. `Sources/LarkPeek/` contains the SwiftUI application and panel UI. Reusable models, parsing, chat matching, CLI execution, and command-policy code live in `Sources/LarkPeekCore/`. Add unit tests under `Tests/LarkPeekCoreTests/`, usually beside the feature area they cover. App metadata and icons are in `Resources/`; development, packaging, signing, and notarization helpers are in `Scripts/`. Generated products belong in `.build/` or `dist/` and must not be committed.

## Build, Test, and Development Commands

- `./Scripts/test.sh` runs the Swift Testing suite with isolated caches and the required macOS SDK settings.
- `swift run LarkPeek` builds and launches the executable directly for local development.
- `./Scripts/setup-local-signing.sh` creates or repairs the local self-signed code-signing identity. It may prompt for Keychain access.
- `./Scripts/build-app.sh` creates a signed release bundle at `dist/Lark Peek.app`.
- `codesign --verify --deep --strict 'dist/Lark Peek.app'` verifies the resulting bundle.
- `./Scripts/notarize-app.sh` is release-only; it requires a Developer ID identity and configured notary profile.

## Coding Style & Naming Conventions

Follow standard Swift style: four-space indentation, one primary type per file, `UpperCamelCase` for types, and `lowerCamelCase` for functions and properties. Match filenames to their main type, such as `LarkCLIClient.swift`. Prefer small value types, explicit error cases, and structured `Process` arguments over shell command strings. No formatter or linter is configured, so keep changes consistent with surrounding code and avoid unrelated reformatting.

## Testing Guidelines

Tests use Apple’s Swift Testing framework (`import Testing`, `@Test`, and `#expect`). Name tests as behavioral statements, for example `untrustedValuesCannotInjectArguments`. Add regression coverage for parser edge cases, chat matching, CLI resolution, and every change to the allowed command surface. Run `./Scripts/test.sh` before submitting; there is no numeric coverage threshold, but new behavior should be exercised directly.

## Security & Read-Only Boundary

Keep all server-facing operations inside `ReadOnlyCommand`. Do not add send, reply, reaction, mutation, generic API, or `sh -c` paths. Validate identifiers and user-controlled arguments. Downloads must remain opt-in, temporary, and deleted after reading.

## Commit & Pull Request Guidelines

Recent commits use short imperative subjects such as `Fix inline image rendering in messages`; use that style and keep each commit focused. Pull requests should explain user-visible behavior, identify security-boundary changes, link relevant issues, and report tests run. Include screenshots or a short recording for panel, animation, or rendering changes.
