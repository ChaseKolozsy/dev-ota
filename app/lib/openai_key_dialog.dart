import 'package:flutter/material.dart';

class OpenAiKeyDialog extends StatefulWidget {
  const OpenAiKeyDialog({super.key, required this.initialValue});

  final String initialValue;

  static Future<String?> show(
    BuildContext context, {
    required String initialValue,
  }) {
    return showDialog<String>(
      context: context,
      builder: (ctx) => OpenAiKeyDialog(initialValue: initialValue),
    );
  }

  @override
  State<OpenAiKeyDialog> createState() => _OpenAiKeyDialogState();
}

class _OpenAiKeyDialogState extends State<OpenAiKeyDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    Navigator.pop(context, _controller.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('OpenAI API Key'),
      content: TextField(
        controller: _controller,
        decoration: const InputDecoration(
          hintText: 'sk-...',
          border: OutlineInputBorder(),
        ),
        obscureText: true,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _save(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}
