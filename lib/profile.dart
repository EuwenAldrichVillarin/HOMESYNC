import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';

import 'household.dart';

// =====================================================================
// PROFILE
//
// Every account — admin or member — can change its own display name and
// picture here. Both live under users/{uid}/profile, which the rules let
// a user write only for themselves.
//
// The picture is stored inline as a base64 JPEG string rather than in
// Cloud Storage, which this project isn't set up for. To keep that
// honest, a picked image is downscaled and re-encoded on the device
// before it's ever written (see _encodeAvatar) — a phone camera photo
// goes in at a few megabytes and comes out around 10-20 KB.
// =====================================================================

const Color _kTeal = Color(0xFF0F766E);
const Color _kInk = Color(0xFF1F2937);
const Color _kMuted = Color(0xFF64748B);
const Color _kFaint = Color(0xFF94A3B8);
const Color _kLine = Color(0xFFE2E8F0);

/// Longest base64 string accepted for an avatar. _encodeAvatar targets a
/// small fraction of this; the cap is a backstop so a pathological image
/// can't bloat the profile node (the database rules enforce the same).
const int kMaxAvatarChars = 200000;

/// Square size, in pixels, every avatar is stored at.
const int kAvatarSize = 256;

// ---------------------------------------------------------------------
// IMAGE PIPELINE
// ---------------------------------------------------------------------

/// Centre-crops to a square, scales to [kAvatarSize], and JPEG-encodes.
///
/// Done in Dart rather than with image_picker's maxWidth/imageQuality so
/// the result is identical on web, Android and iOS — those options are
/// honoured inconsistently across platforms, and "sometimes uploads a
/// 4 MB photo" is not something to leave to chance when the bytes land
/// in the database.
String _encodeAvatar(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) {
    throw const FormatException("That file doesn't look like an image");
  }

  // Square crop from the centre so portraits don't come out stretched.
  final side = decoded.width < decoded.height ? decoded.width : decoded.height;
  final cropped = img.copyCrop(
    decoded,
    x: (decoded.width - side) ~/ 2,
    y: (decoded.height - side) ~/ 2,
    width: side,
    height: side,
  );

  final resized = img.copyResize(
    cropped,
    width: kAvatarSize,
    height: kAvatarSize,
    interpolation: img.Interpolation.average,
  );

  return base64Encode(img.encodeJpg(resized, quality: 80));
}

/// Decoded avatars, keyed by the base64 string they came from.
///
/// Image.memory re-decodes whenever it's handed a fresh Uint8List, and a
/// list of member avatars would otherwise decode on every rebuild.
class _AvatarBytesCache {
  static final Map<String, Uint8List> _entries = {};
  static const int _maxEntries = 24;

  static Uint8List? bytesFor(String base64Data) {
    final cached = _entries[base64Data];
    if (cached != null) return cached;

    Uint8List decoded;
    try {
      decoded = base64Decode(base64Data);
    } catch (_) {
      return null; // Corrupt or truncated — fall back to initials.
    }

    if (_entries.length >= _maxEntries) {
      _entries.remove(_entries.keys.first);
    }
    _entries[base64Data] = decoded;
    return decoded;
  }
}

/// Initials for someone with no picture set, e.g. "Maria Santos" -> "MS".
String initialsFor(String name) {
  final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
  if (parts.isEmpty) return "?";
  if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
  return (parts.first.substring(0, 1) + parts.last.substring(0, 1)).toUpperCase();
}

// ---------------------------------------------------------------------
// AVATAR
// ---------------------------------------------------------------------

/// Someone's picture, or their initials when they haven't set one.
class ProfileAvatar extends StatelessWidget {
  final String name;

  /// Base64 JPEG as stored at users/{uid}/profile/photo, or null.
  final String? photo;

  final double size;

  const ProfileAvatar({
    super.key,
    required this.name,
    required this.photo,
    this.size = 40,
  });

