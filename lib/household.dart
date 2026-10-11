import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';

// =====================================================================
// HOUSEHOLD ROLES & PERMISSIONS
//
// The account that signs up through /signup is the household ADMIN. An
// admin can create limited MEMBER accounts from the Members page; those
// members share the admin's appliances instead of owning any themselves.
//
// Source of truth for membership is users/{adminUid}/members/{memberUid},
// which only the admin can write. A member's own node carries just a
// pointer (householdAdminUid) — so a member editing their own record
// can't grant themselves permissions or claim someone else's household.
// =====================================================================

enum HouseholdRole {
  admin,

  /// Signed in, linked to an admin, and still listed by that admin.
  member,

  /// Was a member, but the admin removed them (or the link is dangling).
  /// Kept as a distinct state so the UI can say so instead of silently
  /// showing an empty house.
  revoked,
}

class MemberPermissions {
  /// Turn appliances on/off from Home and Appliances.
  final bool control;

  /// Create and change appliance schedules.
  final bool schedule;

  /// Open the Report page.
  final bool reports;

  const MemberPermissions({
    required this.control,
    required this.schedule,
    required this.reports,
  });

  /// What an admin always has — lets permission checks be written once
  /// and work for both roles.
  static const all = MemberPermissions(control: true, schedule: true, reports: true);

  /// Pre-ticked boxes on the "Add Member" form.
  static const defaults = MemberPermissions(control: true, schedule: false, reports: true);

  static const none = MemberPermissions(control: false, schedule: false, reports: false);

  factory MemberPermissions.fromMap(Object? raw) {
    if (raw is! Map) return MemberPermissions.none;
    return MemberPermissions(
      control: raw['control'] == true,
      schedule: raw['schedule'] == true,
      reports: raw['reports'] == true,
    );
  }

  Map<String, Object?> toMap() => {
        'control': control,
        'schedule': schedule,
        'reports': reports,
      };

  MemberPermissions copyWith({bool? control, bool? schedule, bool? reports}) {
    return MemberPermissions(
      control: control ?? this.control,
      schedule: schedule ?? this.schedule,
      reports: reports ?? this.reports,
    );
  }

  /// Short human summary for the member list, e.g. "Control, Reports".
  String get summary {
    final granted = <String>[
      if (control) "Control",
      if (schedule) "Schedules",
      if (reports) "Reports",
    ];
    return granted.isEmpty ? "View only" : granted.join(", ");
  }
}

/// Who is signed in, whose appliances they see, and what they may do.
class HouseholdSession {
  final String uid;
  final HouseholdRole role;

  /// The uid whose appliance index and electricity rate this session
  /// reads. For an admin that's their own uid; for a member it's the
  /// admin's, which is what makes the admin's appliances show up for
  /// every member automatically.
  final String householdUid;

  final MemberPermissions permissions;

  /// Admin's display name — shown to members so they know whose home
  /// they are looking at.
  final String? householdName;

  const HouseholdSession({
    required this.uid,
    required this.role,
    required this.householdUid,
    required this.permissions,
    this.householdName,
  });

  bool get isAdmin => role == HouseholdRole.admin;
  bool get isMember => role == HouseholdRole.member;
  bool get isRevoked => role == HouseholdRole.revoked;

  // Admin-only capabilities.
  bool get canManageMembers => isAdmin;
  bool get canManageAppliances => isAdmin; // add / edit / claim devices
  bool get canEditRate => isAdmin;

  // Shared capabilities, gated per member.
  bool get canControl => permissions.control;
  bool get canEditSchedules => permissions.schedule;
  bool get canViewReports => permissions.reports;

  // -------------------------------------------------------------------
  // LOADING
  //
  // Resolved once per sign-in and cached, since every page needs it
  // before it can subscribe to the right appliance index. Call reload()
  // after anything that changes this session's own membership.
  // -------------------------------------------------------------------
  static HouseholdSession? _cached;
  static DateTime? _cachedAt;

  static HouseholdSession? get current => _cached;

  static Future<HouseholdSession>? _inFlight;

  /// How long a member's resolved permissions are trusted before being
  /// re-read. An admin changing what a member may do (or removing them)
  /// takes effect on the database immediately, but the member's already
  /// running app would otherwise keep its old answer forever — so a
  /// member session goes stale and is re-resolved on the next page it
  /// opens. An admin's session never needs this: it's derived from their
  /// own uid and can't be changed by anyone else.
  static const Duration _memberCacheTtl = Duration(seconds: 30);

