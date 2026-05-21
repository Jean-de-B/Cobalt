import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../constants/app_constants.dart';
import '../services/settings_service.dart';
import '../services/audio_service.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _settings = SettingsService();
  final _audioService = AudioService();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: const Text('Paramètres', style: AppTextStyles.heading),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: AppColors.textPrimary),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          // === LANGUE ===
          _sectionTitle('Langue'),
          _buildChipSelector(
            value: _settings.language,
            options: const {'fr': 'Français', 'en': 'English'},
            onChanged: (v) => setState(() => _settings.language = v),
          ),

          const SizedBox(height: 24),

          // === SERVICES ===
          _sectionTitle('Services'),

          _buildServiceRow(
            icon: Icons.music_note,
            color: const Color(0xFF1DB954),
            label: 'Musique',
            value: _settings.musicService,
            options: SettingsService.musicServices,
            onChanged: (v) => setState(() => _settings.musicService = v),
          ),

          _buildServiceRow(
            icon: Icons.calendar_month,
            color: const Color(0xFF4285F4),
            label: 'Calendrier',
            value: _settings.calendarService,
            options: SettingsService.calendarServices,
            onChanged: (v) => setState(() => _settings.calendarService = v),
          ),

          _buildServiceRow(
            icon: Icons.alarm,
            color: const Color(0xFFFF5722),
            label: 'Rappel',
            value: _settings.reminderService,
            options: SettingsService.reminderServices,
            onChanged: (v) => setState(() => _settings.reminderService = v),
          ),

          _buildServiceRow(
            icon: Icons.checklist,
            color: const Color(0xFF29B6F6),
            label: 'Liste',
            value: _settings.listService,
            options: SettingsService.listServices,
            onChanged: (v) => setState(() => _settings.listService = v),
          ),

          _buildServiceRow(
            icon: Icons.note_alt,
            color: const Color(0xFFFFB300),
            label: 'Notes',
            value: _settings.notesService,
            options: SettingsService.notesServices,
            onChanged: (v) => setState(() => _settings.notesService = v),
          ),

          _buildServiceRow(
            icon: Icons.navigation,
            color: const Color(0xFF34A853),
            label: 'Navigation',
            value: _settings.navigationApp,
            options: SettingsService.navigationApps,
            onChanged: (v) => setState(() => _settings.navigationApp = v),
          ),

          _buildServiceRow(
            icon: Icons.chat,
            color: const Color(0xFF25D366),
            label: 'Messagerie',
            value: _settings.preferredMessaging,
            options: SettingsService.messagingApps,
            onChanged: (v) => setState(() => _settings.preferredMessaging = v),
          ),

          _buildServiceRow(
            icon: Icons.directions_bike,
            color: AppColors.accent,
            label: 'Transport',
            value: _settings.defaultTransport,
            options: SettingsService.transportModes,
            onChanged: (v) => setState(() => _settings.defaultTransport = v),
          ),

          const SizedBox(height: 24),

          // === SYSTÈME ===
          _sectionTitle('Système'),

          _buildToggle(
            icon: Icons.power_settings_new,
            label: 'Bouton Power → Assistant',
            subtitle: 'Long press sur le bouton Power active l\'assistant',
            value: _settings.powerButtonAssistant,
            onChanged: (v) => setState(() => _settings.powerButtonAssistant = v),
          ),

          _buildToggle(
            icon: Icons.notifications_active,
            label: 'Notification persistante',
            subtitle: 'Affiche le micro dans les notifications',
            value: _settings.persistentNotification,
            onChanged: (v) => setState(() => _settings.persistentNotification = v),
          ),

          _buildToggle(
            icon: Icons.headset_mic,
            label: 'Assistant casque / écouteurs',
            subtitle: 'Répondre au bouton assistant des casques Bluetooth tiers',
            value: _settings.headsetAssistant,
            onChanged: (v) => setState(() => _settings.headsetAssistant = v),
          ),

          _buildToggle(
            icon: Icons.record_voice_over,
            label: 'Retour vocal (TTS)',
            subtitle: 'L\'assistant parle après chaque action',
            value: _settings.ttsEnabled,
            onChanged: (v) => setState(() => _settings.ttsEnabled = v),
          ),

          _buildToggle(
            icon: Icons.volume_up,
            label: 'Son de confirmation',
            subtitle: 'Bip sonore au début et fin de l\'enregistrement',
            value: _settings.confirmationSound,
            onChanged: (v) => setState(() => _settings.confirmationSound = v),
          ),

          _buildToggle(
            icon: Icons.watch,
            label: 'Auto-connexion bracelet',
            subtitle: 'Se connecte au bracelet Cobalt au démarrage',
            value: _settings.autoConnectBracelet,
            onChanged: (v) => setState(() => _settings.autoConnectBracelet = v),
          ),

          _buildToggle(
            icon: Icons.terminal,
            label: 'Console debug',
            subtitle: 'Affiche les logs en temps réel dans l\'app',
            value: _settings.debugConsole,
            onChanged: (v) => setState(() => _settings.debugConsole = v),
          ),

          const SizedBox(height: 24),

          // === COMPTES ===
          _sectionTitle('Comptes'),

          // Google
          StreamBuilder<bool>(
            stream: _audioService.googleConnectionStateStream,
            initialData: _audioService.isGoogleConnected,
            builder: (context, snapshot) {
              final connected = snapshot.data ?? false;
              return _buildAccountRow(
                icon: Icons.cloud,
                color: const Color(0xFF4285F4),
                label: 'Google',
                subtitle: connected
                    ? _audioService.googleUserEmail ?? 'Connecté'
                    : 'Calendrier, Tasks, Docs',
                connected: connected,
                onConnect: () async {
                  await _audioService.signInGoogle();
                  setState(() {});
                },
                onDisconnect: () async {
                  await _audioService.signOutGoogle();
                  setState(() {});
                },
              );
            },
          ),

          // Spotify
          StreamBuilder<bool>(
            stream: _audioService.spotifyConnectionStream,
            initialData: _audioService.isSpotifyConnected,
            builder: (context, snapshot) {
              final connected = snapshot.data ?? false;
              return _buildAccountRow(
                icon: Icons.music_note,
                color: const Color(0xFF1DB954),
                label: 'Spotify',
                subtitle: connected ? 'Connecté' : 'Contrôle musical',
                connected: connected,
                onConnect: () {
                  if (_settings.spotifyClientId.isEmpty) {
                    showSpotifySetup(context);
                  } else {
                    _audioService.connectSpotify();
                  }
                },
                onDisconnect: () async {
                  await _audioService.disconnectSpotify();
                  setState(() {});
                },
              );
            },
          ),

          // Notion
          StreamBuilder<void>(
            stream: _settings.onChanged,
            builder: (context, _) {
              final configured = _settings.notionConfigured;
              return _buildAccountRow(
                icon: Icons.article_outlined,
                color: const Color(0xFFCCCCCC),
                label: 'Notion',
                subtitle: configured ? 'Configuré' : 'Notes mémos',
                connected: configured,
                onConnect: () => showNotionSetup(context),
                onDisconnect: () {
                  _settings.notionToken = '';
                  _settings.notionPageId = '';
                },
              );
            },
          ),

          const SizedBox(height: 24),

          // === CLÉS API ===
          _sectionTitle('Clés API'),

          StreamBuilder<void>(
            stream: _settings.onChanged,
            builder: (context, _) {
              final mapsConfigured = _settings.googleMapsApiKey.isNotEmpty;
              final geminiConfigured = _settings.geminiApiKey.isNotEmpty;
              final bothConfigured = mapsConfigured && geminiConfigured;
              return _buildAccountRow(
                icon: Icons.route,
                color: const Color(0xFF34A853),
                label: 'Briefing vocal navigation',
                subtitle: bothConfigured
                    ? '2 clés configurées'
                    : mapsConfigured || geminiConfigured
                        ? '1 clé manquante'
                        : 'Optionnel — résumé du trajet avant Maps',
                connected: bothConfigured,
                onConnect: () => showNavigationApiSetup(context),
                onDisconnect: () => showNavigationApiSetup(context),
              );
            },
          ),

          const SizedBox(height: 24),

          // === INFO ===
          _sectionTitle('À propos'),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              'Cobalt Task v1.0.0',
              style: AppTextStyles.metadata.copyWith(fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10, top: 4),
      child: Text(
        title.toUpperCase(),
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: AppColors.accent,
          letterSpacing: 1.5,
        ),
      ),
    );
  }

  Widget _buildChipSelector({
    required String value,
    required Map<String, String> options,
    required ValueChanged<String> onChanged,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.all(4),
      child: Row(
        children: options.entries.map((e) {
          final selected = e.key == value;
          return Expanded(
            child: GestureDetector(
              onTap: () => onChanged(e.key),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                  color: selected
                      ? AppColors.accent.withValues(alpha: 0.15)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Center(
                  child: Text(
                    e.value,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                      color: selected ? AppColors.accent : AppColors.textSecondary,
                    ),
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildServiceRow({
    required IconData icon,
    required Color color,
    required String label,
    required String value,
    required Map<String, String> options,
    required ValueChanged<String> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
        ),
        child: ListTile(
          dense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 14),
          leading: Icon(icon, color: color, size: 20),
          title: Text(label, style: const TextStyle(
            color: AppColors.textPrimary, fontSize: 14)),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                options[value] ?? value,
                style: TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.w500),
              ),
              const SizedBox(width: 4),
              Icon(Icons.chevron_right, size: 18, color: AppColors.textTertiary),
            ],
          ),
          onTap: () => _showServicePicker(
            label: label,
            color: color,
            value: value,
            options: options,
            onChanged: onChanged,
          ),
        ),
      ),
    );
  }

  void _showServicePicker({
    required String label,
    required Color color,
    required String value,
    required Map<String, String> options,
    required ValueChanged<String> onChanged,
  }) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(label, style: AppTextStyles.heading),
              ),
            ),
            const Divider(color: AppColors.border, height: 1),
            ...options.entries.map((e) {
              final selected = e.key == value;
              return ListTile(
                title: Text(e.value, style: TextStyle(
                  color: selected ? color : AppColors.textPrimary,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                  fontSize: 14,
                )),
                trailing: selected
                    ? Icon(Icons.check_circle, color: color, size: 20)
                    : null,
                onTap: () {
                  onChanged(e.key);
                  Navigator.pop(ctx);
                },
              );
            }),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _buildAccountRow({
    required IconData icon,
    required Color color,
    required String label,
    required String subtitle,
    required bool connected,
    required VoidCallback onConnect,
    required VoidCallback onDisconnect,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
        ),
        child: ListTile(
          dense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 14),
          leading: Icon(icon, color: color, size: 20),
          title: Text(label, style: const TextStyle(
            color: AppColors.textPrimary, fontSize: 14)),
          subtitle: Text(subtitle, style: const TextStyle(
            color: AppColors.textTertiary, fontSize: 11)),
          trailing: connected
              ? GestureDetector(
                  onTap: onDisconnect,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: Colors.red.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Text('Déconnecter',
                        style: TextStyle(color: Colors.red, fontSize: 12, fontWeight: FontWeight.w500)),
                  ),
                )
              : GestureDetector(
                  onTap: onConnect,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text('Connecter',
                        style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w500)),
                  ),
                ),
        ),
      ),
    );
  }

  Widget _buildToggle({
    required IconData icon,
    required String label,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
        ),
        child: SwitchListTile(
          dense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 14),
          secondary: Icon(icon, color: AppColors.textSecondary, size: 20),
          title: Text(label, style: const TextStyle(
            color: AppColors.textPrimary, fontSize: 14)),
          subtitle: Text(subtitle, style: const TextStyle(
            color: AppColors.textTertiary, fontSize: 11)),
          value: value,
          activeTrackColor: AppColors.accent.withValues(alpha: 0.3),
          activeThumbColor: AppColors.accent,
          onChanged: onChanged,
        ),
      ),
    );
  }
}

