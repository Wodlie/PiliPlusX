import 'package:PiliPlus/utils/accounts/identity_core.dart';

enum IdentityPersistenceSource { stored, legacy, generated }

final class IdentityPersistenceResolution {
  const IdentityPersistenceResolution({
    required this.profile,
    required this.source,
    required this.shouldDeleteLegacy,
  });

  final IdentityCoreProfile profile;
  final IdentityPersistenceSource source;
  final bool shouldDeleteLegacy;

  bool get shouldPersist => source != IdentityPersistenceSource.stored;
}

/// Minimal Task-3 helper for durable owner-scoped BUVID persistence.
///
/// Only stable owner BUVID belongs here. Request/workflow decorations such as
/// `traceId`, `gaia_vtoken`, `v_voucher`, `grisk_id`, `sessionId`, upload
/// markers, `buvid3`, `fp_local`, and `fp_remote` must not be persisted here.
abstract final class OwnerScopedIdentityPersistence {
  static const IdentityCoreProfileValidator _validator =
      IdentityCoreProfileValidator();
  static const IdentityCoreProfileGenerator _generator =
      IdentityCoreProfileGenerator();

  static IdentityPersistenceResolution resolve({
    required IdentityOwnerKey owner,
    String? storedBuvid,
    String? legacyBuvid,
  }) {
    _ensurePersistentOwner(owner);

    final storedProfile = _profileOrNull(owner, storedBuvid);
    if (_isValid(storedProfile)) {
      return IdentityPersistenceResolution(
        profile: storedProfile!,
        source: IdentityPersistenceSource.stored,
        shouldDeleteLegacy: legacyBuvid != null,
      );
    }

    final legacyProfile = _profileOrNull(owner, legacyBuvid);
    if (_isValid(legacyProfile)) {
      return IdentityPersistenceResolution(
        profile: legacyProfile!,
        source: IdentityPersistenceSource.legacy,
        shouldDeleteLegacy: legacyBuvid != null,
      );
    }

    return IdentityPersistenceResolution(
      profile: _generator.generate(
        IdentityCoreGenerationContext(
          owner: owner,
          storedProfile: storedProfile ?? legacyProfile,
        ),
      ),
      source: IdentityPersistenceSource.generated,
      shouldDeleteLegacy: legacyBuvid != null,
    );
  }

  static IdentityCoreProfile profileFor({
    required IdentityOwnerKey owner,
    required String buvid,
  }) {
    _ensurePersistentOwner(owner);
    final profile = IdentityCoreProfile(owner: owner, buvid: buvid);
    final validation = _validator.validate(profile);
    if (!validation.isValid) {
      throw ArgumentError.value(
        buvid,
        'buvid',
        validation.reason ?? 'Invalid persisted owner-scoped BUVID.',
      );
    }
    return profile;
  }

  static void _ensurePersistentOwner(IdentityOwnerKey owner) {
    if (!owner.isPersistent) {
      throw ArgumentError.value(
        owner,
        'owner',
        'Workflow-only owners cannot be persisted.',
      );
    }
  }

  static bool _isValid(IdentityCoreProfile? profile) {
    return profile != null && _validator.validate(profile).isValid;
  }

  static IdentityCoreProfile? _profileOrNull(
    IdentityOwnerKey owner,
    String? buvid,
  ) {
    if (buvid == null) {
      return null;
    }
    return IdentityCoreProfile(owner: owner, buvid: buvid);
  }
}
