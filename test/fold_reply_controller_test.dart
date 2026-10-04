import 'dart:async';
import 'dart:io';

import 'package:PiliPlus/grpc/bilibili/main/community/reply/v1.pb.dart'
    show MainListReply;
import 'package:PiliPlus/grpc/bilibili/main/community/reply/v1.pb.dart' as gen;
import 'package:PiliPlus/grpc/bilibili/pagination.pb.dart';
import 'package:PiliPlus/grpc/fold_list_req_ext.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/models/common/video/video_type.dart';
import 'package:PiliPlus/pages/video/reply/controller.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

/// 根评论区折叠评论的状态机（官方 FOLD 卡 → FoldList → 插回列表）。
///
/// 背景：生成物 `MixedCard_Type` 缺 `FOLD(2)`，修复需要把手写兼容层接进
/// 控制器。接进去以后暴露出三个必须在控制器层钉死的行为：
///
/// 1. 空游标的折叠卡不能被当成「找到了」而截断遍历；
/// 2. 刷新后折叠状态必须重置，否则折叠评论被整页替换后再也拉不回来；
/// 3. 刷新前发出的 FoldList 响应必须丢弃，不能塞回新列表。
///
/// [VideoReplyController] 的实际取数被下面这个测试子类覆盖，因此用例不发网络
/// 请求，也不依赖 `VideoDetailController`。
class _TestVideoReplyController extends VideoReplyController {
  _TestVideoReplyController({required List<MainListReply> queue})
    : _queue = queue,
      super(aid: 12345, videoType: VideoType.ugc, heroTag: 'fold-test');

  final List<MainListReply> _queue;
  int _index = 0;

  int get callCount => _index;
  Future<void>? mainListGate;

  /// FoldList 的返回值；用例用它构造「空结果 / 被挂起 / 失败」等场景。
  Future<LoadingState<FoldListResp>> Function(String offset)? onFoldList;

  @override
  dynamic get sourceId => 'fold-test';

  @override
  Future<LoadingState<MainListReply>> customGetData() async {
    if (_index >= _queue.length) {
      throw StateError('no more queued responses');
    }
    final response = _queue[_index++];
    if (mainListGate case final gate?) await gate;
    return Success(response);
  }

  @override
  Future<LoadingState<FoldListResp>> fetchFoldList(String offset) {
    final handler = onFoldList;
    if (handler == null) {
      throw StateError('onFoldList not set');
    }
    return handler(offset);
  }
}

/// 用**手写**（含 FOLD(2)）的编码器生成 wire 字节，模拟服务端下发。
List<int> _encodeFold({required String offset}) => MixedCard(
  type: MixedCardType.FOLD,
  fold: FoldCard(
    bottomText: '已为您过滤部分不友善评论',
    foldPagination: FeedPagination(offset: offset),
  ),
).writeToBuffer();

/// 把 wire 字节塞回**生成类** MixedCard：线上的 FOLD 就是这样落到 unknownFields。
gen.MixedCard _wireFold({required String offset, int? rank}) {
  final card = gen.MixedCard.fromBuffer(_encodeFold(offset: offset));
  if (rank != null) card.displayRank = Int64(rank);
  return card;
}

gen.ReplyInfo _reply(int id) => gen.ReplyInfo(id: Int64(id));

