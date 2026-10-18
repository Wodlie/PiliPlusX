import 'package:PiliPlus/common/widgets/flutter/text_field/controller.dart';
import 'package:PiliPlus/common/widgets/flutter/text_field/editable_text.dart'
    as rich_edit;
import 'package:PiliPlus/common/widgets/flutter/text_field/text_field.dart'
    as rich;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

// Drives the real paste path of the mirrored EditableText so the delta built
// there and the selection RichTextEditingController adopts are both covered.
Future<void> _paste(
  WidgetTester tester,
  RichTextEditingController controller, {
  required String text,
  required TextSelection selection,
}) async {
  final focusNode = FocusNode();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: rich.RichTextField(
          controller: controller,
          focusNode: focusNode,
          maxLines: 4,
        ),
      ),
    ),
  );
  focusNode.requestFocus();
  await tester.pump();
  controller.selection = selection;
  await tester.pump();

  final state = tester.state<rich_edit.EditableTextState>(
    find.byType(rich_edit.EditableText),
  );
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'Clipboard.getData') {
      return <String, dynamic>{'text': text};
    }
    return null;
  });
  try {
    await tester.runAsync(
      () => state.pasteText(SelectionChangedCause.keyboard),
    );
  } finally {
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
  }
  await tester.pump();

  await tester.pumpWidget(const SizedBox.shrink());
  focusNode.dispose();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('paste at the end leaves the caret after the pasted text', (
    tester,
  ) async {
    final controller = RichTextEditingController(
      items: [RichTextItem.fromStart('abc')],
    );
    await _paste(
      tester,
      controller,
      text: 'XY',
      selection: const TextSelection.collapsed(offset: 3),
    );

    expect(controller.text, 'abcXY');
    expect(controller.selection, const TextSelection.collapsed(offset: 5));

    controller.dispose();
  });

  testWidgets('paste over a selection leaves the caret after the replacement', (
    tester,
  ) async {
    final controller = RichTextEditingController(
      items: [RichTextItem.fromStart('abcdef')],
    );
    await _paste(
      tester,
      controller,
      text: 'X',
      selection: const TextSelection(baseOffset: 1, extentOffset: 5),
    );

    expect(controller.text, 'aXf');
    expect(controller.selection, const TextSelection.collapsed(offset: 2));

    controller.dispose();
  });

  test('a replacement delta cannot adopt a selection past the new text', () {
    final controller = RichTextEditingController(
      items: [RichTextItem.fromStart('abcdef')],
    );
    controller.syncRichText(
      TextEditingDeltaReplacement(
        oldText: 'abcdef',
        replacementText: 'X',
        replacedRange: const TextRange(start: 1, end: 5),
        // Stale pre-paste extent (5) for the 3-character result.
        selection: const TextSelection.collapsed(offset: 5),
        composing: TextRange.empty,
      ),
    );

    expect(controller.plainText, 'aXf');
    expect(controller.newSelection.start, inInclusiveRange(0, 3));
    expect(controller.newSelection.end, inInclusiveRange(0, 3));
  });
}
