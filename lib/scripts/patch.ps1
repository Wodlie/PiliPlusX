param(
    [string]$platform = ""
)

git config --global user.name "ci"
git config --global user.email "example@example.com"

# TODO: remove
# https://github.com/flutter/flutter/issues/182281
$NewOverScrollIndicator = "362b1de29974ffc1ed6faa826e1df870d7bec75f";

# set `gestureSettings`
$BottomSheetAndroidPatch = "lib/scripts/bottom_sheet_android.patch"

# https://github.com/bggRGjQaUbCoE/PiliPlus/issues/1906
$BottomSheetIOSFlutterPatch = "lib/scripts/bottom_sheet_ios_flutter.patch"
$BottomSheetIOSPiliPlusPatch = "lib/scripts/bottom_sheet_ios_piliplus.patch"

# https://github.com/bggRGjQaUbCoE/PiliPlus/issues/1662
# handle bottom scroll event
$ScrollViewPatch = "lib/scripts/scroll_view.patch"

# https://github.com/bggRGjQaUbCoE/PiliPlus/issues/2106
# use `TouchGestureRecognizer` on all platforms
$TextSelectionPatch = "lib/scripts/text_selection.patch"

# https://github.com/bggRGjQaUbCoE/PiliPlus/issues/1947
$NavigatorPatch = "lib/scripts/navigator.patch"

# https://github.com/bggRGjQaUbCoE/PiliPlus/issues/2107
$ImageAnimPatch = "lib/scripts/image_anim.patch"

# remove `_scheduleRebuild`
$LayoutBuilderPatch = "lib/scripts/layout_builder.patch"

# https://github.com/bggRGjQaUbCoE/PiliPlus/issues/2308
$NavigationDrawerPatch = "lib/scripts/navigation_drawer.patch"

# apply text color to icon color
$PopupMenuPatch = "lib/scripts/popup_menu.patch"

# remove `Hero` effect
$FABPatch = "lib/scripts/fab.patch"

# https://github.com/flutter/flutter/issues/139890
# https://github.com/flutter/flutter/issues/174689
# separator support
# clamp handle offset
# widgetspan selection support
# clear selection when tapping outside
# free selection if there is only one text
# clamp dragging selection behavior on Android
# show selection menu if secondary tap position is in text region on desktop
$SelectableRegionPatch = "lib/scripts/selectable_region.patch"

# https://github.com/flutter/flutter/issues/132047
# https://github.com/flutter/flutter/issues/174689
$EditableTextPatch = "lib/scripts/editable_text.patch"

# set `selectAllOnFocus` to `false` by default
$TextFieldPatch = "lib/scripts/text_field.patch"

# notify `userScrollDirection` only if position is actually changing
$ScrollPositionPatch = "lib/scripts/scroll_position.patch"

# expose `_shouldIgnorePointer`
$ScrollablePatch = "lib/scripts/scrollable.patch"

# expose
$ScaffoldPatch = "lib/scripts/scaffold.patch"

# fix nested scrollable gesture
# custom `HorizontalDragGestureRecognizer` support
$ScrollableGesturePatch = "lib/scripts/scrollable_gesture.patch"

# expose
$DraggableScrollableSheetPatch = "lib/scripts/draggable_scrollable_sheet.patch"

# expose
$TextPatch = "lib/scripts/text.patch"

# expose
$TextPainterPatch = "lib/scripts/text_painter.patch"

$SliverPatch = "lib/scripts/sliver.patch"

$RefreshIndicatorPatch = "lib/scripts/refresh_indicator.patch"

# TODO: remove
# https://github.com/flutter/flutter/issues/124078
# https://github.com/flutter/flutter/pull/183261
$NullSafetySelectableRegionPatch = "lib/scripts/null_safety_for_selectable_region.patch"

# TODO: remove
# https://github.com/flutter/flutter/issues/90223
$ModalBarrierPatch = "lib/scripts/modal_barrier.patch"

# TODO: remove
# https://github.com/flutter/flutter/issues/182466
$MouseCursorPatch = "lib/scripts/mouse_cursor.patch"

$GeetestIOSPatch = "lib/scripts/geetest_ios.patch"

