enum IdentityOwnerKind { guest, account, workflow }

sealed class IdentityOwnerKey {
  const IdentityOwnerKey._();

  const factory IdentityOwnerKey.guest() = GuestIdentityOwnerKey;
  factory IdentityOwnerKey.account(int mid) = AccountIdentityOwnerKey;
  factory IdentityOwnerKey.workflow(String scope) = WorkflowIdentityOwnerKey;

  IdentityOwnerKind get kind;

  String get key;

  bool get isPersistent => kind != IdentityOwnerKind.workflow;

  bool get isWorkflowOnly => kind == IdentityOwnerKind.workflow;

  @override
  String toString() => key;
}

final class GuestIdentityOwnerKey extends IdentityOwnerKey {
  const GuestIdentityOwnerKey() : super._();

  @override
  IdentityOwnerKind get kind => IdentityOwnerKind.guest;

  @override
  String get key => 'guest';
}

final class AccountIdentityOwnerKey extends IdentityOwnerKey {
  AccountIdentityOwnerKey(this.mid) : super._() {
    if (mid <= 0) {
      throw ArgumentError.value(mid, 'mid', 'Account identity owner requires a positive mid.');
    }
  }

  final int mid;

  @override
  IdentityOwnerKind get kind => IdentityOwnerKind.account;

  @override
  String get key => 'account:$mid';
}

final class WorkflowIdentityOwnerKey extends IdentityOwnerKey {
  WorkflowIdentityOwnerKey(String scope)
    : scope = scope.trim(),
      super._() {
    if (this.scope.isEmpty) {
      throw ArgumentError.value(scope, 'scope', 'Workflow identity owner requires a non-empty scope.');
    }
  }

  final String scope;

  @override
  IdentityOwnerKind get kind => IdentityOwnerKind.workflow;

  @override
  String get key => 'workflow:$scope';
}
