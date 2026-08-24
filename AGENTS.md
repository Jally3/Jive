# Repository Guidelines

## Project Structure & Module Organization

Jive is a Flutter Android/iOS video-on-demand MVP. Application code lives in `lib/`:

- `lib/app/` contains app setup (`app.dart`) and theme definitions (`theme.dart`); `lib/main.dart` is the entry point.
- `lib/shared/` contains reusable widgets and shared UI state views: `app_states.dart` (moved from the removed `lib/core/`), `app_toast.dart`, `playback_scrubber.dart`, `source_selector.dart`, `video_card.dart`, and `video_grid.dart`.
- `lib/domain/` contains pure business models such as `Video`, `Library`, `VodSource`, and playback records.
- `lib/data/` contains repositories and API/persistence integration. `video_repository.dart`, `library_repository.dart`, and `history_repository.dart` sit at its root, alongside five subdirectories: `vod_source/` (source config/registry/adapter interface/preferences plus `adapters/` implementations), `content/` (category nav, blocklist, filter policy), `playback/` (playback session, URL resolver, local proxy, HLS/ad filtering/sniffing/prefetch), `cache/` (cache manager/index/IO/TTL/policy/providers), and `download/` (download managers, providers, disk space).
- `lib/features/` contains one subdirectory per page/feature: `home/`, `search/`, `detail/`, `player/` (page plus `widgets/` components), `profile/`, `cache/`, `download/`, and `settings/`.
- `test/` mirrors `lib/`: `test/data/{playback,cache,download,vod_source,content}/`, `test/domain/`, `test/features/<feature>/`, and `test/shared/`, with `widget_test.dart` at the root.

For a per-file index of what each Dart file does, see `doc/codebase/CODEBASE_MAP.md` (keep it in sync when adding/moving/deleting files).
- `android/` and `ios/` contain platform runners. Product and architecture documentation is in `doc/` (active docs under `doc/<topic>/`, completed ones under `doc/archive/<topic>/`; see `doc/README.md` for the index); see `README.md` and `ARCHITECTURE.md` first.

## Build, Test, and Development Commands

Run these from the repository root:

```bash
flutter pub get       # Install/resolve Dart and Flutter dependencies
flutter analyze       # Run the configured static lints and analyzer
flutter test          # Run all unit and widget tests
flutter run           # Launch on a connected device or emulator
flutter build apk     # Build the Android APK
```

Use `flutter test test/video_repository_test.dart` to run one test file. Keep the Flutter SDK compatible with `pubspec.yaml`; the `screen_brightness_ios` override is intentional for Flutter 3.35 compatibility.

## Coding Style & Naming Conventions

Follow `flutter_lints` from `analysis_options.yaml`. Use two-space indentation, trailing commas for multiline Dart, `UpperCamelCase` types, `lowerCamelCase` members/variables, and `snake_case.dart` filenames (for example, `playback_scrubber.dart`). Keep UI pages in `features/`, domain models free of UI concerns, and repository/network or persistence logic in `data/`. Run `dart format lib test` before submitting.

## Testing Guidelines

Tests use `flutter_test` and cover repositories, playback state, controllers, widgets, and UI components. Add focused tests alongside behavior changes, using `_test.dart` and descriptive test/group names. Run `flutter analyze` and `flutter test` before a PR. There is no numeric coverage threshold, but new data and playback logic should include regression coverage.

## Commit & Pull Request Guidelines

Recent commits are short, feature-focused descriptions (for example, `Initialize Jive with enhanced player controls` and `首页优化v2`). Keep commits scoped, descriptive, and preferably imperative. PRs should explain the user-visible change, list validation commands, link relevant docs/issues, and include screenshots or a recording for UI changes. Call out platform, API, dependency, or configuration changes.

## Security & Configuration Tips

Do not commit secrets or private API credentials. Review third-party VOD sources for authorization and platform compliance before release, as noted in `README.md`. Preserve fallback behavior for the official demo video so playback remains testable when external services are unavailable.
