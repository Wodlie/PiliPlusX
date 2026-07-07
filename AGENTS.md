# PROJECT KNOWLEDGE BASE

**Generated:** 2026-07-07
**Commit:** `832e73ba2`
**Branch:** `dev`

## OVERVIEW

PiliPlusX is a Flutter-based third-party BiliBili client for Android, iOS, Windows, macOS, Linux, and HarmonyOS. UI and comments are Simplified Chinese; code imports use `package:PiliPlus/...`.

## STRUCTURE

```
lib/
├── pages/            # 114 feature pages; largest handwritten surface
├── common/           # shared widgets, style constants, patched Flutter SDK widgets
├── http/             # Dio-based API layer + interceptors
├── utils/            # storage, accounts, platform helpers, extensions
├── services/         # GetX background services (account, download, audio)
├── plugin/pl_player/ # custom media_kit-based player subsystem
├── models/           # older models + Hive adapters
├── models_new/       # newer feature-scoped JSON models (40+ domains)
├── grpc/             # handwritten wrappers + generated protobuf tree
├── router/           # centralized GetPage route table (~80 routes)
└── scripts/          # build/version/Flutter patch scripts
```

## DEVELOPMENT

- Flutter pinned in `.fvmrc` + `pubspec.yaml`: `3.44.4` (keep in sync)
- Dart SDK: `>=3.12.0`
- Auto-format: `dart format` (no `.editorconfig`; `trailing_commas: preserve` in analysis_options)
- Build runner: `dart run build_runner build --delete-conflicting-outputs`
- Run all tests: `flutter test`
- Always use `package:PiliPlus/...` imports; never relative `../`
- Use `kDebugMode` for debug-only logic
- Settings go through `Pref` / `GStorage`, not ad hoc persistence

## WHERE TO LOOK

| Task | Location | Notes |
|------|----------|-------|
| Add/modify a page | `lib/pages/<feature>/` | `controller.dart` + `view.dart`; no binding files |
| Add routes | `lib/router/app_pages.dart` | Central `GetPage` registry |
| Change API behavior | `lib/http/` + `lib/http/init.dart` | `Request()` singleton owns Dio/interceptors |
| Change settings storage | `lib/utils/storage_pref.dart` + `storage_key.dart` | `Pref` typed accessor over Hive |
| Change player behavior | `lib/plugin/pl_player/` | Custom `media_kit` fork; see child AGENTS |
| Change account/cookies | `lib/utils/accounts/` | Multi-account, BUVID, request identity |
| Change build/release | `lib/scripts/` + `.github/workflows/` | `build.ps1` mutes pubspec; `patch.ps1` patches Flutter SDK |
| Shared page behavior | `lib/pages/common/` | Base controllers, publish/search/multi-select helpers |

## ARCHITECTURE

- **State**: GetX via forked `get`; `GetBuilder` + `Obx` throughout
- **Page registration**: no binding files; controllers wired in `main.dart` or page-local
- **Storage**: Hive (`hive_ce`) via `GStorage` in `lib/utils/storage.dart`
- **HTTP**: Dio singleton `Request()` in `lib/http/init.dart`
- **Services**: `GetxService` implementations in `lib/services/`
- **Player**: custom `pl_player` on forked `media_kit` (in `dependency_overrides`)
- **Multi-account**: `lib/utils/accounts/` with `AccountManager`, identity core, adapter layer
- **Custom binding**: `ScaledWidgetsFlutterBinding` replaces `WidgetsFlutterBinding` for UI scaling

## MODELS & CODEGEN

- `lib/models/` = legacy models + Hive adapters + `*.g.dart` output
- `lib/models_new/` = newer feature-scoped models by domain (`video/`, `live/`, `fav/`, `msg/`, 36+ domains)
- gRPC/protobuf output under `lib/grpc/bilibili/`
- Build runner: `dart run build_runner build --delete-conflicting-outputs`

## GENERATED / DO-NOT-EDIT ZONES

- Never edit `lib/grpc/bilibili/**/*.pb.dart`, `*.pbenum.dart`, `*.pbjson.dart`
- Never edit `lib/utils/android/bindings.g.dart` by hand (JNIGen)
- Never edit `*.g.dart` by hand; run `build_runner`
- `lib/common/widgets/flutter/` = patched Flutter framework widgets
- `BEGIN GENERATED TOKEN PROPERTIES` blocks in patched files are generated

## DEPENDENCIES

- Many packages from git forks, not pub.dev. Primary fork source: `github.com/bggRGjQaUbCoE/...`
- `get` is forked from `bggRGjQaUbCoE/getx` — not stock `get`
- `dependency_overrides` section in `pubspec.yaml` is critical
- Media packages from `github.com/My-Responsitories/...` (branch `version_1.2.5`)
- Check `dependency_overrides` before assuming upstream behavior

## LINTING (analysis_options.yaml)

Base: `package:flutter_lints/flutter.yaml`. Key enforced rules:
- `always_use_package_imports`, `always_declare_return_types`, `avoid_print`
- `prefer_const_constructors`, `avoid_unnecessary_containers`
- `trailing_commas: preserve`
- Excludes: `lib/grpc/bilibili/**`

## BUILD & CI

- `lib/scripts/build.ps1` mutates `pubspec.yaml` version + writes `pili_release.json`
- `lib/scripts/patch.ps1` patches Flutter SDK per platform (runs in `$FLUTTER_ROOT`, not repo)
- CI workflows: `.github/workflows/build.yml` (orchestrator) → `ios.yml`, `mac.yml`, `win_x64.yml`, `linux_x64.yml`
- Android release: `flutter build apk --release --split-per-abi --dart-define-from-file=pili_release.json --pub`
- Android dev: `flutter build apk --release --split-per-abi --android-project-arg dev=1 --pub`
- Trigger on PR, push to `dev`, tags `v*`/`release-*`, manual dispatch
- Release builds are signed (Android); dev builds are unsigned
- Impeller explicitly disabled on Android

## CHILD GUIDES

- `lib/pages/AGENTS.md`
- `lib/pages/video/AGENTS.md`
- `lib/pages/setting/AGENTS.md`
- `lib/common/widgets/AGENTS.md`
- `lib/scripts/AGENTS.md`
- `lib/services/AGENTS.md`
- `lib/utils/AGENTS.md`
- `lib/plugin/pl_player/AGENTS.md`
- `lib/utils/accounts/AGENTS.md`
- `lib/http/AGENTS.md`
- `lib/models/AGENTS.md`
- `lib/models_new/AGENTS.md`
- `lib/grpc/AGENTS.md`
- `lib/tcp/AGENTS.md`
