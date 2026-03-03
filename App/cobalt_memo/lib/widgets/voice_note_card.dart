import 'package:flutter/material.dart';
import '../constants/app_constants.dart';
import '../models/voice_note.dart';
import '../services/ai_sorter_service.dart';

/// =============================================================================
/// voice_note_card.dart
/// =============================================================================
/// Smart Card minimaliste avec état contracté/étendu.
///
/// Contracté (défaut): Icône + Titre en gras + Heure
/// Étendu (au clic): + Divider + Player audio + Transcription brute
/// =============================================================================

/// Couleurs par catégorie
class CategoryColors {
  static const Color todo = Color(0xFFFF9500);     // Orange
  static const Color shopping = Color(0xFFFFD60A);  // Gold
  static const Color event = Color(0xFF00AAFF);     // Bleu
  static const Color system = Color(0xFFFF6B6B);    // Coral
  static const Color contact = Color(0xFFAA66FF);   // Violet (legacy)
  static const Color memo = AppColors.accent;        // Vert

  static Color forCategory(NoteCategory category) {
    switch (category) {
      case NoteCategory.todo:
        return todo;
      case NoteCategory.shopping:
        return shopping;
      case NoteCategory.event:
        return event;
      case NoteCategory.system:
        return system;
      case NoteCategory.contact:
        return contact;
      case NoteCategory.memo:
        return memo;
    }
  }
}

/// Mapping sentiment → emoji pour les MEMO
class MemoEmoji {
  static String forText(String text) {
    final lower = text.toLowerCase();
    if (RegExp(r'idée|idea|concept|invention|projet|trouv').hasMatch(lower)) return '💡';
    if (RegExp(r'souvenir|amour|merci|bonheur|heureux|content|super|génial').hasMatch(lower)) return '❤️';
    if (RegExp(r'colère|énervé|frustré|merde|putain|chiant|ras.le.bol|nul').hasMatch(lower)) return '😡';
    if (RegExp(r'question|pourquoi|comment|demander|comprend').hasMatch(lower)) return '🤔';
    if (RegExp(r'urgent|important|critique|attention|oubli').hasMatch(lower)) return '⚡';
    if (RegExp(r'musique|chanson|concert|playlist|écouter').hasMatch(lower)) return '🎵';
    if (RegExp(r'voyage|vacances|avion|hôtel|destination|partir').hasMatch(lower)) return '✈️';
    if (RegExp(r'rêve|dormir|nuit|sommeil').hasMatch(lower)) return '🌙';
    if (RegExp(r'argent|prix|budget|payer|euro|dépense').hasMatch(lower)) return '💰';
    if (RegExp(r'santé|médecin|docteur|mal|douleur|médicament').hasMatch(lower)) return '🏥';
    return '💬';
  }
}

class VoiceNoteCard extends StatefulWidget {
  final VoiceNote note;
  final VoidCallback? onPlay;
  final VoidCallback? onStop;
  final bool isPlaying;
  final VoidCallback? onTap;
  final VoidCallback? onDelete;
  final VoidCallback? onToggleFavorite;
  final VoidCallback? onToggleCompleted;

  const VoiceNoteCard({
    super.key,
    required this.note,
    this.onPlay,
    this.onStop,
    this.isPlaying = false,
    this.onTap,
    this.onDelete,
    this.onToggleFavorite,
    this.onToggleCompleted,
  });

  @override
  State<VoiceNoteCard> createState() => _VoiceNoteCardState();
}

