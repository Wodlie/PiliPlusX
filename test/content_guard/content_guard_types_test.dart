import 'package:PiliPlus/services/content_guard/content_guard.dart';
import 'package:flutter_test/flutter_test.dart';

/// Concrete operator used to exercise the registry and capability declarations.
final class _FakeOperator implements FilterOperator {
  _FakeOperator({
    required this.id,
    this.status = FilterStatus.notMatched,
    this.availability = const OperatorAvailability(
      state: OperatorInitState.ready,
    ),
    Set<ContentType>? supportedContentTypes,
    Set<MediaType>? supportedMediaTypes,
    Set<ContentInput>? requiredInputs,
    this.needsNetwork = false,
    this.needsLocalInference = false,
    this.batchable = false,
  }) : supportedContentTypes =
           supportedContentTypes ?? const {ContentType.comment},
       supportedMediaTypes = supportedMediaTypes ?? const <MediaType>{},
       requiredInputs = requiredInputs ?? const {ContentInput.text};

  @override
  final String id;

  final FilterStatus status;

  @override
  final OperatorAvailability availability;

  @override
  final Set<ContentType> supportedContentTypes;

  @override
  final Set<MediaType> supportedMediaTypes;

  @override
  final Set<ContentInput> requiredInputs;

  @override
  final bool needsNetwork;

  @override
  final bool needsLocalInference;

  @override
  final bool batchable;

  int initializeCalls = 0;
  int evaluateCalls = 0;

  @override
  Future<void> initialize(OperatorInitContext context) async {
    initializeCalls++;
  }

  @override
  Future<FilterResult> evaluate(
    GuardContent content,
    OperatorRunContext context,
  ) async {
    evaluateCalls++;
    return FilterResult(
      operatorId: id,
      status: status,
      reasonCode: '${id}.reason',
      explanation: 'evaluated',
      evidence: const [],
    );
  }

  @override
  Future<List<FilterResult>> evaluateBatch(
    List<GuardContent> contents,
    OperatorRunContext context,
  ) async => [
    for (final content in contents) await evaluate(content, context),
  ];
}

AccountScope _scope({String id = 'cgs1_guest', bool isGuest = true}) =>
    AccountScope(id: id, isGuest: isGuest);

GuardContent _content({
  String contentId = '1001',
  ContentType contentType = ContentType.comment,
  ContentSurface surface = ContentSurface.rootComments,
  String occurrenceKey = 'occ-1',
  String? authorUid = '2002',
  String? parentId,
  String? text = 'hello world',
  String? title,
  List<String> tags = const [],
  List<MediaRef> media = const [],
  AccountScope? account,
  ContentContext context = ContentContext.empty,
  String contentVersion = 'v1',
}) => GuardContent(
  contentId: contentId,
  contentType: contentType,
  surface: surface,
  occurrenceKey: occurrenceKey,
  authorUid: authorUid,
  parentId: parentId,
  text: text,
  title: title,
  tags: tags,
  media: media,
  account: account ?? _scope(),
  context: context,
  contentVersion: contentVersion,
);

