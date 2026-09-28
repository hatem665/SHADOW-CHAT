import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:audioplayers/audioplayers.dart';
import 'package:video_player/video_player.dart';
import 'package:cryptography/cryptography.dart';
import 'package:record/record.dart';
import 'package:image_picker/image_picker.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'dart:convert';
import 'dart:async';
import 'dart:typed_data';
import 'dart:io';

// متغير عام يتحكم في حالة حركة الحوت في كل التطبيق
final ValueNotifier<bool> whaleMotionNotifier = ValueNotifier<bool>(true);
final ValueNotifier<bool> whaleSoundNotifier = ValueNotifier<bool>(true);
final ValueNotifier<bool> messageSoundNotifier = ValueNotifier<bool>(true);

// متغير عام يتحكم في التشفير التلقائي للرسائل
final ValueNotifier<bool> autoEncryptNotifier = ValueNotifier<bool>(false);

final ValueNotifier<String?> secretRoomCodeHashNotifier =
    ValueNotifier<String?>(null);

final ValueNotifier<String?> roomOwnerKeyHashNotifier = ValueNotifier<String?>(
  null,
);

const bool secureLocalDemoMode = false;
final ValueNotifier<Map<String, String>> chatPasswordsNotifier =
    ValueNotifier<Map<String, String>>({});
const int maxSecretRoomMembers = 100;
final ValueNotifier<List<String>> secretRoomMembersNotifier =
    ValueNotifier<List<String>>([]);

bool canRemoveSecretMember({
  required bool isGroup,
  required bool ownerVerified,
  required bool isOwnerUser,
}) {
  if (isGroup) return true;
  return ownerVerified && isOwnerUser;
}

bool isSecretRoomAtCapacity(int memberCount) {
  return memberCount >= maxSecretRoomMembers;
}

int resolveSecretRoomMemberCount({
  required List<String> memberIds,
  String? ownerUid,
}) {
  final uniqueIds = <String>{
    ...memberIds.where((id) => id.trim().isNotEmpty),
  };
  if (ownerUid != null && ownerUid.trim().isNotEmpty) {
    uniqueIds.add(ownerUid);
  }
  return uniqueIds.length.clamp(0, maxSecretRoomMembers);
}

DocumentReference<Map<String, dynamic>> secretRoomCapacityReference() =>
    FirebaseFirestore.instance
        .collection('rooms')
        .doc('secret_room')
        .collection('metadata')
        .doc('capacity');

Future<int> countRoomMembers(String roomId) async {
  if (!firebaseReady) return 0;
  try {
    final snapshot = await FirebaseFirestore.instance
        .collection('rooms')
        .doc(roomId)
        .collection('members')
        .limit(maxSecretRoomMembers + 1)
        .get();

    final memberIds = snapshot.docs.map((doc) => doc.id).toList();
    String? ownerUid;
    if (roomId == 'secret_room') {
      final owner = await FirebaseFirestore.instance
          .collection('config')
          .doc('app')
          .get();
      ownerUid = owner.data()?['ownerUid'] as String?;
      final actualCount = resolveSecretRoomMemberCount(
        memberIds: memberIds,
        ownerUid: ownerUid,
      );
      await secretRoomCapacityReference().set({
        'ownerUid': ownerUid ?? '',
        'memberCount': actualCount,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      return actualCount;
    }

    return memberIds.length;
  } catch (error) {
    debugPrint('Room member count failed for $roomId: $error');
    return 0;
  }
}

Future<void> ensureSecretRoomCapacityInitialized() async {
  final user = FirebaseAuth.instance.currentUser;
  if (!firebaseReady || user == null) {
    throw StateError('يلزم تسجيل الدخول لتهيئة سعة الغرفة');
  }

  final capacityRef = secretRoomCapacityReference();
  final ownerSnapshot = await FirebaseFirestore.instance
      .collection('config')
      .doc('app')
      .get();
  if (ownerSnapshot.data()?['ownerUid'] != user.uid) {
    throw StateError('تهيئة سعة الغرفة متاحة للمالك فقط');
  }

  final members = await FirebaseFirestore.instance
      .collection('rooms')
      .doc('secret_room')
      .collection('members')
      .limit(maxSecretRoomMembers + 1)
      .get();
  final initialCount = resolveSecretRoomMemberCount(
    memberIds: members.docs.map((doc) => doc.id).toList(),
    ownerUid: user.uid,
  );

  try {
    await capacityRef.set({
      'ownerUid': user.uid,
      'memberCount': initialCount,
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  } catch (error) {
    if (!(await capacityRef.get()).exists) rethrow;
  }
}

Future<bool> addSecretRoomMemberWithCapacity({
  required String memberId,
  required String displayName,
}) async {
  final user = FirebaseAuth.instance.currentUser;
  if (!firebaseReady || user == null || memberId.isEmpty) {
    throw StateError('تعذر التحقق من المستخدم الحالي');
  }
  if (memberId == user.uid) return false;

  final ownerSnapshot = await FirebaseFirestore.instance
      .collection('config')
      .doc('app')
      .get();
  if (ownerSnapshot.data()?['ownerUid'] != user.uid) {
    throw StateError('إضافة أعضاء الغرفة متاحة للمالك فقط');
  }
  await ensureSecretRoomCapacityInitialized();

  final firestore = FirebaseFirestore.instance;
  final capacityRef = secretRoomCapacityReference();
  final memberRef = firestore
      .collection('rooms')
      .doc('secret_room')
      .collection('members')
      .doc(memberId);
  final added = await firestore.runTransaction<bool>((transaction) async {
    final capacity = await transaction.get(capacityRef);
    final existingMember = await transaction.get(memberRef);
    if (existingMember.exists) return false;
    final memberCount = capacity.data()?['memberCount'];
    if (memberCount is! int) {
      throw StateError('عداد سعة الغرفة غير مهيأ');
    }
    if (isSecretRoomAtCapacity(memberCount)) {
      throw StateError('تم الوصول للحد الأقصى 100 عضو');
    }
    transaction.set(memberRef, {
      'displayName': displayName.isEmpty ? 'جهة اتصال' : displayName,
      'addedBy': user.uid,
      'addedAt': FieldValue.serverTimestamp(),
    });
    transaction.update(capacityRef, {
      'memberCount': memberCount + 1,
      'lastMemberId': memberId,
      'updatedAt': FieldValue.serverTimestamp(),
    });
    return true;
  });
  if (added) await refreshSecretRoomMemberNotifier();
  return added;
}

Future<bool> removeSecretRoomMemberWithCapacity(String memberId) async {
  final user = FirebaseAuth.instance.currentUser;
  if (!firebaseReady || user == null || memberId.isEmpty) return false;

  final firestore = FirebaseFirestore.instance;
  final capacityRef = secretRoomCapacityReference();
  final memberRef = firestore
      .collection('rooms')
      .doc('secret_room')
      .collection('members')
      .doc(memberId);
  if (!(await capacityRef.get()).exists) {
    final ownerSnapshot = await firestore.collection('config').doc('app').get();
    if (ownerSnapshot.data()?['ownerUid'] == user.uid) {
      await ensureSecretRoomCapacityInitialized();
    } else {
      await memberRef.delete();
      await refreshSecretRoomMemberNotifier();
      return true;
    }
  }
  final removed = await firestore.runTransaction<bool>((transaction) async {
    final capacity = await transaction.get(capacityRef);
    final member = await transaction.get(memberRef);
    if (!member.exists) return false;
    final memberCount = capacity.data()?['memberCount'];
    if (memberCount is! int || memberCount <= 0) {
      throw StateError('عداد سعة الغرفة غير متسق');
    }
    transaction.delete(memberRef);
    transaction.update(capacityRef, {
      'memberCount': memberCount - 1,
      'lastMemberId': memberId,
      'updatedAt': FieldValue.serverTimestamp(),
    });
    return true;
  });
  if (removed) await refreshSecretRoomMemberNotifier();
  return removed;
}

Future<void> refreshSecretRoomMemberNotifier() async {
  final roomId = 'secret_room';
  if (!firebaseReady) return;
  try {
    final snapshot = await FirebaseFirestore.instance
        .collection('rooms')
        .doc(roomId)
        .collection('members')
        .get();
    final memberIds = snapshot.docs.map((doc) => doc.id).toList();
    final owner = await FirebaseFirestore.instance
        .collection('config')
        .doc('app')
        .get();
    final ownerUid = owner.data()?['ownerUid'] as String?;
    final uniqueMembers = <String>{
      ...memberIds.where((id) => id.trim().isNotEmpty),
    };
    if (ownerUid != null && ownerUid.trim().isNotEmpty) {
      uniqueMembers.add(ownerUid);
    }
    secretRoomMembersNotifier.value = uniqueMembers.toList();
    final actualCount = resolveSecretRoomMemberCount(
      memberIds: uniqueMembers.toList(),
      ownerUid: ownerUid,
    );
    await secretRoomCapacityReference().set({
      'ownerUid': ownerUid ?? '',
      'memberCount': actualCount,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  } catch (error) {
    debugPrint('Secret room member refresh failed: $error');
  }
}

final ValueNotifier<bool> englishLanguageNotifier = ValueNotifier<bool>(false);
final ValueNotifier<bool> appLockEnabledNotifier = ValueNotifier<bool>(false);
final ValueNotifier<String?> appLockPasswordNotifier = ValueNotifier<String?>(
  null,
);
final ValueNotifier<bool> ghostModeNotifier = ValueNotifier<bool>(false);
final ValueNotifier<bool> autoDeleteMessagesNotifier = ValueNotifier<bool>(false);
final ValueNotifier<bool> secretGroupLockEnabledNotifier =
    ValueNotifier<bool>(false);
final ValueNotifier<String?> secretGroupPasswordHashNotifier =
    ValueNotifier<String?>(null);
final ValueNotifier<int> clearHistoryNotifier = ValueNotifier<int>(0);
final ValueNotifier<bool> globalDarkModeNotifier = ValueNotifier<bool>(true);
final ValueNotifier<Uint8List?> userProfileImageBytesNotifier =
    ValueNotifier<Uint8List?>(null);
const String appLockEnabledKey = 'app_lock_enabled';
const String appLockPasswordHashKey = 'app_lock_password_hash';
const String darkModeKey = 'dark_mode_enabled';
const String updateNoticeVersionKey = 'update_notice_version';
const String updateNoticeCountKey = 'update_notice_count';
bool firebaseReady = false;
String firebaseFailureMessage = '';
String? currentPublicUserId;
final ValueNotifier<String?> publicUserIdNotifier = ValueNotifier<String?>(null);

final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
    FlutterLocalNotificationsPlugin();

Future<void> initializeLocalNotifications() async {
  if (kIsWeb || defaultTargetPlatform == TargetPlatform.linux) return;

  const AndroidInitializationSettings androidSettings =
      AndroidInitializationSettings('@mipmap/ic_launcher');
  const DarwinInitializationSettings iosSettings = DarwinInitializationSettings();
  const InitializationSettings settings = InitializationSettings(
    android: androidSettings,
    iOS: iosSettings,
  );

  await flutterLocalNotificationsPlugin.initialize(settings);

  final androidPlugin =
      flutterLocalNotificationsPlugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
  await androidPlugin?.requestNotificationsPermission();
}

Future<void> showChatNotification({
  required String chatTitle,
  required String message,
  bool sentMessage = false,
}) async {
  if (kIsWeb || defaultTargetPlatform == TargetPlatform.linux) return;

  final title = sentMessage
      ? 'A whisper left the dark'
      : 'Something is waiting';
  final body = sentMessage
      ? 'Your message slipped through the silence and reached $chatTitle.'
      : 'A new pulse just arrived in $chatTitle — $message';

  const AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
    'shadow_chat_shadow_signal',
    'Whisper Echo',
    channelDescription: 'إشعارات جذابة وغامضة داخل Shadow Chat',
    importance: Importance.max,
    priority: Priority.high,
    playSound: true,
    enableVibration: true,
    ticker: 'Whisper Echo',
  );
  const DarwinNotificationDetails iosDetails = DarwinNotificationDetails();
  const NotificationDetails details = NotificationDetails(
    android: androidDetails,
    iOS: iosDetails,
  );

  await flutterLocalNotificationsPlugin.show(
    DateTime.now().millisecondsSinceEpoch ~/ 1000,
    title,
    body,
    details,
  );
}

Future<void> setupPushNotifications() async {
  if (!firebaseReady) return;
  final user = FirebaseAuth.instance.currentUser;
  if (user == null) return;

  try {
    final messaging = FirebaseMessaging.instance;
    await messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
      provisional: false,
    );
    final token = await messaging.getToken();
    if (token != null && token.isNotEmpty) {
      await FirebaseFirestore.instance.collection('users').doc(user.uid).set({
        'fcmToken': token,
        'fcmUpdatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    }
    messaging.onTokenRefresh.listen((newToken) async {
      await FirebaseFirestore.instance.collection('users').doc(user.uid).set({
        'fcmToken': newToken,
        'fcmUpdatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    });
  } catch (error) {
    debugPrint('Push notification setup failed: $error');
  }
}

Future<void> checkForUpdates(BuildContext context) async {
  if (!firebaseReady) return;
  try {
    final packageInfo = await PackageInfo.fromPlatform();
    final currentVersion = packageInfo.version;
    
    final updateDoc = await FirebaseFirestore.instance
        .collection('appUpdates')
        .doc('latestVersion')
        .get();
    
    if (!updateDoc.exists) return;
    
    final latestVersion = updateDoc.data()?['version'] as String?;
    final downloadUrl = updateDoc.data()?['downloadUrl'] as String?;
    final updateMessage = updateDoc.data()?['message'] as String?;
    final isForced = updateDoc.data()?['forced'] as bool? ?? false;
    
    if (latestVersion == null || latestVersion == currentVersion) return;

    final preferences = await getSafeSharedPreferences();
    if (preferences == null) return;
    final savedVersion = preferences.getString(updateNoticeVersionKey);
    final shownCount = savedVersion == latestVersion
      ? preferences.getInt(updateNoticeCountKey) ?? 0
      : 0;
    if (shownCount >= 2) return;
    
    // مقارنة الإصدارات
    if (_isNewVersionAvailable(currentVersion, latestVersion)) {
      if (context.mounted) {
        await preferences.setString(updateNoticeVersionKey, latestVersion);
        await preferences.setInt(updateNoticeCountKey, shownCount + 1);
        _showUpdateDialog(
          context,
          latestVersion,
          updateMessage ?? 'تطبيق جديد متاح! يرجى التحديث للاستمتاع بالميزات الجديدة.',
          downloadUrl,
          isForced,
        );
      }
    }
  } catch (error) {
    debugPrint('Update check error: $error');
  }
}

bool _isNewVersionAvailable(String current, String latest) {
  try {
    final currentParts = current.split('.');
    final latestParts = latest.split('.');
    
    for (int i = 0; i < (currentParts.length > latestParts.length ? latestParts.length : currentParts.length); i++) {
      final currentNum = int.tryParse(currentParts[i].split('-')[0]) ?? 0;
      final latestNum = int.tryParse(latestParts[i].split('-')[0]) ?? 0;
      
      if (latestNum > currentNum) return true;
      if (latestNum < currentNum) return false;
    }
    return false;
  } catch (e) {
    debugPrint('Version comparison error: $e');
    return false;
  }
}

void _showUpdateDialog(
  BuildContext context,
  String newVersion,
  String message,
  String? downloadUrl,
  bool isForced,
) {
  showDialog(
    context: context,
    barrierDismissible: !isForced,
    builder: (dialogContext) => AlertDialog(
      backgroundColor: const Color(0xFF1A1A1A),
      title: const Row(
        children: [
          Icon(Icons.system_update, color: Color(0xFF00FF66), size: 24),
          SizedBox(width: 10),
          Text(
            'تحديث جديد متاح ✨',
            style: TextStyle(color: Color(0xFF00FF66), fontSize: 18),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            message,
            style: const TextStyle(color: Colors.white70, fontSize: 14),
            textAlign: TextAlign.right,
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.grey[800],
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              'الإصدار الجديد: $newVersion',
              style: const TextStyle(
                color: Color(0xFF00FF66),
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
      actions: [
        if (!isForced)
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text(
              'تحديث لاحقاً',
              style: TextStyle(color: Colors.white54),
            ),
          ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF00FF66),
            foregroundColor: Colors.black,
          ),
          onPressed: () async {
            if (downloadUrl != null && downloadUrl.isNotEmpty) {
                Navigator.pop(dialogContext);
                await _downloadAndInstallUpdate(context, downloadUrl);
              } else if (dialogContext.mounted) {
                ScaffoldMessenger.of(dialogContext).showSnackBar(
                  const SnackBar(content: Text('رابط التحديث غير متاح حاليًا')),
                );
            }
          },
          child: const Text(
            'تحديث الآن',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
      ],
    ),
  );
}

Future<void> _downloadAndInstallUpdate(
  BuildContext context,
  String downloadUrl,
) async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
    final uri = Uri.tryParse(downloadUrl);
    if (uri != null && await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
      return;
    }
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تعذر فتح رابط التحديث')),
      );
    }
    return;
  }

  final uri = Uri.tryParse(downloadUrl);
  if (uri == null || uri.scheme != 'https') {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('رابط التحديث غير آمن')),
      );
    }
    return;
  }

  BuildContext? progressContext;
  if (context.mounted) {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        progressContext = dialogContext;
        return const AlertDialog(
          content: Row(
            children: [
              CircularProgressIndicator(),
              SizedBox(width: 16),
              Expanded(child: Text('جاري تنزيل التحديث...')),
            ],
          ),
        );
      },
    );
  }

  try {
    final response = await http.get(uri);
    if (response.statusCode != 200 || response.bodyBytes.isEmpty) {
      throw Exception('Update download failed: ${response.statusCode}');
    }
    final directory = await getTemporaryDirectory();
    final apkFile = File('${directory.path}/shadow_chat_update.apk');
    await apkFile.writeAsBytes(response.bodyBytes, flush: true);
    if (progressContext != null && progressContext!.mounted) {
      Navigator.of(progressContext!).pop();
    }
    final result = await OpenFilex.open(
      apkFile.path,
      type: 'application/vnd.android.package-archive',
    );
    if (result.type != ResultType.done && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تعذر فتح مثبت التحديث: ${result.message}')),
      );
    }
  } catch (error) {
    if (progressContext != null && progressContext!.mounted) {
      Navigator.of(progressContext!).pop();
    }
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('فشل تنزيل التحديث، حاول مرة أخرى')),
      );
    }
    debugPrint('In-app update error: $error');
  }
}

String appText(String arabic, String english) {
  return englishLanguageNotifier.value ? english : arabic;
}

Future<String> hashPassword(String password) async {
  final bytes = await Sha256().hash(utf8.encode(password));
  return base64Encode(bytes.bytes);
}

String sanitizeDisplayName(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) return '';
  return trimmed.replaceAll(RegExp(r'\s+'), ' ');
}

bool hasUnknownContactDisplayName(Object? value) {
  if (value is! String || value.trim().isEmpty) return true;
  final normalizedName = value.trim().toLowerCase();
  return normalizedName == 'غير معرف' ||
      normalizedName == 'غير معروف' ||
      normalizedName == 'unknown';
}

bool shouldRemoveUnknownContact(Map<String, dynamic> data) {
  final status = data['status'];
  if (status == 'pending' || status == 'incoming') return false;
  return hasUnknownContactDisplayName(data['displayName']);
}

String resolveContactDisplayName(Object? value, {required String fallback}) {
  if (hasUnknownContactDisplayName(value)) return fallback;
  return sanitizeDisplayName(value as String);
}

Future<void> syncUserDisplayNameAcrossApp(String newName) async {
  final user = FirebaseAuth.instance.currentUser;
  if (user == null) return;
  final cleanedName = sanitizeDisplayName(newName);
  if (cleanedName.isEmpty) return;

  try {
    await user.updateDisplayName(cleanedName);
  } catch (error) {
    debugPrint('Update auth display name failed: $error');
  }

  final firestore = FirebaseFirestore.instance;
  final profileData = {
    'displayName': cleanedName,
    'name': cleanedName,
    'updatedAt': FieldValue.serverTimestamp(),
  };

  await firestore
      .collection('users')
      .doc(user.uid)
      .set(profileData, SetOptions(merge: true));

  final publicId = currentPublicUserId ??
      publicUserIdNotifier.value ??
      'SC-${user.uid.substring(0, 6).toUpperCase()}';
  await firestore
      .collection('publicProfiles')
      .doc(user.uid)
      .set({
        'uid': user.uid,
        'displayName': cleanedName,
        'publicId': publicId,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

  final contactsSnapshot = await firestore
      .collection('users')
      .doc(user.uid)
      .collection(contactsCollectionName(ContactScope.regular))
      .get();

  for (final doc in contactsSnapshot.docs) {
    await doc.reference.set(
      {
        'displayName': cleanedName,
        'name': cleanedName,
        'updatedAt': FieldValue.serverTimestamp(),
      },
      SetOptions(merge: true),
    );
  }
}

Future<void> loadRoomOwnerKey() async {
  roomOwnerKeyHashNotifier.value = null;
  if (!firebaseReady) return;
  try {
    final snapshot = await FirebaseFirestore.instance
        .collection('config')
        .doc('app')
        .get();
    final storedHash = snapshot.data()?['ownerKeyHash'];
    if (storedHash is String && storedHash.isNotEmpty) {
      roomOwnerKeyHashNotifier.value = storedHash;
    }
  } catch (error) {
    debugPrint('Room owner key load error: $error');
  }
}

Future<void> loadSecretRoomCode() async {
  secretRoomCodeHashNotifier.value = null;
  if (!firebaseReady) return;
  try {
    final snapshot = await FirebaseFirestore.instance
        .collection('config')
        .doc('secretRoom')
        .get();
    final storedHash = snapshot.data()?['codeHash'];
    if (storedHash is String && storedHash.isNotEmpty) {
      secretRoomCodeHashNotifier.value = storedHash;
    }
  } catch (error) {
    debugPrint('Secret room code load error: $error');
  }
}

Future<void> savePrivacySetting(String key, bool value) async {
  if (!firebaseReady) return;
  final user = FirebaseAuth.instance.currentUser;
  if (user == null) return;
  try {
    final firestore = FirebaseFirestore.instance;
    final batch = firestore.batch();
    batch.set(
      firestore
          .collection('users')
          .doc(user.uid)
          .collection('settings')
          .doc('privacy'),
      {key: value, 'updatedAt': FieldValue.serverTimestamp()},
      SetOptions(merge: true),
    );
    if (key == 'ghostMode') {
      final presenceData = {
        'ghostMode': value,
        'updatedAt': FieldValue.serverTimestamp(),
      };
      batch.set(
        firestore.collection('users').doc(user.uid),
        presenceData,
        SetOptions(merge: true),
      );
      batch.set(
        firestore.collection('publicProfiles').doc(user.uid),
        presenceData,
        SetOptions(merge: true),
      );
    }
    await batch.commit();
  } catch (error) {
    debugPrint('Privacy setting save error: $error');
  }
}

Future<Map<String, dynamic>> loadSecretGroupSettings() async {
  secretGroupLockEnabledNotifier.value = false;
  secretGroupPasswordHashNotifier.value = null;
  if (!firebaseReady) return {};
  final user = FirebaseAuth.instance.currentUser;
  if (user == null) return {};
  try {
    final snapshot = await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .collection('settings')
        .doc('secretGroup')
        .get();
    final data = snapshot.data() ?? {};
    final hash = data['passwordHash'];
    final enabled = data['enabled'] == true;
    secretGroupLockEnabledNotifier.value = enabled;
    secretGroupPasswordHashNotifier.value =
        enabled && hash is String && hash.isNotEmpty ? hash : null;
    return data;
  } catch (error) {
    debugPrint('Secret group settings load error: $error');
    return {};
  }
}

Future<void> saveSecretGroupPassword(String password) async {
  final hash = await hashPassword(password);
  secretGroupLockEnabledNotifier.value = true;
  secretGroupPasswordHashNotifier.value = hash;
  if (!firebaseReady) return;
  final user = FirebaseAuth.instance.currentUser;
  if (user == null) return;
  try {
    await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .collection('settings')
        .doc('secretGroup')
        .set({
          'enabled': true,
          'passwordHash': hash,
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
  } catch (error) {
    debugPrint('Secret group password save error: $error');
  }
}

Future<void> disableSecretGroupLock() async {
  secretGroupLockEnabledNotifier.value = false;
  secretGroupPasswordHashNotifier.value = null;
  if (!firebaseReady) return;
  final user = FirebaseAuth.instance.currentUser;
  if (user == null) return;
  try {
    await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .collection('settings')
        .doc('secretGroup')
        .set({
          'enabled': false,
          'passwordHash': FieldValue.delete(),
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
  } catch (error) {
    debugPrint('Secret group lock disable error: $error');
  }
}

Future<DateTime> ensureSecretAccessStart(String roomId) async {
  final fallback = DateTime.now();
  if (!firebaseReady) return fallback;
  final user = FirebaseAuth.instance.currentUser;
  if (user == null) return fallback;
  final isPrivateGroup = roomId.startsWith('secret_group_');
  final key = isPrivateGroup
      ? 'secretGroupAccess_$roomId'
      : roomId == 'secret_group'
      ? 'secretGroupAccess'
      : 'secretRoomAccess';
  final reference = FirebaseFirestore.instance
      .collection('users')
      .doc(user.uid)
      .collection('settings')
      .doc(key);
  try {
    final snapshot = await reference.get();
    final value = snapshot.data()?['startedAt'];
    Timestamp? memberAddedAt;
    if (isPrivateGroup) {
      final membership = await FirebaseFirestore.instance
          .collection('rooms')
          .doc(roomId)
          .collection('members')
          .doc(user.uid)
          .get();
      final addedAt = membership.data()?['addedAt'];
      if (addedAt is Timestamp) memberAddedAt = addedAt;
    }
    if (value is Timestamp &&
        (memberAddedAt == null ||
            !memberAddedAt.toDate().isAfter(value.toDate()))) {
      return value.toDate();
    }
    final startedAt = memberAddedAt?.toDate() ?? fallback;
    await reference.set({
      'startedAt': Timestamp.fromDate(startedAt),
    }, SetOptions(merge: true));
    return startedAt;
  } catch (error) {
    debugPrint('Secret access start load error: $error');
  }
  return fallback;
}

Future<Map<String, dynamic>> loadPrivacySettings() async {
  if (!firebaseReady) return {};
  final user = FirebaseAuth.instance.currentUser;
  if (user == null) return {};
  try {
    final snapshot = await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .collection('settings')
        .doc('privacy')
        .get();
    final data = snapshot.data() ?? {};
    if (data['ghostMode'] is bool) {
      final ghostMode = data['ghostMode'] as bool;
      ghostModeNotifier.value = ghostMode;
      await FirebaseFirestore.instance
          .collection('publicProfiles')
          .doc(user.uid)
          .set({'ghostMode': ghostMode}, SetOptions(merge: true));
    }
    if (data['autoDeleteMessages'] is bool) {
      autoDeleteMessagesNotifier.value = data['autoDeleteMessages'] as bool;
    }
    if (data['messageSound'] is bool) {
      messageSoundNotifier.value = data['messageSound'] as bool;
    }
    return data;
  } catch (error) {
    debugPrint('Privacy settings load error: $error');
    return {};
  }
}

Future<void> deleteOwnChatMessages(String chatId) async {
  if (!firebaseReady) return;
  final user = FirebaseAuth.instance.currentUser;
  if (user == null) return;
  try {
    final snapshot = await FirebaseFirestore.instance
        .collection('chats')
        .doc(chatId)
        .collection('messages')
        .where('uid', isEqualTo: user.uid)
        .get();
    var batch = FirebaseFirestore.instance.batch();
    var operationCount = 0;
    for (final message in snapshot.docs) {
      batch.delete(message.reference);
      operationCount++;
      if (operationCount == 450) {
        await batch.commit();
        batch = FirebaseFirestore.instance.batch();
        operationCount = 0;
      }
    }
    if (operationCount > 0) await batch.commit();
  } catch (error) {
    debugPrint('Chat history delete error: $error');
  }
}

Future<void> deleteAllChatHistoryForUser() async {
  if (!firebaseReady) return;
  final user = FirebaseAuth.instance.currentUser;
  if (user == null) return;

  try {
    final snapshot = await FirebaseFirestore.instance
        .collectionGroup('messages')
        .get();
    var batch = FirebaseFirestore.instance.batch();
    var operationCount = 0;

    Future<void> commitBatch() async {
      if (operationCount == 0) return;
      await batch.commit();
      batch = FirebaseFirestore.instance.batch();
      operationCount = 0;
    }

    for (final message in snapshot.docs) {
      batch.update(message.reference, {
        'deletedFor': FieldValue.arrayUnion([user.uid]),
      });
      operationCount++;
      if (operationCount == 450) await commitBatch();
    }
    await commitBatch();
  } catch (error) {
    debugPrint('Full chat history delete error: $error');
    rethrow;
  }
}

Future<void> deleteExpiredOwnChatMessages(String chatId) async {
  if (!firebaseReady) return;
  final user = FirebaseAuth.instance.currentUser;
  if (user == null) return;
  try {
    final snapshot = await FirebaseFirestore.instance
        .collection('chats')
        .doc(chatId)
        .collection('messages')
        .where('uid', isEqualTo: user.uid)
        .get();
    final now = Timestamp.now();
    var batch = FirebaseFirestore.instance.batch();
    var operationCount = 0;
    for (final message in snapshot.docs) {
      final expiresAt = message.data()['expiresAt'];
      if (expiresAt is! Timestamp || expiresAt.compareTo(now) > 0) {
        continue;
      }
      batch.delete(message.reference);
      operationCount++;
      if (operationCount == 450) {
        await batch.commit();
        batch = FirebaseFirestore.instance.batch();
        operationCount = 0;
      }
    }
    if (operationCount > 0) await batch.commit();
  } catch (error) {
    debugPrint('Expired chat message delete error: $error');
  }
}

String chatDocumentId(String chatName) =>
    chatName.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');

String directChatDocumentId(String uidA, String uidB) {
  final participants = [uidA, uidB]..sort();
  return 'dm_${participants[0]}_${participants[1]}';
}

Future<bool> _hasApprovedDirectContact(String targetUid) async {
  final user = FirebaseAuth.instance.currentUser;
  if (!firebaseReady || user == null || targetUid.isEmpty) return false;

  try {
    final myDoc = await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .collection(contactsCollectionName(ContactScope.regular))
        .doc(targetUid)
        .get();
    final otherDoc = await FirebaseFirestore.instance
        .collection('users')
        .doc(targetUid)
        .collection(contactsCollectionName(ContactScope.regular))
        .doc(user.uid)
        .get();

    return myDoc.data()?['status'] == 'accepted' &&
        otherDoc.data()?['status'] == 'accepted';
  } catch (error) {
    debugPrint('Approved contact check error: $error');
    return false;
  }
}

Future<void> _acceptContactRequest(String contactUid, String displayName) async {
  final user = FirebaseAuth.instance.currentUser;
  if (!firebaseReady || user == null || contactUid.isEmpty) return;

  try {
    final update = {
      'status': 'accepted',
      'lastMessage': 'تمت الموافقة على الدردشة',
      'updatedAt': FieldValue.serverTimestamp(),
    };
    await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .collection(contactsCollectionName(ContactScope.regular))
        .doc(contactUid)
        .set(update, SetOptions(merge: true));
    await FirebaseFirestore.instance
        .collection('users')
        .doc(contactUid)
        .collection(contactsCollectionName(ContactScope.regular))
        .doc(user.uid)
        .set(update, SetOptions(merge: true));
  } catch (error) {
    debugPrint('Accept contact request error for $displayName: $error');
  }
}

Future<void> _rejectContactRequest(String contactUid, String displayName) async {
  final user = FirebaseAuth.instance.currentUser;
  if (!firebaseReady || user == null || contactUid.isEmpty) return;

  try {
    final update = {
      'status': 'rejected',
      'lastMessage': 'تم رفض طلب الاتصال',
      'updatedAt': FieldValue.serverTimestamp(),
    };
    await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .collection(contactsCollectionName(ContactScope.regular))
        .doc(contactUid)
        .set(update, SetOptions(merge: true));
    await FirebaseFirestore.instance
        .collection('users')
        .doc(contactUid)
        .collection(contactsCollectionName(ContactScope.regular))
        .doc(user.uid)
        .set(update, SetOptions(merge: true));
  } catch (error) {
    debugPrint('Reject contact request error for $displayName: $error');
  }
}

Future<void> saveChatPassword(String chatName, String password) async {
  final passwordHash = await hashPassword(password);
  chatPasswordsNotifier.value = {
    ...chatPasswordsNotifier.value,
    chatName: passwordHash,
  };
  if (!firebaseReady) return;
  final user = FirebaseAuth.instance.currentUser;
  if (user == null) return;
  try {
    await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .collection('chatSecurity')
        .doc(chatDocumentId(chatName))
        .set({
          'chatName': chatName,
          'passwordHash': passwordHash,
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
  } catch (error) {
    debugPrint('Chat password Firebase sync failed: $error');
  }
}

Future<void> disableChatPassword(String chatName) async {
  chatPasswordsNotifier.value = {...chatPasswordsNotifier.value}
    ..remove(chatName);
  if (!firebaseReady) return;
  final user = FirebaseAuth.instance.currentUser;
  if (user == null) return;
  try {
    await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .collection('chatSecurity')
        .doc(chatDocumentId(chatName))
        .delete();
  } catch (error) {
    debugPrint('Chat password Firebase delete failed: $error');
  }
}

Future<void> loadAppLockSettings() async {
  var passwordHash = await hashPassword(
    'shadow-lock-${DateTime.now().microsecondsSinceEpoch}',
  );
  var enabled = false;

  // SharedPreferences is not supported on Linux
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.linux) {
    appLockEnabledNotifier.value = enabled;
    appLockPasswordNotifier.value = passwordHash;
    globalDarkModeNotifier.value = true;
    return;
  }

  final preferences = await SharedPreferences.getInstance();
  enabled = preferences.getBool(appLockEnabledKey) ?? false;
  final savedPasswordHash = preferences.getString(appLockPasswordHashKey);
  if (savedPasswordHash != null && savedPasswordHash.isNotEmpty) {
    passwordHash = savedPasswordHash;
  }

  if (firebaseReady) {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      try {
        final lockRef = FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .collection('security')
            .doc('appLock');
        final lockSnapshot = await lockRef.get();
        final data = lockSnapshot.data();
        if (data?['passwordHash'] is String &&
            (data!['passwordHash'] as String).isNotEmpty) {
          passwordHash = data['passwordHash'] as String;
          enabled = data['enabled'] == true;
        } else {
          await lockRef.set({
            'passwordHash': passwordHash,
            'enabled': enabled,
            'updatedAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));
        }
      } catch (error) {
        debugPrint('App lock Firebase load failed: $error');
      }
    }
  }

  await preferences.setBool(appLockEnabledKey, enabled);
  await preferences.setString(appLockPasswordHashKey, passwordHash);
  appLockEnabledNotifier.value = enabled;
  appLockPasswordNotifier.value = passwordHash;
  globalDarkModeNotifier.value = preferences.getBool(darkModeKey) ?? true;
}

Future<void> saveDarkModeSetting(bool enabled) async {
  globalDarkModeNotifier.value = enabled;

  // SharedPreferences is not supported on Linux
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.linux) {
    return;
  }

  final preferences = await SharedPreferences.getInstance();
  await preferences.setBool(darkModeKey, enabled);
}

Future<void> saveAppLockSettings({
  required bool enabled,
  required String passwordHash,
}) async {
  if (!firebaseReady) await initializeFirebase();
  final user = FirebaseAuth.instance.currentUser;

  // SharedPreferences is not supported on Linux
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.linux) {
    appLockEnabledNotifier.value = enabled;
    appLockPasswordNotifier.value = passwordHash;
    return;
  }

  final preferences = await SharedPreferences.getInstance();
  await preferences.setBool(appLockEnabledKey, enabled);
  await preferences.setString(appLockPasswordHashKey, passwordHash);
  appLockEnabledNotifier.value = enabled;
  appLockPasswordNotifier.value = passwordHash;

  if (!firebaseReady || user == null) return;
  try {
    await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .collection('security')
        .doc('appLock')
        .set({
          'passwordHash': passwordHash,
          'enabled': enabled,
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
  } catch (error) {
    debugPrint('App lock Firebase sync failed: $error');
  }
}

Future<void> showChangeAppLockPasswordDialog(BuildContext context) async {
  final oldController = TextEditingController();
  final newController = TextEditingController();
  final confirmController = TextEditingController();
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('تغيير كلمة سر قفل التطبيق'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: oldController,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'كلمة السر القديمة'),
          ),
          TextField(
            controller: newController,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'كلمة السر الجديدة'),
          ),
          TextField(
            controller: confirmController,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'تأكيد كلمة السر الجديدة',
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('إلغاء'),
        ),
        ElevatedButton(
          onPressed: () async {
            final newPassword = newController.text.trim();
            if (await hashPassword(oldController.text.trim()) !=
                    appLockPasswordNotifier.value ||
                newPassword.length < 4 ||
                newPassword != confirmController.text.trim()) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('تحقق من كلمة السر القديمة والجديدة'),
                ),
              );
              return;
            }
            try {
              await saveAppLockSettings(
                enabled: true,
                passwordHash: await hashPassword(newPassword),
              );
              if (dialogContext.mounted) Navigator.pop(dialogContext);
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('تم حفظ كلمة السر في Firebase')),
                );
              }
            } catch (error) {
              debugPrint('App lock password save error: $error');
              if (context.mounted) {
                showGenericFailureSnackBar(context);
              }
            }
          },
          child: const Text('حفظ'),
        ),
      ],
    ),
  );
  oldController.dispose();
  newController.dispose();
  confirmController.dispose();
}