# `git apply` fails when the target files are already patched. That happens when
# the Flutter SDK comes from the GitHub Actions cache: subosito/flutter-action
# saves its cache in the post step — i.e. AFTER the job ran this script and
# patched the SDK — so a cache hit restores an already-patched SDK and plain
# `git apply` fails. Make every patch application idempotent.
#
# Whether a patch is already in the tree is decided by CONTENT — the lines the
# patch adds — never by a command's exit code or output alone:
#   * `git apply --check` / `--reverse --check` messages go to stderr, so
#     "did it print something" says nothing about the tree state (that is why
#     testing the output instead of `$LASTEXITCODE` mis-skipped patches).
#   * `git apply` can also exit 0 without touching a file: when the patch paths
#     are filtered against an enclosing work tree, or a patch is skipped
#     wholesale. An exit code of 0 is therefore not proof that a patch landed.
# Each application is re-read from disk afterwards and verified, so a patch that
# did not land fails loudly instead of leaving a silently unpatched tree.
#region patch-apply-helpers
function Invoke-GitApplyCommand {
    param(
        [string]$Root,
        [string[]]$Arguments
    )
    $output = & git -C $Root apply @Arguments 2>&1
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output   = (($output | ForEach-Object { "$_" }) -join "`n").Trim()
    }
}

# Map of "relative path of the patched file" -> "lines this patch adds to it".
# Only hunk bodies (everything after a `@@` header) are read, so file-header
# lines such as `+++ b/path` can never be mistaken for added content.
function Get-PatchAddedLines {
    param(
        [string]$PatchPath
    )
    $added = [ordered]@{}
    $currentPath = $null
    $inHunk = $false
    foreach ($line in [System.IO.File]::ReadAllLines($PatchPath)) {
        if ($line -match '^diff --git .* b/(.+)$') {
            $currentPath = $Matches[1]
            $inHunk = $false
            if (-not $added.Contains($currentPath)) {
                $added[$currentPath] = [System.Collections.Generic.List[string]]::new()
            }
            continue
        }
        if ($line.StartsWith("@@")) {
            $inHunk = $true
            continue
        }
        if (-not $inHunk -or $null -eq $currentPath) {
            continue
        }
        if ($line.StartsWith("+")) {
            $added[$currentPath].Add($line.Substring(1))
        }
    }
    return $added
}

# True only when every line the patch adds is already present in the target
# files below $Root — i.e. the patch is in the tree, whatever git says.
function Test-PatchAddedLinesPresent {
    param(
        [System.Collections.IDictionary]$AddedLines,
        [string]$Root
    )
    foreach ($relativePath in @($AddedLines.Keys)) {
        $targetPath = Join-Path $Root $relativePath
        if (-not (Test-Path -LiteralPath $targetPath -PathType Leaf)) {
            return $false
        }
        $presentLines = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($line in [System.IO.File]::ReadAllLines($targetPath)) {
            [void]$presentLines.Add($line.TrimEnd())
        }
        foreach ($expectedLine in $AddedLines[$relativePath]) {
            if (-not $presentLines.Contains($expectedLine.TrimEnd())) {
                return $false
            }
        }
    }
    return $true
}

function Test-PatchAppliedByContent {
    param(
        [string]$PatchPath,
        [string]$Root
    )
    $added = Get-PatchAddedLines -PatchPath $PatchPath
    if ($added.Count -eq 0) {
        return $false
    }
    return Test-PatchAddedLinesPresent -AddedLines $added -Root $Root
}

function Apply-GitPatch {
    param(
        [string]$PatchPath,
        [string]$Root = (Get-Location).Path
    )
    if (-not (Test-Path -LiteralPath $PatchPath -PathType Leaf)) {
        throw "patch file not found: $PatchPath"
    }

    # The lines the patch adds are the evidence; a patch that adds none (binary or
    # mode-only) can only be judged by `git apply` itself.
    $added = Get-PatchAddedLines -PatchPath $PatchPath
    $hasContentMarkers = $added.Count -gt 0

    $forwardCheck = Invoke-GitApplyCommand -Root $Root -Arguments @("--check", $PatchPath)
    $reverseCheck = Invoke-GitApplyCommand -Root $Root -Arguments @("--reverse", "--check", $PatchPath)
    $alreadyApplied = $hasContentMarkers -and (Test-PatchAddedLinesPresent -AddedLines $added -Root $Root)

    # Content present *and* the patch no longer applies forward: it is in the tree.
    if ($alreadyApplied -and $forwardCheck.ExitCode -ne 0) {
        Write-Host "SKIP (already applied): $PatchPath"
        return
    }
    if ($forwardCheck.ExitCode -ne 0) {
        throw ("FAILED to apply {0} in {1}: the patch does not apply and its content is not in the tree (git apply --check exit {2}, --reverse --check exit {3}).`n{4}" -f
            $PatchPath, $Root, $forwardCheck.ExitCode, $reverseCheck.ExitCode, $forwardCheck.Output)
    }

    $apply = Invoke-GitApplyCommand -Root $Root -Arguments @($PatchPath)
    if ($apply.ExitCode -ne 0) {
        throw ("FAILED to apply {0} in {1} (git apply exit code {2}).`n{3}" -f
            $PatchPath, $Root, $apply.ExitCode, $apply.Output)
    }
    if ($hasContentMarkers -and -not (Test-PatchAddedLinesPresent -AddedLines $added -Root $Root)) {
        throw ("FAILED to apply {0}: git apply exited 0 but the patched content is missing from {1} (the patch was skipped, not applied; check that {1} is the directory the patch paths are relative to).`n{2}" -f
            $PatchPath, $Root, $apply.Output)
    }
    Write-Host "APPLIED: $PatchPath"
}
#endregion

