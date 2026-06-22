import 'package:flutter/material.dart';
import 'build_list_screen.dart';

void main() {
  runApp(const DevOtaApp());
}

class DevOtaApp extends StatelessWidget {
  const DevOtaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DevOTA',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: Colors.deepPurple,
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: const BuildListScreen(),
    );
  }
}