class _VoiceNoteCardState extends State<VoiceNoteCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return Dismissible(
      key: Key('note_${widget.note.id}'),
      direction: DismissDirection.horizontal,
      background: _buildFavoriteBackground(),
      secondaryBackground: _buildDeleteBackground(),
      confirmDismiss: (direction) => _handleDismiss(context, direction),
      child: _buildCard(),
    );
  }

  Widget _buildCard() {
    final categoryColor = CategoryColors.forCategory(widget.note.category);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: widget.note.isProcessing
              ? AppColors.border
              : categoryColor.withValues(alpha: 0.3),
          width: 1,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          borderRadius: BorderRadius.circular(12),
          child: AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeInOut,
            alignment: Alignment.topCenter,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // === ÉTAT CONTRACTÉ (toujours visible) ===
                _buildContractedRow(categoryColor),
                // === ÉTAT ÉTENDU (au clic) ===
                if (_expanded) ...[
                  const Divider(
                    color: AppColors.border,
                    height: 1,
                    indent: 16,
                    endIndent: 16,
                  ),
                  _buildExpandedContent(categoryColor),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Row contracté : Icône + Titre bold + Heure
  Widget _buildContractedRow(Color categoryColor) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          // Icône catégorie (ou spinner si processing)
          _buildCategoryIcon(categoryColor),
          const SizedBox(width: 12),
          // Titre en gras (action validée)
          Expanded(
            child: Text(
              widget.note.displayTitle,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: widget.note.isCompleted
                    ? AppColors.textSecondary
                    : AppColors.textPrimary,
                decoration: widget.note.isCompleted
                    ? TextDecoration.lineThrough
                    : null,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          // Favori
          if (widget.note.isFavorite)
            const Padding(
              padding: EdgeInsets.only(right: 6),
              child: Icon(Icons.star, size: 14, color: Colors.amber),
            ),
          // Heure
          Text(
            widget.note.formattedTime,
            style: AppTextStyles.metadata,
          ),
        ],
      ),
    );
  }

  /// Icône de catégorie ou emoji pour MEMO
  Widget _buildCategoryIcon(Color categoryColor) {
    // En cours de traitement → spinner
    if (widget.note.isProcessing) {
      return SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          valueColor: AlwaysStoppedAnimation<Color>(categoryColor),
        ),
      );
    }

    // Erreur → icône erreur
    if (widget.note.errorMessage != null) {
      return const Icon(Icons.error_outline, size: 20, color: Colors.red);
    }

    // MEMO → emoji basé sur le sentiment du texte
    if (widget.note.category == NoteCategory.memo) {
      final emoji = MemoEmoji.forText(
        widget.note.summary.isNotEmpty ? widget.note.summary : widget.note.text,
      );
      return Text(emoji, style: const TextStyle(fontSize: 18));
    }

    // Autres catégories → icône Material
    IconData icon;
    switch (widget.note.category) {
      case NoteCategory.todo:
        icon = widget.note.isCompleted
            ? Icons.check_box
            : Icons.checklist;
        break;
      case NoteCategory.shopping:
        icon = Icons.shopping_cart;
        break;
      case NoteCategory.event:
        icon = Icons.calendar_today;
        break;
      case NoteCategory.system:
        icon = Icons.bolt;
        break;
      case NoteCategory.contact:
        icon = Icons.person;
        break;
      case NoteCategory.memo:
        icon = Icons.notes;
        break;
    }

    // TODO checkbox cliquable
    if (widget.note.category == NoteCategory.todo &&
        widget.onToggleCompleted != null) {
      return GestureDetector(
        onTap: widget.onToggleCompleted,
        child: Icon(icon, size: 20,
          color: widget.note.isCompleted ? categoryColor : AppColors.textSecondary,
        ),
      );
    }

    return Icon(icon, size: 20, color: categoryColor);
  }

  /// Contenu étendu : Player audio + Transcription brute
  Widget _buildExpandedContent(Color categoryColor) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Player audio
          _buildAudioPlayer(categoryColor),
          const SizedBox(height: 12),
          // Transcription brute Whisper (gris, pour vérification)
          Text(
            widget.note.text.isEmpty
                ? (widget.note.isProcessing
                    ? 'Transcription en cours...'
                    : 'Note vide')
                : widget.note.text,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 13,
              color: AppColors.textSecondary,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }

  /// Player audio minimaliste : bouton play + durée
  Widget _buildAudioPlayer(Color categoryColor) {
    final isDisabled = widget.note.isProcessing ||
        widget.note.errorMessage != null;

    return Row(
      children: [
        // Bouton Play/Stop circulaire
        GestureDetector(
          onTap: isDisabled
              ? null
              : () => widget.isPlaying
                  ? widget.onStop?.call()
                  : widget.onPlay?.call(),
          child: Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: isDisabled
                  ? AppColors.border
                  : (widget.isPlaying ? categoryColor : Colors.white),
              shape: BoxShape.circle,
            ),
            child: Icon(
              widget.isPlaying ? Icons.stop : Icons.play_arrow,
              size: 20,
              color: isDisabled
                  ? AppColors.textSecondary
                  : (widget.isPlaying ? Colors.white : Colors.black),
            ),
          ),
        ),
        const SizedBox(width: 12),
        // Durée
        Text(
          widget.note.formattedDuration,
          style: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 13,
            color: AppColors.textSecondary,
          ),
        ),
      ],
    );
  }

  // === Swipe actions ===

  Widget _buildFavoriteBackground() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.amber.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(12),
      ),
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.only(left: 20),
      child: Icon(
        widget.note.isFavorite ? Icons.star_border : Icons.star,
        color: Colors.amber,
      ),
    );
  }

  Widget _buildDeleteBackground() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.red.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(12),
      ),
      alignment: Alignment.centerRight,
      padding: const EdgeInsets.only(right: 20),
      child: const Icon(Icons.delete_outline, color: Colors.red),
    );
  }

  Future<bool> _handleDismiss(
      BuildContext context, DismissDirection direction) async {
    if (direction == DismissDirection.startToEnd) {
      widget.onToggleFavorite?.call();
      return false;
    } else if (direction == DismissDirection.endToStart) {
      final confirmed = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              backgroundColor: AppColors.surface,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
              title: const Text('Supprimer la note ?',
                  style: AppTextStyles.heading),
              content: const Text('Cette action est irréversible.',
                  style: AppTextStyles.noteText),
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
}
