import 'package:flutter/material.dart';
import '../constants/app_constants.dart';
import '../models/incoming_message.dart';
import '../services/message_aggregator_service.dart';

class MessageAggregatorScreen extends StatefulWidget {
  const MessageAggregatorScreen({super.key});

  @override
  State<MessageAggregatorScreen> createState() => _MessageAggregatorScreenState();
}

class _MessageAggregatorScreenState extends State<MessageAggregatorScreen> {
  final _service = MessageAggregatorService();

  @override
  void initState() {
    super.initState();
    _service.markAllRead();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<IncomingMessage>>(
      stream: _service.messagesStream,
      initialData: _service.messages,
      builder: (context, snapshot) {
        final messages = snapshot.data ?? [];

        if (messages.isEmpty) {
          return _buildEmpty();
        }

        return ListView.builder(
          padding: EdgeInsets.only(
            top: MediaQuery.of(context).padding.top + kToolbarHeight + 8,
            bottom: 100,
          ),
          itemCount: messages.length,
          itemBuilder: (context, index) => _MessageTile(message: messages[index]),
        );
      },
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.chat_bubble_outline,
              size: 64,
              color: AppColors.textTertiary,
            ),
            const SizedBox(height: 24),
            const Text('Aucun message reçu', style: AppTextStyles.heading),
            const SizedBox(height: 8),
            const Text(
              'Les messages entrants de vos apps\nde messagerie apparaîtront ici',
              style: AppTextStyles.metadata,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _MessageTile extends StatelessWidget {
  final IncomingMessage message;

  const _MessageTile({required this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        boxShadow: const [
          BoxShadow(color: AppColors.shadowLight, blurRadius: 6, offset: Offset(0, 2)),
        ],
      ),
      child: Row(
        children: [
          _AppBadge(appSource: message.appSource),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        message.senderName,
                        style: AppTextStyles.cardTitle.copyWith(fontSize: 15),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _formatTime(message.receivedAt),
                      style: AppTextStyles.metadata.copyWith(fontSize: 12),
                    ),
                  ],
                ),
                if (message.messagePreview.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(
                    message.messagePreview,
                    style: AppTextStyles.cardBody.copyWith(fontSize: 13),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
                const SizedBox(height: 4),
                Text(
                  message.appSource,
                  style: AppTextStyles.metadata.copyWith(
                    fontSize: 11,
                    color: _appColor(message.appSource),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _formatTime(DateTime dt) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final msgDay = DateTime(dt.year, dt.month, dt.day);

    if (msgDay == today) {
      return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    }
    if (msgDay == today.subtract(const Duration(days: 1))) {
      return 'hier';
    }
    return '${dt.day}/${dt.month}';
  }

  static Color _appColor(String app) {
    switch (app) {
      case 'WhatsApp':
        return const Color(0xFF25D366);
      case 'Telegram':
        return const Color(0xFF0088CC);
      case 'Signal':
        return const Color(0xFF3A76F0);
      case 'Messenger':
        return const Color(0xFF0084FF);
      case 'SMS':
        return const Color(0xFF4CAF50);
      default:
        return AppColors.textSecondary;
    }
  }
}

class _AppBadge extends StatelessWidget {
  final String appSource;

  const _AppBadge({required this.appSource});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: _MessageTile._appColor(appSource).withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Center(
        child: Text(
          _icon(),
          style: const TextStyle(fontSize: 18),
        ),
      ),
    );
  }

  String _icon() {
    switch (appSource) {
      case 'WhatsApp':
        return 'W';
      case 'Telegram':
        return 'T';
      case 'Signal':
        return 'S';
      case 'Messenger':
        return 'M';
      case 'SMS':
        return '✉';
      default:
        return '?';
    }
  }
}
