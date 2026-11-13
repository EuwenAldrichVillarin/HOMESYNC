import 'package:flutter/widgets.dart';
import 'package:google_sign_in_web/web_only.dart' as web_gsi;

// Web-only: google_sign_in_web pulls in dart:ui_web and dart:js_interop,
// which don't exist on Android/iOS. google_auth.dart picks this file or
// google_button_stub.dart with a conditional import.
//
// Styled to sit next to the Facebook button rather than next to
// nothing: pill + outline + large matches that button's 25px
// radius, grey border and ~50px height.
//
// locale is pinned because the rendered button otherwise follows
// the browser's language — which is why it read "Mag-sign in sa
// Google" beside an English "Facebook".
//
// Google caps this button at 400x40 and gives no way to stretch
// it, so the Facebook button is sized to match this one rather
// than the other way round. 240 is what both are pinned to.
Widget renderGoogleButton() {
  return web_gsi.renderButton(
    configuration: web_gsi.GSIButtonConfiguration(
      theme: web_gsi.GSIButtonTheme.outline,
      size: web_gsi.GSIButtonSize.large,
      shape: web_gsi.GSIButtonShape.pill,
      text: web_gsi.GSIButtonText.continueWith,
      logoAlignment: web_gsi.GSIButtonLogoAlignment.center,
      minimumWidth: 240,
      locale: 'en',
    ),
  );
}
