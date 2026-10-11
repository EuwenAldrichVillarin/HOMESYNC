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

class SignUpPage extends StatefulWidget {
  const SignUpPage({super.key});

  @override
  State<SignUpPage> createState() => _SignUpPageState();
}

class _SignUpPageState extends State<SignUpPage> {
  final _formKey = GlobalKey<FormState>();

  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();

  bool _obscurePassword = true;
  bool _obscureConfirm = true;
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
    _nameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  // Actual initialize() call lives in GoogleAuthGate, shared with LoginPage,
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

  Future<void> _handleGoogleUser(GoogleSignInAccount googleUser) async {
    setState(() => _isLoading = true);
    try {
      final googleAuth = googleUser.authentication;
      final credential = GoogleAuthProvider.credential(idToken: googleAuth.idToken);

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
  // EMAIL/PASSWORD SIGN UP
  // ===========================================================
  Future<void> _signUpWithEmail() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isLoading = true);
    try {
      final credential = await FirebaseAuth.instance.createUserWithEmailAndPassword(
        email: _emailController.text.trim(),
        password: _passwordController.text.trim(),
      );

      final user = credential.user;
      if (user != null) {
        await user.updateDisplayName(_nameController.text.trim());
        await user.reload();
      }

      // Records this account as a household admin and resolves the
      // session before Home starts reading from the database.
      await completeSignIn(name: _nameController.text.trim());

      if (mounted) {
        Navigator.pushReplacementNamed(context, '/home');
      }
    } on FirebaseAuthException catch (e) {
      _showError(e.message ?? "Sign up failed");
    } catch (e) {
      _showError("Something went wrong: $e");
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // ===========================================================
  // GOOGLE SIGN-IN (Android/iOS only — web uses renderButton below)
  // ===========================================================
  Future<void> _signUpWithGoogle() async {
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
  Future<void> _signUpWithFacebook() async {
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
        final credential = FacebookAuthProvider.credential(accessToken.tokenString);

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

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  InputDecoration _fieldDecoration(String hint, {Widget? suffixIcon}) {
    return InputDecoration(
      hintText: hint,
      filled: true,
      fillColor: const Color(0xFFF9FAFB),
      suffixIcon: suffixIcon,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(20),
        borderSide: BorderSide.none,
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
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
            height: 200,
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF0F766E), Color(0xFF34D399)],
              ),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  width: 70,
                  height: 70,
                  // Solid white: the mark is teal and would otherwise sit
                  // teal-on-teal against this header.
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  padding: const EdgeInsets.all(9),
                  child: Image.asset("assets/logo.png"),
                ),
                const SizedBox(height: 6),
                const Text(
                  "HOMESYNC",
                  style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold, color: Color(0xFF34D399)),
                ),
                const SizedBox(height: 4),
                const Text(
                  "Smart energy, smarter living.",
                  style: TextStyle(fontSize: 13, color: Colors.white),
                ),
              ],
            ),
          ),

          // WHITE SIGN UP CARD
          Expanded(
            child: Container(
              width: double.infinity,
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.only(topLeft: Radius.circular(30), topRight: Radius.circular(30)),
              ),
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(32, 24, 32, 20),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [

                      const Text(
                        "Create Account",
                        style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Color(0xFF1F2937)),
                      ),

                      const SizedBox(height: 22),

                      // FULL NAME
                      const Text("Full Name", style: TextStyle(fontSize: 16, color: Color(0xFF4B5563))),
                      const SizedBox(height: 8),
                      TextFormField(
                        controller: _nameController,
                        textCapitalization: TextCapitalization.words,
                        decoration: _fieldDecoration("Your Name"),
                        validator: (value) {
                          if (value == null || value.trim().isEmpty) return "Enter your name";
                          return null;
                        },
                      ),

                      const SizedBox(height: 22),

                      // EMAIL
                      const Text("Email Address", style: TextStyle(fontSize: 16, color: Color(0xFF4B5563))),
                      const SizedBox(height: 8),
                      TextFormField(
                        controller: _emailController,
                        keyboardType: TextInputType.emailAddress,
                        decoration: _fieldDecoration("name@home.com"),
                        validator: (value) {
                          final email = value?.trim() ?? "";
                          if (email.isEmpty) return "Enter your email address";
                          final valid = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email);
                          if (!valid) return "Enter a valid email address";
                          return null;
                        },
                      ),

                      const SizedBox(height: 22),

                      // PASSWORD
                      const Text("Password", style: TextStyle(fontSize: 16, color: Color(0xFF4B5563))),
                      const SizedBox(height: 8),
                      TextFormField(
                        controller: _passwordController,
                        obscureText: _obscurePassword,
                        decoration: _fieldDecoration(
                          "••••••••",
                          suffixIcon: IconButton(
                            icon: Icon(
                              _obscurePassword ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                              color: const Color(0xFF9CA3AF),
                            ),
                            onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                          ),
                        ),
                        validator: (value) {
                          if (value == null || value.length < 6) return "Password must be at least 6 characters";
                          return null;
                        },
                      ),

                      const SizedBox(height: 22),

                      // CONFIRM PASSWORD
                      const Text("Confirm Password", style: TextStyle(fontSize: 16, color: Color(0xFF4B5563))),
                      const SizedBox(height: 8),
                      TextFormField(
                        controller: _confirmController,
                        obscureText: _obscureConfirm,
                        decoration: _fieldDecoration(
                          "••••••••",
                          suffixIcon: IconButton(
                            icon: Icon(
                              _obscureConfirm ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                              color: const Color(0xFF9CA3AF),
                            ),
                            onPressed: () => setState(() => _obscureConfirm = !_obscureConfirm),
                          ),
                        ),
                        validator: (value) {
                          if (value != _passwordController.text) return "Passwords don't match";
                          return null;
                        },
                      ),

                      const SizedBox(height: 26),

                      // SIGN UP BUTTON
                      SizedBox(
                        width: double.infinity,
                        height: 54,
                        child: ElevatedButton(
                          onPressed: _isLoading ? null : _signUpWithEmail,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF0F766E),
                            foregroundColor: Colors.white,
                            elevation: 5,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
                          ),
                          child: _isLoading
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                                )
                              : const Text("Sign Up", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                        ),
                      ),

                      const SizedBox(height: 26),

                      // OR CONTINUE WITH
                      Row(
                        children: [
                          const Expanded(child: Divider(color: Color(0xFFE5E7EB))),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            child: Text(
                              "OR CONTINUE WITH",
                              style: TextStyle(
                                color: const Color(0xFF9CA3AF),
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                letterSpacing: 0.5,
                              ),
                            ),
                          ),
                          const Expanded(child: Divider(color: Color(0xFFE5E7EB))),
                        ],
                      ),

                      const SizedBox(height: 22),

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
                                      onPressed: _isLoading ? null : _signUpWithGoogle,
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
                                onPressed: _isLoading ? null : _signUpWithFacebook,
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

                      const SizedBox(height: 26),

                      // LOG IN
                      Center(
                        child: RichText(
                          text: TextSpan(
                            text: "Already have an account? ",
                            style: const TextStyle(color: Color(0xFF6B7280), fontSize: 14),
                            children: [
                              TextSpan(
                                text: "Log In",
                                style: const TextStyle(
                                  color: Color(0xFF0F766E),
                                  fontSize: 14,
                                  fontWeight: FontWeight.bold,
                                ),
                                recognizer: TapGestureRecognizer()
                                  ..onTap = () {
                                    if (Navigator.canPop(context)) {
                                      Navigator.pop(context);
                                    } else {
                                      Navigator.pushReplacementNamed(context, '/login');
                                    }
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
