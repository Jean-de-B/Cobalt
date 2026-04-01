import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const CobaltFlowApp());
}

class CobaltFlowApp extends StatelessWidget {
  const CobaltFlowApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Cobalt Flow',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0A0A0A),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF00FF88),
          secondary: Color(0xFF00FF88),
          surface: Color(0xFF141414),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF0A0A0A),
          elevation: 0,
          titleTextStyle: TextStyle(
            fontFamily: 'monospace',
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
        cardTheme: const CardThemeData(
          color: Color(0xFF1A1A1A),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(12)),
          ),
        ),
        switchTheme: SwitchThemeData(
          thumbColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) return const Color(0xFF00FF88);
            return const Color(0xFF666666);
          }),
          trackColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) {
              return const Color(0xFF00FF88).withValues(alpha: 0.3);
            }
            return const Color(0xFF333333);
          }),
        ),
      ),
      home: const SettingsScreen(),
    );
  }
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> with WidgetsBindingObserver {
  static const _channel = MethodChannel('com.cobalt_flow/settings');

  String _language = 'fr';
  bool _autoPunctuation = true;
  bool _useGroq = true;
  String _groqApiKey = '';
  bool _serviceEnabled = false;
  final _apiKeyController = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadSettings();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _apiKeyController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _checkServiceStatus();
  }

  Future<void> _loadSettings() async {
    try {
      final settings =
          await _channel.invokeMapMethod<String, dynamic>('getSettings');
      if (settings != null && mounted) {
        setState(() {
          _language = settings['language'] as String? ?? 'fr';
          _autoPunctuation = settings['autoPunctuation'] as bool? ?? true;
          _useGroq = settings['useGroq'] as bool? ?? true;
          _groqApiKey = settings['groqApiKey'] as String? ?? '';
          _apiKeyController.text = _groqApiKey;
        });
      }
    } catch (e) {
      debugPrint('Error loading settings: $e');
    }
    _checkServiceStatus();
  }

  Future<void> _checkServiceStatus() async {
    try {
      final enabled =
          await _channel.invokeMethod<bool>('isRecognitionServiceEnabled') ?? false;
      if (mounted) setState(() => _serviceEnabled = enabled);
    } catch (_) {}
  }

  Future<void> _set(String method, dynamic value) async {
    try {
      await _channel.invokeMethod(method, {'value': value});
    } catch (e) {
      debugPrint('Error $method: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Cobalt Flow'),
        actions: [
          Container(
            margin: const EdgeInsets.only(right: 12),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: _serviceEnabled
                  ? const Color(0xFF00FF88).withValues(alpha: 0.15)
                  : Colors.orange.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _serviceEnabled ? Icons.check_circle : Icons.info_outline,
                  size: 14,
                  color: _serviceEnabled ? const Color(0xFF00FF88) : Colors.orange,
                ),
                const SizedBox(width: 4),
                Text(
                  _serviceEnabled ? 'Actif' : 'Non configuré',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    color: _serviceEnabled ? const Color(0xFF00FF88) : Colors.orange,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (!_serviceEnabled) _buildActivationBanner(),
          _sectionTitle('Langue'),
          _buildLanguageSelector(),
          const SizedBox(height: 20),
          _sectionTitle('Moteur de transcription'),
          _buildEngineCard(),
          const SizedBox(height: 20),
          _sectionTitle('Post-traitement'),
          _settingSwitch(
            'Ponctuation automatique',
            'Ajoute points, majuscules et virgules',
            _autoPunctuation,
            (v) {
              setState(() => _autoPunctuation = v);
              _set('setAutoPunctuation', v);
            },
          ),
          const SizedBox(height: 20),
          _sectionTitle('Clé API Groq'),
          _buildApiKeyField(),
          const SizedBox(height: 20),
          _buildInfoCard(),
        ],
      ),
    );
  }

  Widget _buildActivationBanner() {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.orange.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.orange.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          const Icon(Icons.mic, color: Colors.orange, size: 28),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Saisie vocale non configurée',
                    style: TextStyle(
                        color: Colors.orange,
                        fontWeight: FontWeight.bold,
                        fontSize: 14)),
                const SizedBox(height: 2),
                Text(
                  'Sélectionnez Cobalt Flow comme service de reconnaissance vocale',
                  style: TextStyle(
                      color: Colors.orange.withValues(alpha: 0.8),
                      fontSize: 12),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: () => _channel.invokeMethod('openVoiceInputSettings'),
            child:
                const Text('CONFIGURER', style: TextStyle(color: Colors.orange)),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        title,
        style: const TextStyle(
          fontFamily: 'monospace',
          fontSize: 12,
          color: Color(0xFF00FF88),
          fontWeight: FontWeight.bold,
          letterSpacing: 1.2,
        ),
      ),
    );
  }

  Widget _buildLanguageSelector() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Row(
          children: [
            _langChip('fr', 'Français'),
            _langChip('en', 'English'),
            _langChip('es', 'Español'),
            _langChip('de', 'Deutsch'),
          ],
        ),
      ),
    );
  }

  Widget _langChip(String code, String label) {
    final sel = _language == code;
    return Expanded(
      child: GestureDetector(
        onTap: () {
          setState(() => _language = code);
          _set('setLanguage', code);
        },
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: sel
                ? const Color(0xFF00FF88).withValues(alpha: 0.15)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            children: [
              Text(code.toUpperCase(),
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color:
                        sel ? const Color(0xFF00FF88) : const Color(0xFF666666),
                  )),
              const SizedBox(height: 2),
              Text(label,
                  style: TextStyle(
                    fontSize: 10,
                    color:
                        sel ? const Color(0xFF00FF88) : const Color(0xFF555555),
                  )),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEngineCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            _settingRow('Groq Whisper (cloud)',
                'Haute qualité, ~1.5s de latence', _useGroq, (v) {
              setState(() => _useGroq = v);
              _set('setUseGroq', v);
            }),
            const Divider(color: Color(0xFF333333), height: 16),
            Row(
              children: [
                const Icon(Icons.info_outline,
                    size: 14, color: Color(0xFF555555)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _useGroq
                        ? 'Le texte apparaît mot par mot pendant la dictée'
                        : 'Fallback local — qualité inférieure, zéro latence réseau',
                    style: const TextStyle(
                        fontSize: 11, color: Color(0xFF555555)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _settingSwitch(
      String t, String s, bool v, ValueChanged<bool> cb) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: _settingRow(t, s, v, cb),
      ),
    );
  }

  Widget _settingRow(
      String t, String s, bool v, ValueChanged<bool> cb) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(t, style: const TextStyle(color: Colors.white, fontSize: 14)),
              const SizedBox(height: 2),
              Text(s,
                  style:
                      const TextStyle(color: Color(0xFF666666), fontSize: 11)),
            ],
          ),
        ),
        Switch(value: v, onChanged: cb),
      ],
    );
  }

  Widget _buildApiKeyField() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _apiKeyController,
              style: const TextStyle(
                  fontFamily: 'monospace', fontSize: 13, color: Colors.white),
              obscureText: true,
              decoration: InputDecoration(
                hintText: 'gsk_...',
                hintStyle: const TextStyle(color: Color(0xFF444444)),
                border:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: Color(0xFF333333)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: Color(0xFF00FF88)),
                ),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                isDense: true,
                suffixIcon: IconButton(
                  icon: const Icon(Icons.save,
                      color: Color(0xFF00FF88), size: 20),
                  onPressed: () {
                    final key = _apiKeyController.text.trim();
                    setState(() => _groqApiKey = key);
                    _set('setGroqApiKey', key);
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Clé API sauvegardée'),
                        backgroundColor: Color(0xFF1A1A1A),
                        duration: Duration(seconds: 2),
                      ),
                    );
                  },
                ),
              ),
              onSubmitted: (v) {
                setState(() => _groqApiKey = v.trim());
                _set('setGroqApiKey', v.trim());
              },
            ),
            const SizedBox(height: 8),
            Text(
              _groqApiKey.isEmpty
                  ? 'Obtenez une clé sur console.groq.com'
                  : 'Clé configurée (${_groqApiKey.substring(0, _groqApiKey.length.clamp(0, 8))}...)',
              style: TextStyle(
                fontSize: 11,
                color:
                    _groqApiKey.isEmpty ? Colors.orange : const Color(0xFF00FF88),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Comment utiliser',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            _step('1',
                'Ouvrez l\'app Cobalt Flow et configurez votre clé API Groq'),
            _step('2',
                'Allez dans Paramètres → Gestion générale → Langue et saisie → Saisie vocale'),
            _step('3',
                'Sélectionnez "Cobalt Flow" comme service de reconnaissance vocale'),
            _step('4',
                'Utilisez le bouton micro 🎤 du clavier Samsung — Cobalt transcrit via Groq'),
          ],
        ),
      ),
    );
  }

  Widget _step(String n, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 20,
            height: 20,
            decoration: BoxDecoration(
              color: const Color(0xFF00FF88).withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Center(
              child: Text(n,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                    color: Color(0xFF00FF88),
                    fontWeight: FontWeight.bold,
                  )),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text,
                style:
                    const TextStyle(fontSize: 12, color: Color(0xFF999999))),
          ),
        ],
      ),
    );
  }
}
