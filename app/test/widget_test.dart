import 'package:flutter_test/flutter_test.dart';
import 'package:devota/main.dart';

void main() {
  testWidgets('App renders', (WidgetTester tester) async {
    await tester.pumpWidget(const DevOtaApp());
    expect(find.text('DevOTA'), findsOneWidget);
  });
}