bool isDuplicateFirebaseInitializationError(Object error) {
  if (error is FirebaseException) {
    if (error.code == 'duplicate-app') return true;
  }

  final text = error.toString();
  return text.contains('A Firebase App named') &&
      text.contains('already exists');
}

Future<SharedPreferences?> getSafeSharedPreferences() async {
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.linux) {
    return null;
  }
  return SharedPreferences.getInstance();
}

const String firebaseWebApiKey = String.fromEnvironment(
  'FIREBASE_WEB_API_KEY',
  defaultValue: 'REPLACE_WITH_WEB_API_KEY',
);

Future<void> initializeFirebase() async {
  // Firebase is not supported on Linux desktop
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.linux) {
    firebaseReady = false;
    firebaseFailureMessage =
        'Firebase is not supported on Linux. Use Android, iOS, or Web.';
    return;
  }

  if (secureLocalDemoMode) {
    firebaseReady = false;
    firebaseFailureMessage = 'Local demo mode enabled';
    return;
  }

  try {
    if (Firebase.apps.isEmpty) {
      try {
        if (kIsWeb) {
          await Firebase.initializeApp(
            options: FirebaseOptions(
              apiKey: firebaseWebApiKey,
              appId: '1:525641785110:android:acb70e1294c17dec00fa37',
              messagingSenderId: '525641785110',
              projectId: 'shadow-chat-9edd9',
              authDomain: 'shadow-chat-9edd9.firebaseapp.com',
              storageBucket: 'shadow-chat-9edd9.firebasestorage.app',
            ),
          );
        } else {
          await Firebase.initializeApp();
        }
      } on FirebaseException catch (error) {
        if (!isDuplicateFirebaseInitializationError(error)) rethrow;
        debugPrint(
          'Firebase already initialized; ignoring duplicate init: $error',
        );
      }
    }

    firebaseReady = true;
    unawaited(initializeLocalNotifications());
  } catch (error) {
    firebaseFailureMessage = error.toString();
    debugPrint('Firebase initialization failed: $error');
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (secureLocalDemoMode) {
    firebaseReady = false;
    await loadAppLockSettings();
  } else {
    await initializeFirebase();
  }
  runApp(const ShadowChatApp());
}

Future<void> ensureUserProfile() async {
  final user = FirebaseAuth.instance.currentUser;
  if (user == null) return;
  final fallbackPublicId =
    'SC-${user.uid.substring(0, 6).toUpperCase()}';
  currentPublicUserId = fallbackPublicId;
  publicUserIdNotifier.value = fallbackPublicId;

  final profileRef = FirebaseFirestore.instance
      .collection('users')
      .doc(user.uid);
  DocumentSnapshot<Map<String, dynamic>>? profile;
  var profileReadSucceeded = false;
  try {
    profile = await profileRef.get().timeout(const Duration(seconds: 10));
    profileReadSucceeded = true;
  } catch (error) {
    debugPrint('User profile read failed: $error');
  }
  final storedPublicId = profile?.data()?['publicId'];
  final publicId = storedPublicId is String && storedPublicId.isNotEmpty
    ? storedPublicId
    : fallbackPublicId;
  currentPublicUserId = publicId;
  publicUserIdNotifier.value = publicId;
  if (profileReadSucceeded) {
    try {
      final profileData = {
        'publicId': publicId,
        'displayName': profile?.data()?['displayName'] ?? 'Shadow User',
        if (user.phoneNumber != null)
          'phoneNumber': normalizePhoneNumber(user.phoneNumber!),
        if (user.phoneNumber != null)
          'phoneSearchKey': _phoneSearchKey(user.phoneNumber!),
        'updatedAt': FieldValue.serverTimestamp(),
      };
      await profileRef.set(profileData, SetOptions(merge: true))
          .timeout(const Duration(seconds: 10));
      await FirebaseFirestore.instance
          .collection('publicProfiles')
          .doc(user.uid)
          .set({
            'uid': user.uid,
            'publicId': publicId,
            'displayName': profileData['displayName'],
            if (profileData['phoneSearchKey'] != null)
              'phoneSearchKey': profileData['phoneSearchKey'],
            if (profileData['phoneNumber'] != null)
              'phoneNumber': profileData['phoneNumber'],
            'updatedAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));
    } catch (error) {
      debugPrint('User profile sync failed: $error');
    }
  }

  // تعيين owner للغرفة السرية والمجموعة السرية تلقائياً
  try {
    final configRef = FirebaseFirestore.instance
        .collection('config')
        .doc('app');
    final configDoc = await configRef.get();
    if (configDoc.data()?['ownerUid'] == null) {
      await configRef.set({
        'ownerUid': user.uid,
        'createdAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    }
  } catch (error) {
    debugPrint('Owner assignment error: $error');
  }
}

String normalizePhoneNumber(String phone) =>
    phone
        .replaceAllMapped(RegExp(r'[٠-٩]'), (match) {
          return '٠١٢٣٤٥٦٧٨٩'.indexOf(match.group(0)!).toString();
        })
        .replaceAll(RegExp(r'[^0-9+]'), '');

String determineRegularContactAction({
  required String myStatus,
  required String otherStatus,
}) {
  final normalizedMyStatus = myStatus.trim().toLowerCase();
  final normalizedOtherStatus = otherStatus.trim().toLowerCase();

  if (normalizedMyStatus == 'accepted' || normalizedOtherStatus == 'accepted') {
    return 'accepted';
  }
  if (normalizedMyStatus == 'pending' || normalizedOtherStatus == 'pending') {
    return 'pending';
  }
  if (normalizedMyStatus == 'incoming' || normalizedOtherStatus == 'incoming') {
    return 'incoming';
  }
  if (normalizedMyStatus == 'rejected' || normalizedOtherStatus == 'rejected') {
    return 'rejected';
  }
  return 'none';
}

String _phoneSearchKey(String phone) {
  final normalizedPhone = normalizePhoneNumber(phone);
  final normalized = normalizedPhone.startsWith('+')
      ? normalizedPhone.substring(1)
      : normalizedPhone;
  return normalized.length > 10
      ? normalized.substring(normalized.length - 10)
      : normalized;
}

String firebaseWriteFailureMessage(Object error) {
  if (error is FirebaseException) {
    return 'تعذرت الإضافة في Firebase (${error.code}). تحقق من تسجيل الدخول والاتصال وقواعد المشروع.';
  }
  if (error is StateError) return error.message.toString();
  return 'تعذرت الإضافة في Firebase. تحقق من الاتصال وإعدادات المشروع.';
}

void showGenericFailureSnackBar(BuildContext context) {
  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(content: Text('حدث خطأ، حاول مرة أخرى')),
  );
}

Future<void> addSecretRoomMember({
  required String targetUid,
  required String displayName,
}) async {
  await addSecretRoomMemberWithCapacity(
    memberId: targetUid,
    displayName: displayName,
  );
}

Future<void> updatePresence(bool isOnline) async {
  if (!firebaseReady) return;
  final user = FirebaseAuth.instance.currentUser;
  if (user == null) return;
  try {
    final now = Timestamp.now();
    await FirebaseFirestore.instance
        .collection('publicProfiles')
        .doc(user.uid)
        .set({
          'isOnline': isOnline,
          'lastSeen': now,
          'lastSeenAt': now,
        }, SetOptions(merge: true));
  } catch (error) {
    debugPrint('Presence update error: $error');
  }
}

class ShadowChatApp extends StatelessWidget {
  const ShadowChatApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: englishLanguageNotifier,
      builder: (context, isEnglish, child) {
        return ValueListenableBuilder<bool>(
          valueListenable: globalDarkModeNotifier,
          builder: (context, isDark, child) {
            return MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: ThemeData.light(useMaterial3: true).copyWith(
                scaffoldBackgroundColor: const Color(0xFFF5F7F8),
                colorScheme: ColorScheme.fromSeed(
                  seedColor: const Color(0xFF167A5A),
                  brightness: Brightness.light,
                ),
                appBarTheme: const AppBarTheme(
                  backgroundColor: Color(0xFFEFF5F3),
                  foregroundColor: Color(0xFF13211D),
                  elevation: 0,
                  centerTitle: true,
                ),
                cardTheme: const CardThemeData(
                  color: Colors.white,
                  elevation: 0,
                  surfaceTintColor: Colors.transparent,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.all(Radius.circular(18)),
                  ),
                ),
                dividerTheme: const DividerThemeData(color: Color(0x1F1F2933)),
                inputDecorationTheme: const InputDecorationTheme(
                  filled: true,
                  fillColor: Color(0xFFF0F4F3),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.all(Radius.circular(14)),
                    borderSide: BorderSide(color: Color(0xFFE2E8E5)),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.all(Radius.circular(14)),
                    borderSide: BorderSide(color: Color(0xFFE2E8E5)),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.all(Radius.circular(14)),
                    borderSide: BorderSide(color: Color(0xFF167A5A), width: 1.6),
                  ),
                ),
                listTileTheme: const ListTileThemeData(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.all(Radius.circular(16)),
                  ),
                ),
                elevatedButtonTheme: ElevatedButtonThemeData(
                  style: ElevatedButton.styleFrom(
                    elevation: 0,
                    minimumSize: const Size(0, 52),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                ),
                floatingActionButtonTheme: const FloatingActionButtonThemeData(
                  backgroundColor: Color(0xFF167A5A),
                  foregroundColor: Colors.white,
                ),
                dialogTheme: const DialogThemeData(
                  backgroundColor: Color(0xFFF9FBFB),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.all(Radius.circular(20)),
                  ),
                ),
              ),
              darkTheme: ThemeData.dark(useMaterial3: true).copyWith(
                scaffoldBackgroundColor: const Color(0xFF0C1217),
                colorScheme: ColorScheme.fromSeed(
                  seedColor: const Color(0xFF38E8A5),
                  brightness: Brightness.dark,
                ),
                appBarTheme: const AppBarTheme(
                  backgroundColor: Color(0xFF121B1A),
                  foregroundColor: Color(0xFFE8F3EF),
                  elevation: 0,
                  centerTitle: true,
                ),
                cardTheme: const CardThemeData(
                  color: Color(0xFF171F26),
                  elevation: 0,
                  surfaceTintColor: Colors.transparent,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.all(Radius.circular(18)),
                  ),
                ),
                dividerTheme: const DividerThemeData(color: Color(0x334DD6A2)),
                inputDecorationTheme: const InputDecorationTheme(
                  filled: true,
                  fillColor: Color(0xFF1A2329),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.all(Radius.circular(14)),
                    borderSide: BorderSide(color: Color(0xFF25313A)),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.all(Radius.circular(14)),
                    borderSide: BorderSide(color: Color(0xFF25313A)),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.all(Radius.circular(14)),
                    borderSide: BorderSide(color: Color(0xFF38E8A5), width: 1.6),
                  ),
                ),
                listTileTheme: const ListTileThemeData(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.all(Radius.circular(16)),
                  ),
                ),
                elevatedButtonTheme: ElevatedButtonThemeData(
                  style: ElevatedButton.styleFrom(
                    elevation: 0,
                    minimumSize: const Size(0, 52),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                ),
                floatingActionButtonTheme: const FloatingActionButtonThemeData(
                  backgroundColor: Color(0xFF38E8A5),
                  foregroundColor: Color(0xFF07130F),
                ),
                dialogTheme: const DialogThemeData(
                  backgroundColor: Color(0xFF161D24),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.all(Radius.circular(20)),
                  ),
                ),
              ),
              themeMode: isDark ? ThemeMode.dark : ThemeMode.light,
              home: Directionality(
                textDirection: isEnglish
                    ? TextDirection.ltr
                    : TextDirection.rtl,
                child: const StartupGate(),
              ),
            );
          },
        );
      },
    );
  }
}

class StartupGate extends StatefulWidget {
  const StartupGate({super.key});

  @override
  State<StartupGate> createState() => _StartupGateState();
}

class _StartupGateState extends State<StartupGate> {
  static const String _introSeenKey = 'startup_intro_seen';

  @override
  void initState() {
    super.initState();
    _showStartupInfoIfNeeded();
  }

  Future<void> _showStartupInfoIfNeeded() async {
    final preferences = await getSafeSharedPreferences();
    if (preferences == null || !mounted) return;
    if (preferences.getBool(_introSeenKey) == true || !mounted) return;
    await Future<void>.delayed(Duration.zero);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.shield_rounded, color: Color(0xFF38E8A5)),
            SizedBox(width: 10),
            Text('Shadow Chat BETA'),
          ],
        ),
        content: const Text(
          'مساحتك الخاصة للمحادثات. يستخدم التطبيق Firebase لحفظ الرسائل، ويطلب الإشعارات لإبلاغك بالرسائل الجديدة، والكاميرا والميكروفون عند استخدام الوسائط أو الرسائل الصوتية.',
          textAlign: TextAlign.right,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('فهمت'),
          ),
        ],
      ),
    );
    await preferences.setBool(_introSeenKey, true);
  }

  @override
  Widget build(BuildContext context) => const AuthGate();
}

class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  bool _isTryingAnonymousLogin = false;
  bool _sessionPrepared = false;
  bool _preparingSession = false;
  String? _authError;

  Future<void> _ensureAnonymousLogin() async {
    if (!firebaseReady || FirebaseAuth.instance.currentUser != null) return;

    try {
      await FirebaseAuth.instance.signInAnonymously();
      if (mounted) setState(() => _authError = null);
    } catch (error) {
      debugPrint('Anonymous login failed: $error');
      if (mounted) {
        setState(() {
          _isTryingAnonymousLogin = false;
          _authError = error.toString();
        });
      }
    }
  }

  Future<void> _prepareAuthenticatedSession() async {
    if (_sessionPrepared || _preparingSession) return;
    _preparingSession = true;
    try {
      await Future.wait([
        loadPrivacySettings(),
        loadAppLockSettings(),
      ]);
      unawaited(ensureUserProfile());
      unawaited(setupPushNotifications());
      unawaited(loadRoomOwnerKey());
      unawaited(loadSecretRoomCode());
      if (mounted) setState(() => _authError = null);
    } catch (error) {
      debugPrint('Authenticated session setup failed: $error');
      if (mounted) {
        setState(() => _authError = error.toString());
      }
    } finally {
      _sessionPrepared = true;
      _preparingSession = false;
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    if (secureLocalDemoMode) {
      return const AppLockGate();
    }

    if (!firebaseReady) {
      return Scaffold(
        body: Center(
          child: Text(
            'الوضع المحلي مفعل\nسيتم استكمال المزايا عند اتصال Firebase',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
      );
    }

    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return Scaffold(body: Center(child: CircularProgressIndicator()));
        }

        if (snapshot.data == null) {
          if (!_isTryingAnonymousLogin) {
            _isTryingAnonymousLogin = true;
            unawaited(_ensureAnonymousLogin());
          }
          return Scaffold(
            body: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text(
                    _authError == null
                        ? 'جاري تجهيز التطبيق...'
                        : 'حدثت مشكلة، حاول مرة أخرى',
                    style: const TextStyle(color: Colors.white70),
                  ),
                  if (_authError != null)
                    TextButton.icon(
                      onPressed: _ensureAnonymousLogin,
                      icon: const Icon(Icons.refresh),
                      label: const Text('إعادة المحاولة'),
                    ),
                ],
              ),
            ),
          );
        }

        if (!_sessionPrepared) {
          unawaited(_prepareAuthenticatedSession());
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        return const AppLockGate();
      },
    );
  }
}

class AppLockGate extends StatefulWidget {
  const AppLockGate({super.key});

