import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import '../constants/app_constants.dart';
import '../models/fiche.dart';
import '../models/voice_note.dart';
import '../services/ai_sorter_service.dart';
import '../services/audio_service.dart';
import '../services/database_service.dart';
import '../widgets/ble_status_indicator.dart';
import '../widgets/fiche_card.dart';
import '../widgets/voice_note_card.dart';

/// =============================================================================
/// home_screen.dart
/// =============================================================================
/// Écran principal de l'application Cobalt Voice.
///
/// Interface minimaliste affichant:
/// - AppBar avec indicateur BLE et titre
/// - Liste chronologique des notes vocales
/// - État vide si aucune note
///
/// L'écran utilise des Streams pour une mise à jour réactive:
/// - Stream des notes depuis SQLite
/// - Stream de l'état de lecture audio
/// - Stream de progression du transfert BLE
/// =============================================================================

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  /// Services
  final AudioService _audioService = AudioService();
  final DatabaseService _databaseService = DatabaseService();

  /// Filtre de catégorie actif (null = toutes les catégories)
  NoteCategory? _selectedCategory;

  /// Filtre favoris actif
  bool _showOnlyFavorites = false;

  @override
  void initState() {
    super.initState();
    // Observer pour détecter le retour au premier plan
    WidgetsBinding.instance.addObserver(this);
    // Rafraîchir les streams au démarrage
    _databaseService.refreshStream();
    _databaseService.refreshFichesStream();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Quand l'app revient au premier plan
    if (state == AppLifecycleState.resumed) {
      // ignore: avoid_print
      print('APP: Retour au premier plan - retry des transcriptions en attente');
      _audioService.retryPendingTranscriptions();
      _databaseService.refreshStream();
      _databaseService.refreshFichesStream();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: _buildAppBar(),
      body: _buildBody(),
      floatingActionButton: _buildPTTButton(),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
    );
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      backgroundColor: AppColors.background,
      elevation: 0,
      centerTitle: false,
      title: const Text(
        'Cobalt Voice',
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: 20,
          fontWeight: FontWeight.bold,
          color: AppColors.textPrimary,
        ),
      ),
      actions: [
        // Indicateur de progression du transfert
        _buildTransferIndicator(),
        // Indicateur batterie (discret)
        _buildBatteryIndicator(),
        // Indicateur d'état BLE
        BleStatusIndicator(
          audioService: _audioService,
          onScanRequested: _scanAndPickDevice,
        ),
        const SizedBox(width: 8),
      ],
    );
  }

  Widget _buildTransferIndicator() {
    return StreamBuilder<double>(
      stream: _audioService.transferProgressStream,
      initialData: 0.0,
      builder: (context, snapshot) {
        final progress = snapshot.data ?? 0.0;
        if (progress <= 0 || progress >= 1) {
          return const SizedBox.shrink();
        }

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: SizedBox(
            width: 60,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                LinearProgressIndicator(
                  value: progress,
                  backgroundColor: AppColors.border,
                  valueColor: AlwaysStoppedAnimation<Color>(AppColors.accent),
                ),
                const SizedBox(height: 2),
                Text(
                  '${(progress * 100).toInt()}%',
                  style: AppTextStyles.metadata.copyWith(fontSize: 10),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildBatteryIndicator() {
    return StreamBuilder<int>(
      stream: _audioService.batteryLevelStream,
      initialData: _audioService.batteryLevel,
      builder: (context, snapshot) {
        final level = snapshot.data ?? -1;
        // Ne pas afficher si batterie non disponible
        if (level < 0) {
          return const SizedBox.shrink();
        }

        // Couleur selon le niveau
        Color color;
        if (level <= 15) {
          color = Colors.red;
        } else if (level <= 30) {
          color = Colors.orange;
        } else {
          color = AppColors.textSecondary;
        }

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                _getBatteryIcon(level),
                size: 14,
                color: color,
              ),
              const SizedBox(width: 2),
              Text(
                '$level%',
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 10,
                  color: color,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  IconData _getBatteryIcon(int level) {
    if (level >= 90) return Icons.battery_full;
    if (level >= 70) return Icons.battery_6_bar;
    if (level >= 50) return Icons.battery_4_bar;
    if (level >= 30) return Icons.battery_3_bar;
    if (level >= 15) return Icons.battery_2_bar;
    return Icons.battery_1_bar;
  }

  /// Bouton PTT (Push-To-Talk) flottant
  Widget _buildPTTButton() {
    return StreamBuilder<bool>(
      stream: _audioService.recordingStateStream,
      initialData: _audioService.isRecording,
      builder: (context, snapshot) {
        final isRecording = snapshot.data ?? false;

        return GestureDetector(
          onLongPressStart: (_) => _startPTTRecording(),
          onLongPressEnd: (_) => _stopPTTRecording(),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: isRecording ? 80 : 64,
            height: isRecording ? 80 : 64,
            decoration: BoxDecoration(
              color: isRecording ? Colors.red.shade700 : Colors.red,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: Colors.red.withValues(alpha: isRecording ? 0.6 : 0.3),
                  blurRadius: isRecording ? 20 : 10,
                  spreadRadius: isRecording ? 2 : 0,
                ),
              ],
            ),
            child: Icon(
              Icons.mic,
              color: Colors.white,
              size: isRecording ? 40 : 32,
            ),
          ),
        );
      },
    );
  }

  Future<void> _startPTTRecording() async {
    final success = await _audioService.startRecording();
    if (!success && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Impossible d\'accéder au microphone',
            style: TextStyle(fontFamily: 'monospace'),
          ),
          backgroundColor: Colors.red,
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _stopPTTRecording() async {
    await _audioService.stopRecording();
  }

  Widget _buildBody() {
    return Column(
      children: [
        // Filtres par catégorie
        _buildCategoryFilters(),
        // Contenu selon le mode
        Expanded(
          child: _selectedCategory == null && !_showOnlyFavorites
              ? _buildArchiveView() // "Tout" = VoiceNotes avec audio
              : _buildFichesView(), // Catégories = Fiches consolidées
        ),
      ],
    );
  }

  /// Vue archive: toutes les notes vocales avec contrôles audio
  Widget _buildArchiveView() {
    return StreamBuilder<List<VoiceNote>>(
      stream: _databaseService.notesStream,
      initialData: _databaseService.lastNotes,
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return _buildLoadingState();
        }

        final notes = snapshot.data!;
        if (notes.isEmpty) {
          return _buildEmptyState();
        }

        return _buildNotesList(notes);
      },
    );
  }

  /// Vue fiches: fiches thématiques consolidées (sans audio)
  Widget _buildFichesView() {
    return StreamBuilder<List<Fiche>>(
      stream: _databaseService.fichesStream,
      initialData: _databaseService.lastFiches,
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return _buildLoadingState();
        }

        var fiches = snapshot.data!;

        // Filtrer par favoris
        if (_showOnlyFavorites) {
          fiches = fiches.where((f) => f.isFavorite).toList();
        }

        // Filtrer par catégorie si sélectionnée
        if (_selectedCategory != null) {
          fiches = fiches.where((f) => f.category == _selectedCategory).toList();
        }

        if (fiches.isEmpty) {
          return _buildEmptyState();
        }

        return _buildFichesList(fiches);
      },
    );
  }

  Widget _buildCategoryFilters() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            // Bouton favoris
            _buildFavoritesChip(),
            const SizedBox(width: 8),
            _buildFilterChip(null, 'Tout', Icons.apps),
            const SizedBox(width: 8),
            _buildFilterChip(NoteCategory.todo, 'Tâches', Icons.checklist),
            const SizedBox(width: 8),
            _buildFilterChip(NoteCategory.shopping, 'Courses', Icons.shopping_cart),
            const SizedBox(width: 8),
            _buildFilterChip(NoteCategory.event, 'Agenda', Icons.calendar_today),
            const SizedBox(width: 8),
            _buildFilterChip(NoteCategory.system, 'Système', Icons.bolt),
            const SizedBox(width: 8),
            _buildFilterChip(NoteCategory.memo, 'Mémos', Icons.notes),
          ],
        ),
      ),
    );
  }

  Widget _buildFavoritesChip() {
    return GestureDetector(
      onTap: () {
        setState(() {
          _showOnlyFavorites = !_showOnlyFavorites;
        });
        // Rafraîchir le stream des fiches pour le mode favoris
        if (_showOnlyFavorites || _selectedCategory != null) {
          _databaseService.refreshFichesStream();
        } else {
          _databaseService.refreshStream();
        }
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: _showOnlyFavorites ? Colors.amber.withValues(alpha: 0.2) : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: _showOnlyFavorites ? Colors.amber : AppColors.border,
            width: 1,
          ),
        ),
        child: Icon(
          _showOnlyFavorites ? Icons.star : Icons.star_border,
          size: 18,
          color: _showOnlyFavorites ? Colors.amber : AppColors.textSecondary,
        ),
      ),
    );
  }

  IconData _getCategoryIcon(NoteCategory category) {
    switch (category) {
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

  Widget _buildFilterChip(NoteCategory? category, String label, IconData icon) {
    final isSelected = _selectedCategory == category;
    final color = category != null
        ? CategoryColors.forCategory(category)
        : AppColors.accent;

    return GestureDetector(
      onTap: () {
        setState(() {
          _selectedCategory = category;
        });
        // Rafraîchir les streams selon le mode
        if (category == null && !_showOnlyFavorites) {
          _databaseService.refreshStream();
        } else {
          _databaseService.refreshFichesStream();
        }
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? color.withValues(alpha: 0.2) : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected ? color : AppColors.border,
            width: 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 16,
              color: isSelected ? color : AppColors.textSecondary,
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                color: isSelected ? color : AppColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLoadingState() {
    return const Center(
      child: CircularProgressIndicator(
        valueColor: AlwaysStoppedAnimation<Color>(AppColors.accent),
      ),
    );
  }

  Widget _buildEmptyState() {
    // Icône et message selon le filtre actif
    IconData icon;
    String title;
    String subtitle;

    if (_selectedCategory != null) {
      icon = _getCategoryIcon(_selectedCategory!);
      title = 'Aucune ${_selectedCategory!.displayName.toLowerCase()}';
      subtitle = 'Les notes de cette catégorie\napparaîtront ici';
    } else {
      icon = Icons.mic_none;
      title = 'Aucune note vocale';
      subtitle = 'Enregistrez une note avec le bracelet\nou le bouton micro';
    }

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 64,
              color: AppColors.textSecondary.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 24),
            Text(title, style: AppTextStyles.heading),
            const SizedBox(height: 8),
            Text(
              subtitle,
              style: AppTextStyles.metadata,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),
            // Bouton de scan manuel (caché si connecté)
            StreamBuilder<BleConnectionState>(
              stream: _audioService.bleConnectionStateStream,
              initialData: _audioService.bleConnectionState,
              builder: (context, snapshot) {
                final state = snapshot.data ?? BleConnectionState.disconnected;
                final isScanning = state == BleConnectionState.scanning;
                final isConnected = state == BleConnectionState.connected;

                // Ne pas afficher le bouton si déjà connecté
                if (isConnected) {
                  return const SizedBox.shrink();
                }

                return OutlinedButton.icon(
                  onPressed: isScanning ? null : () => _scanAndPickDevice(),
                  icon: Icon(
                    isScanning ? Icons.bluetooth_searching : Icons.bluetooth,
                    size: 18,
                  ),
                  label: Text(
                    isScanning ? 'Recherche...' : 'Connecter une montre',
                    style: const TextStyle(fontFamily: 'monospace'),
                  ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.accent,
                    side: const BorderSide(color: AppColors.accent),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: 12,
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNotesList(List<VoiceNote> notes) {
    return StreamBuilder<int?>(
      stream: _audioService.playbackStateStream,
      initialData: null,
      builder: (context, playbackSnapshot) {
        // Le stream déclenche un rebuild quand l'état de lecture change
        return ListView.builder(
          padding: const EdgeInsets.only(top: 8, bottom: 80),
          itemCount: notes.length,
          itemBuilder: (context, index) {
            final note = notes[index];
            return VoiceNoteCard(
              note: note,
              isPlaying: _audioService.isPlaying(note.id),
              onPlay: () => _playNote(note),
              onStop: () => _audioService.stopPlayback(),
              onTap: () => _showNoteDetail(note),
              onDelete: () => _deleteNote(note),
              onToggleFavorite: () => _toggleFavorite(note),
              onToggleCompleted: () => _toggleCompleted(note),
            );
          },
        );
      },
    );
  }

  Widget _buildFichesList(List<Fiche> fiches) {
    return ListView.builder(
      padding: const EdgeInsets.only(top: 8, bottom: 80),
      itemCount: fiches.length,
      itemBuilder: (context, index) {
        final fiche = fiches[index];
        return FicheCard(
          fiche: fiche,
          onTap: () => _showFicheDetail(fiche),
          onDelete: () => _deleteFiche(fiche),
          onToggleFavorite: () => _toggleFicheFavorite(fiche),
          onToggleItem: (itemIndex) => _toggleFicheItem(fiche, itemIndex),
          onToggleCompleted: () => _toggleFicheCompleted(fiche),
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // SÉLECTION D'APPAREIL BLE
  // ---------------------------------------------------------------------------

  /// Lance le scan et affiche un bottom sheet pour choisir l'appareil
  Future<void> _scanAndPickDevice() async {
    // Lancer le scan sans auto-connect (l'utilisateur choisit)
    _audioService.startBleScan(autoConnect: false);

    if (!mounted) return;

    // Afficher le bottom sheet de sélection
    await showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      isScrollControlled: true,
      builder: (context) => _DevicePickerSheet(audioService: _audioService),
    );
  }

  // ---------------------------------------------------------------------------
  // ACTIONS
  // ---------------------------------------------------------------------------

  Future<void> _playNote(VoiceNote note) async {
    try {
      await _audioService.playNote(note);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Erreur de lecture: $e',
              style: const TextStyle(fontFamily: 'monospace'),
            ),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _deleteNote(VoiceNote note) async {
    // Supprimer le fichier audio
    await _audioService.deleteAudioFile(note.audioPath);
    // Supprimer de la base de données
    if (note.id != null) {
      await _databaseService.deleteNote(note.id!);
    }
  }

  Future<void> _toggleFavorite(VoiceNote note) async {
    if (note.id != null) {
      await _databaseService.toggleFavorite(note.id!);
    }
  }

  Future<void> _toggleCompleted(VoiceNote note) async {
    if (note.id != null) {
      await _databaseService.toggleCompleted(note.id!);
    }
  }

  // ---------------------------------------------------------------------------
  // ACTIONS FICHES
  // ---------------------------------------------------------------------------

  Future<void> _deleteFiche(Fiche fiche) async {
    if (fiche.id != null) {
      await _databaseService.deleteFiche(fiche.id!);
    }
  }

  Future<void> _toggleFicheFavorite(Fiche fiche) async {
    if (fiche.id != null) {
      await _databaseService.toggleFicheFavorite(fiche.id!);
    }
  }

  Future<void> _toggleFicheItem(Fiche fiche, int itemIndex) async {
    if (fiche.id != null) {
      await _databaseService.toggleFicheItem(fiche.id!, itemIndex);
    }
  }

  Future<void> _toggleFicheCompleted(Fiche fiche) async {
    if (fiche.id != null) {
      await _databaseService.toggleFicheCompleted(fiche.id!);
    }
  }

  void _showFicheDetail(Fiche fiche) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.6,
        minChildSize: 0.3,
        maxChildSize: 0.9,
        expand: false,
        builder: (context, scrollController) {
          return _FicheDetailSheet(
            fiche: fiche,
            scrollController: scrollController,
            onToggleItem: (index) => _toggleFicheItem(fiche, index),
          );
        },
      ),
    );
  }

  void _showNoteDetail(VoiceNote note) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.6,
        minChildSize: 0.3,
        maxChildSize: 0.9,
        expand: false,
        builder: (context, scrollController) {
          return _NoteDetailSheet(
            note: note,
            scrollController: scrollController,
            onPlay: () => _playNote(note),
            onStop: () => _audioService.stopPlayback(),
            isPlaying: _audioService.isPlaying(note.id),
          );
        },
      ),
    );
  }
}

/// Sheet de détail d'une fiche
class _FicheDetailSheet extends StatelessWidget {
  final Fiche fiche;
  final ScrollController scrollController;
  final Function(int)? onToggleItem;

  const _FicheDetailSheet({
    required this.fiche,
    required this.scrollController,
    this.onToggleItem,
  });

  @override
  Widget build(BuildContext context) {
    final color = CategoryColors.forCategory(fiche.category);

    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Column(
        children: [
          // Poignée de drag
          Container(
            margin: const EdgeInsets.only(top: 12),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: AppColors.border,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          // En-tête
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Icon(_getCategoryIcon(), size: 24, color: color),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        fiche.title,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${fiche.category.displayName} • ${fiche.sourceNoteIds.length} enregistrement(s)',
                        style: AppTextStyles.metadata,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const Divider(color: AppColors.border),
          // Contenu scrollable
          Expanded(
            child: SingleChildScrollView(
              controller: scrollController,
              padding: const EdgeInsets.all(16),
              child: _buildContent(color),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContent(Color color) {
    // Affichage spécifique selon la catégorie
    switch (fiche.category) {
      case NoteCategory.todo:
      case NoteCategory.shopping:
        return _buildTodoContent(color);
      case NoteCategory.event:
        return _buildEventContent(color);
      case NoteCategory.system:
        return _buildMemoContent();
      case NoteCategory.contact:
        return _buildContactContent(color);
      case NoteCategory.memo:
        return _buildMemoContent();
    }
  }

  Widget _buildTodoContent(Color color) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (fiche.items.isNotEmpty) ...[
          // Progression
          Row(
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: fiche.itemsProgress,
                    backgroundColor: color.withValues(alpha: 0.2),
                    valueColor: AlwaysStoppedAnimation<Color>(color),
                    minHeight: 6,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Text(
                '${fiche.completedItemsCount}/${fiche.items.length}',
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: color,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // Liste complète des items
          ...fiche.items.asMap().entries.map((entry) {
            final index = entry.key;
            final item = entry.value;
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: GestureDetector(
                onTap: () => onToggleItem?.call(index),
                child: Row(
                  children: [
                    Icon(
                      item.isCompleted ? Icons.check_box : Icons.check_box_outline_blank,
                      size: 22,
                      color: item.isCompleted ? color : AppColors.textSecondary,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        item.text,
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 15,
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
        ],
        if (fiche.content.isNotEmpty) ...[
          const SizedBox(height: 16),
          const Divider(color: AppColors.border),
          const SizedBox(height: 16),
          SelectableText(fiche.content, style: AppTextStyles.noteText),
        ],
      ],
    );
  }

  Widget _buildEventContent(Color color) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (fiche.eventDateTime != null || fiche.eventLocation != null) ...[
          Wrap(
            spacing: 12,
            runSpacing: 10,
            children: [
              if (fiche.eventDateTime != null)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.schedule, size: 20, color: color),
                      const SizedBox(width: 10),
                      Text(
                        fiche.eventDateTime!,
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: color,
                        ),
                      ),
                    ],
                  ),
                ),
              if (fiche.eventLocation != null)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.location_on, size: 20, color: color),
                      const SizedBox(width: 10),
                      Text(
                        fiche.eventLocation!,
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: color,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: 20),
        ],
        if (fiche.content.isNotEmpty)
          SelectableText(fiche.content, style: AppTextStyles.noteText),
      ],
    );
  }

  Widget _buildContactContent(Color color) {
    final displayName = fiche.contactFullName ?? fiche.title;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Avatar et nom
        Row(
          children: [
            Container(
              width: 60,
              height: 60,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.2),
                shape: BoxShape.circle,
              ),
              child: Center(
                child: Text(
                  _getInitials(displayName),
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: color,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (fiche.contactFirstName != null)
                    Text(
                      fiche.contactFirstName!,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  if (fiche.contactLastName != null)
                    Text(
                      fiche.contactLastName!,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 16,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  if (fiche.contactFirstName == null && fiche.contactLastName == null)
                    Text(
                      fiche.title,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: AppColors.textPrimary,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        // Infos de contact extraites
        if (fiche.contactPhone != null)
          _buildContactRow(Icons.phone, 'Téléphone', fiche.contactPhone!, color),
        if (fiche.contactEmail != null)
          _buildContactRow(Icons.email, 'Email', fiche.contactEmail!, color),
        if (fiche.contactBuildingCode != null)
          _buildContactRow(Icons.vpn_key, 'Code immeuble', fiche.contactBuildingCode!, color),
      ],
    );
  }

  Widget _buildContactRow(IconData icon, String label, String value, Color color) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 10,
                    color: AppColors.textSecondary,
                  ),
                ),
                SelectableText(
                  value,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 15,
                    color: AppColors.textPrimary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMemoContent() {
    return SelectableText(
      fiche.content.isEmpty ? 'Aucun contenu' : fiche.content,
      style: AppTextStyles.noteText,
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

  String _getInitials(String name) {
    final parts = name.split(' ');
    if (parts.length >= 2) {
      return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    }
    return name.isNotEmpty ? name[0].toUpperCase() : '?';
  }
}

/// Sheet de détail d'une note
class _NoteDetailSheet extends StatelessWidget {
  final VoiceNote note;
  final ScrollController scrollController;
  final VoidCallback onPlay;
  final VoidCallback onStop;
  final bool isPlaying;

  const _NoteDetailSheet({
    required this.note,
    required this.scrollController,
    required this.onPlay,
    required this.onStop,
    required this.isPlaying,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Column(
        children: [
          // Poignée de drag
          Container(
            margin: const EdgeInsets.only(top: 12),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: AppColors.border,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          // En-tête
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      note.formattedDate,
                      style: AppTextStyles.metadata,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      note.formattedDuration,
                      style: AppTextStyles.metadata,
                    ),
                  ],
                ),
                // Bouton play
                IconButton(
                  onPressed: isPlaying ? onStop : onPlay,
                  icon: Icon(
                    isPlaying ? Icons.stop : Icons.play_arrow,
                    color: AppColors.accent,
                  ),
                  iconSize: 32,
                ),
              ],
            ),
          ),
          const Divider(color: AppColors.border),
          // Contenu scrollable
          Expanded(
            child: SingleChildScrollView(
              controller: scrollController,
              padding: const EdgeInsets.all(16),
              child: SelectableText(
                note.text.isEmpty
                    ? (note.isTranscribing
                        ? 'Transcription en cours...'
                        : 'Note vide')
                    : note.text,
                style: AppTextStyles.noteText,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Bottom sheet pour choisir un appareil BLE parmi ceux découverts
class _DevicePickerSheet extends StatelessWidget {
  final AudioService audioService;

  const _DevicePickerSheet({required this.audioService});

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxHeight: 400),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Poignée de drag
          Container(
            margin: const EdgeInsets.only(top: 12),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: AppColors.border,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          // Titre
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                const Icon(Icons.bluetooth_searching,
                    color: AppColors.accent, size: 24),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text(
                    'Montres disponibles',
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ),
                // Indicateur de scan
                StreamBuilder<BleConnectionState>(
                  stream: audioService.bleConnectionStateStream,
                  initialData: audioService.bleConnectionState,
                  builder: (context, snapshot) {
                    final isScanning =
                        snapshot.data == BleConnectionState.scanning;
                    if (!isScanning) return const SizedBox.shrink();
                    return const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor:
                            AlwaysStoppedAnimation<Color>(AppColors.accent),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
          const Divider(color: AppColors.border, height: 1),
          // Liste des appareils
          Flexible(
            child: StreamBuilder<List<ScanResult>>(
              stream: audioService.discoveredDevicesStream,
              initialData: const [],
              builder: (context, snapshot) {
                final devices = snapshot.data ?? [];

                if (devices.isEmpty) {
                  return _buildScanningState();
                }

                return ListView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: devices.length,
                  itemBuilder: (context, index) {
                    final result = devices[index];
                    return _buildDeviceTile(context, result);
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildScanningState() {
    return const Padding(
      padding: EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.bluetooth_searching,
              size: 48, color: AppColors.textSecondary),
          SizedBox(height: 16),
          Text(
            'Recherche en cours...',
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 14,
              color: AppColors.textSecondary,
            ),
          ),
          SizedBox(height: 8),
          Text(
            'Assurez-vous que la montre est allumée',
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 12,
              color: AppColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDeviceTile(BuildContext context, ScanResult result) {
    // Récupérer le vrai nom BLE de la montre
    final advName = result.advertisementData.advName;
    final platformName = result.device.platformName;
    final displayName = advName.isNotEmpty ? advName : platformName;

    return ListTile(
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: AppColors.accent.withValues(alpha: 0.15),
          shape: BoxShape.circle,
        ),
        child: const Icon(Icons.watch, color: AppColors.accent, size: 22),
      ),
      title: Text(
        displayName,
        style: const TextStyle(
          fontFamily: 'monospace',
          fontSize: 14,
          fontWeight: FontWeight.bold,
          color: AppColors.textPrimary,
        ),
      ),
      trailing: const Icon(Icons.chevron_right, color: AppColors.textSecondary),
      onTap: () {
        Navigator.of(context).pop();
        audioService.connectToBleDevice(result.device);
      },
    );
  }
}