void showSpotifySetup(BuildContext context) {
  final controller = TextEditingController(text: SettingsService().spotifyClientId);
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: const Color(0xFF1A1A1A),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  const Text('Connexion Spotify',
                      style: TextStyle(color: Color(0xFFEEEEEE), fontSize: 18, fontWeight: FontWeight.w700)),
                  const SizedBox(width: 8),
                  const Text('- 6 min',
                      style: TextStyle(color: Color(0xFF888888), fontSize: 12)),
                ],
              ),
              const SizedBox(height: 6),
              const Text(
                'Créez une app Spotify Developer pour obtenir votre Client ID.',
                style: TextStyle(color: Color(0xFF888888), fontSize: 13),
              ),
              const SizedBox(height: 20),
              _spotifySetupStep('1',
                  'Rendez-vous sur le dashboard Spotify Developer et connectez-vous avec votre compte Spotify.',
                  buttonLabel: 'Ouvrir le dashboard',
                  buttonUrl: 'https://developer.spotify.com/dashboard'),
              _spotifySetupStep('2',
                  'Cliquez "Create App". Remplissez un nom, cochez "Web API", puis cliquez "Save".'),
              _spotifySetupStep('3',
                  'Dans les Settings de l\'app, ajoutez ce Redirect URI exactement :',
                  highlight: 'cobalttask://spotify-callback'),
              _spotifySetupStep('4',
                  'Dans "Settings" → "User Management", ajoutez l\'email de votre compte Spotify.'),
              _spotifySetupStep('5',
                  'Copiez le Client ID affiché en haut des Settings de l\'app et collez-le ci-dessous.'),
              const SizedBox(height: 20),
              TextField(
                controller: controller,
                style: const TextStyle(color: Color(0xFFEEEEEE), fontSize: 14),
                decoration: InputDecoration(
                  labelText: 'Client ID Spotify',
                  labelStyle: const TextStyle(color: Color(0xFF888888), fontSize: 13),
                  hintText: 'ex: a1b2c3d4e5f6g7h8i9...',
                  hintStyle: const TextStyle(color: Color(0xFF555555), fontSize: 12),
                  filled: true,
                  fillColor: const Color(0xFF111111),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: Color(0xFF333333)),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: Color(0xFF333333)),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: Color(0xFF1DB954)),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () {
                    final id = controller.text.trim();
                    if (id.isNotEmpty) {
                      SettingsService().spotifyClientId = id;
                      Navigator.pop(ctx);
                      AudioService().connectSpotify();
                    }
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF1DB954),
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  child: const Text('Autoriser l\'accès',
                      style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

Widget _spotifySetupStep(String number, String text,
    {String? highlight, String? buttonLabel, String? buttonUrl}) {
  return Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 22,
          height: 22,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: const Color(0xFF1DB954).withValues(alpha: 0.15),
            shape: BoxShape.circle,
          ),
          child: Text(number,
              style: const TextStyle(
                  color: Color(0xFF1DB954), fontSize: 11, fontWeight: FontWeight.bold)),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(text,
                  style: const TextStyle(
                      color: Color(0xFFCCCCCC), fontSize: 13, height: 1.4)),
              if (highlight != null) ...[
                const SizedBox(height: 6),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: const Color(0xFF111111),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: const Color(0xFF333333)),
                  ),
                  child: Text(highlight,
                      style: const TextStyle(
                          color: Color(0xFF1DB954),
                          fontSize: 12,
                          fontFamily: 'monospace',
                          letterSpacing: 0.3)),
                ),
              ],
              if (buttonLabel != null && buttonUrl != null) ...[
                const SizedBox(height: 8),
                GestureDetector(
                  onTap: () => launchUrl(Uri.parse(buttonUrl),
                      mode: LaunchMode.externalApplication),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1DB954).withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFF1DB954).withValues(alpha: 0.4)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.open_in_new, color: Color(0xFF1DB954), size: 14),
                        const SizedBox(width: 6),
                        Text(buttonLabel,
                            style: const TextStyle(
                                color: Color(0xFF1DB954),
                                fontSize: 12,
                                fontWeight: FontWeight.w600)),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    ),
  );
}

