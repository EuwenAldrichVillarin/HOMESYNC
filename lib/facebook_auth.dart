import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_facebook_auth/flutter_facebook_auth.dart';

// =====================================================================
// FACEBOOK SIGN-IN SETUP
//
// Android and iOS read the app id out of the native config — on Android
// that's res/values/strings.xml, which the SDK picks up at startup. Web
// has no such file: the Facebook JavaScript SDK has to be loaded and
// handed the app id at runtime, and until that happens `window.FB`
// doesn't exist and login fails with exactly that error.
//
// flutter_facebook_auth injects the SDK <script> itself, but only from
// inside webAndDesktopInitialize(), so something has to call it. Same
// shape as GoogleAuthGate: initialise once, process-wide, rather than
// once per page.
// =====================================================================

/// The web app id, from developers.facebook.com -> App settings -> Basic.
///
/// Only web needs this in Dart. Android reads its copy from
/// android/app/src/main/res/values/strings.xml, so when you fill that in,
/// fill this in too — they are the same number.
///
/// Not a secret: it's visible in any page that loads the SDK.
const String kFacebookWebAppId = '1693090185754153';

/// Graph API version the web SDK is pinned to. Bumping this is safe as
/// long as the Meta app supports it.
const String kFacebookGraphVersion = 'v21.0';

class FacebookAuthGate {
  FacebookAuthGate._();
  static final FacebookAuthGate instance = FacebookAuthGate._();

  Future<void>? _initFuture;

  /// False while [kFacebookWebAppId] is still the placeholder. Lets the
  /// UI say so plainly instead of letting the SDK fail with
  /// "window.FB is undefined", which tells a user nothing.
  static bool get isConfiguredForWeb =>
      kFacebookWebAppId.isNotEmpty && !kFacebookWebAppId.startsWith('REPLACE_WITH');

  /// True when Facebook sign-in can actually be attempted here. Mobile
  /// is configured natively, so it's only web that can be unready.
  static bool get isAvailable => !kIsWeb || isConfiguredForWeb;

  /// No-op off the web, where the native SDK self-initialises.
  Future<void> ensureInitialized() {
    if (!kIsWeb) return Future.value();
    return _initFuture ??= _init();
  }

  Future<void> _init() async {
    if (!isConfiguredForWeb) {
      throw StateError(
        'Facebook sign-in is not set up for web yet. Put your Facebook '
        'app id in kFacebookWebAppId (lib/facebook_auth.dart).',
      );
    }

    await FacebookAuth.i.webAndDesktopInitialize(
      appId: kFacebookWebAppId,
      cookie: true,
      xfbml: true,
      version: kFacebookGraphVersion,
    );
  }
}
