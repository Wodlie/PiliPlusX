import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:PiliPlus/grpc/bilibili/main/community/reply/v1.pb.dart' as gen;
import 'package:PiliPlus/grpc/bilibili/pagination.pb.dart';
import 'package:PiliPlus/grpc/fold_list_req_ext.dart';
import 'package:PiliPlus/grpc/grpc_req.dart';
import 'package:PiliPlus/grpc/url.dart';
import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/models/common/reply/reply_sort_type.dart';
import 'package:PiliPlus/pages/video/reply_reply/controller.dart';
import 'package:PiliPlus/utils/accounts/account_manager/account_mgr.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:dio/dio.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:protobuf/protobuf.dart' show GeneratedMessage;

// Keep production fetching and normalization; only skip automatic onInit fetching.
class _TestNestedReplyController extends VideoReplyReplyController {
  _TestNestedReplyController({super.dialog})
    : super(
        hasRoot: false,
        id: null,
        oid: 12345,
        rpid: 678,
        replyType: 1,
      );

  bool _initializing = false;

  @override
  void onInit() {
    _initializing = true;
    super.onInit();
    _initializing = false;
  }

  @override
  Future<void> queryData([bool isRefresh = true]) {
    if (_initializing) return Future<void>.value();
    return super.queryData(isRefresh);
  }
}