if ($platform.ToLower() -eq "ios") {
    Apply-GitPatch "$env:GITHUB_WORKSPACE/$BottomSheetIOSPiliPlusPatch"
    Apply-GitPatch "$env:GITHUB_WORKSPACE/$GeetestIOSPatch"
}

Set-Location $env:FLUTTER_ROOT

# The SDK may have been restored from the actions cache in an already-patched
# state (the cache is saved after the previous run patched the SDK). Restore the
# pristine checkout so the patches below apply cleanly. `git clean -fd` also
# removes untracked files added by previous patch runs (the geetest patch adds
# whole files). Skipped when the cache does not carry the git metadata.
if (Test-Path ".git") {
    git reset --hard HEAD
    if ($LASTEXITCODE -ne 0) {
        throw "git reset --hard failed in $env:FLUTTER_ROOT (exit code $LASTEXITCODE)"
    }
    git clean -fd
    if ($LASTEXITCODE -ne 0) {
        throw "git clean failed in $env:FLUTTER_ROOT (exit code $LASTEXITCODE)"
    }
}

$picks   = @()
$reverts = @()
$patches = @($ModalBarrierPatch, $TextSelectionPatch, $MouseCursorPatch,
            $ImageAnimPatch, $LayoutBuilderPatch, $NavigationDrawerPatch,
            $PopupMenuPatch, $FABPatch, $NullSafetySelectableRegionPatch,
            $SelectableRegionPatch, $EditableTextPatch, $TextFieldPatch,
            $ScrollPositionPatch, $ScrollablePatch, $ScrollableGesturePatch,
            $DraggableScrollableSheetPatch, $ScaffoldPatch, $TextPatch,
            $TextPainterPatch, $SliverPatch, $RefreshIndicatorPatch)

switch ($platform.ToLower()) {
    "android" {
        $patches += $BottomSheetAndroidPatch
        $patches += $ScrollViewPatch
        $patches += $NavigatorPatch
    }
    "ios" {
        $patches += $ScrollViewPatch
        $patches += $BottomSheetIOSFlutterPatch
        $patches += $NavigatorPatch
    }
    "linux" {
    }
    "macos" {
    }
    "windows" {
    }
    default {}
}

foreach ($pick in $picks) {
    git stash
    git cherry-pick $pick --no-edit
    if ($LASTEXITCODE -eq 0) {
        git reset --soft HEAD~1
        Write-Host "$pick picked"
    } else {
        throw "$LASTEXITCODE"
    }
    git stash pop
}

foreach ($revert in $reverts) {
    git stash
    git revert $revert --no-edit
    if ($LASTEXITCODE -eq 0) {
        git reset --soft HEAD~1
        Write-Host "$revert reverted"
    } else {
        throw "$LASTEXITCODE"
    }
    git stash pop
}

foreach ($patch in $patches) {
    Apply-GitPatch "$env:GITHUB_WORKSPACE/$patch"
}

Set-Location $env:GITHUB_WORKSPACE

$BottomSheetAndroidPatchMaterial = "lib/scripts/material/bottom_sheet_android.patch"

$BottomSheetIOSFlutterMaterialPatchMaterial = "lib/scripts/material/bottom_sheet_ios_flutter_material.patch"

$ModalBarrierPatchMaterial = "lib/scripts/material/modal_barrier_material.patch"

$NavigationDrawerPatchMaterial = "lib/scripts/material/navigation_drawer.patch"

$PopupMenuPatchMaterial = "lib/scripts/material/popup_menu.patch"

$FABPatchMaterial = "lib/scripts/material/fab.patch"

$TextFieldPatchMaterial = "lib/scripts/material/text_field.patch"

$ScaffoldPatchMaterial = "lib/scripts/material/scaffold.patch"

