import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';

import 'firebase_options.dart';
import 'household.dart';
import 'activity.dart';
import 'profile.dart';

// =====================================================================
// HOUSEHOLD MEMBERS (admin only)
//
// Lets the admin create limited accounts for the people living in the
// house, adjust what each one can do, and remove them again.
//
// Members don't claim devices of their own: every page resolves its
// appliance list from HouseholdSession.householdUid, which for a member
// points at the admin's uid. So whatever the admin has registered — now
// or later — a member sees without any copying or syncing.
// =====================================================================

const Color _kTeal = Color(0xFF0F766E);
const Color _kInk = Color(0xFF1F2937);
const Color _kMuted = Color(0xFF64748B);
const Color _kFaint = Color(0xFF94A3B8);
const Color _kLine = Color(0xFFE2E8F0);

class HouseholdMember {
  final String uid;
  final String name;
  final String email;
  final MemberPermissions permissions;

  const HouseholdMember({
    required this.uid,
    required this.name,
    required this.email,
    required this.permissions,
  });
}

// =====================================================================
// MEMBER ACCOUNT CREATION
//
// FirebaseAuth.createUserWithEmailAndPassword() signs in whoever it just
// created, which on the default app instance would kick the admin out
// mid-task. So the new account is created on a SECOND, throwaway Firebase
// app: the admin's session on the default instance is never touched.
//
// While still signed in as the new member on that second instance we
// write their own users/{uid} node — that's the only moment anyone can
// write it, since the rules only allow a user to write their own node.
// The admin then records the membership under their own node, which is
// the copy that actually grants access.
// =====================================================================
class MemberCreationException implements Exception {
  final String message;
  MemberCreationException(this.message);
  @override
  String toString() => message;
}

const String _kMemberAppName = 'memberCreator';

Future<FirebaseApp> _memberCreatorApp() async {
  try {
    // Re-used across calls: initializeApp() with a name that already
    // exists throws, and deleting/recreating it per member is needless.
    return Firebase.app(_kMemberAppName);
  } catch (_) {
    return Firebase.initializeApp(
      name: _kMemberAppName,
      options: DefaultFirebaseOptions.currentPlatform,
    );
  }
}

Future<String> createHouseholdMember({
  required String adminUid,
  required String name,
  required String email,
  required String password,
  required MemberPermissions permissions,
}) async {
  final app = await _memberCreatorApp();
  final auth = FirebaseAuth.instanceFor(app: app);

  UserCredential credential;
  try {
    credential = await auth.createUserWithEmailAndPassword(email: email, password: password);
  } on FirebaseAuthException catch (e) {
    throw MemberCreationException(switch (e.code) {
      'email-already-in-use' => "That email already has an account. Use a different one.",
      'invalid-email' => "That email address doesn't look right.",
      'weak-password' => "Password is too weak — use at least 6 characters.",
      'operation-not-allowed' => "Email/password accounts are disabled for this project.",
      _ => e.message ?? "Couldn't create the account (${e.code}).",
    });
  }

  final memberUid = credential.user?.uid;
  if (memberUid == null) {
    throw MemberCreationException("Couldn't create the account — no user was returned.");
  }

  try {
    await credential.user!.updateDisplayName(name);

    // Written as the member, because rules allow a user to write only
    // their own node. householdAdminUid is just a pointer back to the
    // admin; it grants nothing on its own.
    await FirebaseDatabase.instanceFor(app: app).ref('users/$memberUid').update({
      'householdAdminUid': adminUid,
      'profile': {
        'name': name,
        'email': email,
        'role': 'member',
      },
    });
  } finally {
    // Always release the second instance's session, even if the writes
    // failed, so a later "Add Member" doesn't start signed in as someone.
    await auth.signOut();
  }

  // The record that actually grants access. Only the admin can write it,
  // and removing it is what revokes a member.
  await FirebaseDatabase.instance.ref('users/$adminUid/members/$memberUid').set({
    'name': name,
    'email': email,
    'createdAt': ServerValue.timestamp,
    'permissions': permissions.toMap(),
  });

  logActivity(
    action: ActivityAction.memberAdded,
    target: name,
    detail: permissions.summary,
  );

  return memberUid;
}

// =====================================================================
// MEMBERS PAGE
// =====================================================================
class MembersPage extends StatefulWidget {
  const MembersPage({super.key});

  @override
  State<MembersPage> createState() => _MembersPageState();
}

