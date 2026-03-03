import 'package:flutter/material.dart';
import '../constants/app_constants.dart';
import '../models/fiche.dart';
import '../services/ai_sorter_service.dart';
import 'voice_note_card.dart';

/// =============================================================================
/// fiche_card.dart
/// =============================================================================
/// Widgets de cartes pour les fiches thématiques consolidées.
///
/// Chaque catégorie a son propre style de présentation:
/// - TodoFicheCard: Liste de tâches avec cases à cocher
/// - EventFicheCard: Carte événement avec date/heure
/// - ContactFicheCard: Fiche contact avec infos structurées
/// - MemoFicheCard: Note simple avec contenu texte
///
/// Ces cartes n'affichent PAS les contrôles audio (play, durée, etc.)
/// car elles représentent des données consolidées, pas des enregistrements.
/// =============================================================================

/// Carte générique qui délègue au bon type selon la catégorie
class FicheCard extends StatelessWidget {
  final Fiche fiche;
  final VoidCallback? onTap;
  final VoidCallback? onToggleFavorite;
  final VoidCallback? onDelete;
  final Function(int)? onToggleItem;
  final VoidCallback? onToggleCompleted;

  const FicheCard({
    super.key,
    required this.fiche,
    this.onTap,
    this.onToggleFavorite,
    this.onDelete,
    this.onToggleItem,
    this.onToggleCompleted,
  });

  @override
  Widget build(BuildContext context) {
    return Dismissible(
      key: Key('fiche_${fiche.id}'),
      direction: DismissDirection.horizontal,
      background: _buildFavoriteBackground(),
      secondaryBackground: _buildDeleteBackground(),
      confirmDismiss: (direction) => _handleDismiss(context, direction),
      child: _buildCard(),
    );
  }

  Widget _buildCard() {
    switch (fiche.category) {
      case NoteCategory.todo:
      case NoteCategory.shopping:
        return _TodoFicheCard(
          fiche: fiche,
          onTap: onTap,
          onToggleItem: onToggleItem,
          onToggleCompleted: onToggleCompleted,
        );
      case NoteCategory.event:
        return _EventFicheCard(fiche: fiche, onTap: onTap);
      case NoteCategory.system:
        return _MemoFicheCard(fiche: fiche, onTap: onTap);
      case NoteCategory.contact:
        return _ContactFicheCard(fiche: fiche, onTap: onTap);
      case NoteCategory.memo:
        return _MemoFicheCard(fiche: fiche, onTap: onTap);
    }
  }

  Widget _buildFavoriteBackground() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.amber.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(12),
      ),
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.only(left: 20),
      child: Icon(
        fiche.isFavorite ? Icons.star_border : Icons.star,
        color: Colors.amber,
      ),
    );
  }

  Widget _buildDeleteBackground() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.red.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(12),
      ),
      alignment: Alignment.centerRight,
      padding: const EdgeInsets.only(right: 20),
      child: const Icon(Icons.delete_outline, color: Colors.red),
    );
  }

  Future<bool> _handleDismiss(BuildContext context, DismissDirection direction) async {
    if (direction == DismissDirection.startToEnd) {
      onToggleFavorite?.call();
      return false;
    } else if (direction == DismissDirection.endToStart) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: AppColors.surface,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          title: const Text('Supprimer la fiche ?', style: AppTextStyles.heading),
          content: const Text(
            'Cette action supprimera la fiche.\nLes enregistrements audio seront conservés.',
            style: AppTextStyles.noteText,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Annuler', style: TextStyle(color: AppColors.textSecondary)),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Supprimer', style: TextStyle(color: Colors.red)),
            ),
          ],
        ),
      ) ?? false;

      if (confirmed) onDelete?.call();
      return confirmed;
    }
    return false;
  }
}

/// Carte pour les fiches de type TODO (liste de tâches)
class _TodoFicheCard extends StatelessWidget {
  final Fiche fiche;
  final VoidCallback? onTap;
  final Function(int)? onToggleItem;
  final VoidCallback? onToggleCompleted;

  const _TodoFicheCard({
    required this.fiche,
    this.onTap,
    this.onToggleItem,
    this.onToggleCompleted,
  });

