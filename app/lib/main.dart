import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'config.dart';
import 'screens/home_screen.dart';
import 'screens/setup_screen.dart';
import 'state/app_state.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  final state = AppState(prefs);
  runApp(ChangeNotifierProvider.value(value: state, child: const NavigApp()));
  await state.init();
}

class NavigApp extends StatelessWidget {
  const NavigApp({super.key});

  static const seed = Color(0xFFFF4D6D);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: kAppName,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: seed, useMaterial3: true),
      darkTheme: ThemeData(colorSchemeSeed: seed, brightness: Brightness.dark, useMaterial3: true),
      locale: const Locale('vi'),
      supportedLocales: const [Locale('vi'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: Consumer<AppState>(
        builder: (context, state, _) {
          if (!state.ready) {
            return const Scaffold(body: Center(child: CircularProgressIndicator()));
          }
          return state.isLoggedIn ? const HomeScreen() : const SetupScreen();
        },
      ),
    );
  }
}
