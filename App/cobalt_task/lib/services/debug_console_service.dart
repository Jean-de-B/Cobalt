import 'dart:async';
import 'dart:collection';

/// Service qui capture les logs de l'application pour les afficher dans l'UI.
/// Singleton — les logs sont stockés en mémoire (ring buffer de 500 lignes max).
class DebugConsoleService {
  static DebugConsoleService? _instance;
  factory DebugConsoleService() {
    _instance ??= DebugConsoleService._internal();
    return _instance!;
  }
  DebugConsoleService._internal();

  static const int _maxLines = 500;
  final _logs = Queue<DebugLogEntry>();
  final _controller = StreamController<List<DebugLogEntry>>.broadcast();

  Stream<List<DebugLogEntry>> get stream => _controller.stream;
  List<DebugLogEntry> get logs => _logs.toList();

  void log(String message, {String level = 'info'}) {
    final entry = DebugLogEntry(
      time: DateTime.now(),
      message: message,
      level: level,
    );
    _logs.addLast(entry);
    while (_logs.length > _maxLines) {
      _logs.removeFirst();
    }
    _controller.add(_logs.toList());
  }

  void clear() {
    _logs.clear();
    _controller.add([]);
  }
}

class DebugLogEntry {
  final DateTime time;
  final String message;
  final String level; // info, warning, error

  const DebugLogEntry({
    required this.time,
    required this.message,
    this.level = 'info',
  });

  String get timeStr =>
      '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}:${time.second.toString().padLeft(2, '0')}';
}
