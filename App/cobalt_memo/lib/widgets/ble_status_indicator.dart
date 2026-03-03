import 'package:flutter/material.dart';
import '../constants/app_constants.dart';
import '../services/audio_service.dart';

/// =============================================================================
/// ble_status_indicator.dart
/// =============================================================================
/// Widget indicateur de l'état de connexion Bluetooth.
///
/// Affiche une icône avec une couleur correspondant à l'état:
/// - Gris: déconnecté ou Bluetooth désactivé
/// - Orange: scan ou connexion en cours
/// - Vert: connecté
/// - Bleu pulsant: synchronisation de données en cours
/// =============================================================================

class BleStatusIndicator extends StatelessWidget {
  /// Service audio pour accéder à l'état BLE
  final AudioService audioService;

  /// Callback quand l'utilisateur demande un scan (pour ouvrir le device picker)
  final VoidCallback? onScanRequested;

  const BleStatusIndicator({
    super.key,
    required this.audioService,
    this.onScanRequested,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<BleConnectionState>(
      stream: audioService.bleConnectionStateStream,
      initialData: audioService.bleConnectionState,
      builder: (context, snapshot) {
        final state = snapshot.data ?? BleConnectionState.disconnected;
        return _buildIndicator(context, state);
      },
    );
  }

  Widget _buildIndicator(BuildContext context, BleConnectionState state) {
    // Déterminer la couleur et l'icône selon l'état
    final (color, icon, tooltip) = switch (state) {
      BleConnectionState.disabled => (
          AppColors.bleDisconnected,
          Icons.bluetooth_disabled,
          'Bluetooth désactivé',
        ),
      BleConnectionState.disconnected => (
          AppColors.bleDisconnected,
          Icons.bluetooth,
          'Déconnecté - Appuyez pour scanner',
        ),
      BleConnectionState.scanning => (
          AppColors.bleConnecting,
          Icons.bluetooth_searching,
          'Recherche en cours...',
        ),
      BleConnectionState.connecting => (
          AppColors.bleConnecting,
          Icons.bluetooth_connected,
          'Connexion en cours...',
        ),
      BleConnectionState.connected => (
          AppColors.bleConnected,
          Icons.bluetooth_connected,
          'Connecté à Cobalt Voice',
        ),
      BleConnectionState.syncing => (
          AppColors.bleSyncing,
          Icons.sync,
          'Réception de données...',
        ),
      BleConnectionState.error => (
          Colors.red,
          Icons.bluetooth_disabled,
          'Erreur de connexion',
        ),
    };

    // Animation pour les états de transition
    final isAnimated = state == BleConnectionState.scanning ||
        state == BleConnectionState.connecting ||
        state == BleConnectionState.syncing;

    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: () => _handleTap(context, state),
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.all(8.0),
          child: isAnimated
              ? _AnimatedIcon(icon: icon, color: color)
              : Icon(icon, color: color, size: 24),
        ),
      ),
    );
  }

  void _handleTap(BuildContext context, BleConnectionState state) {
    switch (state) {
      case BleConnectionState.disabled:
        // Afficher un message pour activer le Bluetooth
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Veuillez activer le Bluetooth',
              style: TextStyle(fontFamily: 'monospace'),
            ),
            backgroundColor: AppColors.surface,
          ),
        );
        break;
      case BleConnectionState.disconnected:
      case BleConnectionState.error:
        // Ouvrir le device picker (ou scan direct si pas de callback)
        if (onScanRequested != null) {
          onScanRequested!();
        } else {
          audioService.startBleScan();
        }
        break;
      case BleConnectionState.connected:
        // Afficher les options de déconnexion
        _showConnectionMenu(context);
        break;
      default:
        // Scan ou connexion en cours, ne rien faire
        break;
    }
  }

  void _showConnectionMenu(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(
                Icons.bluetooth_connected,
                color: AppColors.bleConnected,
              ),
              title: const Text(
                'Cobalt Voice',
                style: AppTextStyles.noteText,
              ),
              subtitle: const Text(
                'Connecté',
                style: AppTextStyles.metadata,
              ),
            ),
            const Divider(color: AppColors.border),
            ListTile(
              leading: const Icon(
                Icons.bluetooth_disabled,
                color: AppColors.textSecondary,
              ),
              title: const Text(
                'Déconnecter',
                style: AppTextStyles.noteText,
              ),
              onTap: () {
                audioService.disconnectBle();
                Navigator.pop(context);
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// Widget icône avec animation de pulsation
class _AnimatedIcon extends StatefulWidget {
  final IconData icon;
  final Color color;

  const _AnimatedIcon({
    required this.icon,
    required this.color,
  });

  @override
  State<_AnimatedIcon> createState() => _AnimatedIconState();
}

class _AnimatedIconState extends State<_AnimatedIcon>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 1000),
      vsync: this,
    )..repeat(reverse: true);

    _animation = Tween<double>(begin: 0.5, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) {
        return Opacity(
          opacity: _animation.value,
          child: Icon(
            widget.icon,
            color: widget.color,
            size: 24,
          ),
        );
      },
    );
  }
}
