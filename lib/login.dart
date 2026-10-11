import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/gestures.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:flutter_facebook_auth/flutter_facebook_auth.dart';
import 'facebook_auth.dart';
import 'google_auth.dart';
import 'household.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isLoading = false;
  bool _googleSignInReady = false;
  StreamSubscription<GoogleSignInAccount>? _googleAuthSub;

  @override
  void initState() {
    super.initState();
    _initGoogleSignIn();
  }

  @override
  void dispose() {
    _googleAuthSub?.cancel();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  // Actual initialize() call lives in GoogleAuthGate, shared with SignUpPage,
  // since GoogleSignIn.instance.initialize() may only be called once ever —
  // calling it again (e.g. after visiting the other auth page) throws.
  Future<void> _initGoogleSignIn() async {
    try {
      await GoogleAuthGate.instance.ensureInitialized();
      _googleAuthSub = GoogleAuthGate.instance.onSignIn.listen(
        _handleGoogleUser,
        onError: (Object e) => _showError("Google sign-in failed: $e"),
      );
      if (mounted) setState(() => _googleSignInReady = GoogleAuthGate.instance.ready);
    } catch (e) {
      if (mounted) {
        setState(() => _googleSignInReady = false);
        _showError("Google Sign-In setup issue: $e");
      }
    }
  }

  // Shared by both the mobile (authenticate()) and web (event stream) flows:
  // exchanges the Google account for a Firebase credential.
  Future<void> _handleGoogleUser(GoogleSignInAccount googleUser) async {
    setState(() => _isLoading = true);
    try {
      final googleAuth = googleUser.authentication;

      final credential = GoogleAuthProvider.credential(
        idToken: googleAuth.idToken,
      );

      await FirebaseAuth.instance.signInWithCredential(credential);
      await completeSignIn();
      if (mounted) {
        Navigator.pushReplacementNamed(context, '/home');
      }
    } on FirebaseAuthException catch (e) {
      _showError(e.message ?? "Google sign-in failed");
    } catch (e) {
      _showError("Something went wrong: $e");
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // ===========================================================
  // PASSWORD RESET
  //
  // Firebase mails the reset link and hosts the page that actually
  // changes the password, so there's nothing to build for the second
  // half of this — the app only asks which address to send it to.
  // ===========================================================
  void _showForgotPasswordDialog() {
    showDialog<void>(
      context: context,
      builder: (_) => _ForgotPasswordDialog(
        // Save them retyping it if they already started logging in.
        initialEmail: _emailController.text.trim(),
      ),
    );
  }

  // ===========================================================
  // EMAIL/PASSWORD LOGIN
  // ===========================================================
  Future<void> _loginWithEmail() async {
    setState(() => _isLoading = true);
    try {
      await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: _emailController.text.trim(),
        password: _passwordController.text.trim(),
      );
      // Resolves whether this account is a household admin or a member,
      // and what that member is allowed to do, before Home loads.
      await completeSignIn();
      if (mounted) {
        Navigator.pushReplacementNamed(context, '/home');
      }
    } on FirebaseAuthException catch (e) {
      _showError(e.message ?? "Login failed");
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // ===========================================================
  // GOOGLE SIGN-IN (Android/iOS only — web uses renderButton below)
  // ===========================================================
  Future<void> _loginWithGoogle() async {
    if (!_googleSignInReady) {
      _showError("Google Sign-In is still starting up, try again in a moment");
      return;
    }
    setState(() => _isLoading = true);
    try {
      final googleUser = await GoogleAuthGate.instance.authenticate();
      await _handleGoogleUser(googleUser);
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) {
        // User cancelled the sign-in flow — no error needed
        if (mounted) setState(() => _isLoading = false);
      } else {
        _showError("Google sign-in failed: ${e.description ?? e.code}");
        if (mounted) setState(() => _isLoading = false);
      }
    } catch (e) {
      _showError("Something went wrong: $e");
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // ===========================================================
  // FACEBOOK SIGN-IN
  // ===========================================================
  Future<void> _loginWithFacebook() async {
    // The web SDK has to be loaded and given the app id before any of
    // this works; off the web this returns immediately.
    if (!FacebookAuthGate.isAvailable) {
      _showError("Facebook sign-in isn't set up for web yet — use email or Google here.");
      return;
    }
    setState(() => _isLoading = true);
    try {
      await FacebookAuthGate.instance.ensureInitialized();
      final result = await FacebookAuth.instance.login();

      if (result.status == LoginStatus.success) {
        final accessToken = result.accessToken!;

        final credential = FacebookAuthProvider.credential(
          accessToken.tokenString,
        );

        await FirebaseAuth.instance.signInWithCredential(credential);
        await completeSignIn();
        if (mounted) {
          Navigator.pushReplacementNamed(context, '/home');
        }
      } else if (result.status == LoginStatus.cancelled) {
        // User cancelled — no error needed
      } else {
        _showError(result.message ?? "Facebook sign-in failed");
      }
    } on FirebaseAuthException catch (e) {
      _showError(e.message ?? "Facebook sign-in failed");
    } catch (e) {
      _showError("Something went wrong: $e");
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // ===========================================================
  // ERROR HELPER
  // ===========================================================
  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color.fromARGB(255, 229, 231, 235),

      body: Column(
        children: [

          // GREEN HEADER
          Container(
            width: double.infinity,
            height: 250,

            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color(0xFF0F766E),
                  Color(0xFF34D399),
                ],
              ),
            ),

            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.center,

              children: [

                // LOGO
                Container(
                  width: 80,
                  height: 80,

                  // Solid white rather than a translucent overlay: the
                  // mark is teal, and teal-on-teal washes out against
                  // this header.
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                  ),

                  padding: const EdgeInsets.all(10),

                  child: Image.asset(
                    "assets/logo.png",
                  ),
                ),

                // HOMESYNC
                const Text(
                  "HOMESYNC",
                  style: TextStyle(
                    fontSize: 30,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF34D399),
                  ),
                ),

                const SizedBox(height: 6),

                // SUBTITLE
                const Text(
                  "Smart energy, smarter living.",
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
          ),

          // WHITE LOGIN CARD
          Expanded(
            child: Container(
              width: double.infinity,

              decoration: const BoxDecoration(
                color: Colors.white,

                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(30),
                  topRight: Radius.circular(30),
                ),
              ),

              child: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                    32,
                    20,
                    32,
                    20,
                  ),

                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,

                    children: [

                      // EMAIL
                      const Text(
                        "Email Address",
                        style: TextStyle(
                          fontSize: 16,
                          color: Color(0xFF4B5563),
                        ),
                      ),

                      const SizedBox(height: 8),

                      TextField(
                        controller: _emailController,
                        keyboardType: TextInputType.emailAddress,
                        decoration: InputDecoration(
                          hintText: "name@home.com",

                          filled: true,
                          fillColor: const Color(0xFFF9FAFB),

                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(20),
                            borderSide: BorderSide.none,
                          ),

                          contentPadding:
                              const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 18,
                          ),
                        ),
                      ),

                      const SizedBox(height: 30),

                      // PASSWORD
                      const Text(
                        "Password",
                        style: TextStyle(
                          fontSize: 16,
                          color: Color(0xFF4B5563),
                        ),
                      ),

                      const SizedBox(height: 8),

                      TextField(
                        controller: _passwordController,
                        obscureText: true,

                        decoration: InputDecoration(
                          hintText: "••••••••",

                          filled: true,
                          fillColor: const Color(0xFFF9FAFB),

                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(20),
                            borderSide: BorderSide.none,
                          ),

                          contentPadding:
                              const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 18,
                          ),
                        ),
                      ),

                      // FORGOT PASSWORD
                      Align(
                        alignment: Alignment.centerRight,

                        child: TextButton(
                          onPressed: _showForgotPasswordDialog,

                          child: const Text(
                            "Forgot Password?",
                            style: TextStyle(
                              color: Color(0xFF0F766E),
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),

                      const SizedBox(height: 10),

                      // LOGIN BUTTON
                      SizedBox(
                        width: double.infinity,
                        height: 54,

                        child: ElevatedButton(
                          onPressed: _isLoading ? null : _loginWithEmail,

                          style: ElevatedButton.styleFrom(
                            backgroundColor:
                                const Color(0xFF0F766E),

                            foregroundColor: Colors.white,

                            elevation: 5,

                            shape: RoundedRectangleBorder(
                              borderRadius:
                                  BorderRadius.circular(30),
                            ),
                          ),

                          child: _isLoading
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    color: Colors.white,
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Text(
                                  "Log In",

                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                        ),
                      ),

                      const SizedBox(height: 30),

                      // OR CONTINUE WITH
                      const Center(
                        child: Text(
                          "or continue with",

                          style: TextStyle(
                            color: Color(0xFF9CA3AF),
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),

                      const SizedBox(height: 25),

                      // GOOGLE + FACEBOOK
                      //
                      // Both buttons are pinned to the same 240x40 box.
                      // Google's rendered button maxes out at 400x40 and
                      // can't be told to fill a slot, so matching it means
                      // sizing ours to it rather than the other way round.
                      // Centred explicitly: the Wrap shrink-wraps to
                      // its children, and the form Column around it is
                      // start-aligned, so without this the pair sits
                      // flush left instead of under the Log In button.
                      Center(
                        child: Wrap(
                          alignment: WrapAlignment.center,
                          spacing: 14,
                          runSpacing: 12,
                          children: [

                            // GOOGLE
                            // Web requires Google's own rendered button (its
                            // SDK does not allow a custom button to trigger
                            // sign-in). Android/iOS keep the custom button.
                            SizedBox(
                              width: 240,
                              height: 40,
                              child: kIsWeb
                                  ? (GoogleAuthGate.instance.button != null
                                      ? Center(child: GoogleAuthGate.instance.button!)
                                      : const Center(
                                          child: SizedBox(
                                            width: 18,
                                            height: 18,
                                            child: CircularProgressIndicator(strokeWidth: 2),
                                          ),
                                        ))
                                  : OutlinedButton(
                                      onPressed: _isLoading ? null : _loginWithGoogle,
                                      style: OutlinedButton.styleFrom(
                                        foregroundColor: const Color(0xFF1F2937),
                                        side: const BorderSide(color: Color(0xFFE5E7EB)),
                                        padding: EdgeInsets.zero,
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(20),
                                        ),
                                      ),
                                      child: const Row(
                                        mainAxisAlignment: MainAxisAlignment.center,
                                        children: [
                                          Text(
                                            "G",
                                            style: TextStyle(
                                              color: Colors.red,
                                              fontSize: 17,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                          SizedBox(width: 8),
                                          Text("Google", style: TextStyle(fontSize: 14)),
                                        ],
                                      ),
                                    ),
                            ),

                            // FACEBOOK
                            SizedBox(
                              width: 240,
                              height: 40,
                              child: OutlinedButton(
                                onPressed: _isLoading ? null : _loginWithFacebook,
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: const Color(0xFF1F2937),
                                  side: const BorderSide(color: Color(0xFFE5E7EB)),
                                  padding: EdgeInsets.zero,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                ),
                                child: const Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(Icons.facebook, color: Colors.blue, size: 19),
                                    SizedBox(width: 8),
                                    Text("Facebook", style: TextStyle(fontSize: 14)),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 28),

                      // SIGN UP
                      Center(
                        child: RichText(
                          text: TextSpan(
                            text: "Don't have an account? ",
                            style: const TextStyle(
                              color: Color(0xFF6B7280),
                              fontSize: 14,
                            ),
                            children: [
                              TextSpan(
                                text: "Sign Up",
                                style: const TextStyle(
                                  color: Color(0xFF0F766E),
                                  fontSize: 14,
                                  fontWeight: FontWeight.bold,
                                ),
                                recognizer: TapGestureRecognizer()
                                  ..onTap = () {
                                    Navigator.pushNamed(context, '/signup');
                                  },
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// =====================================================================
// FORGOT-PASSWORD DIALOG
//
// Note what this deliberately does NOT do: tell you whether an account
// exists for the address you typed. Firebase's email enumeration
// protection (on by default) won't report it, and volunteering "no
// account with that email" to whoever is holding the phone hands out
// exactly the information that protection exists to withhold. A send
// and a miss look identical here.
// =====================================================================
class _ForgotPasswordDialog extends StatefulWidget {
  final String initialEmail;

  const _ForgotPasswordDialog({required this.initialEmail});

  @override
  State<_ForgotPasswordDialog> createState() => _ForgotPasswordDialogState();
}

class _ForgotPasswordDialogState extends State<_ForgotPasswordDialog> {
  late final TextEditingController _controller = TextEditingController(text: widget.initialEmail);

  bool _sending = false;
  bool _sent = false;
  String _sentTo = '';
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final email = _controller.text.trim();

    if (email.isEmpty || !RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email)) {
      setState(() => _error = "Enter a valid email address");
      return;
    }

    setState(() {
      _sending = true;
      _error = null;
    });

    try {
      await FirebaseAuth.instance.sendPasswordResetEmail(email: email);
      if (!mounted) return;
      setState(() {
        _sent = true;
        _sentTo = email;
        _sending = false;
      });
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;

      if (e.code == 'user-not-found') {
        // Shown as a success on purpose — see the note above the class.
        setState(() {
          _sent = true;
          _sentTo = email;
          _sending = false;
        });
        return;
      }

      setState(() {
        _sending = false;
        _error = switch (e.code) {
          'invalid-email' => "That email address doesn't look right.",
          'too-many-requests' => "Too many attempts. Wait a few minutes, then try again.",
          'network-request-failed' => "No connection. Check your internet and try again.",
          _ => e.message ?? "Couldn't send the reset email (${e.code}).",
        };
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _error = "Something went wrong: $e";
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      contentPadding: const EdgeInsets.fromLTRB(24, 26, 24, 12),
      content: _sent ? _sentContent() : _formContent(),
      actions: _sent
          ? [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text(
                  "Done",
                  style: TextStyle(color: Color(0xFF0F766E), fontWeight: FontWeight.bold),
                ),
              ),
            ]
          : [
              TextButton(
                onPressed: _sending ? null : () => Navigator.pop(context),
                child: const Text("Cancel", style: TextStyle(color: Color(0xFF64748B))),
              ),
              ElevatedButton(
                onPressed: _sending ? null : _send,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF0F766E),
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: const Color(0xFFCBD5E1),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                child: _sending
                    ? const SizedBox(
                        width: 17,
                        height: 17,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Text("Send Link"),
              ),
            ],
    );
  }

  Widget _formContent() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          "Reset your password",
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF1F2937)),
        ),
        const SizedBox(height: 8),
        const Text(
          "Tell us the email you sign in with and we'll send you a link to set a new password.",
          style: TextStyle(fontSize: 12.5, color: Color(0xFF64748B), height: 1.45),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _controller,
          autofocus: true,
          enabled: !_sending,
          keyboardType: TextInputType.emailAddress,
          onSubmitted: (_) => _sending ? null : _send(),
          decoration: InputDecoration(
            hintText: "name@example.com",
            hintStyle: const TextStyle(fontSize: 13, color: Color(0xFF94A3B8)),
            errorText: _error,
            filled: true,
            fillColor: const Color(0xFFF9FAFB),
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: Color(0xFF0F766E)),
            ),
          ),
        ),
      ],
    );
  }

  Widget _sentContent() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 60,
          height: 60,
          alignment: Alignment.center,
          decoration: const BoxDecoration(color: Color(0xFFE6F7F5), shape: BoxShape.circle),
          child: const Icon(Icons.mark_email_read_outlined, size: 28, color: Color(0xFF0F766E)),
        ),
        const SizedBox(height: 16),
        const Text(
          "Check your email",
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF1F2937)),
        ),
        const SizedBox(height: 10),
        Text(
          "If an account exists for $_sentTo, a link to set a new password is on its way. "
          "It can take a minute — and it's worth checking your spam folder.",
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 12.5, color: Color(0xFF64748B), height: 1.5),
        ),
      ],
    );
  }
}
