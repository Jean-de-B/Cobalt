import 'dart:async';
import 'package:flutter/services.dart';
import '../models/incoming_message.dart';
import 'database_service.dart';

/// =============================================================================
/// message_aggregator_service.dart
/// =============================================================================
/// Singleton qui écoute les notifications Android en temps réel via EventChannel
/// et persiste les messages en SQLite. Suppression uniquement manuelle.
/// =============================================================================

class MessageAggregatorService {
  static MessageAggregatorService? _instance;

  factory MessageAggregatorService() {
    return _instance ??= MessageAggregatorService._internal();
  }

  static const _eventChannel = EventChannel('com.cobalt_task/notification_stream');

  final DatabaseService _db = DatabaseService();
  final List<IncomingMessage> _messages = [];
  final _controller = StreamController<List<IncomingMessage>>.broadcast();
  StreamSubscription? _eventSub;

  static const int _maxEntries = 200;

  int _unreadCount = 0;
  final _unreadController = StreamController<int>.broadcast();

  MessageAggregatorService._internal() {
    _loadFromDb();
    _listenToNotifications();
  }

  Stream<List<IncomingMessage>> get messagesStream => _controller.stream;
  List<IncomingMessage> get messages => List.unmodifiable(_messages);
  Stream<int> get unreadStream => _unreadController.stream;
  int get unreadCount => _unreadCount;

  Future<void> _loadFromDb() async {
    final saved = await _db.getMessages();
    _messages.clear();
    _messages.addAll(saved);
    _controller.add(List.unmodifiable(_messages));
  }

  void _listenToNotifications() {
    _eventSub = _eventChannel.receiveBroadcastStream().listen(
      (event) {
        if (event is Map) {
          final msg = IncomingMessage.fromNotification(event);
          _messages.insert(0, msg);

          if (_messages.length > _maxEntries) {
            final removed = _messages.removeAt(_messages.length - 1);
            _db.deleteMessage(removed.id);
          }

          _db.insertMessage(msg);

          _unreadCount++;
          _unreadController.add(_unreadCount);
          _controller.add(List.unmodifiable(_messages));
        }
      },
      onError: (error) {
        // ignore: avoid_print
        print('[MsgAggregator] EventChannel error: $error');
      },
    );
  }

  void markAllRead() {
    _unreadCount = 0;
    _unreadController.add(0);
  }

  void removeAt(int index) {
    if (index >= 0 && index < _messages.length) {
      final removed = _messages.removeAt(index);
      _db.deleteMessage(removed.id);
      _controller.add(List.unmodifiable(_messages));
    }
  }

  void clearAll() {
    _messages.clear();
    _unreadCount = 0;
    _unreadController.add(0);
    _controller.add(const []);
    _db.deleteAllMessages();
  }

  void dispose() {
    _eventSub?.cancel();
    _controller.close();
    _unreadController.close();
  }
}
