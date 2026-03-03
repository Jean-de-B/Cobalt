import 'package:flutter/material.dart';
import '../constants/app_constants.dart';
import '../models/voice_note.dart';
import '../services/ai_sorter_service.dart';

/// =============================================================================
/// memo_card.dart
/// =============================================================================
/// Widget carte pour afficher un memo vocal.
///
/// Design minimaliste avec deux etats :
/// - Contracte (defaut) : Icone + Titre gras + Heure
/// - Etendu (au clic) : Divider + Player audio + Transcription brute
/// =============================================================================

/// Visuels d'une categorie (icone, couleur, label)
class _CategoryVisuals {
  final IconData icon;
  final Color color;
  final String label;

  const _CategoryVisuals({
    required this.icon,
    required this.color,
    required this.label,
  });
}

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
    final canExpand =
        !widget.note.isProcessing && widget.note.errorMessage == null;

    return GestureDetector(
      onTap: canExpand
          ? () => setState(() => _isExpanded = !_isExpanded)
          : null,
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
              // === Ligne contractee : icone + titre + heure ===
              _buildContractedRow(),

              // === Contenu etendu (si ouvert) ===
              if (_isExpanded && canExpand) ...[
                _buildDivider(),
                _buildExpandedContent(),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // ===========================================================================
  // CONTRACTED ROW
  // ===========================================================================

  /// Ligne principale toujours visible : [Icone 36x36] [Titre] ... [HH:MM]
  Widget _buildContractedRow() {
    final visuals = _getCategoryVisuals();

    return Row(
      children: [
        // Icone categorie
        _buildCategoryIcon(visuals),
        const SizedBox(width: 12),

        // Titre (1 ligne, ellipsis)
        Expanded(
          child: Text(
            _getDisplayTitle(),
            style: AppTextStyles.cardTitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 12),

        // Heure
        Text(
          _getTimeString(),
          style: AppTextStyles.cardTime,
        ),
      ],
    );
  }

  /// Icone de categorie 36x36 (spinner si processing, rouge si erreur)
  Widget _buildCategoryIcon(_CategoryVisuals visuals) {
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
              valueColor:
                  AlwaysStoppedAnimation<Color>(AppColors.textSecondary),
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
  // EXPANDED CONTENT
  // ===========================================================================

  /// Divider entre la ligne contractee et le contenu etendu
  Widget _buildDivider() {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 12),
      child: Divider(height: 1, color: AppColors.border),
    );
  }

  /// Contenu affiche quand la carte est etendue
  Widget _buildExpandedContent() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Player audio
        _buildAudioPlayer(),

        // Transcription brute
        if (widget.note.text.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(
            widget.note.text,
            style: AppTextStyles.cardBody,
            maxLines: 5,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ],
    );
  }

  /// Player audio minimaliste : [Play 32px] 00:12
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

  /// Heure formatee HH:MM
  String _getTimeString() {
    final d = widget.note.date;
    return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  /// Titre principal
  String _getDisplayTitle() {
    if (widget.note.isProcessing) return 'Traitement...';
    if (widget.note.errorMessage != null) return 'Erreur';

    final summary = widget.note.summary;

    // Actions locales (emoji-prefixed) : strip l'emoji
    if (summary.isNotEmpty) {
      final stripped = _stripEmoji(summary);
      if (stripped != summary && stripped.isNotEmpty) {
        return stripped;
      }
    }

    // Categories AI sorter
    switch (widget.note.category) {
      case NoteCategory.contact:
        return widget.note.contactName ??
            (summary.isNotEmpty ? summary : 'Contact');
      case NoteCategory.event:
        return summary.isNotEmpty ? summary : 'Evenement';
      case NoteCategory.todo:
        return summary.isNotEmpty ? summary : 'Tache';
      case NoteCategory.shopping:
        return summary.isNotEmpty ? summary : 'Courses';
      case NoteCategory.memo:
        return summary.isNotEmpty ? summary : 'Memo';
    }
  }

  /// Determine les visuels depuis la categorie, les emojis ou le sentiment
  _CategoryVisuals _getCategoryVisuals() {
    if (widget.note.isProcessing) {
      return const _CategoryVisuals(
        icon: Icons.hourglass_empty,
        color: AppColors.textSecondary,
        label: 'Traitement',
      );
    }

    if (widget.note.errorMessage != null) {
      return const _CategoryVisuals(
        icon: Icons.error_outline,
        color: Colors.red,
        label: 'Erreur',
      );
    }

    final summary = widget.note.summary;

    // --- Actions locales (backward compat emoji detection) ---
    if (summary.startsWith('\u{1F4C5}')) {
      return const _CategoryVisuals(
          icon: Icons.event,
          color: AppColors.actionCalendar,
          label: 'Calendrier');
    }
    if (summary.startsWith('\u{1F4AC}') && summary.contains('SMS')) {
      return const _CategoryVisuals(
          icon: Icons.sms, color: AppColors.actionSms, label: 'SMS');
    }
    if (summary.startsWith('\u{1F4AC}')) {
      return const _CategoryVisuals(
          icon: Icons.chat,
          color: AppColors.actionWhatsapp,
          label: 'Message');
    }
    if (summary.startsWith('\u{1F4DE}')) {
      return const _CategoryVisuals(
          icon: Icons.phone, color: AppColors.actionCall, label: 'Appel');
    }
    if (summary.startsWith('\u{1F5FA}')) {
      return const _CategoryVisuals(
          icon: Icons.navigation,
          color: AppColors.actionNav,
          label: 'Navigation');
    }
    if (summary.startsWith('\u{1F3B5}')) {
      return const _CategoryVisuals(
          icon: Icons.music_note,
          color: AppColors.actionMedia,
          label: 'Musique');
    }
    if (summary.startsWith('\u{1F4F1}')) {
      return const _CategoryVisuals(
          icon: Icons.apps,
          color: AppColors.actionApp,
          label: 'Application');
    }
    // Systeme (alarme, minuteur, volume) → icone unique
    if (summary.startsWith('\u{23F0}') ||
        summary.startsWith('\u{23F1}') ||
        summary.startsWith('\u{1F50A}')) {
      return const _CategoryVisuals(
          icon: Icons.notifications_active,
          color: AppColors.actionSystem,
          label: 'Systeme');
    }

    // --- Categories AI sorter ---
    switch (widget.note.category) {
      case NoteCategory.todo:
        return const _CategoryVisuals(
            icon: Icons.checklist,
            color: AppColors.categoryTodo,
            label: 'Tache');
      case NoteCategory.shopping:
        return const _CategoryVisuals(
            icon: Icons.shopping_cart_outlined,
            color: AppColors.categoryShopping,
            label: 'Courses');
      case NoteCategory.event:
        return const _CategoryVisuals(
            icon: Icons.calendar_today,
            color: AppColors.categoryEvent,
            label: 'Evenement');
      case NoteCategory.contact:
        return const _CategoryVisuals(
            icon: Icons.person_outline,
            color: AppColors.categoryContact,
            label: 'Contact');
      case NoteCategory.memo:
        return _getMemoVisuals();
    }
  }

  /// Visuels MEMO selon le sentiment detecte par l'IA
  _CategoryVisuals _getMemoVisuals() {
    switch (widget.note.sentiment) {
      case 'idea':
        return const _CategoryVisuals(
            icon: Icons.lightbulb_outline,
            color: AppColors.categoryMemo,
            label: 'Idee');
      case 'frustration':
        return const _CategoryVisuals(
            icon: Icons.sentiment_very_dissatisfied,
            color: AppColors.categoryMemo,
            label: 'Memo');
      case 'memory':
        return const _CategoryVisuals(
            icon: Icons.favorite_outline,
            color: AppColors.categoryMemo,
            label: 'Souvenir');
      case 'question':
        return const _CategoryVisuals(
            icon: Icons.help_outline,
            color: AppColors.categoryMemo,
            label: 'Question');
      default:
        return const _CategoryVisuals(
            icon: Icons.edit_note,
            color: AppColors.categoryMemo,
            label: 'Memo');
    }
  }

  // ===========================================================================
  // UTILITAIRES
  // ===========================================================================

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

  Future<bool> _handleDismiss(
      BuildContext context, DismissDirection direction) async {
    if (direction == DismissDirection.endToStart) {
      final confirmed = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('Supprimer le memo ?'),
              content: const Text('Cette action est irreversible.'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Annuler',
                      style: TextStyle(color: AppColors.textSecondary)),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Supprimer',
                      style: TextStyle(color: Colors.red)),
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

  /// Strip les emojis en debut de summary
  String _stripEmoji(String text) {
    return text.replaceFirst(
        RegExp(
            r'^[\u{1F300}-\u{1F9FF}\u{2600}-\u{26FF}\u{2700}-\u{27BF}\u{FE00}-\u{FE0F}\u{200D}\u{20E3}\u{E0020}-\u{E007F}]+\s*',
            unicode: true),
        '');
  }
}
