import 'dart:typed_data';

/// =============================================================================
/// adpcm_decoder.dart
/// =============================================================================
/// Décodeur IMA ADPCM (Intel/DVI) vers PCM 16-bit.
///
/// L'algorithme IMA ADPCM compresse l'audio avec un ratio de 4:1 en encodant
/// chaque échantillon sur 4 bits au lieu de 16. Le décodage utilise des tables
/// de quantification standardisées pour reconstruire le signal PCM original.
///
/// Flux de données:
/// 1. Réception des données BLE (Header CVOX 34 bytes + ADPCM)
/// 2. Parsing du header pour extraire les paramètres initiaux
/// 3. Décodage ADPCM → PCM 16-bit
/// 4. Encapsulation dans un conteneur WAV (header 44 bytes + PCM)
/// =============================================================================

/// -----------------------------------------------------------------------------
/// TABLES DE QUANTIFICATION IMA ADPCM
/// -----------------------------------------------------------------------------
/// Ces tables sont standardisées et identiques à celles du firmware nRF52840.

/// Table des pas de quantification (step table)
/// Index: 0-88, représente l'amplitude du pas actuel
const List<int> _stepTable = [
  7, 8, 9, 10, 11, 12, 13, 14,
  16, 17, 19, 21, 23, 25, 28, 31,
  34, 37, 41, 45, 50, 55, 60, 66,
  73, 80, 88, 97, 107, 118, 130, 143,
  157, 173, 190, 209, 230, 253, 279, 307,
  337, 371, 408, 449, 494, 544, 598, 658,
  724, 796, 876, 963, 1060, 1166, 1282, 1411,
  1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024,
  3327, 3660, 4026, 4428, 4871, 5358, 5894, 6484,
  7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899,
  15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794,
  32767,
];

/// Table d'ajustement de l'index (index table)
/// Indexée par la valeur du nibble (0-15), indique le décalage de l'index
const List<int> _indexTable = [
  -1, -1, -1, -1, 2, 4, 6, 8,
  -1, -1, -1, -1, 2, 4, 6, 8,
];

/// -----------------------------------------------------------------------------
/// STRUCTURE DU HEADER CVOX
/// -----------------------------------------------------------------------------
/// Représente les métadonnées audio envoyées par le firmware.

class CvoxHeader {
  /// Magic number ("CVOX")
  final String magic;

  /// Version du format (actuellement 1)
  final int version;

  /// Fréquence d'échantillonnage (Hz)
  final int sampleRate;

  /// Nombre de canaux (1 = mono)
  final int channels;

  /// Bits par échantillon ADPCM (4)
  final int bitsPerSample;

  /// Taille d'un bloc (en échantillons)
  final int blockSize;

  /// Nombre total d'échantillons PCM
  final int totalSamples;

  /// Taille des données ADPCM (en bytes)
  final int dataSize;

  /// Échantillon initial pour le décodeur (predictor)
  final int initialSample;

  /// Index initial du pas de quantification
  final int initialIndex;

  CvoxHeader({
    required this.magic,
    required this.version,
    required this.sampleRate,
    required this.channels,
    required this.bitsPerSample,
    required this.blockSize,
    required this.totalSamples,
    required this.dataSize,
    required this.initialSample,
    required this.initialIndex,
  });

  /// Parse un header CVOX depuis un buffer de bytes
  ///
  /// Structure du header (34 bytes):
  /// - magic[4]: "CVOX"
  /// - version[2]: uint16 little-endian
  /// - sampleRate[2]: uint16 little-endian
  /// - channels[1]: uint8
  /// - bitsPerSample[1]: uint8
  /// - blockSize[2]: uint16 little-endian
  /// - totalSamples[4]: uint32 little-endian
  /// - dataSize[4]: uint32 little-endian
  /// - initialSample[2]: int16 little-endian
  /// - initialIndex[1]: int8
  /// - reserved[1]: padding
  factory CvoxHeader.fromBytes(Uint8List data) {
    if (data.length < 34) {
      throw FormatException(
        'Header CVOX invalide: taille insuffisante (${data.length} < 34 bytes)',
      );
    }

    // Lecture du magic number
    final magic = String.fromCharCodes(data.sublist(0, 4));
    if (magic != 'CVOX') {
      throw FormatException(
        'Header CVOX invalide: magic number incorrect ("$magic" != "CVOX")',
      );
    }

    // Création d'un ByteData pour lecture little-endian
    final byteData = ByteData.sublistView(data);

    return CvoxHeader(
      magic: magic,
      version: byteData.getUint16(4, Endian.little),
      sampleRate: byteData.getUint16(6, Endian.little),
      channels: data[8],
      bitsPerSample: data[9],
      blockSize: byteData.getUint16(10, Endian.little),
      totalSamples: byteData.getUint32(12, Endian.little),
      dataSize: byteData.getUint32(16, Endian.little),
      initialSample: byteData.getInt16(20, Endian.little),
      initialIndex: data[22].toSigned(8), // int8
    );
  }

