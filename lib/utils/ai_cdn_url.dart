import 'dart:math' as math;

/// B站 CDN thumbnail URL patterns.
final _cdnHostRegex = RegExp(r'\.(hdslb|biliimg)\.com$');
const _bfsPath = '/bfs/';

/// Generates a CDN thumbnail URL suitable for AI inference.
///
/// For B站 CDN URLs (matching `*.hdslb.com` or `*.biliimg.com` with `/bfs/`
/// in the path), appends a `@{size}w_{size}h_0e.webp` suffix that:
///   - Clamps [size] to at least 320
///   - Strips any existing `@` parameter suffix
///   - Preserves any existing query string after the new suffix
///
/// For non-B站 URLs the original is returned unchanged.
String aiThumbnailUrl(
  String url, {
  required int inputWidth,
  required int inputHeight,
}) {
  final uri = Uri.tryParse(url);
  if (uri == null || !uri.hasAuthority) return url;

  // Must be a B站 CDN host with /bfs/ path.
  final host = uri.host;
  if (!_cdnHostRegex.hasMatch(host)) return url;
  if (!uri.path.contains(_bfsPath)) return url;

  // Separate query string (everything after first `?`).
  final queryIndex = url.indexOf('?');
  final baseUrl = queryIndex >= 0 ? url.substring(0, queryIndex) : url;
  final queryString = queryIndex >= 0 ? url.substring(queryIndex) : '';

  // Strip existing `@` suffix (from the last `@` onward).
  final atIndex = baseUrl.lastIndexOf('@');
  final cleanBase = atIndex >= 0 ? baseUrl.substring(0, atIndex) : baseUrl;

  final size = math.max(math.max(inputWidth, inputHeight), 320);

  return '${cleanBase}@${size}w_${size}h_0e.webp$queryString';
}
