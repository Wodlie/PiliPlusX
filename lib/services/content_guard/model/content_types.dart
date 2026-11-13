/// Content categories ContentGuard can evaluate.
///
/// The set is closed on purpose: an adapter that cannot map a platform object
/// onto one of these values must fail loudly instead of inventing a category at
/// runtime (plan-core §2.1).
enum ContentType { video, comment, article, dynamic, searchResult }

/// Where a piece of content was encountered.
///
/// The surface participates in every decision key and in every suggestion
/// anchor scope, so the same content id seen on two surfaces never shares one
/// decision (plan-core §2.8, §5.1).
enum ContentSurface {
  homeRecommend,
  relatedVideos,
  rootComments,
  nestedReplies,
  dynamicFeed,
  searchResults,
}

/// Role a media reference plays inside a piece of content.
enum MediaType { image, avatar, video, thumbnail, qrCandidate }

/// Declarative input requirement an operator can state.
///
/// Operators never receive the raw platform object; they declare which inputs
/// they need, and the registry only dispatches operators whose requirements the
/// content actually satisfies.
enum ContentInput { text, title, description, tags, authorUid, metadata, media }

/// Stable machine name of [ContentType], used by rule JSON and storage keys.
///
/// Never localise it and never derive it from a display label.
extension ContentTypeWire on ContentType {
  String get wireName => name;
}

/// Stable machine name of [ContentSurface], used by rule JSON and storage keys.
extension ContentSurfaceWire on ContentSurface {
  String get wireName => name;
}

/// Stable machine name of [MediaType], used by rule JSON and storage keys.
extension MediaTypeWire on MediaType {
  String get wireName => name;
}

/// Stable machine name of [ContentInput], used by rule JSON and storage keys.
extension ContentInputWire on ContentInput {
  String get wireName => name;
}

/// Resolves an enum value from its [Enum.name] wire value.
///
/// Returns `null` for a missing or unknown name. Callers must treat that as a
/// validation failure; silently falling back to a default would let a renamed
/// rule change meaning without notice (plan-core §2.4, §3 Step 3).
T? enumByWireName<T extends Enum>(List<T> values, String? wireName) {
  if (wireName == null) return null;
  final length = values.length;
  for (var i = 0; i < length; i++) {
    if (values[i].name == wireName) return values[i];
  }
  return null;
}