void main() {
  group('OperatorRegistry', () {
    test('register then find returns the same operator instance', () {
      final registry = OperatorRegistry();
      final keyword = _FakeOperator(id: 'keyword');

      expect(registry.isEmpty, isTrue);
      registry.register(keyword);

      expect(registry.isNotEmpty, isTrue);
      expect(registry.length, 1);
      expect(registry.contains('keyword'), isTrue);
      expect(identical(registry.find('keyword'), keyword), isTrue);
      expect(registry.operators, <FilterOperator>[keyword]);
    });

    test('find returns null for an unknown id instead of substituting', () {
      final registry = OperatorRegistry()
        ..register(_FakeOperator(id: 'keyword'));

      expect(registry.find('regex'), isNull);
      expect(registry.contains('regex'), isFalse);
      expect(registry.unregister('regex'), isFalse);
      expect(registry.unregister('keyword'), isTrue);
      expect(registry.find('keyword'), isNull);
    });

    test('register rejects a blank or duplicate id', () {
      final registry = OperatorRegistry()
        ..register(_FakeOperator(id: 'keyword'));

      expect(
        () => registry.register(_FakeOperator(id: '')),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => registry.register(_FakeOperator(id: 'keyword')),
        throwsA(isA<ArgumentError>()),
      );
      expect(registry.length, 1);
    });

    test('replace swaps the implementation and returns the previous one', () {
      final registry = OperatorRegistry();
      final first = _FakeOperator(id: 'keyword');
      final second = _FakeOperator(id: 'keyword');

      expect(registry.replace(first), isNull);
      expect(identical(registry.replace(second), first), isTrue);
      expect(identical(registry.find('keyword'), second), isTrue);
      expect(registry.length, 1);
    });

    test(
      'availableFor dispatches only ready operators that match capability',
      () {
        final registry = OperatorRegistry()
          ..register(_FakeOperator(id: 'keyword'))
          ..register(
            _FakeOperator(
              id: 'qr',
              availability: const OperatorAvailability(
                state: OperatorInitState.unavailable,
                reasonCode: 'capability.missing_qr',
              ),
            ),
          )
          ..register(
            _FakeOperator(
              id: 'video-only',
              supportedContentTypes: const {ContentType.video},
            ),
          )
          ..register(
            _FakeOperator(
              id: 'media-only',
              supportedMediaTypes: const {MediaType.image},
            ),
          );

        final withoutMedia = registry.availableFor(_content());
        expect(withoutMedia.map((o) => o.id), <String>['keyword']);

        final withImage = registry.availableFor(
          _content(
            media: const [
              MediaRef(
                id: 'p1',
                type: MediaType.image,
                url: 'https://example.invalid/a.jpg',
              ),
            ],
          ),
        );
        expect(withImage.map((o) => o.id), <String>['keyword', 'media-only']);
      },
    );

    test('an operator whose required input is missing is not dispatched', () {
      final registry = OperatorRegistry()
        ..register(
          _FakeOperator(
            id: 'title-rule',
            requiredInputs: const {ContentInput.title},
          ),
        )
        ..register(
          _FakeOperator(
            id: 'author-rule',
            requiredInputs: const {ContentInput.authorUid},
          ),
        );

      expect(
        registry
            .availableFor(_content(title: null, authorUid: '2002'))
            .map((o) => o.id),
        <String>['author-rule'],
      );
      expect(
        registry
            .availableFor(_content(title: 'T', authorUid: null))
            .map((o) => o.id),
        <String>['title-rule'],
      );
    });

    test('unavailable operators are reported, not silently omitted', () {
      final unavailable = _FakeOperator(
        id: 'llm',
        availability: const OperatorAvailability(
          state: OperatorInitState.unavailable,
          reasonCode: 'capability.no_provider',
          message: 'no AI provider configured',
        ),
      );
      final disabled = _FakeOperator(
        id: 'ocr',
        availability: const OperatorAvailability(
          state: OperatorInitState.disabled,
          reasonCode: 'feature.disabled',
        ),
      );
      final ready = _FakeOperator(id: 'keyword');

      final registry = OperatorRegistry()
        ..register(ready)
        ..register(unavailable)
        ..register(disabled);

      final content = _content();
      expect(registry.availableFor(content).map((o) => o.id), <String>[
        'keyword',
      ]);
      expect(registry.unavailableFor(content).map((o) => o.id), <String>[
        'llm',
        'ocr',
      ]);
      expect(registry.unavailableOperators.map((o) => o.id), <String>[
        'llm',
        'ocr',
      ]);
      expect(
        registry.byState(OperatorInitState.disabled).map((o) => o.id),
        <String>[
          'ocr',
        ],
      );

      final snapshot = registry.availabilitySnapshot();
      expect(snapshot.keys, <String>['keyword', 'llm', 'ocr']);
      expect(snapshot['llm']!.state, OperatorInitState.unavailable);
      expect(snapshot['llm']!.reasonCode, 'capability.no_provider');
      expect(snapshot['llm']!.isUnavailable, isTrue);
      expect(snapshot['keyword']!.isReady, isTrue);
      expect(snapshot['keyword']!.isUnavailable, isFalse);
    });

    test(
      'an operator outside its content-type scope is neither dispatched nor reported',
      () {
        final registry = OperatorRegistry()
          ..register(
            _FakeOperator(
              id: 'video-rule',
              supportedContentTypes: const {ContentType.video},
              availability: const OperatorAvailability(
                state: OperatorInitState.unavailable,
              ),
            ),
          );

        final comment = _content(contentType: ContentType.comment);
        expect(registry.availableFor(comment), isEmpty);
        expect(registry.unavailableFor(comment), isEmpty);
        expect(registry.unavailableOperators, hasLength(1));
      },
    );

    test('capability declarations are readable through the registry', () async {
      final keyword = _FakeOperator(
        id: 'keyword',
        needsNetwork: false,
        needsLocalInference: false,
        batchable: true,
        status: FilterStatus.matched,
      );
      final llm = _FakeOperator(
        id: 'llm',
        needsNetwork: true,
        needsLocalInference: true,
        requiredInputs: const {ContentInput.text, ContentInput.tags},
      );
      final registry = OperatorRegistry()
        ..register(keyword)
        ..register(llm);

      final found = registry.find('keyword')!;
      expect(found.needsNetwork, isFalse);
      expect(found.needsLocalInference, isFalse);
      expect(found.batchable, isTrue);
      expect(found.supportedContentTypes, const {ContentType.comment});
      expect(found.supportedMediaTypes, isEmpty);

      // A remote/inference operator declares both costs truthfully.
      final remote = registry.find('llm')!;
      expect(remote.needsNetwork, isTrue);
      expect(remote.needsLocalInference, isTrue);
      expect(remote.batchable, isFalse);
      expect(remote.requiredInputs, const {
        ContentInput.text,
        ContentInput.tags,
      });

      // A content object missing one declared input is not dispatched.
      expect(
        registry.availableFor(_content(tags: const [])).map((o) => o.id),
        <String>['keyword'],
      );
      expect(
        registry.availableFor(_content(tags: const ['ad'])).map((o) => o.id),
        <String>['keyword', 'llm'],
      );

      // The declared verdict of an operator reaches the caller unchanged.
      final verdict = await found.evaluate(
        _content(),
        OperatorRunContext(account: _scope(), ruleVersion: 'r1', generation: 1),
      );
      expect(verdict.status, FilterStatus.matched);
      expect(verdict.operatorId, 'keyword');
    });

    test('initializeAll initialises every registered operator once', () async {
      final first = _FakeOperator(id: 'a');
      final second = _FakeOperator(id: 'b');
      final registry = OperatorRegistry()
        ..register(first)
        ..register(second);

      await registry.initializeAll(
        const OperatorInitContext(
          buildVariant: 'standard',
          featureEnabled: true,
        ),
      );

      expect(first.initializeCalls, 1);
      expect(second.initializeCalls, 1);
      expect(first.evaluateCalls, 0);
    });

    test('operator lists are unmodifiable snapshots', () {
      final registry = OperatorRegistry()..register(_FakeOperator(id: 'a'));

      expect(
        () => registry.operators.add(_FakeOperator(id: 'b')),
        throwsUnsupportedError,
      );
      expect(registry.length, 1);
    });
  });

  group('FilterResult', () {
    FilterResult result(
      FilterStatus status, {
      String? errorCode,
      bool retryable = false,
    }) => FilterResult(
      operatorId: 'keyword',
      status: status,
      reasonCode: 'keyword.${status.name}',
      explanation: null,
      evidence: const [],
      errorCode: errorCode,
      retryable: retryable,
    );

    test('unknown is distinct from notMatched', () {
      final unknown = result(FilterStatus.unknown);
      final notMatched = result(FilterStatus.notMatched);

      expect(unknown.status, isNot(notMatched.status));
      expect(unknown == notMatched, isFalse);
      expect(unknown.isUnresolved, isTrue);
      expect(unknown.isNegative, isFalse);
      expect(notMatched.isUnresolved, isFalse);
      expect(notMatched.isNegative, isTrue);
      expect(notMatched.isMatch, isFalse);
    });

    test('error is distinct from notMatched', () {
      final error = result(FilterStatus.error, errorCode: 'operator.timeout');
      final notMatched = result(FilterStatus.notMatched);

      expect(error.status, isNot(notMatched.status));
      expect(error == notMatched, isFalse);
      expect(error.isUnresolved, isTrue);
      expect(error.isNegative, isFalse);
      expect(error.errorCode, 'operator.timeout');
      expect(notMatched.errorCode, isNull);
    });

    test('matched is the only positive verdict', () {
      for (final status in FilterStatus.values) {
        final verdict = result(status);
        expect(
          verdict.isMatch,
          status == FilterStatus.matched,
          reason: status.name,
        );
      }
    });

    test('all four statuses are mutually distinct values', () {
      expect(FilterStatus.values.toSet(), hasLength(4));
      expect(
        <FilterStatus>{
          FilterStatus.matched,
          FilterStatus.notMatched,
          FilterStatus.unknown,
          FilterStatus.error,
        },
        hasLength(4),
      );
      expect(FilterStatus.unknown, isNot(FilterStatus.error));
    });

    test('attributeViolation defaults to false and is part of equality', () {
      const plain = FilterResult(
        operatorId: 'qr',
        status: FilterStatus.matched,
        reasonCode: 'qr.detected',
        explanation: null,
        evidence: [],
      );
      const attributed = FilterResult(
        operatorId: 'qr',
        status: FilterStatus.matched,
        reasonCode: 'qr.detected',
        explanation: null,
        evidence: [],
        attributeViolation: true,
      );

      expect(plain.attributeViolation, isFalse);
      expect(plain.retryable, isFalse);
      expect(plain == attributed, isFalse);
      expect(attributed == attributed, isTrue);
    });

    test('evidence participates in equality', () {
      const withEvidence = FilterResult(
        operatorId: 'keyword',
        status: FilterStatus.matched,
        reasonCode: 'keyword.hit',
        explanation: null,
        evidence: [
          FilterEvidence(
            kind: EvidenceKind.text,
            field: 'text',
            redactedExcerpt: 'we\u2026',
          ),
        ],
      );
      const empty = FilterResult(
        operatorId: 'keyword',
        status: FilterStatus.matched,
        reasonCode: 'keyword.hit',
        explanation: null,
        evidence: [],
      );

      expect(withEvidence == empty, isFalse);
      expect(
        withEvidence.hashCode == empty.hashCode,
        isFalse,
      );
    });
  });

  group('AccountScope', () {
    AccountScope scopeOf({
      String? accessKey,
      String cookieDigest = 'cookie-a',
    }) => AccountScope.fromIdentityMaterial(
      mid: 42,
      isLogin: true,
      accessKey: accessKey,
      buvid: 'buvid-1',
      mobiApp: 'android',
      deviceDigest: 'device-1',
      cookieDigest: cookieDigest,
    );

    test('exposes only a digest and never the credential material', () {
      final scope = scopeOf(accessKey: 'super-secret-access-key');

      expect(scope.id, hasLength(69));
      expect(scope.id, startsWith('cgs1_'));
      expect(scope.isGuest, isFalse);

      final text = scope.toString();
      expect(text, isNot(contains('super-secret-access-key')));
      expect(text, isNot(contains('buvid-1')));
      expect(text, isNot(contains('cookie-a')));
      expect(text, isNot(contains('device-1')));
      expect(scope.id, isNot(contains('super-secret-access-key')));
    });

    test('rotating the access key rotates the scope id', () {
      expect(
        scopeOf(accessKey: 'key-a').id,
        isNot(scopeOf(accessKey: 'key-b').id),
      );
      expect(
        scopeOf(accessKey: 'key-a').id,
        isNot(scopeOf(accessKey: null).id),
      );
    });

    test('rotating the cookie digest rotates the scope id', () {
      expect(
        scopeOf(accessKey: 'key-a', cookieDigest: 'cookie-a').id,
        isNot(scopeOf(accessKey: 'key-a', cookieDigest: 'cookie-b').id),
      );
    });

    test('identical material yields an identical, equal scope', () {
      final a = scopeOf(accessKey: 'key-a');
      final b = scopeOf(accessKey: 'key-a');

      expect(a.id, b.id);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(scopeOf(accessKey: 'key-b')));
    });

    test('guest scopes are flagged and isolated from logged-in scopes', () {
      final guest = AccountScope.fromIdentityMaterial(
        mid: 0,
        isLogin: false,
        accessKey: null,
        buvid: 'buvid-1',
        mobiApp: '',
        deviceDigest: 'device-1',
        cookieDigest: 'cookie-a',
      );
      final loggedIn = scopeOf(accessKey: null);

      expect(guest.isGuest, isTrue);
      expect(loggedIn.isGuest, isFalse);
      expect(guest.id, isNot(loggedIn.id));
      expect(guest == loggedIn, isFalse);
    });

    test('scope identity is path safe for namespaced storage keys', () {
      final scope = scopeOf(accessKey: 'key/with:unsafe chars');
      expect(RegExp(r'^[A-Za-z0-9_]+$').hasMatch(scope.id), isTrue);
    });
  });

  group('GuardContent', () {
    test('value equality covers every field', () {
      final base = _content();
      expect(base, _content());
      expect(base.hashCode, _content().hashCode);

      expect(base, isNot(_content(contentId: '1002')));
      expect(base, isNot(_content(contentType: ContentType.video)));
      expect(base, isNot(_content(surface: ContentSurface.nestedReplies)));
      expect(base, isNot(_content(occurrenceKey: 'occ-2')));
      expect(base, isNot(_content(authorUid: '9999')));
      expect(base, isNot(_content(parentId: '7')));
      expect(base, isNot(_content(text: 'hello world!')));
      expect(base, isNot(_content(title: 'T')));
      expect(base, isNot(_content(tags: const ['ad'])));
      expect(base, isNot(_content(account: _scope(id: 'cgs1_other'))));
      expect(
        base,
        isNot(_content(context: const ContentContext(videoId: 'BV1'))),
      );
      expect(base, isNot(_content(contentVersion: 'v2')));
      expect(
        base,
        isNot(
          _content(
            media: const [
              MediaRef(
                id: 'p1',
                type: MediaType.image,
                url: 'https://example.invalid/a.jpg',
              ),
            ],
          ),
        ),
      );
    });

    test('lists with equal contents compare equal', () {
      final a = _content(tags: const ['ad', 'spam']);
      final b = _content(tags: const ['ad', 'spam']);
      final c = _content(tags: const ['spam', 'ad']);

      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a == c, isFalse);
    });

    test('fields are final and there is no mutable setter', () {
      final content = _content();

      expect(content.contentId, '1001');
      expect(content.contentVersion, 'v1');
      expect(content.versionKey, '1001@v1');
      expect(content.hasMedia, isFalse);
      expect(
        () => (content as dynamic).contentId = 'x',
        throwsNoSuchMethodError,
      );
      expect(
        () => (content as dynamic).contentVersion = 'v2',
        throwsNoSuchMethodError,
      );
    });

    test('contentVersion change produces a new identity', () {
      final first = _content(contentVersion: 'v1');
      final second = _content(contentVersion: 'v2');
      expect(first.versionKey, isNot(second.versionKey));
      expect(first, isNot(second));
    });

    test('toString does not leak the content payload', () {
      final content = _content(
        text: 'buy followers now',
        title: 'secret title',
      );
      final text = content.toString();

      expect(text, contains('1001'));
      expect(text, isNot(contains('buy followers now')));
      expect(text, isNot(contains('secret title')));
    });

    test('capability queries drive input declarations', () {
      final bare = _content(
        text: null,
        title: null,
        authorUid: null,
        tags: const [],
        media: const [],
      );
      expect(bare.provides(ContentInput.text), isFalse);
      expect(bare.provides(ContentInput.title), isFalse);
      expect(bare.provides(ContentInput.description), isFalse);
      expect(bare.provides(ContentInput.tags), isFalse);
      expect(bare.provides(ContentInput.authorUid), isFalse);
      expect(bare.provides(ContentInput.media), isFalse);
      // Structural metadata is always present: content type, surface, context.
      expect(bare.provides(ContentInput.metadata), isTrue);

      final full = _content(
        title: 'T',
        tags: const ['ad'],
        media: const [
          MediaRef(
            id: 'p1',
            type: MediaType.image,
            url: 'https://example.invalid/a.jpg',
          ),
        ],
      );
      expect(full.provides(ContentInput.text), isTrue);
      expect(full.provides(ContentInput.title), isTrue);
      expect(full.provides(ContentInput.tags), isTrue);
      expect(full.provides(ContentInput.authorUid), isTrue);
      expect(full.provides(ContentInput.media), isTrue);
      // The approved model has no description field, so this stays false
      // rather than being backed by an unrelated field.
      expect(full.provides(ContentInput.description), isFalse);
    });
  });

  group('MediaRef', () {
    test('fingerprint is the stable identity, url is not', () {
      const withoutPrint = MediaRef(
        id: 'p1',
        type: MediaType.image,
        url: 'https://example.invalid/a.jpg?sign=1',
      );
      const withPrint = MediaRef(
        id: 'p1',
        type: MediaType.image,
        url: 'https://example.invalid/b.jpg?sign=2',
        fingerprint: 'phash-abc',
      );

      expect(withoutPrint.hasStableIdentity, isFalse);
      expect(withoutPrint.stableKey, 'id:p1');
      expect(withPrint.hasStableIdentity, isTrue);
      expect(withPrint.stableKey, 'fp:phash-abc');
      expect(withPrint.stableKey, isNot(contains('example.invalid')));
    });

    test('withFingerprint preserves every other field', () {
      const original = MediaRef(
        id: 'p1',
        type: MediaType.avatar,
        url: 'https://example.invalid/a.jpg',
        width: 64,
        height: 64,
      );
      final hashed = original.withFingerprint('phash-xyz');

      expect(hashed.id, original.id);
      expect(hashed.type, original.type);
      expect(hashed.url, original.url);
      expect(hashed.width, original.width);
      expect(hashed.height, original.height);
      expect(hashed.fingerprint, 'phash-xyz');
      expect(hashed, isNot(original));
      expect(original.hasStableIdentity, isFalse);
    });

    test('equality covers every field and toString omits the url', () {
      const base = MediaRef(
        id: 'p1',
        type: MediaType.image,
        url: 'https://example.invalid/a.jpg?sign=secret-signature',
        fingerprint: 'phash-abc',
      );
      expect(
        base,
        const MediaRef(
          id: 'p1',
          type: MediaType.image,
          url: 'https://example.invalid/a.jpg?sign=secret-signature',
          fingerprint: 'phash-abc',
        ),
      );
      expect(
        base,
        isNot(
          const MediaRef(
            id: 'p2',
            type: MediaType.image,
            url: 'https://example.invalid/a.jpg?sign=secret-signature',
            fingerprint: 'phash-abc',
          ),
        ),
      );
      expect(
        base,
        isNot(
          const MediaRef(
            id: 'p1',
            type: MediaType.avatar,
            url: 'https://example.invalid/a.jpg?sign=secret-signature',
            fingerprint: 'phash-abc',
          ),
        ),
      );
      expect(
        base,
        isNot(
          const MediaRef(
            id: 'p1',
            type: MediaType.image,
            url: 'https://example.invalid/c.jpg?sign=secret-signature',
            fingerprint: 'phash-abc',
          ),
        ),
      );
      expect(
        base,
        isNot(
          const MediaRef(
            id: 'p1',
            type: MediaType.image,
            url: 'https://example.invalid/a.jpg?sign=secret-signature',
            fingerprint: 'phash-zzz',
          ),
        ),
      );

      final text = base.toString();
      expect(text, isNot(contains('example.invalid')));
      expect(text, isNot(contains('secret-signature')));
      expect(text, contains('phash'));
    });
  });

  group('ContentContext', () {
    test('empty carries no structural information', () {
      expect(ContentContext.empty.isEmpty, isTrue);
      expect(ContentContext.empty.videoId, isNull);
      expect(ContentContext.empty.threadId, isNull);
      expect(ContentContext.empty.parentContentId, isNull);
      expect(ContentContext.empty.replyType, isNull);
      expect(ContentContext.empty.sortKey, isNull);
      expect(ContentContext.empty.occurrenceKey, isNull);
    });

    test('copyWith fills fields and preserves the rest', () {
      const base = ContentContext(
        videoId: 'BV1',
        threadId: 'T1',
        sortKey: 'hot',
      );
      final nested = base.copyWith(
        parentContentId: '9001',
        replyType: 2,
        occurrenceKey: 'occ-2',
      );

      expect(nested.videoId, 'BV1');
      expect(nested.threadId, 'T1');
      expect(nested.sortKey, 'hot');
      expect(nested.parentContentId, '9001');
      expect(nested.replyType, 2);
      expect(nested.occurrenceKey, 'occ-2');
      expect(nested.isEmpty, isFalse);
      expect(nested, isNot(base));
    });

    test('thread and sort context are part of equality', () {
      expect(
        const ContentContext(threadId: 'T1'),
        const ContentContext(threadId: 'T1'),
      );
      expect(
        const ContentContext(threadId: 'T1').hashCode,
        const ContentContext(threadId: 'T1').hashCode,
      );
      expect(
        const ContentContext(threadId: 'T1'),
        isNot(const ContentContext(threadId: 'T2')),
      );
      expect(
        const ContentContext(sortKey: 'hot'),
        isNot(const ContentContext(sortKey: 'new')),
      );
      expect(
        const ContentContext(replyType: 1),
        isNot(const ContentContext(replyType: 2)),
      );
    });
  });

  group('OperatorAvailability / OperatorInitContext', () {
    test('only ready is dispatchable, and only settled states report', () {
      for (final state in OperatorInitState.values) {
        final availability = OperatorAvailability(state: state);
        expect(
          availability.isReady,
          state == OperatorInitState.ready,
          reason: state.name,
        );
        expect(
          availability.isSettled,
          state != OperatorInitState.uninitialized &&
              state != OperatorInitState.initializing,
          reason: state.name,
        );
        expect(
          availability.isUnavailable,
          state == OperatorInitState.unavailable ||
              state == OperatorInitState.disabled ||
              state == OperatorInitState.failed,
          reason: state.name,
        );
      }
    });

    test('availability equality includes the reason', () {
      const a = OperatorAvailability(
        state: OperatorInitState.unavailable,
        reasonCode: 'r1',
      );
      const b = OperatorAvailability(
        state: OperatorInitState.unavailable,
        reasonCode: 'r2',
      );
      const c = OperatorAvailability(
        state: OperatorInitState.unavailable,
        reasonCode: 'r1',
      );

      expect(a, c);
      expect(a.hashCode, c.hashCode);
      expect(a, isNot(b));
      expect(
        OperatorAvailability.uninitialized.state,
        OperatorInitState.uninitialized,
      );
    });

    test('init context carries the variant and the master switch only', () {
      const context = OperatorInitContext(
        buildVariant: 'standard',
        featureEnabled: false,
      );
      expect(context.buildVariant, 'standard');
      expect(context.featureEnabled, isFalse);
      expect(
        context,
        const OperatorInitContext(
          buildVariant: 'standard',
          featureEnabled: false,
        ),
      );
      expect(
        context,
        isNot(
          const OperatorInitContext(
            buildVariant: 'with_ai',
            featureEnabled: false,
          ),
        ),
      );
    });
  });

  group('OperatorRunContext', () {
    test('generation and rule version are part of equality', () {
      final account = _scope();
      final base = OperatorRunContext(
        account: account,
        ruleVersion: 'r1',
        generation: 1,
      );

      expect(
        base,
        OperatorRunContext(account: account, ruleVersion: 'r1', generation: 1),
      );
      expect(
        base.hashCode,
        OperatorRunContext(
          account: account,
          ruleVersion: 'r1',
          generation: 1,
        ).hashCode,
      );
      expect(
        base,
        isNot(
          OperatorRunContext(
            account: account,
            ruleVersion: 'r2',
            generation: 1,
          ),
        ),
      );
      expect(
        base,
        isNot(
          OperatorRunContext(
            account: account,
            ruleVersion: 'r1',
            generation: 2,
          ),
        ),
      );
      expect(
        base,
        isNot(
          OperatorRunContext(
            account: _scope(id: 'cgs1_other'),
            ruleVersion: 'r1',
            generation: 1,
          ),
        ),
      );
    });

    test('cancellation is an opaque token with an opt-in contract', () {
      final account = _scope();
      final idle = OperatorRunContext(
        account: account,
        ruleVersion: 'r1',
        generation: 1,
      );
      expect(idle.isCancelled, isFalse);
      expect(idle.cancellation, isNull);

      final aborted = OperatorRunContext(
        account: account,
        ruleVersion: 'r1',
        generation: 1,
        cancellation: const _Signal(true),
      );
      expect(aborted.isCancelled, isTrue);

      final flag = OperatorRunContext(
        account: account,
        ruleVersion: 'r1',
        generation: 1,
        cancellation: true,
      );
      expect(flag.isCancelled, isTrue);

      final opaque = OperatorRunContext(
        account: account,
        ruleVersion: 'r1',
        generation: 1,
        cancellation: Object(),
      );
      expect(opaque.isCancelled, isFalse);
    });

    test('evaluateBatch returns one positional verdict per input', () async {
      final operator = _FakeOperator(id: 'keyword', batchable: true);
      final context = OperatorRunContext(
        account: _scope(),
        ruleVersion: 'r1',
        generation: 3,
      );
      final contents = [_content(contentId: '1'), _content(contentId: '2')];

      final results = await operator.evaluateBatch(contents, context);

      expect(results, hasLength(2));
      expect(results.map((r) => r.operatorId), everyElement('keyword'));
      expect(operator.evaluateCalls, 2);
    });
  });
}

final class _Signal implements AbortSignal {
  const _Signal(this.isCancelled);

  @override
  final bool isCancelled;
}
