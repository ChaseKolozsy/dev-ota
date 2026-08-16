import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Hold-to-reposition support shared by the Macros tab (a vertical list) and the
/// terminal macro bar (a horizontal strip). Both surfaces show the same ranked
/// macro order, so dragging has to feel the same in both: hold a macro to pick
/// it up, drag slowly to move it one slot at a time, or flick to send it to the
/// very start or the very end of the list.

/// Release speed, in logical pixels per second, that turns a drag into a
/// "send it all the way" flick. A deliberate reposition ends with the finger
/// nearly stopped, so this only has to clear a slow drag's release speed —
/// but it has to stay high enough that easing into a slot mid-list never
/// teleports the macro.
const double macroFlingVelocity = 1200;

/// A velocity sample older than this is treated as a stop: the user dragged,
/// paused, then lifted, which is a placement and not a flick.
const Duration macroFlingSampleWindow = Duration(milliseconds: 100);

/// Resolves where a dragged macro actually lands.
///
/// [newIndex] is the slot the finger was over at release, as reported by
/// `ReorderableListView.onReorderItem`. [flingVelocity] is the primary-axis
/// release speed: negative points at the start of the list (up, or left),
/// positive at the end.
int resolveMacroDropIndex({
  required int newIndex,
  required int itemCount,
  required double flingVelocity,
  double flingThreshold = macroFlingVelocity,
}) {
  if (itemCount <= 0) return 0;
  var target = newIndex;
  if (flingVelocity <= -flingThreshold) {
    target = 0;
  } else if (flingVelocity >= flingThreshold) {
    target = itemCount - 1;
  }
  return target.clamp(0, itemCount - 1);
}

/// Tracks the primary-axis speed of the pointer that is dragging a macro.
///
/// `ReorderableListView` reports only the slot the finger was over at release,
/// so this is what tells a slow one-slot nudge from a flick to the end.
class MacroDragVelocityTracker {
  MacroDragVelocityTracker(this.axis);

  final Axis axis;

  VelocityTracker? _tracker;
  int? _pointer;
  Duration _lastSample = Duration.zero;
  double _velocity = 0;

  /// Primary-axis velocity of the most recent drag, in pixels per second.
  /// Negative points at the start of the list.
  double get velocity => _velocity;

  void onPointerDown(PointerDownEvent event) {
    _pointer = event.pointer;
    _tracker = VelocityTracker.withKind(event.kind);
    _lastSample = event.timeStamp;
    _velocity = 0;
    _tracker!.addPosition(event.timeStamp, event.position);
  }

  void onPointerMove(PointerMoveEvent event) {
    final tracker = _tracker;
    if (tracker == null || event.pointer != _pointer) return;
    tracker.addPosition(event.timeStamp, event.position);
    _lastSample = event.timeStamp;
    final pixelsPerSecond = tracker.getVelocity().pixelsPerSecond;
    _velocity = axis == Axis.vertical ? pixelsPerSecond.dy : pixelsPerSecond.dx;
  }

  void onPointerUp(PointerUpEvent event) {
    if (event.pointer != _pointer) return;
    // A finger that held still before lifting stops generating move events, so
    // the last sample would otherwise keep reporting the speed it had before
    // the pause and fling a carefully placed macro to the end.
    if (event.timeStamp - _lastSample > macroFlingSampleWindow) _velocity = 0;
    _pointer = null;
    _tracker = null;
  }

  void onPointerCancel(PointerCancelEvent event) {
    if (event.pointer != _pointer) return;
    _velocity = 0;
    _pointer = null;
    _tracker = null;
  }
}

/// A list whose items are picked up by holding them down, then dragged to a new
/// position — one slot at a time when moved slowly, or all the way to the start
/// or end when flicked.
class MacroReorderableList extends StatefulWidget {
  const MacroReorderableList({
    super.key,
    required this.itemCount,
    required this.itemKey,
    required this.itemBuilder,
    required this.onReposition,
    this.scrollDirection = Axis.vertical,
    this.padding,
    this.onRepositionStart,
    this.onRepositionEnd,
  });

  final int itemCount;

  /// Stable identity per item; macros use their id so the drag survives the
  /// rebuild that follows a reorder.
  final Key Function(int index) itemKey;
  final IndexedWidgetBuilder itemBuilder;

  /// Called with the final resting index, flick handling already applied.
  final void Function(int fromIndex, int toIndex) onReposition;

  final Axis scrollDirection;
  final EdgeInsets? padding;
  final ValueChanged<int>? onRepositionStart;
  final ValueChanged<int>? onRepositionEnd;

  @override
  State<MacroReorderableList> createState() => _MacroReorderableListState();
}

class _MacroReorderableListState extends State<MacroReorderableList> {
  late final _dragVelocity = MacroDragVelocityTracker(widget.scrollDirection);

  Widget _liftedItem(Widget child, int index, Animation<double> animation) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, _) {
        final lift = Curves.easeInOut.transform(animation.value);
        return Transform.scale(
          scale: 1 + 0.04 * lift,
          child: Material(
            type: MaterialType.transparency,
            elevation: 10 * lift,
            shadowColor: Theme.of(context).colorScheme.shadow,
            borderRadius: BorderRadius.circular(12),
            child: child,
          ),
        );
      },
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: _dragVelocity.onPointerDown,
      onPointerMove: _dragVelocity.onPointerMove,
      onPointerUp: _dragVelocity.onPointerUp,
      onPointerCancel: _dragVelocity.onPointerCancel,
      child: ReorderableListView.builder(
        scrollDirection: widget.scrollDirection,
        padding: widget.padding,
        // Handles are replaced by a hold anywhere on the macro, so the same
        // gesture works on the phone and on a desktop debug build.
        buildDefaultDragHandles: false,
        proxyDecorator: _liftedItem,
        onReorderStart: (index) {
          _confirmPickUp();
          widget.onRepositionStart?.call(index);
        },
        onReorderEnd: (index) => widget.onRepositionEnd?.call(index),
        itemCount: widget.itemCount,
        itemBuilder: (context, index) => ReorderableDelayedDragStartListener(
          key: widget.itemKey(index),
          index: index,
          child: widget.itemBuilder(context, index),
        ),
        onReorderItem: (oldIndex, newIndex) {
          final target = resolveMacroDropIndex(
            newIndex: newIndex,
            itemCount: widget.itemCount,
            flingVelocity: _dragVelocity.velocity,
          );
          if (target == oldIndex) return;
          widget.onReposition(oldIndex, target);
        },
      ),
    );
  }
}

/// Confirms the macro was picked up. Haptics are best-effort: a device without
/// a vibrator must not break the drag.
void _confirmPickUp() {
  HapticFeedback.mediumImpact().catchError((Object _) {});
}