  static bool get _cacheIsFresh {
    final cached = _cached;
    if (cached == null) return false;
    if (cached.uid != FirebaseAuth.instance.currentUser?.uid) return false;
    if (cached.isAdmin) return true;
    final at = _cachedAt;
    return at != null && DateTime.now().difference(at) < _memberCacheTtl;
  }

  static Future<HouseholdSession> ensureLoaded() {
    if (_cacheIsFresh) return Future.value(_cached!);
    // Several pages can ask at the same moment on first load; share one
    // round trip rather than racing duplicate reads.
    return _inFlight ??= _resolve().whenComplete(() => _inFlight = null);
  }

  static Future<HouseholdSession> reload() {
    _cached = null;
    _cachedAt = null;
    return ensureLoaded();
  }

  static void clear() {
    _cached = null;
    _cachedAt = null;
    _inFlight = null;
  }

  static Future<HouseholdSession> _resolve() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw StateError("Not signed in");
    }
    final uid = user.uid;
    final db = FirebaseDatabase.instance.ref();

    String? adminUid;
    try {
      final snap = await db.child('users/$uid/householdAdminUid').get();
      final value = snap.value;
      if (value is String && value.isNotEmpty) adminUid = value;
    } catch (_) {
      // Unreadable pointer — fall through and treat them as an admin of
      // their own household rather than locking them out of the app.
    }

    if (adminUid == null || adminUid == uid) {
      _cachedAt = DateTime.now();
      return _cached = HouseholdSession(
        uid: uid,
        role: HouseholdRole.admin,
        householdUid: uid,
        permissions: MemberPermissions.all,
        householdName: user.displayName,
      );
    }

    // Verify the link against the admin's own member list. A removed
    // member either sees no record or gets permission-denied, both of
    // which mean "no longer part of this household".
    Object? memberRecord;
    try {
      final snap = await db.child('users/$adminUid/members/$uid').get();
      memberRecord = snap.value;
    } catch (_) {
      memberRecord = null;
    }

    if (memberRecord is! Map) {
      _cachedAt = DateTime.now();
      return _cached = HouseholdSession(
        uid: uid,
        role: HouseholdRole.revoked,
        householdUid: adminUid,
        permissions: MemberPermissions.none,
      );
    }

    String? householdName;
    try {
      final snap = await db.child('users/$adminUid/profile/name').get();
      final value = snap.value;
      if (value is String && value.trim().isNotEmpty) householdName = value.trim();
    } catch (_) {
      // Non-essential.
    }

    _cachedAt = DateTime.now();
    return _cached = HouseholdSession(
      uid: uid,
      role: HouseholdRole.member,
      householdUid: adminUid,
      permissions: MemberPermissions.fromMap(memberRecord['permissions']),
      householdName: householdName,
    );
  }
}

// =====================================================================
// PROFILE BOOTSTRAP
//
// Writes users/{uid}/profile the first time an account signs in, so the
// Members page has a name/email to show and the role is recorded. Never
// overwrites an existing profile, and never promotes a member to admin.
// =====================================================================
/// Run after any successful sign-in or sign-up, before navigating to
/// /home: drops any session left behind by the previous account, records
/// the profile if this is a first sign-in, and resolves the household so
/// the pages know which appliance index to read and what's allowed.
Future<void> completeSignIn({String? name}) async {
  HouseholdSession.clear();
  final user = FirebaseAuth.instance.currentUser;
  if (user == null) return;
  await ensureProfile(user, name: name);
  try {
    await HouseholdSession.ensureLoaded();
  } catch (_) {
    // Pages fall back to loading it themselves.
  }
}

Future<void> ensureProfile(User user, {String? name}) async {
  final ref = FirebaseDatabase.instance.ref('users/${user.uid}');
  try {
    final existing = await ref.child('profile').get();
    if (existing.exists) return;

    final linkSnap = await ref.child('householdAdminUid').get();
    final link = linkSnap.value;
    final isMember = link is String && link.isNotEmpty;

    final resolvedName = (name ?? user.displayName ?? user.email?.split('@').first ?? 'User').trim();

    await ref.child('profile').set({
      'name': resolvedName.isEmpty ? 'User' : resolvedName,
      'email': user.email ?? '',
      'role': isMember ? 'member' : 'admin',
    });
  } catch (_) {
    // Profile is cosmetic — a failure here shouldn't block sign-in.
  }
}
