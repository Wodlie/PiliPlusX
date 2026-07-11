import 'package:PiliPlus/common/widgets/dialog/missing_model_dialog.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MissingModelDialog session flag', () {
    setUp(() {
      MissingModelDialog.resetSessionFlag();
    });

    test('hasShownThisSession is false by default after reset', () {
      expect(MissingModelDialog.hasShownThisSession, isFalse);
    });

    test('resetSessionFlag does not throw', () {
      expect(MissingModelDialog.resetSessionFlag, returnsNormally);
    });

    test('resetSessionFlag can be called multiple times', () {
      MissingModelDialog.resetSessionFlag();
      MissingModelDialog.resetSessionFlag();
      MissingModelDialog.resetSessionFlag();
      expect(MissingModelDialog.hasShownThisSession, isFalse);
    });
  });
}