void showNavigationApiSetup(BuildContext context) {
  final mapsController = TextEditingController(text: SettingsService().googleMapsApiKey);
  final geminiController = TextEditingController(text: SettingsService().geminiApiKey);

  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: const Color(0xFF1A1A1A),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Briefing vocal navigation',
                  style: TextStyle(color: Color(0xFFEEEEEE), fontSize: 18, fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              const Text(
                'Avant d\'ouvrir Maps, Cobalt calcule le trajet et le résume à voix haute. Deux clés Google sont nécessaires.',
                style: TextStyle(color: Color(0xFF888888), fontSize: 13),
              ),
              const SizedBox(height: 20),
              _navApiStep('1', 'Ouvrez Google Cloud Console et activez les APIs "Directions API" et "Generative Language API" sur votre projet.',
                  buttonLabel: 'Ouvrir Cloud Console',
                  buttonUrl: 'https://console.cloud.google.com/apis/library'),
              _navApiStep('2', 'Allez dans "APIs & Services" → "Credentials" → "Create credentials" → "API key". Créez deux clés (ou une seule avec les deux APIs activées).'),
              _navApiStep('3', 'Pour la clé Gemini, vous pouvez aussi utiliser AI Studio (plus simple).',
                  buttonLabel: 'Ouvrir AI Studio',
                  buttonUrl: 'https://aistudio.google.com/apikey'),
              const SizedBox(height: 4),
              _navApiKeyField(
                label: 'Google Maps API Key',
                hint: 'AIza...',
                controller: mapsController,
                color: const Color(0xFF4285F4),
              ),
              const SizedBox(height: 12),
              _navApiKeyField(
                label: 'Gemini API Key',
                hint: 'AIza...',
                controller: geminiController,
                color: const Color(0xFF7B4FFF),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () {
                    SettingsService().googleMapsApiKey = mapsController.text.trim();
                    SettingsService().geminiApiKey = geminiController.text.trim();
                    Navigator.pop(ctx);
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF34A853),
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  child: const Text('Enregistrer',
                      style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

Widget _navApiStep(String number, String text, {String? buttonLabel, String? buttonUrl}) {
  return Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 22,
          height: 22,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: const Color(0xFF34A853).withValues(alpha: 0.15),
            shape: BoxShape.circle,
          ),
          child: Text(number,
              style: const TextStyle(color: Color(0xFF34A853), fontSize: 11, fontWeight: FontWeight.bold)),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(text,
                  style: const TextStyle(color: Color(0xFFCCCCCC), fontSize: 13, height: 1.4)),
              if (buttonLabel != null && buttonUrl != null) ...[
                const SizedBox(height: 8),
                GestureDetector(
                  onTap: () => launchUrl(Uri.parse(buttonUrl),
                      mode: LaunchMode.externalApplication),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                    decoration: BoxDecoration(
                      color: const Color(0xFF34A853).withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFF34A853).withValues(alpha: 0.4)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.open_in_new, color: Color(0xFF34A853), size: 14),
                        const SizedBox(width: 6),
                        Text(buttonLabel,
                            style: const TextStyle(
                                color: Color(0xFF34A853),
                                fontSize: 12,
                                fontWeight: FontWeight.w600)),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    ),
  );
}

Widget _navApiKeyField({
  required String label,
  required String hint,
  required TextEditingController controller,
  required Color color,
}) {
  return TextField(
    controller: controller,
    style: const TextStyle(color: Color(0xFFEEEEEE), fontSize: 13),
    decoration: InputDecoration(
      labelText: label,
      labelStyle: TextStyle(color: color.withValues(alpha: 0.8), fontSize: 13),
      hintText: hint,
      hintStyle: const TextStyle(color: Color(0xFF555555), fontSize: 12),
      filled: true,
      fillColor: const Color(0xFF111111),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: Color(0xFF333333)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: Color(0xFF333333)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: color),
      ),
    ),
  );
}