  @override
  State<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends State<AppLockGate>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  final TextEditingController _passwordController = TextEditingController();
  late AnimationController _lockAnimationController;
  late Animation<double> _lockAnimation;
  bool _unlocked = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(updatePresence(true));
    appLockEnabledNotifier.addListener(_onLockChanged);
    _unlocked = !appLockEnabledNotifier.value;
    _lockAnimationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat(reverse: true);
    _lockAnimation = Tween<double>(begin: 0.94, end: 1.06).animate(
      CurvedAnimation(
        parent: _lockAnimationController,
        curve: Curves.easeInOut,
      ),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(updatePresence(true));
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      unawaited(updatePresence(false));
    }
    if ((state == AppLifecycleState.paused ||
            state == AppLifecycleState.inactive) &&
        appLockEnabledNotifier.value &&
        mounted) {
      setState(() => _unlocked = false);
    }
  }

  void _onLockChanged() {
    if (!appLockEnabledNotifier.value) {
      setState(() => _unlocked = true);
    } else if (appLockPasswordNotifier.value != null) {
      setState(() => _unlocked = false);
    }
  }

  Future<void> _unlock() async {
    if (await hashPassword(_passwordController.text.trim()) ==
        appLockPasswordNotifier.value) {
      setState(() {
        _unlocked = true;
        _passwordController.clear();
      });
    } else {
      debugPrint('App lock password check failed');
    }
  }

  @override
  void dispose() {
    unawaited(updatePresence(false));
    WidgetsBinding.instance.removeObserver(this);
    appLockEnabledNotifier.removeListener(_onLockChanged);
    _lockAnimationController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_unlocked || !appLockEnabledNotifier.value)
      return const ChatListScreen();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: const Color(0xFF06110D),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF071A13), Color(0xFF020504)],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              const Padding(
                padding: EdgeInsets.only(top: 24),
                child: Text(
                  '✦  SHADOW SHAT  ✦',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 2.5,
                  ),
                ),
              ),
              const Text(
                'Private space',
                style: TextStyle(
                  color: Color(0xFF8BA99A),
                  fontSize: 11,
                  letterSpacing: 1.4,
                ),
              ),
              Expanded(
                child: Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(24),
                    child: Container(
                      constraints: const BoxConstraints(maxWidth: 410),
                      padding: const EdgeInsets.fromLTRB(24, 30, 24, 24),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0C1B15).withOpacity(0.96),
                        borderRadius: BorderRadius.circular(26),
                        border: Border.all(
                          color: const Color(0xFF3D8062).withOpacity(0.45),
                        ),
                        boxShadow: const [
                          BoxShadow(
                            color: Color(0x3300FF66),
                            blurRadius: 30,
                            spreadRadius: 2,
                          ),
                        ],
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ScaleTransition(
                            scale: _lockAnimation,
                            child: Container(
                              padding: const EdgeInsets.all(19),
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: const Color(0xFF00FF66).withOpacity(0.1),
                                border: Border.all(
                                  color: const Color(0xFF00FF66),
                                  width: 1.5,
                                ),
                              ),
                              child: const Icon(
                                Icons.phonelink_lock_rounded,
                                color: Color(0xFF00FF66),
                                size: 48,
                              ),
                            ),
                          ),
                          const SizedBox(height: 22),
                          const Text(
                            'APP SECURED',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 23,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 1.2,
                            ),
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            'مساحتك الخاصة محمية بالكامل',
                            style: TextStyle(
                              color: Color(0xFF9BB5A7),
                              fontSize: 13,
                            ),
                          ),
                          const SizedBox(height: 25),
                          TextField(
                            controller: _passwordController,
                            obscureText: true,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Colors.white,
                              letterSpacing: 3,
                            ),
                            decoration: InputDecoration(
                              hintText: 'اكتب كلمة مرورك هنا',
                              hintStyle: TextStyle(
                                color: isDark ? Colors.white : Colors.black,
                                letterSpacing: 0,
                              ),
                              filled: true,
                              fillColor: Colors.black.withOpacity(0.28),
                              prefixIcon: const Icon(
                                Icons.key_rounded,
                                color: Colors.amberAccent,
                              ),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(15),
                                borderSide: BorderSide.none,
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(15),
                                borderSide: const BorderSide(
                                  color: Color(0xFF00FF66),
                                  width: 1.5,
                                ),
                              ),
                            ),
                            onSubmitted: (_) => _unlock(),
                          ),
                          const SizedBox(height: 18),
                          SizedBox(
                            width: double.infinity,
                            height: 50,
                            child: ElevatedButton.icon(
                              onPressed: _unlock,
                              icon: const Icon(Icons.lock_open_rounded),
                              label: const Text(
                                'دخول آمن',
                                style: TextStyle(fontWeight: FontWeight.bold),
                              ),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF00FF66),
                                foregroundColor: Colors.black,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(15),
                                ),
                              ),
                            ),
                          ),
                          if (appLockEnabledNotifier.value)
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: TextButton.icon(
                                onPressed: () =>
                                    showChangeAppLockPasswordDialog(context),
                                icon: const Icon(
                                  Icons.password_rounded,
                                  size: 18,
                                ),
                                label: const Text('تغيير كلمة سر قفل التطبيق'),
                                style: TextButton.styleFrom(
                                  foregroundColor: Colors.amberAccent,
                                ),
                              ),
                            ),
                          const SizedBox(height: 15),
                          const Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.verified_user_outlined,
                                color: Colors.amberAccent,
                                size: 15,
                              ),
                              SizedBox(width: 6),
                              Text(
                                'Shadow Chat Security',
                                style: TextStyle(
                                  color: Colors.white54,
                                  fontSize: 11,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ==========================================
// 1. القائمة الرئيسية
// ==========================================
class ChatListScreen extends StatefulWidget {
  const ChatListScreen({super.key});

  @override
  State<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends State<ChatListScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkAndShowIntroduction();
      // التحقق من التحديثات
      if (mounted) {
        checkForUpdates(context);
      }
    });
  }

  Future<void> _checkAndShowIntroduction() async {
    try {
      final prefs = await getSafeSharedPreferences();
      if (prefs == null) return;
      final hasSeenIntro = prefs.getBool('has_seen_onboarding') ?? false;

      if (!hasSeenIntro && mounted) {
        _showIntroductionDialog();
      } else if (firebaseReady && hasSeenIntro) {
        // مزامنة حالة الترحيب مع Firebase في الخلفية
        _syncOnboardingStatusWithFirebase(true);
      }
    } catch (error) {
      debugPrint('Error checking introduction: $error');
    }
  }

  Future<void> _syncOnboardingStatusWithFirebase(bool completed) async {
    if (!firebaseReady) return;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .collection('settings')
          .doc('onboarding')
          .set({
            'onboardingCompleted': completed,
            'completedAt': FieldValue.serverTimestamp(),
            'appVersion': '1.0.0-beta.1',
          }, SetOptions(merge: true));
      debugPrint('Onboarding status synced to Firebase');
    } catch (error) {
      debugPrint('Error syncing onboarding status: $error');
    }
  }

  Future<void> _showIntroductionDialog() async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: const Text(
          'أهلاً بك في Shadow Chat 👋',
          style: TextStyle(
            color: Color(0xFF00FF66),
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              const Text(
                'تطبيق المراسلة الآمن والمشفر',
                style: TextStyle(color: Colors.white70, fontSize: 16),
                textAlign: TextAlign.right,
              ),
              const SizedBox(height: 16),
              Text(
                'الإصدار التجريبي: BETA 1.0.0-beta.1',
                style: TextStyle(color: Colors.white54, fontSize: 14),
                textAlign: TextAlign.right,
              ),
              const SizedBox(height: 12),
              const Divider(color: Color(0xFF00FF66)),
              const SizedBox(height: 12),
              const Text(
                'المميزات:',
                style: TextStyle(
                  color: Color(0xFF00FF66),
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.right,
              ),
              const SizedBox(height: 8),
              const Text(
                '🔐 تشفير AES-256 للرسائل\n'
                '🎙️ رسائل صوتية مشفرة\n'
                '📸 مشاركة الصور والفيديوهات\n'
                '🌙 وضع مظلم حصري\n'
                '👻 وضع الشبح المتقدم\n'
                '🔒 غرفة سرية بكلمة مرور\n'
                '⏰ حذف تلقائي للرسائل',
                style: TextStyle(color: Colors.white70, height: 1.6),
                textAlign: TextAlign.right,
              ),
              const SizedBox(height: 16),
              const Divider(color: Color(0xFF00FF66)),
              const SizedBox(height: 12),
              const Text(
                'الأذونات المطلوبة:',
                style: TextStyle(
                  color: Color(0xFF00FF66),
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.right,
              ),
              const SizedBox(height: 8),
              const Text(
                '📷 الكاميرا: لمشاركة الصور والفيديوهات\n'
                '🎙️ الميكروفون: للرسائل الصوتية\n'
                '🔔 الإشعارات: للتنبيهات الفورية',
                style: TextStyle(color: Colors.white70, height: 1.6),
                textAlign: TextAlign.right,
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFF00FF66).withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFF00FF66), width: 1),
                ),
                child: const Text(
                  '💾 سيتم حفظ بياناتك بأمان في Firebase\nجميع البيانات مشفرة وآمنة 🔐',
                  style: TextStyle(
                    color: Color(0xFF00FF66),
                    fontSize: 12,
                    height: 1.5,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              try {
                final prefs = await getSafeSharedPreferences();
                if (prefs != null) {
                  await prefs.setBool('has_seen_onboarding', true);
                }

                // مزامنة الحالة مع Firebase
                await _syncOnboardingStatusWithFirebase(true);

                if (dialogContext.mounted) Navigator.pop(dialogContext);
              } catch (error) {
                debugPrint('Error saving onboarding flag: $error');
                if (dialogContext.mounted) Navigator.pop(dialogContext);
              }
            },
            child: const Text(
              'الدخول',
              style: TextStyle(
                color: Color(0xFF00FF66),
                fontWeight: FontWeight.bold,
                fontSize: 16,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _chooseChatToSecure(BuildContext context) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: const Text(
          'اختر دردشة لتأمينها',
          style: TextStyle(color: Colors.white),
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: FirebaseAuth.instance.currentUser == null
                ? null
                : FirebaseFirestore.instance
                    .collection('users')
                    .doc(FirebaseAuth.instance.currentUser!.uid)
                    .collection(contactsCollectionName(ContactScope.regular))
                    .orderBy('updatedAt', descending: true)
                    .snapshots(),
            builder: (context, snapshot) {
              final contacts = snapshot.data?.docs ??
                  const <QueryDocumentSnapshot<Map<String, dynamic>>>[];
              if (contacts.isEmpty) {
                return const Text(
                  'لا توجد دردشات متاحة للتأمين',
                  style: TextStyle(color: Colors.white70),
                );
              }
              return ListView.builder(
                shrinkWrap: true,
                itemCount: contacts.length,
                itemBuilder: (context, index) {
                  final data = contacts[index].data();
                  final chatName = data['displayName'] as String? ?? 'دردشة';
                  return ListTile(
                    leading: const Icon(
                      Icons.chat_bubble_outline,
                      color: Color(0xFF00FF66),
                    ),
                    title: Text(
                      chatName,
                      style: const TextStyle(color: Colors.white),
                    ),
                    onTap: () {
                      Navigator.pop(dialogContext);
                      final currentUid = FirebaseAuth.instance.currentUser?.uid;
                      final chatId = currentUid == null
                          ? chatName
                          : directChatDocumentId(currentUid, contacts[index].id);
                      _setChatPassword(context, chatName, chatId: chatId);
                    },
                  );
                },
              );
            },
          ),
        ),
      ),
    );
  }

  void _setChatPassword(
    BuildContext context,
    String chatName, {
    String? chatId,
  }) {
    final TextEditingController passwordController = TextEditingController();
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: Text(
          'تأمين $chatName',
          style: const TextStyle(color: Color(0xFF00FF66)),
        ),
        content: TextField(
          controller: passwordController,
          obscureText: true,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            hintText: 'اكتب كلمة المرور',
            hintStyle: TextStyle(color: Colors.white54),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('إلغاء', style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () async {
              final String password = passwordController.text.trim();
              if (password.length < 4) return;
              try {
                await saveChatPassword(chatId ?? chatName, password);
              } catch (error) {
                debugPrint('Chat password save error: $error');
                return;
              }
              Navigator.pop(dialogContext);
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(SnackBar(content: Text('تم تأمين $chatName')));
            },
            child: const Text(
              'تأمين',
              style: TextStyle(color: Color(0xFF00FF66)),
            ),
          ),
        ],
      ),
    ).then((_) => passwordController.dispose());
  }

  Future<void> _removeChatContact(String contactUid) async {
    final user = FirebaseAuth.instance.currentUser;
    if (!firebaseReady || user == null || contactUid.isEmpty) return;

    try {
      final firestore = FirebaseFirestore.instance;

      await firestore
          .collection('users')
          .doc(user.uid)
          .collection(contactsCollectionName(ContactScope.regular))
          .doc(contactUid)
          .delete();

      await firestore
          .collection('users')
          .doc(contactUid)
          .collection(contactsCollectionName(ContactScope.regular))
          .doc(user.uid)
          .delete();

      final directChatId = directChatDocumentId(user.uid, contactUid);
      final chatRef = firestore.collection('chats').doc(directChatId);
      final chatSnapshot = await chatRef.get();
      if (chatSnapshot.exists) {
        await chatRef.delete();
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تم حذف الدردشة من Firebase')),
        );
      }
    } catch (error) {
      debugPrint('Chat contact removal error: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final User? user = FirebaseAuth.instance.currentUser;

    return Directionality(
      textDirection: englishLanguageNotifier.value
          ? TextDirection.ltr
          : TextDirection.rtl,
      child: Scaffold(
        body: Stack(
          children: [
            Positioned.fill(
              child: ClipRect(
                child: Transform.scale(
                  scale: MediaQuery.sizeOf(context).width < 600 ? 1.9 : 1.0,
                  child: Image.asset(
                    'assets/images/magic_bg.jpg',
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) => Container(
                      color: const Color(0xFF101716),
                    ),
                  ),
                ),
              ),
            ),
            Positioned.fill(
              child: Container(color: Colors.black.withOpacity(0.5)),
            ),
            Scaffold(
              backgroundColor: Colors.transparent,
              appBar: AppBar(
                backgroundColor: Colors.black.withOpacity(0.6),
                centerTitle: true,
                title: const FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    "✨ 🌑 SHADOW CHAT BETA 🌑 ✨",
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.5,
                    ),
                  ),
                ),
                actions: [
                  IconButton(
                    icon: const Icon(Icons.search, color: Color(0xFF00FF66)),
                    tooltip: appText('بحث', 'Search'),
                    onPressed: () {},
                  ),
                  IconButton(
                    icon: const Icon(Icons.settings, color: Colors.white70),
                    tooltip: 'الإعدادات',
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => const SettingsScreen(),
                        ),
                      );
                    },
                  ),
                ],
              ),
              body: user == null || !firebaseReady
                  ? const Center(
                      child: Text(
                        'يرجى تسجيل الدخول أولاً',
                        style: TextStyle(color: Colors.white70),
                      ),
                    )
                  : StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                      stream: FirebaseFirestore.instance
                          .collection('users')
                          .doc(user.uid)
                          .collection(contactsCollectionName(ContactScope.regular))
                          .orderBy('updatedAt', descending: true)
                          .snapshots(),
                      builder: (context, snapshot) {
                        if (snapshot.hasError) {
                          return Center(
                            child: const Text(
                              'حدثت مشكلة، حاول مرة أخرى',
                              style: TextStyle(color: Colors.white70),
                            ),
                          );
                        }

                        if (!snapshot.hasData) {
                          return const Center(
                            child: CircularProgressIndicator(
                              valueColor: AlwaysStoppedAnimation<Color>(
                                Color(0xFF00FF66),
                              ),
                            ),
                          );
                        }

                        final contacts = (snapshot.data?.docs ??
                          <QueryDocumentSnapshot<Map<String, dynamic>>>[])
                            .where((doc) => !shouldRemoveUnknownContact(doc.data()))
                            .toList();

                        for (final doc in snapshot.data?.docs ?? []) {
                          if (shouldRemoveUnknownContact(doc.data())) {
                            unawaited(_removeChatContact(doc.id));
                          }
                        }

                        if (contacts.isEmpty) {
                          return Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Icon(
                                  Icons.chat_bubble_outline,
                                  color: Color(0xFF00FF66),
                                  size: 48,
                                ),
                                const SizedBox(height: 16),
                                const Text(
                                  'لا توجد دردشات',
                                  style: TextStyle(
                                    color: Colors.white70,
                                    fontSize: 18,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                const Text(
                                  'أضف جهات اتصال جديدة للبدء',
                                  style: TextStyle(
                                    color: Colors.white54,
                                    fontSize: 14,
                                  ),
                                ),
                              ],
                            ),
                          );
                        }

                        return ListView.builder(
                          itemCount: contacts.length,
                          itemBuilder: (context, index) {
                            final contactData = contacts[index].data();
                            final contactName = resolveContactDisplayName(
                              contactData['displayName'],
                              fallback: 'مستخدم',
                            );
                            final lastMessage = contactData['lastMessage'] ?? 'لا توجد رسائل';
                            final contactUid = contacts[index].id;
                            final status = (contactData['status'] as String?) ?? 'pending';
                            final isIncomingRequest = status == 'incoming';
                            final isPendingRequest = status == 'pending';

                            return Dismissible(
                              key: ValueKey('chat-$contactUid'),
                              direction: DismissDirection.endToStart,
                              background: Container(
                                margin: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 4,
                                ),
                                alignment: Alignment.centerLeft,
                                padding: const EdgeInsets.only(left: 20),
                                decoration: BoxDecoration(
                                  color: Colors.redAccent,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: const Icon(
                                  Icons.delete_outline,
                                  color: Colors.white,
                                ),
                              ),
                              onDismissed: (_) {
                                unawaited(_removeChatContact(contactUid));
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('تمت إزالة الدردشة'),
                                  ),
                                  );
                              },
                              child: Container(
                                margin: const EdgeInsets.symmetric(vertical: 4),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF0E1716).withOpacity(0.9),
                                  borderRadius: BorderRadius.circular(16),
                                  border: Border.all(
                                    color: const Color(0xFF1B2D2A),
                                    width: 1,
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: const Color(0xFF00FF66).withOpacity(0.06),
                                      blurRadius: 18,
                                      spreadRadius: 1,
                                    ),
                                  ],
                                ),
                                child: ListTile(
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                    vertical: 8,
                                  ),
                                  leading: CircleAvatar(
                                    radius: 26,
                                    backgroundColor: const Color(0xFF0F2724),
                                    foregroundColor: const Color(0xFFB7FFD8),
                                    child: Text(
                                      contactName.toString().isNotEmpty
                                          ? contactName.toString()[0]
                                          : 'م',
                                      style: const TextStyle(
                                        color: Color(0xFFB7FFD8),
                                        fontSize: 18,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                  title: Text(
                                    contactName.toString(),
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold,
                                      letterSpacing: 0.2,
                                    ),
                                  ),
                                  subtitle: Text(
                                    isIncomingRequest
                                        ? 'طلب اتصال جديد — يحتاج موافقة'
                                        : (isPendingRequest
                                            ? 'طلب تم إرساله — ينتظر الموافقة'
                                            : lastMessage.toString()),
                                    style: TextStyle(
                                      color: isIncomingRequest
                                          ? const Color(0xFFB7FFD8)
                                          : Colors.white70,
                                      fontSize: 12,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  trailing: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      if (isIncomingRequest || isPendingRequest)
                                        Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            if (isIncomingRequest)
                                              Container(
                                              height: 32,
                                              decoration: BoxDecoration(
                                                color: const Color(0xFF00FF66).withOpacity(0.15),
                                                borderRadius: BorderRadius.circular(10),
                                                border: Border.all(
                                                  color: const Color(0xFF00FF66).withOpacity(0.35),
                                                  width: 1,
                                                ),
                                              ),
                                              child: IconButton(
                                                padding: const EdgeInsets.symmetric(horizontal: 12),
                                                constraints: const BoxConstraints(),
                                                icon: const Icon(Icons.check, color: Color(0xFF9BF7C8)),
                                                tooltip: 'قبول',
                                                onPressed: () => _acceptContactRequest(
                                                  contactUid,
                                                  contactName.toString(),
                                                ),
                                              ),
                                            ),
                                            if (isIncomingRequest) const SizedBox(width: 8),
                                            Container(
                                              height: 32,
                                              decoration: BoxDecoration(
                                                color: Colors.redAccent.withOpacity(0.12),
                                                borderRadius: BorderRadius.circular(10),
                                                border: Border.all(
                                                  color: Colors.redAccent.withOpacity(0.28),
                                                  width: 1,
                                                ),
                                              ),
                                              child: IconButton(
                                                padding: const EdgeInsets.symmetric(horizontal: 12),
                                                constraints: const BoxConstraints(),
                                                icon: const Icon(Icons.close, color: Colors.redAccent),
                                                tooltip: isPendingRequest ? 'إلغاء الطلب' : 'رفض الطلب',
                                                onPressed: () => _rejectContactRequest(
                                                  contactUid,
                                                  contactName.toString(),
                                                ),
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                          ],
                                        ),
                                      Container(
                                        height: 32,
                                        decoration: BoxDecoration(
                                          color: Colors.redAccent.withOpacity(0.12),
                                          borderRadius: BorderRadius.circular(10),
                                          border: Border.all(
                                            color: Colors.redAccent.withOpacity(0.28),
                                            width: 1,
                                          ),
                                        ),
                                        child: IconButton(
                                          padding: const EdgeInsets.symmetric(horizontal: 12),
                                          constraints: const BoxConstraints(),
                                          icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                                          tooltip: 'حذف الدردشة',
                                          onPressed: () => _removeChatContact(contactUid),
                                        ),
                                      ),
                                    ],
                                  ),
                                  onTap: () {
                                    if (isIncomingRequest || isPendingRequest) {
                                      return;
                                    }
                                    Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (context) => ChatScreen(
                                          chatName: contactName.toString(),
                                          contactUid: contactUid,
                                        ),
                                      ),
                                    );
                                  },
                                ),
                              ),
                            );
                          },
                        );
                      },
                    ),
              floatingActionButton: Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF00FF66).withOpacity(0.6),
                      blurRadius: 18,
                      spreadRadius: 3,
                    ),
                  ],
                ),
                child: PopupMenuButton<String>(
                  color: Colors.grey[900],
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                    side: const BorderSide(color: Color(0xFF00FF66), width: 1),
                  ),
                  itemBuilder: (BuildContext context) =>
                      <PopupMenuEntry<String>>[
                        const PopupMenuItem<String>(
                          value: 'status',
                          child: Row(
                            children: [
                              Icon(Icons.amp_stories, color: Color(0xFF00FF66)),
                              SizedBox(width: 10),
                              Text(
                                'خيارات الحالة',
                                style: TextStyle(color: Colors.white),
                              ),
                            ],
                          ),
                        ),
                        const PopupMenuItem<String>(
                          value: 'security',
                          child: Row(
                            children: [
                              Icon(Icons.security, color: Colors.cyanAccent),
                              SizedBox(width: 10),
                              Text(
                                'تأمين الدردشة',
                                style: TextStyle(color: Colors.white),
                              ),
                            ],
                          ),
                        ),
                        const PopupMenuItem<String>(
                          value: 'contacts',
                          child: Row(
                            children: [
                              Icon(
                                Icons.person_add_alt_1,
                                color: Colors.amberAccent,
                              ),
                              SizedBox(width: 10),
                              Text(
                                'إضافة جهات اتصال',
                                style: TextStyle(color: Colors.white),
                              ),
                            ],
                          ),
                        ),
                        const PopupMenuItem<String>(
                          value: 'secret_room',
                          child: Row(
                            children: [
                              Icon(Icons.vpn_key, color: Colors.amberAccent),
                              SizedBox(width: 10),
                              Text(
                                'الغرفة السرية (Password)',
                                style: TextStyle(color: Colors.white),
                              ),
                            ],
                          ),
                        ),
                        const PopupMenuItem<String>(
                          value: 'ghost',
                          child: Row(
                            children: [
                              Icon(
                                Icons.visibility_off,
                                color: Colors.purpleAccent,
                              ),
                              SizedBox(width: 10),
                              Text(
                                ' المجموعة السرية (Password)',
                                style: TextStyle(color: Colors.white),
                              ),
                            ],
                          ),
                        ),
                      ],
                  onSelected: (String result) {
                    if (result == 'status') {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('تم فتح خيارات الحالة ✨')),
                      );
                    } else if (result == 'security') {
                      _chooseChatToSecure(context);
                    } else if (result == 'contacts') {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => const ContactsScreen(),
                        ),
                      );
                    } else if (result == 'secret_room') {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => const SecretRoomScreen(),
                        ),
                      );
                    } else if (result == 'ghost') {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => const SecretGroupsScreen(),
                        ),
                      );
                    }
                  },
                  child: FloatingActionButton(
                    onPressed: null,
                    backgroundColor: Colors.black,
                    elevation: 0,
                    highlightElevation: 0,
                    shape: const CircleBorder(
                      side: BorderSide(color: Color(0xFF00FF66), width: 2),
                    ),
                    child: const Icon(
                      Icons.fingerprint,
                      color: Color(0xFF00FF66),
                      size: 28,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ==========================================
// 2. شاشة الغرفة السرية
// ==========================================
class SecretRoomScreen extends StatefulWidget {
  const SecretRoomScreen({super.key});

  @override
  State<SecretRoomScreen> createState() => _SecretRoomScreenState();
}

enum ContactScope { regular, group, room }

String contactsCollectionName(ContactScope scope) {
  switch (scope) {
    case ContactScope.regular:
      return 'regularContacts';
    case ContactScope.group:
      return 'groupContacts';
    case ContactScope.room:
      return 'roomContacts';
  }
}

String secretGroupRoomId(String ownerUid) => 'secret_group_$ownerUid';

bool shouldShowSecretGroupsEmptyState({
  required bool isPreparing,
  required int groupsCount,
}) {
  return !isPreparing && groupsCount == 0;
}

Future<String> createSecretGroup({required String title}) async {
  final user = FirebaseAuth.instance.currentUser;
  if (!firebaseReady || user == null) {
    throw StateError('يلزم تسجيل الدخول لإنشاء مجموعة');
  }

  final firestore = FirebaseFirestore.instance;
  final roomId =
      'secret_group_${user.uid}_${firestore.collection('rooms').doc().id}';
  final groupTitle = sanitizeDisplayName(title);
  final roomRef = firestore.collection('rooms').doc(roomId);
  await roomRef.set({
    'ownerUid': user.uid,
    'title': groupTitle,
    'updatedAt': FieldValue.serverTimestamp(),
  });

  final ownerMembershipRef = roomRef.collection('members').doc(user.uid);
  final groupIndexRef = firestore
      .collection('users')
      .doc(user.uid)
      .collection('secretGroups')
      .doc(roomId);
  final batch = firestore.batch();
  batch.set(ownerMembershipRef, {
    'displayName': user.displayName ?? currentPublicUserId ?? 'مالك المجموعة',
    'addedBy': user.uid,
    'role': 'owner',
    'addedAt': FieldValue.serverTimestamp(),
  });
  batch.set(groupIndexRef, {
    'roomId': roomId,
    'ownerUid': user.uid,
    'title': groupTitle,
    'updatedAt': FieldValue.serverTimestamp(),
  });
  await batch.commit();
  return roomId;
}

class SecretGroupsScreen extends StatefulWidget {
  const SecretGroupsScreen({super.key});

  @override
  State<SecretGroupsScreen> createState() => _SecretGroupsScreenState();
}

class _SecretGroupsScreenState extends State<SecretGroupsScreen> {
  bool _isPreparingGroups = false;
  final Set<String> _busyGroupIds = <String>{};

  Future<void> _deleteOrLeaveGroup({
    required String roomId,
    required String title,
    required bool isOwner,
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || !firebaseReady || _busyGroupIds.contains(roomId)) return;

    final actionLabel = isOwner ? 'حذف المجموعة' : 'مغادرة المجموعة';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          backgroundColor: const Color(0xFF171D26),
          title: Text(actionLabel, style: const TextStyle(color: Colors.white)),
          content: Text(
            isOwner
                ? 'سيتم حذف "$title" وأعضائها نهائيًا. هل تريد المتابعة؟'
                : 'هل تريد مغادرة "$title"؟',
            style: const TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              style: FilledButton.styleFrom(
                backgroundColor: Colors.redAccent,
                foregroundColor: Colors.white,
              ),
              child: Text(actionLabel),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _busyGroupIds.add(roomId));
    try {
      final firestore = FirebaseFirestore.instance;
      final roomRef = firestore.collection('rooms').doc(roomId);
      final groupIndexRef = firestore
          .collection('users')
          .doc(user.uid)
          .collection('secretGroups')
          .doc(roomId);

      if (isOwner) {
        final members = await roomRef.collection('members').get();
        final messages = await firestore
            .collection('chats')
            .doc(roomId)
            .collection('messages')
            .get();

        for (var start = 0; start < messages.docs.length; start += 400) {
          final batch = firestore.batch();
          final end = (start + 400).clamp(0, messages.docs.length);
          for (final message in messages.docs.sublist(start, end)) {
            batch.delete(message.reference);
          }
          await batch.commit();
        }

        final batch = firestore.batch();
        for (final member in members.docs) {
          batch.delete(member.reference);
        }
        batch.delete(groupIndexRef);
        batch.delete(firestore.collection('chats').doc(roomId));
        batch.delete(roomRef);
        await batch.commit();
      } else {
        await roomRef.collection('members').doc(user.uid).delete();
        await groupIndexRef.delete();
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(isOwner ? 'تم حذف المجموعة' : 'تمت مغادرة المجموعة')),
        );
      }
    } catch (error) {
      debugPrint('Secret group removal failed: $error');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(firebaseWriteFailureMessage(error)),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busyGroupIds.remove(roomId));
    }
  }

  Future<void> _createSecretGroup() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || !firebaseReady) return;

    final titleController = TextEditingController();
    final groupTitle = await showDialog<String>(
      context: context,
      builder: (dialogContext) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          backgroundColor: const Color(0xFF171D26),
          title: const Text(
            'إنشاء مجموعة جديدة',
            style: TextStyle(color: Colors.white),
          ),
          content: TextField(
            controller: titleController,
            autofocus: true,
            maxLength: 60,
            textCapitalization: TextCapitalization.sentences,
            style: const TextStyle(color: Colors.white),
            decoration: const InputDecoration(
              labelText: 'اسم المجموعة',
              prefixIcon: Icon(Icons.groups_rounded),
            ),
            onSubmitted: (value) {
              final cleanedTitle = sanitizeDisplayName(value);
              if (cleanedTitle.isNotEmpty) {
                Navigator.pop(dialogContext, cleanedTitle);
              }
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('إلغاء'),
            ),
            FilledButton.icon(
              onPressed: () {
                final cleanedTitle =
                    sanitizeDisplayName(titleController.text);
                if (cleanedTitle.isNotEmpty) {
                  Navigator.pop(dialogContext, cleanedTitle);
                }
              },
              icon: const Icon(Icons.add_rounded),
              label: const Text('إنشاء'),
            ),
          ],
        ),
      ),
    );
    titleController.dispose();
    if (!mounted || groupTitle == null) return;

    try {
      setState(() => _isPreparingGroups = true);
      final roomId = await createSecretGroup(title: groupTitle);

      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => SecretChatScreen(
            groupId: roomId,
            chatTitle: groupTitle,
          ),
        ),
      );
    } catch (error) {
      debugPrint('Create secret group failed: $error');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(firebaseWriteFailureMessage(error)),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isPreparingGroups = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: const Color(0xFF0D1117),
        appBar: AppBar(
          title: const Text('مجموعاتي السرية'),
          backgroundColor: const Color(0xFF111827),
          foregroundColor: Colors.white,
          elevation: 0,
          actions: [
            Padding(
              padding: const EdgeInsets.only(left: 12),
              child: IconButton(
                tooltip: 'إنشاء مجموعة سرية',
                onPressed: _isPreparingGroups ? null : _createSecretGroup,
                icon: const Icon(Icons.add_rounded, color: Color(0xFF00FF66)),
              ),
            ),
          ],
        ),
        body: user == null || !firebaseReady
            ? const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'يلزم الاتصال بالتطبيق أولًا',
                    style: TextStyle(color: Colors.white70),
                  ),
                ),
              )
            : StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                stream: FirebaseFirestore.instance
                    .collection('users')
                    .doc(user.uid)
                    .collection('secretGroups')
                    .orderBy('updatedAt', descending: true)
                    .snapshots(),
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    return const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.error_outline_rounded, color: Colors.redAccent, size: 48),
                            SizedBox(height: 12),
                            Text(
                              'تعذر تحميل المجموعات',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: Colors.white70),
                            ),
                          ],
                        ),
                      ),
                    );
                  }
                  if (!snapshot.hasData) {
                    return const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            CircularProgressIndicator(color: Color(0xFF00FF66)),
                            SizedBox(height: 16),
                            Text(
                              'جارٍ تجهيز مجموعاتك...',
                              style: TextStyle(color: Colors.white70),
                            ),
                          ],
                        ),
                      ),
                    );
                  }

                  final groups = snapshot.data!.docs;
                  if (shouldShowSecretGroupsEmptyState(
                    isPreparing: _isPreparingGroups,
                    groupsCount: groups.length,
                  )) {
                    return Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Container(
                          padding: const EdgeInsets.all(24),
                          decoration: BoxDecoration(
                            color: const Color(0xFF161C2A),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: Colors.white12),
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.lock_outline_rounded,
                                size: 58,
                                color: Color(0xFF00FF66),
                              ),
                              const SizedBox(height: 16),
                              const Text(
                                'لا توجد مجموعات بعد',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 20,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'سيظهر هنا كل ما تنشئه أو تنضم إليه في المستقبل.',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: Colors.white.withOpacity(0.7),
                                  fontSize: 14,
                                ),
                              ),
                              const SizedBox(height: 20),
                              SizedBox(
                                width: 210,
                                child: ElevatedButton.icon(
                                  onPressed: _isPreparingGroups ? null : _createSecretGroup,
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: const Color(0xFF00FF66),
                                    foregroundColor: Colors.black,
                                    padding: const EdgeInsets.symmetric(vertical: 14),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(14),
                                    ),
                                  ),
                                  icon: const Icon(Icons.lock_open_rounded),
                                  label: const Text(
                                    'إنشاء مجموعة جديدة',
                                    style: TextStyle(fontWeight: FontWeight.w700),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  }

                  return ListView.separated(
                    padding: const EdgeInsets.all(12),
                    itemCount: groups.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 10),
                    itemBuilder: (context, index) {
                      final group = groups[index];
                      final data = group.data();
                      final roomId = data['roomId'] as String? ?? group.id;
                      final title = data['title'] as String? ?? 'مجموعة سرية';
                      final isOwner = data['ownerUid'] == user.uid;
                      final isBusy = _busyGroupIds.contains(roomId);

                      return Container(
                        decoration: BoxDecoration(
                          color: const Color(0xFF161C2A),
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(color: Colors.white12),
                          boxShadow: const [
                            BoxShadow(
                              color: Color(0x1A000000),
                              blurRadius: 10,
                              offset: Offset(0, 4),
                            ),
                          ],
                        ),
                        child: ListTile(
                              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                              leading: const CircleAvatar(
                                radius: 22,
                                backgroundColor: Color(0xFF0F172A),
                                child: Icon(Icons.lock_rounded, color: Color(0xFF00FF66)),
                              ),
                              title: Text(
                                title,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              subtitle: Text(
                                isOwner ? 'مجموعتك الخاصة' : 'مجموعة تمت دعوتك إليها',
                                style: const TextStyle(color: Colors.white70),
                              ),
                              trailing: isBusy
                                  ? const SizedBox(
                                      width: 22,
                                      height: 22,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Color(0xFF00FF66),
                                      ),
                                    )
                                  : Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        IconButton(
                                          onPressed: () => _deleteOrLeaveGroup(
                                            roomId: roomId,
                                            title: title,
                                            isOwner: isOwner,
                                          ),
                                          icon: Icon(
                                            isOwner
                                                ? Icons.delete_outline_rounded
                                                : Icons.logout_rounded,
                                            color: Colors.redAccent,
                                          ),
                                          tooltip: isOwner
                                              ? 'حذف المجموعة'
                                              : 'مغادرة المجموعة',
                                        ),
                                        const Icon(
                                          Icons.chevron_left_rounded,
                                          color: Colors.white70,
                                        ),
                                      ],
                                    ),
                              onTap: () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => SecretChatScreen(
                                    groupId: roomId,
                                    chatTitle: title,
                                  ),
                                ),
                              ),
                        ),
                      );
                    },
                  );
                },
              ),
      ),
    );
  }
}

class _AppUsersInfoState extends StatelessWidget {
  final String message;
  final IconData? icon;
  final bool isLoading;
  final String? actionLabel;
  final VoidCallback? onAction;

  const _AppUsersInfoState({
    required this.message,
    this.icon,
    this.isLoading = false,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF14231F),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (isLoading)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Color(0xFF38E8A5),
                  ),
                )
              else
                Icon(icon ?? Icons.info_outline_rounded, color: Colors.white54, size: 18),
              const SizedBox(width: 9),
              Flexible(
                child: Text(
                  message,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ),
            ],
          ),
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: onAction,
              icon: const Icon(Icons.badge_outlined, size: 17),
              label: Text(actionLabel!),
            ),
          ],
        ],
      ),
    );
  }
}

class ContactsScreen extends StatefulWidget {
  final ContactScope scope;
  final bool ownerVerified;
  final String? roomId;

  const ContactsScreen({
    super.key,
    this.scope = ContactScope.regular,
    this.ownerVerified = false,
    this.roomId,
  });

  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen> {
  final TextEditingController _contactIdController = TextEditingController();
  final TextEditingController _nameController = TextEditingController();
  final ScrollController _headerScrollController = ScrollController();
  final Set<String> _sendingRequestUids = <String>{};
  bool _isConfiguredOwner = false;
  bool _checkingOwnerPermission = false;

  bool get _canAddScopedContacts =>
      widget.scope == ContactScope.regular ||
      widget.scope == ContactScope.group ||
      !firebaseReady ||
      _isConfiguredOwner;

  @override
  void initState() {
    super.initState();
    if (widget.scope == ContactScope.room) {
      _isConfiguredOwner = widget.ownerVerified;
      unawaited(refreshSecretRoomMemberNotifier());
    }
  }

  Future<void> _loadGroupOwnerPermission() async {
    final user = FirebaseAuth.instance.currentUser;
    if (!firebaseReady || user == null) return;
    if (mounted) setState(() => _checkingOwnerPermission = true);
    try {
      final ownerSnapshot = await FirebaseFirestore.instance
          .collection('config')
          .doc('app')
          .get();
      if (mounted) {
        setState(() {
          _isConfiguredOwner = ownerSnapshot.data()?['ownerUid'] == user.uid;
        });
      }
    } catch (error) {
      debugPrint('Group owner verification error: $error');
    } finally {
      if (mounted) setState(() => _checkingOwnerPermission = false);
    }
  }

  @override
  void dispose() {
    _contactIdController.dispose();
    _nameController.dispose();
    _headerScrollController.dispose();
    super.dispose();
  }

  Future<void> _saveLocalContactEntry({
    required String targetUid,
    required String displayName,
    required String publicId,
  }) async {
    final preferences = await getSafeSharedPreferences();
    if (preferences == null) return;
    final key = 'local_contacts_${widget.scope.name}';
    final existing = preferences.getStringList(key) ?? const <String>[];
    final decoded = existing
        .map((item) => jsonDecode(item))
        .whereType<Map<String, dynamic>>()
        .toList();
    final entry = {
      'contactId': publicId,
      'uid': targetUid,
      'displayName': displayName.isEmpty ? 'جهة اتصال' : displayName,
      'name': displayName.isEmpty ? 'جهة اتصال' : displayName,
      'lastMessage': 'لا توجد رسائل',
      'updatedAt': DateTime.now().toIso8601String(),
    };
    final index = decoded.indexWhere((item) => item['uid'] == targetUid);
    if (index >= 0) {
      decoded[index] = entry;
    } else {
      decoded.add(entry);
    }
    await preferences.setStringList(
      key,
      decoded.map((item) => jsonEncode(item)).toList(),
    );
  }

  Future<void> _saveContactRelationship({
    required String targetUid,
    required String displayName,
    required String publicId,
    String status = 'accepted',
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (targetUid.isEmpty) return;

    if (!firebaseReady || user == null) {
      await _saveLocalContactEntry(
        targetUid: targetUid,
        displayName: displayName,
        publicId: publicId,
      );
      return;
    }

    final contactData = {
      'contactId': publicId,
      'uid': targetUid,
      'displayName': displayName.isEmpty ? 'جهة اتصال' : displayName,
      'lastMessage': status == 'pending' ? 'طلب اتصال في انتظار الموافقة' : 'لا توجد رسائل',
      'name': displayName.isEmpty ? 'جهة اتصال' : displayName,
      'status': status,
      'updatedAt': FieldValue.serverTimestamp(),
      'createdAt': FieldValue.serverTimestamp(),
    };

    final groupId = widget.scope == ContactScope.group
        ? widget.roomId ?? secretGroupRoomId(user.uid)
        : null;
    if (widget.scope != ContactScope.regular) {
      final roomId = groupId ?? 'secret_room';
      if (widget.scope == ContactScope.room) {
        await addSecretRoomMember(
          targetUid: targetUid,
          displayName: displayName.isEmpty ? 'جهة اتصال' : displayName,
        );
      } else {
        final firestore = FirebaseFirestore.instance;
        final roomSnapshot = await firestore.collection('rooms').doc(roomId).get();
        if (!roomSnapshot.exists) {
          throw StateError('المجموعة الخاصة غير موجودة');
        }
        final memberRef = firestore
            .collection('rooms')
            .doc(roomId)
            .collection('members')
            .doc(targetUid);
        final memberSnapshot = await memberRef.get();
        if (!memberSnapshot.exists) {
          await memberRef.set({
            'displayName': displayName.isEmpty ? 'جهة اتصال' : displayName,
            'addedBy': user.uid,
            'addedAt': FieldValue.serverTimestamp(),
          });
        }
        final roomData = roomSnapshot.data() ?? {};
        await firestore
            .collection('users')
            .doc(targetUid)
            .collection('secretGroups')
            .doc(roomId)
            .set({
              'roomId': roomId,
              'ownerUid': roomData['ownerUid'],
              'title': roomData['title'] ?? 'مجموعة سرية',
              'updatedAt': FieldValue.serverTimestamp(),
            });
      }
    }

    final contactEntryId = groupId == null ? targetUid : '${groupId}_$targetUid';
    await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .collection(contactsCollectionName(widget.scope))
        .doc(contactEntryId)
        .set({
          ...contactData,
          if (groupId != null) 'roomId': groupId,
        }, SetOptions(merge: true));
  }

  String _regularContactDecision({
    required String myStatus,
    required String otherStatus,
  }) {
    return determineRegularContactAction(
      myStatus: myStatus,
      otherStatus: otherStatus,
    );
  }

  Future<bool> _hasApprovedDirectContact(String targetUid) async {
    final user = FirebaseAuth.instance.currentUser;
    if (!firebaseReady || user == null || targetUid.isEmpty) return false;

    try {
      final myDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .collection(contactsCollectionName(ContactScope.regular))
          .doc(targetUid)
          .get();
      final otherDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(targetUid)
          .collection(contactsCollectionName(ContactScope.regular))
          .doc(user.uid)
          .get();

      final myStatus = (myDoc.data()?['status'] as String?) ?? 'none';
      final otherStatus = (otherDoc.data()?['status'] as String?) ?? 'none';
      return _regularContactDecision(myStatus: myStatus, otherStatus: otherStatus) == 'accepted';
    } catch (error) {
      debugPrint('Approved contact check error: $error');
      return false;
    }
  }

  Future<void> _acceptContactRequest(String contactUid, String displayName) async {
    final user = FirebaseAuth.instance.currentUser;
    if (!firebaseReady || user == null || contactUid.isEmpty) return;

    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .collection(contactsCollectionName(ContactScope.regular))
          .doc(contactUid)
          .set({
            'status': 'accepted',
            'lastMessage': 'تمت الموافقة على الدردشة',
            'updatedAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));

      await FirebaseFirestore.instance
          .collection('users')
          .doc(contactUid)
          .collection(contactsCollectionName(ContactScope.regular))
          .doc(user.uid)
          .set({
            'status': 'accepted',
            'lastMessage': 'تمت الموافقة على الدردشة',
            'updatedAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('تمت الموافقة على $displayName')),
        );
      }
    } catch (error) {
      debugPrint('Accept contact request error: $error');
    }
  }

  Future<void> _rejectContactRequest(String contactUid, String displayName) async {
    final user = FirebaseAuth.instance.currentUser;
    if (!firebaseReady || user == null || contactUid.isEmpty) return;

    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .collection(contactsCollectionName(ContactScope.regular))
          .doc(contactUid)
          .set({
            'status': 'rejected',
            'lastMessage': 'تم رفض طلب الاتصال',
            'updatedAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));

      await FirebaseFirestore.instance
          .collection('users')
          .doc(contactUid)
          .collection(contactsCollectionName(ContactScope.regular))
          .doc(user.uid)
          .set({
            'status': 'rejected',
            'lastMessage': 'تم رفض طلب الاتصال',
            'updatedAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('تم رفض طلب $displayName')),
        );
      }
    } catch (error) {
      debugPrint('Reject contact request error: $error');
    }
  }

  Future<void> _addContact() async {
    final input = _contactIdController.text.trim();
    final String publicId = input.toUpperCase();
    final String name = _nameController.text.trim();
    final User? user = FirebaseAuth.instance.currentUser;
    if (input.isEmpty) return;
    if (!_canAddScopedContacts) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('إضافة أعضاء الغرفة متاحة لمالك التطبيق فقط')),
      );
      return;
    }

    if (!firebaseReady || user == null) {
      final targetUid = publicId.isEmpty ? 'local_${DateTime.now().millisecondsSinceEpoch}' : publicId;
      await _saveContactRelationship(
        targetUid: targetUid,
        displayName: name.isEmpty ? 'جهة اتصال محلية' : name,
        publicId: publicId.isEmpty ? targetUid : publicId,
      );
      _contactIdController.clear();
      _nameController.clear();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تمت إضافة جهة الاتصال محليًا')),
        );
      }
      return;
    }