  /// Calcule la durée de l'audio en secondes
  double get durationSeconds => totalSamples / sampleRate;

  @override
  String toString() {
    return 'CvoxHeader(version: $version, sampleRate: $sampleRate Hz, '
        'channels: $channels, totalSamples: $totalSamples, '
        'duration: ${durationSeconds.toStringAsFixed(2)}s)';
  }
}

/// -----------------------------------------------------------------------------
/// CLASSE PRINCIPALE: AdpcmDecoder
/// -----------------------------------------------------------------------------
/// Service de décodage IMA ADPCM avec génération de fichiers WAV.

class AdpcmDecoder {
  /// Taille du header CVOX en bytes
  static const int cvoxHeaderSize = 34;

  /// Taille du header WAV en bytes
  static const int wavHeaderSize = 44;

  /// État interne du décodeur
  int _predictor = 0; // Échantillon prédit (accumulateur)
  int _stepIndex = 0; // Index dans la table des pas

  /// Parse les données reçues via BLE et retourne le header + données ADPCM séparés
  ///
  /// [rawData] Les données brutes reçues (header CVOX + données ADPCM)
  ///
  /// Retourne un tuple (CvoxHeader, Uint8List adpcmData)
  (CvoxHeader, Uint8List) parseReceivedData(Uint8List rawData) {
    final header = CvoxHeader.fromBytes(rawData);
    final adpcmData = rawData.sublist(cvoxHeaderSize);
    return (header, adpcmData);
  }

  /// Décode des données IMA ADPCM en échantillons PCM 16-bit signés
  ///
  /// [adpcmData] Les données ADPCM compressées (4 bits par échantillon)
  /// [initialSample] Valeur initiale du prédicteur (depuis le header CVOX)
  /// [initialIndex] Index initial du pas (depuis le header CVOX)
  ///
  /// Retourne une liste d'échantillons PCM 16-bit signés
  ///
  /// Algorithme IMA ADPCM:
  /// 1. Extraire le nibble (4 bits) de l'échantillon
  /// 2. Calculer la différence à partir du pas actuel
  /// 3. Appliquer le signe et ajouter au prédicteur
  /// 4. Mettre à jour l'index du pas
  /// 5. Clamper le résultat dans [-32768, 32767]
  List<int> decode(Uint8List adpcmData, int initialSample, int initialIndex) {
    // Initialisation de l'état du décodeur
    _predictor = initialSample;
    _stepIndex = initialIndex.clamp(0, 88);

    // Chaque byte contient 2 échantillons (2 nibbles de 4 bits)
    final pcmSamples = <int>[];

    for (int i = 0; i < adpcmData.length; i++) {
      final byte = adpcmData[i];

      // Nibble bas (bits 0-3) = premier échantillon
      final lowNibble = byte & 0x0F;
      pcmSamples.add(_decodeNibble(lowNibble));

      // Nibble haut (bits 4-7) = deuxième échantillon
      final highNibble = (byte >> 4) & 0x0F;
      pcmSamples.add(_decodeNibble(highNibble));
    }

    return pcmSamples;
  }

  /// Décode un seul nibble (4 bits) en échantillon PCM
  ///
  /// [nibble] Valeur 4 bits (0-15)
  ///
  /// Structure du nibble:
  /// - Bit 3 (MSB): signe (1 = négatif)
  /// - Bits 0-2: magnitude (0-7)
  int _decodeNibble(int nibble) {
    // Récupérer le pas actuel
    final step = _stepTable[_stepIndex];

    // Calcul de la différence à partir de la magnitude (bits 0-2)
    // diff = (nibble + 0.5) * step / 4
    // Optimisé en: diff = step/8 + step/4*(bit2) + step/2*(bit1) + step*(bit0)
    int diff = step >> 3; // step / 8 (terme de base)

    if (nibble & 0x04 != 0) diff += step; // bit 2
    if (nibble & 0x02 != 0) diff += step >> 1; // bit 1
    if (nibble & 0x01 != 0) diff += step >> 2; // bit 0

    // Appliquer le signe (bit 3)
    if (nibble & 0x08 != 0) {
      _predictor -= diff;
    } else {
      _predictor += diff;
    }

    // Clamper dans la plage 16-bit signée
    _predictor = _predictor.clamp(-32768, 32767);

    // Mettre à jour l'index du pas
    _stepIndex += _indexTable[nibble];
    _stepIndex = _stepIndex.clamp(0, 88);

    return _predictor;
  }