class _ReplyAdapter implements HttpClientAdapter {
  final handlers =
      <String, Future<GeneratedMessage> Function(GeneratedMessage)>{};
  final requests = <({String path, GeneratedMessage message})>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.uri.path;
    final bytes = GrpcReq.decompressProtobuf(options.data as Uint8List);
    final GeneratedMessage request = switch (path) {
      GrpcUrl.dialogList => gen.DialogListReq.fromBuffer(bytes),
      GrpcUrl.detailList => gen.DetailListReq.fromBuffer(bytes),
      GrpcUrl.foldList => FoldListReq.fromBuffer(bytes),
      _ => throw StateError('Unexpected request: $path'),
    };
    requests.add((path: path, message: request));
    final handler = handlers[path];
    if (handler == null) throw StateError('No handler for $path');
    final response = await handler(request);
    return ResponseBody.fromBytes(
      GrpcReq.compressProtobuf(response.writeToBuffer()),
      200,
      headers: {
        'grpc-status': ['0'],
        Headers.contentTypeHeader: ['application/grpc'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

gen.ReplyInfo _reply(int id, {int likes = 0}) =>
    gen.ReplyInfo(id: Int64(id), like: Int64(likes));

List<int> _foldBytes(String offset) => MixedCard(
  type: MixedCardType.FOLD,
  fold: FoldCard(foldPagination: FeedPagination(offset: offset)),
).writeToBuffer();

gen.DetailListReply _detail(
  List<int> ids, {
  List<List<int>> cards = const [],
  bool isEnd = false,
  String nextOffset = '',
}) {
  final reply = gen.DetailListReply(
    cursor: gen.CursorReply(isEnd: isEnd),
    root: gen.ReplyInfo(count: Int64(100), replies: ids.map(_reply)),
    paginationReply: FeedPaginationReply(nextOffset: nextOffset),
    subjectControl: gen.SubjectControl(upMid: Int64(99)),
  );
  return gen.DetailListReply.fromBuffer([
    ...reply.writeToBuffer(),
    for (final card in cards) ...[
      0x5a, // mixed_cards(11), length-delimited
      ..._varint(card.length),
      ...card,
    ],
  ]);
}

List<int> _varint(int value) {
  final out = <int>[];
  while (value >= 0x80) {
    out.add((value & 0x7f) | 0x80);
    value >>= 7;
  }
  return [...out, value];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tempDir;
  late _ReplyAdapter adapter;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('pili_nested_fold_test_');
    debugSetAppSupportDirPath(tempDir.path);
    await GStorage.init();
    Request();
    Request.accountManager = AccountManager();
    Request.dio.interceptors.add(Request.accountManager);
    Request.dio.interceptors.removeWhere((entry) => entry is LogInterceptor);
    adapter = _ReplyAdapter();
    Request.dio.httpClientAdapter = adapter;
  });

  setUp(() async {
    adapter.requests.clear();
    adapter.handlers.clear();
    await GStorage.setting.put(SettingBoxKey.autoShowFoldedReply, true);
    await GStorage.setting.put(
      SettingBoxKey.reply2SortType,
      ReplySortType.hot.index,
    );
  });

  tearDown(Get.reset);

  tearDownAll(() async {
    Request.dio.close(force: true);
    await GStorage.close();
    await tempDir.delete(recursive: true);
  });

  _TestNestedReplyController controller({int? dialog}) =>
      Get.put(_TestNestedReplyController(dialog: dialog));

  List<int> ids(VideoReplyReplyController controller) => controller
      .loadingState
      .value
      .data!
      .map((reply) => reply.id.toInt())
      .toList();

  test(
    'dialog cursor controls paging even when reported count is too small',
    () async {
      var calls = 0;
      adapter.handlers[GrpcUrl.dialogList] = (request) async {
        final dialogRequest = request as gen.DialogListReq;
        calls++;
        expect(dialogRequest.dialog, Int64(1));
        expect(dialogRequest.root, Int64(678));
        expect(dialogRequest.pagination.offset, calls == 1 ? '' : 'dialog-2');
        return gen.DialogListReply(
          subjectControl: gen.SubjectControl(count: Int64(2)),
          cursor: gen.CursorReply(isEnd: calls == 2),
          paginationReply: FeedPaginationReply(
            nextOffset: calls == 1 ? 'dialog-2' : '',
          ),
          replies: calls == 1
              ? [_reply(11), _reply(12)]
              : [_reply(12), _reply(13)],
        );
      };
      final ctr = controller(dialog: 1);
      await ctr.queryData();
      expect(ids(ctr), [11, 12]);
      expect(ctr.isEnd, isFalse);
      expect(ctr.count.value, 2);
      expect(ctr.firstFloor.value, isNull);

      await ctr.onLoadMore();
      expect(ids(ctr), [11, 12, 13]);
      expect(ctr.isEnd, isTrue);
      await ctr.onLoadMore();
      expect(calls, 2);
    },
  );

  for (final count in <int?>[null, 0]) {
    test('dialog pagination works with ${count ?? 'missing'} count', () async {
      var calls = 0;
      adapter.handlers[GrpcUrl.dialogList] = (_) async {
        calls++;
        return gen.DialogListReply(
          subjectControl: gen.SubjectControl(
            count: count == null ? null : Int64(count),
          ),
          cursor: gen.CursorReply(isEnd: calls == 2),
          paginationReply: FeedPaginationReply(
            nextOffset: calls == 1 ? 'next' : '',
          ),
          replies: [_reply(calls)],
        );
      };
      final ctr = controller(dialog: 1);
      await ctr.queryData();
      expect(ctr.isEnd, isFalse);
      expect(ctr.count.value, count ?? -1);
      await ctr.onLoadMore();
      expect(ids(ctr), [1, 2]);
      expect(ctr.isEnd, isTrue);
    });
  }

  test(
    'nested decoder skips malformed, missing and empty-offset cards',
    () async {
      adapter.handlers[GrpcUrl.detailList] = (_) async => _detail(
        [1, 2],
        cards: [
          [0x08],
          MixedCard(type: MixedCardType.FOLD).writeToBuffer(),
          _foldBytes(''),
          _foldBytes('nested-fold'),
        ],
      );
      adapter.handlers[GrpcUrl.foldList] = (request) async {
        expect((request as FoldListReq).pagination.offset, 'nested-fold');
        return FoldListResp(replies: [_reply(700, likes: 99)]);
      };
      final ctr = controller();
      await ctr.queryData();
      expect(ids(ctr), [700, 1, 2]);
      expect(ctr.foldedIds, {700});
      expect(ctr.foldCard.value?.foldPagination.offset, 'nested-fold');
    },
  );

  test('first fold card on a later nested page loads automatically', () async {
    var calls = 0;
    adapter.handlers[GrpcUrl.detailList] = (request) async {
      calls++;
      expect(
        (request as gen.DetailListReq).pagination.offset,
        calls == 1 ? '' : 'detail-2',
      );
      return calls == 1
          ? _detail([1], nextOffset: 'detail-2')
          : _detail([2], cards: [_foldBytes('later-fold')]);
    };
    adapter.handlers[GrpcUrl.foldList] = (_) async =>
        FoldListResp(replies: [_reply(700, likes: 99)]);
    final ctr = controller();
    await ctr.queryData();
    expect(
      adapter.requests.where((request) => request.path == GrpcUrl.foldList),
      isEmpty,
    );
    await ctr.onLoadMore();
    expect(ids(ctr), [700, 1, 2]);
    expect(ctr.foldedIds, {700});
  });

  test('nested fold pages continue and use the existing sort order', () async {
    adapter.handlers[GrpcUrl.detailList] = (_) async =>
        _detail([1], cards: [_foldBytes('fold-1')]);
    final offsets = <String>[];
    adapter.handlers[GrpcUrl.foldList] = (request) async {
      final offset = (request as FoldListReq).pagination.offset;
      offsets.add(offset);
      return FoldListResp(
        replies: [
          _reply(
            offset == 'fold-1' ? 700 : 701,
            likes: offset == 'fold-1' ? 99 : 100,
          ),
        ],
        paginationReply: FeedPaginationReply(
          nextOffset: offset == 'fold-1' ? 'fold-2' : '',
        ),
      );
    };
    final ctr = controller();
    await ctr.queryData();
    expect(offsets, ['fold-1', 'fold-2']);
    expect(ids(ctr), [701, 700, 1]);
    expect(ctr.foldedIds, {700, 701});
  });

  test(
    'rejected refresh and reload preserve nested state during load-more',
    () async {
      var calls = 0;
      final gate = Completer<void>();
      final requested = Completer<void>();
      adapter.handlers[GrpcUrl.detailList] = (_) async {
        calls++;
        if (calls == 2) {
          requested.complete();
          await gate.future;
        }
        return calls == 1
            ? _detail([1], cards: [_foldBytes('fold-1')], nextOffset: 'next')
            : _detail([2]);
      };
      adapter.handlers[GrpcUrl.foldList] = (_) async =>
          FoldListResp(replies: [_reply(700, likes: 99)]);
      final ctr = controller();
      await ctr.queryData();
      final card = ctr.foldCard.value;
      final loading = ctr.onLoadMore();
      await requested.future;
      ctr.index.value = 0;
      await ctr.onRefresh();
      await ctr.onReload();
      expect(calls, 2);
      expect(ctr.foldCard.value, same(card));
      expect(ctr.foldedIds, {700});
      expect(ctr.foldedLoaded, isTrue);
      expect(ids(ctr), [700, 1]);
      expect(ctr.index.value, 0);
      gate.complete();
      await loading;
      expect(ids(ctr), [700, 1, 2]);
    },
  );

  test(
    'accepted refresh discards the previous generation fold response',
    () async {
      var calls = 0;
      final gate = Completer<void>();
      final requested = Completer<void>();
      adapter.handlers[GrpcUrl.detailList] = (_) async {
        calls++;
        return calls == 1
            ? _detail([1], cards: [_foldBytes('old-fold')])
            : _detail([2]);
      };
      adapter.handlers[GrpcUrl.foldList] = (_) async {
        requested.complete();
        await gate.future;
        return FoldListResp(replies: [_reply(700)]);
      };
      final ctr = controller();
      final first = ctr.queryData();
      await requested.future;
      await ctr.onRefresh();
      expect(ids(ctr), [2]);
      expect(ctr.foldCard.value, isNull);
      gate.complete();
      await first;
      expect(ids(ctr), [2]);
      expect(ctr.foldedIds, isEmpty);
    },
  );

  test(
    'manual nested fold entry stays available when auto loading is disabled',
    () async {
      await GStorage.setting.put(SettingBoxKey.autoShowFoldedReply, false);
      adapter.handlers[GrpcUrl.detailList] = (_) async =>
          _detail([1], cards: [_foldBytes('manual')]);
      adapter.handlers[GrpcUrl.foldList] = (_) async =>
          FoldListResp(replies: [_reply(700)]);
      final ctr = controller();
      await ctr.queryData();
      expect(ctr.canShowFoldEntry, isTrue);
      expect(adapter.requests.length, 1);
      await ctr.loadFoldedReplies();
      expect(ctr.canShowFoldEntry, isFalse);
      expect(ctr.foldedIds, {700});
    },
  );
}
