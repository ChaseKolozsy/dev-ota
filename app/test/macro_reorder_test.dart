import 'package:devota/macro_reorder.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // VelocityTracker reaches for the gesture binding's sampling clock.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('resolveMacroDropIndex', () {
    test('a slow drag keeps the slot the finger was released over', () {
      expect(
        resolveMacroDropIndex(newIndex: 2, itemCount: 6, flingVelocity: 120),
        2,
      );
      expect(
        resolveMacroDropIndex(newIndex: 3, itemCount: 6, flingVelocity: -300),
        3,
      );
    });

    test('a fast flick sends the macro to the start or the end', () {
      expect(
        resolveMacroDropIndex(newIndex: 4, itemCount: 6, flingVelocity: -2400),
        0,
      );
      expect(
        resolveMacroDropIndex(newIndex: 1, itemCount: 6, flingVelocity: 2400),
        5,
      );
    });

    test('the resolved slot always stays inside the list', () {
      expect(
        resolveMacroDropIndex(newIndex: 9, itemCount: 3, flingVelocity: 0),
        2,
      );
      expect(
        resolveMacroDropIndex(newIndex: -1, itemCount: 3, flingVelocity: 0),
        0,
      );
      expect(
        resolveMacroDropIndex(newIndex: 0, itemCount: 0, flingVelocity: 5000),
        0,
      );
    });
  });

  group('MacroDragVelocityTracker', () {
    PointerDownEvent down(Duration at, Offset position) =>
        PointerDownEvent(pointer: 1, timeStamp: at, position: position);
    PointerMoveEvent move(Duration at, Offset position) =>
        PointerMoveEvent(pointer: 1, timeStamp: at, position: position);
    PointerUpEvent up(Duration at, Offset position) =>
        PointerUpEvent(pointer: 1, timeStamp: at, position: position);

    testWidgets('reports the direction and speed of the drag', (tester) async {
      final tracker = MacroDragVelocityTracker(Axis.horizontal);
      tracker.onPointerDown(down(Duration.zero, const Offset(300, 40)));
      for (var step = 1; step <= 5; step++) {
        tracker.onPointerMove(
          move(
            Duration(milliseconds: 10 * step),
            Offset(300 - 30.0 * step, 40),
          ),
        );
      }
      tracker.onPointerUp(
        up(const Duration(milliseconds: 55), const Offset(150, 40)),
      );

      expect(tracker.velocity, lessThan(-macroFlingVelocity));
    });

    testWidgets('a drag that pauses before the lift is not a flick', (
      tester,
    ) async {
      final tracker = MacroDragVelocityTracker(Axis.vertical);
      tracker.onPointerDown(down(Duration.zero, const Offset(40, 400)));
      for (var step = 1; step <= 5; step++) {
        tracker.onPointerMove(
          move(
            Duration(milliseconds: 10 * step),
            Offset(40, 400 - 30.0 * step),
          ),
        );
      }
      expect(tracker.velocity, lessThan(-macroFlingVelocity));

      // The finger holds still for half a second: no further move events, so
      // only the stale-sample check can tell this apart from a flick.
      tracker.onPointerUp(
        up(const Duration(milliseconds: 550), const Offset(40, 250)),
      );

      expect(tracker.velocity, 0);
    });
  });

  group('MacroReorderableList', () {
    Future<List<int>> dragItem(
      WidgetTester tester, {
      required String label,
      required Offset Function(int step) moveBy,
      required int steps,
      required Duration stepDuration,
    }) async {
      final moves = <int>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 400,
              child: MacroReorderableList(
                itemCount: 5,
                itemKey: (index) => ValueKey('macro-$index'),
                itemBuilder: (context, index) => SizedBox(
                  height: 60,
                  child: Center(child: Text('macro-$index')),
                ),
                onReposition: (from, to) => moves.addAll([from, to]),
              ),
            ),
          ),
        ),
      );

      final gesture = await tester.startGesture(
        tester.getCenter(find.text(label)),
      );
      // Hold long enough to pick the macro up.
      var elapsed = kLongPressTimeout + const Duration(milliseconds: 20);
      await tester.pump(elapsed);
      for (var step = 1; step <= steps; step++) {
        elapsed += stepDuration;
        // Test pointers timestamp every event at zero unless told otherwise,
        // and a velocity is only as good as the times it is measured over.
        await gesture.moveBy(moveBy(step), timeStamp: elapsed);
        await tester.pump(stepDuration);
      }
      await gesture.up(timeStamp: elapsed);
      await tester.pumpAndSettle();
      return moves;
    }

    testWidgets('a slow drag moves the macro one slot', (tester) async {
      final moves = await dragItem(
        tester,
        label: 'macro-3',
        moveBy: (_) => const Offset(0, -12),
        steps: 5,
        stepDuration: const Duration(milliseconds: 120),
      );

      expect(moves, [3, 2]);
    });

    testWidgets('a fast flick sends the macro to the top', (tester) async {
      final moves = await dragItem(
        tester,
        label: 'macro-4',
        moveBy: (_) => const Offset(0, -30),
        steps: 5,
        stepDuration: const Duration(milliseconds: 8),
      );

      expect(moves, [4, 0]);
    });
  });
}
