import 'dart:io';

import 'package:PiliPlus/grpc/bilibili/main/community/reply/v1.pb.dart';
import 'package:PiliPlus/grpc/bilibili/pagination.pb.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/pages/common/reply_controller.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';

/// Tests the reply list pagination dedup logic in [ReplyController].
///
/// The server's offset-based pagination can return comments that were
/// already loaded (hot-sort drift, new comments inserted between pages),
/// which made the comment section show identical comments while scrolling.
/// [ReplyController.handleLoadMore] must drop those duplicates before
/// appending.

class _TestReplyController extends ReplyController<MainListReply> {
  _TestReplyController([List<MainListReply>? queue]) : _queue = queue ?? [];

  final List<MainListReply> _queue;
  int _index = 0;

  @override
  dynamic get sourceId => 'test-oid';

  @override
  Future<LoadingState<MainListReply>> customGetData() async {
    if (_index >= _queue.length) {
      throw StateError('no more queued responses');
    }
    return Success(_queue[_index++]);
  }

  @override
  List<ReplyInfo>? getDataList(MainListReply response) => response.replies;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('pili_reply_dedup_test_');
    debugSetAppSupportDirPath(tempDir.path);
    await GStorage.init();
  });

  tearDownAll(() async {
    await GStorage.close();
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  ReplyInfo _reply(int id) => ReplyInfo(id: Int64(id));

  MainListReply _page(
    List<int> ids, {
    bool isEnd = false,
    int count = 100,
  }) =>
      MainListReply(
        replies: ids.map(_reply).toList(),
        subjectControl: SubjectControl(count: Int64(count)),
        cursor: CursorReply(isEnd: isEnd),
      );

  group('handleLoadMore', () {
    test('drops replies already present in the loaded list', () {
      final ctr = _TestReplyController();
      ctr.loadingState.value = Success([_reply(1), _reply(2), _reply(3)]);

      final incoming = [_reply(2), _reply(3), _reply(4)];
      ctr.handleLoadMore(incoming);

      expect(incoming.map((e) => e.id.toInt()), [4]);
    });

    test('keeps all items when there is no overlap', () {
      final ctr = _TestReplyController();
      ctr.loadingState.value = Success([_reply(1)]);

      final incoming = [_reply(2), _reply(3)];
      ctr.handleLoadMore(incoming);

      expect(incoming.map((e) => e.id.toInt()), [2, 3]);
    });

    test('also removes duplicates within the incoming page', () {
      final ctr = _TestReplyController();
      ctr.loadingState.value = Success([_reply(1)]);

      final incoming = [_reply(2), _reply(2), _reply(3)];
      ctr.handleLoadMore(incoming);

      expect(incoming.map((e) => e.id.toInt()), [2, 3]);
    });

    test('no-op when nothing is loaded yet', () {
      final ctr = _TestReplyController();
      ctr.loadingState.value = Success(null);

      final incoming = [_reply(1)];
      ctr.handleLoadMore(incoming);

      expect(incoming.map((e) => e.id.toInt()), [1]);
    });
  });

  group('queryData integration', () {
    test('load-more appends deduplicated replies', () async {
      final ctr = _TestReplyController([
        _page([1, 2, 3]),
        _page([3, 4, 5], isEnd: true),
      ]);

      await ctr.queryData();
      expect(ctr.loadingState.value.data!.map((e) => e.id.toInt()), [1, 2, 3]);

      await ctr.queryData(false);
      expect(
        ctr.loadingState.value.data!.map((e) => e.id.toInt()),
        [1, 2, 3, 4, 5],
      );
    });

    test('refresh replaces the list without dedup interference', () async {
      final ctr = _TestReplyController([
        _page([1, 2, 3]),
        _page([2, 3, 4]),
      ]);

      await ctr.queryData();
      await ctr.queryData(false);
      expect(
        ctr.loadingState.value.data!.map((e) => e.id.toInt()),
        [1, 2, 3, 4],
      );

      // Refresh: the fresh page overlaps the old list, but refresh
      // must keep it untouched (dedup only applies to load-more).
      final refreshed = _TestReplyController([_page([1, 3, 5])]);
      await refreshed.queryData();
      expect(
        refreshed.loadingState.value.data!.map((e) => e.id.toInt()),
        [1, 3, 5],
      );
    });
  });
}
