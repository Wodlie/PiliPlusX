/*
 * This file is part of PiliPlus
 *
 * PiliPlus is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * PiliPlus is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with PiliPlus.  If not, see <https://www.gnu.org/licenses/>.
 */

import 'dart:io' show Platform;
import 'dart:math' show min;

import 'package:PiliPlus/common/assets.dart';
import 'package:PiliPlus/common/style.dart';
import 'package:PiliPlus/common/widgets/badge.dart';
import 'package:PiliPlus/common/widgets/image/blocked_image_placeholder.dart';
import 'package:PiliPlus/common/widgets/image/network_img_layer.dart';
import 'package:PiliPlus/common/widgets/image_grid/image_grid_builder.dart';
import 'package:PiliPlus/models/common/image_preview_type.dart';
import 'package:PiliPlus/utils/extension/context_ext.dart';
import 'package:PiliPlus/utils/extension/num_ext.dart';
import 'package:PiliPlus/utils/extension/size_ext.dart';
import 'package:PiliPlus/utils/image_block_service.dart';
import 'package:PiliPlus/utils/image_utils.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:get/get_core/src/get_main.dart';
import 'package:get/get_navigation/src/extension_navigation.dart';
import 'package:visibility_detector/visibility_detector.dart';

class ImageModel {
  ImageModel({
    required num? width,
    required num? height,
    required this.url,
    this.liveUrl,
  }) {
    this.width = width == null || width == 0 ? 1 : width;
    this.height = height == null || height == 0 ? 1 : height;
  }

  late num width;
  late num height;
  String url;
  String? liveUrl;
  bool? _isLongPic;
  bool? _isLivePhoto;

  bool get isLongPic =>
      _isLongPic ??= (height / width) > Style.imgMaxRatio && width > 100;
  bool get isLivePhoto =>
      _isLivePhoto ??= enableLivePhoto && liveUrl?.isNotEmpty == true;

  static bool enableLivePhoto = Pref.enableLivePhoto;
}

class ImageGridView extends StatefulWidget {
  const ImageGridView({
    super.key,
    required this.picArr,
    this.onViewImage,
    this.fullScreen = false,
    this.tempUnblockedUrls,
  });

  final List<ImageModel> picArr;
  final VoidCallback? onViewImage;
  final bool fullScreen;

  /// URLs to temporarily show even if blocked (external control, e.g. from
  /// the reply long-press menu). The grid merges this with its internal
  /// [_tempUnblockedSrcs]. When the grid goes off-screen, the parent should
  /// clear this set to restore blocking.
  final Set<String>? tempUnblockedUrls;

  /// Exposed preferences (read/written externally via settings).
  static bool horizontalPreview = Pref.horizontalPreview;
  static bool enableImgMenu = Pref.enableImgMenu;

  @override
  State<ImageGridView> createState() => _ImageGridViewState();
}

class _ImageGridViewState extends State<ImageGridView> {
  /// Blocking state per image URL (pHash-based).
  final Map<String, bool> _imageBlockStatus = {};

  final Set<String> _tempUnblockedSrcs = {};

  bool _isTempUnblocked(String url) =>
      _tempUnblockedSrcs.contains(url) ||
      (widget.tempUnblockedUrls?.contains(url) ?? false);

  /// Whether blocking UI is enabled. Inferred once from Pref at init.
  bool _enableBlock = false;

  /// Whether we have kicked off blocking evaluation for this grid.
  bool _blockingInitialized = false;

  static final _regex = RegExp(r'/videoV|/dynamicDetail$|/articlePage');

  @override
  void initState() {
    super.initState();
    _enableBlock = Pref.enableImageBlock;
  }

  Future<void> _evaluateImageBlock(String imgSrc) async {
    if (!_enableBlock) return;
    // 1. Run pHash evaluation (existing)
    final blocked = await ImageBlockService.evaluateBlock(imgSrc);
    if (mounted && _imageBlockStatus[imgSrc] == null) {
      _imageBlockStatus[imgSrc] = blocked;
      setState(() {});
    }
  }

  void _evaluateAllImages() {
    if (!_enableBlock) return;
    for (final item in widget.picArr) {
      if (!_imageBlockStatus.containsKey(item.url)) {
        // fire-and-forget; each calls setState when done.
        _evaluateImageBlock(item.url);
      }
    }
  }

