import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:google_sign_in/google_sign_in.dart';
import 'package:google_sign_in_web/web_only.dart' as web_gsi;

const String _googleClientId =
    '768506792119-t4sqinevc60rael06hiodfcr7page100.apps.googleusercontent.com';

// GoogleSignIn.instance.initialize() must be called exactly once for the
// whole lifetime of the app — calling it a second time throws "Bad state:
// init() has already been called." Login and Sign Up both need Google
// Sign-In, so initialization lives here as a process-wide singleton
// instead of being duplicated (and re-triggered) in each page's initState.
class GoogleAuthGate {
  GoogleAuthGate._();
  static final GoogleAuthGate instance = GoogleAuthGate._();

  Future<void>? _initFuture;
  bool ready = false;

  // Built once on web and reused everywhere — a fresh renderButton() call
  // tears down and re-mounts the underlying platform view.
  Widget? button;

  final _signInEvents = StreamController<GoogleSignInAccount>.broadcast();
  Stream<GoogleSignInAccount> get onSignIn => _signInEvents.stream;

  Future<void> ensureInitialized() {
    return _initFuture ??= _init();
  }

  Future<void> _init() async {
    await GoogleSignIn.instance.initialize(
      clientId: kIsWeb ? _googleClientId : null,
      serverClientId: kIsWeb ? null : _googleClientId,
    );

    if (kIsWeb) {
      // Web sign-in results arrive via this event stream instead of being
      // returned directly from authenticate() (which isn't supported on
      // web). Fanned out through our own broadcast controller so both
      // pages can listen without touching this single-subscription stream
      // more than once.
      GoogleSignIn.instance.authenticationEvents.listen((event) {
        if (event is GoogleSignInAuthenticationEventSignIn) {
          _signInEvents.add(event.user);
        }
      });
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
      button = web_gsi.renderButton(
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

    ready = true;
  }

  // Android/iOS only — web must use the `button` widget above.
  Future<GoogleSignInAccount> authenticate() {
    return GoogleSignIn.instance.authenticate();
  }
}