    try {
      QuerySnapshot<Map<String, dynamic>> matchingUsers;
      if (input.startsWith('+') || RegExp(r'^[0-9٠-٩ ()-]+$').hasMatch(input)) {
        final phoneKey = _phoneMatchKey(input);
        matchingUsers = await FirebaseFirestore.instance
          .collection('publicProfiles')
            .where('phoneSearchKey', isEqualTo: phoneKey)
            .limit(1)
            .get()
            .timeout(const Duration(seconds: 12));
      } else {
        matchingUsers = await FirebaseFirestore.instance
          .collection('publicProfiles')
            .where('publicId', isEqualTo: publicId)
            .limit(1)
            .get()
            .timeout(const Duration(seconds: 12));
      }
      if (matchingUsers.docs.isEmpty) {
        if (mounted)
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('لم يتم العثور على حساب بهذا المعرّف أو الرقم'),
            ),
          );
        return;
      }

      final targetUid = matchingUsers.docs.first.id;
      if (targetUid == user.uid) {
        return;
      }

      final resolvedDisplayName = name.isEmpty
          ? (matchingUsers.docs.first.data()['displayName'] as String? ??
              'جهة اتصال')
          : name;
      final resolvedPublicId =
          matchingUsers.docs.first.data()['publicId'] as String? ?? targetUid;
      if (widget.scope != ContactScope.regular) {
        await _saveContactRelationship(
          targetUid: targetUid,
          displayName: resolvedDisplayName,
          publicId: resolvedPublicId,
          status: 'accepted',
        );
        _contactIdController.clear();
        _nameController.clear();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('تمت إضافة العضو بنجاح')),
          );
        }
        return;
      }

      final myDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .collection(contactsCollectionName(ContactScope.regular))
          .doc(targetUid)
          .get();
      final otherDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(targetUid)
          .collection(contactsCollectionName(ContactScope.regular))
          .doc(user.uid)
          .get();
      final action = _regularContactDecision(
        myStatus: (myDoc.data()?['status'] as String?) ?? 'none',
        otherStatus: (otherDoc.data()?['status'] as String?) ?? 'none',
      );

      if (action == 'accepted') {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('أنت بالفعل متصل بهذا المستخدم')),
          );
        }
        return;
      }
      if (action == 'pending') {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('طلب الإضافة لهذا المستخدم قيد الانتظار بالفعل')),
          );
        }
        return;
      }
      if (action == 'incoming') {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('هذا المستخدم أرسل لك طلب اتصال بالفعل')),
          );
        }
        return;
      }

      await _saveContactRelationship(
        targetUid: targetUid,
        displayName: resolvedDisplayName,
        publicId: resolvedPublicId,
        status: 'pending',
      );

      await FirebaseFirestore.instance
          .collection('users')
          .doc(targetUid)
          .collection(contactsCollectionName(ContactScope.regular))
          .doc(user.uid)
          .set({
            'contactId': user.uid,
            'uid': user.uid,
            'displayName': user.displayName ?? 'مستخدم',
            'name': user.displayName ?? 'مستخدم',
            'lastMessage': 'طلب اتصال جديد',
            'status': 'incoming',
            'updatedAt': FieldValue.serverTimestamp(),
            'createdAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));

      _contactIdController.clear();
      _nameController.clear();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تم إرسال طلب الموافقة إلى جهة الاتصال')),
        );
      }
    } catch (error) {
      debugPrint('Contact save error: $error');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(firebaseWriteFailureMessage(error)),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }
  }

  String _normalizePhone(String phone) {
    final arabicDigits = '٠١٢٣٤٥٦٧٨٩';
    var normalized = phone;
    for (var index = 0; index < arabicDigits.length; index++) {
      normalized = normalized.replaceAll(arabicDigits[index], index.toString());
    }
    return normalized.replaceAll(RegExp(r'[^0-9+]'), '');
  }

  String _phoneMatchKey(String phone) {
    return _phoneSearchKey(phone);
  }

  Future<void> _addAppUserByTap(String targetUid, String publicId, String displayName) async {
    final user = FirebaseAuth.instance.currentUser;
    if (!firebaseReady || user == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('يحتاج التطبيق إلى اتصال Firebase لإضافة مستخدم من التطبيق')),
        );
      }
      return;
    }
    if (!_canAddScopedContacts) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('إضافة أعضاء الغرفة متاحة لمالك التطبيق فقط')),
      );
      return;
    }
    if (targetUid == user.uid) {
      return;
    }
    if (_sendingRequestUids.contains(targetUid)) return;
    final safeTargetName = resolveContactDisplayName(
      displayName,
      fallback: publicId,
    );
    final safeRequestSenderName = resolveContactDisplayName(
      user.displayName,
      fallback: 'مستخدم',
    );
    setState(() => _sendingRequestUids.add(targetUid));

    try {
      if (widget.scope != ContactScope.regular) {
        await _saveContactRelationship(
          targetUid: targetUid,
          displayName: safeTargetName,
          publicId: publicId,
          status: 'accepted',
        );
        if (mounted) {
          final sectionName = widget.scope == ContactScope.group
              ? 'المجموعة'
              : 'الغرفة';
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('تمت إضافة $safeTargetName إلى $sectionName')),
          );
          if (widget.scope == ContactScope.group && Navigator.of(context).canPop()) {
            Navigator.of(context).pop();
          }
        }
        return;
      }

      final myExisting = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .collection(contactsCollectionName(ContactScope.regular))
          .doc(targetUid)
          .get();
      final otherExisting = await FirebaseFirestore.instance
          .collection('users')
          .doc(targetUid)
          .collection(contactsCollectionName(ContactScope.regular))
          .doc(user.uid)
          .get();
      final action = _regularContactDecision(
        myStatus: (myExisting.data()?['status'] as String?) ?? 'none',
        otherStatus: (otherExisting.data()?['status'] as String?) ?? 'none',
      );

      if (action == 'accepted') {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('أنت بالفعل لديك صلاحية الدردشة مع $safeTargetName')),
          );
        }
        return;
      }
      if (action == 'pending') {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('طلب الإضافة إلى $safeTargetName موجود بالفعل في الانتظار')),
          );
        }
        return;
      }
      if (action == 'incoming') {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('لدى $safeTargetName طلب اتصال موجود بالفعل')),
          );
        }
        return;
      }

      await _saveContactRelationship(
        targetUid: targetUid,
        displayName: safeTargetName,
        publicId: publicId,
        status: 'pending',
      );

      await FirebaseFirestore.instance
          .collection('users')
          .doc(targetUid)
          .collection(contactsCollectionName(ContactScope.regular))
          .doc(user.uid)
          .set({
            'contactId': user.uid,
            'uid': user.uid,
            'displayName': safeRequestSenderName,
            'name': safeRequestSenderName,
            'lastMessage': 'طلب اتصال جديد',
            'status': 'incoming',
            'updatedAt': FieldValue.serverTimestamp(),
            'createdAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('تم إرسال طلب الموافقة إلى $safeTargetName')),
        );
      }
    } catch (error) {
      debugPrint('One-tap add request error: $error');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(firebaseWriteFailureMessage(error)),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _sendingRequestUids.remove(targetUid));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.scope == ContactScope.room && !widget.ownerVerified) {
      return const Scaffold(
        body: Center(child: Text('يجب التحقق من مفتاح المالك أولًا')),
      );
    }
    final User? user = FirebaseAuth.instance.currentUser;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: const Color(0xFF07110F),
        appBar: AppBar(
          title: Text(
            widget.scope == ContactScope.regular
                ? 'جهات اتصال الشات'
                : widget.scope == ContactScope.group
                ? 'جهات اتصال المجموعة'
                : 'جهات اتصال الغرفة',
          ),
          backgroundColor: Theme.of(context).appBarTheme.backgroundColor,
          iconTheme: const IconThemeData(color: Color(0xFF38E8A5)),
        ),
        body: Column(
          children: [
            Flexible(
              fit: FlexFit.loose,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(context).height * 0.52,
                ),
                child: Scrollbar(
                  controller: _headerScrollController,
                  thumbVisibility: true,
                  child: SingleChildScrollView(
                    controller: _headerScrollController,
                    padding: const EdgeInsets.all(16),
                    child: Column(
                children: [
                  if (user != null)
                    ValueListenableBuilder<String?>(
                      valueListenable: publicUserIdNotifier,
                      builder: (context, publicId, child) {
                        return SelectableText(
                          'معرّفك السهل: ${publicId ?? 'جارٍ التحميل...'}',
                          style: const TextStyle(
                            color: Color(0xFF38E8A5),
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                          ),
                        );
                      },
                    ),
                  const SizedBox(height: 8),
                  if (firebaseReady && _canAddScopedContacts)
                    StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                      stream: FirebaseFirestore.instance
                          .collection('publicProfiles')
                          .snapshots(),
                      builder: (context, snapshot) {
                        return Container(
                          margin: const EdgeInsets.only(bottom: 12),
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: const Color(0xFF0F1C1A),
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(
                              color: const Color(0xFF38E8A5).withOpacity(0.22),
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Container(
                                    width: 38,
                                    height: 38,
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF38E8A5).withOpacity(0.12),
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: const Icon(
                                      Icons.person_add_alt_1_rounded,
                                      color: Color(0xFF38E8A5),
                                      size: 20,
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  const Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          'إضافة من مستخدمي التطبيق',
                                          style: TextStyle(
                                            color: Colors.white,
                                            fontWeight: FontWeight.w700,
                                            fontSize: 14,
                                          ),
                                        ),
                                        SizedBox(height: 3),
                                        Text(
                                          'اختر مستخدمًا للإضافة مباشرة',
                                          style: TextStyle(
                                            color: Colors.white54,
                                            fontSize: 12,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              if (snapshot.hasError)
                                const _AppUsersInfoState(
                                  icon: Icons.wifi_off_rounded,
                                  message: 'تعذر تحميل المستخدمين الآن',
                                )
                              else if (!snapshot.hasData)
                                const _AppUsersInfoState(
                                  isLoading: true,
                                  message: 'جارٍ تحميل المستخدمين...',
                                )
                              else ...[
                                Builder(
                                  builder: (context) {
                                    final currentUserId = FirebaseAuth.instance.currentUser?.uid;
                                    final appUsers = snapshot.data!.docs
                                        .where((doc) => doc.id != currentUserId)
                                        .toList()
                                      ..sort((first, second) {
                                        final firstUpdatedAt =
                                            first.data()['updatedAt'];
                                        final secondUpdatedAt =
                                            second.data()['updatedAt'];
                                        if (firstUpdatedAt is Timestamp &&
                                            secondUpdatedAt is Timestamp) {
                                          return secondUpdatedAt.compareTo(
                                            firstUpdatedAt,
                                          );
                                        }
                                        if (firstUpdatedAt is Timestamp) return -1;
                                        if (secondUpdatedAt is Timestamp) return 1;
                                        return first.id.compareTo(second.id);
                                      });
                                    if (appUsers.isEmpty) {
                                      return _AppUsersInfoState(
                                        icon: Icons.group_off_rounded,
                                        message:
                                            'لا يوجد مستخدمون آخرون مسجلون حاليًا. أضف المستخدم بمعرّفه من النموذج أدناه.',
                                        actionLabel: 'الإضافة بالمعرّف',
                                        onAction: () {
                                          _headerScrollController.animateTo(
                                            _headerScrollController.position.maxScrollExtent,
                                            duration: const Duration(milliseconds: 350),
                                            curve: Curves.easeOut,
                                          );
                                        },
                                      );
                                    }

                                    return Column(
                                      children: [
                                        Align(
                                          alignment: Alignment.centerRight,
                                          child: Text(
                                            '${appUsers.length} مستخدم',
                                            style: const TextStyle(
                                              color: Colors.white54,
                                              fontSize: 12,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(height: 8),
                                        SizedBox(
                                          height: 300,
                                          child: ListView.separated(
                                            primary: false,
                                            cacheExtent: 120,
                                            itemCount: appUsers.length,
                                            separatorBuilder: (_, __) =>
                                                const SizedBox(height: 8),
                                            itemBuilder: (context, index) {
                                          final doc = appUsers[index];
                                          final data = doc.data();
                                          final publicId = (data['publicId'] as String?) ?? doc.id;
                                          final displayName = (data['displayName'] as String?) ?? 'مستخدم';
                                          final isSending = _sendingRequestUids.contains(doc.id);
                                          return Container(
                                            margin: const EdgeInsets.only(bottom: 8),
                                            padding: const EdgeInsetsDirectional.only(
                                              start: 10,
                                              end: 6,
                                              top: 9,
                                              bottom: 9,
                                            ),
                                            decoration: BoxDecoration(
                                              color: const Color(0xFF14231F),
                                              borderRadius: BorderRadius.circular(14),
                                              border: Border.all(color: Colors.white10),
                                            ),
                                            child: Row(
                                              children: [
                                                CircleAvatar(
                                                  radius: 20,
                                                  backgroundColor: const Color(0xFF38E8A5).withOpacity(0.14),
                                                  child: Text(
                                                    displayName.trim().isEmpty
                                                        ? '؟'
                                                        : String.fromCharCode(displayName.runes.first),
                                                    style: const TextStyle(
                                                      color: Color(0xFF38E8A5),
                                                      fontWeight: FontWeight.w700,
                                                    ),
                                                  ),
                                                ),
                                                const SizedBox(width: 10),
                                                Expanded(
                                                  child: Column(
                                                    crossAxisAlignment: CrossAxisAlignment.start,
                                                    children: [
                                                      Text(
                                                        displayName,
                                                        maxLines: 1,
                                                        overflow: TextOverflow.ellipsis,
                                                        style: const TextStyle(
                                                          color: Colors.white,
                                                          fontWeight: FontWeight.w600,
                                                          fontSize: 14,
                                                        ),
                                                      ),
                                                      const SizedBox(height: 3),
                                                      Text(
                                                        publicId,
                                                        maxLines: 1,
                                                        overflow: TextOverflow.ellipsis,
                                                        style: const TextStyle(
                                                          color: Colors.white54,
                                                          fontSize: 11,
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                                const SizedBox(width: 6),
                                                FilledButton.tonalIcon(
                                                  onPressed: isSending
                                                      ? null
                                                      : () => _addAppUserByTap(
                                                            doc.id,
                                                            publicId,
                                                            displayName,
                                                          ),
                                                  icon: isSending
                                                      ? const SizedBox(
                                                          width: 15,
                                                          height: 15,
                                                          child: CircularProgressIndicator(
                                                            strokeWidth: 2,
                                                          ),
                                                        )
                                                      : const Icon(
                                                          Icons.person_add_alt_1_rounded,
                                                          size: 16,
                                                        ),
                                                  label: Text(
                                                    isSending
                                                        ? 'جارٍ الإرسال'
                                                        : widget.scope == ContactScope.regular
                                                            ? 'طلب'
                                                            : 'إضافة',
                                                  ),
                                                  style: FilledButton.styleFrom(
                                                    foregroundColor: const Color(0xFF38E8A5),
                                                    backgroundColor: const Color(0xFF38E8A5).withOpacity(0.12),
                                                    padding: const EdgeInsets.symmetric(horizontal: 10),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          );
                                            },
                                          ),
                                        ),
                                      ],
                                    );
                                  },
                                ),
                              ],
                            ],
                          ),
                        );
                      },
                    ),
                  if (_canAddScopedContacts) ...[
                    Container(
                      width: double.infinity,
                      margin: const EdgeInsets.only(top: 12, bottom: 12),
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0F1C1A),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: Colors.white12),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'إضافة يدوية بالمعرّف',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 4),
                          const Text(
                            'أدخل المعرّف السهل للمستخدم لإضافته مباشرة',
                            style: TextStyle(color: Colors.white70, fontSize: 12),
                          ),
                          const SizedBox(height: 10),
                          TextField(
                            controller: _contactIdController,
                            style: const TextStyle(color: Colors.white),
                            textDirection: TextDirection.ltr,
                            textAlign: TextAlign.start,
                            decoration: const InputDecoration(
                              labelText: 'المعرّف السهل',
                              hintText: 'SC-A1B2C3',
                              labelStyle: TextStyle(color: Colors.white70),
                              hintStyle: TextStyle(color: Colors.white54),
                              prefixIcon: Icon(
                                Icons.badge_outlined,
                                color: Color(0xFF38E8A5),
                              ),
                              filled: true,
                              fillColor: Color(0xFF14231F),
                            ),
                          ),
                          const SizedBox(height: 8),
                          TextField(
                            controller: _nameController,
                            style: const TextStyle(color: Colors.white),
                            decoration: const InputDecoration(
                              labelText: 'اسم جهة الاتصال (اختياري)',
                              prefixIcon: Icon(Icons.person_outline),
                              filled: true,
                              fillColor: Color(0xFF14231F),
                            ),
                          ),
                          const SizedBox(height: 10),
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton.icon(
                              onPressed: _addContact,
                              icon: const Icon(Icons.person_add_alt_1),
                              label: Text(
                                widget.scope == ContactScope.regular
                                    ? 'إرسال طلب'
                                    : 'إضافة عضو',
                              ),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF38E8A5),
                                foregroundColor: Colors.black,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ] else if (widget.scope == ContactScope.room) ...[
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        _checkingOwnerPermission
                            ? 'جارٍ التحقق من صلاحية المالك...'
                            : 'إضافة أعضاء الغرفة متاحة لمالك التطبيق فقط',
                        style: const TextStyle(color: Colors.white70),
                      ),
                    ),
                  ],
                  Align(
                    alignment: Alignment.center,
                    child: TextButton.icon(
                      onPressed: () {
                        _headerScrollController.animateTo(
                          _headerScrollController.position.maxScrollExtent,
                          duration: const Duration(milliseconds: 350),
                          curve: Curves.easeOut,
                        );
                      },
                      icon: const Icon(Icons.keyboard_arrow_down),
                      label: const Text('نزّل الصفحة لعرض المزيد'),
                    ),
                  ),
                ],
                    ),
                  ),
                ),
              ),
            ),
            Expanded(
              child: user == null
                  ? const Center(
                      child: Text(
                        'حدثت مشكلة، حاول مرة أخرى',
                        style: TextStyle(color: Colors.white70),
                      ),
                    )
                  : StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                      stream: FirebaseFirestore.instance
                          .collection('users')
                          .doc(user.uid)
                          .collection(contactsCollectionName(widget.scope))
                          .orderBy('createdAt')
                          .snapshots(),
                      builder: (context, snapshot) {
                        if (snapshot.hasError)
                          return const Center(
                            child: Text(
                              'حدثت مشكلة، حاول مرة أخرى',
                              style: TextStyle(color: Colors.white70),
                            ),
                          );
                        final allDocs = snapshot.data?.docs ?? [];
                        final docs = widget.scope == ContactScope.group
                          ? allDocs
                            .where((doc) =>
                              doc.data()['roomId'] ==
                              (widget.roomId ??
                                secretGroupRoomId(user.uid)))
                            .toList()
                          : allDocs;
                        if (docs.isEmpty)
                          return const Center(
                            child: Text(
                              'لا توجد جهات اتصال بعد',
                              style: TextStyle(color: Colors.white54),
                            ),
                          );
                        return ListView.builder(
                          itemCount: docs.length,
                          itemBuilder: (context, index) {
                            final data = docs[index].data();
                            return ListTile(
                              leading: const CircleAvatar(
                                child: Icon(Icons.person),
                              ),
                              title: Text(
                                data['displayName'] ?? 'جهة اتصال',
                                style: const TextStyle(color: Colors.white),
                              ),
                              subtitle: Text(
                                data['contactId'] ?? docs[index].id,
                                style: const TextStyle(color: Colors.white54),
                              ),
                              onTap: () {
                                final status = data['status'] as String? ?? 'pending';
                                if (widget.scope == ContactScope.regular &&
                                    status != 'accepted') {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        status == 'incoming'
                                            ? 'اقبل طلب الاتصال أولًا لفتح الدردشة'
                                            : 'انتظر موافقة الطرف الآخر لفتح الدردشة',
                                      ),
                                    ),
                                  );
                                  return;
                                }
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) {
                                      if (widget.scope == ContactScope.room) {
                                        return const BlackRoomScreen();
                                      }
                                      if (widget.scope == ContactScope.group) {
                                        return SecretChatScreen(
                                          groupId: widget.roomId ??
                                              secretGroupRoomId(
                                                FirebaseAuth.instance.currentUser!.uid,
                                              ),
                                        );
                                      }
                                      return ChatScreen(
                                        chatName:
                                            data['displayName'] ?? 'جهة اتصال',
                                        contactUid:
                                            data['uid'] ?? docs[index].id,
                                      );
                                    },
                                  ),
                                );
                              },
                            );
                          },
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SecretRoomScreenState extends State<SecretRoomScreen>
    with SingleTickerProviderStateMixin {
  final TextEditingController _codeController = TextEditingController();
  bool _isUnlocked = false;
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);

    _pulseAnimation = Tween<double>(begin: 0.95, end: 1.05).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _codeController.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: const Color(0xFF07110F),
        appBar: AppBar(
          title: const Text(
            '🔐 الغرفة السرية المحصنة',
            style: TextStyle(
              color: Colors.amberAccent,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.2,
            ),
          ),
          backgroundColor: Colors.black87,
          centerTitle: true,
          iconTheme: const IconThemeData(color: Colors.amberAccent),
        ),
        body: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Colors.black, Colors.grey[900]!, Colors.black],
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: _isUnlocked
                ? _buildSecretWorkspace()
                : _buildCodeEntryView(),
          ),
        ),
      ),
    );
  }

  Widget _buildCodeEntryView() {
    return Center(
      child: SingleChildScrollView(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ScaleTransition(
              scale: _pulseAnimation,
              child: Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Colors.amberAccent.withOpacity(0.5),
                    width: 2,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.amberAccent.withOpacity(0.2),
                      blurRadius: 20,
                      spreadRadius: 5,
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.fingerprint,
                  size: 70,
                  color: Colors.amberAccent,
                ),
              ),
            ),
            const SizedBox(height: 30),
            const Text(
              'منطقة مقيدة أمنياً',
              style: TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'أدخل كود الغرفة الثابت للوصول إلى محتواها',
              style: TextStyle(color: Colors.white54, fontSize: 13),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            const SizedBox(height: 30),
            TextField(
              controller: _codeController,
              style: const TextStyle(color: Colors.white, letterSpacing: 2),
              obscureText: true,
              textAlign: TextAlign.center,
              decoration: InputDecoration(
                hintText: '••••••••',
                hintStyle: const TextStyle(color: Colors.white24),
                filled: true,
                fillColor: Colors.grey[900],
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: const BorderSide(
                    color: Colors.amberAccent,
                    width: 1,
                  ),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: const BorderSide(
                    color: Color(0xFF00FF66),
                    width: 2,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 25),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.amberAccent,
                  foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  elevation: 5,
                ),
                icon: const Icon(Icons.lock_open, color: Colors.black),
                label: const Text(
                  'فك التشفير والدخول',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                ),
                onPressed: () async {
                  await loadSecretRoomCode();
                    final enteredCode = _codeController.text.trim();
                    final isValidCode = enteredCode.isNotEmpty &&
                        secretRoomCodeHashNotifier.value != null &&
                        await hashPassword(enteredCode) ==
                            secretRoomCodeHashNotifier.value;
                    if (isValidCode) {
                    final user = FirebaseAuth.instance.currentUser;
                    try {
                      if (firebaseReady && user != null) {
                          final membershipReference = FirebaseFirestore.instance
                            .collection('rooms')
                            .doc('secret_room')
                            .collection('members')
                              .doc(user.uid);
                          final membership = await membershipReference.get();
                          final isOwner = (await FirebaseFirestore.instance
                                  .collection('config')
                                  .doc('app')
                                  .get())
                              .data()?['ownerUid'] == user.uid;
                          if (!membership.exists && !isOwner) {
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('يجب أن يضيفك مالك الغرفة أولًا قبل الدخول'),
                                  backgroundColor: Colors.redAccent,
                                ),
                              );
                            }
                            return;
                          }
                          if (isOwner) {
                            await ensureSecretRoomCapacityInitialized();
                          }
                      }
                    } catch (error) {
                      debugPrint('Secret room entry membership error: $error');
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('تعذر دخول الغرفة. تأكد من نشر قواعد Firebase وتحقق صلاحية المالك.'),
                            backgroundColor: Colors.redAccent,
                          ),
                        );
                      }
                      return;
                    }
                    setState(() {
                      _isUnlocked = true;
                    });
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('تم فتح الغرفة السرية بنجاح 🚀'),
                      ),
                    );
                  } else {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('الكود خطأ! ❌ برجاء مراجعة كود الغرفة'),
                      ),
                    );
                  }
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSecretWorkspace() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.amberAccent.withOpacity(0.08),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.amberAccent, width: 1),
          ),
          child: Row(
            children: [
              const Icon(Icons.security, color: Colors.amberAccent, size: 36),
              const SizedBox(width: 15),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: const [
                    Text(
                      'أنت الآن في النطاق الآمن',
                      style: TextStyle(
                        color: Colors.amberAccent,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    SizedBox(height: 4),
                    Text(
                      'البيانات هنا مشفرة كلياً ولا تظهر في السجل الرئيسي للتطبيق.',
                      style: TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        const Text(
          'إدارة إعدادات الغرفة:',
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 15,
          ),
        ),
        const SizedBox(height: 10),
        ValueListenableBuilder<List<String>>(
          valueListenable: secretRoomMembersNotifier,
          builder: (context, members, child) {
            return ListTile(
              tileColor: Colors.grey[900],
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              leading: const Icon(Icons.group_add, color: Color(0xFF00FF66)),
              title: Text(
                'إدارة أعضاء الغرفة (للمالك فقط)',
                style: TextStyle(color: Colors.white, fontSize: 14),
              ),
              subtitle: Text(
                members.length >= maxSecretRoomMembers
                    ? 'تم الوصول إلى الحد الأقصى: ${members.length} / $maxSecretRoomMembers'
                    : 'الأعضاء: ${members.length} / $maxSecretRoomMembers',
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
              trailing: const Icon(
                Icons.arrow_forward_ios,
                color: Colors.white54,
                size: 16,
              ),
              onTap: () => _verifyRoomOwner(context),
            );
          },
        ),
        const SizedBox(height: 15),
        const Text(
          'المحادثات المخفية داخل الغرفة:',
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 15,
          ),
        ),
        const SizedBox(height: 10),
        Expanded(
          child: ListView(
            children: [
              ListTile(
                tileColor: Colors.grey[900]?.withOpacity(0.5),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                leading: const CircleAvatar(
                  backgroundColor: Colors.amberAccent,
                  child: Icon(Icons.vpn_key, color: Colors.black),
                ),
                title: const Text(
                  'الغرفة السوداء (Shadow Ops)',
                  style: TextStyle(color: Colors.white),
                ),
                subtitle: const Text(
                  'آخر رسالة: تم تأمين التردد بنجاح...',
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                ),
                trailing: const Icon(
                  Icons.lock,
                  color: Color(0xFF00FF66),
                  size: 18,
                ),
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => const BlackRoomScreen(),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ],
    );
  }

  void _showRoomMembersDialog(BuildContext context) {
    final User? owner = FirebaseAuth.instance.currentUser;
    showDialog(
      context: context,
      builder: (dialogContext) =>
          StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: owner == null
                ? null
                : FirebaseFirestore.instance
                      .collection('users')
                      .doc(owner.uid)
                      .collection(contactsCollectionName(ContactScope.room))
                      .orderBy('createdAt')
                      .snapshots(),
            builder: (context, contactsSnapshot) =>
                ValueListenableBuilder<List<String>>(
                  valueListenable: secretRoomMembersNotifier,
                  builder: (context, members, child) {
                    final contacts = contactsSnapshot.data?.docs ?? [];
                    final currentMemberCount = members.length;
                    final availableContacts = contacts
                        .where((contact) => !members.contains(contact.id))
                        .toList();
                    return AlertDialog(
                      backgroundColor: Colors.grey[900],
                      title: Text(
                        'أعضاء الغرفة (${members.length}/$maxSecretRoomMembers)',
                        style: const TextStyle(color: Colors.white),
                      ),
                      content: SizedBox(
                        width: double.maxFinite,
                        child: isSecretRoomAtCapacity(currentMemberCount)
                            ? const Text(
                                'تم الوصول إلى الحد الأقصى: تم توصيل 100 عضو في الغرفة السرية. لا يمكن إضافة أعضاء جدد فعليًا.',
                                style: TextStyle(color: Colors.white70),
                              )
                            : availableContacts.isEmpty
                            ? const Text(
                                'أضف جهات اتصال أولًا من زر البصمة.',
                                style: TextStyle(color: Colors.white70),
                              )
                            : ListView.builder(
                                shrinkWrap: true,
                                itemCount: availableContacts.length,
                                itemBuilder: (context, index) {
                                  final contact = availableContacts[index];
                                  final data = contact.data();
                                  return ListTile(
                                    leading: const Icon(
                                      Icons.person_add,
                                      color: Color(0xFF00FF66),
                                    ),
                                    title: Text(
                                      data['displayName'] ?? 'جهة اتصال',
                                      style: const TextStyle(
                                        color: Colors.white,
                                      ),
                                    ),
                                    subtitle: Text(
                                      contact.id,
                                      style: const TextStyle(
                                        color: Colors.white54,
                                      ),
                                    ),
                                    onTap: () async {
                                      try {
                                        await addSecretRoomMember(
                                          targetUid: contact.id,
                                          displayName: data['displayName'] ??
                                              'جهة اتصال',
                                        );
                                        if (dialogContext.mounted) {
                                          Navigator.pop(dialogContext);
                                        }
                                      } catch (error) {
                                        if (dialogContext.mounted) {
                                          ScaffoldMessenger.of(
                                            dialogContext,
                                          ).showSnackBar(
                                            SnackBar(
                                              content: Text(
                                                firebaseWriteFailureMessage(
                                                  error,
                                                ),
                                              ),
                                              backgroundColor: Colors.redAccent,
                                            ),
                                          );
                                        }
                                      }
                                    },
                                  );
                                },
                              ),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(dialogContext),
                          child: const Text(
                            'إغلاق',
                            style: TextStyle(color: Colors.amberAccent),
                          ),
                        ),
                      ],
                    );
                  },
                ),
          ),
    );
  }

  void _verifyRoomOwner(BuildContext context) {
    final TextEditingController ownerKeyController = TextEditingController();
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: const Text(
          'تحقق من المالك',
          style: TextStyle(color: Colors.amberAccent),
        ),
        content: TextField(
          controller: ownerKeyController,
          obscureText: true,
          autofocus: true,
          style: const TextStyle(color: Colors.white, letterSpacing: 2),
          decoration: const InputDecoration(
            hintText: 'مفتاح المالك',
            hintStyle: TextStyle(color: Colors.white54),
            prefixIcon: Icon(
              Icons.admin_panel_settings,
              color: Colors.amberAccent,
            ),
          ),
          onSubmitted: (_) =>
              _submitOwnerKey(dialogContext, ownerKeyController),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('إلغاء', style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            onPressed: () => _submitOwnerKey(dialogContext, ownerKeyController),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.amberAccent,
              foregroundColor: Colors.black,
            ),
            child: const Text('تحقق'),
          ),
        ],
      ),
    ).then((_) => ownerKeyController.dispose());
  }

  Future<void> _submitOwnerKey(
    BuildContext dialogContext,
    TextEditingController controller,
  ) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || !firebaseReady) return;
    await loadRoomOwnerKey();
    final enteredKey = controller.text.trim();
    final matchesStoredOwnerKey = await hashPassword(enteredKey) ==
        roomOwnerKeyHashNotifier.value;
    var isConfiguredOwner = false;
    try {
      final ownerSnapshot = await FirebaseFirestore.instance
          .collection('config')
          .doc('app')
          .get();
      isConfiguredOwner = ownerSnapshot.data()?['ownerUid'] == user.uid;
    } catch (error) {
      debugPrint('Room owner verification error: $error');
    }
    if (isConfiguredOwner && matchesStoredOwnerKey) {
      Navigator.pop(dialogContext);
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => const ContactsScreen(
            scope: ContactScope.room,
            ownerVerified: true,
          ),
        ),
      );
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('مفتاح المالك غير صحيح'),
        backgroundColor: Colors.redAccent,
      ),
    );
  }
}

class SecretMembersScreen extends StatefulWidget {
  final String roomId;
  final String title;

  const SecretMembersScreen({
    super.key,
    required this.roomId,
    required this.title,
  });

  @override
  State<SecretMembersScreen> createState() => _SecretMembersScreenState();
}

class _SecretMembersScreenState extends State<SecretMembersScreen> {
  DateTime? _accessStartedAt;
  bool _ownerVerifiedForRoom = false;
  bool _isGroupOwner = false;

  bool get _isSecretRoom => widget.roomId == 'secret_room';
  bool get _isSecretGroup => widget.roomId.startsWith('secret_group_');

