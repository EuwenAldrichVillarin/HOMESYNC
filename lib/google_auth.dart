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
      button = web_gsi.renderButton();
    }

    ready = true;
  }

  // Android/iOS only — web must use the `button` widget above.
  Future<GoogleSignInAccount> authenticate() {
    return GoogleSignIn.instance.authenticate();
  }
}
