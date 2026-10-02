import 'package:devota/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('new profile and selector preserve the existing connection', (tester) async {
    SharedPreferences.setMockInitialValues({
      'agent_ws_url': 'ws://original:8083/phone',
      'agent_pair_token': 'original-test-token',
      'agent_whole_device': true,
    });
    await tester.pumpWidget(const DevOtaApp());
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 30));
    }
    tester.widget<TabBar>(find.byType(TabBar).first).controller!.animateTo(7);
    await tester.pumpAndSettle();
    expect(find.text('ws://original:8083/phone'), findsOneWidget);
    await tester.tap(find.text('New profile'));
    await tester.pumpAndSettle();
    await tester.enterText(find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField)), 'Windows');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('ws://original:8083/phone'), findsNothing);
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Existing agent').last);
    await tester.pumpAndSettle();
    expect(find.text('ws://original:8083/phone'), findsOneWidget);
    expect(find.text('original-test-token'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  });
}
