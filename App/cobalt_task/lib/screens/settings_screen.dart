import 'package:flutter/material.dart';
import '../constants/app_constants.dart';
import '../services/settings_service.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _settings = SettingsService();

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
