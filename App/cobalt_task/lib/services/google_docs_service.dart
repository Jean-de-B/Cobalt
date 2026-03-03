import 'package:googleapis/docs/v1.dart' as docs;
import 'package:googleapis/drive/v3.dart' as drive;
import 'google_auth_service.dart';

/// =============================================================================
/// google_docs_service.dart
/// =============================================================================
/// Service Google Docs pour Cobalt Task.
///
/// Synchronise les fiches MEMO vers un document "Journal Cobalt".
/// Chaque mémo est ajouté avec date/heure, titre et contenu.
/// =============================================================================

class GoogleDocsService {
  /// Instance singleton
  static GoogleDocsService? _instance;

  /// Service d'authentification
  final GoogleAuthService _authService;

  /// API Docs
  docs.DocsApi? _docsApi;

  /// API Drive (pour créer/trouver le document)
  drive.DriveApi? _driveApi;

  /// ID du document "Journal Cobalt"
  String? _journalDocId;

  /// Nom du document journal
  static const String _journalName = 'Journal Cobalt';

  /// Constructeur privé
  GoogleDocsService._internal(this._authService);

  /// Factory Singleton
  factory GoogleDocsService(GoogleAuthService authService) {
    _instance ??= GoogleDocsService._internal(authService);
    return _instance!;
  }

  /// Initialise l'API Docs et Drive
  Future<bool> initialize() async {
    if (!_authService.isSignedIn || _authService.authClient == null) {
      // ignore: avoid_print
      print('GOOGLE_DOCS: Non authentifié');
      return false;
    }

    try {
      _docsApi = docs.DocsApi(_authService.authClient!);
      _driveApi = drive.DriveApi(_authService.authClient!);
      await _ensureJournalDocument();
      // ignore: avoid_print
      print('GOOGLE_DOCS: Initialisé avec document $_journalDocId');
      return true;
    } catch (e) {
      // ignore: avoid_print
      print('GOOGLE_DOCS: Erreur initialisation - $e');
      return false;
    }
  }

  /// Crée ou récupère le document "Journal Cobalt"
  Future<void> _ensureJournalDocument() async {
    if (_driveApi == null || _docsApi == null) return;

    try {
      // Chercher le document existant
      final files = await _driveApi!.files.list(
        q: "name='$_journalName' and mimeType='application/vnd.google-apps.document'",
        spaces: 'drive',
      );

      if (files.files?.isNotEmpty == true) {
        _journalDocId = files.files!.first.id;
        // ignore: avoid_print
        print('GOOGLE_DOCS: Document "$_journalName" trouvé');
        return;
      }

      // Créer le document s'il n'existe pas
      final doc = await _docsApi!.documents.create(
        docs.Document(title: _journalName),
      );
      _journalDocId = doc.documentId;

      // Ajouter un titre initial
      await _docsApi!.documents.batchUpdate(
        docs.BatchUpdateDocumentRequest(requests: [
          docs.Request(
            insertText: docs.InsertTextRequest(
              location: docs.Location(index: 1),
              text: '📔 Journal Cobalt\n\nVos mémos vocaux sont sauvegardés ici.\n\n─────────────────────────────\n\n',
            ),
          ),
        ]),
        _journalDocId!,
      );

      // ignore: avoid_print
      print('GOOGLE_DOCS: Document "$_journalName" créé');
    } catch (e) {
      // ignore: avoid_print
      print('GOOGLE_DOCS: Erreur création document - $e');
    }
  }

  /// Ajoute un mémo au journal
  ///
  /// [title] Titre du mémo
  /// [content] Contenu complet (transcription)
  /// [timestamp] Date/heure de l'enregistrement
  ///
  /// Retourne true si succès
  Future<bool> addMemo({
    required String title,
    required String content,
    DateTime? timestamp,
  }) async {
    if (_docsApi == null || _journalDocId == null) {
      // ignore: avoid_print
      print('GOOGLE_DOCS: Service non initialisé');
      return false;
    }

    try {
      final date = timestamp ?? DateTime.now();
      final dateStr = _formatDate(date);

      // Formater l'entrée du mémo
      final memoEntry = '''
📝 $title
$dateStr

$content

─────────────────────────────

''';

      // Obtenir la longueur actuelle du document pour insérer à la fin
      final doc = await _docsApi!.documents.get(_journalDocId!);
      final endIndex = doc.body?.content?.last.endIndex ?? 1;

      // Insérer le mémo à la fin
      await _docsApi!.documents.batchUpdate(
        docs.BatchUpdateDocumentRequest(requests: [
          docs.Request(
            insertText: docs.InsertTextRequest(
              location: docs.Location(index: endIndex - 1),
              text: memoEntry,
            ),
          ),
        ]),
        _journalDocId!,
      );

      // ignore: avoid_print
      print('GOOGLE_DOCS: Mémo "$title" ajouté au journal');
      return true;
    } catch (e) {
      // ignore: avoid_print
      print('GOOGLE_DOCS: Erreur ajout mémo - $e');
      return false;
    }
  }

  /// Formate une date en français
  String _formatDate(DateTime date) {
    const jours = ['Lun', 'Mar', 'Mer', 'Jeu', 'Ven', 'Sam', 'Dim'];
    const mois = ['janv', 'fév', 'mars', 'avr', 'mai', 'juin', 'juil', 'août', 'sept', 'oct', 'nov', 'déc'];

    final jour = jours[date.weekday - 1];
    final m = mois[date.month - 1];
    final heure = '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';

    return '$jour ${date.day} $m ${date.year} à $heure';
  }

  /// Retourne l'URL du document journal
  String? get journalUrl {
    if (_journalDocId == null) return null;
    return 'https://docs.google.com/document/d/$_journalDocId/edit';
  }
}
