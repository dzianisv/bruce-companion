/// App root: theme + the single [ConnectionController] provider.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'state/connection_controller.dart';
import 'ui/home_screen.dart';

class BruceCompanionApp extends StatelessWidget {
  const BruceCompanionApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => ConnectionController(),
      child: MaterialApp(
        title: 'Bruce Companion',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          brightness: Brightness.dark,
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.tealAccent,
            brightness: Brightness.dark,
          ),
        ),
        darkTheme: ThemeData(
          brightness: Brightness.dark,
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.tealAccent,
            brightness: Brightness.dark,
          ),
        ),
        themeMode: ThemeMode.dark,
        home: const HomeScreen(),
      ),
    );
  }
}
