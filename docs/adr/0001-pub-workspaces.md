# ADR-F01: Dart pub workspaces

- Status: accepted
- Date: 2026-10-05

## Decision

The three packages (`accordsync_core`, `accordsync`, `accordsync_flutter`) live in one Dart pub
workspace (`workspace:` in the root `pubspec.yaml`, `resolution: workspace` in each package), built
into Dart 3.6+. No melos.

## Why

- One dependency resolution for all packages, so the core, the client and the Flutter layer are
  always tested together.
- No extra tool to install in CI or on a contributor's machine.

## Consequences

- Flutter's `flutter_test` pins `test_api`, so the pure Dart packages use a `test` version range
  compatible with it (`>=1.25.0 <2.0.0`).
- If publishing several packages at once becomes tedious, melos can be added later on top of the
  workspace.
