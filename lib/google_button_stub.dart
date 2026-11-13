import 'package:flutter/widgets.dart';

// Android/iOS stand-in for google_button_web.dart. Never called there —
// GoogleAuthGate only renders the button when kIsWeb — it just keeps the
// web-only package out of the mobile build.
Widget renderGoogleButton() => throw UnsupportedError('Google button is web-only');
