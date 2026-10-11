import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'household.dart';

class LogoutPage extends StatelessWidget {
  const LogoutPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,

      body: SafeArea(
        child: Stack(
          children: [

            // =====================================================
            // LOGOUT CONTENT
            // =====================================================
            Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 40,
                ),

                child: Container(
                  width: double.infinity,

                  padding: const EdgeInsets.fromLTRB(
                    28,
                    40,
                    28,
                    32,
                  ),

                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(28),

                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.25),
                        blurRadius: 30,
                        offset: const Offset(0, 15),
                      ),
                    ],
                  ),

                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [

                      // =================================================
                      // LOGOUT ICON
                      // =================================================
                      Container(
                        width: 80,
                        height: 80,

                        decoration: const BoxDecoration(
                          color: Color(0xFFE8F8F6),
                          shape: BoxShape.circle,
                        ),

                        child: const Icon(
                          Icons.arrow_forward,
                          size: 48,
                          color: Color(0xFF0F766E),
                        ),
                      ),

                      const SizedBox(height: 70),

                      // =================================================
                      // TITLE
                      // =================================================
                      const Text(
                        "Log Out?",
                        textAlign: TextAlign.center,

                        style: TextStyle(
                          fontSize: 38,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF1E293B),
                          letterSpacing: -1,
                        ),
                      ),

                      const SizedBox(height: 24),

                      // =================================================
                      // DESCRIPTION
                      // =================================================
                      const Text(
                        "Are you sure you want to log out\nof your account?",
                        textAlign: TextAlign.center,

                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w500,
                          color: Color(0xFF94A3B8),
                          height: 1.5,
                        ),
                      ),

                      const SizedBox(height: 70),

                      // =================================================
                      // YES, LOG OUT BUTTON
                      // =================================================
                      SizedBox(
                        width: double.infinity,
                        height: 64,

                        child: ElevatedButton(
                          onPressed: () async {
                            // Actually end the Firebase session, not just
                            // navigate away — otherwise the account stays
                            // signed in, which matters now that a household
                            // can have several accounts on one device.
                            HouseholdSession.clear();
                            await FirebaseAuth.instance.signOut();
                            if (!context.mounted) return;
                            Navigator.pushReplacementNamed(
                              context,
                              '/login',
                            );
                          },

                          style: ElevatedButton.styleFrom(
                            backgroundColor:
                                const Color(0xFF0F766E),

                            foregroundColor: Colors.white,

                            elevation: 8,

                            shadowColor:
                                const Color(0x330F766E),

                            shape: RoundedRectangleBorder(
                              borderRadius:
                                  BorderRadius.circular(40),
                            ),
                          ),

                          child: const Text(
                            "Yes, Log Out",
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),

                      const SizedBox(height: 20),

                      // =================================================
                      // CANCEL BUTTON
                      // =================================================
                      SizedBox(
                        width: double.infinity,
                        height: 64,

                        child: OutlinedButton(
                          onPressed: () {
                            // Return to Home Page
                            Navigator.pushReplacementNamed(
                              context,
                              '/home',
                            );
                          },

                          style: OutlinedButton.styleFrom(
                            foregroundColor:
                                const Color(0xFF0F766E),

                            side: const BorderSide(
                              color: Color(0xFFDDE5ED),
                              width: 3,
                            ),

                            shape: RoundedRectangleBorder(
                              borderRadius:
                                  BorderRadius.circular(40),
                            ),
                          ),

                          child: const Text(
                            "Cancel",
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF0F766E),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            // =====================================================
            // FOOTER
            // =====================================================
            Positioned(
              left: 40,
              right: 40,
              bottom: 30,

              child: const Text(
                "Your energy dashboard is always here\nwhen you return.",
                textAlign: TextAlign.center,

                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                  color: Color(0xFF94A3B8),
                  height: 1.5,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}