// ---------------------------------------------------------------------------
// NOTION SETUP
// ---------------------------------------------------------------------------

void showNotionSetup(BuildContext context) {
  final tokenController = TextEditingController(text: SettingsService().notionToken);
  final pageController = TextEditingController(text: SettingsService().notionPageId);

  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: const Color(0xFF1A1A1A),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  const Text('Connexion Notion',
                      style: TextStyle(
                          color: Color(0xFFEEEEEE),
                          fontSize: 18,
                          fontWeight: FontWeight.w700)),
                  const SizedBox(width: 8),
                  const Text('- 3 min',
                      style: TextStyle(color: Color(0xFF888888), fontSize: 12)),
                ],
              ),
              const SizedBox(height: 6),
              const Text(
                'Vos mémos vocaux seront envoyés automatiquement dans une page Notion.',
                style: TextStyle(color: Color(0xFF888888), fontSize: 13),
              ),
              const SizedBox(height: 20),
              _notionSetupStep('1',
                  'Créez une intégration sur Notion (connexions internes).',
                  buttonLabel: 'Ouvrir notion.so/my-integrations',
                  buttonUrl: 'https://www.notion.so/my-integrations'),
              _notionSetupStep('2',
                  'Cliquez "Nouvelle intégration". Donnez-lui un nom, puis copiez le "Token d\'intégration interne" (commence par secret_...).'),
              _notionSetupStep('3',
                  'Dans Notion, ouvrez ou créez la page où vous voulez recevoir vos mémos.'),
              _notionSetupStep('4',
                  'Cliquez "..." → "Connexions" → ajoutez votre intégration. Copiez ensuite l\'ID depuis l\'URL de la page (les 32 derniers caractères).'),
              const SizedBox(height: 4),
              _notionTextField(
                label: 'Token d\'intégration',
                hint: 'secret_xxx...',
                controller: tokenController,
              ),
              const SizedBox(height: 12),
              _notionTextField(
                label: 'ID de la page cible',
                hint: 'abc123def456... (depuis l\'URL)',
                controller: pageController,
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () {
                    final token = tokenController.text.trim();
                    final pageId = pageController.text.trim();
                    if (token.isNotEmpty && pageId.isNotEmpty) {
                      SettingsService().notionToken = token;
                      SettingsService().notionPageId = pageId;
                      Navigator.pop(ctx);
                    }
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFCCCCCC),
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                  child: const Text('Enregistrer',
                      style:
                          TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

Widget _notionSetupStep(String number, String text,
    {String? buttonLabel, String? buttonUrl}) {
  return Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 22,
          height: 22,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: const Color(0xFFCCCCCC).withValues(alpha: 0.15),
            shape: BoxShape.circle,
          ),
          child: Text(number,
              style: const TextStyle(
                  color: Color(0xFFCCCCCC),
                  fontSize: 11,
                  fontWeight: FontWeight.bold)),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(text,
                  style: const TextStyle(
                      color: Color(0xFFCCCCCC), fontSize: 13, height: 1.4)),
              if (buttonLabel != null && buttonUrl != null) ...[
                const SizedBox(height: 8),
                GestureDetector(
                  onTap: () => launchUrl(Uri.parse(buttonUrl),
                      mode: LaunchMode.externalApplication),
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                    decoration: BoxDecoration(
                      color: const Color(0xFFCCCCCC).withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                          color: const Color(0xFFCCCCCC).withValues(alpha: 0.35)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.open_in_new,
                            color: Color(0xFFCCCCCC), size: 14),
                        const SizedBox(width: 6),
                        Text(buttonLabel,
                            style: const TextStyle(
                                color: Color(0xFFCCCCCC),
                                fontSize: 12,
                                fontWeight: FontWeight.w600)),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    ),
  );
}

Widget _notionTextField({
  required String label,
  required String hint,
  required TextEditingController controller,
}) {
  return TextField(
    controller: controller,
    style: const TextStyle(color: Color(0xFFEEEEEE), fontSize: 13),
    decoration: InputDecoration(
      labelText: label,
      labelStyle:
          const TextStyle(color: Color(0xFF999999), fontSize: 13),
      hintText: hint,
      hintStyle: const TextStyle(color: Color(0xFF555555), fontSize: 12),
      filled: true,
      fillColor: const Color(0xFF111111),
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: Color(0xFF333333)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: Color(0xFF333333)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: Color(0xFFCCCCCC)),
      ),
    ),
  );
}
