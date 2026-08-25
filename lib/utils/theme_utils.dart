import 'package:PiliPlus/common/style.dart';
import 'package:PiliPlus/utils/extension/theme_ext.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:cupertino_ui/cupertino_ui.dart' show CupertinoThemeData;
import 'package:flutter/foundation.dart' show PlatformDispatcher;
import 'package:material_ui/material_ui.dart';

abstract final class ThemeUtils {
  static late ThemeData lightTheme;

  static late ThemeData darkTheme;

  static late ThemeMode themeMode;

  static ThemeData get theme {
    if (themeMode == .dark ||
        (themeMode == .system &&
            PlatformDispatcher.instance.platformBrightness == .dark)) {
      return darkTheme;
    }
    return lightTheme;
  }

  static bool get isDarkMode => theme.isDark;

  static String themeUrl(bool isDark) =>
      'native.theme=${isDark ? 2 : 1}&night=${isDark ? 1 : 0}';

  static ThemeData getThemeData({
    required ColorScheme colorScheme,
    required bool isDynamic,
    bool isDark = false,
  }) {
    final appFontWeight = Pref.appFontWeight.clamp(
      -1,
      FontWeight.values.length - 1,
    );
    final fontWeight = appFontWeight == -1
        ? null
        : FontWeight.values[appFontWeight];
    final font = Pref.appFont;
    // 根据设置决定使用系统字体还是 HarmonyOS_Sans
    final fontFamilyFallback = Pref.useSystemFont ? null : ['HarmonyOS_Sans'];
    final changeStyle =
        font == null && fontWeight == null && fontFamilyFallback == null;
    late final textStyle = TextStyle(fontWeight: fontWeight, fontFamily: font);
    ThemeData theme = ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      textTheme: changeStyle
          ? null
          : TextTheme(
              displayLarge: textStyle.copyWith(
                fontFamilyFallback: fontFamilyFallback,
              ),
              displayMedium: textStyle.copyWith(
                fontFamilyFallback: fontFamilyFallback,
              ),
              displaySmall: textStyle.copyWith(
                fontFamilyFallback: fontFamilyFallback,
              ),
              headlineLarge: textStyle.copyWith(
                fontFamilyFallback: fontFamilyFallback,
              ),
              headlineMedium: textStyle.copyWith(
                fontFamilyFallback: fontFamilyFallback,
              ),
              headlineSmall: textStyle.copyWith(
                fontFamilyFallback: fontFamilyFallback,
              ),
              titleLarge: textStyle.copyWith(
                fontFamilyFallback: fontFamilyFallback,
              ),
              titleMedium: textStyle.copyWith(
                fontFamilyFallback: fontFamilyFallback,
              ),
              titleSmall: textStyle.copyWith(
                fontFamilyFallback: fontFamilyFallback,
              ),
              bodyLarge: textStyle.copyWith(
                fontFamilyFallback: fontFamilyFallback,
              ),
              bodyMedium: textStyle.copyWith(
                fontFamilyFallback: fontFamilyFallback,
              ),
              bodySmall: textStyle.copyWith(
                fontFamilyFallback: fontFamilyFallback,
              ),
              labelLarge: textStyle.copyWith(
                fontFamilyFallback: fontFamilyFallback,
              ),
              labelMedium: textStyle.copyWith(
                fontFamilyFallback: fontFamilyFallback,
              ),
              labelSmall: textStyle.copyWith(
                fontFamilyFallback: fontFamilyFallback,
              ),
            ),
      tabBarTheme: changeStyle ? null : TabBarThemeData(labelStyle: textStyle),
      appBarTheme: AppBarTheme(
        elevation: 0,
        titleSpacing: 0,
        centerTitle: false,
        scrolledUnderElevation: 0,
        backgroundColor: colorScheme.surface,
        titleTextStyle: TextStyle(
          fontSize: 16,
          color: colorScheme.onSurface,
          fontFamily: font,
          fontWeight: fontWeight,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        surfaceTintColor: isDark ? colorScheme.surfaceContainerHighest : null,
      ),
      snackBarTheme: SnackBarThemeData(
        elevation: 20,
        actionTextColor: colorScheme.primary,
        closeIconColor: colorScheme.secondary,
        backgroundColor: colorScheme.secondaryContainer,
        contentTextStyle: TextStyle(color: colorScheme.onSecondaryContainer),
      ),
      popupMenuTheme: PopupMenuThemeData(
        surfaceTintColor: isDark ? colorScheme.surfaceContainerHighest : null,
      ),
      cardTheme: CardThemeData(
        elevation: 1,
        margin: EdgeInsets.zero,
        shadowColor: Colors.transparent,
        surfaceTintColor: isDark ? colorScheme.onSurfaceVariant : null,
      ),
      progressIndicatorTheme: isDark
          ? ProgressIndicatorThemeData(
              // ignore: deprecated_member_use
              year2023: false,
              refreshBackgroundColor: colorScheme.onInverseSurface,
            )
          // ignore: deprecated_member_use
          : const ProgressIndicatorThemeData(year2023: false),
      dialogTheme: DialogThemeData(
        titleTextStyle: TextStyle(
          fontSize: 18,
          fontFamily: font,
          fontWeight: fontWeight,
          color: colorScheme.onSurface,
        ),
        backgroundColor: colorScheme.surface,
        constraints: const BoxConstraints(minWidth: 280, maxWidth: 420),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: colorScheme.surface,
        shape: const RoundedRectangleBorder(
          borderRadius: Style.bottomSheetRadius,
        ),
      ),
      // ignore: deprecated_member_use
      sliderTheme: const SliderThemeData(year2023: false),
      tooltipTheme: TooltipThemeData(
        textStyle: const TextStyle(color: Colors.white, fontSize: 14),
        decoration: BoxDecoration(
          color: Colors.grey[700]!.withValues(alpha: 0.9),
          borderRadius: const BorderRadius.all(Radius.circular(4)),
        ),
      ),
      cupertinoOverrideTheme: CupertinoThemeData(
        selectionHandleColor: colorScheme.primary,
      ),
      switchTheme: const SwitchThemeData(
        padding: .zero,
        materialTapTargetSize: .shrinkWrap,
        thumbIcon: WidgetStateProperty<Icon?>.fromMap(
          <WidgetStatesConstraint, Icon?>{
            WidgetState.selected: Icon(Icons.done),
            WidgetState.any: null,
          },
        ),
      ),
      expansionTileTheme: const ExpansionTileThemeData(
        shape: Border(),
        collapsedShape: Border(),
      ),
      listTileTheme: const ListTileThemeData(controlAffinity: .leading),
      filledButtonTheme: const FilledButtonThemeData(
        style: ButtonStyle(
          shadowColor: WidgetStatePropertyAll(Colors.transparent),
        ),
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: ZoomPageTransitionsBuilder(),
        },
      ),
    );
    if (isDark && Pref.isPureBlackTheme) {
      return darkenTheme(theme);
    }
    return theme;
  }

  static ThemeData darkenTheme(ThemeData theme) {
    final colorScheme = theme.colorScheme;
    final color = colorScheme.surfaceContainerHighest.darken(0.7);

    // 获取字体回退设置
    final fontFamilyFallback = Pref.useSystemFont ? null : ['HarmonyOS_Sans'];

    return theme.copyWith(
      canvasColor: Colors.black,
      scaffoldBackgroundColor: Colors.black,
      textTheme: theme.textTheme.copyWith(
        bodyLarge: theme.textTheme.bodyLarge?.copyWith(
          fontFamilyFallback: fontFamilyFallback,
        ),
        bodyMedium: theme.textTheme.bodyMedium?.copyWith(
          fontFamilyFallback: fontFamilyFallback,
        ),
        bodySmall: theme.textTheme.bodySmall?.copyWith(
          fontFamilyFallback: fontFamilyFallback,
        ),
        displayLarge: theme.textTheme.displayLarge?.copyWith(
          fontFamilyFallback: fontFamilyFallback,
        ),
        displayMedium: theme.textTheme.displayMedium?.copyWith(
          fontFamilyFallback: fontFamilyFallback,
        ),
        displaySmall: theme.textTheme.displaySmall?.copyWith(
          fontFamilyFallback: fontFamilyFallback,
        ),
        headlineLarge: theme.textTheme.headlineLarge?.copyWith(
          fontFamilyFallback: fontFamilyFallback,
        ),
        headlineMedium: theme.textTheme.headlineMedium?.copyWith(
          fontFamilyFallback: fontFamilyFallback,
        ),
        headlineSmall: theme.textTheme.headlineSmall?.copyWith(
          fontFamilyFallback: fontFamilyFallback,
        ),
        titleLarge: theme.textTheme.titleLarge?.copyWith(
          fontFamilyFallback: fontFamilyFallback,
        ),
        titleMedium: theme.textTheme.titleMedium?.copyWith(
          fontFamilyFallback: fontFamilyFallback,
        ),
        titleSmall: theme.textTheme.titleSmall?.copyWith(
          fontFamilyFallback: fontFamilyFallback,
        ),
        labelLarge: theme.textTheme.labelLarge?.copyWith(
          fontFamilyFallback: fontFamilyFallback,
        ),
        labelMedium: theme.textTheme.labelMedium?.copyWith(
          fontFamilyFallback: fontFamilyFallback,
        ),
        labelSmall: theme.textTheme.labelSmall?.copyWith(
          fontFamilyFallback: fontFamilyFallback,
        ),
      ),
      appBarTheme: theme.appBarTheme.copyWith(
        backgroundColor: Colors.black,
      ),
      cardTheme: theme.cardTheme.copyWith(
        color: colorScheme.surfaceContainer.darken(0.75),
      ),
      dialogTheme: theme.dialogTheme.copyWith(backgroundColor: color),
      bottomSheetTheme: theme.bottomSheetTheme.copyWith(
        backgroundColor: color,
      ),
      bottomNavigationBarTheme: theme.bottomNavigationBarTheme.copyWith(
        backgroundColor: color,
      ),
      navigationBarTheme: theme.navigationBarTheme.copyWith(
        backgroundColor: color,
      ),
      navigationRailTheme: theme.navigationRailTheme.copyWith(
        backgroundColor: Colors.black,
      ),
      popupMenuTheme: theme.popupMenuTheme.copyWith(color: color),
      colorScheme: colorScheme.copyWith(
        primary: colorScheme.primary.darken(0.1),
        onPrimary: colorScheme.onPrimary.darken(0.1),
        primaryContainer: colorScheme.primaryContainer.darken(0.1),
        onPrimaryContainer: colorScheme.onPrimaryContainer.darken(0.1),
        inversePrimary: colorScheme.inversePrimary.darken(0.1),
        secondary: colorScheme.secondary.darken(0.05),
        onSecondary: colorScheme.onSecondary.darken(0.05),
        secondaryContainer: colorScheme.secondaryContainer.darken(0.05),
        onSecondaryContainer: colorScheme.onSecondaryContainer.darken(0.05),
        error: colorScheme.error.darken(0.05),
        surface: Colors.black,
        onSurface: colorScheme.onSurface.darken(0.15),
        surfaceTint: colorScheme.surfaceTint.darken(),
        inverseSurface: colorScheme.inverseSurface.darken(),
        onInverseSurface: colorScheme.onInverseSurface.darken(),
        surfaceContainer: colorScheme.surfaceContainer.darken(),
        surfaceContainerHigh: colorScheme.surfaceContainerHigh.darken(),
        surfaceContainerHighest: colorScheme.surfaceContainerHighest.darken(
          0.4,
        ),
      ),
    );
  }
}