MainListReply _page(
  List<int> ids, {
  List<gen.MixedCard> mixedCards = const [],
  bool isEnd = false,
  int count = 100,
}) => MainListReply(
  replies: ids.map(_reply).toList(),
  mixedCards: mixedCards,
  subjectControl: gen.SubjectControl(count: Int64(count)),
  cursor: gen.CursorReply(isEnd: isEnd),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp(
      'pili_fold_controller_test_',
    );
    debugSetAppSupportDirPath(tempDir.path);
    await GStorage.init();
  });

  tearDownAll(() async {
    await GStorage.close();
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  setUp(() async {
    await GStorage.setting.put(SettingBoxKey.autoShowFoldedReply, true);
  });

  tearDown(() => Get.reset());

  /// 注册控制器即可：用例只驱动它的状态机，不构建任何界面。
  void register(_TestVideoReplyController ctr) {
    Get.put<VideoReplyController>(ctr, tag: 'fold-test');
  }

  group('折叠卡挑选', () {
    testWidgets('空游标的卡被跳过，继续找后面的有效卡', (tester) async {
      final ctr = _TestVideoReplyController(
        queue: [
          _page(
            [1, 2],
            mixedCards: [
              _wireFold(offset: '', rank: 0),
              _wireFold(offset: 'valid-offset', rank: 1),
            ],
          ),
        ],
      );
      ctr.onFoldList = (_) async => Success(FoldListResp());
      register(ctr);

      await ctr.queryData();

      expect(
        ctr.foldCard.value?.foldPagination.offset,
        'valid-offset',
        reason: '空游标卡没有入口，不能截断遍历',
      );
      expect(ctr.foldRank, 1);
    });

    testWidgets('没有可用折叠卡时保持为空', (tester) async {
      final ctr = _TestVideoReplyController(
        queue: [
          _page([1], mixedCards: [_wireFold(offset: '')]),
        ],
      );
      ctr.onFoldList = (_) async => Success(FoldListResp());
      register(ctr);

      await ctr.queryData();

      expect(ctr.foldCard.value, isNull);
    });
  });

  group('自动并入折叠评论', () {
    testWidgets('按 display_rank 插回列表，并标记为官方折叠', (tester) async {
      final ctr = _TestVideoReplyController(
        queue: [
          _page([1, 2], mixedCards: [_wireFold(offset: 'offset-1', rank: 1)]),
        ],
      );
      ctr.onFoldList = (_) async => Success(
        FoldListResp(replies: [_reply(900)]),
      );
      register(ctr);

      await ctr.queryData();
      await tester.pump();

      expect(
        ctr.loadingState.value.data!.map((e) => e.id.toInt()).toList(),
        [1, 900, 2],
        reason: 'display_rank=1 的折叠评论插到下标 1',
      );
      expect(ctr.foldedIds, contains(900));
      expect(ctr.foldedLoaded, isTrue);
    });

    testWidgets('折叠列表为空时不插入内容，也不算加载失败', (tester) async {
      final ctr = _TestVideoReplyController(
        queue: [
          _page([1], mixedCards: [_wireFold(offset: 'offset-1')]),
        ],
      );
      ctr.onFoldList = (_) async => Success(FoldListResp());
      register(ctr);

      await ctr.queryData();
      await tester.pump();

      expect(ctr.loadingState.value.data!.map((e) => e.id.toInt()).toList(), [
        1,
      ]);
      expect(ctr.foldedIds, isEmpty);
      expect(ctr.foldedLoaded, isTrue);
    });
  });

  group('刷新隔离', () {
    testWidgets('刷新后清空旧折叠评论，并按新卡重新拉取', (tester) async {
      final ctr = _TestVideoReplyController(
        queue: [
          _page([1, 2], mixedCards: [_wireFold(offset: 'offset-1', rank: 1)]),
          _page([3, 4], mixedCards: [_wireFold(offset: 'offset-2', rank: 0)]),
        ],
      );
      var foldCalls = 0;
      ctr.onFoldList = (offset) async {
        foldCalls++;
        return Success(
          FoldListResp(replies: [_reply(offset == 'offset-2' ? 901 : 900)]),
        );
      };
      register(ctr);

      await ctr.queryData();
      await tester.pump();
      expect(ctr.loadingState.value.data!.map((e) => e.id.toInt()).toList(), [
        1,
        900,
        2,
      ]);

      await ctr.onRefresh();
      await tester.pump();

      expect(
        ctr.loadingState.value.data!.map((e) => e.id.toInt()).toList(),
        [901, 3, 4],
        reason: '旧折叠评论随整页替换消失，新卡重新拉取并插回',
      );
      expect(ctr.foldedIds, contains(901));
      expect(ctr.foldCard.value?.foldPagination.offset, 'offset-2');
      expect(foldCalls, 2);
    });

    testWidgets('刷新前发出的响应被丢弃，不会污染新列表', (tester) async {
      final ctr = _TestVideoReplyController(
        queue: [
          _page([1, 2], mixedCards: [_wireFold(offset: 'offset-old')]),
          _page([3, 4], mixedCards: [_wireFold(offset: 'offset-new')]),
        ],
      );
      final gate = Completer<void>();
      ctr.onFoldList = (offset) async {
        // 上一代的请求挂起，等新列表就位后才返回。
        if (offset == 'offset-old') await gate.future;
        return Success(FoldListResp(replies: [_reply(900)]));
      };
      register(ctr);

      final first = ctr.queryData();
      await tester.pump();
      expect(ctr.callCount, 1);

      String? freshOffset;
      ctr.onFoldList = (offset) async {
        freshOffset = offset;
        return Success(FoldListResp(replies: [_reply(901)]));
      };
      await ctr.onRefresh();
      await tester.pump();
      expect(freshOffset, 'offset-new', reason: '刷新应针对新卡的游标重新拉取');
      expect(
        ctr.loadingState.value.data!.map((e) => e.id.toInt()).toList(),
        [901, 3, 4],
      );

      // 旧请求此刻才返回：它的结果属于上一代列表，必须被丢弃。
      gate.complete();
      await first;
      await tester.pump();

      expect(
        ctr.loadingState.value.data!.map((e) => e.id.toInt()).toList(),
        [901, 3, 4],
        reason: '属于上一代的 FoldList 结果不能追加进来',
      );
      expect(ctr.foldedIds, isNot(contains(900)));
    });

    testWidgets('新列表没有折叠卡时入口不残留', (tester) async {
      final ctr = _TestVideoReplyController(
        queue: [
          _page([1], mixedCards: [_wireFold(offset: 'offset-1')]),
          _page([2]),
        ],
      );
      ctr.onFoldList = (_) async => Success(FoldListResp());
      register(ctr);

      await ctr.queryData();
      await tester.pump();
      expect(ctr.foldCard.value, isNotNull);

      await ctr.onRefresh();
      await tester.pump();

      expect(ctr.foldCard.value, isNull);
      expect(ctr.foldedLoaded, isFalse);
    });

    testWidgets('根评论折叠列表跟随 next_offset 继续三页并保持顺序', (tester) async {
      final ctr = _TestVideoReplyController(
        queue: [
          _page([1, 2], mixedCards: [_wireFold(offset: 'fold-1', rank: 1)]),
        ],
      );
      final offsets = <String>[];
      ctr.onFoldList = (offset) async {
        offsets.add(offset);
        return switch (offset) {
          'fold-1' => Success(
            FoldListResp(
              replies: [_reply(900)],
              paginationReply: FeedPaginationReply(nextOffset: 'fold-2'),
            ),
          ),
          'fold-2' => Success(
            FoldListResp(
              replies: [_reply(901)],
              paginationReply: FeedPaginationReply(nextOffset: 'fold-3'),
            ),
          ),
          _ => Success(
            FoldListResp(
              replies: [_reply(902)],
              paginationReply: FeedPaginationReply(nextOffset: ''),
            ),
          ),
        };
      };
      register(ctr);

      await ctr.queryData();
      await tester.pump();

      expect(offsets, ['fold-1', 'fold-2', 'fold-3']);
      expect(
        ctr.loadingState.value.data!.map((e) => e.id.toInt()).toList(),
        [1, 900, 901, 902, 2],
      );
      expect(ctr.foldedIds, {900, 901, 902});
    });

    testWidgets('加载主列表期间刷新被拒绝时，不清空折叠状态', (tester) async {
      final ctr = _TestVideoReplyController(
        queue: [
          _page([1], mixedCards: [_wireFold(offset: 'fold-1')]),
          _page([2]),
        ],
      );
      ctr.onFoldList = (_) async => Success(
        FoldListResp(replies: [_reply(900)]),
      );
      register(ctr);
      await ctr.queryData();
      await tester.pump();

      final gate = Completer<void>();
      ctr.mainListGate = gate.future;
      final loading = ctr.queryData(false);
      await tester.pump();
      expect(ctr.isLoading, isTrue);

      await ctr.onRefresh();
      expect(ctr.foldCard.value, isNotNull);
      expect(ctr.foldedIds, contains(900));
      expect(ctr.loadingState.value.data!.map((e) => e.id.toInt()).toList(), [
        900,
        1,
      ]);

      gate.complete();
      await loading;
    });

    testWidgets('后续普通页首次带卡时自动加载，重复或空折叠页仍续页', (tester) async {
      final ctr = _TestVideoReplyController(
        queue: [
          _page([1, 2]),
          _page([3], mixedCards: [_wireFold(offset: 'fold-1', rank: 1)]),
        ],
      );
      final offsets = <String>[];
      ctr.onFoldList = (offset) async {
        offsets.add(offset);
        return switch (offset) {
          'fold-1' => Success(
            FoldListResp(
              replies: [_reply(2)],
              paginationReply: FeedPaginationReply(nextOffset: 'fold-2'),
            ),
          ),
          'fold-2' => Success(
            FoldListResp(
              paginationReply: FeedPaginationReply(nextOffset: 'fold-3'),
            ),
          ),
          _ => Success(FoldListResp(replies: [_reply(900)])),
        };
      };
      register(ctr);
      await ctr.queryData();
      expect(offsets, isEmpty);

      await ctr.onLoadMore();

      expect(offsets, ['fold-1', 'fold-2', 'fold-3']);
      expect(
        ctr.loadingState.value.data!.map((e) => e.id.toInt()).toList(),
        [1, 900, 2, 3],
      );
      expect(ctr.foldedIds, {900});
      expect(ctr.foldedLoaded, isTrue);
    });

    testWidgets('关闭自动加载时，后续页的卡仍可手动展开', (tester) async {
      await tester.runAsync(
        () => GStorage.setting.put(SettingBoxKey.autoShowFoldedReply, false),
      );
      final ctr = _TestVideoReplyController(
        queue: [
          _page([1]),
          _page([2], mixedCards: [_wireFold(offset: 'manual')]),
        ],
      );
      var foldCalls = 0;
      ctr.onFoldList = (_) async {
        foldCalls++;
        return Success(FoldListResp(replies: [_reply(900)]));
      };
      register(ctr);
      await ctr.queryData();
      await ctr.onLoadMore();

      expect(foldCalls, 0);
      expect(ctr.canShowFoldEntry, isTrue);
      await ctr.loadFoldedReplies();
      expect(foldCalls, 1);
      expect(ctr.canShowFoldEntry, isFalse);
      expect(ctr.foldedIds, {900});
    });
  });
}
