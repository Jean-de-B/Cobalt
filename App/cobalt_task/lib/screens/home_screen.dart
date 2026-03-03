import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import '../constants/app_constants.dart';
import '../models/voice_note.dart';
import '../models/ai_action.dart';
import '../services/ai_sorter_service.dart';
import '../services/audio_service.dart';
import '../services/database_service.dart';
import '../services/google_bridge_service.dart';
import '../services/local_action_dispatcher.dart';
import '../services/overlay_permission_service.dart';
import '../services/validated_contacts_service.dart';
import '../services/contact_lookup_service.dart';
import '../services/incoming_history_service.dart';
import '../services/audio_feedback_service.dart';
import '../services/assistant_launch_service.dart';
import '../services/cobalt_overlay_service.dart';
import '../services/foreground_service.dart';
import '../services/paypal_payment_service.dart';
import 'package:url_launcher/url_launcher.dart';
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
  final PayPalPaymentService _paypalService = PayPalPaymentService();
  StreamSubscription<PendingValidation>? _pendingValidationSub;
  StreamSubscription<String>? _assistLaunchSub;
  StreamSubscription<bool>? _micButtonSub;
  StreamSubscription<bool>? _assistRecordSub;
  StreamSubscription<void>? _overlayDismissSub;
  bool _isShowingValidationDialog = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _databaseService.refreshStream();
    _checkOverlayPermission();

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

      if (!isRoleHeld && !isCobaltVoice && mounted) {
        _showAssistantSetupDialog(isSamsung);
      }
    } catch (e) {
      // ignore: avoid_print
      print('[HomeScreen] Erreur check assistant: $e');
    }
  }

  void _showAssistantSetupDialog(bool isSamsung) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Assistant vocal'),
        content: Text(
          'Pour activer le micro Cobalt avec le bouton Power :\n\n'
          '1. Sélectionner Cobalt comme assistant par défaut\n'
          '   (Paramètres > Apps > Apps par défaut > Assistant numérique)\n'
          '${isSamsung ? '\n2. Configurer la touche latérale Samsung\n'
          '   (Paramètres > Fonctions avancées > Touche latérale\n'
          '   > Appui prolongé > Assistant numérique)\n' : ''}'
          '\nVoulez-vous configurer maintenant ?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Plus tard', style: TextStyle(color: AppColors.textSecondary)),
          ),
          if (isSamsung)
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                _assistantLaunchService.openSideKeySettings();
              },
              child: const Text('Touche latérale'),
            ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              final result = await _assistantLaunchService.requestAssistantRole();
              // ignore: avoid_print
              print('[HomeScreen] Role request result: $result');
            },
            child: const Text('Configurer'),
          ),
        ],
      ),
    );
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
        text: 'En \u00e9coute...',
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
        text: 'En \u00e9coute...',
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
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // ignore: avoid_print
      print('APP: Retour au premier plan - retry des transcriptions en attente');
      _audioService.retryPendingTranscriptions();
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
    return Scaffold(
      backgroundColor: AppColors.background,
      extendBodyBehindAppBar: true,
      appBar: _buildAppBar(),
      body: _buildBody(),
      floatingActionButton: _buildPTTButton(),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
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
            title: const Text('Cobalt Task', style: AppTextStyles.heading),
            actions: [
              _buildTransferIndicator(),
              _buildBatteryIndicator(),
              _buildPayPalIndicator(),
              _buildSpotifyIndicator(),
              _buildGoogleIndicator(),
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

  Widget _buildPayPalIndicator() {
    return StreamBuilder<bool>(
      stream: _paypalService.configuredStream,
      initialData: _paypalService.isConfigured,
      builder: (context, snapshot) {
        final isConfigured = snapshot.data ?? false;

        return Tooltip(
          message: isConfigured ? 'PayPal connecté' : 'Configurer PayPal',
          child: InkWell(
            onTap: () => _showPayPalMenu(context, isConfigured),
            borderRadius: BorderRadius.circular(20),
            child: Padding(
              padding: const EdgeInsets.all(8.0),
              child: Icon(
                Icons.attach_money,
                color: isConfigured
                    ? const Color(0xFF0070BA)
                    : AppColors.textSecondary,
                size: 22,
              ),
            ),
          ),
        );
      },
    );
  }

  void _showPayPalMenu(BuildContext context, bool isConfigured) {
    final clientIdController = TextEditingController();
    final secretController = TextEditingController();

    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(sheetContext).viewInsets.bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isConfigured) ...[
                const ListTile(
                  leading: Icon(Icons.check_circle, color: Color(0xFF0070BA)),
                  title: Text('PayPal connecté', style: AppTextStyles.noteText),
                  subtitle: Text(
                    'Paiements vocaux activés',
                    style: AppTextStyles.metadata,
                  ),
                ),
                const Divider(color: AppColors.border),
                ListTile(
                  leading: const Icon(Icons.logout, color: AppColors.textSecondary),
                  title: const Text('Déconnecter PayPal',
                      style: AppTextStyles.noteText),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _paypalService.clearCredentials();
                  },
                ),
              ] else ...[
                const ListTile(
                  leading: Icon(Icons.money_off, color: AppColors.textSecondary),
                  title: Text('PayPal non configuré', style: AppTextStyles.noteText),
                  subtitle: Text(
                    'Entrez vos identifiants API PayPal pour activer les paiements vocaux',
                    style: AppTextStyles.metadata,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: InkWell(
                    onTap: () async {
                      final uri = Uri.parse('https://developer.paypal.com/dashboard/applications/live');
                      if (await canLaunchUrl(uri)) {
                        await launchUrl(uri, mode: LaunchMode.externalApplication);
                      }
                    },
                    child: const Row(
                      children: [
                        Icon(Icons.open_in_new, size: 16, color: Color(0xFF0070BA)),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Créer une app sur developer.paypal.com → Apps & Credentials → Create App',
                            style: TextStyle(
                              fontSize: 12,
                              color: Color(0xFF0070BA),
                              decoration: TextDecoration.underline,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const Divider(color: AppColors.border),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: TextField(
                    controller: clientIdController,
                    decoration: const InputDecoration(
                      labelText: 'Client ID',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.key),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: TextField(
                    controller: secretController,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'Secret',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.lock),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: () async {
                        final clientId = clientIdController.text.trim();
                        final secret = secretController.text.trim();
                        if (clientId.isEmpty || secret.isEmpty) return;

                        final messenger = ScaffoldMessenger.of(this.context);
                        final success = await _paypalService.saveCredentials(clientId, secret);
                        if (!sheetContext.mounted) return;

                        Navigator.pop(sheetContext);
                        if (success) {
                          messenger.showSnackBar(
                            const SnackBar(
                              content: Text('PayPal connecté !'),
                              backgroundColor: Color(0xFF0070BA),
                            ),
                          );
                        } else {
                          messenger.showSnackBar(
                            const SnackBar(
                              content: Text('Identifiants invalides'),
                              backgroundColor: Colors.red,
                            ),
                          );
                        }
                      },
                      icon: const Icon(Icons.login),
                      label: const Text('Connecter'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF0070BA),
                        foregroundColor: Colors.white,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSpotifyIndicator() {
    return StreamBuilder<bool>(
      stream: _audioService.spotifyConnectionStream,
      initialData: _audioService.isSpotifyConnected,
      builder: (context, snapshot) {
        final isConnected = snapshot.data ?? false;

        return Tooltip(
          message: isConnected ? 'Spotify connecte' : 'Connecter Spotify',
          child: InkWell(
            onTap: () => _showSpotifyMenu(context, isConnected),
            borderRadius: BorderRadius.circular(20),
            child: Padding(
              padding: const EdgeInsets.all(8.0),
              child: Icon(
                Icons.music_note,
                color: isConnected
                    ? const Color(0xFF1DB954)
                    : AppColors.textSecondary,
                size: 22,
              ),
            ),
          ),
        );
      },
    );
  }

  void _showSpotifyMenu(BuildContext context, bool isConnected) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isConnected) ...[
              ListTile(
                leading: const Icon(Icons.music_note, color: Color(0xFF1DB954)),
                title: const Text('Spotify connecte', style: AppTextStyles.noteText),
                subtitle: const Text(
                  'Controle via API Web (fonctionne ecran verrouille)',
                  style: AppTextStyles.metadata,
                ),
              ),
              const Divider(color: AppColors.border),
              FutureBuilder<Map<String, dynamic>?>(
                future: _audioService.getSpotifyPlayerState(),
                builder: (context, snapshot) {
                  final state = snapshot.data;
                  if (state == null) {
                    return const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text('Aucune lecture en cours',
                          style: AppTextStyles.metadata),
                    );
                  }
                  final item = state['item'] as Map<String, dynamic>?;
                  final trackName = item?['name'] as String? ?? 'Inconnu';
                  final artists = (item?['artists'] as List?)
                          ?.map((a) => a['name'])
                          .join(', ') ??
                      '';
                  return ListTile(
                    leading:
                        const Icon(Icons.play_circle, color: Color(0xFF1DB954)),
                    title: Text(trackName, style: AppTextStyles.noteText),
                    subtitle: Text(artists, style: AppTextStyles.metadata),
                  );
                },
              ),
              const Divider(color: AppColors.border),
              ListTile(
                leading: const Icon(Icons.logout, color: AppColors.textSecondary),
                title: const Text('Deconnecter Spotify',
                    style: AppTextStyles.noteText),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _audioService.disconnectSpotify();
                },
              ),
            ] else ...[
              ListTile(
                leading: const Icon(Icons.music_off, color: AppColors.textSecondary),
                title: const Text('Spotify non connecte', style: AppTextStyles.noteText),
                subtitle: const Text(
                  'Connectez-vous pour controler la musique par la voix sans allumer l\'ecran',
                  style: AppTextStyles.metadata,
                ),
              ),
              const Divider(color: AppColors.border),
              ListTile(
                leading: const Icon(Icons.login, color: Color(0xFF1DB954)),
                title: const Text('Connecter Spotify',
                    style: AppTextStyles.noteText),
                onTap: () {
                  // ignore: avoid_print
                  print('[UI] Tap Connecter Spotify - fermeture bottom sheet...');
                  Navigator.pop(sheetContext);
                  // Délai pour laisser l'animation de fermeture du bottom sheet
                  // se terminer avant de lancer le flux OAuth (appel plateforme lourd)
                  Future.delayed(const Duration(milliseconds: 500), () {
                    // ignore: avoid_print
                    print('[UI] Bottom sheet fermé, lancement connectSpotify...');
                    _audioService.connectSpotify();
                  });
                },
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildGoogleIndicator() {
    return StreamBuilder<bool>(
      stream: _audioService.googleConnectionStateStream,
      initialData: _audioService.isGoogleConnected,
      builder: (context, snapshot) {
        final isConnected = snapshot.data ?? false;

        return Tooltip(
          message: isConnected
              ? 'Google connecte: ${_audioService.googleUserEmail ?? ""}'
              : 'Appuyez pour connecter Google',
          child: InkWell(
            onTap: () => _showGoogleMenu(context, isConnected),
            borderRadius: BorderRadius.circular(20),
            child: Padding(
              padding: const EdgeInsets.all(8.0),
              child: Icon(
                isConnected ? Icons.cloud_done : Icons.cloud_off,
                color: isConnected ? AppColors.bleConnected : AppColors.textSecondary,
                size: 22,
              ),
            ),
          ),
        );
      },
    );
  }

  void _showGoogleMenu(BuildContext context, bool isConnected) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isConnected) ...[
              ListTile(
                leading: Icon(Icons.cloud_done, color: AppColors.bleConnected),
                title: Text(
                  _audioService.googleUserName ?? 'Google',
                  style: AppTextStyles.noteText,
                ),
                subtitle: Text(
                  _audioService.googleUserEmail ?? '',
                  style: AppTextStyles.metadata,
                ),
              ),
              const Divider(color: AppColors.border),
              _buildGoogleHistory(),
              const Divider(color: AppColors.border),
              ListTile(
                leading: const Icon(Icons.logout, color: AppColors.textSecondary),
                title: const Text('Deconnecter Google', style: AppTextStyles.noteText),
                onTap: () async {
                  await _audioService.signOutGoogle();
                  if (mounted) Navigator.pop(context);
                },
              ),
            ] else ...[
              ListTile(
                leading: const Icon(Icons.cloud_off, color: AppColors.textSecondary),
                title: const Text('Non connecte', style: AppTextStyles.noteText),
                subtitle: const Text(
                  'Connectez-vous pour synchroniser avec Google Tasks, Calendar, Contacts et Docs',
                  style: AppTextStyles.metadata,
                ),
              ),
              const Divider(color: AppColors.border),
              ListTile(
                leading: const Icon(Icons.login, color: AppColors.accent),
                title: const Text('Connecter Google', style: AppTextStyles.noteText),
                onTap: () async {
                  final messenger = ScaffoldMessenger.of(context);
                  Navigator.pop(context);
                  final success = await _audioService.signInGoogle();
                  if (mounted && success) {
                    messenger.showSnackBar(
                      const SnackBar(
                        content: Text('Connecte a Google!'),
                        backgroundColor: Colors.green,
                      ),
                    );
                  }
                },
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildGoogleHistory() {
    return StreamBuilder<List<SyncAction>>(
      stream: _audioService.googleHistoryStream,
      initialData: _audioService.googleActionHistory,
      builder: (context, snapshot) {
        final actions = snapshot.data ?? [];

        if (actions.isEmpty) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Aucune action recente',
              style: AppTextStyles.metadata,
            ),
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                'Dernieres synchronisations',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textSecondary,
                ),
              ),
            ),
            ...actions.take(5).map((action) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Row(
                children: [
                  Icon(
                    action.success ? Icons.check_circle : Icons.error,
                    size: 14,
                    color: action.success ? AppColors.bleConnected : Colors.red,
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    _getCategoryIcon(action.category),
                    size: 14,
                    color: _getCategoryColor(action.category),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    _getCategoryLabel(action.category),
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      color: _getCategoryColor(action.category),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      action.title,
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.textPrimary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            )),
          ],
        );
      },
    );
  }

  IconData _getCategoryIcon(NoteCategory category) {
    switch (category) {
      case NoteCategory.todo:
        return Icons.check_circle_outline;
      case NoteCategory.shopping:
        return Icons.shopping_cart_outlined;
      case NoteCategory.event:
        return Icons.event;
      case NoteCategory.contact:
        return Icons.person_outline;
      case NoteCategory.memo:
        return Icons.edit_note;
    }
  }

  Color _getCategoryColor(NoteCategory category) {
    switch (category) {
      case NoteCategory.todo:
        return AppColors.categoryTodo;
      case NoteCategory.shopping:
        return AppColors.categoryShopping;
      case NoteCategory.event:
        return AppColors.categoryEvent;
      case NoteCategory.contact:
        return AppColors.categoryContact;
      case NoteCategory.memo:
        return AppColors.categoryMemo;
    }
  }

  String _getCategoryLabel(NoteCategory category) {
    switch (category) {
      case NoteCategory.todo:
        return 'Tasks';
      case NoteCategory.shopping:
        return 'Courses';
      case NoteCategory.event:
        return 'Calendar';
      case NoteCategory.contact:
        return 'Contacts';
      case NoteCategory.memo:
        return 'Docs';
    }
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
            } else if (level <= 15) {
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

  Widget _buildBody() {
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
                  label: const Text('Connecter une montre'),
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

  void _scanAndPickDevice() {
    _audioService.startBleScan();

    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
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

class _DevicePickerSheet extends StatelessWidget {
  final AudioService audioService;

  const _DevicePickerSheet({required this.audioService});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Montres disponibles',
              style: AppTextStyles.heading,
            ),
          ),
          const Divider(color: AppColors.border),
          StreamBuilder<List<ScanResult>>(
            stream: audioService.discoveredDevicesStream,
            initialData: audioService.discoveredDevices,
            builder: (context, snapshot) {
              final devices = snapshot.data ?? [];

              if (devices.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.all(32),
                  child: Column(
                    children: [
                      SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor:
                              AlwaysStoppedAnimation<Color>(AppColors.accent),
                        ),
                      ),
                      SizedBox(height: 16),
                      Text(
                        'Recherche en cours...',
                        style: AppTextStyles.metadata,
                      ),
                    ],
                  ),
                );
              }

              return ListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: devices.length,
                itemBuilder: (context, index) =>
                    _buildDeviceTile(context, devices[index]),
              );
            },
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  Widget _buildDeviceTile(BuildContext context, ScanResult result) {
    final advName = result.advertisementData.advName;
    final platformName = result.device.platformName;
    final displayName = advName.isNotEmpty ? advName : platformName;

    return ListTile(
      leading: const Icon(Icons.watch, color: AppColors.accent),
      title: Text(displayName, style: AppTextStyles.noteText),
      trailing: const Icon(Icons.chevron_right, color: AppColors.textSecondary),
      onTap: () {
        Navigator.pop(context);
        audioService.connectToBleDevice(result.device);
      },
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