  @override
  Widget build(BuildContext context) {
    final color = CategoryColors.todo;
    final hasItems = fiche.items.isNotEmpty;

    return _FicheCardBase(
      fiche: fiche,
      color: color,
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Titre avec progression
          Row(
            children: [
              Expanded(
                child: Text(
                  fiche.title,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: fiche.isCompleted ? AppColors.textSecondary : AppColors.textPrimary,
                    decoration: fiche.isCompleted ? TextDecoration.lineThrough : null,
                  ),
                ),
              ),
              if (hasItems) ...[
                Text(
                  '${fiche.completedItemsCount}/${fiche.items.length}',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    color: color,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ],
          ),
          if (hasItems) ...[
            const SizedBox(height: 10),
            // Liste des items (max 5 affichés)
            ...fiche.items.take(5).toList().asMap().entries.map((entry) {
              final index = entry.key;
              final item = entry.value;
              return Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: GestureDetector(
                  onTap: () => onToggleItem?.call(index),
                  child: Row(
                    children: [
                      Icon(
                        item.isCompleted ? Icons.check_box : Icons.check_box_outline_blank,
                        size: 18,
                        color: item.isCompleted ? color : AppColors.textSecondary,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          item.text,
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 13,
                            color: item.isCompleted ? AppColors.textSecondary : AppColors.textPrimary,
                            decoration: item.isCompleted ? TextDecoration.lineThrough : null,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }),
            if (fiche.items.length > 5)
              Text(
                '+${fiche.items.length - 5} autres',
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 11,
                  color: color,
                  fontStyle: FontStyle.italic,
                ),
              ),
          ] else if (fiche.content.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              fiche.content,
              style: AppTextStyles.noteText,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }
}

/// Carte pour les fiches de type EVENT
class _EventFicheCard extends StatelessWidget {
  final Fiche fiche;
  final VoidCallback? onTap;

  const _EventFicheCard({required this.fiche, this.onTap});

  @override
  Widget build(BuildContext context) {
    final color = CategoryColors.event;

    return _FicheCardBase(
      fiche: fiche,
      color: color,
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Titre
          Text(
            fiche.title,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: AppColors.textPrimary,
            ),
          ),
          if (fiche.eventDateTime != null || fiche.eventLocation != null) ...[
            const SizedBox(height: 8),
            // Date/heure et lieu
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                if (fiche.eventDateTime != null)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.schedule, size: 16, color: color),
                        const SizedBox(width: 6),
                        Text(
                          fiche.eventDateTime!,
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: color,
                          ),
                        ),
                      ],
                    ),
                  ),
                if (fiche.eventLocation != null)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.location_on, size: 16, color: color),
                        const SizedBox(width: 6),
                        Text(
                          fiche.eventLocation!,
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: color,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ],
          if (fiche.content.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              fiche.content,
              style: AppTextStyles.noteText,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }
}

/// Carte pour les fiches de type CONTACT
class _ContactFicheCard extends StatelessWidget {
  final Fiche fiche;
  final VoidCallback? onTap;

  const _ContactFicheCard({required this.fiche, this.onTap});

  @override
  Widget build(BuildContext context) {
    final color = CategoryColors.contact;
    final displayName = fiche.contactFullName ?? fiche.title;

    return _FicheCardBase(
      fiche: fiche,
      color: color,
      onTap: onTap,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Avatar
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.2),
              shape: BoxShape.circle,
            ),
            child: Center(
              child: Text(
                _getInitials(displayName),
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: color,
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          // Infos extraites uniquement
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  displayName,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: AppColors.textPrimary,
                  ),
                ),
                if (fiche.contactPhone != null) ...[
                  const SizedBox(height: 4),
                  _buildInfoRow(Icons.phone, fiche.contactPhone!, color),
                ],
                if (fiche.contactEmail != null) ...[
                  const SizedBox(height: 4),
                  _buildInfoRow(Icons.email, fiche.contactEmail!, color),
                ],
                if (fiche.contactBuildingCode != null) ...[
                  const SizedBox(height: 4),
                  _buildInfoRow(Icons.vpn_key, fiche.contactBuildingCode!, color),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoRow(IconData icon, String text, Color color) {
    return Row(
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 12,
              color: AppColors.textSecondary,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  String _getInitials(String name) {
    final parts = name.split(' ');
    if (parts.length >= 2) {
      return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    }
    return name.isNotEmpty ? name[0].toUpperCase() : '?';
  }
}

/// Carte pour les fiches de type MEMO
class _MemoFicheCard extends StatelessWidget {
  final Fiche fiche;
  final VoidCallback? onTap;

  const _MemoFicheCard({required this.fiche, this.onTap});

  @override
  Widget build(BuildContext context) {
    final color = CategoryColors.memo;

    return _FicheCardBase(
      fiche: fiche,
      color: color,
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Titre
          Text(
            fiche.title,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: AppColors.textPrimary,
            ),
          ),
          if (fiche.content.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              fiche.content,
              style: AppTextStyles.noteText,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }
}

/// Base commune pour toutes les cartes de fiches
class _FicheCardBase extends StatelessWidget {
  final Fiche fiche;
  final Color color;
  final VoidCallback? onTap;
  final Widget child;

  const _FicheCardBase({
    required this.fiche,
    required this.color,
    required this.child,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: color.withValues(alpha: 0.3),
          width: 1,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // En-tête: catégorie + favori (sans heure)
                Row(
                  children: [
                    Icon(_getCategoryIcon(), size: 16, color: color),
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        fiche.category.displayName.toUpperCase(),
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 9,
                          fontWeight: FontWeight.bold,
                          color: color,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ),
                    const Spacer(),
                    if (fiche.isFavorite)
                      const Icon(Icons.star, size: 14, color: Colors.amber),
                  ],
                ),
                const SizedBox(height: 10),
                // Contenu spécifique à la catégorie
                child,
              ],
            ),
          ),
        ),
      ),
    );
  }

  IconData _getCategoryIcon() {
    switch (fiche.category) {
      case NoteCategory.todo:
        return Icons.checklist;
      case NoteCategory.shopping:
        return Icons.shopping_cart;
      case NoteCategory.event:
        return Icons.calendar_today;
      case NoteCategory.system:
        return Icons.bolt;
      case NoteCategory.contact:
        return Icons.person;
      case NoteCategory.memo:
        return Icons.notes;
    }
  }
}