  @override
  Widget build(BuildContext context) {
    final data = photo;
    final bytes = (data == null || data.isEmpty) ? null : _AvatarBytesCache.bytesFor(data);

    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      clipBehavior: Clip.antiAlias,
      decoration: const BoxDecoration(
        color: Color(0xFFE6F7F5),
        shape: BoxShape.circle,
      ),
      child: bytes == null
          ? Text(
              initialsFor(name),
              style: TextStyle(
                fontSize: size * 0.36,
                fontWeight: FontWeight.bold,
                color: _kTeal,
              ),
            )
          : Image.memory(
              bytes,
              width: size,
              height: size,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) => Text(
                initialsFor(name),
                style: TextStyle(
                  fontSize: size * 0.36,
                  fontWeight: FontWeight.bold,
                  color: _kTeal,
                ),
              ),
            ),
    );
  }
}

/// Watches users/{uid}/profile and keeps an avatar in sync with it.
/// Used where the profile isn't already loaded — the Home header, and
/// each row of the members list.
class LiveProfileAvatar extends StatefulWidget {
  final String uid;

  /// Shown until the profile arrives, and if it can't be read.
  final String fallbackName;
  final String? fallbackPhoto;
  final double size;

  const LiveProfileAvatar({
    super.key,
    required this.uid,
    required this.fallbackName,
    this.fallbackPhoto,
    this.size = 40,
  });

  @override
  State<LiveProfileAvatar> createState() => _LiveProfileAvatarState();
}

