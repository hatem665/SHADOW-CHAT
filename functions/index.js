const { initializeApp } = require('firebase-admin/app');
const { getFirestore } = require('firebase-admin/firestore');
const { getMessaging } = require('firebase-admin/messaging');
const { onDocumentCreated } = require('firebase-functions/v2/firestore');

initializeApp();

exports.notifyNewMessage = onDocumentCreated(
  'chats/{chatId}/messages/{messageId}',
  async (event) => {
    const message = event.data?.data();
    if (!message || typeof message.uid !== 'string') return;

    const db = getFirestore();
    const recipientIds = new Set();
    if (typeof message.recipientUid === 'string'
      && message.recipientUid !== message.uid) {
      recipientIds.add(message.recipientUid);
    }

    const chatId = event.params.chatId;
    const membersRoomId = chatId.startsWith('secret_group_')
      ? chatId
      : chatId === 'shadow_ops' || chatId === 'secret_room'
        ? 'secret_room'
        : null;
    if (membersRoomId) {
      const members = await db.collection('rooms').doc(membersRoomId)
        .collection('members').get();
      for (const member of members.docs) {
        if (member.id !== message.uid) {
          recipientIds.add(member.id);
        }
      }
    }
    if (recipientIds.size === 0) return;

    const recipients = await Promise.all(
      [...recipientIds].map(async (uid) => {
        const [userDoc, settingsDoc] = await Promise.all([
          db.collection('users').doc(uid).get(),
          db.collection('users').doc(uid).collection('settings')
            .doc('privacy').get(),
        ]);
        const token = userDoc.data()?.fcmToken;
        const messageSound = settingsDoc.data()?.messageSound;
        return messageSound === false ? null : token;
      }),
    );
    const tokens = recipients
      .filter((token) => typeof token === 'string' && token.length > 0);
    if (tokens.length === 0) return;

    const text = typeof message.text === 'string' ? message.text : 'رسالة جديدة';
    await getMessaging().sendEachForMulticast({
      tokens,
      notification: {
        title: 'Shadow Chat',
        body: text.length > 120 ? `${text.substring(0, 117)}...` : text,
      },
      android: {
        priority: 'high',
        notification: { sound: 'default', channelId: 'shadow_messages' },
      },
      webpush: {
        notification: { title: 'Shadow Chat', body: text },
      },
      data: { chatId, messageId: event.params.messageId },
    });
  },
);
