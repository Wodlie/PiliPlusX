import 'dart:collection';

import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/pages/mine/controller.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/accounts/identity_core/identity_snapshot.dart';
import 'package:PiliPlus/utils/login_utils.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:hive_ce/hive.dart';

abstract final class Accounts {
  static late final Box<LoginAccount> account;
  static final _AccountLifecycleRegistry accountMode =
      _AccountLifecycleRegistry();
  static _AccountLifecycleState _state = _AccountLifecycleState.anonymous();
  static bool get mainEqVideo => main == video;
  static Account get main => get(AccountType.main);
  static Account get video => get(AccountType.video);
  static Account get heartbeat => get(AccountType.heartbeat);
  static OwnerScopedIdentitySnapshot get mainIdentity =>
      snapshot(AccountType.main);
  static OwnerScopedIdentitySnapshot get videoIdentity =>
      snapshot(AccountType.video);
  static OwnerScopedIdentitySnapshot get heartbeatIdentity =>
      snapshot(AccountType.heartbeat);
  static Account get history {
    final heartbeat = Accounts.heartbeat;
    if (heartbeat is AnonymousAccount) {
      return Accounts.main;
    }
    return heartbeat;
  }

  static Account get reply {
    final reply = accountMode[AccountType.reply.index];
    if (reply is AnonymousAccount) {
      return Accounts.main;
    }
    return reply;
  }

  static Account get blacklist {
    final blacklist = accountMode[AccountType.blacklist.index];
    if (blacklist is AnonymousAccount) {
      return Accounts.main;
    }
    return blacklist;
  }
  // static set main(Account account) => set(AccountType.main, account);

  static OwnerScopedIdentitySnapshot snapshot(AccountType key) {
    return _state.snapshots[key.index];
  }

  static Account canonicalize(Account value) {
    if (value is NoAccount) {
      return value;
    }
    if (value is AnonymousAccount) {
      return AnonymousAccount();
    }
    if (value is LoginAccount) {
      for (final account in _state.accounts) {
        if (account is LoginAccount && account.mid == value.mid) {
          return account;
        }
      }
    }
    return value;
  }

  static Future<void> init() async {
    account = await Hive.openBox(
      'account',
      compactionStrategy: (int entries, int deletedEntries) {
        return deletedEntries > 2;
      },
    );
  }

  static Future<void> refresh() async {
    final nextAccounts = _anonymousAccounts();
    final persistAccounts = <LoginAccount>[];
    for (final a in account.values) {
      for (final t in a.type) {
        nextAccounts[t.index] = a;
      }
      if (a.needsBuvidPersist) {
        persistAccounts.add(a);
      }
    }
    _publish(nextAccounts);
    // Persist accounts whose BUVID was auto-generated (old Hive records
    // that lacked field 4). This closes the gap where a fresh BUVID was
    // computed transiently but never written back to durable storage.
    await Future.wait([
      ...persistAccounts.map((a) => a.onChange()),
      ...(nextAccounts.toSet()..removeWhere((i) => i.activated)).map(
        Request.buvidActive,
      ),
    ]);
    // Legacy global 'buvid' key cleanup.
    // Since Tasks 1-2, guest BUVID (Pref.guestBuvid) covers anonymous
    // paths and per-account BUVID (LoginAccount.buvid) covers
    // logged-in paths. The old global key is no longer read by any
    // code path. Remove it so it can never accidentally re-enter
    // account hydration.
    await Pref.deleteLegacyBuvid();
  }

  static Future<void> clear() async {
    await account.clear();
    _publish(_anonymousAccounts());
    await AnonymousAccount().delete();
    Request.buvidActive(AnonymousAccount());
  }

  static Future<void> deleteAll(Set<Account> accounts) async {
    final isLoginMain = Accounts.main.isLogin;
    final nextAccounts = List<Account>.from(_state.accounts);
    for (int i = 0; i < AccountType.values.length; i++) {
      if (accounts.contains(nextAccounts[i])) {
        nextAccounts[i] = AnonymousAccount();
      }
    }
    _publish(nextAccounts);
    await Future.wait(accounts.map((i) => i.delete()));
    if (isLoginMain && !Accounts.main.isLogin) {
      await LoginUtils.onLogoutMain();
    }
  }

  static Future<void> set(AccountType key, Account account) async {
    final oldAccount = _state.accounts[key.index];
    final nextAccounts = List<Account>.from(_state.accounts);
    nextAccounts[key.index] = account;
    _publish(nextAccounts);
    await Future.wait([?account.onChange(), ?oldAccount.onChange()]);
    if (!account.activated) await Request.buvidActive(account);
    switch (key) {
      case AccountType.main:
        await (account.isLogin
            ? LoginUtils.onLoginMain()
            : LoginUtils.onLogoutMain());
        break;
      case AccountType.heartbeat:
        MineController.anonymity.value = !account.isLogin;
        break;
      default:
        break;
    }
  }

  @pragma("vm:prefer-inline")
  static Account get(AccountType key) {
    return _state.accounts[key.index];
  }

  static void _publish(List<Account> accounts) {
    final nextAccounts = List<Account>.unmodifiable(
      List<Account>.from(accounts),
    );
    final touchedAccounts = {
      ..._state.accounts.whereType<LoginAccount>(),
      ...nextAccounts.whereType<LoginAccount>(),
    };
    for (final account in touchedAccounts) {
      account.type.clear();
    }
    for (final type in AccountType.values) {
      final account = nextAccounts[type.index];
      if (account is LoginAccount) {
        account.type.add(type);
      }
    }
    _state = _AccountLifecycleState.fromAccounts(nextAccounts);
  }

  static List<Account> _anonymousAccounts() => List<Account>.filled(
    AccountType.values.length,
    AnonymousAccount(),
  );
}

final class _AccountLifecycleRegistry extends ListBase<Account> {
  @override
  int get length => AccountType.values.length;

  @override
  set length(int value) {
    throw UnsupportedError('Accounts.accountMode has a fixed length.');
  }

  @override
  Account operator [](int index) => Accounts._state.accounts[index];

  @override
  void operator []=(int index, Account value) {
    final nextAccounts = List<Account>.from(Accounts._state.accounts);
    nextAccounts[index] = value;
    Accounts._publish(nextAccounts);
  }
}

final class _AccountLifecycleState {
  const _AccountLifecycleState({
    required this.accounts,
    required this.snapshots,
  });

  factory _AccountLifecycleState.anonymous() {
    return _AccountLifecycleState.fromAccounts(Accounts._anonymousAccounts());
  }

  factory _AccountLifecycleState.fromAccounts(List<Account> accounts) {
    return _AccountLifecycleState(
      accounts: List<Account>.unmodifiable(accounts),
      snapshots: List<OwnerScopedIdentitySnapshot>.unmodifiable(
        accounts.map(OwnerScopedIdentitySnapshot.fromAccount),
      ),
    );
  }

  final List<Account> accounts;
  final List<OwnerScopedIdentitySnapshot> snapshots;
}
