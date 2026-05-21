import 'dart:convert';
import 'package:flutter/material.dart';
import '../constants/app_constants.dart';
import '../models/voice_note.dart';
import '../services/ai_sorter_service.dart';
import '../services/settings_service.dart';

/// =============================================================================
/// memo_card.dart
/// =============================================================================
/// Carte d'action tracée.
///
/// Contracté (défaut) :
///   [Icône] [Titre / contact] [Heure]
///   + tous les détails structurés de l'action (toujours lisibles)
///
/// Développé (tap) :
///   + transcription brute + lecteur audio (debug / vérification)
/// =============================================================================

class MemoCard extends StatefulWidget {
  final VoiceNote note;
  final VoidCallback? onPlay;
  final VoidCallback? onStop;
  final bool isPlaying;
  final VoidCallback? onDelete;

  const MemoCard({
    super.key,
    required this.note,
    this.onPlay,
    this.onStop,
    this.isPlaying = false,
    this.onDelete,
  });

  @override
  State<MemoCard> createState() => _MemoCardState();
}

class _MemoCardState extends State<MemoCard> {
  bool _isExpanded = false;

  Map<String, dynamic>? get _action {
    final json = widget.note.actionJson;
    if (json == null || json.isEmpty) return null;
    try {
      return jsonDecode(json) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  String get _intent => _action?['intent'] as String? ?? 'none';

  /// La section détail est disponible si la note a un texte transcrit ou un audio
  bool get _canExpand =>
      !widget.note.isProcessing &&
      (widget.note.text.isNotEmpty || widget.note.audioPath.isNotEmpty);

  /// True si la note est une fiche rejetée (silence, hallucination)
  bool get _isRejected =>
      widget.note.errorMessage != null &&
      (widget.note.errorMessage == 'silence' || widget.note.errorMessage == 'hallucination');

  @override
  Widget build(BuildContext context) {
    return Dismissible(
      key: Key('memo_${widget.note.id}'),
      direction: DismissDirection.endToStart,
      background: _buildDeleteBackground(),
      confirmDismiss: (direction) => _handleDismiss(context, direction),
      child: _buildCard(),
    );
  }

  Widget _buildCard() {
    return GestureDetector(
      onTap: _canExpand ? () => setState(() => _isExpanded = !_isExpanded) : null,
      child: Opacity(
        opacity: _isRejected ? 0.5 : 1.0,
        child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          boxShadow: const [
            BoxShadow(
              color: AppColors.shadowMedium,
              blurRadius: 12,
              offset: Offset(0, 4),
            ),
          ],
        ),
        child: AnimatedSize(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeInOut,
          alignment: Alignment.topCenter,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // === En-tête : icône + titre + badge type + heure ===
              _buildHeader(),

              // === Détails structurés — toujours visibles après traitement ===
              if (!widget.note.isProcessing && widget.note.errorMessage == null) ...[
                const SizedBox(height: 10),
                _buildStructuredContent(),
              ],

              // === Section debug — uniquement en mode développé ===
              if (_isExpanded && _canExpand) ...[
                _buildDivider(),
                _buildDebugSection(),
              ],
            ],
          ),
        ),
      ),
      ),
    );
  }

  // ===========================================================================
  // EN-TÊTE (icône + titre + badge + heure)
  // ===========================================================================

  Widget _buildHeader() {
    final visuals = _getVisuals();
    final badge = _getBadge();

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        _buildIcon(visuals),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            _getTitle(),
            style: AppTextStyles.cardTitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (badge != null) ...[
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            decoration: BoxDecoration(
              color: visuals.color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              badge,
              style: AppTextStyles.metadata.copyWith(
                color: visuals.color,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
        const SizedBox(width: 6),
        Text(
          _getTimeString(),
          style: AppTextStyles.metadata.copyWith(fontSize: 11),
        ),
      ],
    );
  }

  Widget _buildIcon(_ActionVisuals visuals) {
    if (widget.note.isProcessing) {
      return Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: AppColors.border,
          borderRadius: BorderRadius.circular(10),
        ),
        child: const Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation<Color>(AppColors.textSecondary),
            ),
          ),
        ),
      );
    }

    if (widget.note.errorMessage != null) {
      return Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: Colors.red.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(10),
        ),
        child: const Icon(Icons.error_outline, size: 18, color: Colors.red),
      );
    }

    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: visuals.color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Icon(visuals.icon, size: 18, color: visuals.color),
    );
  }

  // ===========================================================================
  // DÉTAILS STRUCTURÉS (toujours affichés)
  // ===========================================================================

  Widget _buildStructuredContent() {
    final action = _action;
    if (action == null) {
      // Anciennes notes sans actionJson → texte du summary uniquement
      final text = widget.note.summary;
      if (text.isEmpty) return const SizedBox.shrink();
      return Text(
        _stripEmoji(text),
        style: AppTextStyles.cardBody,
      );
    }

    final params = action['params'] as Map<String, dynamic>? ?? {};
    final resolved = action['resolved'] as Map<String, dynamic>? ?? {};

    switch (_intent) {
      case 'calendar':
        return _buildCalendarDetails(params);
      case 'sms':
        return _buildMessageDetails(
          contact: resolved['contact'] as String? ?? params['recipient'] as String? ?? '',
          app: 'SMS',
          message: params['message'] as String? ?? '',
        );
      case 'messaging':
        return _buildMessageDetails(
          contact: resolved['contact'] as String? ?? params['recipient'] as String? ?? '',
          app: _appLabel(resolved['app'] as String? ?? params['app'] as String? ?? ''),
          message: params['message'] as String? ?? '',
        );
      case 'message':
        return _buildMessageDetails(
          contact: resolved['contact'] as String? ?? params['recipient'] as String? ?? '',
          app: _appLabel(resolved['app'] as String? ?? ''),
          message: params['message'] as String? ?? '',
        );
      case 'payment':
        return _buildPaymentDetails(params, resolved);
      case 'none':
      default:
        final raw = params['memo'] as String?;
        final displayText =
            (raw != null && raw.isNotEmpty) ? raw : widget.note.summary;
        if (displayText.isEmpty) return const SizedBox.shrink();
        return Text(
          displayText.trim(),
          style: AppTextStyles.cardBody,
        );
    }
  }

  /// Événement calendrier : date + heure sur deux lignes, lieu, description
  /// (titre déjà dans l'en-tête, heure d'enregistrement dans le debug)
  Widget _buildCalendarDetails(Map<String, dynamic> params) {
    final startRaw = params['start_time'] as String?;
    final endRaw = params['end_time'] as String?;
    final location = params['location'] as String?;
    final description = params['description'] as String?;

    final startDt = startRaw != null ? DateTime.tryParse(startRaw) : null;
    final endDt = endRaw != null ? DateTime.tryParse(endRaw) : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (startDt != null) ...[
          _DetailRow(
            icon: Icons.calendar_today,
            color: AppColors.actionCalendar,
            text: _formatDateOnly(startDt),
          ),
          const SizedBox(height: 6),
          _DetailRow(
            icon: Icons.schedule,
            color: AppColors.actionCalendar,
            text: _formatTimeRange(startDt, endDt),
          ),
          const SizedBox(height: 6),
        ],
        if (location != null && location.isNotEmpty) ...[
          _DetailRow(
            icon: Icons.location_on_outlined,
            color: AppColors.actionCalendar,
            text: location,
          ),
          const SizedBox(height: 6),
        ],
        if (description != null && description.isNotEmpty)
          _DetailRow(
            icon: Icons.notes,
            color: AppColors.actionCalendar,
            text: description,
          ),
      ],
    );
  }

  /// Message envoyé : texte exact dans un bloc cité (contact déjà dans l'en-tête)
  Widget _buildMessageDetails({
    required String contact,
    required String app,
    required String message,
  }) {
    final color = switch (_intent) {
      'sms' => AppColors.actionSms,
      _ => AppColors.actionWhatsapp,
    };

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(10),
        border: Border(left: BorderSide(color: color, width: 3)),
      ),
      child: Text(
        message.isNotEmpty ? message : '—',
        style: AppTextStyles.cardBody,
      ),
    );
  }

  /// Paiement : destinataire, montant, note
  Widget _buildPaymentDetails(
    Map<String, dynamic> params,
    Map<String, dynamic> resolved,
  ) {
    const color = Color(0xFF00C471);
    final contact = resolved['contact'] as String? ?? params['recipient'] as String? ?? '';
    final amount = (params['amount'] as num?)?.toDouble() ?? 0;
    final note = params['note'] as String?;
    final amtStr = amount == amount.roundToDouble()
        ? '${amount.toInt()}€'
        : '${amount.toStringAsFixed(2)}€';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _DetailRow(
          icon: Icons.person_outline,
          color: color,
          text: contact.isNotEmpty ? contact : '—',
          bold: true,
        ),
        const SizedBox(height: 6),
        _DetailRow(
          icon: Icons.euro,
          color: color,
          text: amtStr,
          bold: true,
        ),
        const SizedBox(height: 4),
        _DetailRow(
          icon: Icons.account_balance,
          color: color,
          text: 'Demande de remboursement',
        ),
        if (note != null && note.isNotEmpty) ...[
          const SizedBox(height: 4),
          _DetailRow(icon: Icons.notes, color: color, text: note),
        ],
      ],
    );
  }

  // ===========================================================================
  // SECTION DEBUG (développée uniquement)
  // ===========================================================================

  Widget _buildDebugSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Heure d'enregistrement (pour tous les types)
        Row(
          children: [
            Icon(Icons.access_time, size: 14, color: AppColors.textTertiary),
            const SizedBox(width: 4),
            Text('Enregistré à ${_getTimeString()}', style: AppTextStyles.metadata),
          ],
        ),
        const SizedBox(height: 10),
        // Transcription brute entre guillemets
        if (widget.note.text.isNotEmpty) ...[
          Text(
            '« ${widget.note.text} »',
            style: AppTextStyles.cardBody.copyWith(
              color: AppColors.textSecondary,
              fontStyle: FontStyle.italic,
            ),
          ),
          const SizedBox(height: 12),
        ],
        // Lecteur audio
        _buildAudioPlayer(),
      ],
    );
  }

  Widget _buildAudioPlayer() {
    return Row(
      children: [
        Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () => widget.isPlaying
                ? widget.onStop?.call()
                : widget.onPlay?.call(),
            borderRadius: BorderRadius.circular(20),
            child: Icon(
              widget.isPlaying ? Icons.stop_circle : Icons.play_circle_filled,
              size: 32,
              color: AppColors.textPrimary,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text(widget.note.formattedDuration, style: AppTextStyles.metadata),
      ],
    );
  }

  // ===========================================================================
  // LOGIQUE D'AFFICHAGE
  // ===========================================================================

  String _getTimeString() {
    final d = widget.note.date;
    return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  /// Titre principal de l'en-tête
  String _getTitle() {
    if (widget.note.isProcessing) return 'Traitement...';
    if (widget.note.errorMessage != null) return 'Erreur';

    final action = _action;
    if (action == null) {
      final s = widget.note.summary;
      return s.isNotEmpty ? _stripEmoji(s) : widget.note.text;
    }

    final params = action['params'] as Map<String, dynamic>? ?? {};
    final resolved = action['resolved'] as Map<String, dynamic>? ?? {};

    switch (_intent) {
      case 'calendar':
        return params['title'] as String? ?? 'Événement';
      case 'sms':
      case 'messaging':
      case 'message':
        final c = resolved['contact'] as String? ?? params['recipient'] as String? ?? '';
        return c.isNotEmpty ? c : 'Message';
      case 'payment':
        final c = resolved['contact'] as String? ?? params['recipient'] as String? ?? '';
        final amt = (params['amount'] as num?)?.toDouble() ?? 0;
        final amtStr = amt == amt.roundToDouble()
            ? '${amt.toInt()}€'
            : '${amt.toStringAsFixed(2)}€';
        return '$amtStr → $c';
      case 'none':
        final memo = params['memo'] as String? ?? '';
        if (memo.isEmpty) {
          final s = widget.note.summary;
          return s.isNotEmpty ? _stripEmoji(s) : 'Mémo';
        }
        final firstLine = memo.split('\n').first.trim();
        return firstLine.isNotEmpty ? firstLine : 'Mémo';
      default:
        return _stripEmoji(widget.note.summary);
    }
  }

  /// Badge court sous le titre (type d'action)
  String? _getBadge() {
    if (widget.note.isProcessing || widget.note.errorMessage != null) return null;
    final action = _action;

    // Notes legacy sans actionJson : badge basé sur la catégorie IA
    if (action == null) return _badgeForCategory(widget.note.category);

    final params = action['params'] as Map<String, dynamic>? ?? {};
    final resolved = action['resolved'] as Map<String, dynamic>? ?? {};

    switch (_intent) {
      case 'calendar':
        return 'Google Calendar';
      case 'sms':
        return 'SMS';
      case 'messaging':
        return _appLabel(resolved['app'] as String? ?? params['app'] as String? ?? '');
      case 'message':
        return _appLabel(resolved['app'] as String? ?? '');
      case 'payment':
        return 'Paiement';
      case 'none':
      default:
        return (params['syncedService'] as String?) ?? _badgeForCategory(widget.note.category);
    }
  }

  String? _badgeForCategory(NoteCategory category) {
    final s = SettingsService();
    return switch (category) {
      NoteCategory.todo     => SettingsService.reminderServices[s.reminderService] ?? 'Google Tasks',
      NoteCategory.shopping => SettingsService.listServices[s.listService] ?? 'Google Tasks',
      NoteCategory.event    => 'Google Calendar',
      NoteCategory.contact  => 'Contacts',
      NoteCategory.memo     => switch (s.notesService) {
          'samsung' => 'Samsung Notes',
          'notion'  => 'Notion',
          _         => 'Google Tasks',
        },
    };
  }

  _ActionVisuals _getVisuals() {
    if (widget.note.isProcessing) {
      return const _ActionVisuals(icon: Icons.hourglass_empty, color: AppColors.textSecondary);
    }
    if (widget.note.errorMessage != null) {
      return const _ActionVisuals(icon: Icons.error_outline, color: Colors.red);
    }
    switch (_intent) {
      case 'calendar':
        return const _ActionVisuals(icon: Icons.event, color: AppColors.actionCalendar);
      case 'sms':
        return const _ActionVisuals(icon: Icons.sms, color: AppColors.actionSms);
      case 'messaging':
      case 'message':
        return const _ActionVisuals(icon: Icons.chat_bubble_outline, color: AppColors.actionWhatsapp);
      case 'payment':
        return const _ActionVisuals(icon: Icons.account_balance, color: Color(0xFF00C471));
      case 'none':
        return switch (widget.note.category) {
          NoteCategory.todo     => const _ActionVisuals(icon: Icons.checklist, color: AppColors.categoryTodo),
          NoteCategory.shopping => const _ActionVisuals(icon: Icons.shopping_cart_outlined, color: AppColors.categoryShopping),
          NoteCategory.event    => const _ActionVisuals(icon: Icons.event_note, color: AppColors.categoryEvent),
          NoteCategory.contact  => const _ActionVisuals(icon: Icons.person_outline, color: AppColors.categoryContact),
          NoteCategory.memo     => const _ActionVisuals(icon: Icons.edit_note, color: AppColors.categoryMemo),
        };
      default:
        return const _ActionVisuals(icon: Icons.edit_note, color: AppColors.categoryMemo);
    }
  }

  // ===========================================================================
  // HELPERS
  // ===========================================================================

  /// "Mer 16 mars 2026"
  String _formatDateOnly(DateTime dt) {
    final weekdays = ['Lun', 'Mar', 'Mer', 'Jeu', 'Ven', 'Sam', 'Dim'];
    final months = ['janvier', 'février', 'mars', 'avril', 'mai', 'juin',
                    'juillet', 'août', 'septembre', 'octobre', 'novembre', 'décembre'];
    return '${weekdays[dt.weekday - 1]} ${dt.day} ${months[dt.month - 1]} ${dt.year}';
  }

  /// "14h00 – 15h30"  ou  "14h00"
  String _formatTimeRange(DateTime start, DateTime? end) {
    String t(DateTime d) =>
        '${d.hour.toString().padLeft(2, '0')}h${d.minute.toString().padLeft(2, '0')}';
    return end != null ? '${t(start)} – ${t(end)}' : t(start);
  }

  String _appLabel(String app) {
    return switch (app.toLowerCase()) {
      'whatsapp' || 'wa' => 'WhatsApp',
      'telegram' || 'tg' => 'Telegram',
      'signal' => 'Signal',
      'messenger' => 'Messenger',
      'sms' => 'SMS',
      _ => 'SMS',
    };
  }

  Widget _buildDivider() {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 12),
      child: Divider(height: 1, color: AppColors.border),
    );
  }

  Widget _buildDeleteBackground() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.red.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(16),
      ),
      alignment: Alignment.centerRight,
      padding: const EdgeInsets.only(right: 20),
      child: const Icon(Icons.delete_outline, color: Colors.red),
    );
  }

  Future<bool> _handleDismiss(BuildContext context, DismissDirection direction) async {
    if (direction == DismissDirection.endToStart) {
      final confirmed = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('Supprimer ?'),
              content: const Text('Cette action est irréversible.'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Annuler',
                      style: TextStyle(color: AppColors.textSecondary)),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Supprimer', style: TextStyle(color: Colors.red)),
                ),
              ],
            ),
          ) ??
          false;
      if (confirmed) widget.onDelete?.call();
      return confirmed;
    }
    return false;
  }

  String _stripEmoji(String text) {
    return text.replaceFirst(
        RegExp(
            r'^[\u{1F300}-\u{1F9FF}\u{2600}-\u{26FF}\u{2700}-\u{27BF}\u{FE00}-\u{FE0F}\u{200D}\u{20E3}\u{E0020}-\u{E007F}]+\s*',
            unicode: true),
        '');
  }
}

// =============================================================================
// DATA CLASSES
// =============================================================================

class _ActionVisuals {
  final IconData icon;
  final Color color;
  const _ActionVisuals({required this.icon, required this.color});
}

// =============================================================================
// WIDGET UTILITAIRE
// =============================================================================

/// Ligne de détail : icône colorée + texte
class _DetailRow extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String text;
  final bool bold;

  const _DetailRow({
    required this.icon,
    required this.color,
    required this.text,
    this.bold = false,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 15, color: color),
        const SizedBox(width: 7),
        Expanded(
          child: Text(
            text,
            style: bold
                ? AppTextStyles.cardBody.copyWith(fontWeight: FontWeight.w600)
                : AppTextStyles.cardBody,
          ),
        ),
      ],
    );
  }
}