  /// Convertit des échantillons PCM 16-bit en fichier WAV complet
  ///
  /// [pcmSamples] Liste d'échantillons PCM 16-bit signés
  /// [sampleRate] Fréquence d'échantillonnage (défaut: 16000 Hz)
  /// [channels] Nombre de canaux (défaut: 1 = mono)
  ///
  /// Retourne un Uint8List contenant le fichier WAV complet (header + données)
  ///
  /// Structure du fichier WAV:
  /// - RIFF header (12 bytes)
  /// - fmt chunk (24 bytes)
  /// - data chunk header (8 bytes)
  /// - PCM data (variable)
  Uint8List createWavFile(
    List<int> pcmSamples, {
    int sampleRate = 16000,
    int channels = 1,
  }) {
    const bitsPerSample = 16;
    final byteRate = sampleRate * channels * (bitsPerSample ~/ 8);
    final blockAlign = channels * (bitsPerSample ~/ 8);
    final dataSize = pcmSamples.length * 2; // 2 bytes par échantillon
    final fileSize = wavHeaderSize + dataSize - 8; // -8 pour RIFF header

    // Buffer pour le fichier WAV complet
    final wavData = ByteData(wavHeaderSize + dataSize);
    int offset = 0;

    // --- RIFF Header (12 bytes) ---
    // "RIFF" chunk ID
    wavData.setUint8(offset++, 0x52); // 'R'
    wavData.setUint8(offset++, 0x49); // 'I'
    wavData.setUint8(offset++, 0x46); // 'F'
    wavData.setUint8(offset++, 0x46); // 'F'

    // Taille du fichier - 8 (little-endian)
    wavData.setUint32(offset, fileSize, Endian.little);
    offset += 4;

    // "WAVE" format
    wavData.setUint8(offset++, 0x57); // 'W'
    wavData.setUint8(offset++, 0x41); // 'A'
    wavData.setUint8(offset++, 0x56); // 'V'
    wavData.setUint8(offset++, 0x45); // 'E'

    // --- fmt Chunk (24 bytes) ---
    // "fmt " chunk ID
    wavData.setUint8(offset++, 0x66); // 'f'
    wavData.setUint8(offset++, 0x6D); // 'm'
    wavData.setUint8(offset++, 0x74); // 't'
    wavData.setUint8(offset++, 0x20); // ' '

    // Taille du chunk fmt (16 pour PCM)
    wavData.setUint32(offset, 16, Endian.little);
    offset += 4;

    // Format audio (1 = PCM)
    wavData.setUint16(offset, 1, Endian.little);
    offset += 2;

    // Nombre de canaux
    wavData.setUint16(offset, channels, Endian.little);
    offset += 2;

    // Fréquence d'échantillonnage
    wavData.setUint32(offset, sampleRate, Endian.little);
    offset += 4;

    // Byte rate (octets par seconde)
    wavData.setUint32(offset, byteRate, Endian.little);
    offset += 4;

    // Block align (octets par bloc)
    wavData.setUint16(offset, blockAlign, Endian.little);
    offset += 2;

    // Bits par échantillon
    wavData.setUint16(offset, bitsPerSample, Endian.little);
    offset += 2;

    // --- data Chunk ---
    // "data" chunk ID
    wavData.setUint8(offset++, 0x64); // 'd'
    wavData.setUint8(offset++, 0x61); // 'a'
    wavData.setUint8(offset++, 0x74); // 't'
    wavData.setUint8(offset++, 0x61); // 'a'

    // Taille des données
    wavData.setUint32(offset, dataSize, Endian.little);
    offset += 4;

    // --- Données PCM (little-endian 16-bit signed) ---
    for (final sample in pcmSamples) {
      wavData.setInt16(offset, sample, Endian.little);
      offset += 2;
    }

    return wavData.buffer.asUint8List();
  }

  /// Méthode combinée: décode les données BLE et retourne un fichier WAV
  ///
  /// [rawBleData] Données brutes reçues via BLE (header CVOX + ADPCM)
  ///
  /// Retourne un tuple (Uint8List wavFile, CvoxHeader header)
  ///
  /// Usage typique:
  /// ```dart
  /// final decoder = AdpcmDecoder();
  /// final (wavFile, header) = decoder.decodeToWav(bleData);
  /// await File('note.wav').writeAsBytes(wavFile);
  /// ```
  (Uint8List, CvoxHeader) decodeToWav(Uint8List rawBleData) {
    // 1. Parser le header et extraire les données ADPCM
    final (header, adpcmData) = parseReceivedData(rawBleData);

    // 2. Décoder ADPCM → PCM
    final pcmSamples = decode(
      adpcmData,
      header.initialSample,
      header.initialIndex,
    );

    // 3. Créer le fichier WAV
    final wavFile = createWavFile(
      pcmSamples,
      sampleRate: header.sampleRate,
      channels: header.channels,
    );

    return (wavFile, header);
  }
}
