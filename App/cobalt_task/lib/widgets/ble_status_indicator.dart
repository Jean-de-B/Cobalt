import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import '../constants/app_constants.dart';
import '../screens/debug_screen.dart';
import '../services/audio_service.dart';
import '../services/dfu_service.dart';

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
          Icons.watch_off,
          'Bluetooth désactivé',
        ),
      BleConnectionState.disconnected => (
          AppColors.bleDisconnected,
          Icons.watch,
          'Montre déconnectée - Appuyez pour scanner',
        ),
      BleConnectionState.scanning => (
          AppColors.bleConnecting,
          Icons.watch,
          'Recherche de la montre...',
        ),
      BleConnectionState.connecting => (
          AppColors.bleConnecting,
          Icons.watch,
          'Connexion en cours...',
        ),
      BleConnectionState.connected => (
          AppColors.bleConnected,
          Icons.watch,
          'Connecté à ${audioService.connectedDeviceName ?? "Cobalt"}',
        ),
      BleConnectionState.syncing => (
          AppColors.bleSyncing,
          Icons.sync,
          'Réception de données...',
        ),
      BleConnectionState.error => (
          Colors.red,
          Icons.watch_off,
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
              ? _AnimatedIcon(icon: icon, color: color, size: 21.6)
              : Icon(icon, color: color, size: 21.6),
        ),
      ),
    );
  }

  void _handleTap(BuildContext context, BleConnectionState state) {
    switch (state) {
      case BleConnectionState.connected:
        _showConnectionMenu(context);
        break;
      default:
        // Toujours ouvrir le picker (scan, connecting, disconnected, disabled, error)
        if (onScanRequested != null) {
          onScanRequested!();
        } else {
          audioService.startBleScan();
        }
        break;
    }
  }

  void _showConnectionMenu(BuildContext context) {
    final fwVersion = audioService.firmwareVersion;
    final deviceName = audioService.connectedDeviceName ?? 'Cobalt';

    // Lancer le browse scan pour afficher les autres montres en dessous
    audioService.startBrowseScan();

    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header : montre + nom + version | MAJ | déconnecter
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
              child: Row(
                children: [
                  const Icon(Icons.watch, color: AppColors.bleConnected, size: 18),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          deviceName,
                          style: const TextStyle(
                            color: AppColors.bleConnected,
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                          ),
                        ),
                        if (fwVersion != null)
                          Text(
                            'v$fwVersion',
                            style: AppTextStyles.metadata.copyWith(fontSize: 11),
                          ),
                      ],
                    ),
                  ),
                  // MAJ firmware
                  GestureDetector(
                    onTap: () {
                      Navigator.pop(sheetContext);
                      audioService.stopBrowseScan();
                      _showDfuDialog(context);
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: AppColors.bleSyncing.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.system_update, size: 14, color: AppColors.bleSyncing),
                          const SizedBox(width: 4),
                          Text('MAJ', style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: AppColors.bleSyncing,
                          )),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Debug firmware
                  GestureDetector(
                    onTap: () {
                      Navigator.pop(sheetContext);
                      audioService.stopBrowseScan();
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => DebugScreen(
                            bleService: audioService.bleServiceInstance,
                          ),
                        ),
                      );
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.orange.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.terminal, size: 14, color: Colors.orange),
                          SizedBox(width: 4),
                          Text('Debug', style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: Colors.orange,
                          )),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Oublier la montre
                  GestureDetector(
                    onTap: () {
                      Navigator.pop(sheetContext);
                      audioService.stopBrowseScan();
                      audioService.disconnectBle();
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.red.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.link_off, size: 14, color: Colors.red),
                          SizedBox(width: 4),
                          Text('Oublier', style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: Colors.red,
                          )),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(color: AppColors.border, height: 1),
            // Autres montres visibles
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Autres appareils à proximité',
                  style: AppTextStyles.metadata.copyWith(fontSize: 11),
                ),
              ),
            ),
            StreamBuilder<List<ScanResult>>(
              stream: audioService.discoveredDevicesStream,
              initialData: audioService.discoveredDevices,
              builder: (context, snapshot) {
                final devices = (snapshot.data ?? [])
                    .where((d) {
                      final name = d.advertisementData.advName.isNotEmpty
                          ? d.advertisementData.advName
                          : d.device.platformName;
                      // Exclure la montre déjà connectée
                      return name != deviceName && name.isNotEmpty;
                    })
                    .toList();

                if (devices.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const SizedBox(
                          width: 12, height: 12,
                          child: CircularProgressIndicator(
                            strokeWidth: 1.5,
                            valueColor: AlwaysStoppedAnimation<Color>(AppColors.textTertiary),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text('Recherche...', style: AppTextStyles.metadata.copyWith(fontSize: 11)),
                      ],
                    ),
                  );
                }

                return ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 160),
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: devices.length,
                    itemBuilder: (context, index) {
                      final result = devices[index];
                      final name = result.advertisementData.advName.isNotEmpty
                          ? result.advertisementData.advName
                          : result.device.platformName;
                      final isCobalt = name.toLowerCase().startsWith('cobalt');

                      return ListTile(
                        dense: true,
                        visualDensity: const VisualDensity(vertical: -2),
                        leading: Icon(
                          isCobalt ? Icons.watch : Icons.bluetooth,
                          size: 18,
                          color: isCobalt ? AppColors.textSecondary : AppColors.textTertiary,
                        ),
                        title: Text(name, style: AppTextStyles.metadata.copyWith(
                          color: isCobalt ? AppColors.textPrimary : AppColors.textSecondary,
                          fontSize: 12,
                        )),
                        trailing: Text('${result.rssi} dBm',
                          style: AppTextStyles.metadata.copyWith(fontSize: 10)),
                        onTap: isCobalt ? () {
                          Navigator.pop(sheetContext);
                          audioService.stopBrowseScan();
                          audioService.connectToBleDevice(result.device, deviceName: name);
                        } : null,
                      );
                    },
                  ),
                );
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    ).whenComplete(() => audioService.stopBrowseScan());
  }

  void _showDfuDialog(BuildContext context) {
    final dfuService = DfuService(audioService.bleServiceInstance);

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => _DfuDialog(dfuService: dfuService),
    );
  }
}

