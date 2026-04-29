import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/debug_console_service.dart';
import '../services/ble_service.dart';

/// Ecran debug firmware : affiche les logs BLE en temps reel.
/// Style cohérent avec le _DebugConsolePanel de l'écran principal.
class DebugScreen extends StatefulWidget {
  final BleService bleService;

  const DebugScreen({super.key, required this.bleService});

  @override
  State<DebugScreen> createState() => _DebugScreenState();
}

class _DebugScreenState extends State<DebugScreen> {
  final _scrollController = ScrollController();
  final _logs = <DebugLogEntry>[];
  StreamSubscription? _bleDebugSub;
  bool _autoScroll = true;

  @override
  void initState() {
    super.initState();
    // Activer les notifications Debug Log BLE
    widget.bleService.enableDebugLog();
    // Écouter les logs firmware BLE directement (pas le singleton app)
    _bleDebugSub = widget.bleService.debugLogStream.listen((logMsg) {
      for (final line in logMsg.split('\n')) {
        if (line.trim().isNotEmpty) {
          setState(() {
            _logs.add(DebugLogEntry(
              time: DateTime.now(),
              message: line.trim(),
              level: 'firmware',
            ));
            if (_logs.length > 1000) _logs.removeAt(0);
          });
          _scrollToBottom();
        }
      }
    });
  }

  @override
  void dispose() {
    _bleDebugSub?.cancel();
    widget.bleService.disableDebugLog();
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    if (_autoScroll && _scrollController.hasClients) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0A0A),
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        titleSpacing: 0,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('FW',
                style: TextStyle(fontFamily: 'monospace', fontSize: 14, color: Colors.white)),
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
              decoration: BoxDecoration(
                color: widget.bleService.isConnected
                    ? Colors.green.withValues(alpha: 0.15)
                    : Colors.red.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                widget.bleService.isConnected ? 'BLE' : 'OFF',
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 9,
                  color: widget.bleService.isConnected ? Colors.green : Colors.red,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
        actions: [
          GestureDetector(
            onTap: () => setState(() => _autoScroll = !_autoScroll),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Icon(
                _autoScroll ? Icons.vertical_align_bottom : Icons.pause,
                size: 18,
                color: _autoScroll ? const Color(0xFF00FF88) : Colors.orange,
              ),
            ),
          ),
          GestureDetector(
            onTap: () {
              final text = _logs
                  .map((e) => '[${e.timeStr}] ${e.message}')
                  .join('\n');
              Clipboard.setData(ClipboardData(text: text));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Logs copiés'),
                  backgroundColor: Color(0xFF1A1A1A),
                ),
              );
            },
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8),
              child: Icon(Icons.copy, size: 16, color: Color(0xFF666666)),
            ),
          ),
          GestureDetector(
            onTap: () => setState(() => _logs.clear()),
            child: const Padding(
              padding: EdgeInsets.only(left: 8, right: 14),
              child: Icon(Icons.delete_outline, size: 16, color: Color(0xFF666666)),
            ),
          ),
        ],
      ),
      body: _logs.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.terminal, size: 40,
                      color: Colors.green.withValues(alpha: 0.3)),
                  const SizedBox(height: 12),
                  Text(
                    widget.bleService.isConnected
                        ? 'En attente de logs firmware...'
                        : 'Montre non connectée',
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 13,
                      color: Color(0xFF555555),
                    ),
                  ),
                ],
              ),
            )
          : ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              itemCount: _logs.length,
              itemBuilder: (context, index) {
                final entry = _logs[index];
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 0.5),
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: '${entry.timeStr} ',
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 10,
                            color: Color(0xFF555555),
                          ),
                        ),
                        TextSpan(
                          text: entry.message,
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 10,
                            color: Colors.green,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }
}