class _MembersPageState extends State<MembersPage> {
  HouseholdSession? _session;
  StreamSubscription<DatabaseEvent>? _membersSub;
  List<HouseholdMember> _members = [];
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    HouseholdSession.ensureLoaded().then((session) {
      if (!mounted) return;
      setState(() => _session = session);
      if (session.canManageMembers) {
        _listenToMembers(session.uid);
      } else {
        setState(() => _loaded = true);
      }
    }).catchError((Object _) {
      if (mounted) setState(() => _loaded = true);
    });
  }

  void _listenToMembers(String adminUid) {
    final ref = FirebaseDatabase.instance.ref('users/$adminUid/members');
    _membersSub = ref.onValue.listen((event) {
      final raw = event.snapshot.value;
      final list = <HouseholdMember>[];
      if (raw is Map) {
        raw.forEach((key, value) {
          if (value is! Map) return;
          list.add(HouseholdMember(
            uid: key.toString(),
            name: (value['name'] as String?)?.trim().isNotEmpty == true
                ? (value['name'] as String).trim()
                : 'Member',
            email: (value['email'] as String?) ?? '',
            permissions: MemberPermissions.fromMap(value['permissions']),
          ));
        });
      }
      list.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      setState(() {
        _members = list;
        _loaded = true;
      });
    }, onError: (Object _) {
      if (mounted) setState(() => _loaded = true);
    });
  }

  @override
  void dispose() {
    _membersSub?.cancel();
    super.dispose();
  }

  void _notify(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _openAddMember() async {
    final session = _session;
    if (session == null) return;

    final created = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => AddMemberPage(adminUid: session.uid)),
    );
    if (created != null && mounted) {
      _notify("Member account created");
    }
  }

  Future<void> _editPermissions(HouseholdMember member) async {
    final session = _session;
    if (session == null) return;

    final updated = await showModalBottomSheet<MemberPermissions>(
      context: context,
      backgroundColor: Colors.white,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (sheetContext) => _PermissionsSheet(member: member),
    );

    if (updated == null) return;

    try {
      await FirebaseDatabase.instance
          .ref('users/${session.uid}/members/${member.uid}/permissions')
          .set(updated.toMap());
      logActivity(
        action: ActivityAction.memberPermissions,
        target: member.name,
        detail: updated.summary,
      );
      _notify("Access updated for ${member.name}");
    } catch (e) {
      _notify("Couldn't update access: $e");
    }
  }

  /// Mails the member a reset link. The admin set their first password,
  /// so the admin is who gets asked when it's forgotten — this saves a
  /// round trip through the login page.
  ///
  /// Safe to call while signed in as the admin: sending a reset email
  /// doesn't touch the current session.
  Future<void> _sendPasswordReset(HouseholdMember member) async {
    final email = member.email.trim();
    if (email.isEmpty) {
      _notify("No email on record for ${member.name}");
      return;
    }
    try {
      await FirebaseAuth.instance.sendPasswordResetEmail(email: email);
      _notify("Password reset link sent to $email");
    } on FirebaseAuthException catch (e) {
      _notify(e.code == 'too-many-requests'
          ? "Too many attempts. Wait a few minutes, then try again."
          : (e.message ?? "Couldn't send the reset email."));
    } catch (e) {
      _notify("Couldn't send the reset email: $e");
    }
  }

  Future<void> _removeMember(HouseholdMember member) async {
    final session = _session;
    if (session == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text(
          "Remove member?",
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: _kInk),
        ),
        content: Text(
          "${member.name} will immediately lose access to your appliances. "
          "Their login still exists, but it won't be able to see or control anything.",
          style: const TextStyle(fontSize: 13, color: _kMuted, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text("Cancel", style: TextStyle(color: _kMuted)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFDC2626),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text("Remove"),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      // Removing the admin's record is what cuts access off — the rules
      // check for it on every read and every relay command. The member's
      // Firebase Auth login can't be deleted from here (only the Admin
      // SDK or the member themselves can do that), so it's left in place.
      await FirebaseDatabase.instance.ref('users/${session.uid}/members/${member.uid}').remove();
      logActivity(action: ActivityAction.memberRemoved, target: member.name);
      _notify("${member.name} removed");
    } catch (e) {
      _notify("Couldn't remove member: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      body: SafeArea(
        child: Column(
          children: [
            // =========================================================
            // HEADER
            // =========================================================
            Container(
              width: double.infinity,
              color: Colors.white,
              padding: const EdgeInsets.fromLTRB(8, 10, 20, 14),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.arrow_back, color: _kInk),
                  ),
                  const Expanded(
                    child: Text(
                      "Household Members",
                      style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold, color: _kInk),
                    ),
                  ),
                  if (session != null && session.canManageMembers)
                    InkWell(
                      borderRadius: BorderRadius.circular(20),
                      onTap: _openAddMember,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                        decoration: BoxDecoration(
                          color: _kTeal,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: const Row(
                          children: [
                            Icon(Icons.person_add_alt, size: 15, color: Colors.white),
                            SizedBox(width: 5),
                            Text(
                              "Add",
                              style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),

            Expanded(child: _body(session)),
          ],
        ),
      ),
    );
  }

  Widget _body(HouseholdSession? session) {
    if (!_loaded || session == null) {
      return const Center(child: CircularProgressIndicator());
    }

    if (!session.canManageMembers) {
      return const AccessNotice(
        icon: Icons.lock_outline,
        title: "Admins only",
        message: "Only the household admin can add or manage member accounts.",
      );
    }

    if (_members.isEmpty) {
      return AccessNotice(
        icon: Icons.group_outlined,
        title: "No members yet",
        message: "Create an account for someone in your household. They'll see all of your "
            "registered appliances, with only the access you give them.",
        action: ElevatedButton(
          onPressed: _openAddMember,
          style: ElevatedButton.styleFrom(
            backgroundColor: _kTeal,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          ),
          child: const Text("Add Member", style: TextStyle(fontWeight: FontWeight.bold)),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      itemCount: _members.length + 1,
      separatorBuilder: (_, _) => const SizedBox(height: 11),
      itemBuilder: (context, index) {
        if (index == _members.length) {
          return Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              "Members automatically see every appliance registered under your "
              "account. Only you can add, rename, or remove appliances and change "
              "the electricity rate.",
              style: const TextStyle(fontSize: 11, color: _kFaint, height: 1.5),
            ),
          );
        }
        return _memberCard(_members[index]);
      },
    );
  }

  Widget _memberCard(HouseholdMember member) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 13, 8, 13),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _kLine),
        boxShadow: const [BoxShadow(color: Color(0x08000000), blurRadius: 4, offset: Offset(0, 2))],
      ),
      child: Row(
        children: [
          // Reads the member's own profile, so a picture or name they
          // set for themselves shows up here. The record stored on this
          // admin's node is the fallback if that read isn't permitted.
          LiveProfileAvatar(
            uid: member.uid,
            fallbackName: member.name,
            size: 42,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  member.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: _kInk),
                ),
                const SizedBox(height: 2),
                Text(
                  member.email,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11, color: _kFaint),
                ),
                const SizedBox(height: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF1F5F9),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    member.permissions.summary,
                    style: const TextStyle(fontSize: 9, fontWeight: FontWeight.w600, color: _kMuted),
                  ),
                ),
              ],
            ),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, size: 20, color: _kFaint),
            color: Colors.white,
            onSelected: (value) {
              if (value == 'permissions') _editPermissions(member);
              if (value == 'reset') _sendPasswordReset(member);
              if (value == 'remove') _removeMember(member);
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'permissions',
                child: Text("Edit access", style: TextStyle(fontSize: 13, color: _kInk)),
              ),
              PopupMenuItem(
                value: 'reset',
                child: Text("Send password reset", style: TextStyle(fontSize: 13, color: _kInk)),
              ),
              PopupMenuItem(
                value: 'remove',
                child: Text("Remove member", style: TextStyle(fontSize: 13, color: Color(0xFFDC2626))),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// =====================================================================
// ADD MEMBER
// =====================================================================
class AddMemberPage extends StatefulWidget {
  final String adminUid;

  const AddMemberPage({super.key, required this.adminUid});

  @override
  State<AddMemberPage> createState() => _AddMemberPageState();
}

class _AddMemberPageState extends State<AddMemberPage> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();

  bool _obscurePassword = true;
  bool _obscureConfirm = true;
  bool _isSaving = false;
  MemberPermissions _permissions = MemberPermissions.defaults;

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _handleSave() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isSaving = true);
    try {
      final memberUid = await createHouseholdMember(
        adminUid: widget.adminUid,
        name: _nameController.text.trim(),
        email: _emailController.text.trim(),
        password: _passwordController.text,
        permissions: _permissions,
      );
      if (!mounted) return;
      Navigator.pop(context, memberUid);
    } on MemberCreationException catch (e) {
      _showError(e.message);
    } catch (e) {
      _showError("Something went wrong: $e");
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  InputDecoration _fieldDecoration(String hint, {Widget? suffix}) {
    return InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(fontSize: 13, color: _kFaint),
      filled: true,
      fillColor: const Color(0xFFF8FAFC),
      suffixIcon: suffix,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: _kLine),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: _kLine),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: _kTeal),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      body: SafeArea(
        child: Column(
          children: [
            // HEADER
            Container(
              width: double.infinity,
              color: Colors.white,
              padding: const EdgeInsets.fromLTRB(8, 10, 20, 14),
              child: Row(
                children: [
                  IconButton(
                    onPressed: _isSaving ? null : () => Navigator.pop(context),
                    icon: const Icon(Icons.arrow_back, color: _kInk),
                  ),
                  const Text(
                    "Add Member",
                    style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold, color: _kInk),
                  ),
                ],
              ),
            ),

            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        "You're creating the login for them, so pick a password you can "
                        "pass along. They can change it later from the login page.",
                        style: TextStyle(fontSize: 12, color: _kMuted, height: 1.45),
                      ),
                      const SizedBox(height: 22),

                      _label("Full name"),
                      TextFormField(
                        controller: _nameController,
                        textCapitalization: TextCapitalization.words,
                        decoration: _fieldDecoration("e.g. Maria Santos"),
                        validator: (value) =>
                            (value == null || value.trim().isEmpty) ? "Enter their name" : null,
                      ),
                      const SizedBox(height: 16),

                      _label("Email"),
                      TextFormField(
                        controller: _emailController,
                        keyboardType: TextInputType.emailAddress,
                        decoration: _fieldDecoration("name@example.com"),
                        validator: (value) {
                          final text = (value ?? '').trim();
                          if (text.isEmpty) return "Enter an email address";
                          if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(text)) {
                            return "That email doesn't look right";
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 16),

                      _label("Password"),
                      TextFormField(
                        controller: _passwordController,
                        obscureText: _obscurePassword,
                        decoration: _fieldDecoration(
                          "At least 6 characters",
                          suffix: IconButton(
                            icon: Icon(
                              _obscurePassword ? Icons.visibility_off : Icons.visibility,
                              size: 19,
                              color: _kFaint,
                            ),
                            onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                          ),
                        ),
                        validator: (value) {
                          if (value == null || value.isEmpty) return "Enter a password";
                          if (value.length < 6) return "Use at least 6 characters";
                          return null;
                        },
                      ),
                      const SizedBox(height: 16),

                      _label("Confirm password"),
                      TextFormField(
                        controller: _confirmController,
                        obscureText: _obscureConfirm,
                        decoration: _fieldDecoration(
                          "Re-enter the password",
                          suffix: IconButton(
                            icon: Icon(
                              _obscureConfirm ? Icons.visibility_off : Icons.visibility,
                              size: 19,
                              color: _kFaint,
                            ),
                            onPressed: () => setState(() => _obscureConfirm = !_obscureConfirm),
                          ),
                        ),
                        validator: (value) =>
                            value != _passwordController.text ? "Passwords don't match" : null,
                      ),

                      const SizedBox(height: 26),
                      _label("What they can do"),
                      const SizedBox(height: 2),
                      Container(
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: _kLine),
                        ),
                        child: Column(
                          children: [
                            _PermissionToggle(
                              icon: Icons.power_settings_new,
                              title: "Control appliances",
                              subtitle: "Turn your appliances on and off",
                              value: _permissions.control,
                              onChanged: (v) => setState(
                                () => _permissions = _permissions.copyWith(control: v),
                              ),
                            ),
                            const Divider(height: 1, color: Color(0xFFF1F5F9)),
                            _PermissionToggle(
                              icon: Icons.access_time,
                              title: "Edit schedules",
                              subtitle: "Change when appliances switch on and off",
                              value: _permissions.schedule,
                              onChanged: (v) => setState(
                                () => _permissions = _permissions.copyWith(schedule: v),
                              ),
                            ),
                            const Divider(height: 1, color: Color(0xFFF1F5F9)),
                            _PermissionToggle(
                              icon: Icons.show_chart,
                              title: "View reports",
                              subtitle: "See usage history and cost breakdowns",
                              value: _permissions.reports,
                              onChanged: (v) => setState(
                                () => _permissions = _permissions.copyWith(reports: v),
                              ),
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 10),
                      const Text(
                        "Adding appliances, renaming them, changing the electricity rate, "
                        "and managing members stay admin-only.",
                        style: TextStyle(fontSize: 11, color: _kFaint, height: 1.45),
                      ),

                      const SizedBox(height: 26),
                      SizedBox(
                        width: double.infinity,
                        height: 50,
                        child: ElevatedButton(
                          onPressed: _isSaving ? null : _handleSave,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _kTeal,
                            foregroundColor: Colors.white,
                            disabledBackgroundColor: const Color(0xFF94A3B8),
                            elevation: 0,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                          child: _isSaving
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                )
                              : const Text(
                                  "Create Member Account",
                                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                                ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static Widget _label(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Text(
        text,
        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: _kInk),
      ),
    );
  }
}

// =====================================================================
// EDIT-ACCESS SHEET
// =====================================================================
class _PermissionsSheet extends StatefulWidget {
  final HouseholdMember member;

  const _PermissionsSheet({required this.member});

  @override
  State<_PermissionsSheet> createState() => _PermissionsSheetState();
}

class _PermissionsSheetState extends State<_PermissionsSheet> {
  late MemberPermissions _permissions = widget.member.permissions;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 38,
                height: 4,
                decoration: BoxDecoration(
                  color: const Color(0xFFE2E8F0),
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              widget.member.name,
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: _kInk),
            ),
            const SizedBox(height: 3),
            Text(
              widget.member.email,
              style: const TextStyle(fontSize: 11, color: _kFaint),
            ),
            const SizedBox(height: 18),
            _PermissionToggle(
              icon: Icons.power_settings_new,
              title: "Control appliances",
              subtitle: "Turn your appliances on and off",
              value: _permissions.control,
              onChanged: (v) => setState(() => _permissions = _permissions.copyWith(control: v)),
            ),
            const Divider(height: 1, color: Color(0xFFF1F5F9)),
            _PermissionToggle(
              icon: Icons.access_time,
              title: "Edit schedules",
              subtitle: "Change when appliances switch on and off",
              value: _permissions.schedule,
              onChanged: (v) => setState(() => _permissions = _permissions.copyWith(schedule: v)),
            ),
            const Divider(height: 1, color: Color(0xFFF1F5F9)),
            _PermissionToggle(
              icon: Icons.show_chart,
              title: "View reports",
              subtitle: "See usage history and cost breakdowns",
              value: _permissions.reports,
              onChanged: (v) => setState(() => _permissions = _permissions.copyWith(reports: v)),
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton(
                onPressed: () => Navigator.pop(context, _permissions),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _kTeal,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: const Text("Save Access", style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PermissionToggle extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _PermissionToggle({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      value: value,
      onChanged: onChanged,
      activeThumbColor: Colors.white,
      activeTrackColor: _kTeal,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
      secondary: Container(
        width: 34,
        height: 34,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: const Color(0xFFF1F5F9),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon, size: 17, color: _kTeal),
      ),
      title: Text(
        title,
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _kInk),
      ),
      subtitle: Text(
        subtitle,
        style: const TextStyle(fontSize: 10.5, color: _kFaint),
      ),
    );
  }
}

// =====================================================================
// SHARED EMPTY / BLOCKED STATE
// =====================================================================
class AccessNotice extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;
  final Widget? action;

  const AccessNotice({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 46, color: const Color(0xFFCBD5E1)),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: _kInk),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12.5, color: _kFaint, height: 1.5),
            ),
            if (action != null) ...[
              const SizedBox(height: 20),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

// =====================================================================
// REVOKED ACCESS
//
// Shown when an account is still a valid login but the admin has taken
// it out of their member list. Better to say so plainly than to show an
// empty house and let them think the appliances disappeared.
// =====================================================================
class RevokedAccessScreen extends StatelessWidget {
  const RevokedAccessScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      body: SafeArea(
        child: AccessNotice(
          icon: Icons.no_accounts,
          title: "No household access",
          message: "The admin of this household removed your access. Ask them to "
              "add you again, or log out and use a different account.",
          action: OutlinedButton(
            onPressed: () async {
              HouseholdSession.clear();
              await FirebaseAuth.instance.signOut();
              if (!context.mounted) return;
              Navigator.pushReplacementNamed(context, '/login');
            },
            style: OutlinedButton.styleFrom(
              foregroundColor: _kTeal,
              side: const BorderSide(color: _kTeal),
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
            ),
            child: const Text("Log Out", style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ),
      ),
    );
  }
}