  Future<void> _verifyRoomOwnerForRemoval() async {
    if (!_isSecretRoom) return;

    final TextEditingController ownerKeyController = TextEditingController();
    final bool? verified = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: const Text(
          'تحقق من مالك الغرفة',
          style: TextStyle(color: Colors.amberAccent),
        ),
        content: TextField(
          controller: ownerKeyController,
          obscureText: true,
          autofocus: true,
          style: const TextStyle(color: Colors.white, letterSpacing: 2),
          decoration: const InputDecoration(
            hintText: 'مفتاح المالك',
            hintStyle: TextStyle(color: Colors.white54),
            prefixIcon: Icon(
              Icons.admin_panel_settings,
              color: Colors.amberAccent,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('إلغاء', style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            onPressed: () async {
              final user = FirebaseAuth.instance.currentUser;
              final enteredKey = ownerKeyController.text.trim();
              if (user == null) {
                Navigator.pop(dialogContext, false);
                return;
              }
                await loadRoomOwnerKey();
              final matchesStoredOwnerKey = await hashPassword(enteredKey) ==
                  roomOwnerKeyHashNotifier.value;
              bool isConfiguredOwner = false;
              try {
                final ownerSnapshot = await FirebaseFirestore.instance
                    .collection('config')
                    .doc('app')
                    .get();
                isConfiguredOwner = ownerSnapshot.data()?['ownerUid'] == user.uid;
              } catch (error) {
                debugPrint('Room owner verification error: $error');
              }
              if (isConfiguredOwner && matchesStoredOwnerKey) {
                if (mounted) {
                  Navigator.pop(dialogContext, true);
                }
                return;
              }
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('مفتاح المالك غير صحيح'),
                    backgroundColor: Colors.redAccent,
                  ),
                );
              }
              Navigator.pop(dialogContext, false);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.amberAccent,
              foregroundColor: Colors.black,
            ),
            child: const Text('تحقق'),
          ),
        ],
      ),
    );

    if (verified == true) {
      setState(() => _ownerVerifiedForRoom = true);
    }
  }

  Future<void> _removeMember(String memberId, String displayName) async {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null || memberId.isEmpty) return;
    if (memberId == currentUser.uid) {
      return;
    }

    try {
      if (_isSecretRoom) {
        await removeSecretRoomMemberWithCapacity(memberId);
      } else {
        await FirebaseFirestore.instance
            .collection('rooms')
            .doc(widget.roomId)
            .collection('members')
            .doc(memberId)
            .delete();
      }

      if (_isSecretGroup) {
        await FirebaseFirestore.instance
            .collection('users')
            .doc(memberId)
            .collection('secretGroups')
            .doc(widget.roomId)
            .delete();
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('تمت إزالة $displayName من ${widget.title}'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    } catch (error) {
      debugPrint('Failed to remove secret member: $error');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('تعذرت إزالة العضو'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }
  }

  @override
  void initState() {
    super.initState();
    unawaited(_loadAccessStart());
    if (_isSecretGroup) unawaited(_loadGroupOwner());
  }

  Future<void> _loadGroupOwner() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    try {
      final group = await FirebaseFirestore.instance
          .collection('rooms')
          .doc(widget.roomId)
          .get();
      if (mounted) {
        setState(() => _isGroupOwner = group.data()?['ownerUid'] == user.uid);
      }
    } catch (error) {
      debugPrint('Private group owner load failed: $error');
    }
  }

  Future<void> _loadAccessStart() async {
    if (_isSecretGroup) return;
    final startedAt = await ensureSecretAccessStart(widget.roomId);
    if (mounted) {
      setState(() => _accessStartedAt = startedAt);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: const Color(0xFF0D1117),
        appBar: AppBar(
          title: Text(widget.title),
          backgroundColor: const Color(0xFF171D26),
          foregroundColor: Colors.white,
          centerTitle: true,
          actions: [
            if (_isSecretRoom)
              IconButton(
                onPressed: _ownerVerifiedForRoom
                    ? null
                    : _verifyRoomOwnerForRemoval,
                icon: Icon(
                  _ownerVerifiedForRoom
                      ? Icons.verified_user
                      : Icons.admin_panel_settings_outlined,
                  color: _ownerVerifiedForRoom
                      ? const Color(0xFF38E8A5)
                      : Colors.amberAccent,
                ),
                tooltip: _ownerVerifiedForRoom
                    ? 'تم التحقق من المالك'
                    : 'إدخال مفتاح المالك للإزالة',
              ),
          ],
        ),
        body: !firebaseReady
            ? const Center(
                child: Text(
                  'حدثت مشكلة، حاول مرة أخرى',
                  style: TextStyle(color: Colors.white70),
                ),
              )
            : StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                stream: FirebaseFirestore.instance
                    .collection('rooms')
                    .doc(widget.roomId)
                    .collection('members')
                    .snapshots(),
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    return const Center(
                      child: Text(
                        'حدثت مشكلة، حاول مرة أخرى',
                        style: TextStyle(color: Colors.white70),
                      ),
                    );
                  }
                  if (!snapshot.hasData) {
                    return const Center(
                      child: CircularProgressIndicator(
                        color: Color(0xFF38E8A5),
                      ),
                    );
                  }

                  final currentUid = FirebaseAuth.instance.currentUser?.uid;
                  final visibleMembers = snapshot.data!.docs.where((member) {
                    if (_isSecretGroup) return true;
                    if (_isSecretRoom && _ownerVerifiedForRoom) return true;
                    final addedAt = member.data()['addedAt'];
                    if (currentUid != null && member.id == currentUid) {
                      return true;
                    }
                    if (addedAt is! Timestamp) {
                      return false;
                    }
                    if (_accessStartedAt == null) {
                      return true;
                    }
                    return addedAt.toDate().isAfter(_accessStartedAt!);
                  }).toList();

                  if (visibleMembers.isEmpty) {
                    return const Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.group_off_rounded, color: Colors.white38, size: 52),
                          SizedBox(height: 12),
                          Text(
                            'لا يوجد أعضاء حتى الآن',
                            style: TextStyle(color: Colors.white70, fontSize: 16),
                          ),
                        ],
                      ),
                    );
                  }

                  return Column(
                    children: [
                      Container(
                        margin: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                        decoration: BoxDecoration(
                          color: const Color(0xFF171F29),
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(color: const Color(0xFF38E8A5).withOpacity(0.35)),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.people_alt_rounded, color: Color(0xFF38E8A5)),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                'أعضاء ${widget.title}',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 16,
                                ),
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                              decoration: BoxDecoration(
                                color: const Color(0xFF38E8A5).withOpacity(0.14),
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Text(
                                '${visibleMembers.length}',
                                style: const TextStyle(
                                  color: Color(0xFF38E8A5),
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: ListView.separated(
                          padding: const EdgeInsets.fromLTRB(16, 6, 16, 20),
                          itemCount: visibleMembers.length,
                          separatorBuilder: (_, __) => const SizedBox(height: 10),
                          itemBuilder: (context, index) {
                            final member = visibleMembers[index];
                            final memberId = member.id;
                            final memberName = member.data()['displayName'] ?? 'مجهول الهوية';
                            final isCurrentUser = memberId == currentUid;
                            final canRemoveMember = memberId != currentUid &&
                                (_isSecretGroup
                                    ? _isGroupOwner
                                    : canRemoveSecretMember(
                                        isGroup: false,
                                        ownerVerified: _ownerVerifiedForRoom,
                                        isOwnerUser: _ownerVerifiedForRoom,
                                      ));

                            return Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: const Color(0xFF171F29),
                                borderRadius: BorderRadius.circular(18),
                                border: Border.all(color: Colors.white10),
                              ),
                              child: Row(
                                children: [
                                  const CircleAvatar(
                                    radius: 24,
                                    backgroundColor: Color(0xFF38E8A5),
                                    child: Icon(Icons.person, color: Colors.black),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          memberName,
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontWeight: FontWeight.w700,
                                            fontSize: 15,
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          isCurrentUser ? 'أنت' : 'عضو في ${widget.title}',
                                          style: const TextStyle(
                                            color: Colors.white54,
                                            fontSize: 12,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  if (canRemoveMember)
                                    IconButton(
                                      onPressed: () => _removeMember(memberId, memberName),
                                      icon: const Icon(Icons.delete_forever_rounded, color: Colors.redAccent),
                                      tooltip: 'إزالة العضو',
                                    )
                                  else if (isCurrentUser)
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                      decoration: BoxDecoration(
                                        color: Colors.white.withOpacity(0.08),
                                        borderRadius: BorderRadius.circular(999),
                                      ),
                                      child: const Text(
                                        'أنت',
                                        style: TextStyle(
                                          color: Colors.white70,
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  );
                },
              ),
      ),
    );
  }
}

// ==========================================
// 3. شاشة الشات الجماعي السري (المجموعة السرية الآمنة 🛡️)
// ==========================================
class SecretChatScreen extends StatefulWidget {
  final bool? requirePassword;
  final String chatTitle;
  final String? groupId;

  const SecretChatScreen({
    super.key,
    this.requirePassword,
    this.chatTitle = 'المجموعة السرية الآمنة',
    this.groupId,
  });

  @override
  State<SecretChatScreen> createState() => _SecretChatScreenState();
}

class BlackRoomScreen extends StatelessWidget {
  const BlackRoomScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const SecretChatScreen(
      chatTitle: 'الغرفة السوداء (Shadow Ops)',
      requirePassword: false,
    );
  }
}

class _SecretChatScreenState extends State<SecretChatScreen>
    with SingleTickerProviderStateMixin {
  bool _isUnlocked = false;
  bool _requiresPassword = false;
  bool _isSecretMember = false;
  bool _isGroupOwner = false;
  String? _groupPasswordHash;
  DateTime? _accessStartedAt;
  final TextEditingController _passController = TextEditingController();
  final TextEditingController _messageController = TextEditingController();
  final AudioRecorder _secretVoiceRecorder = AudioRecorder();
  final AudioPlayer _secretAudioPlayer = AudioPlayer();
  bool _isSecretRecording = false;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>?
  _secretMessagesSubscription;

  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  final List<Map<String, dynamic>> _secretMessages = [];

  @override
  void initState() {
    super.initState();
    _requiresPassword = widget.requirePassword ??
        secretGroupLockEnabledNotifier.value;
    _isUnlocked = !_requiresPassword;
    _loadLocalSecretVoiceMessages();
    unawaited(_prepareSecretChat());
    clearHistoryNotifier.addListener(_clearSecretMessages);
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);

    _pulseAnimation = Tween<double>(begin: 0.85, end: 1.15).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
  }

  Future<void> _prepareSecretChat() async {
    final roomId = _roomId;
    if (_isBlackRoom) {
      _accessStartedAt = await ensureSecretAccessStart(roomId);
      await _loadSecretMembership();
      _listenToSecretMessages();
      return;
    }

    final accessStartFuture = ensureSecretAccessStart(roomId);
    final membershipFuture = _loadSecretMembership();
    final passwordFuture = _loadGroupPassword();
    _accessStartedAt = await accessStartFuture;
    await passwordFuture;
    unawaited(membershipFuture);
    _listenToSecretMessages();
  }

  Future<void> _sendSecretMessage() async {
    final String text = _messageController.text.trim();
    if (text.isNotEmpty) {
      if (!_isSecretMember) {
        await _loadSecretMembership();
      }
      if (!_isSecretMember) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('أنت لست عضوًا في هذه المجموعة ولا يمكنك الإرسال'),
            ),
          );
        }
        return;
      }
      _messageController.clear();
      if (firebaseReady) {
        await _saveSecretMessage(text);
      } else if (mounted) {
        setState(() {
          _secretMessages.add({
            "sender": "أنت",
            "text": text,
            "isMe": true,
            "time": _formatMessageTime(),
          });
        });
      }
      if (autoDeleteMessagesNotifier.value) {
        Future.delayed(const Duration(seconds: 8), () {
          unawaited(deleteExpiredOwnChatMessages(_secretChatId));
        });
      }
    }
  }

  Future<void> _loadGroupPassword() async {
    if (widget.chatTitle.contains('الغرفة السوداء')) return;
    await loadSecretGroupSettings();
    if (mounted) {
      setState(() {
        _groupPasswordHash = secretGroupPasswordHashNotifier.value;
        _requiresPassword = secretGroupLockEnabledNotifier.value;
        _isUnlocked = !_requiresPassword;
      });
    }
  }

  bool get _isBlackRoom => widget.chatTitle.contains('الغرفة السوداء');

  String get _roomId => _isBlackRoom
      ? 'secret_room'
      : widget.groupId ??
          secretGroupRoomId(FirebaseAuth.instance.currentUser?.uid ?? '');

  String get _secretChatId => _isBlackRoom ? 'shadow_ops' : _roomId;
  bool get _isOwnPrivateGroup {
    final user = FirebaseAuth.instance.currentUser;
    return !_isBlackRoom &&
        user != null &&
        _roomId == secretGroupRoomId(user.uid);
  }

  String get _senderName {
    final displayName = FirebaseAuth.instance.currentUser?.displayName?.trim();
    if (displayName != null && displayName.isNotEmpty) return displayName;
    return currentPublicUserId ?? 'مستخدم';
  }

  Future<void> _loadSecretMembership() async {
    if (!firebaseReady) return;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      if (mounted) setState(() => _isSecretMember = false);
      return;
    }

    try {
      final roomId = _roomId;
      final membership = await FirebaseFirestore.instance
          .collection('rooms')
          .doc(roomId)
          .collection('members')
          .doc(user.uid)
          .get();
      if (roomId.startsWith('secret_group_')) {
        final group = await FirebaseFirestore.instance
            .collection('rooms')
            .doc(roomId)
            .get();
        final isOwner = group.data()?['ownerUid'] == user.uid;
        if (mounted) {
          setState(() {
            _isSecretMember = membership.exists || isOwner;
            _isGroupOwner = isOwner;
          });
        }
        return;
      }
      final ownerSnapshot = await FirebaseFirestore.instance
          .collection('config')
          .doc('app')
          .get();
      final isOwner = ownerSnapshot.data()?['ownerUid'] == user.uid;
      if (mounted) {
        setState(() {
          _isSecretMember = membership.exists || isOwner;
          _isGroupOwner = false;
        });
      }
    } catch (error) {
      debugPrint('Secret membership load error: $error');
      if (mounted) setState(() => _isSecretMember = false);
    }
  }

  Future<void> _leaveSecretChat() async {
    final user = FirebaseAuth.instance.currentUser;
    if (!firebaseReady || user == null) return;
    if (_isGroupOwner || _isOwnPrivateGroup) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: const Color(0xFF171D26),
        title: const Text(
          'تأكيد الخروج',
          style: TextStyle(color: Colors.amberAccent),
        ),
        content: const Text(
          'هل تريد الخروج من هذه المجموعة؟ لن تتمكن من إرسال رسائل حتى تتم إضافتك مرة أخرى.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('إلغاء', style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('خروج', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final roomId = _roomId;
    final isPrivateGroup = roomId.startsWith('secret_group_');
    try {
      if (isPrivateGroup) {
        await FirebaseFirestore.instance
            .collection('rooms')
            .doc(roomId)
            .collection('members')
            .doc(user.uid)
            .delete();
      } else {
        await removeSecretRoomMemberWithCapacity(user.uid);
      }
      await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .collection(
            contactsCollectionName(
              isPrivateGroup
                  ? ContactScope.group
                  : ContactScope.room,
            ),
          )
          .doc(user.uid)
          .delete();
      if (isPrivateGroup) {
        await FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .collection('secretGroups')
            .doc(roomId)
            .delete();
        await FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .collection('settings')
            .doc('secretGroupAccess_$roomId')
            .delete();
      }

      await _secretMessagesSubscription?.cancel();
      _secretMessagesSubscription = null;
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تم الخروج من المحادثة بنجاح')),
      );
      Navigator.of(context).pop();
    } catch (error) {
      debugPrint('Secret chat leave error: $error');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('تعذر الخروج الآن، حاول مرة أخرى'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }
  }

  void _listenToSecretMessages() {
    if (!firebaseReady) return;
    unawaited(deleteExpiredOwnChatMessages(_secretChatId));
    _secretMessagesSubscription = FirebaseFirestore.instance
        .collection('chats')
        .doc(_secretChatId)
        .collection('messages')
      .orderBy('createdAt', descending: true)
        .limit(100)
        .snapshots()
        .listen(
          (snapshot) {
            if (!mounted) return;
            final currentUid = FirebaseAuth.instance.currentUser?.uid;
            final accessStartedAt = _accessStartedAt;
            final messages = snapshot.docs.reversed.map((doc) {
              final data = doc.data();
              final deletedFor = data['deletedFor'];
              final expiresAt = data['expiresAt'];
              if (currentUid != null &&
                  deletedFor is List &&
                  deletedFor.contains(currentUid)) {
                return null;
              }
              if (expiresAt is Timestamp &&
                  expiresAt.compareTo(Timestamp.now()) <= 0) {
                return null;
              }
              final timestamp = data['createdAt'];
              if (accessStartedAt != null &&
                  timestamp is Timestamp &&
                  timestamp.toDate().isBefore(accessStartedAt)) {
                return null;
              }
              final mediaUrl = data['mediaUrl'] as String?;
              final localMediaPath = mediaUrl != null &&
                      mediaUrl.startsWith('local://')
                  ? mediaUrl.substring('local://'.length)
                  : null;
              return {
                'docId': doc.id,
                'sender': data['sender'] ?? 'مستخدم',
                'text': data['text'] ?? '',
                'isMe': data['uid'] == FirebaseAuth.instance.currentUser?.uid,
                'mediaType': data['mediaType'] as String?,
                'mediaFile': localMediaPath == null
                    ? null
                    : XFile(localMediaPath),
                'mediaUrl': localMediaPath == null ? mediaUrl : null,
                'time': timestamp is Timestamp
                    ? _formatTimestamp(timestamp)
                    : _formatMessageTime(),
              };
            }).whereType<Map<String, dynamic>>().toList();
            final localMessages = _secretMessages
                .where((message) => message['docId'] == null)
                .toList();
            setState(() {
              _secretMessages
                ..clear()
                ..addAll(messages)
                ..addAll(localMessages);
            });
          },
          onError: (error) {
            debugPrint('Secret messages listener error: $error');
          },
        );
  }

  Future<String?> _saveSecretMediaLocally(XFile file, String mediaType) async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      final safeName = file.name.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
      final localFile = File(
        '${directory.path}/secret_${mediaType}_${DateTime.now().millisecondsSinceEpoch}_$safeName',
      );
      await localFile.writeAsBytes(await file.readAsBytes());
      return 'local://${localFile.path}';
    } catch (error) {
      debugPrint('Secret media local save error: $error');
      return null;
    }
  }

  String get _localSecretVoiceMessagesKey =>
      'local_secret_voice_messages_$_secretChatId';

  Future<void> _loadLocalSecretVoiceMessages() async {
    final preferences = await getSafeSharedPreferences();
    if (preferences == null) return;
    try {
      final encoded = preferences.getString(_localSecretVoiceMessagesKey);
      if (encoded == null || encoded.isEmpty) return;
      final storedMessages = jsonDecode(encoded);
      if (storedMessages is! List) return;
      for (final item in storedMessages) {
        if (item is! Map || item['path'] is! String) continue;
        final path = item['path'] as String;
        if (!await File(path).exists()) continue;
        _secretMessages.add({
          'sender': 'أنت',
          'text': 'رسالة صوتية 🎙️',
          'isMe': true,
          'time': item['time'] as String? ?? _formatMessageTime(),
          'mediaType': 'audio',
          'mediaFile': XFile(path),
          'mediaUrl': 'local://$path',
        });
      }
    } catch (error) {
      debugPrint('Local secret voice messages load error: $error');
    }
  }

  Future<void> _saveLocalSecretVoiceMessage(String path, String time) async {
    final preferences = await getSafeSharedPreferences();
    if (preferences == null) return;
    try {
      final storedMessages = <Map<String, String>>[];
      final encoded = preferences.getString(_localSecretVoiceMessagesKey);
      if (encoded != null && encoded.isNotEmpty) {
        final decoded = jsonDecode(encoded);
        if (decoded is List) {
          for (final item in decoded) {
            if (item is Map && item['path'] is String) {
              storedMessages.add({
                'path': item['path'] as String,
                'time': item['time'] as String? ?? time,
              });
            }
          }
        }
      }
      if (storedMessages.every((item) => item['path'] != path)) {
        storedMessages.add({'path': path, 'time': time});
      }
      await preferences.setString(
        _localSecretVoiceMessagesKey,
        jsonEncode(storedMessages),
      );
    } catch (error) {
      debugPrint('Local secret voice message save error: $error');
    }
  }

  Future<String?> _uploadSecretMedia(XFile file, String mediaType) async {
    if (!firebaseReady) return null;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return null;

    try {
      final fileName = 'secret_${mediaType}_${DateTime.now().millisecondsSinceEpoch}_${file.name}';
      final uploadTask = FirebaseStorage.instance
          .ref()
          .child('rooms')
          .child(_roomId)
          .child('secret_media')
          .child(user.uid)
          .child(mediaType)
          .child(fileName)
          .putFile(File(file.path));
      final snapshot = await uploadTask;
      return await snapshot.ref.getDownloadURL();
    } catch (error) {
      debugPrint('Secret media upload error: $error');
      return null;
    }
  }

  Future<void> _saveSecretMediaMessage(
    String text,
    String mediaType,
    String? mediaUrl,
  ) async {
    if (!firebaseReady || mediaUrl == null) return;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    try {
      await FirebaseFirestore.instance
          .collection('chats')
          .doc(_secretChatId)
          .collection('messages')
          .add({
            'sender': _senderName,
            'text': text,
            'uid': user.uid,
            'deletedFor': <String>[],
            'mediaType': mediaType,
            'mediaUrl': mediaUrl,
            'createdAt': FieldValue.serverTimestamp(),
            if (autoDeleteMessagesNotifier.value)
              'expiresAt': Timestamp.fromDate(
                DateTime.now().add(const Duration(seconds: 8)),
              ),
          });
    } catch (error) {
      debugPrint('Secret media save error: $error');
    }
  }

  Future<void> _toggleSecretVoiceRecording() async {
    if (_isSecretRecording) {
      try {
        final path = await _secretVoiceRecorder.stop();
        if (!mounted) return;
        setState(() => _isSecretRecording = false);
        if (path == null || path.isEmpty) return;

        final voiceFile = XFile(path);
        final localPath = await _saveSecretMediaLocally(voiceFile, 'audio');
        final messageTime = _formatMessageTime();
        final secretMsg = {
          'sender': 'أنت',
          'text': 'رسالة صوتية 🎙️',
          'isMe': true,
          'time': messageTime,
          'mediaType': 'audio',
          'mediaFile': voiceFile,
          'mediaUrl': localPath,
        };

        if (mounted) {
          setState(() => _secretMessages.add(secretMsg));
        }

        String? remoteUrl;
        if (firebaseReady) {
          remoteUrl = await _uploadSecretMedia(voiceFile, 'audio');
          if (remoteUrl != null && mounted) {
            setState(() {
              final last = _secretMessages.isNotEmpty ? _secretMessages.last : null;
              if (last != null) last['mediaUrl'] = remoteUrl;
            });
          }
        }

        if (remoteUrl == null && localPath != null) {
          await _saveLocalSecretVoiceMessage(path, messageTime);
        }
        if (remoteUrl != null) {
          await _saveSecretMediaMessage('رسالة صوتية 🎙️', 'audio', remoteUrl);
        }
      } catch (error) {
        debugPrint('Secret voice recording stop error: $error');
        if (mounted) {
          setState(() => _isSecretRecording = false);
        }
      }
      return;
    }

    try {
      final hasPermission = await _secretVoiceRecorder.hasPermission();
      if (!hasPermission) {
        if (!mounted) return;
        return;
      }

      final directory = await getApplicationDocumentsDirectory();
      final fileName = 'shadow_secret_voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
      final filePath = '${directory.path}/$fileName';
      await _secretVoiceRecorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          sampleRate: 44100,
          bitRate: 128000,
        ),
        path: filePath,
      );
      if (mounted) setState(() => _isSecretRecording = true);
    } catch (error) {
      debugPrint('Secret voice recording start error: $error');
    }
  }

  Future<void> _playSecretAudio(Map<String, dynamic> msg) async {
    final mediaUrl = msg['mediaUrl'] as String?;
    final mediaFile = msg['mediaFile'] as XFile?;
    try {
      await _secretAudioPlayer.stop();
      if (mediaFile != null) {
        await _secretAudioPlayer.play(DeviceFileSource(mediaFile.path));
      } else if (mediaUrl != null && mediaUrl.isNotEmpty) {
        if (mediaUrl.startsWith('local://')) {
          final localFile = File(mediaUrl.substring('local://'.length));
          if (await localFile.exists()) {
            await _secretAudioPlayer.play(DeviceFileSource(localFile.path));
            return;
          }
        }
        await _secretAudioPlayer.play(UrlSource(mediaUrl));
      }
    } catch (error) {
      debugPrint('Secret audio playback error: $error');
    }
  }

  Future<void> _saveSecretMessage(String text) async {
    if (!firebaseReady) {
      debugPrint('Secret message save skipped: Firebase not ready');
      return;
    }
    try {
      final user = FirebaseAuth.instance.currentUser;
      await FirebaseFirestore.instance
          .collection('chats')
          .doc(_secretChatId)
          .collection('messages')
          .add({
            'sender': _senderName,
            'text': text,
            'uid': user?.uid,
            'deletedFor': <String>[],
            'createdAt': FieldValue.serverTimestamp(),
            if (autoDeleteMessagesNotifier.value)
              'expiresAt': Timestamp.fromDate(
                DateTime.now().add(const Duration(seconds: 8)),
              ),
          });
    } catch (error) {
      debugPrint('Secret message save error: $error');
      if (mounted) {
        showGenericFailureSnackBar(context);
      }
    }
  }

  Future<void> _deleteSecretMessage(
    Map<String, dynamic> message, {
    required bool forEveryone,
  }) async {
    final docId = message['docId'];
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    if (docId is! String || !firebaseReady) {
      await _deleteSecretMedia(message, remote: false);
      if (mounted) {
        setState(() => _secretMessages.remove(message));
      }
      return;
    }
    if (forEveryone && message['isMe'] != true) {
      return;
    }

    final reference = FirebaseFirestore.instance
        .collection('chats')
        .doc(_secretChatId)
        .collection('messages')
        .doc(docId);
    try {
      if (forEveryone && message['isMe'] == true) {
        await reference.delete();
        await _deleteSecretMedia(message, remote: true);
      } else {
        await reference.update({
          'deletedFor': FieldValue.arrayUnion([user.uid]),
        });
        await _deleteSecretMedia(message, remote: false);
      }
      if (mounted) {
        setState(() {
          _secretMessages.removeWhere((item) => item['docId'] == docId);
        });
      }
    } catch (error) {
      debugPrint('Secret message delete error: $error');
    }
  }

  Future<void> _deleteSecretMedia(
    Map<String, dynamic> message, {
    required bool remote,
  }) async {
    final mediaFile = message['mediaFile'] as XFile?;
    if (mediaFile != null) {
      try {
        final localFile = File(mediaFile.path);
        if (await localFile.exists()) await localFile.delete();
      } catch (error) {
        debugPrint('Secret local media delete error: $error');
      }
    }
    final mediaUrl = message['mediaUrl'] as String?;
    if (!remote || mediaUrl == null || mediaUrl.isEmpty) return;
    try {
      await FirebaseStorage.instance.refFromURL(mediaUrl).delete();
    } catch (error) {
      debugPrint('Secret Firebase media delete error: $error');
    }
  }

  Future<void> _showSecretMessageActions(Map<String, dynamic> message) async {
    final deleteMode = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xFF18231F),
      builder: (sheetContext) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.white),
              title: const Text(
                'حذف لدي',
                style: TextStyle(color: Colors.white),
              ),
              onTap: () => Navigator.pop(sheetContext, 'mine'),
            ),
            if (message['isMe'] == true && message['docId'] is String)
              ListTile(
                leading: const Icon(
                  Icons.delete_forever,
                  color: Colors.redAccent,
                ),
                title: const Text(
                  'حذف لدى الجميع',
                  style: TextStyle(color: Colors.redAccent),
                ),
                onTap: () => Navigator.pop(sheetContext, 'everyone'),
              ),
          ],
        ),
      ),
    );
    if (!mounted || deleteMode == null) return;
    if (deleteMode == 'everyone' && message['docId'] is String) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('حذف لدى الجميع'),
          content: const Text(
            'سيتم حذف الرسالة والوسائط المرتبطة بها من Firebase لدى جميع المشاركين.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('إلغاء'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('حذف للجميع'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    await _deleteSecretMessage(
      message,
      forEveryone: deleteMode == 'everyone',
    );
  }

  String _formatTimestamp(Timestamp timestamp) {
    final date = timestamp.toDate();
    return '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
  }

  void _showGroupContactDialog() {
    final User? owner = FirebaseAuth.instance.currentUser;
    if (!firebaseReady || owner == null) return;
    showDialog(
      context: context,
      builder: (dialogContext) =>
          StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: owner == null
                ? null
                : FirebaseFirestore.instance
                      .collection('users')
                      .doc(owner.uid)
                      .collection(contactsCollectionName(ContactScope.group))
                      .orderBy('createdAt')
                      .snapshots(),
            builder: (context, snapshot) {
                final contacts = (snapshot.data?.docs ?? [])
                  .where((contact) => contact.data()['roomId'] == _roomId)
                  .toList();
              return AlertDialog(
                backgroundColor: const Color(0xFF101B18),
                title: const Text(
                  'إضافة جهة اتصال للمجموعة',
                  style: TextStyle(color: Colors.white),
                ),
                content: SizedBox(
                  width: double.maxFinite,
                  child: contacts.isEmpty
                      ? const Text(
                          'أضف جهات اتصال أولًا من زر البصمة.',
                          style: TextStyle(color: Colors.white70),
                        )
                      : ListView.builder(
                          shrinkWrap: true,
                          itemCount: contacts.length,
                          itemBuilder: (context, index) {
                            final data = contacts[index].data();
                            return ListTile(
                              leading: const Icon(
                                Icons.person_add,
                                color: Color(0xFFFFD76A),
                              ),
                              title: Text(
                                data['displayName'] ?? 'جهة اتصال',
                                style: const TextStyle(color: Colors.white),
                              ),
                              subtitle: Text(
                                contacts[index].id,
                                style: const TextStyle(color: Colors.white54),
                              ),
                              onTap: () async {
                                final roomId = _roomId;
                                final firestore = FirebaseFirestore.instance;
                                final targetUid = data['uid'] as String? ??
                                  contacts[index].id;
                                final memberRef = firestore
                                    .collection('rooms')
                                    .doc(roomId)
                                    .collection('members')
                                  .doc(targetUid);
                                if (!(await memberRef.get()).exists) {
                                  await memberRef.set({
                                    'displayName':
                                        data['displayName'] ?? 'جهة اتصال',
                                    'addedBy': owner.uid,
                                    'addedAt': FieldValue.serverTimestamp(),
                                  });
                                }
                                final group = await firestore
                                    .collection('rooms')
                                    .doc(roomId)
                                    .get();
                                await firestore
                                    .collection('users')
                                    .doc(targetUid)
                                    .collection('secretGroups')
                                    .doc(roomId)
                                    .set({
                                      'roomId': roomId,
                                      'ownerUid': group.data()?['ownerUid'],
                                      'title': group.data()?['title'] ??
                                          'مجموعة سرية',
                                      'updatedAt':
                                          FieldValue.serverTimestamp(),
                                    });
                                if (dialogContext.mounted)
                                  Navigator.pop(dialogContext);
                              },
                            );
                          },
                        ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(dialogContext),
                    child: const Text(
                      'إغلاق',
                      style: TextStyle(color: Colors.amberAccent),
                    ),
                  ),
                ],
              );
            },
          ),
    );
  }

  String _firebaseUnavailableMessage() {
    return 'حدثت مشكلة، حاول مرة أخرى';
  }

  String _formatMessageTime() {
    final DateTime now = DateTime.now();
    return '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
  }

  @override
  void dispose() {
    _secretMessagesSubscription?.cancel();
    clearHistoryNotifier.removeListener(_clearSecretMessages);
    _pulseController.dispose();
    _passController.dispose();
    _messageController.dispose();
    unawaited(_secretVoiceRecorder.stop());
    unawaited(_secretAudioPlayer.stop());
    _secretVoiceRecorder.dispose();
    _secretAudioPlayer.dispose();
    super.dispose();
  }

  void _clearSecretMessages() {
    if (mounted) setState(_secretMessages.clear);
  }

  @override
  Widget build(BuildContext context) {
    return _isUnlocked ? _buildChatInterface() : _buildPasswordInterface();
  }

  // 1. واجهة الباسورد (العنوان في المنتصف والقفل على الشمال)
  Widget _buildPasswordInterface() {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: const Color(0xFF0A0A0A),
        appBar: AppBar(
          centerTitle: true, // جعل العنوان في المنتصف
          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  widget.chatTitle,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              const Icon(Icons.lock_rounded, color: Colors.amberAccent, size: 18),
            ],
          ),
          backgroundColor: const Color(0xFF121212),
          elevation: 2,
          iconTheme: const IconThemeData(color: Colors.amberAccent),
        ),
        body: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ScaleTransition(
                  scale: _pulseAnimation,
                  child: Container(
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.amberAccent.withOpacity(0.08),
                      border: Border.all(color: Colors.amberAccent, width: 2),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.amberAccent.withOpacity(0.3),
                          blurRadius: 30,
                          spreadRadius: 5,
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.lock_rounded,
                      color: Colors.amberAccent,
                      size: 55,
                    ),
                  ),
                ),
                const SizedBox(height: 30),
                Text(
                  widget.chatTitle.contains('الغرفة السوداء')
                      ? 'غرفة Shadow Ops'
                      : 'المجموعة السرية الآمنة',
                  style: const TextStyle(
                    color: Colors.amberAccent,
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.1,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  widget.chatTitle.contains('الغرفة السوداء')
                      ? 'قناة خاصة ومحمية - أدخل مفتاح التشفير'
                      : 'منطقة مقيدة أمنياً - أدخل مفتاح التشفير',
                  style: TextStyle(color: Colors.grey, fontSize: 13),
                ),
                const SizedBox(height: 40),
                Container(
                  constraints: const BoxConstraints(maxWidth: 380),
                  child: TextField(
                    controller: _passController,
                    obscureText: true,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.amberAccent,
                      fontSize: 18,
                      letterSpacing: 2,
                    ),
                    decoration: InputDecoration(
                      hintText: '••••••••••••',
                      hintStyle: TextStyle(color: Colors.grey[700]),
                      filled: true,
                      fillColor: const Color(0xFF141414),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(20),
                        borderSide: BorderSide.none,
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(20),
                        borderSide: const BorderSide(
                          color: Colors.amberAccent,
                          width: 1.5,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 25),
                Container(
                  constraints: const BoxConstraints(maxWidth: 380),
                  width: double.infinity,
                  height: 50,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.amberAccent,
                      foregroundColor: Colors.black,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20),
                      ),
                      elevation: 8,
                      shadowColor: Colors.amberAccent.withOpacity(0.5),
                    ),
                    onPressed: () async {
                      final enteredHash =
                          await hashPassword(_passController.text.trim());
                      if (_groupPasswordHash != null &&
                          enteredHash == _groupPasswordHash) {
                        setState(() => _isUnlocked = true);
                        await _loadSecretMembership();
                      } else {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                              'الكود غير صحيح! حاول مجدداً',
                              style: TextStyle(color: Colors.white),
                            ),
                            backgroundColor: Colors.redAccent,
                          ),
                        );
                      }
                    },
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.lock_open_rounded, size: 20),
                        SizedBox(width: 8),
                        Text(
                          'فك التشفير والدخول',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                          ),
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
    );
  }

  // 2. واجهة الشات الجماعي السري
  Widget _buildChatInterface() {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: const Color(0xFF0D1117),
        appBar: AppBar(
          centerTitle: true,
          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  widget.chatTitle,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.amberAccent,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              const Icon(
                Icons.verified_user_rounded,
                color: Color(0xFF38E8A5),
                size: 20,
              ),
            ],
          ),
          backgroundColor: const Color(0xFF171D26),
          elevation: 0,
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(1),
            child: Container(height: 1, color: const Color(0xFF3A4655)),
          ),
          iconTheme: const IconThemeData(color: Color(0xFF38E8A5)),
          actions: [
            IconButton(
              icon: const Icon(Icons.groups_rounded),
              tooltip: 'أعضاء المحادثة السرية',
              onPressed: () {
                final isBlackRoom = widget.chatTitle.contains('الغرفة السوداء');
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => SecretMembersScreen(
                      roomId: isBlackRoom ? 'secret_room' : _roomId,
                      title: isBlackRoom ? 'أعضاء الغرفة' : 'أعضاء المجموعة',
                    ),
                  ),
                );
              },
            ),
            if (!widget.chatTitle.contains('الغرفة السوداء'))
              IconButton(
                icon: const Icon(
                  Icons.person_add_alt_1,
                  color: Color(0xFFFFD76A),
                ),
                tooltip: 'إضافة جهة اتصال للمجموعة',
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) =>
                          ContactsScreen(
                            scope: ContactScope.group,
                            roomId: _roomId,
                          ),
                    ),
                  );
                },
              ),
            if (!_isGroupOwner && !_isOwnPrivateGroup)
              IconButton(
                icon: const Icon(Icons.logout, color: Colors.redAccent),
                tooltip: 'الخروج من المحادثة',
                onPressed: _leaveSecretChat,
              ),
          ],
        ),
        body: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xFF0D1117), Color(0xFF111A1D)],
            ),
          ),
          child: Column(
            children: [
              Container(
                margin: const EdgeInsets.fromLTRB(14, 0, 14, 4),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFF1A2930),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: const Color(0xFF61E7C0).withOpacity(0.45),
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.lock_outline_rounded,
                      color: Color(0xFF38E8A5),
                      size: 18,
                    ),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Text(
                        widget.chatTitle.contains('الغرفة السوداء')
                            ? 'قناة Shadow Ops الخاصة'
                            : 'اتصال مشفّر داخل المجموعة',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        ),
                      ),
                    ),
                    const Text(
                      'متصل الآن',
                      style: TextStyle(color: Color(0xFF38E8A5), fontSize: 11),
                    ),
                  ],
                ),
              ),
              Container(
                margin: const EdgeInsets.fromLTRB(14, 4, 14, 2),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  color: Colors.amberAccent.withOpacity(0.06),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: Colors.amberAccent.withOpacity(0.25),
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.verified_user_rounded,
                      color: Colors.amberAccent,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        widget.chatTitle.contains('الغرفة السوداء')
                            ? 'أهلاً بك في غرفة Shadow Ops · الرسائل مشفرة'
                            : 'أهلاً بك في المجموعة السرية · الرسائل مشفرة',
                        style: const TextStyle(
                          color: Colors.amberAccent,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView.builder(
                  primary: false,
                  padding: const EdgeInsets.fromLTRB(14, 8, 14, 16),
                  itemCount: _secretMessages.length,
                  itemBuilder: (context, index) {
                    final msg = _secretMessages[index];
                    final bool isMe = msg["isMe"]!;

                    if (msg["mediaType"] == 'audio') {
                      return Align(
                        alignment: isMe
                            ? Alignment.centerRight
                            : Alignment.centerLeft,
                        child: GestureDetector(
                          onTap: () => _playSecretAudio(msg),
                          onLongPress: () => _showSecretMessageActions(msg),
                          child: Container(
                            margin: const EdgeInsets.symmetric(vertical: 5),
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: isMe
                                  ? const Color(0xFF176B59)
                                  : const Color(0xFF202733),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: isMe
                                    ? const Color(0xFF38E8A5).withOpacity(0.7)
                                    : const Color(0xFF718096).withOpacity(0.45),
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(
                                  Icons.graphic_eq_rounded,
                                  color: Color(0xFF00FF66),
                                  size: 24,
                                ),
                                const SizedBox(width: 10),
                                Text(
                                  'رسالة صوتية 🎙️',
                                  style: TextStyle(
                                    color: isMe ? Colors.white : Colors.white70,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    }

                    final isWelcomeMsg = !isMe &&
                        (msg["text"].toString().contains(
                              "أهلاً بك في المجموعة السرية الآمنة",
                            ) ||
                            msg["text"].toString().contains(
                              "أهلاً بك في غرفة Shadow Ops",
                            ));
                    if (isWelcomeMsg) return const SizedBox.shrink();

                    return Align(
                      alignment: isMe
                          ? Alignment.centerRight
                          : Alignment.centerLeft,
                      child: GestureDetector(
                        onLongPress: () => _showSecretMessageActions(msg),
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: MediaQuery.sizeOf(context).width * 0.78,
                            minWidth: 76,
                          ),
                          child: Container(
                            margin: const EdgeInsets.symmetric(vertical: 5),
                            padding: const EdgeInsets.fromLTRB(14, 10, 12, 8),
                            decoration: BoxDecoration(
                              color: isMe
                                  ? const Color(0xFF176B59)
                                  : const Color(0xFF202733),
                              borderRadius: BorderRadius.only(
                                topLeft: const Radius.circular(18),
                                topRight: const Radius.circular(18),
                                bottomLeft: Radius.circular(isMe ? 18 : 5),
                                bottomRight: Radius.circular(isMe ? 5 : 18),
                              ),
                              border: Border.all(
                                color: isMe
                                    ? const Color(0xFF38E8A5).withOpacity(0.7)
                                    : const Color(0xFF718096).withOpacity(0.45),
                              ),
                              boxShadow: const [
                                BoxShadow(
                                  color: Color(0x22000000),
                                  blurRadius: 8,
                                  offset: Offset(0, 3),
                                ),
                              ],
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      isMe
                                          ? Icons.account_circle
                                          : Icons.shield_rounded,
                                      color: isMe
                                          ? const Color(0xFF8FFFD0)
                                          : const Color(0xFFFFD76A),
                                      size: 15,
                                    ),
                                    const SizedBox(width: 5),
                                    Text(
                                      msg["sender"]!,
                                      style: TextStyle(
                                        color: isMe
                                            ? const Color(0xFF8FFFD0)
                                            : const Color(0xFFFFD76A),
                                        fontSize: 11,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 5),
                                Text(
                                  msg["text"]!,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 14,
                                    height: 1.3,
                                  ),
                                  textDirection: TextDirection.rtl,
                                  softWrap: true,
                                ),
                                const SizedBox(height: 4),
                                Align(
                                  alignment: AlignmentDirectional.bottomEnd,
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        msg["time"] ?? _formatMessageTime(),
                                        style: const TextStyle(
                                          color: Colors.white54,
                                          fontSize: 10,
                                        ),
                                      ),
                                      if (isMe) ...[
                                        const SizedBox(width: 4),
                                        const Icon(
                                          Icons.done_all_rounded,
                                          size: 14,
                                          color: Color(0xFFB5E7D2),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  },

                ),
              ),

              Container(
                margin: const EdgeInsets.fromLTRB(10, 4, 10, 12),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFF18231F).withOpacity(0.98),
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(
                    color: const Color(0xFF38E8A5).withOpacity(0.45),
                  ),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x33000000),
                      blurRadius: 12,
                      offset: Offset(0, 4),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _messageController,
                        style: const TextStyle(color: Colors.white),
                        textDirection: TextDirection.rtl,
                        textAlign: TextAlign.start,
                        minLines: 1,
                        maxLines: 4,
                        textInputAction: TextInputAction.newline,
                        decoration: InputDecoration(
                          filled: false,
                          fillColor: Colors.transparent,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 11,
                          ),
                          hintText: 'اكتب رسالتك السرية',
                          hintStyle: TextStyle(
                            color: const Color(0xFFEAF4F0).withOpacity(0.9),
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                          ),
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                        ),
                        onSubmitted: (_) => _sendSecretMessage(),
                      ),
                    ),
                    IconButton(
                      icon: Icon(
                        _isSecretRecording
                            ? Icons.stop_circle_rounded
                            : Icons.mic_none_rounded,
                        color: _isSecretRecording
                            ? Colors.redAccent
                            : const Color(0xFF38E8A5),
                      ),
                      tooltip: _isSecretRecording ? 'إيقاف التسجيل' : 'تسجيل رسالة صوتية',
                      onPressed: _toggleSecretVoiceRecording,
                    ),
                    IconButton(
                      icon: const Icon(
                        Icons.send_rounded,
                        color: Color(0xFF38E8A5),
                      ),
                      onPressed: _sendSecretMessage,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ==========================================
// 4. إعدادات النظام وشاشات التطبيق
// ==========================================
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Directionality(
      textDirection: englishLanguageNotifier.value
          ? TextDirection.ltr
          : TextDirection.rtl,
      child: Scaffold(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        appBar: AppBar(
          title: Text(
            'إعدادات النظام',
            style: TextStyle(
              color: isDark ? Colors.white : Colors.black,
              fontWeight: FontWeight.bold,
            ),
          ),
          backgroundColor: isDark ? const Color(0xFF0B1D19) : Colors.white,
          foregroundColor: isDark ? Colors.white : Colors.black,
          iconTheme: IconThemeData(color: isDark ? Colors.white : Colors.black),
          centerTitle: true,
        ),
        body: ListView(
          children: [
            ValueListenableBuilder<bool>(
              valueListenable: englishLanguageNotifier,
              builder: (context, isEnglish, child) {
                return ListTile(
                  leading: Icon(
                    Icons.language,
                    color: isDark ? Colors.cyanAccent : Colors.black,
                  ),
                  title: Text(
                    isEnglish ? 'Language' : 'اللغة',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurface,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  subtitle: Text(
                    isEnglish ? 'Choose the app language' : 'اختار لغة التطبيق',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  trailing: DropdownButton<bool>(
                    value: isEnglish,
                    dropdownColor: isDark ? Colors.grey[900] : Colors.white,
                    underline: const SizedBox.shrink(),
                    items: [
                      DropdownMenuItem(
                        value: false,
                        child: Text(
                          'العربية',
                          style: const TextStyle(color: Colors.white),
                        ),
                      ),
                      DropdownMenuItem(
                        value: true,
                        child: Text(
                          'English',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                        ),
                      ),
                    ],
                    onChanged: (value) {
                      if (value != null) englishLanguageNotifier.value = value;
                    },
                  ),
                );
              },
            ),
            Divider(color: Theme.of(context).dividerColor),
            ListTile(
              leading: Icon(
                Icons.folder_special,
                color: isDark ? const Color(0xFF00FF66) : Colors.black,
              ),
              title: Text(
                'الإعدادات المتغيرة',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurface,
                  fontWeight: FontWeight.bold,
                ),
              ),
              subtitle: Text(
                'تحكم في الحركة، الصوت، والتشفير التلقائي',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              trailing: Icon(
                Icons.arrow_forward_ios,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                size: 16,
              ),
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const DynamicSettingsScreen(),
                  ),
                );
              },
            ),
            Divider(color: Theme.of(context).dividerColor),
            ListTile(
              leading: Icon(
                Icons.security,
                color: isDark ? Colors.cyanAccent : Colors.black,
              ),
              title: Text(
                'الخصوصية والأمان',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurface,
                  fontWeight: FontWeight.bold,
                ),
              ),
              subtitle: Text(
                'الوضع الخفي، قفل التطبيق، وحذف السجل',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              trailing: Icon(
                Icons.arrow_forward_ios,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                size: 16,
              ),
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const PrivacySettingsScreen(),
                  ),
                );
              },
            ),
            Divider(color: Theme.of(context).dividerColor),
            ListTile(
              leading: Icon(
                Icons.account_circle,
                color: isDark ? const Color(0xFF38E8A5) : Colors.black,
              ),
              title: Text(
                'الحساب والمظهر',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurface,
                  fontWeight: FontWeight.bold,
                ),
              ),
              subtitle: Text(
                'الملف الشخصي وتخصيص المظهر والألوان',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              trailing: Icon(
                Icons.arrow_forward_ios,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                size: 16,
              ),
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const AccountAndThemeScreen(),
                  ),
                );
              },
            ),
            Divider(color: Theme.of(context).dividerColor),
            ListTile(
              leading: Icon(
                Icons.notifications_active,
                color: isDark ? Colors.pinkAccent : Colors.black,
              ),
              title: Text(
                'الإشعارات والأصوات',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurface,
                  fontWeight: FontWeight.bold,
                ),
              ),
              subtitle: Text(
                'تخصيص نغمات التنبيه والاهتزاز',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              trailing: Icon(
                Icons.arrow_forward_ios,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                size: 16,
              ),
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const NotificationsScreen(),
                  ),
                );
              },
            ),
            Divider(color: Theme.of(context).dividerColor),
            ListTile(
              leading: Icon(
                Icons.info_outline,
                color: isDark ? Colors.blueAccent : Colors.black,
              ),
              title: Text(
                'حول التطبيق',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurface,
                  fontWeight: FontWeight.bold,
                ),
              ),
              subtitle: Text(
                'Shadow Chat BETA v1.0.0-beta.1 ومعلومات المبرمج',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              trailing: Icon(
                Icons.arrow_forward_ios,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                size: 16,
              ),
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const AboutAppScreen(),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class DynamicSettingsScreen extends StatelessWidget {
  const DynamicSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        appBar: AppBar(
          title: Text(
            'الإعدادات المتغيرة',
            style: TextStyle(
              color: isDark ? Colors.white : Colors.black,
              fontWeight: FontWeight.bold,
            ),
          ),
          backgroundColor: Theme.of(context).appBarTheme.backgroundColor,
          foregroundColor: isDark ? Colors.white : Colors.black,
          iconTheme: IconThemeData(color: isDark ? Colors.white : Colors.black),
          centerTitle: true,
        ),
        body: ListView(
          children: [
            ValueListenableBuilder<bool>(
              valueListenable: whaleMotionNotifier,
              builder: (context, isMoving, child) {
                return SwitchListTile(
                  secondary: Icon(
                    Icons.waves,
                    color: Theme.of(context).brightness == Brightness.dark
                        ? Colors.cyanAccent
                        : Colors.black,
                  ),
                  title: Text(
                    'تحريك خلفية الحوت',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                  subtitle: Text(
                    'تفعيل أو إيقاف حركة طفو الحوت في الخلفية',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  value: isMoving,
                  activeColor: isDark ? const Color(0xFF00FF66) : Colors.black,
                  onChanged: (bool value) {
                    whaleMotionNotifier.value = value;
                  },
                );
              },
            ),
            Divider(color: Theme.of(context).dividerColor),
            ValueListenableBuilder<bool>(
              valueListenable: whaleSoundNotifier,
              builder: (context, isSoundEnabled, child) {
                return SwitchListTile(
                  secondary: Icon(
                    Icons.volume_up,
                    color: Theme.of(context).brightness == Brightness.dark
                        ? Colors.pinkAccent
                        : Colors.black,
                  ),
                  title: Text(
                    'صوت ترحيب الحوت',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                  subtitle: Text(
                    'تشغيل أو إيقاف المؤثر الصوتي عند فتح الشات',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  value: isSoundEnabled,
                  activeColor: isDark ? const Color(0xFF00FF66) : Colors.black,
                  onChanged: (bool value) {
                    whaleSoundNotifier.value = value;
                  },
                );
              },
            ),
            Divider(color: Theme.of(context).dividerColor),
            ValueListenableBuilder<bool>(
              valueListenable: autoEncryptNotifier,
              builder: (context, isAutoEncryptEnabled, child) {
                return SwitchListTile(
                  secondary: Icon(
                    Icons.security,
                    color: Theme.of(context).brightness == Brightness.dark
                        ? const Color(0xFF00FF66)
                        : Colors.black,
                  ),
                  title: Text(
                    'تشفير الرسائل التلقائي',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                  subtitle: Text(
                    'تشفير كل رسالة جديدة فور إرسالها تلقائياً',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  value: isAutoEncryptEnabled,
                  activeColor: isDark ? const Color(0xFF00FF66) : Colors.black,
                  onChanged: (bool value) {
                    autoEncryptNotifier.value = value;
                  },
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class PrivacySettingsScreen extends StatefulWidget {
  const PrivacySettingsScreen({super.key});

  @override
  State<PrivacySettingsScreen> createState() => _PrivacySettingsScreenState();
}

class _PrivacySettingsScreenState extends State<PrivacySettingsScreen> {
  bool _appLockEnabled = false;
  bool _ghostModeEnabled = true;
  bool _autoDeleteMessages = false;

  @override
  void initState() {
    super.initState();
    _appLockEnabled = appLockEnabledNotifier.value;
    _ghostModeEnabled = ghostModeNotifier.value;
    _autoDeleteMessages = autoDeleteMessagesNotifier.value;
    _loadPrivacySettings();
  }

  Future<void> _loadPrivacySettings() async {
    final settings = await loadPrivacySettings();
    if (!mounted) return;
    setState(() {
      if (settings['ghostMode'] is bool) {
        _ghostModeEnabled = settings['ghostMode'] as bool;
        ghostModeNotifier.value = _ghostModeEnabled;
      }
      if (settings['autoDeleteMessages'] is bool) {
        _autoDeleteMessages = settings['autoDeleteMessages'] as bool;
        autoDeleteMessagesNotifier.value = _autoDeleteMessages;
      }
      if (settings['messageSound'] is bool) {
        messageSoundNotifier.value = settings['messageSound'] as bool;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        appBar: AppBar(
          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'الخصوصية والأمان',
                style: TextStyle(
                  color: isDark ? Colors.white : Colors.black,
                  fontWeight: FontWeight.bold,
                ),
              ),
              SizedBox(width: 8),
              Icon(
                Icons.lock,
                color: isDark ? const Color(0xFF00FF66) : Colors.black,
                size: 20,
              ),
            ],
          ),
          backgroundColor: Theme.of(context).appBarTheme.backgroundColor,
          centerTitle: true,
        ),
        body: ListView(
          padding: const EdgeInsets.all(16.0),
          children: [
            Text(
              'حماية التطبيق',
              style: TextStyle(
                color: isDark ? const Color(0xFF00FF66) : Colors.black,
                fontWeight: FontWeight.bold,
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 10),
            SwitchListTile(
              secondary: Icon(
                Icons.fingerprint,
                color: Theme.of(context).brightness == Brightness.dark
                    ? const Color(0xFF63F5C2)
                    : Colors.black,
              ),
              title: Text(
                'قفل التطبيق بالبصمة / كلمة السر',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
              subtitle: Text(
                'طلب التحقق عند فتح Shadow Chat',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              value: _appLockEnabled,
              activeColor: isDark ? const Color(0xFF00FF66) : Colors.black,
              onChanged: (bool value) async {
                if (value) {
                  _setAppLockPassword();
                  return;
                }
                final currentHash = appLockPasswordNotifier.value;
                if (currentHash == null) return;
                await saveAppLockSettings(
                  enabled: false,
                  passwordHash: currentHash,
                );
                if (mounted) setState(() => _appLockEnabled = false);
              },
            ),
            ValueListenableBuilder<String?>(
              valueListenable: appLockPasswordNotifier,
              builder: (context, passwordHash, child) {
                if (passwordHash == null || !appLockEnabledNotifier.value)
                  return const SizedBox.shrink();
                return ListTile(
                  leading: Icon(
                    Icons.password_rounded,
                    color: isDark ? Colors.amberAccent : Colors.black,
                  ),
                  title: Text(
                    'كلمة سر قفل التطبيق',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                  subtitle: Text(
                    'كلمة السر ثابتة ومربوطة بإعدادات Firebase',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  trailing: Icon(
                    Icons.arrow_forward_ios,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    size: 16,
                  ),
                  onTap: () => showChangeAppLockPasswordDialog(context),
                );
              },
            ),
            Divider(color: Theme.of(context).dividerColor, height: 30),
            Text(
              'خصوصية المحادثات',
              style: TextStyle(
                color: isDark ? const Color(0xFF00FF66) : Colors.black,
                fontWeight: FontWeight.bold,
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 10),
            ValueListenableBuilder<bool>(
              valueListenable: ghostModeNotifier,
              builder: (context, isGhostModeEnabled, child) {
                return SwitchListTile(
                  secondary: Icon(
                    Icons.visibility_off,
                    color: Theme.of(context).brightness == Brightness.dark
                        ? Colors.purpleAccent
                        : Colors.black,
                  ),
                  title: Text(
                    'الوضع الخفي (Ghost Mode)',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                  subtitle: Text(
                    'إخفاء مؤشر "جاري الكتابة" وحالة الاتصال',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  value: isGhostModeEnabled,
                  activeColor: isDark ? const Color(0xFF00FF66) : Colors.black,
                  onChanged: (bool value) {
                    ghostModeNotifier.value = value;
                    savePrivacySetting('ghostMode', value);
                    setState(() => _ghostModeEnabled = value);
                  },
                );
              },
            ),
            SwitchListTile(
              secondary: Icon(
                Icons.timer_off,
                color: Theme.of(context).brightness == Brightness.dark
                    ? Colors.orangeAccent
                    : Colors.black,
              ),
              title: Text(
                'الرسائل ذاتية التدمير',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
              subtitle: Text(
                'حذف الرسائل تلقائياً بعد قراءتها',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              value: autoDeleteMessagesNotifier.value,
              activeColor: isDark ? const Color(0xFF00FF66) : Colors.black,
              onChanged: (bool value) {
                autoDeleteMessagesNotifier.value = value;
                savePrivacySetting('autoDeleteMessages', value);
                setState(() {
                  _autoDeleteMessages = value;
                });
              },
            ),
            ValueListenableBuilder<bool>(
              valueListenable: secretGroupLockEnabledNotifier,
              builder: (context, isLocked, child) {
                return SwitchListTile(
                  secondary: Icon(
                    Icons.groups_rounded,
                    color: isDark ? Colors.amberAccent : Colors.black,
                  ),
                  title: Text(
                    'قفل المجموعة السرية',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                  subtitle: Text(
                    isLocked
                        ? 'المجموعة محمية بكلمة سر خاصة بك'
                        : 'المجموعة مفتوحة بدون كلمة سر',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  value: isLocked,
                  activeColor: isDark ? Colors.amberAccent : Colors.black,
                  onChanged: (value) {
                    if (value) {
                      _showSecretGroupPasswordDialog();
                    } else {
                      unawaited(disableSecretGroupLock());
                    }
                  },
                );
              },
            ),
            ValueListenableBuilder<bool>(
              valueListenable: secretGroupLockEnabledNotifier,
              builder: (context, isLocked, child) {
                if (!isLocked) return const SizedBox.shrink();
                return ListTile(
                  leading: Icon(
                    Icons.password_rounded,
                    color: isDark ? Colors.amberAccent : Colors.black,
                  ),
                  title: Text(
                    'تغيير كلمة سر المجموعة',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                  trailing: const Icon(Icons.arrow_forward_ios, size: 16),
                  onTap: () => _showSecretGroupPasswordDialog(changing: true),
                );
              },
            ),
            Divider(color: Theme.of(context).dividerColor, height: 30),
            const Text(
              'إدارة البيانات',
              style: TextStyle(
                color: Colors.redAccent,
                fontWeight: FontWeight.bold,
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 10),
            ListTile(
              leading: const Icon(
                Icons.delete_forever,
                color: Colors.redAccent,
              ),
              title: Text(
                'حذف سجل المحادثات بالكامل',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
              subtitle: Text(
                'مسح كافة الرسائل المخزنة نهائياً',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              onTap: () {
                _showDeleteConfirmationDialog(context);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _setAppLockPassword() {
    final TextEditingController passwordController = TextEditingController();
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: const Text(
          'تفعيل قفل التطبيق',
          style: TextStyle(color: Color(0xFF00FF66)),
        ),
        content: TextField(
          controller: passwordController,
          obscureText: true,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            hintText: 'اكتب كلمة مرورك هنا',
            hintStyle: TextStyle(color: Colors.black),
            filled: true,
            fillColor: Colors.white,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('إلغاء', style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () async {
              final String password = passwordController.text.trim();
              if (password.isEmpty) return;
              if (password.length < 4) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('كلمة السر يجب أن تكون 4 أحرف على الأقل'),
                  ),
                );
                return;
              }
              await saveAppLockSettings(
                enabled: true,
                passwordHash: await hashPassword(password),
              );
              if (!mounted) return;
              setState(() => _appLockEnabled = true);
              if (dialogContext.mounted) Navigator.pop(dialogContext);
            },
            child: const Text(
              'تفعيل',
              style: TextStyle(color: Color(0xFF00FF66)),
            ),
          ),
        ],
      ),
    ).then((_) => passwordController.dispose());
  }

  void _showSecretGroupPasswordDialog({bool changing = false}) {
    final oldController = TextEditingController();
    final newController = TextEditingController();
    final confirmController = TextEditingController();
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(changing ? 'تغيير كلمة سر المجموعة' : 'قفل المجموعة السرية'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (changing)
              TextField(
                controller: oldController,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'كلمة السر الحالية'),
              ),
            TextField(
              controller: newController,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'كلمة السر الجديدة'),
            ),
            TextField(
              controller: confirmController,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'تأكيد كلمة السر'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('إلغاء'),
          ),
          ElevatedButton(
            onPressed: () async {
              final newPassword = newController.text.trim();
              final currentHash = secretGroupPasswordHashNotifier.value;
              final oldPasswordValid = !changing ||
                  (currentHash != null &&
                      await hashPassword(oldController.text.trim()) == currentHash);
              if (!oldPasswordValid ||
                  newPassword.length < 4 ||
                  newPassword != confirmController.text.trim()) {
                debugPrint('Secret group password validation failed');
                return;
              }
              await saveSecretGroupPassword(newPassword);
              if (dialogContext.mounted) Navigator.pop(dialogContext);
            },
            child: const Text('حفظ'),
          ),
        ],
      ),
    ).then((_) {
      oldController.dispose();
      newController.dispose();
      confirmController.dispose();
    });
  }

  void _showDeleteConfirmationDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (BuildContext dialogContext) {
        return Directionality(
          textDirection: TextDirection.rtl,
          child: AlertDialog(
            backgroundColor: Colors.grey[900],
            title: const Text(
              'تحذير أمني',
              style: TextStyle(color: Colors.redAccent),
            ),
            content: const Text(
              'هل أنت متأكد من حذف جميع سجلات الشات نهائياً؟ لا يمكن التراجع عن هذه الخطوة.',
              style: TextStyle(color: Colors.white70),
            ),
            actions: [
              TextButton(
                child: const Text(
                  'إلغاء',
                  style: TextStyle(color: Colors.cyanAccent),
                ),
                onPressed: () => Navigator.of(dialogContext).pop(),
              ),
              TextButton(
                child: const Text(
                  'حذف الكل',
                  style: TextStyle(color: Colors.redAccent),
                ),
                onPressed: () async {
                  clearHistoryNotifier.value++;
                  Navigator.of(dialogContext).pop();
                  try {
                    await deleteAllChatHistoryForUser();
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('تم حذف سجل المحادثات من Firebase'),
                        ),
                      );
                    }
                  } catch (error) {
                    if (context.mounted) {
                      showGenericFailureSnackBar(context);
                    }
                    debugPrint('Full history delete action error: $error');
                  }
                },
              ),
            ],
          ),
        );
      },
    );
  }
}

class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        appBar: AppBar(
          title: Text(
            'الإشعارات والأصوات',
            style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
          ),
          backgroundColor: Theme.of(context).appBarTheme.backgroundColor,
          centerTitle: true,
        ),
        body: ListView(
          padding: const EdgeInsets.all(16.0),
          children: [
            ValueListenableBuilder<bool>(
              valueListenable: messageSoundNotifier,
              builder: (context, isSoundEnabled, child) => SwitchListTile(
                secondary: Icon(
                  Icons.music_note,
                  color: isDark ? Colors.pinkAccent : Colors.black,
                ),
                title: Text(
                  'صوت الرسائل الواردة',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
                value: isSoundEnabled,
                activeColor: isDark ? const Color(0xFF38E8A5) : Colors.black,
                onChanged: (value) {
                  messageSoundNotifier.value = value;
                  unawaited(savePrivacySetting('messageSound', value));
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class AboutAppScreen extends StatelessWidget {
  const AboutAppScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final isDark = true;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          title: const Text(
            'حول التطبيق',
            style: TextStyle(color: Colors.white),
          ),
          backgroundColor: Colors.black87,
          centerTitle: true,
          iconTheme: const IconThemeData(color: Colors.white),
        ),
        body: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: isDark ? const Color(0xFF00FF66) : Colors.black,
                    width: 2,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF00FF66).withOpacity(0.4),
                      blurRadius: 20,
                      spreadRadius: 5,
                    ),
                  ],
                ),
                child: Icon(
                  Icons.code,
                  size: 50,
                  color: const Color(0xFF00FF66),
                ),
              ),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.public, color: Colors.cyanAccent, size: 20),
                  SizedBox(width: 8),
                  Text(
                    '🌑 SHADOW CHAT',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.2,
                    ),
                  ),
                  SizedBox(width: 8),
                  Icon(Icons.public, color: Colors.cyanAccent, size: 20),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                'BETA Version v1.0.0-beta.1',
                style: TextStyle(color: Colors.white54, fontSize: 14),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 30),
                child: Divider(color: Colors.white24, thickness: 1),
              ),
              const Text(
                'من خلف الظل:',
                style: TextStyle(color: Color(0xFF00FF66), fontSize: 13),
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    'Eng. Hatem',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  SizedBox(width: 8),
                  Icon(Icons.public, color: Colors.cyanAccent, size: 20),
                  SizedBox(width: 4),
                  Text('✨', style: TextStyle(fontSize: 18)),
                ],
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFF00FF66).withOpacity(0.15),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: const Color(0xFF00FF66).withOpacity(0.5),
                  ),
                ),
                child: const Text(
                  '« مساحة خاصة »',
                  style: TextStyle(
                    color: Color(0xFF00FF66),
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(height: 25),
              const Text(
                'مساحة هادئة للمحادثات الخاصة بعيداً عن الضوضاء.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 13,
                  height: 1.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ==========================================
// 5. شاشة الشات العادية (بدون AppBar - عائمة في الماء)
// ==========================================
class _VideoMessagePlayer extends StatefulWidget {
  final XFile? mediaFile;
  final String? mediaUrl;

  const _VideoMessagePlayer({this.mediaFile, this.mediaUrl});

  @override
  State<_VideoMessagePlayer> createState() => _VideoMessagePlayerState();
}

class _VideoMessagePlayerState extends State<_VideoMessagePlayer> {
  VideoPlayerController? _controller;

  @override
  void initState() {
    super.initState();
    _initializeVideo();
  }

  Future<void> _initializeVideo() async {
    final controller = widget.mediaFile != null
        ? VideoPlayerController.file(File(widget.mediaFile!.path))
        : widget.mediaUrl != null && widget.mediaUrl!.isNotEmpty
        ? VideoPlayerController.networkUrl(Uri.parse(widget.mediaUrl!))
        : null;
    if (controller == null) return;
    _controller = controller;
    try {
      await controller.initialize();
      if (mounted) setState(() {});
    } catch (error) {
      debugPrint('Video message playback error: $error');
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final mediaWidth = MediaQuery.sizeOf(context).width < 600
        ? MediaQuery.sizeOf(context).width * 0.72
        : 340.0;
    if (controller == null || !controller.value.isInitialized) {
      return Container(
        width: mediaWidth,
        height: mediaWidth * 0.62,
        decoration: BoxDecoration(
          color: Colors.grey[800],
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Center(
          child: CircularProgressIndicator(
            valueColor: AlwaysStoppedAnimation<Color>(Colors.amberAccent),
          ),
        ),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Stack(
        alignment: Alignment.center,
        children: [
          SizedBox(
            width: mediaWidth,
            child: AspectRatio(
              aspectRatio: controller.value.aspectRatio,
              child: VideoPlayer(controller),
            ),
          ),
          IconButton(
            iconSize: 52,
            color: Colors.white,
            icon: Icon(
              controller.value.isPlaying
                  ? Icons.pause_circle_filled
                  : Icons.play_circle_fill,
            ),
            onPressed: () {
              setState(() {
                controller.value.isPlaying
                    ? controller.pause()
                    : controller.play();
              });
            },
          ),
        ],
      ),
    );
  }
}

class Message {
  final String originalText;
  final String encryptedData; // هنحفظ هنا النص المتشفر بجد
  bool isEncrypted;
  final bool isMe;
  final String? firestoreId;
  final String? time;
  final String? mediaType;
  final XFile? mediaFile;
  final String? mediaUrl;

  Duration? voiceDuration;
  bool isPlayingVoice;
  Duration currentPlaybackPosition;

  Message({
    required this.originalText,
    required this.encryptedData,
    required this.isMe,
    this.firestoreId,
    this.time,
    this.isEncrypted = false,
    this.mediaType,
    this.mediaFile,
    this.mediaUrl,
    this.voiceDuration,
    this.isPlayingVoice = false,
    this.currentPlaybackPosition = Duration.zero,
  });

  String get displayText {
    if (!isEncrypted) return originalText;
    // الشكل السري الغامض (المربعات) مع الحفاظ على التشفير الحقيقي جواه
    return encryptedData.replaceAll(RegExp(r'[^\s]'), '█');
  }
}

class _MediaOption extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _MediaOption({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 34),
            const SizedBox(height: 6),
            Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ShellClipper extends CustomClipper<Path> {
  @override
  Path getClip(Size size) {
    final Path path = Path()..moveTo(22, 0);
    path.quadraticBezierTo(size.width * 0.25, 8, size.width * 0.42, 0);
    path.quadraticBezierTo(size.width * 0.58, -8, size.width * 0.74, 0);
    path.quadraticBezierTo(size.width * 0.9, 8, size.width - 22, 0);
    path.quadraticBezierTo(size.width, 0, size.width, 22);
    path.lineTo(size.width, size.height - 22);
    path.quadraticBezierTo(
      size.width,
      size.height,
      size.width - 22,
      size.height,
    );
    path.quadraticBezierTo(
      size.width * 0.75,
      size.height - 8,
      size.width * 0.58,
      size.height,
    );
    path.quadraticBezierTo(
      size.width * 0.42,
      size.height + 8,
      size.width * 0.26,
      size.height,
    );
    path.quadraticBezierTo(8, size.height - 8, 22, size.height);
    path.quadraticBezierTo(0, size.height, 0, size.height - 22);
    path.lineTo(0, 22);
    path.quadraticBezierTo(0, 0, 22, 0);
    return path;
  }

  @override
  bool shouldReclip(covariant CustomClipper<Path> oldClipper) => false;
}

class _ShellBorderPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..color = const Color(0xFF00FF66).withOpacity(0.5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.3;
    canvas.drawPath(_ShellClipper().getClip(size), paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _FloatingChatButton extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String tooltip;
  final VoidCallback onPressed;

  const _FloatingChatButton({
    required this.icon,
    required this.color,
    required this.tooltip,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(
        icon,
        color: color,
        shadows: [Shadow(color: color.withOpacity(0.8), blurRadius: 12)],
      ),
      tooltip: tooltip,
      onPressed: onPressed,
    );
  }
}

class _SeaShellPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final Path shell = Path()..moveTo(24, 6);
    shell.quadraticBezierTo(size.width * 0.18, 14, size.width * 0.3, 7);
    shell.quadraticBezierTo(size.width * 0.42, 0, size.width * 0.54, 7);
    shell.quadraticBezierTo(size.width * 0.66, 14, size.width * 0.78, 7);
    shell.quadraticBezierTo(size.width * 0.9, 0, size.width - 24, 6);
    shell.quadraticBezierTo(size.width, 8, size.width - 4, 22);
    shell.lineTo(size.width - 4, size.height - 20);
    shell.quadraticBezierTo(
      size.width - 8,
      size.height - 6,
      size.width - 24,
      size.height - 6,
    );
    shell.quadraticBezierTo(
      size.width * 0.78,
      size.height - 14,
      size.width * 0.66,
      size.height - 6,
    );
    shell.quadraticBezierTo(
      size.width * 0.54,
      size.height + 2,
      size.width * 0.42,
      size.height - 6,
    );
    shell.quadraticBezierTo(
      size.width * 0.3,
      size.height - 14,
      size.width * 0.18,
      size.height - 6,
    );
    shell.quadraticBezierTo(8, size.height - 6, 4, size.height - 20);
    shell.lineTo(4, 22);
    shell.quadraticBezierTo(0, 8, 24, 6);
    shell.close();
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _ShellMediaPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final Rect bounds = Rect.fromLTWH(5, 4, size.width - 10, size.height - 8);
    final Paint fill = Paint()
      ..shader = const LinearGradient(
        colors: [Color(0xFF174B38), Color(0xFF0B2119)],
      ).createShader(bounds);
    final Paint outline = Paint()
      ..color = Colors.amberAccent.withOpacity(0.8)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4;
    final Path shell = Path()
      ..moveTo(7, size.height - 9)
      ..quadraticBezierTo(size.width * 0.16, 5, size.width * 0.5, 6)
      ..quadraticBezierTo(size.width * 0.84, 5, size.width - 7, size.height - 9)
      ..quadraticBezierTo(size.width * 0.5, size.height + 2, 7, size.height - 9)
      ..close();
    canvas.drawPath(shell, fill);
    canvas.drawPath(shell, outline);

    final Paint ridges = Paint()
      ..color = const Color(0x99FFDF75)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (int index = 1; index < 5; index++) {
      final double x = size.width * index / 5;
      canvas.drawLine(Offset(7, size.height - 10), Offset(x, 8), ridges);
    }
    canvas.drawArc(
      Rect.fromCircle(
        center: Offset(size.width * 0.58, size.height * 0.55),
        radius: 6,
      ),
      0.4,
      4.8,
      false,
      ridges,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class ChatScreen extends StatefulWidget {
  final String chatName;
  final String? contactUid;

  const ChatScreen({
    super.key,
    this.chatName = '✨ 🌑 SHADOW CHAT 🌑 ✨',
    this.contactUid,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with TickerProviderStateMixin {
  final List<Message> _messages = [];
  final ScrollController _messagesScrollController = ScrollController();
  final TextEditingController _controller = TextEditingController();
  final AudioPlayer _chatAudioPlayer = AudioPlayer();
  final AudioPlayer _messageNotificationPlayer = AudioPlayer();
  final AudioPlayer _mediaAudioPlayer = AudioPlayer();
  final AudioRecorder _voiceRecorder = AudioRecorder();
  final ImagePicker _mediaPicker = ImagePicker();

  late AnimationController _whaleController;
  late Animation<double> _whaleAnimation;

  late AnimationController _launchController;
  late AnimationController _lockPulseController;
  late Animation<double> _lockPulseAnimation;
  bool _isLaunching = false;
  bool _isRecording = false;
  bool _isOtherTyping = false;
  bool _hasLoadedMessages = false;
  bool _chatLocked = false;
  bool _directAccessChecked = false;
  bool _directAccessApproved = true;
  String? _chatPassword;
  final TextEditingController _chatPasswordController = TextEditingController();
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>?
  _messagesSubscription;

  Stream<DocumentSnapshot<Map<String, dynamic>>>? get _contactPresenceStream {
    if (!firebaseReady || widget.contactUid == null) return null;
    return FirebaseFirestore.instance
      .collection('publicProfiles')
        .doc(widget.contactUid)
        .snapshots();
  }

  String _presenceText(Map<String, dynamic>? data) {
    if (data?['ghostMode'] == true) return appText('الحالة مخفية', 'Status hidden');
    final value = data?['lastSeen'] ?? data?['lastSeenAt'];
    DateTime? date;
    if (value is Timestamp) {
      date = value.toDate().toLocal();
    } else if (value is DateTime) {
      date = value.toLocal();
    } else if (value is String) {
      date = DateTime.tryParse(value)?.toLocal();
    }
    if (data?['isOnline'] == true &&
        date != null &&
        DateTime.now().difference(date).abs() <= const Duration(minutes: 2)) {
      return 'متصل الآن';
    }
    if (date == null) return 'آخر ظهور غير متاح';
    final localizations = MaterialLocalizations.of(context);
    final formattedDate = localizations.formatShortDate(date);
    final formattedTime = localizations.formatTimeOfDay(
      TimeOfDay.fromDateTime(date),
    );
    return 'آخر ظهور $formattedDate - $formattedTime';
  }

  String _messageTime(dynamic value) {
    final date = value is Timestamp ? value.toDate().toLocal() : DateTime.now();
    return '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
  }

  String get _localVoiceMessagesKey => 'local_voice_messages_$_chatId';

  Future<void> _loadLocalVoiceMessages() async {
    final preferences = await getSafeSharedPreferences();
    if (preferences == null) return;
    try {
      final encoded = preferences.getString(_localVoiceMessagesKey);
      if (encoded == null || encoded.isEmpty) return;
      final storedMessages = jsonDecode(encoded);
      if (storedMessages is! List) return;

      final restoredMessages = <Message>[];
      for (final item in storedMessages) {
        if (item is! Map) continue;
        final path = item['path'];
        if (path is! String || !await File(path).exists()) continue;
        restoredMessages.add(
          Message(
            originalText: '🎙️ رسالة صوتية',
            encryptedData: path,
            isMe: true,
            time: item['time'] as String? ?? _messageTime(null),
            mediaType: 'audio',
            mediaFile: XFile(path),
            mediaUrl: 'local://$path',
          ),
        );
      }
      if (mounted && restoredMessages.isNotEmpty) {
        setState(() => _messages.addAll(restoredMessages));
      }
    } catch (error) {
      debugPrint('Local voice messages load error: $error');
    }
  }

  Future<void> _saveLocalVoiceMessage(String path, String time) async {
    final preferences = await getSafeSharedPreferences();
    if (preferences == null) return;
    try {
      final storedMessages = <Map<String, String>>[];
      final encoded = preferences.getString(_localVoiceMessagesKey);
      if (encoded != null && encoded.isNotEmpty) {
        final decoded = jsonDecode(encoded);
        if (decoded is List) {
          for (final item in decoded) {
            if (item is Map && item['path'] is String) {
              storedMessages.add({
                'path': item['path'] as String,
                'time': item['time'] as String? ?? time,
              });
            }
          }
        }
      }
      if (storedMessages.every((item) => item['path'] != path)) {
        storedMessages.add({'path': path, 'time': time});
      }
      await preferences.setString(
        _localVoiceMessagesKey,
        jsonEncode(storedMessages),
      );
    } catch (error) {
      debugPrint('Local voice message save error: $error');
    }
  }

  Future<void> _ensureDirectChatAccess() async {
    final contactUid = widget.contactUid;
    if (contactUid == null || contactUid.isEmpty) {
      if (mounted) setState(() => _directAccessChecked = true);
      return;
    }
    final approved = await _hasApprovedDirectContact(contactUid);
    if (approved) {
      if (mounted) {
        setState(() {
          _directAccessApproved = true;
          _directAccessChecked = true;
        });
        _listenToChatMessages();
      }
      return;
    }

    if (!mounted) return;
    setState(() {
      _directAccessApproved = false;
      _directAccessChecked = true;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('لا يمكنك الدخول إلى هذه الدردشة إلا بعد موافقة الطرف الآخر'),
      ),
    );
    Navigator.of(context).maybePop();
  }

  @override
  void initState() {
    super.initState();
    clearHistoryNotifier.addListener(_clearChatMessages);
    whaleMotionNotifier.addListener(_onWhaleMotionChanged);
    whaleSoundNotifier.addListener(_onWhaleSoundChanged);
    _chatPassword = chatPasswordsNotifier.value[widget.chatName];
    _chatLocked = _chatPassword != null;
    _loadChatPassword();
    _loadLocalVoiceMessages();
    if (widget.contactUid != null && widget.contactUid!.isNotEmpty) {
      unawaited(_ensureDirectChatAccess());
    } else {
      _directAccessChecked = true;
      _listenToChatMessages();
    }
    _whaleController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 8),
    );
    if (whaleMotionNotifier.value) {
      _whaleController.repeat(reverse: true);
    }

    _whaleAnimation = Tween<double>(begin: -12.0, end: 12.0).animate(
      CurvedAnimation(parent: _whaleController, curve: Curves.easeInOut),
    );

    _launchController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2500),
    );
    _lockPulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat(reverse: true);
    _lockPulseAnimation = Tween<double>(begin: 0.94, end: 1.04).animate(
      CurvedAnimation(parent: _lockPulseController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _messagesSubscription?.cancel();
    clearHistoryNotifier.removeListener(_clearChatMessages);
    whaleMotionNotifier.removeListener(_onWhaleMotionChanged);
    whaleSoundNotifier.removeListener(_onWhaleSoundChanged);
    _chatAudioPlayer.dispose();
    _messageNotificationPlayer.dispose();
    _mediaAudioPlayer.dispose();
    _whaleController.dispose();
    _launchController.dispose();
    _lockPulseController.dispose();
    unawaited(_voiceRecorder.stop());
    _voiceRecorder.dispose();
    _messagesScrollController.dispose();
    _controller.dispose();
    _chatPasswordController.dispose();
    super.dispose();
  }

  void _clearChatMessages() {
    if (mounted) setState(_messages.clear);
  }

  void _scrollToLatestMessage({required bool force}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_messagesScrollController.hasClients) return;
      final position = _messagesScrollController.position;
      final isNearLatest =
          position.maxScrollExtent - position.pixels <= 120;
      if (force || isNearLatest) {
        unawaited(
          _messagesScrollController.animateTo(
            position.maxScrollExtent,
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOut,
          ),
        );
      }
    });
  }

  void _onWhaleSoundChanged() {
    if (!whaleSoundNotifier.value) {
      unawaited(_stopWhaleSound());
    }
  }

  void _onWhaleMotionChanged() {
    if (whaleMotionNotifier.value) {
      _whaleController.repeat(reverse: true);
    } else {
      _whaleController.stop();
    }
  }

  Future<void> _stopWhaleSound() async {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.linux) return;
    try {
      await _chatAudioPlayer.stop().timeout(const Duration(milliseconds: 300));
    } catch (_) {}
  }

  String get _chatId {
    if (widget.contactUid != null && widget.contactUid!.isNotEmpty) {
      final currentUid = FirebaseAuth.instance.currentUser?.uid;
      if (currentUid != null && currentUid.isNotEmpty) {
        return directChatDocumentId(currentUid, widget.contactUid!);
      }
    }
    return chatDocumentId(widget.chatName);
  }

  Future<void> _loadChatPassword() async {
    if (!firebaseReady) {
      _playWhaleIfChatUnlocked();
      return;
    }
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      _playWhaleIfChatUnlocked();
      return;
    }
    try {
      final snapshot = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .collection('chatSecurity')
          .doc(_chatId)
          .get();
      final passwordHash = snapshot.data()?['passwordHash'];
      if (passwordHash is String && mounted) {
        await _chatAudioPlayer.stop();
        setState(() {
          _chatPassword = passwordHash;
          _chatLocked = true;
        });
      } else {
        _playWhaleIfChatUnlocked();
      }
    } catch (error) {
      debugPrint('Chat password load error: $error');
      _playWhaleIfChatUnlocked();
    }
  }

  void _playWhaleIfChatUnlocked() {
    if (_chatLocked || !whaleSoundNotifier.value) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_chatLocked) unawaited(_playWhaleSound());
    });
  }

  void _listenToChatMessages() {
    if (!firebaseReady) return;
    unawaited(deleteExpiredOwnChatMessages(_chatId));
    _messagesSubscription = FirebaseFirestore.instance
        .collection('chats')
        .doc(_chatId)
        .collection('messages')
      .orderBy('createdAt', descending: true)
        .limit(100)
        .snapshots()
        .listen(
          (snapshot) {
            if (!mounted) return;
            final currentUid = FirebaseAuth.instance.currentUser?.uid;
            final isFirstSnapshot = !_hasLoadedMessages;
            final shouldFollowLatest = isFirstSnapshot ||
                !_messagesScrollController.hasClients ||
                _messagesScrollController.position.maxScrollExtent -
                        _messagesScrollController.position.pixels <=
                    120;
            final shouldNotify =
                _hasLoadedMessages &&
                snapshot.docChanges.any(
                  (change) =>
                      change.type == DocumentChangeType.added &&
                      change.doc.data()?['uid'] != currentUid,
                );
            
            // الاحتفاظ فقط بالرسائل المحلية التي لم تُحفظ في Firebase بعد.
            final localMessages = _messages
              .where((msg) => msg.firestoreId == null)
              .toList();
            
            final messages = snapshot.docs.reversed.map((doc) {
              final data = doc.data();
              final deletedFor = data['deletedFor'];
              final expiresAt = data['expiresAt'];
              if (currentUid != null &&
                  deletedFor is List &&
                  deletedFor.contains(currentUid)) {
                return null;
              }
              if (expiresAt is Timestamp &&
                  expiresAt.compareTo(Timestamp.now()) <= 0) {
                return null;
              }
              final mediaUrl = data['mediaUrl'] as String?;
              final localMediaPath = mediaUrl != null &&
                      mediaUrl.startsWith('local://')
                  ? mediaUrl.substring('local://'.length)
                  : null;
              return Message(
                originalText: data['text'] ?? '',
                encryptedData: data['text'] ?? '',
                isMe: data['uid'] == currentUid,
                firestoreId: doc.id,
                time: _messageTime(data['createdAt']),
                mediaType: data['mediaType'] as String?,
                mediaFile: localMediaPath == null
                    ? null
                    : XFile(localMediaPath),
                mediaUrl: localMediaPath == null ? mediaUrl : null,
              );
            }).whereType<Message>().toList();
            
            setState(() {
              _messages.clear();
              _messages.addAll(messages);
              // إضافة الرسائل المحلية المعلقة في النهاية
              _messages.addAll(localMessages
                  .where((local) => 
                      messages.every((server) => 
                          server.originalText != local.originalText ||
                          server.mediaUrl != local.mediaUrl))
                  .toList());
            });
            _hasLoadedMessages = true;
            if (shouldFollowLatest) {
              _scrollToLatestMessage(force: isFirstSnapshot);
            }
            if (shouldNotify) {
              unawaited(_playMessageNotification());
              final incomingText = snapshot.docs
                  .where(
                    (doc) =>
                        doc.data()['uid'] != currentUid &&
                        doc.data()['text'] != null,
                  )
                  .lastOrNull
                  ?.data()['text'] as String?;
              if (incomingText != null && incomingText.isNotEmpty) {
                unawaited(
                  showChatNotification(
                    chatTitle: widget.chatName,
                    message: incomingText,
                  ),
                );
              }
            }
          },
          onError: (error) {
            debugPrint('Chat messages listener error: $error');
          },
        );
  }

  Future<void> _saveChatMessage(
    String text, {
    required bool isEncrypted,
  }) async {
    if (!firebaseReady) {
      debugPrint('Chat message save skipped: Firebase not ready');
      return;
    }
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    if (widget.contactUid != null && widget.contactUid!.isNotEmpty) {
      final isApproved = await _hasApprovedDirectContact(widget.contactUid!);
      if (!isApproved) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('لا يمكنك إرسال رسالة إلا بعد موافقة الطرف الآخر'),
            ),
          );
        }
        return;
      }
    }

    try {
      final chatRef = FirebaseFirestore.instance
          .collection('chats')
          .doc(_chatId);
      await chatRef.set({
        'participantA': widget.contactUid == null
            ? user.uid
            : ([user.uid, widget.contactUid!]..sort())[0],
        'participantB': widget.contactUid == null
            ? user.uid
            : ([user.uid, widget.contactUid!]..sort())[1],
        'participants':
            widget.contactUid == null
                    ? [user.uid]
                    : [user.uid, widget.contactUid].toList()
                ..sort(),
        'chatType': widget.contactUid == null ? 'group' : 'direct',
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      await chatRef.collection('messages').add({
        'text': isEncrypted ? await _realEncrypt(text) : text,
        'sender': 'مستخدم',
        'uid': user.uid,
        'deletedFor': <String>[],
        if (widget.contactUid != null) 'recipientUid': widget.contactUid,
        'createdAt': FieldValue.serverTimestamp(),
        if (autoDeleteMessagesNotifier.value)
          'expiresAt': Timestamp.fromDate(
            DateTime.now().add(const Duration(seconds: 8)),
          ),
      });

      await showChatNotification(
        chatTitle: widget.chatName,
        message: text,
        sentMessage: true,
      );

      // تحديث lastMessage في جهات الاتصال
      if (widget.contactUid != null) {
        final userDoc = await FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .collection(contactsCollectionName(ContactScope.regular))
            .doc(widget.contactUid)
            .get();

        if (userDoc.exists) {
          await FirebaseFirestore.instance
              .collection('users')
              .doc(user.uid)
              .collection(contactsCollectionName(ContactScope.regular))
              .doc(widget.contactUid)
              .update({
                'lastMessage': text.length > 50 ? '${text.substring(0, 50)}...' : text,
                'updatedAt': FieldValue.serverTimestamp(),
              });
        }
      }
    } catch (error) {
      debugPrint('Chat message save error: $error');
    }
  }

  String _firebaseUnavailableMessage() {
    return 'حدثت مشكلة، حاول مرة أخرى';
  }

  Future<void> _unlockChat() async {
    if (await hashPassword(_chatPasswordController.text.trim()) ==
        _chatPassword) {
      setState(() {
        _chatLocked = false;
        _chatPasswordController.clear();
      });
      _scrollToLatestMessage(force: true);
      if (whaleSoundNotifier.value) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && !_chatLocked) unawaited(_playWhaleSound());
        });
      }
    } else {
      debugPrint('Chat unlock failed: invalid password');
    }
  }

  Future<void> _playWhaleSound() async {
    if (!whaleSoundNotifier.value ||
        (!kIsWeb && defaultTargetPlatform == TargetPlatform.linux)) {
      return;
    }
    try {
      await _chatAudioPlayer.play(AssetSource('audio/whale_sound.mp3'));
    } catch (_) {
      // Audio is optional; a browser or device may deny playback.
    }
  }

  Future<void> _playMessageNotification() async {
    if (!messageSoundNotifier.value ||
        (!kIsWeb && defaultTargetPlatform == TargetPlatform.linux)) {
      return;
    }
    try {
      await _messageNotificationPlayer.play(
        AssetSource('audio/whale_sound.mp3'),
        volume: 0.22,
      );
    } catch (_) {}
  }

  Future<void> _playMediaAudio(Message message) async {
    try {
      await _mediaAudioPlayer.stop();
      if (message.mediaFile != null) {
        await _mediaAudioPlayer.play(DeviceFileSource(message.mediaFile!.path));
      } else if (message.mediaUrl != null && message.mediaUrl!.isNotEmpty) {
        await _mediaAudioPlayer.play(UrlSource(message.mediaUrl!));
      }
    } catch (error) {
      debugPrint('Audio message playback error: $error');
    }
  }

  Future<void> _changeChatPassword() async {
    final oldController = TextEditingController();
    final newController = TextEditingController();
    final confirmController = TextEditingController();
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('تغيير كلمة سر الدردشة'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: oldController,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'كلمة السر القديمة'),
            ),
            TextField(
              controller: newController,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'كلمة السر الجديدة'),
            ),
            TextField(
              controller: confirmController,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'تأكيد كلمة السر الجديدة',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('إلغاء'),
          ),
          ElevatedButton(
            onPressed: () async {
              final newPassword = newController.text.trim();
              final oldHash = await hashPassword(oldController.text.trim());
              if (oldHash != _chatPassword ||
                  newPassword.length < 4 ||
                  newPassword != confirmController.text.trim()) {
                debugPrint('Chat password update validation failed');
                return;
              }
              try {
                await saveChatPassword(_chatId, newPassword);
                final newHash = await hashPassword(newPassword);
                if (mounted) {
                  setState(() => _chatPassword = newHash);
                }
                if (dialogContext.mounted) Navigator.pop(dialogContext);
              } catch (error) {
                debugPrint('Chat password update error: $error');
              }
            },
            child: const Text('حفظ'),
          ),
        ],
      ),
    );
    oldController.dispose();
    newController.dispose();
    confirmController.dispose();
  }

  Future<void> _setChatPasswordForCurrentChat() async {
    final passwordController = TextEditingController();
    final confirmController = TextEditingController();
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('تأمين هذه الدردشة'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: passwordController,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'كلمة السر الجديدة'),
            ),
            TextField(
              controller: confirmController,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'تأكيد كلمة السر'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('إلغاء'),
          ),
          ElevatedButton(
            onPressed: () async {
              final newPassword = passwordController.text.trim();
              final confirmed = confirmController.text.trim();
              if (newPassword.length < 4 || newPassword != confirmed) {
                debugPrint('Chat password set validation failed');
                return;
              }
              try {
                await saveChatPassword(_chatId, newPassword);
                final newHash = await hashPassword(newPassword);
                if (mounted) {
                  setState(() {
                    _chatPassword = newHash;
                    _chatLocked = false;
                  });
                }
                if (dialogContext.mounted) Navigator.pop(dialogContext);
              } catch (error) {
                debugPrint('Chat password set error: $error');
              }
            },
            child: const Text('تأمين'),
          ),
        ],
      ),
    );
    passwordController.dispose();
    confirmController.dispose();
  }

  Future<void> _disableChatPassword() async {
    final enteredHash = await hashPassword(_chatPasswordController.text.trim());
    if (enteredHash != _chatPassword) {
      debugPrint('Disable chat password failed: invalid current password');
      return;
    }
    if (mounted) {
      setState(() {
        _chatLocked = false;
        _chatPassword = null;
        _chatPasswordController.clear();
      });
    }
    unawaited(disableChatPassword(_chatId));
  }

  Future<void> _toggleVoiceRecording() async {
    if (_isRecording) {
      try {
        final String? path = await _voiceRecorder.stop();
        if (!mounted) return;
        setState(() => _isRecording = false);
        if (path != null && path.isNotEmpty) {
          final voiceFile = XFile(path);
          final uploadedMediaUrl = await _uploadMedia(voiceFile, 'audio');
          final mediaUrl = uploadedMediaUrl ?? 'local://$path';
          final messageTime = _messageTime(null);
          if (mediaUrl.startsWith('local://')) {
            await _saveLocalVoiceMessage(path, messageTime);
          }
          setState(() {
            final Message voiceMessage = Message(
              originalText: '🎙️ رسالة صوتية',
              encryptedData: path,
              isMe: true,
              time: messageTime,
              mediaType: 'audio',
              mediaFile: voiceFile,
              mediaUrl: mediaUrl,
            );
            _messages.add(voiceMessage);
            _scheduleMessageDeletion(
              voiceMessage,
              enabledAtSend: autoDeleteMessagesNotifier.value,
            );
          });
          if (uploadedMediaUrl != null &&
              !uploadedMediaUrl.startsWith('local://')) {
            await _saveUploadedMediaMessage('🎙️ رسالة صوتية', 'audio', mediaUrl);
          }
        }
      } catch (error) {
        debugPrint('Voice recording stop error: $error');
        if (mounted) {
          setState(() => _isRecording = false);
        }
      }
      return;
    }

    try {
      final hasPermission = await _voiceRecorder.hasPermission();
      if (!hasPermission) {
        if (!mounted) return;
        return;
      }

      final recordPath = await getApplicationDocumentsDirectory();
      final fileName = 'shadow_voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
      final filePath = '${recordPath.path}/$fileName';

      await _voiceRecorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          sampleRate: 44100,
          bitRate: 128000,
        ),
        path: filePath,
      );
      if (mounted) setState(() => _isRecording = true);
    } catch (error) {
      debugPrint('Voice recording start error: $error');
    }
  }

  Future<void> _pickMedia({
    required bool video,
    ImageSource source = ImageSource.gallery,
  }) async {
    final XFile? file = video
        ? await _mediaPicker.pickVideo(source: source)
        : await _mediaPicker.pickImage(source: source);
    if (file == null || !mounted) return;
    
    final mediaType = video ? 'video' : 'image';
    
    // إضافة الرسالة محليًا أولاً لتظهير فوري
    final messageIndex = _messages.length;
    setState(() {
      _messages.add(
        Message(
          originalText: video ? '🎬 فيديو' : '🖼️ صورة',
          encryptedData: file.name,
          isMe: true,
          time: _messageTime(null),
          mediaType: mediaType,
          mediaFile: file,
          mediaUrl: null,
        ),
      );
      _scheduleMessageDeletion(
        _messages.last,
        enabledAtSend: autoDeleteMessagesNotifier.value,
      );
    });

    // رفع الملف في الخلفية
    try {
      final mediaUrl = await _uploadMedia(file, mediaType);
      if (mediaUrl != null && mounted && messageIndex < _messages.length) {
        // إنشاء رسالة جديدة برابط الملف
        setState(() {
          _messages[messageIndex] = Message(
            originalText: video ? '🎬 فيديو' : '🖼️ صورة',
            encryptedData: file.name,
            isMe: true,
            time: _messageTime(null),
            mediaType: mediaType,
            mediaFile: file,
            mediaUrl: mediaUrl,
          );
        });
        
        // لا نرسل local:// إلى Firebase؛ هذا المسار صالح على هذا الجهاز فقط.
        if (!mediaUrl.startsWith('local://')) {
          await _saveUploadedMediaMessage(
            video ? '🎬 فيديو' : '🖼️ صورة',
            mediaType,
            mediaUrl,
          );
        }
      } else if (mounted) {
        debugPrint('Media upload failed');
        if (mounted) {
          setState(() {
            if (messageIndex < _messages.length) {
              _messages.removeAt(messageIndex);
            }
          });
        }
      }
    } catch (error) {
      debugPrint('Media pick error: $error');
      if (mounted) {
        setState(() {
          if (messageIndex < _messages.length) {
            _messages.removeAt(messageIndex);
          }
        });
      }
    }
  }

  Future<String?> _uploadMedia(XFile file, String mediaType) async {
    Future<String?> saveLocally() async {
      try {
        final directory = await getApplicationDocumentsDirectory();
        final safeName = file.name.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
        final localFile = File(
          '${directory.path}/shadow_media_${DateTime.now().millisecondsSinceEpoch}_$safeName',
        );
        await File(file.path).copy(localFile.path);
        return 'local://${localFile.path}';
      } catch (error) {
        debugPrint('Local media save error: $error');
        return null;
      }
    }

    if (!firebaseReady) return saveLocally();
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return saveLocally();

    try {
      final fileName = '${mediaType}_${DateTime.now().millisecondsSinceEpoch}_${file.name}';
      final uploadTask = FirebaseStorage.instance
          .ref()
          .child('users')
          .child(user.uid)
          .child('media')
          .child(mediaType)
          .child(fileName)
          .putFile(File(file.path));
      final snapshot = await uploadTask;
      return await snapshot.ref.getDownloadURL();
    } catch (error) {
      debugPrint('Media upload error: $error');
      return saveLocally();
    }
  }

  Future<void> _saveUploadedMediaMessage(
    String text,
    String mediaType,
    String? mediaUrl,
  ) async {
    if (!firebaseReady ||
        mediaUrl == null ||
        mediaUrl.isEmpty ||
        mediaUrl.startsWith('local://')) {
      return;
    }
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    try {
      final chatRef = FirebaseFirestore.instance
          .collection('chats')
          .doc(_chatId);
      
      await chatRef.set({
        'participantA': widget.contactUid == null
          ? user.uid
          : ([user.uid, widget.contactUid!]..sort())[0],
        'participantB': widget.contactUid == null
          ? user.uid
          : ([user.uid, widget.contactUid!]..sort())[1],
        'participants':
            widget.contactUid == null
                  ? [user.uid]
                  : [user.uid, widget.contactUid].toList()
              ..sort(),
        'chatType': widget.contactUid == null ? 'group' : 'direct',
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      await chatRef.collection('messages').add({
        'text': text,
        'uid': user.uid,
        'sender': 'مستخدم',
        'deletedFor': <String>[],
        'mediaType': mediaType,
        'mediaUrl': mediaUrl,
        if (widget.contactUid != null) 'recipientUid': widget.contactUid,
        'createdAt': FieldValue.serverTimestamp(),
      });

      // تحديث lastMessage في جهات الاتصال
      if (widget.contactUid != null) {
        final userDoc = await FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .collection(contactsCollectionName(ContactScope.regular))
            .doc(widget.contactUid)
            .get();

        if (userDoc.exists) {
          await FirebaseFirestore.instance
              .collection('users')
              .doc(user.uid)
              .collection(contactsCollectionName(ContactScope.regular))
              .doc(widget.contactUid)
              .update({
                'lastMessage': text,
                'updatedAt': FieldValue.serverTimestamp(),
              });
        }
      }
    } catch (error) {
      debugPrint('Media message save error: $error');
    }
  }

  void _showMediaPicker() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF101714),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 22),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _MediaOption(
                  icon: Icons.photo_library_rounded,
                  label: 'صورة',
                  color: const Color(0xFF00FF66),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _pickMedia(video: false);
                  },
                ),
                _MediaOption(
                  icon: Icons.video_library_rounded,
                  label: 'فيديو',
                  color: Colors.amberAccent,
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _pickMedia(video: true);
                  },
                ),
                _MediaOption(
                  icon: Icons.photo_camera_rounded,
                  label: 'كاميرا',
                  color: Colors.cyanAccent,
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _pickMedia(video: false, source: ImageSource.camera);
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<String> _realEncrypt(String text) async {
    if (text.isEmpty) return '';

    final AesGcm cipher = AesGcm.with256bits();
    final List<int> keySeed = utf8.encode('SHADOW_KEY_2026');
    final List<int> keyBytes = (await Sha256().hash(keySeed)).bytes;
    final SecretKey secretKey = SecretKey(keyBytes);
    final SecretBox encrypted = await cipher.encrypt(
      utf8.encode(text),
      secretKey: secretKey,
    );

    return base64Encode([
      ...encrypted.nonce,
      ...encrypted.cipherText,
      ...encrypted.mac.bytes,
    ]);
  }

  void _scheduleMessageDeletion(
    Message message, {
    required bool enabledAtSend,
  }) {
    if (!enabledAtSend || !message.isMe) return;

    Future.delayed(const Duration(seconds: 8), () {
      if (!mounted) {
        unawaited(deleteExpiredOwnChatMessages(_chatId));
        return;
      }
      unawaited(deleteExpiredOwnChatMessages(_chatId));
    });
  }

  Future<void> _deleteRegularMedia(Message message, {required bool remote}) async {
    if (message.mediaFile != null) {
      try {
        final localFile = File(message.mediaFile!.path);
        if (await localFile.exists()) await localFile.delete();
      } catch (error) {
        debugPrint('Local media delete error: $error');
      }
    }
    if (!remote || message.mediaUrl == null || message.mediaUrl!.isEmpty) {
      return;
    }
    try {
      await FirebaseStorage.instance.refFromURL(message.mediaUrl!).delete();
    } catch (error) {
      debugPrint('Firebase media delete error: $error');
    }
  }

  Future<void> _deleteRegularMessage(
    Message message, {
    required bool forEveryone,
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    final docId = message.firestoreId;
    if (user == null) return;
    if (forEveryone && !message.isMe) {
      return;
    }
    if (docId == null || !firebaseReady) {
      await _deleteRegularMedia(message, remote: false);
      if (mounted) setState(() => _messages.remove(message));
      return;
    }

    final reference = FirebaseFirestore.instance
        .collection('chats')
        .doc(_chatId)
        .collection('messages')
        .doc(docId);
    try {
      if (forEveryone && message.isMe) {
        await reference.delete();
        await _deleteRegularMedia(message, remote: true);
      } else {
        await reference.update({
          'deletedFor': FieldValue.arrayUnion([user.uid]),
        });
        await _deleteRegularMedia(message, remote: false);
      }
      if (mounted) setState(() => _messages.remove(message));
    } catch (error) {
      debugPrint('Regular message delete error: $error');
    }
  }

  Future<void> _showMessageActions(Message message) async {
    final deleteMode = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xFF101714),
      builder: (sheetContext) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.white),
              title: const Text(
                'حذف لدي',
                style: TextStyle(color: Colors.white),
              ),
              onTap: () => Navigator.pop(sheetContext, 'mine'),
            ),
            if (message.isMe && message.firestoreId != null)
              ListTile(
                leading: const Icon(
                  Icons.delete_forever,
                  color: Colors.redAccent,
                ),
                title: const Text(
                  'حذف لدى الجميع',
                  style: TextStyle(color: Colors.redAccent),
                ),
                onTap: () => Navigator.pop(sheetContext, 'everyone'),
              ),
          ],
        ),
      ),
    );
    if (!mounted || deleteMode == null) return;
    if (deleteMode == 'everyone') {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('حذف لدى الجميع'),
          content: const Text(
            'سيتم حذف الرسالة والوسائط المرتبطة بها من Firebase لدى جميع المشاركين.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('إلغاء'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('حذف للجميع'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    await _deleteRegularMessage(
      message,
      forEveryone: deleteMode == 'everyone',
    );
  }

  // دعم تحويل النصوص العربية والإنجليزية لنيون
  String _toNeonGreenText(String text) {
    const Map<String, String> normalToNeon = {
      // الحروف العربية
      'ا': '𝕒',
      'ب': '𝕓',
      'ت': '𝕥',
      'ث': '𝕥𝕙',
      'ج': '𝕛',
      'ح': '𝕙',
      'خ': '𝕩',
      'د': '𝕕',
      'ذ': 'ẕ',
      'ر': '𝕣',
      'ز': '𝕫',
      'س': '𝕤',
      'ش': '𝕤𝕙',
      'ص': '𝕤',
      'ض': 'ḏ', 'ط': '𝕥', 'ظ': 'ẓ', 'ع': '𝕔', 'غ': 'ǧ', 'ف': '𝕗', 'ق': 'զ',
      'ك': '𝕜',
      'ل': '𝕝',
      'م': '𝕞',
      'ن': '𝕟',
      'ه': '𝕙',
      'و': '𝕨',
      'ي': '𝟪',
      'أ': '𝕒',
      'إ': '𝕒',
      'آ': '𝕒',
      'ة': '𝕥',
      'ى': '𝟪',
      'ئ': '𝟪',
      'ؤ': '𝕨',
      'ء': '𝕩', 'لا': '𝕝𝕒',

      // الحروف الإنجليزية الصغيرة
      'a': '𝕒',
      'b': '𝕓',
      'c': '𝕔',
      'd': '𝕕',
      'e': '𝕖',
      'f': '𝕗',
      'g': '𝕘',
      'h': '𝕙',
      'i': '𝕚',
      'j': '𝕛',
      'k': '𝕜',
      'l': '𝕝',
      'm': '𝕞',
      'n': '𝕟',
      'o': '𝕠',
      'p': '𝕡',
      'q': 'զ',
      'r': '𝕣',
      's': '𝕤',
      't': '𝕥',
      'u': '𝕦',
      'v': '𝕧', 'w': '𝕨', 'x': '𝕩', 'y': '𝕪', 'z': '𝕫',

      // الحروف الإنجليزية الكبيرة
      'A': '𝔸',
      'B': '𝔹',
      'C': 'ℂ',
      'D': '𝔻',
      'E': '𝔼',
      'F': '𝔽',
      'G': '𝔾',
      'H': 'ℍ', 'I': '𝕀', 'J': '𝕁', 'K': '𝕂', 'L': '𝔏', 'M': '𝕄', 'N': 'ℕ',
      'O': '𝕆', 'P': 'ℙ', 'Q': 'ℚ', 'R': 'ℝ', 'S': '𝕊', 'T': '𝕋', 'U': '𝕌',
      'V': '𝕍', 'W': '𝕎', 'X': '𝕏', 'Y': '𝕐', 'Z': 'ℤ',

      // الأرقام
      '0': '𝟘',
      '1': '𝟙',
      '2': '𝟚',
      '3': '𝟛',
      '4': '𝟜',
      '5': '𝟝',
      '6': '𝟞',
      '7': '𝟟', '8': '𝟠', '9': '𝟡',
    };

    StringBuffer result = StringBuffer();
    for (int i = 0; i < text.length; i++) {
      String char = text[i];
      final bool isArabic = RegExp(r'[\u0600-\u06FF]').hasMatch(char);
      result.write(isArabic ? char : normalToNeon[char] ?? char);
    }
    return result.toString();
  }

  Future<void> _sendMessage() async {
    if (_controller.text.trim().isNotEmpty && !_isLaunching) {
      String userText = _controller.text.trim();
      _controller.clear();

      setState(() {
        _isLaunching = true;
      });

      // تشفير البيانات بجد في الخلفية لو الـ autoEncrypt مفعل
      bool isEncrypted = autoEncryptNotifier.value;
      final String processedText = isEncrypted
          ? await _realEncrypt(userText)
          : userText;

      Future.delayed(const Duration(milliseconds: 500), () {
        if (mounted) {
          setState(() {
            final Message sentMessage = Message(
              originalText: userText,
              encryptedData: processedText,
              isMe: true,
              time: _messageTime(null),
              isEncrypted: isEncrypted,
            );
            _messages.add(sentMessage);
            _saveChatMessage(userText, isEncrypted: isEncrypted);
            _scheduleMessageDeletion(
              sentMessage,
              enabledAtSend: autoDeleteMessagesNotifier.value,
            );
            _isOtherTyping = true;
          });
          Future.delayed(const Duration(seconds: 1), () {
            if (mounted) setState(() => _isOtherTyping = false);
          });
        }
      });

      _launchController.forward(from: 0.0).then((_) {
        if (mounted) {
          setState(() {
            _isLaunching = false;
          });
        }
      });
    }
  }

  Widget _buildMessageContent(Message message) {
    final mediaWidth = MediaQuery.sizeOf(context).width < 600
        ? MediaQuery.sizeOf(context).width * 0.72
        : 340.0;
    final mediaHeight = mediaWidth * 0.72;

    // معالجة الصور
    if (message.mediaType == 'image' &&
        (message.mediaFile != null || message.mediaUrl != null)) {
      debugPrint('عرض صورة: mediaUrl=${message.mediaUrl}, mediaFile=${message.mediaFile?.name}');
      
      // عرض من رابط Firebase
      if (message.mediaUrl != null && message.mediaUrl!.isNotEmpty) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Image.network(
            message.mediaUrl!,
            width: mediaWidth,
            height: mediaHeight,
            fit: BoxFit.cover,
            errorBuilder: (context, error, stackTrace) {
              debugPrint('خطأ في تحميل الصورة من الرابط: $error');
              return Container(
                width: mediaWidth,
                height: mediaHeight,
                decoration: BoxDecoration(
                  color: Colors.grey[800],
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.image_not_supported, color: Colors.white54),
                    SizedBox(height: 8),
                    Text(
                      'تعذر عرض الصورة',
                      style: TextStyle(color: Colors.white54, fontSize: 12),
                    ),
                  ],
                ),
              );
            },
            loadingBuilder: (context, child, loadingProgress) {
              if (loadingProgress == null) return child;
              return Container(
                width: mediaWidth,
                height: mediaHeight,
                decoration: BoxDecoration(
                  color: Colors.grey[800],
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Center(
                  child: CircularProgressIndicator(
                    valueColor: AlwaysStoppedAnimation<Color>(
                      Color(0xFF00FF66),
                    ),
                  ),
                ),
              );
            },
          ),
        );
      }
      
      // عرض من ملف محلي
      if (message.mediaFile != null) {
        debugPrint('عرض صورة محلية: ${message.mediaFile?.name}');
        return FutureBuilder<Uint8List>(
          future: message.mediaFile!.readAsBytes(),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return Container(
                width: 220,
                height: 160,
                decoration: BoxDecoration(
                  color: Colors.grey[800],
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Center(
                  child: CircularProgressIndicator(
                    valueColor: AlwaysStoppedAnimation<Color>(
                      Color(0xFF00FF66),
                    ),
                  ),
                ),
              );
            }
            
            if (!snapshot.hasData || snapshot.data == null) {
              return Container(
                width: 220,
                height: 160,
                decoration: BoxDecoration(
                  color: Colors.grey[800],
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.image_not_supported, color: Colors.white54),
                    SizedBox(height: 8),
                    Text(
                      'لم تتمكن من قراءة الصورة',
                      style: TextStyle(color: Colors.white54, fontSize: 12),
                    ),
                  ],
                ),
              );
            }
            
            return ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.memory(
                snapshot.data!,
                width: mediaWidth,
                height: mediaHeight,
                fit: BoxFit.cover,
              ),
            );
          },
        );
      }
    }
    
    // معالجة الفيديوهات
    if (message.mediaType == 'video') {
      return _VideoMessagePlayer(
        mediaFile: message.mediaFile,
        mediaUrl: message.mediaUrl,
      );
    }
    
    // معالجة التسجيلات الصوتية
    if (message.mediaType == 'audio') {
      return GestureDetector(
        onTap: () => _playMediaAudio(message),
        child: Container(
          width: 220,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: message.isMe
                  ? [const Color(0xFF1FD196), const Color(0xFF0F7D5E)]
                  : [const Color(0xFF1A2A2D), const Color(0xFF131E21)],
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
            ),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: message.isMe
                  ? const Color(0xFF9AF7D0).withOpacity(0.8)
                  : const Color(0xFF7DE5A8).withOpacity(0.5),
              width: 1,
            ),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF00FF66).withOpacity(0.18),
                blurRadius: 12,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.play_arrow_rounded,
                  color: Colors.white,
                  size: 24,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'رسالة صوتية',
                      style: TextStyle(
                        color: message.isMe ? Colors.white : Colors.white70,
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'اضغط للتشغيل 🎙️',
                      style: TextStyle(
                        color: message.isMe ? Colors.white70 : Colors.white54,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }
    return Text(
      _toNeonGreenText(message.displayText),
      textAlign: TextAlign.start,
      softWrap: true,
      style: TextStyle(
        color: message.isMe ? Colors.white : const Color(0xFFE8FFF4),
        fontSize: 15,
        height: 1.45,
        fontWeight: FontWeight.w500,
        shadows: message.isMe
            ? null
            : [
                Shadow(
                  color: const Color(0xFF00FF66).withOpacity(0.28),
                  blurRadius: 5,
                ),
              ],
      ),
    );
  }

  Widget _buildMessageBubble(Message message, bool isDark) {
    final sentColor = const Color(0xFF176B59);
    final receivedColor = const Color(0xFF1C2728);
    final borderColor = message.isMe
        ? const Color(0xFF38E8A5).withOpacity(0.65)
        : const Color(0xFF8BA99A).withOpacity(0.35);
    return Align(
      alignment: message.isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.82,
          minWidth: 72,
        ),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 5),
          padding: const EdgeInsets.fromLTRB(14, 11, 12, 8),
          decoration: BoxDecoration(
            color: message.isMe
                ? sentColor.withOpacity(isDark ? 0.92 : 1)
                : receivedColor.withOpacity(isDark ? 0.94 : 1),
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(18),
              topRight: const Radius.circular(18),
              bottomLeft: Radius.circular(message.isMe ? 18 : 5),
              bottomRight: Radius.circular(message.isMe ? 5 : 18),
            ),
            border: Border.all(color: borderColor),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.18),
                blurRadius: 8,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildMessageContent(message),
              const SizedBox(height: 4),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    message.time ?? _messageTime(null),
                    style: TextStyle(
                      color: message.isMe
                          ? const Color(0xFFB5E7D2)
                          : Colors.white54,
                      fontSize: 10,
                    ),
                  ),
                  if (message.isMe) ...[
                    const SizedBox(width: 4),
                    const Icon(
                      Icons.done_all_rounded,
                      size: 14,
                      color: Color(0xFFB5E7D2),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_directAccessChecked) {
      return const Scaffold(
        backgroundColor: Color(0xFF101716),
        body: Center(
          child: CircularProgressIndicator(color: Color(0xFF38E8A5)),
        ),
      );
    }
    if (!_directAccessApproved) {
      return const Scaffold(
        backgroundColor: Color(0xFF101716),
        body: Center(
          child: Text(
            'هذه الدردشة تحتاج موافقة الطرف الآخر أولًا',
            style: TextStyle(color: Colors.white70),
          ),
        ),
      );
    }
    if (_chatLocked) return _buildLockedChat();
    const isDark = true;
    return Theme(
      data: ThemeData.dark(useMaterial3: true),
      child: Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(
          backgroundColor: isDark
              ? const Color(0xFF101716)
              : const Color(0xFFF4F7F6),
          body: Stack(
            children: [
              if (isDark)
                ValueListenableBuilder<bool>(
                  valueListenable: whaleMotionNotifier,
                  builder: (context, isMoving, child) {
                    return AnimatedBuilder(
                      animation: _whaleAnimation,
                      child: Image.asset(
                        'assets/images/whale.jpg',
                        fit: BoxFit.cover,
                        cacheWidth: 896,
                        errorBuilder: (context, error, stackTrace) =>
                            Container(color: const Color(0xFF101716)),
                      ),
                      builder: (context, child) {
                        return Positioned.fill(
                          child: RepaintBoundary(
                            child: Transform.translate(
                              offset: isMoving
                                  ? Offset(0, _whaleAnimation.value)
                                  : Offset.zero,
                              child: Transform.scale(scale: 1.08, child: child),
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),
              if (isDark)
                Positioned.fill(
                  child: Container(color: Colors.black.withOpacity(0.35)),
                ),
              SafeArea(
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: 8.0,
                        horizontal: 12,
                      ),
                      child: Row(
                        children: [
                          IconButton(
                            icon: const Icon(
                              Icons.arrow_back,
                              color: Color(0xFF00FF66),
                            ),
                            tooltip: 'رجوع',
                            onPressed: () => Navigator.pop(context),
                          ),
                          Expanded(
                            child:
                                StreamBuilder<
                                  DocumentSnapshot<Map<String, dynamic>>
                                >(
                                  stream: _contactPresenceStream,
                                  builder: (context, snapshot) {
                                    final data = snapshot.data?.data();
                                    return Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          widget.chatName,
                                          textAlign: TextAlign.center,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            color: isDark
                                                ? Colors.white
                                                : const Color(0xFF14211D),
                                            fontWeight: FontWeight.bold,
                                            fontSize: 16,
                                            letterSpacing: 1.2,
                                          ),
                                        ),
                                        if (widget.contactUid != null)
                                          Text(
                                            _presenceText(data),
                                            style: TextStyle(
                                              color: data?['isOnline'] == true
                                                  ? const Color(0xFF00FF66)
                                                  : Colors.white60,
                                              fontSize: 11,
                                            ),
                                          ),
                                      ],
                                    );
                                  },
                                ),
                          ),
                          ValueListenableBuilder<bool>(
                            valueListenable: ghostModeNotifier,
                            builder: (context, isGhostModeEnabled, child) {
                              return Icon(
                                isGhostModeEnabled
                                    ? Icons.visibility_off
                                    : Icons.visibility,
                                color: isGhostModeEnabled
                                    ? Colors.purpleAccent
                                    : Colors.white30,
                                size: 18,
                              );
                            },
                          ),
                          const SizedBox(width: 48),
                        ],
                      ),
                    ),
                    Container(
                      margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1B2A25).withOpacity(0.9),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: const Color(0xFF38E8A5).withOpacity(0.35),
                        ),
                      ),
                      child: const Text(
                        'أهلاً بك في نظام shadow chat ✨ 🌑 ✨',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Color(0xFF00FF66),
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    Expanded(
                      child: ListView.builder(
                        controller: _messagesScrollController,
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                        itemCount: _messages.length,
                        itemBuilder: (context, index) {
                          final msg = _messages[index];
                          return GestureDetector(
                            onLongPress: () => _showMessageActions(msg),
                            child: _buildMessageBubble(msg, isDark),
                          );
                        },
                      ),
                    ),
                    Container(
                      margin: const EdgeInsets.fromLTRB(10, 4, 10, 12),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFF15221F).withOpacity(0.96),
                        borderRadius: BorderRadius.circular(22),
                        border: Border.all(
                          color: const Color(0xFF38E8A5).withOpacity(0.45),
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.25),
                            blurRadius: 12,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Row(
                        children: [
                        _FloatingChatButton(
                          icon: Icons.send_rounded,
                          color: const Color(0xFF00FF66),
                          tooltip: 'إرسال',
                          onPressed: _sendMessage,
                        ),
                        _FloatingChatButton(
                          icon: _isRecording
                              ? Icons.stop_circle
                              : Icons.mic_none_rounded,
                          color: _isRecording
                              ? Colors.redAccent
                              : Colors.amberAccent,
                          tooltip: _isRecording
                              ? 'إيقاف التسجيل'
                              : 'تسجيل رسالة صوتية',
                          onPressed: _toggleVoiceRecording,
                        ),
                        Expanded(
                          child: TextField(
                            controller: _controller,
                            style: const TextStyle(color: Colors.white),
                            textDirection: TextDirection.rtl,
                            textAlign: TextAlign.start,
                            minLines: 1,
                            maxLines: 4,
                            textInputAction: TextInputAction.newline,
                            decoration: InputDecoration(
                              filled: true,
                              fillColor: const Color(0xFF11201E),
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 11,
                              ),
                              hintText: 'اكتب رسالتك هنا',
                              hintStyle: TextStyle(
                                color: const Color(0xFFEAF4F0).withOpacity(0.9),
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                              ),
                              border: InputBorder.none,
                              enabledBorder: InputBorder.none,
                              focusedBorder: InputBorder.none,
                            ),
                            onSubmitted: (_) => _sendMessage(),
                          ),
                        ),
                        SizedBox(
                          width: 62,
                          height: 48,
                          child: IconButton(
                            icon: const Text(
                              '🌊',
                              style: TextStyle(fontSize: 25),
                            ),
                            tooltip: 'إرسال صورة أو فيديو',
                            onPressed: _showMediaPicker,
                          ),
                        ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLockedChat() {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: const Color(0xFF0B1220),
        appBar: AppBar(
          title: const Text(
            'دردشة محمية',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
          ),
          centerTitle: true,
          backgroundColor: const Color(0xFF17243A),
          iconTheme: const IconThemeData(color: Color(0xFF7DE7FF)),
        ),
        body: Stack(
          children: [
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      const Color(0xFF0B1220),
                      const Color(0xFF142B42),
                      const Color(0xFF081018),
                    ],
                  ),
                ),
              ),
            ),
            Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Container(
                  constraints: const BoxConstraints(maxWidth: 410),
                  padding: const EdgeInsets.fromLTRB(24, 30, 24, 24),
                  decoration: BoxDecoration(
                    color: const Color(0xFF152235).withOpacity(0.98),
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(
                      color: const Color(0xFF7DE7FF).withOpacity(0.45),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF4CC9F0).withOpacity(0.16),
                        blurRadius: 28,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ScaleTransition(
                        scale: _lockPulseAnimation,
                        child: Container(
                          padding: const EdgeInsets.all(18),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: const Color(0xFF00FF66).withOpacity(0.1),
                            border: Border.all(
                              color: const Color(0xFF00FF66),
                              width: 1.5,
                            ),
                          ),
                          child: const Icon(
                            Icons.lock_rounded,
                            color: Color(0xFF00FF66),
                            size: 48,
                          ),
                        ),
                      ),
                      const SizedBox(height: 22),
                      const Text(
                        'الدردشة مؤمنة',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 23,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'أدخل كلمة المرور للوصول إلى الرسائل',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white60, fontSize: 13),
                      ),
                      const SizedBox(height: 24),
                      TextField(
                        controller: _chatPasswordController,
                        obscureText: true,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          letterSpacing: 3,
                        ),
                        decoration: InputDecoration(
                          hintText: '••••••••',
                          hintStyle: const TextStyle(
                            color: Colors.white30,
                            letterSpacing: 3,
                          ),
                          filled: true,
                          fillColor: Colors.black.withOpacity(0.35),
                          prefixIcon: const Icon(
                            Icons.key_rounded,
                            color: Colors.amberAccent,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                            borderSide: BorderSide(
                              color: Colors.white.withOpacity(0.12),
                            ),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                            borderSide: BorderSide(
                              color: Colors.white.withOpacity(0.12),
                            ),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                            borderSide: const BorderSide(
                              color: Color(0xFF00FF66),
                              width: 1.5,
                            ),
                          ),
                        ),
                        onSubmitted: (_) => _unlockChat(),
                      ),
                      const SizedBox(height: 18),
                      SizedBox(
                        width: double.infinity,
                        height: 50,
                        child: ElevatedButton.icon(
                          onPressed: _unlockChat,
                          icon: const Icon(Icons.lock_open_rounded),
                          label: const Text(
                            'فتح الدردشة',
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF00FF66),
                            foregroundColor: Colors.black,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                        ),
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          TextButton.icon(
                            onPressed: _changeChatPassword,
                            icon: const Icon(Icons.password_rounded, size: 18),
                            label: const Text('تغيير كلمة السر'),
                            style: TextButton.styleFrom(
                              foregroundColor: Colors.amberAccent,
                            ),
                          ),
                          const SizedBox(width: 8),
                          TextButton.icon(
                            onPressed: _disableChatPassword,
                            icon: const Icon(Icons.lock_open_rounded, size: 18),
                            label: const Text('إيقاف كلمة السر'),
                            style: TextButton.styleFrom(
                              foregroundColor: const Color(0xFF61E7C0),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.shield_outlined,
                            color: Colors.amberAccent,
                            size: 15,
                          ),
                          SizedBox(width: 6),
                          Text(
                            'حماية Shadow Chat',
                            style: TextStyle(
                              color: Colors.white54,
                              fontSize: 11,
                            ),
                          ),
                        ],
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
}

// ---------------------------------------------------------
// ضع هذا الجزء في نهاية ملف main.dart تماماً (بدون أي imports جديدة)
// ---------------------------------------------------------

ValueNotifier<XFile?> userProfileImageNotifier = ValueNotifier<XFile?>(null);

class AccountAndThemeScreen extends StatefulWidget {
  const AccountAndThemeScreen({super.key});

  @override
  State<AccountAndThemeScreen> createState() => _AccountAndThemeScreenState();
}

class _AccountAndThemeScreenState extends State<AccountAndThemeScreen> {
  String userName = "Shadow User";
  late TextEditingController nameController;
  final ImagePicker _picker = ImagePicker();
  String? _linkedPhoneNumber;
  bool _isLinkingPhone = false;

  @override
  void initState() {
    super.initState();
    nameController = TextEditingController(text: userName);
    _loadProfile();
  }

  @override
  void dispose() {
    nameController.dispose();
    super.dispose();
  }

  Future<void> _pickProfileImage() async {
    try {
      final XFile? image = await _picker.pickImage(source: ImageSource.gallery);
      if (image == null) return;

      final bytes = await image.readAsBytes();
      if (bytes.isEmpty) {
        throw StateError('Selected profile image is empty');
      }
      userProfileImageNotifier.value = image;
      userProfileImageBytesNotifier.value = bytes;
      await _saveLocalProfileImage(bytes);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تم حفظ الصورة على الجهاز فقط')),
        );
      }
    } catch (error) {
      debugPrint('Profile image pick error: $error');
      debugPrint('Profile image selection failed');
    }
  }

  Future<void> _saveLocalProfileImage(Uint8List bytes) async {
    try {
      final preferences = await getSafeSharedPreferences();
      if (preferences == null) return;
      final userKey = FirebaseAuth.instance.currentUser?.uid ?? 'guest';
      await preferences.setString(
        'profile_image_base64_$userKey',
        base64Encode(bytes),
      );
    } catch (error) {
      debugPrint('Local profile image save error: $error');
    }
  }

  Future<void> _loadLocalProfileImage() async {
    try {
      final preferences = await getSafeSharedPreferences();
      if (preferences == null) return;
      final userKey = FirebaseAuth.instance.currentUser?.uid ?? 'guest';
      final encodedImage = preferences.getString('profile_image_base64_$userKey');
      if (encodedImage != null && encodedImage.isNotEmpty) {
        final bytes = base64Decode(encodedImage);
        if (bytes.isNotEmpty) {
          userProfileImageBytesNotifier.value = bytes;
        }
      }
    } catch (error) {
      debugPrint('Local profile image load error: $error');
    }
  }

  Future<void> _loadProfile() async {
    await _loadLocalProfileImage();
    final initialUser = FirebaseAuth.instance.currentUser;
    User? user = initialUser;
    if (!firebaseReady || user == null) return;
    try {
      await user.reload().timeout(const Duration(seconds: 10));
      final refreshedUser = FirebaseAuth.instance.currentUser;
      if (refreshedUser == null) return;
      final data =
          (await FirebaseFirestore.instance
                  .collection('users')
                  .doc(refreshedUser.uid)
                  .get()
                  .timeout(const Duration(seconds: 10)))
              .data();
      if (mounted) {
        setState(() {
          userName = data?['displayName'] as String? ?? userName;
          _linkedPhoneNumber = refreshedUser.phoneNumber;
          nameController.text = userName;
        });
      }
    } catch (error) {
      debugPrint('Profile load error: $error');
    }
  }

  void _showProfileImageViewer() {
    final imageBytes = userProfileImageBytesNotifier.value;

    showDialog(
      context: context,
      barrierColor: Colors.black87,
      builder: (dialogContext) {
        return Dialog(
          insetPadding: const EdgeInsets.all(18),
          backgroundColor: Colors.transparent,
          child: GestureDetector(
            onTap: () => Navigator.of(dialogContext).pop(),
            child: InteractiveViewer(
              minScale: 1,
              maxScale: 4,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(22),
                child: imageBytes != null
                    ? Image.memory(
                        imageBytes,
                        fit: BoxFit.contain,
                      )
                    : Container(
                        width: 220,
                        height: 220,
                        decoration: BoxDecoration(
                          color: const Color(0xFF101716),
                          borderRadius: BorderRadius.circular(22),
                        ),
                        child: const Icon(
                          Icons.person,
                          size: 110,
                          color: Color(0xFF00FF66),
                        ),
                      ),
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _saveLocalPhoneNumber(String phone) async {
    final preferences = await getSafeSharedPreferences();
    if (preferences == null) return;
    await preferences.setString('local_linked_phone_number', phone);
  }

  Future<String?> _loadLocalPhoneNumber() async {
    final preferences = await getSafeSharedPreferences();
    if (preferences == null) return null;
    final value = preferences.getString('local_linked_phone_number');
    return value != null && value.isNotEmpty ? value : null;
  }

  Future<void> _linkPhoneNumber() async {
    final user = FirebaseAuth.instance.currentUser;
    final existingLocalPhone = await _loadLocalPhoneNumber();
    if (user != null && user.phoneNumber != null && user.phoneNumber!.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('رقم الهاتف مرتبط بهذا الحساب بالفعل')),
      );
      return;
    }
    if (existingLocalPhone != null && existingLocalPhone.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('رقم الهاتف محجوز على الجهاز بالفعل')),
      );
      return;
    }

    final phoneController = TextEditingController();
    final phoneNumber = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('ربط رقم الهاتف'),
        content: TextField(
          controller: phoneController,
          keyboardType: TextInputType.phone,
          autofocus: true,
          textDirection: TextDirection.ltr,
          decoration: const InputDecoration(
            labelText: 'رقم الهاتف',
            hintText: '+201xxxxxxxxx',
            prefixIcon: Icon(Icons.phone_android),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('إلغاء'),
          ),
          ElevatedButton(
            onPressed: () {
              final value = phoneController.text.trim();
              if (value.isNotEmpty) Navigator.pop(dialogContext, value);
            },
            child: const Text('حفظ محليًا'),
          ),
        ],
      ),
    );
    phoneController.dispose();
    if (!mounted || phoneNumber == null || phoneNumber.isEmpty) return;
    final normalizedPhoneNumber = normalizePhoneNumber(phoneNumber);
    if (!normalizedPhoneNumber.startsWith('+') ||
        normalizedPhoneNumber.length < 10) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('اكتب رقم الهاتف بالصيغة الدولية مثل +201xxxxxxxxx'),
        ),
      );
      return;
    }

    setState(() => _isLinkingPhone = true);
    try {
      await _saveLocalPhoneNumber(normalizedPhoneNumber);
      setState(() {
        _linkedPhoneNumber = normalizedPhoneNumber;
        _isLinkingPhone = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تم حفظ رقم الهاتف على الجهاز فقط')),
        );
      }
    } catch (error) {
      debugPrint('Local phone link save error: $error');
      if (mounted) {
        setState(() => _isLinkingPhone = false);
      }
    }
  }

  Future<void> _finishPhoneLink(PhoneAuthCredential credential) async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) throw FirebaseAuthException(code: 'user-not-found');
      final linkedUser = (await user.linkWithCredential(credential)).user;
      if (linkedUser == null || linkedUser.phoneNumber == null) {
        throw FirebaseAuthException(code: 'phone-link-failed');
      }
      await FirebaseFirestore.instance.collection('users').doc(linkedUser.uid).set({
        'phoneNumber': normalizePhoneNumber(linkedUser.phoneNumber!),
        'phoneSearchKey': _phoneSearchKey(linkedUser.phoneNumber!),
        'phoneLinked': true,
        'phoneUpdatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      await FirebaseFirestore.instance
          .collection('publicProfiles')
          .doc(linkedUser.uid)
          .set({
            'uid': linkedUser.uid,
            'phoneNumber': normalizePhoneNumber(linkedUser.phoneNumber!),
            'phoneSearchKey': _phoneSearchKey(linkedUser.phoneNumber!),
            'updatedAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));
      if (!mounted) return;
      setState(() {
        _linkedPhoneNumber = linkedUser.phoneNumber;
        _isLinkingPhone = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تم التحقق من الرقم وربطه بحساب Firebase')),
      );
    } on FirebaseAuthException catch (error) {
      debugPrint('Phone credential link failed: ${error.code}');
      if (!mounted) return;
      setState(() => _isLinkingPhone = false);
    } catch (error) {
      debugPrint('Unexpected phone credential link error: $error');
      if (!mounted) return;
      setState(() => _isLinkingPhone = false);
    }
  }

  String _phoneAuthErrorMessage(Object error) {
    return 'حدثت مشكلة، حاول مرة أخرى';
  }

  void _showEditNameDialog() {
    nameController.text = userName;
    showDialog(
      context: context,
      builder: (context) => Directionality(
        textDirection: TextDirection.rtl,
        child: ValueListenableBuilder<bool>(
          valueListenable: globalDarkModeNotifier,
          builder: (context, isDark, child) {
            return AlertDialog(
              backgroundColor: isDark ? const Color(0xFF1A1A1A) : Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18),
                side: const BorderSide(color: Color(0xFF00FF66), width: 1.5),
              ),
              title: Row(
                children: const [
                  Icon(Icons.edit_outlined, size: 20),
                  SizedBox(width: 8),
                  Text(
                    "تعديل اسم المستخدم",
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              titleTextStyle: TextStyle(
                color: isDark ? const Color(0xFF00FF66) : Colors.black,
              ),
              content: TextField(
                controller: nameController,
                style: TextStyle(color: isDark ? Colors.white : Colors.black),
                decoration: InputDecoration(
                  hintText: "أدخل الاسم الجديد",
                  hintStyle: TextStyle(
                    color: isDark ? Colors.white54 : Colors.black54,
                  ),
                  enabledBorder: const UnderlineInputBorder(
                    borderSide: BorderSide(color: Color(0xFF00FF66)),
                  ),
                  focusedBorder: const UnderlineInputBorder(
                    borderSide: BorderSide(color: Color(0xFF00FF66), width: 2),
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text(
                    "إلغاء",
                    style: TextStyle(
                      color: Colors.grey,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF00FF66),
                    foregroundColor: Colors.black,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  onPressed: () async {
                    final nextName = sanitizeDisplayName(nameController.text);
                    if (nextName.isNotEmpty) {
                      setState(() {
                        userName = nextName;
                      });
                      if (firebaseReady) {
                        await syncUserDisplayNameAcrossApp(nextName);
                      }
                    }
                    if (context.mounted) Navigator.pop(context);
                  },
                  child: const Text(
                    "حفظ",
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: globalDarkModeNotifier,
      builder: (context, isDark, child) {
        return Directionality(
          textDirection: TextDirection.rtl,
          child: Scaffold(
            appBar: AppBar(
              title: Row(
                children: [
                  Icon(
                    Icons.account_circle,
                    size: 20,
                    color: isDark ? const Color(0xFF38E8A5) : Colors.black,
                  ),
                  SizedBox(width: 10),
                  Text(
                    "الحساب والمظهر",
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              backgroundColor: isDark
                  ? const Color(0xFF1A1A1A)
                  : const Color(0xFFE2E7EC),
              foregroundColor: isDark ? Colors.white : Colors.black,
              elevation: 0,
            ),
            body: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: isDark
                      ? [const Color(0xFF1A1A1A), const Color(0xFF000000)]
                      : [const Color(0xFFF4F6F9), const Color(0xFFE4E8EE)],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                ),
              ),
              child: ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  Center(
                    child: Stack(
                      children: [
                        Material(
                          color: Colors.transparent,
                          shape: const CircleBorder(),
                          clipBehavior: Clip.hardEdge,
                          child: InkWell(
                            onTap: () {
                              if (userProfileImageBytesNotifier.value != null) {
                                _showProfileImageViewer();
                              } else {
                                _pickProfileImage();
                              }
                            },
                            child: ValueListenableBuilder<XFile?>(
                              valueListenable: userProfileImageNotifier,
                              builder: (context, profileImg, child) {
                                return ValueListenableBuilder<Uint8List?>(
                                  valueListenable:
                                      userProfileImageBytesNotifier,
                                  builder: (context, imageBytes, child) =>
                                      CircleAvatar(
                                        radius: 62,
                                        backgroundColor: isDark
                                            ? const Color(0xFF00FF66)
                                            : Colors.black,
                                        child: CircleAvatar(
                                          radius: 56,
                                          backgroundColor: isDark
                                              ? Colors.black
                                              : Colors.white,
                                          child: imageBytes != null
                                              ? ClipOval(
                                                  child: Image.memory(
                                                    imageBytes,
                                                    width: 112,
                                                    height: 112,
                                                    fit: BoxFit.cover,
                                                        errorBuilder: (
                                                          context,
                                                          error,
                                                          stackTrace,
                                                        ) => Icon(
                                                          Icons.person,
                                                          size: 65,
                                                          color: isDark
                                                              ? const Color(0xFF00FF66)
                                                              : Colors.black54,
                                                        ),
                                                  ),
                                                )
                                              : Icon(
                                                  Icons.person,
                                                  size: 65,
                                                  color: isDark
                                                      ? const Color(0xFF00FF66)
                                                      : Colors.black54,
                                                ),
                                        ),
                                      ),
                                );
                              },
                            ),
                          ),
                        ),
                        Positioned(
                          bottom: 0,
                          left: 0,
                          child: Material(
                            color: isDark
                                ? const Color(0xFF00FF66)
                                : Colors.black,
                            shape: const CircleBorder(),
                            child: IconButton(
                              onPressed: _pickProfileImage,
                              tooltip: 'تغيير الصورة الشخصية',
                              icon: Icon(
                                Icons.camera_alt,
                                size: 16,
                                color: isDark ? Colors.black : Colors.white,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 15),
                  Center(
                    child: Text(
                      userName,
                      style: TextStyle(
                        color: isDark ? Colors.white : Colors.black,
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(height: 30),
                  Row(
                    children: [
                      Icon(
                        Icons.palette_outlined,
                        size: 18,
                        color: isDark ? const Color(0xFF38E8A5) : Colors.black,
                      ),
                      SizedBox(width: 8),
                      Text(
                        "إعدادات الحساب والمظهر",
                        style: TextStyle(
                          color: isDark
                              ? const Color(0xFF00FF66)
                              : Colors.black,
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Card(
                    color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    elevation: 2,
                    child: Column(
                      children: [
                        ListTile(
                          leading: Icon(
                            Icons.add_a_photo_rounded,
                            color: isDark
                                ? const Color(0xFF00FF66)
                                : Colors.black,
                          ),
                          title: Text(
                            'تغيير الصورة الشخصية',
                            style: TextStyle(
                              color: isDark ? Colors.white : Colors.black,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          subtitle: Text(
                            'اختيار صورة جديدة من الجهاز',
                            style: TextStyle(
                              color: isDark ? Colors.white60 : Colors.black54,
                              fontSize: 12,
                            ),
                          ),
                          trailing: const Icon(
                            Icons.arrow_forward_ios_rounded,
                            size: 16,
                            color: Colors.grey,
                          ),
                          onTap: _pickProfileImage,
                        ),
                        Divider(
                          color: isDark ? Colors.white24 : Colors.grey[300],
                          height: 1,
                          indent: 15,
                          endIndent: 15,
                        ),
                        ListTile(
                          leading: Icon(
                            Icons.edit_rounded,
                            color: isDark
                                ? const Color(0xFF00FF66)
                                : Colors.black,
                          ),
                          title: Text(
                            "تعديل اسم المستخدم",
                            style: TextStyle(
                              color: isDark ? Colors.white : Colors.black,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          trailing: const Icon(
                            Icons.arrow_forward_ios_rounded,
                            size: 16,
                            color: Colors.grey,
                          ),
                          onTap: _showEditNameDialog,
                        ),
                        Divider(
                          color: isDark ? Colors.white24 : Colors.grey[300],
                          height: 1,
                          indent: 15,
                          endIndent: 15,
                        ),
                        ListTile(
                          leading: Icon(
                            Icons.phone_android_rounded,
                            color: isDark
                                ? const Color(0xFF38E8A5)
                                : Colors.black,
                          ),
                          title: Text(
                            'ربط رقم الهاتف',
                            style: TextStyle(
                              color: isDark ? Colors.white : Colors.black,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          subtitle: Text(
                            _linkedPhoneNumber == null
                                ? 'أضف رقمك لتسهيل العثور عليك من جهات الاتصال'
                                : 'مرتبط: $_linkedPhoneNumber',
                            style: TextStyle(
                              color: isDark ? Colors.white54 : Colors.black54,
                              fontSize: 12,
                            ),
                          ),
                          trailing: _isLinkingPhone
                              ? const SizedBox(
                                  width: 22,
                                  height: 22,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : Icon(
                                  _linkedPhoneNumber == null
                                      ? Icons.arrow_forward_ios_rounded
                                      : Icons.verified_rounded,
                                  size: 18,
                                  color: _linkedPhoneNumber == null
                                      ? Colors.grey
                                      : const Color(0xFF38E8A5),
                                ),
                          onTap: _isLinkingPhone || _linkedPhoneNumber != null
                              ? null
                              : _linkPhoneNumber,
                        ),
                        Divider(
                          color: isDark ? Colors.white24 : Colors.grey[300],
                          height: 1,
                          indent: 15,
                          endIndent: 15,
                        ),
                        SwitchListTile(
                          secondary: Icon(
                            isDark
                                ? Icons.dark_mode_rounded
                                : Icons.light_mode_rounded,
                            color: isDark
                                ? const Color(0xFF00FF66)
                                : Colors.black,
                          ),
                          title: Text(
                            "الوضع المظلم (Dark Mode)",
                            style: TextStyle(
                              color: isDark ? Colors.white : Colors.black,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          subtitle: Text(
                            isDark
                                ? "التطبيق يعمل بالوضع المظلم حالياً"
                                : "التطبيق يعمل بالوضع الهادئ المريح",
                            style: TextStyle(
                              color: isDark ? Colors.white54 : Colors.black,
                              fontSize: 12,
                            ),
                          ),
                          value: isDark,
                          activeColor: isDark
                              ? const Color(0xFF00FF66)
                              : Colors.black,
                          onChanged: (bool value) {
                            saveDarkModeSetting(value);
                          },
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