/// Widget icône avec animation de pulsation
class _AnimatedIcon extends StatefulWidget {
  final IconData icon;
  final Color color;
  final double size;

  const _AnimatedIcon({
    required this.icon,
    required this.color,
    this.size = 24,
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
            size: widget.size,
          ),
        );
      },
    );
  }
}

/// Dialog de mise à jour firmware OTA (DFU)
class _DfuDialog extends StatefulWidget {
  final DfuService dfuService;

  const _DfuDialog({required this.dfuService});

  @override
  State<_DfuDialog> createState() => _DfuDialogState();
}

class _DfuDialogState extends State<_DfuDialog> {
  StreamSubscription? _stateSub;
  StreamSubscription? _progressSub;
  StreamSubscription? _statusSub;

  DfuState _state = DfuState.idle;
  double _progress = 0.0;
  String _status = 'Sélectionnez un fichier firmware (.zip)';

  @override
  void initState() {
    super.initState();
    _stateSub = widget.dfuService.stateStream.listen((s) {
      if (mounted) setState(() => _state = s);
    });
    _progressSub = widget.dfuService.progressStream.listen((p) {
      if (mounted) setState(() => _progress = p);
    });
    _statusSub = widget.dfuService.statusStream.listen((s) {
      if (mounted) setState(() => _status = s);
    });
  }

  @override
  void dispose() {
    _stateSub?.cancel();
    _progressSub?.cancel();
    _statusSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.surface,
      title: const Row(
        children: [
          Icon(Icons.system_update, color: AppColors.bleSyncing),
          SizedBox(width: 8),
          Text('Mise à jour firmware', style: AppTextStyles.heading),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_status, style: AppTextStyles.cardBody),
          const SizedBox(height: 16),
          if (_state == DfuState.uploading || _state == DfuState.preparingDevice ||
              _state == DfuState.waitingForDfu) ...[
            LinearProgressIndicator(
              value: _state == DfuState.uploading ? _progress : null,
              backgroundColor: AppColors.border,
              valueColor: const AlwaysStoppedAnimation<Color>(AppColors.bleSyncing),
            ),
            const SizedBox(height: 8),
            if (_state == DfuState.uploading)
              Text(
                '${(_progress * 100).toInt()}%',
                style: AppTextStyles.metadata,
              ),
          ],
          if (_state == DfuState.completed)
            const Row(
              children: [
                Icon(Icons.check_circle, color: AppColors.bleConnected, size: 20),
                SizedBox(width: 8),
                Text('Mise à jour réussie!', style: AppTextStyles.cardBody),
              ],
            ),
          if (_state == DfuState.error)
            Row(
              children: [
                const Icon(Icons.error, color: Colors.red, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.dfuService.errorMessage ?? 'Erreur inconnue',
                    style: AppTextStyles.cardBody.copyWith(color: Colors.red),
                  ),
                ),
              ],
            ),
          if (_state == DfuState.idle) ...[
            const SizedBox(height: 8),
            Text(
              'Placez le fichier cobalt_update.zip\n'
              'dans le dossier Download du téléphone,\n'
              'puis appuyez sur "Lancer".',
              style: AppTextStyles.metadata,
            ),
          ],
        ],
      ),
      actions: [
        if (_state == DfuState.uploading)
          TextButton(
            onPressed: () {
              widget.dfuService.abort();
            },
            child: const Text('Annuler', style: TextStyle(color: Colors.red)),
          ),
        if (_state == DfuState.idle || _state == DfuState.error)
          TextButton(
            onPressed: () {
              widget.dfuService.reset();
              Navigator.pop(context);
            },
            child: const Text('Fermer', style: TextStyle(color: AppColors.textSecondary)),
          ),
        if (_state == DfuState.idle)
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.bleSyncing,
              foregroundColor: Colors.white,
            ),
            onPressed: _startUpdate,
            child: const Text('Lancer'),
          ),
        if (_state == DfuState.completed || _state == DfuState.error)
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.bleConnected,
              foregroundColor: Colors.white,
            ),
            onPressed: () {
              widget.dfuService.reset();
              Navigator.pop(context);
            },
            child: const Text('OK'),
          ),
      ],
    );
  }

  Future<void> _startUpdate() async {
    // Demander la permission d'accès au stockage
    if (Platform.isAndroid) {
      final status = await Permission.manageExternalStorage.request();
      if (!status.isGranted) {
        if (mounted) {
          setState(() {
            _status = 'Permission de stockage refusée.\n\n'
                'Allez dans Paramètres > Applications > Cobalt Task > Permissions\n'
                'et autorisez l\'accès aux fichiers.';
          });
        }
        return;
      }
    }

    // Chemin vers le fichier dans le dossier Download
    const dfuPath = '/storage/emulated/0/Download/cobalt_update.zip';

    // Vérifier que le fichier existe avant de lancer le DFU
    if (!File(dfuPath).existsSync()) {
      if (mounted) {
        setState(() {
          _status = 'Fichier introuvable!\n\n'
              'Placez le fichier cobalt_update.zip\n'
              'dans le dossier Download du téléphone.';
        });
      }
      return;
    }

    await widget.dfuService.startDfu(dfuPath);
  }
}