  void _showUnblockMenu(BuildContext context, String imgSrc) {
    showModalBottomSheet(
      context: context,
      useSafeArea: true,
      constraints: BoxConstraints(
        maxWidth: min(640, context.mediaQueryShortestSide),
      ),
      builder: (context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            onTap: () {
              Get.back();
              if (mounted) {
                setState(() => _tempUnblockedSrcs.add(imgSrc));
              }
            },
            leading: const Icon(Icons.visibility, color: Colors.red, size: 19),
            title: const Text('确定查看图片', style: TextStyle(color: Colors.red)),
          ),
          ListTile(
            onTap: () async {
              Get.back();
              await ImageBlockService.addBlockedImage(imgSrc);
              if (mounted) {
                setState(() => _imageBlockStatus[imgSrc] = true);
              }
              SmartDialog.showToast('已屏蔽图片');
            },
            leading: const Icon(
              Icons.block,
              color: Colors.red,
              size: 19,
            ),
            title: const Text('屏蔽图片', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  void _onTap(BuildContext context, int index) {
    final item = widget.picArr[index];

    // If blocked and not temporarily unblocked → do nothing.
    if (_enableBlock) {
      final isBlocked = _imageBlockStatus[item.url] == true;
      final tempUnblocked = _isTempUnblocked(item.url);

      if (isBlocked && !tempUnblocked) return;
    }

    final imgList = widget.picArr.map(
      (item) {
        bool isLive = item.isLivePhoto;
        return SourceModel(
          sourceType: isLive ? .livePhoto : .networkImage,
          url: item.url,
          liveUrl: isLive ? item.liveUrl : null,
          width: isLive ? item.width.toInt() : null,
          height: isLive ? item.height.toInt() : null,
          isLongPic: item.isLongPic,
        );
      },
    ).toList();
    if (ImageGridView.horizontalPreview &&
        !widget.fullScreen &&
        Get.currentRoute.startsWith(_regex) &&
        !context.mediaQuerySize.isPortrait) {
      final scaffoldState = Scaffold.maybeOf(context);
      if (scaffoldState != null) {
        widget.onViewImage?.call();
        PageUtils.onHorizontalPreviewState(
          scaffoldState,
          imgList,
          index,
        );
        return;
      }
    }
    PageUtils.imageView(
      initialPage: index,
      imgList: imgList,
      tag: hashCode.toString(),
    );
  }

  static BorderRadius _borderRadius(
    int col,
    int length,
    int index, {
    Radius r = Style.imgRadius,
  }) {
    if (length == 1) return Style.mdRadius;

    final bool hasUp = index - col >= 0;
    final bool hasDown = index + col < length;

    final bool isRowStart = (index % col) == 0;
    final bool isRowEnd = (index % col) == col - 1 || index == length - 1;

    final bool hasLeft = !isRowStart;
    final bool hasRight = !isRowEnd && (index + 1) < length;

    return BorderRadius.only(
      topLeft: !hasUp && !hasLeft ? r : Radius.zero,
      topRight: !hasUp && !hasRight ? r : Radius.zero,
      bottomLeft: !hasDown && !hasLeft ? r : Radius.zero,
      bottomRight: !hasDown && !hasRight ? r : Radius.zero,
    );
  }

  void _showMenu(BuildContext context, int index, Offset offset) {
    final item = widget.picArr[index];

    // If blocked and not temporarily unblocked → no context menu.
    if (_enableBlock) {
      final isBlocked = _imageBlockStatus[item.url] == true;
      final tempUnblocked = _isTempUnblocked(item.url);
      if (isBlocked && !tempUnblocked) return;
    }

    HapticFeedback.mediumImpact();
    showMenu(
      context: context,
      position: PageUtils.menuPosition(offset),
      items: [
        if (PlatformUtils.isMobile)
          PopupMenuItem(
            height: 42,
            onTap: () => ImageUtils.onShareImg(item.url),
            child: const Text('分享', style: TextStyle(fontSize: 14)),
          ),
        PopupMenuItem(
          height: 42,
          onTap: () => ImageUtils.downloadImg([item.url]),
          child: const Text('保存图片', style: TextStyle(fontSize: 14)),
        ),
        if (PlatformUtils.isDesktop)
          PopupMenuItem(
            height: 42,
            onTap: () => PageUtils.launchURL(item.url),
            child: const Text('网页打开', style: TextStyle(fontSize: 14)),
          )
        else if (widget.picArr.length > 1)
          PopupMenuItem(
            height: 42,
            onTap: () => ImageUtils.downloadImg(
              widget.picArr.map((item) => item.url).toList(),
            ),
            child: const Text('保存全部', style: TextStyle(fontSize: 14)),
          ),
        if (item.isLivePhoto)
          PopupMenuItem(
            height: 42,
            onTap: () => ImageUtils.downloadLivePhoto(
              url: item.url,
              liveUrl: item.liveUrl!,
              width: item.width.toInt(),
              height: item.height.toInt(),
            ),
            child: Text(
              '保存${Platform.isIOS ? '实况' : '视频'}',
              style: const TextStyle(fontSize: 14),
            ),
          ),
        PopupMenuItem(
          height: 42,
          onTap: () async {
            await ImageBlockService.addBlockedImage(item.url);
            SmartDialog.showToast('已屏蔽图片');
          },
          child: const Text(
            '屏蔽图片',
            style: TextStyle(color: Colors.red, fontSize: 14),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    Widget grid = Padding(
      padding: const .only(top: 6),
      child: ImageGridBuilder(
        picArr: widget.picArr,
        onTap: (index) => _onTap(context, index),
        onSecondaryTapUp: ImageGridView.enableImgMenu && PlatformUtils.isDesktop
            ? (index, offset) => _showMenu(context, index, offset)
            : null,
        onLongPressStart: ImageGridView.enableImgMenu && PlatformUtils.isMobile
            ? (index, offset) => _showMenu(context, index, offset)
            : null,
        builder: (BuildContext context, ImageGridInfo info) {
          final width = info.size.width;
          final height = info.size.height;
          late final placeHolder = Container(
            width: width,
            height: height,
            decoration: BoxDecoration(
              color: ColorScheme.of(
                context,
              ).onInverseSurface.withValues(alpha: 0.4),
            ),
            child: Image.asset(
              Assets.loading,
              width: width,
              height: height,
              cacheWidth: width.cacheSize(context),
            ),
          );
          return List.generate(widget.picArr.length, (index) {
            final item = widget.picArr[index];
            final borderRadius = _borderRadius(
              info.column,
              widget.picArr.length,
              index,
            );
            final imgSrc = item.url;

            // ── Blocked: show placeholder component instead of image ──
            // ── Pending: show neutral loading placeholder while async block check runs ──
            // ── Normal: show preview image ──
            if (_enableBlock) {
              final isBlocked = _imageBlockStatus[imgSrc] == true;
              final tempUnblocked = _isTempUnblocked(imgSrc);

              if (isBlocked && !tempUnblocked) {
                return LayoutId(
                  id: index,
                  child: Semantics(
                    label: '图片已屏蔽，第 ${index + 1} 张，共 ${widget.picArr.length} 张',
                    button: true,
                    child: BlockedImagePlaceholder(
                      width: width,
                      height: height,
                      borderRadius: borderRadius,
                      onLongPress: () => _showUnblockMenu(context, imgSrc),
                    ),
                  ),
                );
              }

              // Not yet evaluated — try sync cache, otherwise show neutral placeholder
              if (_imageBlockStatus[imgSrc] == null) {
                final syncResult = ImageBlockService.getCachedBlockResult(
                  imgSrc,
                );
                if (syncResult != null) {
                  _imageBlockStatus[imgSrc] = syncResult;
                  if (syncResult && !tempUnblocked) {
                    return LayoutId(
                      id: index,
                      child: Semantics(
                        label:
                            '图片已屏蔽，第 ${index + 1} 张，共 ${widget.picArr.length} 张',
                        button: true,
                        child: BlockedImagePlaceholder(
                          width: width,
                          height: height,
                          borderRadius: borderRadius,
                          onLongPress: () => _showUnblockMenu(context, imgSrc),
                        ),
                      ),
                    );
                  }
                } else {
                  // Cache miss — show neutral loading placeholder until async eval completes
                  return LayoutId(id: index, child: placeHolder);
                }
              }

            }

            // ── Normal: show preview image ──
            void onTap() => _onTap(context, index);
            Widget child = Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.center,
              children: [
                NetworkImgLayer(
                  src: item.url,
                  width: width,
                  height: height,
                  borderRadius: borderRadius,
                  alignment: item.isLongPic ? .topCenter : .center,
                  cacheWidth: item.width <= item.height,
                  getPlaceHolder: () => placeHolder,
                ),
                if (item.isLivePhoto)
                  const PBadge(text: 'Live', right: 8, bottom: 8, type: .gray)
                else if (item.isLongPic)
                  const PBadge(text: '长图', right: 8, bottom: 8),
              ],
            );
            if (!item.isLongPic) {
              child = Hero(tag: '${item.url}$hashCode', child: child);
            }
            child = Semantics(
              label: '图片，第 ${index + 1} 张，共 ${widget.picArr.length} 张',
              button: true,
              onTap: onTap,
              child: child,
            );
            return LayoutId(id: index, child: child);
          });
        },
      ),
    );

    // Wrap with VisibilityDetector to trigger blocking evaluation
    // when the grid first becomes visible.
    if (_enableBlock) {
      grid = VisibilityDetector(
        key: ValueKey('image_grid_block_${widget.hashCode}'),
        onVisibilityChanged: (info) {
          if (info.visibleFraction > 0 && !_blockingInitialized) {
            _blockingInitialized = true;
            _evaluateAllImages();
          }
        },
        child: grid,
      );
    }

    return grid;
  }
}
