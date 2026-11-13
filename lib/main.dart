import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'firebase_options.dart';

import 'login.dart';
import 'signup.dart';
import 'home.dart';
import 'appliances.dart';
import 'report.dart';
import 'schedule.dart';
import 'logout.dart';
import 'members.dart';
import 'profile.dart';
import 'activity.dart';
import 'alerts.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'HomeSync',
      debugShowCheckedModeBanner: false,
      initialRoute: '/login',
      routes: {
        '/login': (context) => const LoginPage(),
        '/signup': (context) => const SignUpPage(),
        '/home': (context) => const HomePage(),
        '/appliances': (context) => const AppliancesPage(),
        '/report': (context) => const ReportPage(),
        '/schedule': (context) => const SchedulePage(),
        '/logout': (context) => const LogoutPage(),
        '/members': (context) => const MembersPage(),
        '/profile': (context) => const ProfilePage(),
        '/activity': (context) => const ActivityLogPage(),
        '/alerts': (context) => const AlertsPage(),
      },
    );
  }
}