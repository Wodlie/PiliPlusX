import 'package:PiliPlus/common/style.dart';
import 'package:flutter/material.dart';

/// A placeholder widget that replaces a preview image when it is blocked.
///
/// Unlike a dark overlay mask, this is a standalone component that fully
/// occupies the grid slot of the blocked image.
class BlockedImagePlaceholder extends StatelessWidget {
  const BlockedImagePlaceholder({
    super.key,
    required this.width,
    required this.height,
    this.borderRadius,
    this.onLongPress,
  });

  final double width;
  final double height;
  final BorderRadius? borderRadius;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      onLongPress: onLongPress,
      child: Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: borderRadius ?? Style.mdRadius,
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.image_not_supported_outlined,
                color: theme.colorScheme.outline,
                size: 32,
              ),
              const SizedBox(height: 4),
              Text(
                '图片已屏蔽',
                style: TextStyle(
                  color: theme.colorScheme.outline,
                  fontSize: 12,
                ),
              ),
              Text(
                '长按查看',
                style: TextStyle(
                  color: theme.colorScheme.outline.withValues(alpha: 0.6),
                  fontSize: 10,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
