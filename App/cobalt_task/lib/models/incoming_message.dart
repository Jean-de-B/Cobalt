/// =============================================================================
/// incoming_message.dart
/// =============================================================================
/// Modèle représentant un message entrant capturé via NotificationListenerService.
/// Stocké en mémoire vive uniquement (pas de persistance SQLite).
/// =============================================================================

class IncomingMessage {
  final String id;
  final String senderName;
  final String messagePreview;
  final String appSource;
  final String appPackage;
  final DateTime receivedAt;

  IncomingMessage({
    required this.id,
    required this.senderName,
    required this.messagePreview,
    required this.appSource,
    required this.appPackage,
    required this.receivedAt,
  });

  /// Noms d'apps lisibles depuis le packageName
  static const Map<String, String> appNames = {
    'com.whatsapp': 'WhatsApp',
    'com.whatsapp.w4b': 'WhatsApp',
    'org.telegram.messenger': 'Telegram',
    'org.thoughtcrime.securesms': 'Signal',
    'com.facebook.orca': 'Messenger',
    'com.instagram.android': 'Instagram',
    'com.linkedin.android': 'LinkedIn',
    'com.google.android.apps.messaging': 'SMS',
    'com.android.mms': 'SMS',
    'com.samsung.android.messaging': 'SMS',
  };

  Map<String, dynamic> toMap() => {
    'id': id,
    'sender_name': senderName,
    'message_preview': messagePreview,
    'app_source': appSource,
    'app_package': appPackage,
    'received_at': receivedAt.millisecondsSinceEpoch,
  };

  factory IncomingMessage.fromMap(Map<String, dynamic> map) => IncomingMessage(
    id: map['id'] as String,
    senderName: map['sender_name'] as String,
    messagePreview: map['message_preview'] as String? ?? '',
    appSource: map['app_source'] as String,
    appPackage: map['app_package'] as String,
    receivedAt: DateTime.fromMillisecondsSinceEpoch(map['received_at'] as int),
  );

  factory IncomingMessage.fromNotification(Map<dynamic, dynamic> data) {
    final packageName = data['packageName'] as String? ?? '';
    final preview = data['messagePreview'] as String? ?? '';

    return IncomingMessage(
      id: '${data['timestamp'] ?? DateTime.now().millisecondsSinceEpoch}_${packageName.hashCode}',
      senderName: data['senderName'] as String? ?? 'Inconnu',
      messagePreview: preview.length > 100 ? preview.substring(0, 100) : preview,
      appSource: appNames[packageName] ?? packageName,
      appPackage: packageName,
      receivedAt: DateTime.fromMillisecondsSinceEpoch(
        (data['timestamp'] as int?) ?? DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }
}