class _LiveProfileAvatarState extends State<LiveProfileAvatar> {
  StreamSubscription<DatabaseEvent>? _sub;
  String? _name;
  String? _photo;

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  @override
  void didUpdateWidget(LiveProfileAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.uid != widget.uid) {
      _sub?.cancel();
      _name = null;
      _photo = null;
      _subscribe();
    }
  }

  void _subscribe() {
    final uid = widget.uid;
    _sub = FirebaseDatabase.instance.ref('users/$uid/profile').onValue.listen((event) {
      if (!mounted || uid != widget.uid) return;
      final raw = event.snapshot.value;
      final map = raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
      setState(() {
        _name = map['name'] is String ? map['name'] as String : null;
        _photo = map['photo'] is String ? map['photo'] as String : null;
      });
    }, onError: (Object _) {
      // Not readable (e.g. an admin who can't see this profile) — the
      // fallbacks below carry the row.
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ProfileAvatar(
      name: _name ?? widget.fallbackName,
      photo: _photo ?? widget.fallbackPhoto,
      size: widget.size,
    );
  }
}

// ---------------------------------------------------------------------
// PROFILE PAGE
// ---------------------------------------------------------------------
class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  final _nameController = TextEditingController();

  HouseholdSession? _session;
  bool _loaded = false;
  bool _isSaving = false;
  bool _isPicking = false;

  /// The saved name/photo, so the Save button can tell whether anything
  /// actually changed.
  String _savedName = '';
  String? _savedPhoto;

  /// The picture as it currently stands on screen — may be a newly picked
  /// one that hasn't been saved yet.
  String? _photo;

  String _email = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final session = await HouseholdSession.ensureLoaded();
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        if (mounted) setState(() => _loaded = true);
        return;
      }

      final snap = await FirebaseDatabase.instance.ref('users/${user.uid}/profile').get();
      final raw = snap.value;
      final map = raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};

      // The database copy is authoritative; fall back to the Firebase Auth
      // account for a profile that predates this page.
      final name = (map['name'] is String && (map['name'] as String).trim().isNotEmpty)
          ? (map['name'] as String).trim()
          : (user.displayName ?? user.email?.split('@').first ?? '');

      if (!mounted) return;
      setState(() {
        _session = session;
        _savedName = name;
        _savedPhoto = map['photo'] is String ? map['photo'] as String : null;
        _photo = _savedPhoto;
        _email = (map['email'] is String && (map['email'] as String).isNotEmpty)
            ? map['email'] as String
            : (user.email ?? '');
        _nameController.text = name;
        _loaded = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loaded = true);
      _notify("Couldn't load your profile: $e");
    }
  }

  void _notify(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  bool get _hasChanges {
    final typed = _nameController.text.trim();
    return typed != _savedName || _photo != _savedPhoto;
  }

  // -------------------------------------------------------------------
  // PICTURE
  // -------------------------------------------------------------------
  Future<void> _pickPhoto(ImageSource source) async {
    if (_isPicking) return;
    setState(() => _isPicking = true);
    try {
      final picked = await ImagePicker().pickImage(source: source);
      if (picked == null) return; // Cancelled.

      final bytes = await picked.readAsBytes();
      final encoded = _encodeAvatar(bytes);

      if (encoded.length > kMaxAvatarChars) {
        _notify("That image is too large to use as a profile picture");
        return;
      }

      if (!mounted) return;
      setState(() => _photo = encoded);
    } on FormatException catch (e) {
      _notify(e.message);
    } catch (e) {
      _notify("Couldn't use that image: $e");
    } finally {
      if (mounted) setState(() => _isPicking = false);
    }
  }

  Future<void> _showPhotoOptions() async {
    final hasPhoto = _photo != null && _photo!.isNotEmpty;

    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 14),
            Container(
              width: 38,
              height: 4,
              decoration: BoxDecoration(
                color: _kLine,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            const SizedBox(height: 10),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined, color: _kTeal),
              title: const Text("Choose from gallery", style: TextStyle(fontSize: 14, color: _kInk)),
              onTap: () => Navigator.pop(sheetContext, 'gallery'),
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined, color: _kTeal),
              title: const Text("Take a photo", style: TextStyle(fontSize: 14, color: _kInk)),
              onTap: () => Navigator.pop(sheetContext, 'camera'),
            ),
            if (hasPhoto)
              ListTile(
                leading: const Icon(Icons.delete_outline, color: Color(0xFFDC2626)),
                title: const Text(
                  "Remove picture",
                  style: TextStyle(fontSize: 14, color: Color(0xFFDC2626)),
                ),
                onTap: () => Navigator.pop(sheetContext, 'remove'),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );

    switch (choice) {
      case 'gallery':
        await _pickPhoto(ImageSource.gallery);
      case 'camera':
        await _pickPhoto(ImageSource.camera);
      case 'remove':
        if (mounted) setState(() => _photo = null);
    }
  }

  // -------------------------------------------------------------------
  // SAVE
  // -------------------------------------------------------------------
  Future<void> _save() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final name = _nameController.text.trim();
    if (name.isEmpty) {
      _notify("Your name can't be empty");
      return;
    }
    if (name.length > 60) {
      _notify("That name is too long (60 characters max)");
      return;
    }

    setState(() => _isSaving = true);
    try {
      // null clears the picture; RTDB drops keys written as null.
      await FirebaseDatabase.instance.ref('users/${user.uid}/profile').update({
        'name': name,
        'photo': (_photo != null && _photo!.isNotEmpty) ? _photo : null,
      });

      // Keep the Firebase Auth account in step: Home's greeting and the
      // session's household name both read displayName.
      if (user.displayName != name) {
        await user.updateDisplayName(name);
        await user.reload();
      }

      // The session caches the admin's name; re-resolve so the change is
      // reflected without a sign-out.
      await HouseholdSession.reload();

      if (!mounted) return;
      setState(() {
        _savedName = name;
        _savedPhoto = _photo;
        _isSaving = false;
      });
      _notify("Profile updated");
    } catch (e) {
      if (!mounted) return;
      setState(() => _isSaving = false);
      _notify("Couldn't save your profile: $e");
    }
  }

  // -------------------------------------------------------------------
  // BUILD
  // -------------------------------------------------------------------
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
                    "My Profile",
                    style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold, color: _kInk),
                  ),
                ],
              ),
            ),
            Expanded(
              child: !_loaded
                  ? const Center(child: CircularProgressIndicator())
                  : _form(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _form() {
    final session = _session;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 30),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ============================================ PICTURE
          Center(
            child: Stack(
              children: [
                ProfileAvatar(
                  name: _nameController.text.trim().isEmpty ? _savedName : _nameController.text.trim(),
                  photo: _photo,
                  size: 104,
                ),
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: Material(
                    color: _kTeal,
                    shape: const CircleBorder(),
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: _isPicking ? null : _showPhotoOptions,
                      child: Container(
                        width: 34,
                        height: 34,
                        alignment: Alignment.center,
                        child: _isPicking
                            ? const SizedBox(
                                width: 15,
                                height: 15,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                              )
                            : const Icon(Icons.photo_camera, size: 17, color: Colors.white),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Center(
            child: TextButton(
              onPressed: _isPicking ? null : _showPhotoOptions,
              child: const Text(
                "Change picture",
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: _kTeal),
              ),
            ),
          ),

          const SizedBox(height: 14),

          // ============================================ NAME
          const Text(
            "Display name",
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: _kInk),
          ),
          const SizedBox(height: 7),
          TextField(
            controller: _nameController,
            textCapitalization: TextCapitalization.words,
            maxLength: 60,
            onChanged: (_) => setState(() {}), // keeps Save + initials live
            decoration: InputDecoration(
              hintText: "Your name",
              hintStyle: const TextStyle(fontSize: 13, color: _kFaint),
              counterText: "",
              filled: true,
              fillColor: Colors.white,
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
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            "This is the name shown in your greeting, and to the rest of your household.",
            style: TextStyle(fontSize: 11, color: _kFaint, height: 1.45),
          ),

          const SizedBox(height: 22),

          // ============================================ ACCOUNT
          if (session != null) ...[
            const Text(
              "Account",
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: _kInk),
            ),
            const SizedBox(height: 7),
            Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: _kLine),
              ),
              child: Column(
                children: [
                  _infoRow(Icons.mail_outline, "Email", _email.isEmpty ? "--" : _email),
                  const Divider(height: 1, color: Color(0xFFF1F5F9)),
                  _infoRow(
                    session.isAdmin ? Icons.shield_outlined : Icons.person_outline,
                    "Role",
                    session.isAdmin ? "Household admin" : "Household member",
                  ),
                  if (session.isMember && (session.householdName?.isNotEmpty ?? false)) ...[
                    const Divider(height: 1, color: Color(0xFFF1F5F9)),
                    _infoRow(Icons.home_outlined, "Household", "${session.householdName}'s home"),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 8),
            Text(
              session.isAdmin
                  ? "Your email and role can't be changed here."
                  : "Your email and what you can access are managed by your household admin.",
              style: const TextStyle(fontSize: 11, color: _kFaint, height: 1.45),
            ),
          ],

          const SizedBox(height: 26),

          // ============================================ SAVE
          SizedBox(
            width: double.infinity,
            height: 50,
            child: ElevatedButton(
              onPressed: (_isSaving || !_hasChanges) ? null : _save,
              style: ElevatedButton.styleFrom(
                backgroundColor: _kTeal,
                foregroundColor: Colors.white,
                disabledBackgroundColor: const Color(0xFFCBD5E1),
                elevation: 0,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: _isSaving
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : Text(
                      _hasChanges ? "Save Changes" : "Saved",
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  static Widget _infoRow(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: const Color(0xFFF1F5F9),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(icon, size: 16, color: _kTeal),
          ),
          const SizedBox(width: 12),
          Text(
            label,
            style: const TextStyle(fontSize: 12, color: _kMuted),
          ),
          const Spacer(),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.right,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: _kInk),
            ),
          ),
        ],
      ),
    );
  }
}
