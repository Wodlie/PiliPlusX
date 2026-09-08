# PROJECT KNOWLEDGE BASE

**Updated:** 2026-09 · **Commit:** `cd4af793` · **Branch:** `dev`

## OVERVIEW

PiliPlusX — Flutter-based third-party BiliBili client for Android/iOS/Windows/macOS/Linux/HarmonyOS. ~1.3k Dart files, 117 feature pages, 75 routes. UI in Simplified Chinese; code imports `package:PiliPlus/...`.

Fork of [bggRGjQaUbCoE/PiliPlus](https://github.com/bggRGjQaUbCoE/PiliPlus), synced via merge commits (`Merge remote-tracking branch 'upstream/main' into dev`). Fork-specific features: built-in web browser + JS bridge (`webview_entry/`, `common_funcs/`, `qr_scanner/`, `webview/`), custom API host (`http/api_hosts.dart`, `custom_host_interceptor.dart`), multi-account identity/risk (`utils/accounts/`), comment @-filtering (`pages/setting/pages/at_filter.dart`), image blocking via pHash (`utils/image_block_service.dart`, `setting/pages/image_block.dart`), AI summary, HarmonyOS font, report v2 dialog. Feature roadmap: `docs/TODO.md`.

## NESTED INSTRUCTION FILES

Per-directory `AGENTS.md` files exist in ~16 trees (`.github/workflows/`, `lib/pages/` + `common/`/`video/`/`setting/`, `lib/http/`, `lib/grpc/`, `lib/plugin/pl_player/`, `lib/utils/` + `accounts/`, `lib/services/`, `lib/tcp/`, `lib/common/widgets/`, `lib/models*/`, `lib/scripts/`) and load contextually when working there — follow them for directory-specific rules.

## MATERIAL_UI ARCHITECTURE (IMPORTANT)

The app does **not** use `package:flutter/material.dart` / `package:flutter/cupertino.dart`. Since the upstream Material-3 decoupling, all UI imports the **standalone packages**:

- `package:material_ui/material_ui.dart` — Material widgets/theme (~500 files)
- `package:cupertino_ui/cupertino_ui.dart` — Cupertino widgets (few files, mostly `text_field/` mirrors)

`main.dart` registers localization delegates from **material_ui** + **cupertino_ui** (+ SDK `flutter_localizations` only for `GlobalWidgetsLocalizations`). **Consequence:** any page that imports the SDK `flutter/material.dart` crashes at runtime — its widgets resolve the SDK's `MaterialLocalizations`, which is never registered → null delegates → blank page in Release. Treat `flutter/material.dart` / `flutter/cupertino.dart` as banned imports.

## STRUCTURE

```
lib/
├── pages/            # 117 feature pages (controller.dart + view.dart, no Bindings)
│   ├── common/       # Base controllers, reply/publish/search infra
│   ├── video/        # Deepest page family (46 files, 15 subdirs)
│   ├── setting/      # Flat file design, no controller.dart
│   ├── webview_entry/ etc.  # Fork pages (browser, qr scanner, common funcs)
│   └── ...
├── models_new/       # 44 domain-scoped JSON model subdirs
├── common/           # Shared widgets + patched Flutter SDK framework
│   └── widgets/flutter/  # SDK-source mirrors (material_ui era), NEVER restyle
├── models/           # Legacy models + Hive adapters + .g.dart output
├── utils/            # Storage (Hive), accounts, platform, extensions
│   └── accounts/     # Multi-account, BUVID/identity risk, cookie mgmt
├── grpc/             # Handwritten wrappers + generated protobuf
├── http/             # Dio-based API layer, dual-stack HTTP/2+1.1, custom API host
├── plugin/pl_player/ # Custom media_kit-based player subsystem
├── router/           # Single app_pages.dart (75 GetPage routes)
├── services/         # GetX background services (account, download, audio)
├── scripts/          # build.ps1 mutates pubspec; patch.ps1 patches Flutter SDK + material_ui
│   └── material/     # Patches targeting the material_ui package in pub cache
└── tcp/              # Raw WebSocket transport for live chat
```

## WHERE TO LOOK

| Task | Location | Notes |
|------|----------|-------|
| Add/modify a page | `lib/pages/<feature>/` | `controller.dart` + `view.dart`; no binding files |
| Add routes | `lib/router/app_pages.dart` | Central `GetPage` registry |
| UI widgets/theme | `lib/common/` + `material_ui` | Import `material_ui`/`cupertino_ui`, never `flutter/material` |
| Change API behavior | `lib/http/` + `init.dart` | `Request()` singleton owns Dio/interceptors; fork headers in `request_utils.dart` |
| Change storage | `lib/utils/storage_pref.dart` + `storage_key.dart` | `Pref` typed accessor over Hive (`hive_ce`) |
| Change player | `lib/plugin/pl_player/` | Custom forked `media_kit`; has its own `AGENTS.md` |
| Change accounts | `lib/utils/accounts/` | Multi-account, BUVID identity, gaia risk, cookie jar |
| Change build/release | `lib/scripts/` + `.github/workflows/` | `build.ps1` mutates pubspec; `patch.ps1` patches SDK + material_ui |
| Add a model | `lib/models_new/<domain>/` | JSON model, `fromJson`/`toJson` only |
| Add gRPC call | `lib/grpc/<domain>.dart` | Static method on wrapper; use `grpc_req.dart` |
| Shared page behavior | `lib/pages/common/` | Base controllers, reply/publish/search |

## CONVENTIONS

- **Imports**: `package:PiliPlus/...` only (`always_use_package_imports` lint). UI code imports `package:material_ui/material_ui.dart` (+ `cupertino_ui`); **never** `package:flutter/material.dart` / `package:flutter/cupertino.dart`.
- **State**: GetX via forked `get` (`bggRGjQaUbCoE/getx`, ref `dev`). `GetBuilder` + `Obx`. No `Bindings` — ever.
- **Storage**: Hive (`hive_ce`) via `GStorage`. `Pref` typed accessor. Never touch Hive boxes from pages.
- **HTTP**: Dio singleton `Request()` — dual-stack HTTP/2 + HTTP/1.1, Brotli+gzip decoding.
- **Controllers**: `XxxController` in `controller.dart`. Extend `CommonListController<R,T>` or `CommonDataController<R,T>` (`lib/pages/common/`).
- **Views**: `XxxPage` (Widget). Use `GetBuilder<XxxController>` or `Obx`.
- **Services**: `GetxService` via `Get.lazyPut` in `main()`. Audio bootstrap via `setupServiceLocator()` (plain globals).
- **Models**: Data carriers only: `fromJson`/`toJson`. No business logic, HTTP, or view code.
- **Formatting**: `dart format`; `trailing_commas: preserve` — manual control.
- **Linting**: `flutter_lints` base + custom rules; excludes `lib/grpc/bilibili/**` and `bindings.g.dart`.
- **Commits**: messages in **English**, conventional style (`fix:`, `feat:`, `chore:`).

## ANTI-PATTERNS

- **NEVER** import `flutter/material.dart` / `flutter/cupertino.dart` — runtime `MaterialLocalizations` null crash on pages using SDK widgets.
- **NEVER** edit `*.g.dart`, `*.pb.dart`, `*.pbenum.dart`, `*.pbjson.dart` — generated code.
- **NEVER** edit `lib/utils/android/bindings.g.dart` by hand — JNIGen output.
- **NEVER** use `Bindings`. Controllers wired in `main()` `Get.lazyPut`, page `initState` `Get.put()`, or controller `onInit` `Get.putOrFind()`.
- **NEVER** refactor/restyle/rename patched `lib/common/widgets/flutter/` files — they mirror SDK source (imports may use `material_ui`, but content is upstream Flutter code).
- **NEVER** bypass `Pref`/`GStorage` to touch Hive boxes from pages.
- **NEVER** route player state changes around `pl_player/controller.dart`.
- **NEVER** duplicate compression/headers/framing outside `grpc_req.dart`.
- **NEVER** hardcode gRPC URL strings — use `url.dart` constants.
- **NEVER** add release metadata logic in app code — read version/build info only via `lib/build_config.dart` (`BuildConfig`). Its `pili.*` values come from `pili_release.json` (`--dart-define-from-file`), which `build.ps1` **generates in CI**; the file is not committed.
- **NEVER** put version mutation in CI YAML — `build.ps1` is single source of truth.
- **NEVER** use `print()` — `avoid_print` enforced by linter.

## DEPENDENCIES

- Most packages from **git forks**, not pub.dev. Primary forks: `bggRGjQaUbCoE/*`, `My-Responsitories/*`.
- `get` forked from `bggRGjQaUbCoE/getx` (ref `dev`) — not stock `get`.
- `flex_seed_scheme` ^5.0.0 from pub.dev (upstream moved it back off the git fork) — theme seeding.
- `flutter_html` from `bggRGjQaUbCoE/flutter_html` (ref `dev`) — git dep, not pub.dev.
- `material_ui` ^1.0.0, `cupertino_ui` ^1.0.0, `material_new_shapes` ^1.0.0 — decoupled Material/Cupertino packages.
- `file_picker` ^12.0.0 (new API: `path.toFilePath()`, `pickFiles`).
- `dependency_overrides` is critical: 7 `media_kit*` packages overridden with `bggRGjQaUbCoE/media-kit` fork (`version_1.2.5`); `flutter_inappwebview_android/_windows` and `cached_network_image_ce` also overridden.
- **Always check `dependency_overrides` before assuming package behavior.**

## COMMANDS

```bash
# Dev (requires Flutter 3.47.2 per .fvmrc / pubspec environment:)
flutter run
# Build runner (after model edits)
dart run build_runner build --delete-conflicting-outputs
# Test all / one file
flutter test
flutter test test/buvid_lifecycle_test.dart
# Format
dart format .
# Analyze
flutter analyze
```

## NOTES

- Flutter **3.47.2** pinned in both `.fvmrc` and `pubspec.yaml` — keep in sync. Dart SDK `>=3.13.0`.
- Fonts: custom font page (`lib/utils/font_utils.dart`, `pages/setting/pages/font_setting.dart`, route `/fontSetting`) + fork's `Pref.useSystemFont` → `HarmonyOS_Sans` fallback. `Pref.appFontWeight` returns a `FontWeight` (stored as `SettingBoxKey.appFontWeightV2`; v1 int key is migrated on read). `Pref.appFont` was removed — use `FontUtils.appFont`/`fontFamily`.
- Linux desktop webview: `desktop_webview_window` (Predidit/linux_webview_window) + `lib/utils/linux_cookie_manager.dart`; `WebviewPage.openLinux` mirrors the mobile JS bridge hooks.
- Package pubspec name is `PiliPlus` (not `PiliPlusX`) — imports use `package:PiliPlus/...`. Fork branding lives in CI/launcher names (`PiliPlusX`, `com.Wodlie.PiliPlusX`). CI details: see `.github/workflows/AGENTS.md`.
- SDK patching is two-part (CI only, `lib/scripts/patch.ps1`): 27 `.patch` files patch the Flutter SDK in `$FLUTTER_ROOT`, and `lib/scripts/material/*.patch` (10 files) patch the **material_ui package in the pub cache** (after `flutter pub get`, under `%LOCALAPPDATA%/Pub/Cache` / `~/.pub-cache`). Keep fork's HarmonyOS font paths intact — upstream removed them.
- `ScaledWidgetsFlutterBinding` replaces `WidgetsFlutterBinding` for UI scaling.
- `reverse-output/` contains IDA reverse-engineering artifacts against the official Bilibili APK; `.sisyphus/` holds AI-assisted dev artifacts.
- Sync upstream via merge (`git merge upstream/main`) then reconcile: keep fork workflows/README/version, preserve fork-only files, apply material_ui import style to any still-SDK file.
- After merging, regenerate `pubspec.lock` with the pinned SDK (`flutter pub get`) — never hand-merge it. Git deps resolve to the commits already in the pub cache (`%LOCALAPPDATA%\Pub\Cache\git\cache\<pkg>-<sha1(url)>`); if upstream's lock pins a newer commit that fork code now needs, fetch it into that cache dir before `pub get`.
- Verify a sync with the **patched** SDK: `lib/scripts/patch.ps1 windows` (needs `GITHUB_WORKSPACE`/`FLUTTER_ROOT`; it also rewrites global git identity, so restore it) then `flutter analyze` — fork code legitimately calls patch-added SDK APIs. Compare against a pre-merge worktree baseline instead of expecting a clean report.
- Known pre-existing analyzer noise (not a merge regression): `lib/common/widgets/context_menu/reply_menu_helper.dart` is a `part of` `reply_item_grpc.dart`, but that library no longer declares the `part` (the fork replaced the emote copy menu) — ~40 errors. Either delete the orphan or restore the `part` directive when touching the reply menu.
- Pages have **no tests** (117 pages, zero coverage), but `test/` has ~17 unit tests covering fork-only services (identity/BUVID, phash image-block, reply dedup, video summary). No integration tests.
