import 'identity_contracts.dart';
import 'identity_owner.dart';

final class IdentityCoreProfile implements IdentityProfileView {
  IdentityCoreProfile({
    required this.owner,
    required String buvid,
  }) : buvid = _normalizeBuvid(buvid);

  @override
  final IdentityOwnerKey owner;

  @override
  final String buvid;

  String get ownerKey => owner.key;

  bool get isPersistent => owner.isPersistent;

  bool get isWorkflowOnly => owner.isWorkflowOnly;

  IdentityCoreProfile copyWith({
    IdentityOwnerKey? owner,
    String? buvid,
  }) {
    return IdentityCoreProfile(
      owner: owner ?? this.owner,
      buvid: buvid ?? this.buvid,
    );
  }

  static String _normalizeBuvid(String buvid) {
    final normalized = buvid.trim();
    if (normalized.isEmpty) {
      throw ArgumentError.value(buvid, 'buvid', 'Identity core profile requires a non-empty BUVID.');
    }
    return normalized;
  }
}
