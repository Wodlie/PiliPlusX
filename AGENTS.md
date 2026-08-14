# PROJECT KNOWLEDGE BASE

**Generated:** 2026-07-27
**Commit:** `41f3eeb48`
**Branch:** `dev`

## OVERVIEW

PiliPlusX — Flutter-based third-party BiliBili client for Android/iOS/Windows/macOS/Linux/HarmonyOS. 1323 Dart files, 446K lines, 114 feature pages. UI in Simplified Chinese; code imports `package:PiliPlus/...`.

## STRUCTURE

```
lib/
├── pages/            # 114 feature pages (controller.dart + view.dart, no Bindings)
│   ├── common/       # Base controllers, reply/publish/search infra
│   ├── video/        # Deepest page family (46 files, 15 subdirs)
│   └── setting/      # Flat file design, no controller.dart
├── models_new/       # 40+ domain-scoped JSON model subdirs (368 files)
├── common/           # Shared widgets + patched Flutter SDK framework
├── models/           # Legacy models + Hive adapters + .g.dart output
├── utils/            # Storage (Hive), accounts, platform, extensions
│   └── accounts/     # Multi-account, BUVID/identity, cookie mgmt
├── grpc/             # Handwritten wrappers + generated protobuf (109 files)
├── http/             # Dio-based API layer, dual-stack HTTP/2+1.1
├── plugin/pl_player/ # Custom media_kit-based player subsystem
├── router/           # Single app_pages.dart (87 GetPage routes)
├── services/         # GetX background services (account, download, audio)
├── scripts/          # build.ps1 mutates pubspec; patch.ps1 patches Flutter SDK
└── tcp/              # Raw WebSocket transport for live chat
```

## WHERE TO LOOK

| Task | Location | Notes |
|------|----------|-------|
| Add/modify a page | `lib/pages/<feature>/` | `controller.dart` + `view.dart`; no binding files |
| Add routes | `lib/router/app_pages.dart` | Central `GetPage` registry, 87 entries |
| Change API behavior | `lib/http/` + `init.dart` | `Request()` singleton owns Dio/interceptors |
| Change storage | `lib/utils/storage_pref.dart` + `storage_key.dart` | `Pref` typed accessor over Hive (`hive_ce`) |
| Change player | `lib/plugin/pl_player/` | Custom forked `media_kit`; see child AGENTS |
| Change accounts | `lib/utils/accounts/` | Multi-account, BUVID, cookie jar |
| Change build/release | `lib/scripts/` + `.github/workflows/` | `build.ps1` mutates pubspec; `patch.ps1` patches Flutter SDK |
| Add a model | `lib/models_new/<domain>/` | JSON model, `fromJson`/`toJson` only |
| Add gRPC call | `lib/grpc/<domain>.dart` | Static method on wrapper; use `grpc_req.dart` |
| Shared page behavior | `lib/pages/common/` | Base controllers, reply/publish/search |

## CONVENTIONS

- **Imports**: `package:PiliPlus/...` only. Relative `../` forbidden by linter.
- **State**: GetX via forked `get`. `GetBuilder` + `Obx`. No `Bindings` — ever.
- **Storage**: Hive (`hive_ce`) via `GStorage`. `Pref` typed accessor. Never touch Hive boxes from pages.
- **HTTP**: Dio singleton `Request()` — dual-stack HTTP/2 + HTTP/1.1, Brotli+gzip decoding.
- **Controllers**: `XxxController` in `controller.dart`. Extend `CommonListController<R,T>` or `CommonDataController<R,T>`.
- **Views**: `XxxPage` (Widget). Use `GetBuilder<XxxController>` or `Obx`.
- **Services**: `GetxService` via `Get.lazyPut` in `main()`. Audio bootstrap via `setupServiceLocator()` (plain globals).
- **Models**: Data carriers only: `fromJson`/`toJson`. No business logic, HTTP, or view code.
- **Formatting**: `dart format`. `trailing_commas: preserve` — manual control.
- **Linting**: `flutter_lints` base + 41 custom rules. Excludes `lib/grpc/bilibili/**`.

## ANTI-PATTERNS

- **NEVER** edit `*.g.dart`, `*.pb.dart`, `*.pbenum.dart`, `*.pbjson.dart` — generated code.
- **NEVER** edit `lib/utils/android/bindings.g.dart` by hand — JNIGen output.
- **NEVER** use `Bindings`. Controllers wired in `main()` `Get.lazyPut`, page `initState` `Get.put()`, or controller `onInit` `Get.putOrFind()`.
- **NEVER** refactor/restyle/rename patched `lib/common/widgets/flutter/` files — they mirror Flutter SDK source.
- **NEVER** bypass `Pref`/`GStorage` to touch Hive boxes from pages.
- **NEVER** route player state changes around `pl_player/controller.dart`.
- **NEVER** duplicate compression/headers/framing outside `grpc_req.dart`.
- **NEVER** hardcode gRPC URL strings — use `url.dart` constants.
- **NEVER** add release metadata logic in app code — use `pili_release.json` via `--dart-define-from-file`.
- **NEVER** put version mutation in CI YAML — `build.ps1` is single source of truth.
- **NEVER** use `print()` — `avoid_print` enforced by linter.

## DEPENDENCIES

- Most packages from **git forks**, not pub.dev. Primary forks: `bggRGjQaUbCoE/*`, `My-Responsitories/*`.
- `get` is forked from `bggRGjQaUbCoE/getx` — not stock `get`.
- `dependency_overrides` is critical: 7 `media_kit*` packages overridden with custom fork (`version_1.2.5`).
- **Always check `dependency_overrides` before assuming package behavior.**

## COMMANDS

```bash
# Dev
flutter run
# Build runner (after model edits)
dart run build_runner build --delete-conflicting-outputs
# Test
flutter test
# Format
dart format .
# Analyze
flutter analyze
```

## NOTES

- Flutter 3.44.4 pinned in both `.fvmrc` and `pubspec.yaml` — keep in sync.
- Dart SDK `>=3.12.0`.
- Project contains AI-assisted code (vibe coding). See `.sisyphus/` for AI artifacts.
- Package pubspec name is `PiliPlus` (not `PiliPlusX`) — imports use `package:PiliPlus/...`.
- 16 Flutter SDK `.patch` files in `lib/scripts/` — applied in CI before build.
- `ScaledWidgetsFlutterBinding` replaces `WidgetsFlutterBinding` for UI scaling.
- `reverse-output/` contains IDA Pro reverse engineering artifacts against official Bilibili APK.
- **0% page test coverage** despite 114 pages. No integration tests, no mockito/mocktail.