$RefreshIndicatorPatchMaterial = "lib/scripts/material/refresh_indicator.patch"

$TabsPatchMaterial = "lib/scripts/material/tabs.patch"

$patches_material = @($ModalBarrierPatchMaterial, $NavigationDrawerPatchMaterial, $PopupMenuPatchMaterial,
                    $FABPatchMaterial, $TextFieldPatchMaterial, $ScaffoldPatchMaterial, $RefreshIndicatorPatchMaterial,
                    $TabsPatchMaterial)

$PubCacheDir = "~/.pub-cache"

switch ($platform.ToLower()) {
    "android" {
        $patches_material += $BottomSheetAndroidPatchMaterial
    }
    "ios" {
        $patches_material += $BottomSheetIOSFlutterMaterialPatchMaterial
    }
    "linux" {
    }
    "macos" {
    }
    "windows" {
        $PubCacheDir = "$env:LOCALAPPDATA/Pub/Cache"
    }
    default {}
}

try {
    $MaterialUiDir = Get-ChildItem "$PubCacheDir/hosted/pub.dev" -Directory |
        Where-Object { $_.Name -like "material_ui-*" } |
        Select-Object -Last 1

    if ($MaterialUiDir) {
        Remove-Item -Path $MaterialUiDir.FullName -Recurse -Force
    }

    # cupertino_ui is only patched on iOS. Drop the cached copy for the same
    # reason: `flutter pub get` then restores a pristine tree, so the iOS patch
    # can neither fail against nor stack on top of a cache an earlier run left
    # patched.
    if ($platform.ToLower() -eq "ios") {
        $CupertinoUiCached = Get-ChildItem "$PubCacheDir/hosted/pub.dev" -Directory |
            Where-Object { $_.Name -like "cupertino_ui-*" } |
            Select-Object -Last 1

        if ($CupertinoUiCached) {
            Remove-Item -Path $CupertinoUiCached.FullName -Recurse -Force
        }
    }
} catch {
}

flutter pub get

$MaterialUiDir = Get-ChildItem "$PubCacheDir/hosted/pub.dev" -Directory |
    Where-Object { $_.Name -like "material_ui-*" } |
    Select-Object -Last 1

if (-not $MaterialUiDir) {
    throw "material_ui package not found in pub cache"
}

Write-Host "material_ui dir: $($MaterialUiDir.FullName)"

Get-ChildItem -Path "$env:GITHUB_WORKSPACE/lib/scripts/material" -Filter *.patch | ForEach-Object {
    (Get-Content $_.FullName -Raw) -replace "`r`n", "`n" | 
        Set-Content -NoNewline $_.FullName
}

cd $MaterialUiDir.FullName

foreach ($patch in $patches_material) {
    Apply-GitPatch "$env:GITHUB_WORKSPACE/$patch"
}

$BottomSheetIOSFlutterPatchCupertino = "lib/scripts/cupertino/bottom_sheet_ios_flutter.patch"

$patches_cupertino = @()

switch ($platform.ToLower()) {
    "android" {
    }
    "ios" {
        $patches_cupertino += $BottomSheetIOSFlutterPatchCupertino
    }
    "linux" {
    }
    "macos" {
    }
    "windows" {
    }
    default {}
}

$CupertinoUiDir = Get-ChildItem "$PubCacheDir/hosted/pub.dev" -Directory |
    Where-Object { $_.Name -like "cupertino_ui-*" } |
    Select-Object -Last 1

if (-not $CupertinoUiDir) {
    throw "cupertino_ui package not found in pub cache"
}

Write-Host "cupertino_ui dir: $($CupertinoUiDir.FullName)"

Get-ChildItem -Path "$env:GITHUB_WORKSPACE/lib/scripts/cupertino" -Filter *.patch | ForEach-Object {
    (Get-Content $_.FullName -Raw) -replace "`r`n", "`n" | 
        Set-Content -NoNewline $_.FullName
}

cd $CupertinoUiDir.FullName

# Same verify-after-apply contract as the SDK/material patches above, and never
# leave a half-applied cupertino_ui cache behind: on failure drop the patched
# directory (the next `flutter pub get` restores it pristine) and rethrow.
try {
    foreach ($patch in $patches_cupertino) {
        Apply-GitPatch "$env:GITHUB_WORKSPACE/$patch"
    }
} catch {
    $patchFailure = $_
    Set-Location $env:GITHUB_WORKSPACE
    Remove-Item -Path $CupertinoUiDir.FullName -Recurse -Force -ErrorAction SilentlyContinue
    throw $patchFailure
}
