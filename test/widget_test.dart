// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:shadow_shat/main.dart';

void main() {
  test('duplicate Firebase initialization is ignored safely', () {
    final duplicateError = FirebaseException(
      plugin: 'firebase_core',
      code: 'duplicate-app',
      message: 'A Firebase App named "[DEFAULT]" already exists',
    );

    expect(isDuplicateFirebaseInitializationError(duplicateError), isTrue);
    expect(isDuplicateFirebaseInitializationError(FirebaseException(
      plugin: 'firebase_core',
      code: 'unknown',
      message: 'other error',
    )), isFalse);
  });

  test('Firebase add failures expose the real error code', () {
    expect(
      firebaseWriteFailureMessage(
        FirebaseException(plugin: 'cloud_firestore', code: 'permission-denied'),
      ),
      contains('permission-denied'),
    );
  });

  test('regular contact action blocks duplicate request states', () {
    expect(
      determineRegularContactAction(myStatus: 'pending', otherStatus: 'none'),
      'pending',
    );
    expect(
      determineRegularContactAction(myStatus: 'none', otherStatus: 'incoming'),
      'incoming',
    );
    expect(
      determineRegularContactAction(myStatus: 'accepted', otherStatus: 'none'),
      'accepted',
    );
    expect(
      determineRegularContactAction(myStatus: 'rejected', otherStatus: 'none'),
      'rejected',
    );
  });

  test('display names are sanitized consistently before saving', () {
    expect(
      sanitizeDisplayName('   علي   أحمد   '),
      'علي أحمد',
    );
    expect(sanitizeDisplayName(''), isEmpty);
  });

  test('live contact name takes precedence over the saved name', () {
    expect(resolveLiveContactDisplayName('الاسم الجديد', 'الاسم القديم'), 'الاسم الجديد');
    expect(resolveLiveContactDisplayName(null, 'الاسم القديم'), 'الاسم القديم');
  });

  test('chat history cutoff hides old messages but preserves newer ones', () {
    final clearedAt = Timestamp.fromDate(DateTime.utc(2026, 9, 28, 12));
    expect(
      isMessageVisibleAfterHistoryClear(
        Timestamp.fromDate(DateTime.utc(2026, 9, 28, 11)),
        clearedAt: clearedAt,
      ),
      isFalse,
    );
    expect(
      isMessageVisibleAfterHistoryClear(
        Timestamp.fromDate(DateTime.utc(2026, 9, 28, 13)),
        clearedAt: clearedAt,
      ),
      isTrue,
    );
    expect(
      isMessageVisibleAfterHistoryClear(null, clearedAt: clearedAt),
      isFalse,
    );
  });

  test('unknown contact cleanup preserves pending and incoming requests', () {
    expect(
      shouldRemoveUnknownContact({'status': 'pending', 'displayName': ''}),
      isFalse,
    );
    expect(
      shouldRemoveUnknownContact({'status': 'incoming', 'displayName': 'unknown'}),
      isFalse,
    );
    expect(
      shouldRemoveUnknownContact({'status': 'accepted', 'displayName': 'unknown'}),
      isTrue,
    );
    expect(
      resolveContactDisplayName('', fallback: 'مستخدم'),
      'مستخدم',
    );
  });

  test('secret member removal policy allows group removal and owner-only room removal', () {
    expect(
      canRemoveSecretMember(
        isGroup: true,
        ownerVerified: false,
        isOwnerUser: false,
      ),
      isTrue,
    );
    expect(
      canRemoveSecretMember(
        isGroup: false,
        ownerVerified: false,
        isOwnerUser: true,
      ),
      isFalse,
    );
    expect(
      canRemoveSecretMember(
        isGroup: false,
        ownerVerified: true,
        isOwnerUser: true,
      ),
      isTrue,
    );
    expect(
      canRemoveSecretMember(
        isGroup: false,
        ownerVerified: true,
        isOwnerUser: false,
      ),
      isFalse,
    );
  });

  test('secret room member count treats owner as a single counted member and avoids duplicates', () {
    expect(
      resolveSecretRoomMemberCount(
        memberIds: ['u1', 'u2', 'u1'],
        ownerUid: 'u2',
      ),
      2,
    );
    expect(
      resolveSecretRoomMemberCount(
        memberIds: ['u1', 'u2', 'u3'],
        ownerUid: 'owner',
      ),
      4,
    );
    expect(
      resolveSecretRoomMemberCount(
        memberIds: List.generate(120, (index) => 'u$index'),
        ownerUid: 'owner',
      ),
      100,
    );
  });

  test('secret groups empty state is hidden while the first group is still being prepared', () {
    expect(
      shouldShowSecretGroupsEmptyState(
        isPreparing: true,
        groupsCount: 0,
      ),
      isFalse,
    );
    expect(
      shouldShowSecretGroupsEmptyState(
        isPreparing: false,
        groupsCount: 0,
      ),
      isTrue,
    );
    expect(
      shouldShowSecretGroupsEmptyState(
        isPreparing: false,
        groupsCount: 1,
      ),
      isFalse,
    );
  });

  testWidgets('Shadow Chat app starts', (WidgetTester tester) async {
    appLockEnabledNotifier.value = true;
    appLockPasswordNotifier.value = await hashPassword('test-app-lock-password');
    await tester.pumpWidget(const MaterialApp(home: AppLockGate()));

    expect(find.byType(AppLockGate), findsOneWidget);
    expect(find.text('تغيير كلمة سر قفل التطبيق'), findsOneWidget);
  });
}
