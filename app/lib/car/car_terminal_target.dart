import 'dart:convert';
import 'dart:typed_data';

import '../terminal_macro.dart';
import '../terminal_watch.dart';
import 'car_controller.dart';
import 'car_grammar.dart';

/// Car actions land on notification-bound tmux panes through
/// [TerminalWatchController] (separate SSH exec channels, pane-identity
/// guarded), so they work with DevOTA in the background (proposal §3).
class CarTerminalTarget implements CarTarget {
  CarTerminalTarget({
    required this.watch,
    required this.rankedMacros,
    required this.onUi,
    required this.onReconnect,
    required this.onRestartZeroTier,
    this.openAiTranscriber,
  });

  final TerminalWatchController watch;
  final List<TerminalMacro> Function() rankedMacros;
  final Future<bool> Function(CarUiCommand command) onUi;
  final Future<void> Function() onReconnect;
  final Future<void> Function() onRestartZeroTier;
  final Future<String?> Function(Uint8List wav)? openAiTranscriber;

  CarSendResult _result(String? failure) =>
      failure == null ? const CarSendResult.ok() : CarSendResult.failed(failure);

  @override
  List<CarPane> panes() {
    final cards = {for (final card in watch.cards) card['id']: card};
    return [
      for (final binding in watch.bindings)
        CarPane(
          binding.pane.id,
          cards[binding.pane.id]?['status']?.toString() ?? 'unknown',
          canEnter: cards[binding.pane.id]?['enter'] == true,
        ),
    ];
  }

  @override
  List<TerminalMacro> macros() => rankedMacros();

  @override
  Future<CarSendResult> sendKeys(String paneId, String bytes) async =>
      _result(await watch.carSendBytes(paneId, bytes));

  @override
  Future<CarSendResult> submitText(String paneId, String text) async =>
      _result(await watch.carSubmitText(paneId, text));

  @override
  Future<CarSendResult> backspace(String paneId, int count) async {
    final (failure, deleted) = await watch.carBackspace(paneId, count);
    return failure == null
        ? CarSendResult.ok(deleted)
        : CarSendResult.failed(failure);
  }

  @override
  Future<CarSendResult> runMacro(String paneId, TerminalMacro macro) async =>
      _result(await watch.carRunMacro(paneId, macro));

  @override
  Future<CarSendResult> scroll(
    String paneId,
    int lines, {
    required bool up,
  }) async => _result(await watch.carScroll(paneId, lines, up: up));

  @override
  Future<CarSendResult> scrollBottom(String paneId) async =>
      _result(await watch.carScrollBottom(paneId));

  @override
  Future<String?> readConclusion(String paneId) async {
    try {
      return await watch.carConclusion(paneId);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<String?> transcribeHome(Uint8List wav) async {
    try {
      return await watch.carTranscribe(base64Encode(wav));
    } catch (_) {
      return null;
    }
  }

  @override
  Future<String?> transcribeOpenAi(Uint8List wav) async {
    final transcriber = openAiTranscriber;
    if (transcriber == null) return null;
    try {
      return await transcriber(wav);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<bool> ui(CarUiCommand command) => onUi(command);

  @override
  Future<void> reconnect() => onReconnect();

  @override
  Future<void> restartZeroTier() => onRestartZeroTier();
}
