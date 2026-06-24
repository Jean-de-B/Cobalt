import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:android_intent_plus/android_intent.dart';
import 'package:android_intent_plus/flag.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import '../constants/app_constants.dart';
import '../models/incoming_message.dart';
import '../models/voice_note.dart';
import '../models/ai_action.dart';
import '../services/audio_service.dart';
import '../services/database_service.dart';
import '../services/local_action_dispatcher.dart';
import '../services/overlay_permission_service.dart';
import '../services/validated_contacts_service.dart';
import '../services/contact_lookup_service.dart';
import 'package:flutter_contacts/flutter_contacts.dart' show Contact;
import '../services/incoming_history_service.dart';
import '../services/audio_feedback_service.dart';
import '../services/assistant_launch_service.dart';
import '../services/cobalt_overlay_service.dart';
import '../services/foreground_service.dart';
import '../services/message_aggregator_service.dart';
import '../services/local_sms_service.dart';
import 'settings_screen.dart';
import '../services/settings_service.dart';
import '../services/debug_console_service.dart';
import '../services/transcription_service.dart';
import '../widgets/ble_status_indicator.dart';
import '../widgets/memo_card.dart';

/// =============================================================================
/// home_screen.dart
/// =============================================================================
/// Ecran principal de l'application Cobalt Task.
///
/// Interface creme douce avec AppBar frosted glass.
/// =============================================================================

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final AudioService _audioService = AudioService();
  final DatabaseService _databaseService = DatabaseService();
  final ValidatedContactsService _validatedContactsService = ValidatedContactsService();
  final ContactLookupService _contactLookupService = ContactLookupService();
  final LocalActionDispatcher _dispatcher = LocalActionDispatcher();
  final AudioFeedbackService _audioFeedback = AudioFeedbackService();
  final AssistantLaunchService _assistantLaunchService = AssistantLaunchService();
  final CobaltOverlayService _overlayService = CobaltOverlayService();
  final MessageAggregatorService _messageAggregator = MessageAggregatorService();
  StreamSubscription<PendingValidation>? _pendingValidationSub;
  StreamSubscription<String>? _assistLaunchSub;
  StreamSubscription<bool>? _micButtonSub;
  StreamSubscription<bool>? _assistRecordSub;
  StreamSubscription<void>? _overlayDismissSub;
  StreamSubscription<int>? _batteryLevelSub;
  bool _isShowingValidationDialog = false;
  bool _lowBatteryNotified = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _databaseService.refreshStream();
    _checkOverlayPermission();
    // Vérifier accessibilité et permission notifications après le premier frame
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkNotificationListenerPermission();
    });

    // Écouter les nouvelles validations en attente (affichage immédiat du dialog)
    _pendingValidationSub = _validatedContactsService.pendingAddedStream.listen((pending) {
      if (mounted && !_isShowingValidationDialog) {
        _showContactValidationDialog(pending);
      }
    });

    // Écouter les lancements ASSIST (assistant vocal par défaut)
    _assistLaunchSub = _assistantLaunchService.assistLaunchStream.listen((source) {
      // ignore: avoid_print
      print('[HomeScreen] ASSIST launch détecté: $source');
      _startAssistRecording();
    });

    // Vérifier un lancement ASSIST en attente (cold start)
    _assistantLaunchService.checkPendingAssistLaunch();

    // Bouton micro de la notification → toggle enregistrement
    _micButtonSub = CobaltForegroundService().micButtonStream.listen((_) {
      // ignore: avoid_print
      print('[HomeScreen] Bouton micro notification pressé');
      _handleNotificationMicPress();
    });

    // ASSIST broadcast (Power long-press, warm start) → overlay + enregistrement
    _assistRecordSub = CobaltForegroundService().assistRecordStream.listen((_) {
      // ignore: avoid_print
      print('[HomeScreen] ASSIST record broadcast recu');
      _startAssistRecording();
    });

    // Reagir aux dismiss de l'overlay vocal
    _overlayDismissSub = _overlayService.overlayDismissStream.listen((_) {
      // ignore: avoid_print
      print('[HomeScreen] Overlay dismiss');
    });

    // Alerte batterie faible (<= 10 %)
    _batteryLevelSub = _audioService.batteryLevelStream.listen((level) {
      if (level > 0 && level <= 10 && !_lowBatteryNotified) {
        _lowBatteryNotified = true;
        CobaltForegroundService().showBatteryAlert(level);
        final msg = SettingsService().language == 'en'
            ? 'Watch battery low: $level percent. Please charge.'
            : 'Batterie de la montre faible : $level pourcent. Pensez à recharger.';
        _audioFeedback.speak(msg);
      } else if (level > 20) {
        _lowBatteryNotified = false;
      }
    });
  }

  void _showBluetoothRequiredDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Row(
          children: [
            Icon(Icons.bluetooth_disabled, color: Colors.red),
            SizedBox(width: 8),
            Text('Bluetooth requis', style: AppTextStyles.heading),
          ],
        ),
        content: const Text(
          'Cobalt Task nécessite le Bluetooth pour communiquer avec la montre.\n\n'
          'Veuillez activer le Bluetooth pour continuer.',
          style: AppTextStyles.cardBody,
        ),
        actions: [
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.bleConnected,
              foregroundColor: Colors.white,
            ),
            icon: const Icon(Icons.bluetooth),
            label: const Text('Activer'),
            onPressed: () async {
              Navigator.of(ctx).pop();
              await FlutterBluePlus.turnOn();
            },
          ),
        ],
      ),
    );
  }

  /// Verifie la permission de superposition au demarrage
  /// Necessaire pour que les actions (alarmes, appels, etc.) fonctionnent en arriere-plan
  Future<void> _checkOverlayPermission() async {
    // Attendre que le widget soit construit
    await Future.delayed(const Duration(seconds: 2));
    if (!mounted) return;

    final hasPermission = await OverlayPermissionService.canDrawOverlays();
    if (!hasPermission) {
      _showOverlayPermissionDialog();
    }

    // Vérifier la permission NotificationListener (pour le routage intelligent)
    if (!mounted) return;
    final hasNotifListener = await IncomingHistoryService.isEnabled();
    if (!hasNotifListener && mounted) {
      // Attendre un peu pour ne pas empiler les dialogs
      await Future.delayed(const Duration(seconds: 1));
      if (mounted) _showNotificationListenerDialog();
    }

    // Vérifier la configuration assistant vocal par défaut
    if (!mounted) return;
    await Future.delayed(const Duration(seconds: 1));
    if (mounted) _checkAssistantSetup();
  }

  /// Vérifie si Cobalt est configuré comme assistant par défaut.
  /// Affiche un guide de configuration si ce n'est pas le cas.
  Future<void> _checkAssistantSetup() async {
    try {
      final status = await _assistantLaunchService.getAssistantStatus();
      final isRoleHeld = status['isRoleAssistantHeld'] == true;
      final isCobaltVoice = status['isCobaltVoiceService'] == true;
      final isSamsung = status['isSamsung'] == true;

      // ignore: avoid_print
      print('[HomeScreen] Assistant status: role=$isRoleHeld, voiceService=$isCobaltVoice, samsung=$isSamsung');
      // ignore: avoid_print
      print('[HomeScreen] Assistant full diag: $status');

      // Dialog de configuration assistant désactivé (trop intrusif au démarrage)
    } catch (e) {
      // ignore: avoid_print
      print('[HomeScreen] Erreur check assistant: $e');
    }
  }


  void _showOverlayPermissionDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Permission requise'),
        content: const Text(
          'Pour que les actions vocales (alarmes, appels, navigation...) '
          'fonctionnent quand l\'application est en arriere-plan, '
          'Cobalt Task a besoin de la permission "Superposition d\'apps".',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Plus tard', style: TextStyle(color: AppColors.textSecondary)),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              OverlayPermissionService.requestPermission();
            },
            child: const Text('Autoriser'),
          ),
        ],
      ),
    );
  }

  void _showNotificationListenerDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Routage intelligent'),
        content: const Text(
          'Pour repondre automatiquement sur la bonne app '
          '(WhatsApp, Telegram, Signal...), Cobalt Task a besoin '
          'd\'acceder aux notifications.\n\n'
          'Activez "Cobalt Task" dans la liste.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Plus tard', style: TextStyle(color: AppColors.textSecondary)),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              IncomingHistoryService.requestPermission();
            },
            child: const Text('Activer'),
          ),
        ],
      ),
    );
  }

  /// Demarre ou arrete l'enregistrement via ASSIST (Power long-press).
  /// Si deja en enregistrement → toggle stop (2eme appui Power).
  /// Sinon → overlay + enregistrement.
  Future<void> _startAssistRecording() async {
    if (_audioService.isRecording) {
      // 2eme ASSIST pendant enregistrement → toggle stop
      // ignore: avoid_print
      print('[HomeScreen] ASSIST: deja en enregistrement, toggle stop');
      if (_overlayService.isOverlayActive) {
        await _overlayService.hideOverlay();
      }
      await _audioService.stopRecording();
      await CobaltForegroundService().updateNotification(
        title: 'Cobalt Task',
        text: '',
        isRecording: false,
      );
      return;
    }

    // ASSIST vient de l'exterieur (overlay deja visible depuis AssistantActivity).
    // showOverlay() met a jour le callback dismiss et demarre l'enregistrement + amplitude.
    // ignore: avoid_print
    print('[HomeScreen] ASSIST: activation overlay + enregistrement');
    await _overlayService.showOverlay();
  }

  /// Gere l'appui sur le bouton micro de la notification.
  /// Toggle : start si pas en cours, stop sinon.
  /// Utilise l'overlay si l'app est en arriere-plan.
  Future<void> _handleNotificationMicPress() async {
    final fg = CobaltForegroundService();
    if (_audioService.isRecording) {
      // Arreter : si overlay actif, le dismiss (qui arrete l'enregistrement)
      if (_overlayService.isOverlayActive) {
        await _overlayService.hideOverlay();
      }
      await _audioService.stopRecording();
      // ignore: avoid_print
      print('[HomeScreen] Notification mic: Enregistrement arrete');
      await fg.updateNotification(
        title: 'Cobalt Task',
        text: '',
        isRecording: false,
      );
    } else {
      // Demarrer avec overlay (l'utilisateur est dans les notifications = background)
      // ignore: avoid_print
      print('[HomeScreen] Notification mic: overlay + enregistrement');
      await _overlayService.showOverlay();
    }
  }

  @override
  void dispose() {
    _pendingValidationSub?.cancel();
    _assistLaunchSub?.cancel();
    _micButtonSub?.cancel();
    _assistRecordSub?.cancel();
    _overlayDismissSub?.cancel();
    _batteryLevelSub?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // ignore: avoid_print
      print('APP: Retour au premier plan - retry des transcriptions en attente');
      _audioService.retryPendingTranscriptions();
      _audioService.triggerBleReconnect();
      _databaseService.refreshStream();
      // Log overlay permission status on resume (user may have just granted it)
      OverlayPermissionService.canDrawOverlays().then((granted) {
        // ignore: avoid_print
        print('APP: Permission overlay: ${granted ? "OK" : "NON ACCORDEE"}');
      });
      // Traiter les validations de contacts en attente
      _processPendingValidations();
    }
  }

  Future<void> _checkNotificationListenerPermission() async {
    if (!mounted) return;
    final enabled = await IncomingHistoryService.isEnabled();
    if (!mounted || enabled) return;

    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(SnackBar(
      content: const Text('Activez l\'écoute des notifications pour voir vos messages entrants.'),
      backgroundColor: const Color(0xFF5D4037),
      duration: const Duration(seconds: 8),
      action: SnackBarAction(
        label: 'ACTIVER',
        textColor: AppColors.accent,
        onPressed: () => IncomingHistoryService.requestPermission(),
      ),
    ));
  }

  /// Traite les validations de contacts en attente (fuzzy match a confirmer)
  Future<void> _processPendingValidations() async {
    if (_isShowingValidationDialog) return;

    final pendings = await _validatedContactsService.getPendingValidations();
    if (pendings.isEmpty) return;

    // ignore: avoid_print
    print('APP: ${pendings.length} validation(s) de contacts en attente');

    for (final pending in pendings) {
      if (!mounted || _isShowingValidationDialog) return;
      await _showContactValidationDialog(pending);
    }
  }

  /// Affiche un dialog pour confirmer/corriger un mapping prenom → contact
  /// Montre les 3 meilleurs contacts correspondants.
  /// Après confirmation, envoie automatiquement le message en attente.
  Future<void> _showContactValidationDialog(PendingValidation pending) async {
    if (_isShowingValidationDialog) return;
    _isShowingValidationDialog = true;

    // Chercher les 3 meilleurs contacts
    await _contactLookupService.initialize();
    if (!mounted) {
      _isShowingValidationDialog = false;
      return;
    }

    final topContacts = await _contactLookupService.findTopContacts(pending.spokenName);

    // S'assurer que la suggestion du pending est dans la liste (en première position)
    final hasOriginalSuggestion = topContacts.any(
      (c) => c.phoneNumber == pending.phoneNumber,
    );
    if (!hasOriginalSuggestion) {
      topContacts.insert(
        0,
        ContactLookupResult.found(
          displayName: pending.suggestedName,
          phoneNumber: pending.phoneNumber,
          confidence: 1.0,
        ),
      );
      if (topContacts.length > 3) topContacts.removeLast();
    }

    if (!mounted) {
      _isShowingValidationDialog = false;
      return;
    }

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        int selectedIndex = 0;
        return StatefulBuilder(
          builder: (context, setState) => AlertDialog(
            backgroundColor: AppColors.surface,
            title: const Text('Confirmez le contact', style: AppTextStyles.heading),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                RichText(
                  text: TextSpan(
                    style: AppTextStyles.noteText.copyWith(color: AppColors.textPrimary),
                    children: [
                      const TextSpan(text: 'Vous avez dit '),
                      TextSpan(
                        text: '"${pending.spokenName}"',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                // Liste des contacts candidats
                for (int i = 0; i < topContacts.length; i++) ...[
                  if (i > 0) const SizedBox(height: 8),
                  _ContactOption(
                    name: topContacts[i].displayName ?? '',
                    phone: topContacts[i].phoneNumber ?? '',
                    selected: i == selectedIndex,
                    onTap: () => setState(() => selectedIndex = i),
                  ),
                ],
                const SizedBox(height: 8),
                // Option "Choisir dans la liste complète"
                InkWell(
                  onTap: () async {
                    final contacts = _contactLookupService.allContacts;
                    if (contacts.isEmpty) return;
                    final picked = await showModalBottomSheet<int>(
                      context: context,
                      backgroundColor: AppColors.surface,
                      isScrollControlled: true,
                      builder: (ctx) => _FullContactPicker(contacts: contacts),
                    );
                    if (picked != null) {
                      final c = contacts[picked];
                      final phone = c.phones.first.number;
                      topContacts.add(ContactLookupResult(
                        found: true,
                        displayName: c.displayName,
                        phoneNumber: phone,
                        confidence: 1.0,
                      ));
                      setState(() => selectedIndex = topContacts.length - 1);
                    }
                  },
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppColors.border),
                    ),
                    child: const Row(
                      children: [
                        Icon(Icons.contacts, size: 20, color: AppColors.textSecondary),
                        SizedBox(width: 12),
                        Expanded(
                          child: Text('Choisir dans la liste complète',
                              style: TextStyle(color: AppColors.textSecondary, fontSize: 14),
                              overflow: TextOverflow.ellipsis),
                        ),
                        SizedBox(width: 4),
                        Icon(Icons.chevron_right, size: 18, color: AppColors.textSecondary),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () {
                  // Ignorer : supprimer UNIQUEMENT ce pending
                  _validatedContactsService.clearPendingValidation(pending.id);
                  Navigator.pop(context);
                },
                child: const Text('Ignorer', style: TextStyle(color: AppColors.textSecondary)),
              ),
              TextButton(
                onPressed: () async {
                  final selected = topContacts[selectedIndex];
                  final selectedName = selected.displayName ?? pending.suggestedName;
                  final selectedPhone = selected.phoneNumber ?? pending.phoneNumber;

                  // 1. Valider le mapping (ne supprime que CE pending)
                  await _validatedContactsService.validate(
                    pending.spokenName,
                    selectedName,
                    selectedPhone,
                  );

                  if (!context.mounted) return;
                  Navigator.pop(context);

                  // 2. Envoyer automatiquement le message en attente
                  if (pending.pendingMessage != null && pending.pendingMessage!.isNotEmpty) {
                    final action = MessageAction(
                      reasoning: 'Envoi automatique après validation du contact',
                      recipient: pending.spokenName,
                      message: pending.pendingMessage!,
                    );
                    final result = await _dispatcher.dispatch(action);
                    // ignore: avoid_print
                    print('APP: Auto-envoi après validation: ${result.message}');

                    // Feedback TTS
                    if (result.success) {
                      final app = result.metadata?['app'] as String? ?? 'sms';
                      final appLabel = switch (app) {
                        'whatsapp' => 'WhatsApp',
                        'telegram' => 'Telegram',
                        'signal' => 'Signal',
                        'messenger' => 'Messenger',
                        _ => 'SMS',
                      };
                      await _audioFeedback.speak('$appLabel envoyé à $selectedName');
                    }
                  }
                },
                child: const Text('Confirmer'),
              ),
            ],
          ),
        );
      },
    );

    _isShowingValidationDialog = false;

    // Vérifier s'il reste d'autres pendings à traiter
    if (mounted) {
      _processPendingValidations();
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<void>(
      stream: SettingsService().onChanged,
      builder: (context, _) {
        final showDebug = SettingsService().debugConsole;
        return Scaffold(
          backgroundColor: AppColors.background,
          extendBodyBehindAppBar: true,
          appBar: _buildAppBar(),
          body: showDebug
              ? Column(
                  children: [
                    Expanded(child: _buildBody()),
                    const _DebugConsolePanel(),
                  ],
                )
              : _buildBody(),
          floatingActionButton: Padding(
            padding: EdgeInsets.only(bottom: showDebug ? 180 : 0),
            child: _buildPTTButton(),
          ),
          floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
        );
      },
    );
  }

  PreferredSizeWidget _buildAppBar() {
    return PreferredSize(
      preferredSize: const Size.fromHeight(kToolbarHeight),
      child: ClipRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: AppBar(
            backgroundColor: AppColors.background.withValues(alpha: 0.85),
            elevation: 0,
            scrolledUnderElevation: 0,
            centerTitle: false,
            title: GestureDetector(
              onTap: () {
                final bleState = _audioService.bleConnectionState;
                final isPaired = _audioService.selectedDeviceId != null;
                final isConnected = bleState == BleConnectionState.connected ||
                    bleState == BleConnectionState.syncing;
                if (isPaired && !isConnected) {
                  _scanAndPickDevice();
                } else {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const SettingsScreen()),
                  );
                }
              },
              child: const Text('Cobalt Task', style: AppTextStyles.heading),
            ),
            actions: [
              _buildTransferIndicator(),
              _buildMessagesIndicator(),
              _buildMusicIndicator(),
              _buildGoogleIndicator(),
              _buildBatteryIndicator(),
              BleStatusIndicator(
                audioService: _audioService,
                onScanRequested: _scanAndPickDevice,
              ),
              const SizedBox(width: 8),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMessagesIndicator() {
    return StreamBuilder<int>(
      stream: _messageAggregator.unreadStream,
      initialData: _messageAggregator.unreadCount,
      builder: (context, snapshot) {
        final unread = snapshot.data ?? 0;

        return Tooltip(
          message: 'Messages entrants',
          child: InkWell(
            onTap: () => _showMessagesSheet(context),
            borderRadius: BorderRadius.circular(20),
            child: Padding(
              padding: const EdgeInsets.all(8.0),
              child: Badge(
                isLabelVisible: unread > 0,
                label: Text('$unread', style: const TextStyle(fontSize: 9, color: Colors.white)),
                child: Icon(
                  Icons.chat_bubble_outline,
                  size: 20,
                  color: unread > 0 ? AppColors.accent : AppColors.textSecondary,
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  void _showMessagesSheet(BuildContext context) {
    _messageAggregator.markAllRead();
    final draggableController = DraggableScrollableController();

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (sheetContext) => GestureDetector(
        onTap: () => Navigator.pop(sheetContext),
        behavior: HitTestBehavior.opaque,
        child: GestureDetector(
          onTap: () {},
          child: DraggableScrollableSheet(
            controller: draggableController,
            initialChildSize: 0.45,
            minChildSize: 0.25,
            maxChildSize: 0.92,
            builder: (context, scrollController) => _MessagesSheetContent(
              scrollController: scrollController,
              aggregator: _messageAggregator,
              draggableController: draggableController,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMusicIndicator() {
    return StreamBuilder<void>(
      stream: SettingsService().onChanged,
      builder: (context, _) {
        final service = SettingsService().musicService;

        if (service == 'spotify') {
          return StreamBuilder<bool>(
            stream: _audioService.spotifyConnectionStream,
            initialData: _audioService.isSpotifyConnected,
            builder: (context, snapshot) {
              final isConnected = snapshot.data ?? false;
              return _musicIconTile(
                context: context,
                color: isConnected ? const Color(0xFF1DB954) : AppColors.textSecondary,
                tooltip: isConnected ? 'Spotify connecté' : 'Connecter Spotify',
              );
            },
          );
        }

        return _musicIconTile(
          context: context,
          color: _musicServiceColor(service),
          tooltip: SettingsService.musicServices[service] ?? service,
        );
      },
    );
  }

  Widget _musicIconTile({
    required BuildContext context,
    required Color color,
    required String tooltip,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: () => _showMusicMenu(context),
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.all(8.0),
          child: Icon(Icons.music_note, color: color, size: 22),
        ),
      ),
    );
  }

  void _showMusicMenu(BuildContext context) {
    final service = SettingsService().musicService;

    if (service == 'spotify') {
      final isConnected = _audioService.isSpotifyConnected;
      showModalBottomSheet(
        context: context,
        backgroundColor: AppColors.surface,
        builder: (sheetContext) => SafeArea(
          child: isConnected
              ? _SpotifyPlayerSheet(audioService: _audioService)
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Padding(
                      padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
                      child: Text(
                        'Connectez Spotify pour controler la musique par la voix',
                        style: AppTextStyles.metadata,
                        textAlign: TextAlign.center,
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                      child: SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          icon: const Icon(Icons.login, size: 18),
                          label: const Text('Connecter Spotify'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF1DB954),
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            padding: const EdgeInsets.symmetric(vertical: 12),
                          ),
                          onPressed: () {
                            Navigator.pop(sheetContext);
                            if (SettingsService().spotifyClientId.isEmpty) {
                              Future.delayed(const Duration(milliseconds: 300), () {
                                if (context.mounted) showSpotifySetup(context);
                              });
                            } else {
                              Future.delayed(const Duration(milliseconds: 500), () {
                                _audioService.connectSpotify();
                              });
                            }
                          },
                        ),
                      ),
                    ),
                  ],
                ),
        ),
      );
      return;
    }

    // Deezer / YouTube Music — fiche avec contrôles MediaKey
    final label = SettingsService.musicServices[service] ?? service;
    final color = _musicServiceColor(service);
    final package = switch (service) {
      'deezer' => 'deezer.android.app',
      'youtube_music' => 'com.google.android.apps.youtube.music',
      _ => '',
    };

    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      builder: (sheetContext) => SafeArea(
        child: _MediaKeySheet(
          label: label,
          color: color,
          package: package,
          audioService: _audioService,
        ),
      ),
    );
  }

  static Color _musicServiceColor(String service) => switch (service) {
        'spotify' => const Color(0xFF1DB954),
        'deezer' => const Color(0xFF9B59B6),
        'youtube_music' => const Color(0xFFFF0000),
        _ => AppColors.textSecondary,
      };

  Widget _buildGoogleIndicator() {
    return Tooltip(
      message: 'Historique des actions',
      child: InkWell(
        onTap: () => _showHistorySheet(context),
        borderRadius: BorderRadius.circular(20),
        child: const Padding(
          padding: EdgeInsets.all(8.0),
          child: Icon(Icons.list_alt, color: AppColors.textSecondary, size: 22),
        ),
      ),
    );
  }

  void _showHistorySheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) => GestureDetector(
        onTap: () => Navigator.pop(context),
        behavior: HitTestBehavior.opaque,
        child: GestureDetector(
          onTap: () {},
          child: DraggableScrollableSheet(
            initialChildSize: 0.45,
            minChildSize: 0.25,
            maxChildSize: 0.92,
            expand: false,
            builder: (context, scrollController) => _HistorySheet(
              databaseService: _databaseService,
              scrollController: scrollController,
            ),
          ),
        ),
      ),
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
                  valueColor: const AlwaysStoppedAnimation<Color>(AppColors.accent),
                ),
                const SizedBox(height: 2),
                Text(
                  '${(progress * 100).toInt()}%',
                  style: AppTextStyles.technicalData.copyWith(fontSize: 10),
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
      builder: (context, batterySnapshot) {
        final rawLevel = batterySnapshot.data ?? -1;
        if (rawLevel < 0) {
          return const SizedBox.shrink();
        }
        // Sécurité : clamp 0-100 même si le stream envoie une valeur aberrante
        final level = rawLevel.clamp(0, 100);

        return StreamBuilder<bool>(
          stream: _audioService.chargingStream,
          initialData: _audioService.isCharging,
          builder: (context, chargingSnapshot) {
            final charging = chargingSnapshot.data ?? false;

            Color color;
            if (charging) {
              color = Colors.green;
            } else if (level <= 10) {
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
                    charging ? Icons.battery_charging_full : _getBatteryIcon(level),
                    size: 14,
                    color: color,
                  ),
                  const SizedBox(width: 2),
                  Text(
                    '$level%',
                    style: AppTextStyles.technicalData.copyWith(
                      fontSize: 10,
                      color: color,
                    ),
                  ),
                ],
              ),
            );
          },
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

  Widget _buildPTTButton() {
    return StreamBuilder<bool>(
      stream: _audioService.recordingStateStream,
      initialData: _audioService.isRecording,
      builder: (context, snapshot) {
        final isRecording = snapshot.data ?? false;

        return GestureDetector(
          // Déclenchement instantané au toucher (pas de délai long press)
          onTapDown: (_) {
            if (!isRecording) _startPTTRecording();
          },
          onTapUp: (_) {
            if (isRecording) _stopPTTRecording();
          },
          onTapCancel: () {
            if (isRecording) _stopPTTRecording();
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: isRecording ? 80 : 64,
            height: isRecording ? 80 : 64,
            decoration: BoxDecoration(
              color: isRecording ? Colors.red.shade700 : Colors.red,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: Colors.red.withValues(alpha: isRecording ? 0.4 : 0.25),
                  blurRadius: isRecording ? 24 : 12,
                  spreadRadius: isRecording ? 4 : 0,
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
          content: Text('Impossible d\'acceder au microphone'),
          backgroundColor: Colors.red,
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _stopPTTRecording() async {
    await _audioService.stopRecording();
  }

  bool _isTrackedAction(VoiceNote note) {
    // Masquer les erreurs et les notes vides
    if (note.errorMessage != null) return false;

    // Conserver les notes en cours de traitement (feedback UX)
    if (note.isProcessing) return true;

    final json = note.actionJson;
    if (json == null || json.isEmpty) {
      // Masquer si aucun contenu textuel
      return note.text.isNotEmpty || note.summary.isNotEmpty;
    }

    try {
      final map = jsonDecode(json) as Map<String, dynamic>;
      final intent = map['intent'] as String? ?? 'none';
      // Actions non persistantes (directes ou requêtes ponctuelles)
      const hiddenIntents = {
        'alarm',
        'timer',
        'system_control',
        'call',
        'navigation',
        'media',
        'app_launch',
        'query_time',
        'query_battery',
      };
      return !hiddenIntents.contains(intent);
    } catch (_) {
      return true;
    }
  }

  Widget _buildBody() {
    return StreamBuilder<List<VoiceNote>>(
      stream: _databaseService.notesStream,
      initialData: _databaseService.lastNotes,
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return _buildLoadingState();
        }

        final allNotes = snapshot.data!;
        // Afficher uniquement les tâches tracées (actions persistantes dans des services externes)
        // Les actions directes (alarme, timer, média, appel, navigation, appLaunch, contrôle système)
        // sont auto-validées et n'ont pas besoin d'être listées.
        final notes = allNotes.where(_isTrackedAction).toList();
        if (notes.isEmpty) {
          return _buildEmptyState();
        }

        return _buildMemosList(notes);
      },
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
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.mic_none,
              size: 64,
              color: AppColors.textTertiary,
            ),
            const SizedBox(height: 24),
            const Text('Aucun memo', style: AppTextStyles.heading),
            const SizedBox(height: 8),
            const Text(
              'Enregistrez un memo avec le bracelet\nou le bouton micro',
              style: AppTextStyles.metadata,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),
            StreamBuilder<BleConnectionState>(
              stream: _audioService.bleConnectionStateStream,
              initialData: _audioService.bleConnectionState,
              builder: (context, snapshot) {
                final state = snapshot.data ?? BleConnectionState.disconnected;
                final isConnected = state == BleConnectionState.connected;

                if (isConnected) {
                  return const SizedBox.shrink();
                }

                return OutlinedButton.icon(
                  onPressed: _scanAndPickDevice,
                  icon: const Icon(Icons.watch, size: 18),
                  label: Text(_audioService.selectedDeviceId != null
                      ? 'Reconnecter la montre'
                      : 'Appairer une montre'),
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

  Widget _buildMemosList(List<VoiceNote> notes) {
    return StreamBuilder<int?>(
      stream: _audioService.playbackStateStream,
      initialData: null,
      builder: (context, playbackSnapshot) {
        return ListView.builder(
          padding: EdgeInsets.only(
            top: MediaQuery.of(context).padding.top + kToolbarHeight + 8,
            bottom: 100,
          ),
          itemCount: notes.length,
          itemBuilder: (context, index) {
            final note = notes[index];
            return MemoCard(
              note: note,
              isPlaying: _audioService.isPlaying(note.id),
              onPlay: () => _playNote(note),
              onStop: () => _audioService.stopPlayback(),
              onDelete: () => _deleteNote(note),
            );
          },
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // DEVICE PICKER
  // ---------------------------------------------------------------------------

  Future<void> _scanAndPickDevice() async {
    final btState = FlutterBluePlus.adapterStateNow;
    if (btState != BluetoothAdapterState.on) {
      if (mounted) _showBluetoothRequiredDialog();
      return;
    }

    // Montre déjà appairée → relancer la reconnexion ciblée, pas de picker
    if (_audioService.selectedDeviceId != null) {
      _audioService.triggerBleReconnect();
      return;
    }

    // Aucune montre appairée → mode appairage (première liaison)
    _audioService.startBrowseScan();

    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      builder: (context) => _DevicePickerSheet(audioService: _audioService),
    ).whenComplete(() {
      _audioService.stopBrowseScan();
    });
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
            content: Text('Erreur de lecture: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _deleteNote(VoiceNote note) async {
    await _audioService.deleteAudioFile(note.audioPath);
    if (note.id != null) {
      await _databaseService.deleteNote(note.id!);
    }
  }
}

/// =============================================================================
/// Device Picker Bottom Sheet
/// =============================================================================

class _DevicePickerSheet extends StatefulWidget {
  final AudioService audioService;

  const _DevicePickerSheet({required this.audioService});

  @override
  State<_DevicePickerSheet> createState() => _DevicePickerSheetState();
}

class _DevicePickerSheetState extends State<_DevicePickerSheet> {
  bool _timedOut = false;
  late final Timer _timeoutTimer;

  @override
  void initState() {
    super.initState();
    // Après 10s sans résultat, afficher un diagnostic
    _timeoutTimer = Timer(const Duration(seconds: 10), () {
      if (mounted) setState(() => _timedOut = true);
    });
  }

  @override
  void dispose() {
    _timeoutTimer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
            child: Row(
              children: [
                const Text('Appairer une montre', style: AppTextStyles.heading),
                const Spacer(),
                const SizedBox(
                  width: 16, height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(AppColors.accent),
                  ),
                ),
                const SizedBox(width: 8),
                Text('Scan', style: AppTextStyles.metadata.copyWith(
                  color: AppColors.accent, fontSize: 11)),
              ],
            ),
          ),
          const Divider(color: AppColors.border),
          StreamBuilder<List<ScanResult>>(
            stream: widget.audioService.discoveredDevicesStream,
            initialData: widget.audioService.discoveredDevices,
            builder: (context, snapshot) {
              final devices = snapshot.data ?? [];

              // Dès qu'on a des devices, annuler le timeout
              if (devices.isNotEmpty && _timedOut) {
                _timedOut = false;
              }

              if (devices.isEmpty) {
                return Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    children: [
                      if (!_timedOut) ...[
                        const SizedBox(
                          width: 20, height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation<Color>(AppColors.accent),
                          ),
                        ),
                        const SizedBox(height: 12),
                        const Text('Recherche en cours...', style: AppTextStyles.metadata),
                      ] else ...[
                        const Icon(Icons.bluetooth_searching, size: 36, color: AppColors.textSecondary),
                        const SizedBox(height: 12),
                        const Text(
                          'Aucun appareil trouvé',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'Vérifiez que :\n'
                          '• La montre est allumée et à proximité\n'
                          '• Le Bluetooth est activé\n'
                          '• La localisation est activée (requis par Android pour le BLE)\n'
                          '• Les permissions Bluetooth sont accordées',
                          style: TextStyle(fontSize: 12, color: AppColors.textSecondary, height: 1.5),
                        ),
                        const SizedBox(height: 12),
                        TextButton.icon(
                          onPressed: () {
                            setState(() => _timedOut = false);
                            _timeoutTimer.cancel();
                            widget.audioService.startBrowseScan();
                            // Nouveau timeout
                            Timer(const Duration(seconds: 10), () {
                              if (mounted) setState(() => _timedOut = true);
                            });
                          },
                          icon: const Icon(Icons.refresh, size: 18),
                          label: const Text('Relancer le scan'),
                          style: TextButton.styleFrom(foregroundColor: AppColors.accent),
                        ),
                      ],
                    ],
                  ),
                );
              }

              return ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.5,
                ),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: devices.length,
                  itemBuilder: (context, index) =>
                      _buildDeviceTile(context, devices[index]),
                ),
              );
            },
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  Widget _buildDeviceTile(BuildContext context, ScanResult result) {
    final advName = result.advertisementData.advName;
    final platformName = result.device.platformName;
    final displayName = advName.isNotEmpty ? advName : platformName;
    final isCobalt = displayName.toLowerCase().startsWith('cobalt');
    final isCurrentlyConnected = widget.audioService.connectedDeviceName == displayName &&
        widget.audioService.bleConnectionState == BleConnectionState.connected;
    final rssi = result.rssi;

    final signalIcon = rssi > -60
        ? Icons.signal_cellular_alt
        : rssi > -80
            ? Icons.signal_cellular_alt_2_bar
            : Icons.signal_cellular_alt_1_bar;
    final signalColor = rssi > -60
        ? AppColors.bleConnected
        : rssi > -80
            ? AppColors.bleConnecting
            : AppColors.textSecondary;

    return ListTile(
      leading: Icon(
        isCobalt ? Icons.watch : Icons.bluetooth,
        color: isCurrentlyConnected
            ? AppColors.bleConnected
            : isCobalt
                ? AppColors.accent
                : AppColors.textTertiary,
        size: isCobalt ? 24 : 20,
      ),
      title: Text(
        displayName,
        style: isCobalt
            ? AppTextStyles.noteText
            : AppTextStyles.metadata.copyWith(color: AppColors.textSecondary),
      ),
      subtitle: Text(
        isCurrentlyConnected ? 'Connecté' : '$rssi dBm',
        style: AppTextStyles.metadata,
      ),
      trailing: isCurrentlyConnected
          ? const Icon(Icons.check_circle, color: AppColors.bleConnected)
          : Icon(signalIcon, color: signalColor, size: 20),
      onTap: isCobalt ? () {
        Navigator.pop(context);
        widget.audioService.stopBrowseScan();
        widget.audioService.connectToBleDevice(result.device, deviceName: displayName);
      } : null,
    );
  }
}

/// =============================================================================
/// Contact Option Widget (pour le dialog de validation)
/// =============================================================================

class _ContactOption extends StatelessWidget {
  final String name;
  final String phone;
  final bool selected;
  final VoidCallback onTap;

  const _ContactOption({
    required this.name,
    required this.phone,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? AppColors.accent.withValues(alpha: 0.1) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? AppColors.accent : AppColors.border,
          ),
        ),
        child: Row(
          children: [
            Icon(
              Icons.person,
              size: 20,
              color: selected ? AppColors.accent : AppColors.textSecondary,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    style: AppTextStyles.noteText.copyWith(
                      fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                    ),
                  ),
                  Text(
                    phone,
                    style: AppTextStyles.metadata,
                  ),
                ],
              ),
            ),
            if (selected)
              const Icon(Icons.check_circle, size: 20, color: AppColors.accent),
          ],
        ),
      ),
    );
  }
}

/// =============================================================================
/// Full Contact Picker (bottom sheet with search)
/// =============================================================================

class _FullContactPicker extends StatefulWidget {
  final List<Contact> contacts;
  const _FullContactPicker({required this.contacts});

  @override
  State<_FullContactPicker> createState() => _FullContactPickerState();
}

class _FullContactPickerState extends State<_FullContactPicker> {
  String _search = '';

  List<Contact> get _filtered {
    if (_search.isEmpty) return widget.contacts;
    final lower = _search.toLowerCase();
    return widget.contacts
        .where((c) => c.displayName.toLowerCase().contains(lower))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      minChildSize: 0.4,
      maxChildSize: 0.92,
      expand: false,
      builder: (context, scrollController) => Column(
        children: [
          // Drag handle
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Container(
              width: 36, height: 4,
              decoration: BoxDecoration(
                color: AppColors.textTertiary.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          // Search bar
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: TextField(
              autofocus: true,
              style: AppTextStyles.noteText,
              decoration: InputDecoration(
                hintText: 'Rechercher un contact...',
                hintStyle: AppTextStyles.metadata,
                prefixIcon: const Icon(Icons.search, size: 20, color: AppColors.textSecondary),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: AppColors.border),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: AppColors.accent),
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                isDense: true,
              ),
              onChanged: (v) => setState(() => _search = v),
            ),
          ),
          const SizedBox(height: 4),
          // Contact list
          Expanded(
            child: ListView.builder(
              controller: scrollController,
              itemCount: _filtered.length,
              itemBuilder: (context, index) {
                final c = _filtered[index];
                final phone = c.phones.isNotEmpty ? c.phones.first.number : '';
                return ListTile(
                  dense: true,
                  leading: const Icon(Icons.person_outline, size: 20, color: AppColors.textSecondary),
                  title: Text(c.displayName, style: AppTextStyles.noteText),
                  subtitle: Text(phone, style: AppTextStyles.metadata),
                  onTap: () {
                    // Return the index in the original list
                    final origIdx = widget.contacts.indexOf(c);
                    Navigator.pop(context, origIdx);
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// =============================================================================
/// History Sheet — toutes les commandes vocales, format debug compact
/// =============================================================================

class _HistorySheet extends StatelessWidget {
  final DatabaseService databaseService;
  final ScrollController scrollController;

  const _HistorySheet({
    required this.databaseService,
    required this.scrollController,
  });

  static String _intentLabel(String intent) => switch (intent) {
    'calendar'      => 'Calendar',
    'sms'           => 'SMS',
    'messaging'     => 'Message',
    'message'       => 'Message',
    'alarm'         => 'Alarme',
    'timer'         => 'Timer',
    'call'          => 'Appel',
    'navigation'    => 'GPS',
    'media'         => 'Média',
    'app_launch'    => 'Appli',
    'system_control'=> 'Sys',
    'query_time'    => 'Heure',
    'query_battery' => 'Batterie',
    'payment'       => 'Paiement',
    'none'          => 'Mémo',
    _               => intent,
  };

  static Color _intentColor(String intent) => switch (intent) {
    'calendar'       => AppColors.categoryEvent,
    'sms' || 'messaging' || 'message' => AppColors.categoryContact,
    'payment'        => AppColors.categoryShopping,
    'none'           => AppColors.categoryMemo,
    _                => AppColors.textSecondary,
  };

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Container(
              width: 36, height: 4,
              decoration: BoxDecoration(
                color: AppColors.textTertiary.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('Historique', style: AppTextStyles.heading),
            ),
          ),
          const Divider(color: AppColors.border, height: 1),
          Expanded(
            child: StreamBuilder<List<VoiceNote>>(
              stream: databaseService.notesStream,
              initialData: databaseService.lastNotes,
              builder: (context, snapshot) {
                final notes = snapshot.data ?? [];

                if (notes.isEmpty) {
                  return const Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.history, size: 40, color: AppColors.textTertiary),
                        SizedBox(height: 8),
                        Text('Aucune commande', style: AppTextStyles.metadata),
                      ],
                    ),
                  );
                }

                return ListView.builder(
                  controller: scrollController,
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemCount: notes.length,
                  itemBuilder: (context, index) {
                    final note = notes[index];
                    final hasError = note.errorMessage != null;
                    final isProcessing = note.isProcessing;

                    String intent = 'none';
                    String appLabel = '…';
                    Color appColor = AppColors.textSecondary;
                    if (note.actionJson != null && note.actionJson!.isNotEmpty) {
                      try {
                        final map = jsonDecode(note.actionJson!) as Map<String, dynamic>;
                        intent = map['intent'] as String? ?? 'none';
                        appLabel = _intentLabel(intent);
                        appColor = _intentColor(intent);
                      } catch (_) {}
                    } else if (!isProcessing) {
                      appLabel = 'Mémo';
                      appColor = AppColors.categoryMemo;
                    }

                    final title = note.summary.isNotEmpty
                        ? note.summary
                        : note.text.isNotEmpty
                            ? note.text
                            : '—';
                    final hasAudio = note.audioPath.isNotEmpty;

                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
                      child: Row(
                        children: [
                          // Macaron statut
                          Container(
                            width: 8, height: 8,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: isProcessing
                                  ? AppColors.textSecondary
                                  : hasError
                                      ? Colors.red
                                      : AppColors.bleConnected,
                            ),
                          ),
                          const SizedBox(width: 6),
                          // Chip intent
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                            decoration: BoxDecoration(
                              color: appColor.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              appLabel,
                              style: TextStyle(
                                fontSize: 9,
                                fontWeight: FontWeight.w600,
                                color: appColor,
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          // Titre
                          Expanded(
                            child: Text(
                              title,
                              style: const TextStyle(
                                fontSize: 11,
                                color: AppColors.textPrimary,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          // Indicateur audio
                          if (hasAudio) ...[
                            const SizedBox(width: 4),
                            const Icon(Icons.mic, size: 10, color: AppColors.textTertiary),
                          ],
                        ],
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// =============================================================================
/// Spotify Player Sheet (compact avec contrôles)
class _SpotifyPlayerSheet extends StatefulWidget {
  final AudioService audioService;
  const _SpotifyPlayerSheet({required this.audioService});

  @override
  State<_SpotifyPlayerSheet> createState() => _SpotifyPlayerSheetState();
}

class _SpotifyPlayerSheetState extends State<_SpotifyPlayerSheet> {
  Map<String, dynamic>? _state;
  bool _isPlaying = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final state = await widget.audioService.getSpotifyPlayerState();
    if (!mounted) return;
    setState(() {
      _state = state;
      _isPlaying = state?['is_playing'] as bool? ?? false;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final item = _state?['item'] as Map<String, dynamic>?;
    final trackName = item?['name'] as String? ?? '';
    final artists = (item?['artists'] as List?)
            ?.map((a) => a['name'])
            .join(', ') ??
        '';

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Header: Spotify label + disconnect icon
          Row(
            children: [
              const Icon(Icons.music_note, color: Color(0xFF1DB954), size: 18),
              const SizedBox(width: 6),
              const Text('Spotify',
                  style: TextStyle(
                    color: Color(0xFF1DB954),
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  )),
              const Spacer(),
              // Device switcher
              GestureDetector(
                onTap: () => _showDevicePicker(context),
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 6),
                  child: Icon(Icons.speaker_group, color: Color(0xFF1DB954), size: 20),
                ),
              ),
              const SizedBox(width: 8),
              // Disconnect
              GestureDetector(
                onTap: () {
                  Navigator.pop(context);
                  widget.audioService.disconnectSpotify();
                },
                child: const Icon(Icons.logout, color: Colors.red, size: 18),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // Track info
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: SizedBox(
                width: 20, height: 20,
                child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF1DB954)),
              ),
            )
          else if (trackName.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('Aucune lecture en cours', style: AppTextStyles.metadata),
            )
          else ...[
            Text(trackName,
                style: AppTextStyles.noteText,
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
            if (artists.isNotEmpty)
              Text(artists,
                  style: AppTextStyles.metadata,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
          ],
          const SizedBox(height: 12),

          // Controls — Previous, Play/Pause, Next
          Container(
            padding: const EdgeInsets.symmetric(vertical: 4),
            decoration: BoxDecoration(
              color: AppColors.background.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(24),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.skip_previous_rounded),
                  color: AppColors.textPrimary,
                  iconSize: 32,
                  tooltip: 'Piste précédente',
                  onPressed: () async {
                    await widget.audioService.spotifyPrevious();
                    Future.delayed(const Duration(milliseconds: 500), _refresh);
                  },
                ),
                const SizedBox(width: 12),
                IconButton(
                  icon: Icon(_isPlaying
                      ? Icons.pause_circle_filled
                      : Icons.play_circle_filled),
                  color: const Color(0xFF1DB954),
                  iconSize: 52,
                  tooltip: _isPlaying ? 'Pause' : 'Lecture',
                  onPressed: () async {
                    if (_isPlaying) {
                      await widget.audioService.spotifyPause();
                    } else {
                      await widget.audioService.spotifyPlay();
                    }
                    setState(() => _isPlaying = !_isPlaying);
                  },
                ),
                const SizedBox(width: 12),
                IconButton(
                  icon: const Icon(Icons.skip_next_rounded),
                  color: AppColors.textPrimary,
                  iconSize: 32,
                  tooltip: 'Piste suivante',
                  onPressed: () async {
                    await widget.audioService.spotifyNext();
                    Future.delayed(const Duration(milliseconds: 500), _refresh);
                  },
                ),
                const SizedBox(width: 8),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _showDevicePicker(BuildContext context) async {
    final devices = await widget.audioService.spotifyGetDevices();
    if (devices.isEmpty || !context.mounted) return;

    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 14, 16, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Écouter sur', style: AppTextStyles.heading),
              ),
            ),
            const Divider(color: AppColors.border, height: 1),
            ...devices.map((device) {
              final name = device['name'] as String? ?? '?';
              final type = device['type'] as String? ?? '';
              final isActive = device['is_active'] as bool? ?? false;
              final id = device['id'] as String? ?? '';
              final icon = switch (type.toLowerCase()) {
                'smartphone' => Icons.smartphone,
                'computer' => Icons.computer,
                'speaker' => Icons.speaker,
                'tv' => Icons.tv,
                'cast_audio' || 'castaudio' => Icons.cast,
                _ => Icons.devices,
              };

              return ListTile(
                leading: Icon(icon,
                    color: isActive ? const Color(0xFF1DB954) : AppColors.textSecondary,
                    size: 22),
                title: Text(name, style: AppTextStyles.noteText.copyWith(
                  color: isActive ? const Color(0xFF1DB954) : AppColors.textPrimary,
                )),
                trailing: isActive
                    ? const Icon(Icons.volume_up, color: Color(0xFF1DB954), size: 18)
                    : null,
                onTap: isActive ? null : () async {
                  Navigator.pop(ctx);
                  await widget.audioService.spotifyTransferPlayback(id);
                  _refresh();
                },
              );
            }),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

/// Fiche contrôles MediaKey (Deezer, YouTube Music)
/// =============================================================================

class _MediaKeySheet extends StatefulWidget {
  final String label;
  final Color color;
  final String package;
  final AudioService audioService;

  const _MediaKeySheet({
    required this.label,
    required this.color,
    required this.package,
    required this.audioService,
  });

  @override
  State<_MediaKeySheet> createState() => _MediaKeySheetState();
}

class _MediaKeySheetState extends State<_MediaKeySheet> {
  bool _isPlaying = false;

  void _openApp() {
    if (widget.package.isEmpty) return;
    AndroidIntent(
      action: 'android.intent.action.MAIN',
      category: 'android.intent.category.LAUNCHER',
      package: widget.package,
      flags: <int>[Flag.FLAG_ACTIVITY_NEW_TASK],
    ).launch();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(Icons.music_note, color: widget.color, size: 18),
              const SizedBox(width: 6),
              Text(
                widget.label,
                style: TextStyle(
                  color: widget.color,
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                ),
              ),
              const Spacer(),
              GestureDetector(
                onTap: _openApp,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Icon(Icons.open_in_new, color: widget.color, size: 20),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(vertical: 4),
            decoration: BoxDecoration(
              color: AppColors.background.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(24),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.skip_previous_rounded),
                  color: AppColors.textPrimary,
                  iconSize: 32,
                  onPressed: () => widget.audioService.mediaPrevious(),
                ),
                const SizedBox(width: 12),
                IconButton(
                  icon: Icon(
                    _isPlaying ? Icons.pause_circle_filled : Icons.play_circle_filled,
                    color: widget.color,
                  ),
                  iconSize: 52,
                  tooltip: _isPlaying ? 'Pause' : 'Lecture',
                  onPressed: () {
                    widget.audioService.mediaPlayPause();
                    setState(() => _isPlaying = !_isPlaying);
                  },
                ),
                const SizedBox(width: 12),
                IconButton(
                  icon: const Icon(Icons.skip_next_rounded),
                  color: AppColors.textPrimary,
                  iconSize: 32,
                  onPressed: () => widget.audioService.mediaNext(),
                ),
                const SizedBox(width: 8),
              ],
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Contrôle via les touches média Android',
            style: AppTextStyles.metadata,
          ),
        ],
      ),
    );
  }
}

/// Messages Sheet Content (bottom sheet draggable)
/// =============================================================================

class _MessagesSheetContent extends StatefulWidget {
  final ScrollController scrollController;
  final MessageAggregatorService aggregator;
  final DraggableScrollableController? draggableController;

  const _MessagesSheetContent({
    required this.scrollController,
    required this.aggregator,
    this.draggableController,
  });

  @override
  State<_MessagesSheetContent> createState() => _MessagesSheetContentState();
}

class _MessagesSheetContentState extends State<_MessagesSheetContent> {
  /// Index du message en mode réponse clavier (-1 = aucun)
  int _replyIndex = -1;
  IncomingMessage? _replyMsg;
  final _replyController = TextEditingController();
  final _replyFocus = FocusNode();

  /// Réponse vocale (long press)
  bool _isVoiceRecording = false;
  bool _isVoiceTranscribing = false;
  int _voiceReplyIndex = -1;
  IncomingMessage? _voiceReplyMsg;
  String? _voiceReplyText;

  @override
  void dispose() {
    _replyController.dispose();
    _replyFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Column(
        children: [
          // Drag handle
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.textTertiary.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          // Header compact
          Padding(
            padding: const EdgeInsets.only(left: 16, right: 6, bottom: 2),
            child: Row(
              children: [
                const Text('Messages', style: AppTextStyles.heading),
                const Spacer(),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.delete_outline, size: 18, color: AppColors.textSecondary),
                  tooltip: 'Tout effacer',
                  onPressed: () {
                    widget.aggregator.clearAll();
                    setState(() {});
                  },
                ),
              ],
            ),
          ),
          const Divider(color: AppColors.border, height: 1),
          // Messages list
          Expanded(
            child: StreamBuilder<List<IncomingMessage>>(
              stream: widget.aggregator.messagesStream,
              initialData: widget.aggregator.messages,
              builder: (context, snapshot) {
                final messages = snapshot.data ?? [];

                if (messages.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.chat_bubble_outline, size: 48, color: AppColors.textTertiary),
                        const SizedBox(height: 12),
                        const Text(
                          'Aucun message',
                          style: AppTextStyles.metadata,
                        ),
                      ],
                    ),
                  );
                }

                return ListView.builder(
                  controller: widget.scrollController,
                  padding: const EdgeInsets.only(top: 4, bottom: 16),
                  itemCount: messages.length,
                  itemBuilder: (context, index) {
                    final msg = messages[index];

                    return Dismissible(
                      key: ValueKey(msg.id),
                      background: Container(
                        alignment: Alignment.centerLeft,
                        padding: const EdgeInsets.only(left: 20),
                        color: AppColors.accent.withValues(alpha: 0.15),
                        child: const Icon(Icons.reply, color: AppColors.accent),
                      ),
                      secondaryBackground: Container(
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.only(right: 20),
                        color: Colors.red.withValues(alpha: 0.12),
                        child: const Icon(Icons.delete_outline, color: Colors.red),
                      ),
                      confirmDismiss: (direction) async {
                        if (direction == DismissDirection.endToStart) {
                          // Swipe gauche → supprimer
                          return true;
                        }
                        // Swipe droite → répondre (expand plein écran pour le clavier)
                        setState(() {
                          _replyIndex = index;
                          _replyMsg = msg;
                        });
                        widget.draggableController?.animateTo(
                          0.92,
                          duration: const Duration(milliseconds: 250),
                          curve: Curves.easeOut,
                        );
                        Future.delayed(const Duration(milliseconds: 150), () {
                          _replyFocus.requestFocus();
                        });
                        return false;
                      },
                      onDismissed: (direction) {
                        _removeMessage(msg.id);
                      },
                      child: _voiceReplyIndex == index
                          ? _buildVoiceMessageTile(msg, index)
                          : GestureDetector(
                              onTap: () => _openInSourceApp(msg),
                              onLongPressStart: (_) => _startVoiceReply(msg, index),
                              onLongPressEnd: (_) => _stopVoiceReply(),
                              child: _buildMessageTile(msg),
                            ),
                    );
                  },
                );
              },
            ),
          ),
          // Reply bar fixée en bas (au-dessus du clavier)
          if (_replyMsg != null)
            _buildBottomReplyBar(),
        ],
      ),
    );
  }

  Widget _buildBottomReplyBar() {
    final msg = _replyMsg!;
    return Padding(
      padding: EdgeInsets.only(
        left: 12, right: 12, top: 6,
        bottom: MediaQuery.of(context).viewInsets.bottom + 8,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Contexte : nom + aperçu du message original
          Row(
            children: [
              const Icon(Icons.reply, size: 14, color: AppColors.accent),
              const SizedBox(width: 6),
              Expanded(
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: msg.senderName,
                        style: const TextStyle(
                          color: AppColors.accent,
                          fontWeight: FontWeight.w600,
                          fontSize: 12,
                        ),
                      ),
                      TextSpan(
                        text: '  ${msg.messagePreview}',
                        style: AppTextStyles.metadata.copyWith(fontSize: 11),
                      ),
                    ],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              GestureDetector(
                onTap: () {
                  setState(() {
                    _replyIndex = -1;
                    _replyMsg = null;
                    _replyController.clear();
                  });
                  _replyFocus.unfocus();
                  widget.draggableController?.animateTo(
                    0.45,
                    duration: const Duration(milliseconds: 250),
                    curve: Curves.easeOut,
                  );
                },
                child: const Padding(
                  padding: EdgeInsets.only(left: 8),
                  child: Icon(Icons.close, size: 16, color: AppColors.textSecondary),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          // Champ de saisie
          Container(
            decoration: BoxDecoration(
              color: AppColors.background,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: AppColors.border),
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _replyController,
                    focusNode: _replyFocus,
                    style: AppTextStyles.cardBody.copyWith(
                      color: AppColors.textPrimary,
                      fontSize: 14,
                    ),
                    decoration: const InputDecoration(
                      hintText: 'Répondre par SMS...',
                      hintStyle: AppTextStyles.metadata,
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      isDense: true,
                    ),
                    textInputAction: TextInputAction.send,
                    onSubmitted: (text) => _sendReply(msg, text),
                  ),
                ),
                GestureDetector(
                  onTap: () => _sendReply(msg, _replyController.text),
                  child: Container(
                    margin: const EdgeInsets.only(right: 6),
                    width: 32, height: 32,
                    decoration: const BoxDecoration(
                      color: AppColors.accent,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.arrow_upward_rounded, size: 18, color: Colors.white),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static const Map<String, Color> _appColors = {
    'WhatsApp': Color(0xFF25D366),
    'Telegram': Color(0xFF0088CC),
    'Signal': Color(0xFF3A76F0),
    'Messenger': Color(0xFF0084FF),
    'Instagram': Color(0xFFE1306C),
    'LinkedIn': Color(0xFF0A66C2),
    'SMS': Color(0xFF757575),
  };

  Widget _buildMessageTile(IncomingMessage msg) {
    final appColor = _appColors[msg.appSource] ?? AppColors.textSecondary;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border.withValues(alpha: 0.5)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Barre latérale colorée de l'app
          Container(
            width: 3,
            height: 36,
            margin: const EdgeInsets.only(right: 10),
            decoration: BoxDecoration(
              color: appColor,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Ligne 1 : nom + app source + heure
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        msg.senderName,
                        style: AppTextStyles.cardTitle.copyWith(fontSize: 14),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      msg.appSource,
                      style: TextStyle(
                        fontSize: 10,
                        color: appColor,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      _formatTime(msg.receivedAt),
                      style: AppTextStyles.metadata.copyWith(fontSize: 11),
                    ),
                  ],
                ),
                // Ligne 2 : aperçu du message (2 lignes max)
                if (msg.messagePreview.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(
                    msg.messagePreview,
                    style: AppTextStyles.cardBody.copyWith(fontSize: 13),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  // =========================================================================
  // RÉPONSE VOCALE (long press)
  // =========================================================================

  Future<void> _startVoiceReply(IncomingMessage msg, int index) async {
    // Annuler une éventuelle réponse clavier en cours
    if (_replyMsg != null) {
      setState(() { _replyIndex = -1; _replyMsg = null; _replyController.clear(); });
    }
    setState(() {
      _voiceReplyIndex = index;
      _voiceReplyMsg = msg;
      _isVoiceRecording = true;
      _isVoiceTranscribing = false;
      _voiceReplyText = null;
    });
    HapticFeedback.mediumImpact();
    final audioService = AudioService();
    await audioService.startRecording();
  }

  Future<void> _stopVoiceReply() async {
    if (!_isVoiceRecording) return;
    setState(() {
      _isVoiceRecording = false;
      _isVoiceTranscribing = true;
    });

    try {
      final audioService = AudioService();
      final filePath = await audioService.stopRecordingRaw();
      if (filePath == null) {
        setState(() { _voiceReplyIndex = -1; _voiceReplyMsg = null; _isVoiceTranscribing = false; });
        return;
      }

      final file = File(filePath);
      final wavData = await file.readAsBytes();

      // Silence check
      if (audioService.isWavSilent(wavData)) {
        try { await file.delete(); } catch (_) {}
        setState(() { _voiceReplyIndex = -1; _voiceReplyMsg = null; _isVoiceTranscribing = false; });
        return;
      }

      // Transcription Groq Whisper
      final transcription = TranscriptionService();
      final result = await transcription.transcribeBytes(
        wavData,
        language: SettingsService().language,
      );
      try { await file.delete(); } catch (_) {}

      final text = result.text.trim();
      if (text.isEmpty) {
        setState(() { _voiceReplyIndex = -1; _voiceReplyMsg = null; _isVoiceTranscribing = false; });
        return;
      }

      setState(() {
        _isVoiceTranscribing = false;
        _voiceReplyText = text;
      });
    } catch (e) {
      // ignore: avoid_print
      print('[VoiceReply] Erreur: $e');
      setState(() { _voiceReplyIndex = -1; _voiceReplyMsg = null; _isVoiceTranscribing = false; });
    }
  }

  /// Ouvre l'app source du message (WhatsApp, Telegram, SMS, etc.)
  void _openInSourceApp(IncomingMessage msg) {
    try {
      final package = msg.appPackage;

      // SMS : ouvrir la conversation avec le contact
      if (package.contains('messaging') || package.contains('mms') || package.contains('samsung')) {
        final intent = AndroidIntent(
          action: 'android.intent.action.VIEW',
          data: 'sms:',
          package: package,
          flags: <int>[Flag.FLAG_ACTIVITY_NEW_TASK],
        );
        intent.launch();
        return;
      }

      // Autres apps : ouvrir l'app (WhatsApp, Telegram, etc.)
      final intent = AndroidIntent(
        action: 'android.intent.action.MAIN',
        package: package,
        flags: <int>[Flag.FLAG_ACTIVITY_NEW_TASK],
      );
      intent.launch();
    } catch (e) {
      // ignore: avoid_print
      print('[Messages] Impossible d\'ouvrir ${msg.appPackage}: $e');
    }
  }

  void _cancelVoiceReply() {
    setState(() {
      _voiceReplyIndex = -1;
      _voiceReplyMsg = null;
      _voiceReplyText = null;
      _isVoiceRecording = false;
      _isVoiceTranscribing = false;
    });
  }

  bool _isSending = false;

  Future<void> _sendVoiceReply() async {
    if (_voiceReplyMsg == null || _voiceReplyText == null || _isSending) return;
    _isSending = true;
    await _sendReply(_voiceReplyMsg!, _voiceReplyText!);
    _cancelVoiceReply();
    _isSending = false;
  }

  /// Message tile en mode vocal (long press actif ou texte transcrit)
  /// Isolé du reste du ListView pour limiter les rebuilds
  Widget _buildVoiceMessageTile(IncomingMessage msg, int index) {
    final isActive = _isVoiceRecording || _isVoiceTranscribing;
    final appColor = _appColors[msg.appSource] ?? AppColors.textSecondary;

    return GestureDetector(
      onTap: () => _openInSourceApp(msg),
      onLongPressStart: (_) => _startVoiceReply(msg, index),
      onLongPressEnd: (_) => _stopVoiceReply(),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Message tile avec fond vert subtil pendant enregistrement/transcription
          AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: isActive
                  ? AppColors.accent.withValues(alpha: 0.06)
                  : AppColors.background,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: isActive
                    ? AppColors.accent.withValues(alpha: 0.3)
                    : AppColors.border.withValues(alpha: 0.5),
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 3, height: 36,
                  margin: const EdgeInsets.only(right: 10),
                  decoration: BoxDecoration(
                    color: appColor,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(msg.senderName,
                              style: AppTextStyles.cardTitle.copyWith(fontSize: 14),
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          ),
                          const SizedBox(width: 6),
                          Text(msg.appSource, style: TextStyle(
                            fontSize: 10, color: appColor, fontWeight: FontWeight.w600)),
                          const SizedBox(width: 6),
                          // Indicateur d'activité intégré (remplace l'heure pendant l'enregistrement)
                          if (isActive)
                            SizedBox(width: 12, height: 12,
                              child: CircularProgressIndicator(strokeWidth: 1.5,
                                valueColor: AlwaysStoppedAnimation<Color>(AppColors.accent)))
                          else
                            Text(_formatTime(msg.receivedAt),
                              style: AppTextStyles.metadata.copyWith(fontSize: 11)),
                        ],
                      ),
                      if (msg.messagePreview.isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text(msg.messagePreview,
                          style: AppTextStyles.cardBody.copyWith(fontSize: 13),
                          maxLines: 2, overflow: TextOverflow.ellipsis),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
          // Bulle de réponse vocale (sous le message)
          if (_voiceReplyText != null)
            _buildVoiceReplyBubble(msg),
        ],
      ),
    );
  }

  Widget _buildVoiceReplyBubble(IncomingMessage msg) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 4, 12, 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: AppColors.accent.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.accent.withValues(alpha: 0.25)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                _voiceReplyText!,
                style: AppTextStyles.cardBody.copyWith(
                  fontSize: 13,
                  fontStyle: FontStyle.italic,
                  color: AppColors.textPrimary,
                ),
              ),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: _cancelVoiceReply,
              child: const Icon(Icons.close, size: 18, color: AppColors.textSecondary),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: _sendVoiceReply,
              child: Container(
                width: 32, height: 32,
                decoration: const BoxDecoration(
                  color: AppColors.accent,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.arrow_upward_rounded, size: 18, color: Colors.white),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // =========================================================================
  // RÉPONSE CLAVIER (swipe)
  // =========================================================================

  Future<void> _sendReply(IncomingMessage msg, String text) async {
    if (text.trim().isEmpty || _isSending) return;
    _isSending = true;

    final trimmed = text.trim();
    final senderName = msg.senderName;
    final msgId = msg.id;

    // Envoi systématique par SMS direct (arrière-plan, même canal que l'assistant vocal)
    final svc = LocalSmsService();
    await svc.initialize();
    await svc.sendSms(
      recipient: senderName,
      message: trimmed,
      forceDirect: true,
    );

    // Supprimer le message une fois répondu
    _removeMessage(msgId);

    setState(() {
      _replyIndex = -1;
      _replyMsg = null;
      _replyController.clear();
    });
    widget.draggableController?.animateTo(
      0.45,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
    _isSending = false;
  }

  void _removeMessage(String id) {
    // Access internal list via reflection-free approach:
    // The service exposes messages as unmodifiable, so we remove via index
    final msgs = widget.aggregator.messages;
    final idx = msgs.toList().indexWhere((m) => m.id == id);
    if (idx >= 0) {
      widget.aggregator.removeAt(idx);
    }
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
}

/// =============================================================================
/// Debug Console Panel (affichée en bas de l'écran quand activée)
/// =============================================================================

class _DebugConsolePanel extends StatefulWidget {
  const _DebugConsolePanel();

  @override
  State<_DebugConsolePanel> createState() => _DebugConsolePanelState();
}

class _DebugConsolePanelState extends State<_DebugConsolePanel> {
  final _debug = DebugConsoleService();
  final _scrollController = ScrollController();
  bool _autoScroll = true;

  @override
  void dispose() {
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
    return Container(
      height: 180,
      decoration: const BoxDecoration(
        color: Color(0xFF0A0A0A),
        border: Border(top: BorderSide(color: Color(0xFF333333), width: 0.5)),
      ),
      child: Column(
        children: [
          // Header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            color: const Color(0xFF1A1A1A),
            child: Row(
              children: [
                const Icon(Icons.terminal, size: 14, color: Color(0xFF00FF88)),
                const SizedBox(width: 6),
                const Text('Console',
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      color: Color(0xFF00FF88),
                      fontWeight: FontWeight.bold,
                    )),
                const Spacer(),
                GestureDetector(
                  onTap: () => setState(() => _autoScroll = !_autoScroll),
                  child: Icon(
                    _autoScroll ? Icons.vertical_align_bottom : Icons.pause,
                    size: 14,
                    color: _autoScroll ? const Color(0xFF00FF88) : Colors.orange,
                  ),
                ),
                const SizedBox(width: 12),
                GestureDetector(
                  onTap: () {
                    _debug.clear();
                    setState(() {});
                  },
                  child: const Icon(Icons.delete_outline, size: 14, color: Color(0xFF666666)),
                ),
              ],
            ),
          ),
          // Log lines
          Expanded(
            child: StreamBuilder<List<DebugLogEntry>>(
              stream: _debug.stream,
              initialData: _debug.logs,
              builder: (context, snapshot) {
                final logs = snapshot.data ?? [];
                _scrollToBottom();
                return ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  itemCount: logs.length,
                  itemBuilder: (context, index) {
                    final entry = logs[index];
                    final color = switch (entry.level) {
                      'error' => Colors.red,
                      'warning' => Colors.orange,
                      _ => const Color(0xFFCCCCCC),
                    };
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 0.5),
                      child: Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(
                              text: '${entry.timeStr} ',
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 9,
                                color: Color(0xFF555555),
                              ),
                            ),
                            TextSpan(
                              text: entry.message,
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 9,
                                color: color,
                              ),
                            ),
                          ],
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
