# Rapport Technique - Stack IA Cobalt Task

## Architecture Generale du Pipeline Vocal

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         PIPELINE COMPLET                                    │
│                                                                             │
│  Bracelet BLE ──► Audio ADPCM ──► Decodage WAV ──► Transcription ──►       │
│                                                     (Whisper)               │
│                                                                             │
│  ──► Analyse LLM (Llama 3) ──► AiAction (JSON) ──► Dispatch ──► Execution │
│                                                                             │
│  DEUX BRANCHES APRES TRANSCRIPTION :                                        │
│  ┌──────────────────────────┐    ┌──────────────────────────────────┐       │
│  │ Branche 1: ACTIONS       │    │ Branche 2: NOTES/FICHES         │       │
│  │ GroqClient (Llama 3)     │    │ AiSorterService (Llama 3)       │       │
│  │ → JSON d'action          │    │ → Categorisation + resume       │       │
│  │ → Execution immediate    │    │ → Stockage SQLite + fiches      │       │
│  └──────────────────────────┘    └──────────────────────────────────┘       │
└─────────────────────────────────────────────────────────────────────────────┘
```

**Flux de decision** : La transcription passe d'abord par la Branche 1 (GroqClient via VoiceInputProcessor). Si le LLM detecte une action (intent != `none`), l'action est executee et le pipeline s'arrete. Si `intent == none` (memo), le texte passe dans la Branche 2 (AiSorterService) pour categorisation et stockage en fiches thematiques.

---

## 1. Transcription Audio (Speech-to-Text)

### Fichier : `lib/services/transcription_service.dart`

| Parametre     | Valeur                                             |
|---------------|-----------------------------------------------------|
| API           | Groq (compatible OpenAI)                            |
| Modele        | `whisper-large-v3`                                  |
| Endpoint      | `https://api.groq.com/openai/v1/audio/transcriptions` |
| Format input  | WAV 16kHz mono (encode multipart/form-data)         |
| Format output | JSON `{ "text": "..." }`                            |
| Langue        | Forcement `fr` (parametre `language`)               |
| Auth          | Bearer token (cle API dans `.env`)                  |

### Methode principale

```dart
Future<TranscriptionResult> transcribeBytes(
  Uint8List audioBytes, {
  String filename = 'audio.wav',
  String? language,
})
```

- Envoie le WAV en `multipart/form-data` avec le champ `file`
- Parametres : `model=whisper-large-v3`, `response_format=json`, `language=fr`
- Retourne `TranscriptionResult { text, duration, language }`

### Gestion d'erreurs

| Code HTTP | Signification                    |
|-----------|-----------------------------------|
| 401       | Cle API invalide/expiree          |
| 413       | Fichier trop volumineux           |
| 429       | Rate limit atteint                |
| 500+      | Erreur serveur Groq               |

### Strategie de transcription (dans `audio_service.dart`)

Le pipeline utilise une strategie hybride local/cloud :

1. **Sherpa-ONNX** (local, offline) - tente d'abord la transcription locale via Whisper Tiny
2. Si qualite < 60% ou echec → **Groq Whisper** (cloud) en fallback
3. La qualite est evaluee par heuristique : nombre de mots, ratio caracteres speciaux

---

## 2. Analyse LLM - Detection d'Actions (Branche 1)

### Fichier : `lib/services/groq_client.dart`

C'est le coeur du systeme d'interpretation. Il prend une transcription en entree et retourne un JSON structure representant l'action a executer.

| Parametre     | Valeur                                              |
|---------------|------------------------------------------------------|
| API           | Groq Chat Completions                                |
| Modele        | `llama-3.1-8b-instant`                               |
| Endpoint      | `https://api.groq.com/openai/v1/chat/completions`   |
| Temperature   | `0.3` (basse pour coherence)                         |
| Max tokens    | `500`                                                |
| Response mode | `{ "type": "json_object" }` (force JSON)             |

### System Prompt (Few-Shot)

Le prompt systeme est genere dynamiquement avec la date/heure courante pour que le LLM puisse calculer les heures relatives ("demain", "dans 5 minutes", etc.).

```
Assistant vocal francais. Extrait actions en JSON.

Date: YYYY-MM-DD, Heure: HH:MM

REGLES:
- JSON uniquement, pas de texte
- "reasoning" = explication courte
- Heure sans date = aujourd'hui (demain si passee)
- Duree relative = calcule heure exacte

INTENTS: calendar, sms, alarm, timer, system_control, call, messaging,
         message, navigation, media, app_launch, none

system_control types: volume_up/down/set/mute, vibrate/silent/normal,
                      dnd_on/off, wifi_toggle, bluetooth_toggle,
                      flashlight_on/off
messaging apps: whatsapp, telegram, signal, messenger
media types: play, pause, next, previous, stop, play_search
             (avec query et app optionnel)
media apps: spotify, youtube_music, deezer, amazon_music,
            apple_music, soundcloud

FORMAT: {"reasoning":"...", "intent":"...", "params":{...}}
```

### Exemples Few-Shot (integres dans le prompt)

Chaque exemple montre une phrase utilisateur et le JSON attendu en sortie :

| Phrase utilisateur | JSON attendu |
|---|---|
| "Mets un timer de 5 min" | `{"reasoning":"Timer 5 min","intent":"timer","params":{"duration_seconds":300,"label":"Timer"}}` |
| "RDV dentiste demain 14h30" | `{"reasoning":"Calendrier demain","intent":"calendar","params":{"title":"Dentiste","start_time":"YYYY-MM-DDT14:30:00"}}` |
| "SMS a maman: j'arrive" | `{"reasoning":"SMS","intent":"sms","params":{"recipient":"maman","message":"J'arrive"}}` |
| "Reveille-moi a 7h" | `{"reasoning":"Alarme 7h","intent":"alarm","params":{"time":"ISO8601","label":"Reveil"}}` |
| "Son a fond" | `{"reasoning":"Volume max","intent":"system_control","params":{"control_type":"volume_set","value":100}}` |
| "Acheter du lait" | `{"reasoning":"Memo simple","intent":"none","params":{"memo":"Acheter du lait"}}` |
| "Appelle maman" | `{"reasoning":"Appel","intent":"call","params":{"contact":"maman"}}` |
| "WhatsApp a Pierre: en route" | `{"reasoning":"WhatsApp","intent":"messaging","params":{"app":"whatsapp","recipient":"Pierre","message":"En route"}}` |
| "Envoie a Paul que j'arrive" | `{"reasoning":"Message auto","intent":"message","params":{"recipient":"Paul","message":"J'arrive"}}` |
| "Dis a Marie que je serai en retard" | `{"reasoning":"Message auto","intent":"message","params":{"recipient":"Marie","message":"Je serai en retard"}}` |
| "Emmene-moi gare de Lyon" | `{"reasoning":"Navigation","intent":"navigation","params":{"destination":"Gare de Lyon"}}` |
| "Ouvre Instagram" | `{"reasoning":"App","intent":"app_launch","params":{"app_name":"Instagram"}}` |
| "Mets pause" | `{"reasoning":"Pause media","intent":"media","params":{"control_type":"pause"}}` |
| "Joue du jazz sur Spotify" | `{"reasoning":"Musique jazz Spotify","intent":"media","params":{"control_type":"play_search","query":"jazz","app":"spotify"}}` |
| "Mets Dire Straits" | `{"reasoning":"Musique","intent":"media","params":{"control_type":"play_search","query":"Dire Straits"}}` |
| "Allume la lampe" | `{"reasoning":"Lampe torche","intent":"system_control","params":{"control_type":"flashlight_on"}}` |

### Appel API

```dart
final response = await http.post(
  Uri.parse(_baseUrl),
  headers: {
    'Content-Type': 'application/json',
    'Authorization': 'Bearer $_apiKey',
  },
  body: jsonEncode({
    'model': 'llama-3.1-8b-instant',
    'messages': [
      { 'role': 'system', 'content': systemPrompt },
      { 'role': 'user', 'content': transcript },
    ],
    'response_format': { 'type': 'json_object' },
    'temperature': 0.3,
    'max_tokens': 500,
  }),
);
```

### Retry et Rate Limiting

Methode `analyzeWithRetry(transcript, maxRetries: 2)` :

1. Premiere tentative
2. Si erreur 429 (rate limit) → parse `try again in X.XXs` depuis le message d'erreur → attendre X secondes
3. Sinon → backoff exponentiel (1s, 2s, 3s)
4. Apres `maxRetries+1` tentatives → retourne `NoAction` avec le texte en memo (fallback gracieux)

---

## 3. Schema JSON des Actions

### Fichier : `lib/models/ai_action.dart`

Le JSON retourne par le LLM est parse en un objet Dart fortement type via un **Union Pattern** (sealed class).

### Format JSON generique

```json
{
  "reasoning": "Explication courte de l'interpretation",
  "intent": "calendar|sms|alarm|timer|system_control|call|messaging|message|navigation|media|app_launch|none",
  "params": { ... }
}
```

### Schemas par intent

#### `calendar` - Creer un evenement

```json
{
  "reasoning": "Calendrier demain",
  "intent": "calendar",
  "params": {
    "title": "Dentiste",
    "start_time": "2026-02-14T14:30:00",
    "end_time": "2026-02-14T15:30:00",  // optionnel
    "location": "Cabinet Dr. Martin",     // optionnel
    "description": "Controle annuel"      // optionnel
  }
}
```

#### `sms` - Envoyer un SMS

```json
{
  "reasoning": "SMS",
  "intent": "sms",
  "params": {
    "recipient": "maman",
    "message": "J'arrive dans 10 minutes"
  }
}
```

#### `alarm` - Programmer une alarme

```json
{
  "reasoning": "Alarme 7h",
  "intent": "alarm",
  "params": {
    "time": "2026-02-14T07:00:00",
    "label": "Reveil"               // optionnel
  }
}
```

#### `timer` - Lancer un minuteur

```json
{
  "reasoning": "Timer 5 min",
  "intent": "timer",
  "params": {
    "duration_seconds": 300,
    "label": "Timer"                 // optionnel
  }
}
```

Formats de duree acceptes par le parseur : `duration_seconds`, `duration_minutes`, `duration_hours`, ou composants separes `hours`/`minutes`/`seconds`.

#### `system_control` - Controle systeme

```json
{
  "reasoning": "Volume max",
  "intent": "system_control",
  "params": {
    "control_type": "volume_set",
    "value": 100                     // optionnel selon le type
  }
}
```

Types de controle :
- Volume : `volume_up`, `volume_down`, `volume_set`, `volume_mute`
- Modes : `vibrate`, `silent`, `normal`
- DND : `dnd_on`, `dnd_off`
- Connectivite : `wifi_toggle`, `bluetooth_toggle`, `airplane_toggle`
- Eclairage : `flashlight_on`, `flashlight_off`, `brightness_up`, `brightness_down`

#### `call` - Passer un appel

```json
{
  "reasoning": "Appel",
  "intent": "call",
  "params": {
    "contact": "maman",
    "phone_number": "+33612345678", // optionnel
    "app": "whatsapp"               // optionnel (appel via app)
  }
}
```

#### `messaging` - Message via app specifique

```json
{
  "reasoning": "WhatsApp",
  "intent": "messaging",
  "params": {
    "app": "whatsapp",
    "recipient": "Pierre",
    "message": "En route"
  }
}
```

Apps supportees : `whatsapp`, `telegram`, `signal`, `messenger`

#### `message` - Message generique (routage intelligent)

```json
{
  "reasoning": "Message auto",
  "intent": "message",
  "params": {
    "recipient": "Paul",
    "message": "J'arrive"
  }
}
```

**Difference avec `messaging`** : ici l'app n'est PAS specifiee par l'utilisateur. Le systeme determine automatiquement la meilleure app selon :
1. Derniere app par laquelle le contact nous a ecrit (`IncomingHistoryService`)
2. Derniere app utilisee pour ecrire au contact (`ContactHistoryService`)
3. SMS par defaut

#### `navigation` - Lancer un itineraire GPS

```json
{
  "reasoning": "Navigation",
  "intent": "navigation",
  "params": {
    "destination": "Gare de Lyon",
    "mode": "driving"              // optionnel: driving, walking, bicycling, transit
  }
}
```

#### `media` - Controle multimedia

```json
{
  "reasoning": "Musique jazz Spotify",
  "intent": "media",
  "params": {
    "control_type": "play_search",
    "query": "jazz",               // obligatoire pour play_search
    "app": "spotify"               // optionnel
  }
}
```

Types : `play`, `pause`, `next`, `previous`, `stop`, `play_search`
Apps : `spotify`, `youtube_music`, `deezer`, `amazon_music`, `apple_music`, `soundcloud`

#### `app_launch` - Lancer une application

```json
{
  "reasoning": "App",
  "intent": "app_launch",
  "params": {
    "app_name": "Instagram",
    "package_name": "com.instagram.android"  // optionnel
  }
}
```

#### `none` - Memo (pas d'action)

```json
{
  "reasoning": "Memo simple",
  "intent": "none",
  "params": {
    "memo": "Acheter du lait"
  }
}
```

---

## 4. Parsing JSON et Robustesse

### Fichier : `lib/services/json_sanitizer.dart`

Le LLM peut retourner du JSON entoure de texte ou de blocs markdown. Le `JsonSanitizer` nettoie la reponse :

### Pipeline de nettoyage

```
Reponse LLM brute
  │
  ├─ 1. Extraire depuis ```json ... ``` (si markdown)
  ├─ 2. Trouver le premier '{' ou '['
  ├─ 3. Compter les accolades/crochets (gestion imbrication + strings)
  ├─ 4. Extraire la sous-chaine JSON valide
  │
  ▼
JSON propre → jsonDecode() → AiAction.fromJson()
```

### Gestion des accolades dans les strings

```dart
static int _findMatchingClose(String input, int start, String openChar, String closeChar) {
  int depth = 0;
  bool inString = false;
  bool escaped = false;

  for (int i = start; i < input.length; i++) {
    final char = input[i];
    if (char == '"' && !escaped) inString = !inString;
    escaped = (char == '\\' && !escaped);
    if (!inString) {
      if (char == openChar) depth++;
      else if (char == closeChar) {
        depth--;
        if (depth == 0) return i;
      }
    }
  }
  return -1;
}
```

### Corrections automatiques

- Suppression des virgules trailing (`{..., }` → `{... }`)
- Suppression des caracteres de controle (sauf newline/tab)

### Fallback

Si le parsing JSON echoue completement → `NoAction(memo: transcript)` : le texte original est sauvegarde en tant que memo.

---

## 5. Parsing des parametres (Helpers)

### Fichier : `lib/models/ai_action.dart` (section helpers)

#### Parsing de date/heure (`_parseDateTime`)

Accepte plusieurs formats :
- ISO 8601 : `"2026-02-14T14:30:00"`
- Heure seule : `"14:30"` → aujourd'hui (ou demain si passee)
- Relatif : `"demain 14:30"` → lendemain

```dart
DateTime _parseDateTime(dynamic value) {
  // 1. DateTime.tryParse(value) pour ISO 8601
  // 2. RegExp r'^(\d{1,2}):(\d{2})$' pour heure seule
  // 3. RegExp r'demain\s+(\d{1,2}):(\d{2})' pour "demain HH:mm"
  // 4. Fallback: DateTime.now()
}
```

#### Parsing de duree (`_parseDuration`)

Accepte : `duration_seconds`, `duration_minutes`, `duration_hours`, ou composants `hours`+`minutes`+`seconds`.

#### Parsing des types de controle (`_parseControlType`)

Accepte les variantes francaises et anglaises :
- `"volume_up"`, `"volumeup"`, `"augmenter"` → `SystemControlType.volumeUp`
- `"vibrate"`, `"vibreur"` → `SystemControlType.vibrate`
- `"flashlight_on"`, `"torch"`, `"lampe"` → `SystemControlType.flashlightOn`

#### Parsing des types media (`_parseMediaControlType`)

- `"play"`, `"lecture"`, `"jouer"` → `MediaControlType.play`
- `"next"`, `"suivant"`, `"skip"` → `MediaControlType.next`
- `"play_search"`, `"playsearch"`, `"recherche"` → `MediaControlType.playSearch`

---

## 6. Dispatch et Execution des Actions

### Fichier : `lib/services/local_action_dispatcher.dart`

Le dispatcher recoit un `AiAction` et le route vers le bon service Android natif via MethodChannel.

### Table de routage

| Intent | Service | MethodChannel Android |
|---|---|---|
| `calendar` | `LocalCalendarService` | Google Calendar API (via Google Sign-In) |
| `sms` | `LocalSmsService` | `com.cobalt_task/sms` |
| `alarm` | `LocalAlarmService` | `com.cobalt_task/alarm` (ACTION_SET_ALARM) |
| `timer` | `LocalAlarmService` | `com.cobalt_task/alarm` (ACTION_SET_TIMER) |
| `system_control` | `LocalSystemControlService` | `com.cobalt_task/system_control` |
| `call` | `LocalPhoneService` | `com.cobalt_task/phone` (ACTION_CALL) |
| `messaging` | `LocalMessagingService` | Intent WhatsApp/Telegram/Signal/Messenger |
| `message` | Routage intelligent | Determine l'app puis `LocalMessagingService` ou `LocalSmsService` |
| `navigation` | `LocalNavigationService` | Intent Google Maps |
| `media` | `LocalMediaService` | MediaKey OU Spotify Web API (si connecte) |
| `app_launch` | `LocalAppLauncherService` | `com.cobalt_task/app_launcher` |
| `none` | - | Sauvegarde en memo |

### Validation des contacts (securite)

Toutes les actions impliquant un contact (SMS, appel, messagerie) passent par un systeme de validation :

```
1. ValidatedContactsService.resolve("maman")
   ├─ Contact deja valide? → envoyer immediatement
   └─ Non valide? →
      ├─ Recherche dans ContactHistoryService (historique sortant)
      ├─ Recherche dans ContactLookupService (fuzzy match contacts tel)
      └─ Queue PendingValidation → dialog UI pour confirmation
         └─ Utilisateur confirme → mapping permanent ("maman" = "+33612345678")
```

### Routage intelligent des messages generiques (intent `message`)

Quand l'utilisateur dit "Dis a Paul que j'arrive" sans preciser l'app :

```
1. Contact valide? (ValidatedContactsService)
   ├─ NON → queue validation, message PAS envoye
   └─ OUI →
      2. IncomingHistoryService.getLastIncomingApp("Paul")
         → derniere app avec laquelle Paul nous a ecrit
         ├─ "whatsapp" → envoyer via WhatsApp
         ├─ "telegram" → envoyer via Telegram
         └─ null →
            3. ContactHistoryService.findByName("Paul")
               → derniere app qu'on a utilisee pour Paul
               ├─ "signal" → envoyer via Signal
               └─ null → SMS par defaut

      4. Ecran verrouille? → forcer SMS (securite)
```

---

## 7. Analyse LLM - Categorisation des Notes (Branche 2)

### Fichier : `lib/services/ai_sorter_service.dart`

Si l'intent est `none` (memo), le texte passe dans ce second LLM pour categorisation et stockage structure.

| Parametre     | Valeur                      |
|---------------|-----------------------------|
| Modele        | `llama-3.1-8b-instant`      |
| Temperature   | `0.1` (tres deterministe)   |
| Max tokens    | `500`                       |

### System Prompt

```
REPONDS UNIQUEMENT EN JSON. Aucun texte, aucune explication.

CATEGORIES:
- TODO = rappels, taches, choses a faire ("rappelle-moi", "il faut", "je dois")
- SHOPPING = listes de courses, achats ("acheter", "courses", "il me faut")
- EVENT = rendez-vous AVEC quelqu'un a une date/heure precise
- CONTACT = informations sur une personne (nom, telephone, email)
- MEMO = reflexions, idees, pensees (PAS de tache a accomplir)

REGLES:
- "rappelle-moi de..." = TOUJOURS TODO
- "il faut...", "je dois..." = TODO (sauf achat → SHOPPING)
- summary = verbe + action
- todo_due = date/heure si mentionnee
- items = sous-taches (TODO) ou articles (SHOPPING)
- Pour MEMO: sentiment = "idea"|"frustration"|"memory"|"question"|"neutral"
```

### Schema JSON de sortie

```json
{
  "category": "TODO|SHOPPING|EVENT|CONTACT|MEMO",
  "summary": "Titre court",
  "content": "Contenu complet",
  "items": ["item1", "item2"],
  "todo_due": "demain matin",
  "sentiment": "idea|frustration|memory|question|neutral",
  "event_datetime": "vendredi 14h",
  "event_location": "Cabinet Dr. Martin",
  "contact_first_name": "Marie",
  "contact_last_name": "Dupont",
  "contact_phone": "0612345678",
  "contact_email": "marie@example.com",
  "contact_building_code": "1234A"
}
```

### Exemples Few-Shot

| Phrase | Categorie | JSON |
|---|---|---|
| "rappelle-moi de sortir les poubelles" | TODO | `{"category":"TODO","summary":"Sortir les poubelles","items":["sortir les poubelles"],"todo_due":null}` |
| "rappelle-moi de faire des pompes demain matin" | TODO | `{"category":"TODO","summary":"Faire des pompes","items":["faire des pompes"],"todo_due":"demain matin"}` |
| "il faut appeler le plombier lundi" | TODO | `{"category":"TODO","summary":"Appeler le plombier","items":["appeler le plombier"],"todo_due":"lundi"}` |
| "acheter pain lait fromage" | SHOPPING | `{"category":"SHOPPING","summary":"Liste de courses","items":["pain","lait","fromage"]}` |
| "il me faut des piles et du scotch" | SHOPPING | `{"category":"SHOPPING","summary":"Fournitures","items":["piles","scotch"]}` |
| "rdv medecin vendredi 14h" | EVENT | `{"category":"EVENT","summary":"Medecin","event_datetime":"vendredi 14h"}` |
| "Marie 0612345678" | CONTACT | `{"category":"CONTACT","summary":"Marie","contact_first_name":"Marie","contact_phone":"0612345678"}` |
| "idee: utiliser du machine learning" | MEMO | `{"category":"MEMO","summary":"Idee ML","content":"...","sentiment":"idea"}` |
| "j'en ai marre de ce projet" | MEMO | `{"category":"MEMO","summary":"Ras-le-bol projet","content":"...","sentiment":"frustration"}` |

### Fusion automatique des fiches (TitleMatcher)

Quand une note est categorisee, le systeme cherche une fiche existante similaire pour y ajouter la note (au lieu de creer une nouvelle fiche) :

```dart
// Normalisation : minuscules, sans accents, sans caracteres speciaux
TitleMatcher.normalize("Chez le Médecin") → "chez le medecin"

// Similarite : contenance ou mots communs >= 4 lettres
TitleMatcher.areSimilar("Liste de courses", "Courses") → true
TitleMatcher.areSimilar("Dentiste", "RDV Dentiste") → true

// Recherche dans les fiches existantes (meme categorie obligatoire)
TitleMatcher.findMatchingFiche("Courses", NoteCategory.shopping, fiches) → ficheId
```

---

## 8. Union Pattern (Sealed Classes Dart)

### Fichier : `lib/models/ai_action.dart`

L'architecture utilise le pattern **sealed class** de Dart 3 pour garantir l'exhaustivite a la compilation.

```dart
sealed class AiAction {
  final String reasoning;
  final ActionIntent intent;

  factory AiAction.fromJson(Map<String, dynamic> json);

  // Pattern matching exhaustif (erreur compilation si un cas manque)
  T when<T>({
    required T Function(CalendarAction) calendar,
    required T Function(SmsAction) sms,
    required T Function(AlarmAction) alarm,
    required T Function(TimerAction) timer,
    required T Function(SystemControlAction) systemControl,
    required T Function(CallAction) call,
    required T Function(MessagingAction) messaging,
    required T Function(MessageAction) message,
    required T Function(NavigationAction) navigation,
    required T Function(MediaAction) media,
    required T Function(AppLaunchAction) appLaunch,
    required T Function(NoAction) none,
  });
}
```

Classes concretes : `CalendarAction`, `SmsAction`, `AlarmAction`, `TimerAction`, `SystemControlAction`, `CallAction`, `MessagingAction`, `MessageAction`, `NavigationAction`, `MediaAction`, `AppLaunchAction`, `NoAction`.

Utilisation dans le code :

```dart
final (summary, ttsMessage) = actionResult.action.when(
  calendar: (a) => ('Evenement ${a.title}', 'Evenement ajoute'),
  sms: (a) => ('SMS a ${a.recipient}', 'SMS envoye'),
  alarm: (a) => ('Alarme ${a.time}', 'Alarme programmee'),
  media: (a) => ('Musique ${a.controlType}', 'Musique lancee !'),
  // ... tous les cas obligatoires
  none: (a) => (a.memo ?? '', ''),
);
```

---

## 9. Orchestrateur Central

### Fichier : `lib/services/voice_input_processor.dart`

Point d'entree unique qui orchestre tout le pipeline :

```dart
class VoiceInputProcessor {
  Future<VoiceProcessingResult> processVoiceInput(String transcript) async {
    // 1. Analyser avec Groq LLM (retry automatique)
    final action = await _groqClient.analyzeWithRetry(transcript);

    // 2. Executer l'action via le dispatcher Android
    final executionResult = await _dispatcher.dispatch(action);

    // 3. Retourner le resultat complet
    return VoiceProcessingResult(
      transcript: transcript,
      action: action,
      executionResult: executionResult,
      processingTime: stopwatch.elapsed,
    );
  }
}
```

Resultat :

```dart
class VoiceProcessingResult {
  final String transcript;           // Texte transcrit
  final AiAction action;             // Action detectee (type fort)
  final ActionResult? executionResult; // Resultat d'execution Android
  final Duration processingTime;     // Temps total du pipeline
  final String? error;               // Erreur eventuelle
  bool get success => error == null && (executionResult?.success ?? true);
}
```

---

## 10. Diagramme de Sequence Complet

```
Bracelet BLE              AudioService            GroqClient           Dispatcher
     │                         │                       │                    │
     │── audio ADPCM ─────────►│                       │                    │
     │                         │── decode WAV          │                    │
     │                         │── Whisper API ────────►                    │
     │                         │◄── transcription ─────│                    │
     │                         │                       │                    │
     │                         │── VoiceInputProcessor │                    │
     │                         │     │                 │                    │
     │                         │     │── analyze ──────►│                    │
     │                         │     │                 │── POST /chat       │
     │                         │     │                 │   model: llama-3.1 │
     │                         │     │                 │   temp: 0.3        │
     │                         │     │                 │   format: json     │
     │                         │     │◄── AiAction ────│                    │
     │                         │     │                 │                    │
     │                         │     │── dispatch ─────────────────────────►│
     │                         │     │                 │                    │── Android
     │                         │     │                 │                    │   natif
     │                         │     │◄── ActionResult ────────────────────│
     │                         │     │                 │                    │
     │                         │◄── VoiceProcessingResult                  │
     │                         │                       │                    │
     │                         │── TTS feedback        │                    │
     │                         │── Mise a jour DB      │                    │
```

---

## 11. Points d'Amelioration Potentiels

1. **Contexte conversationnel** : Le prompt ne garde pas d'historique des echanges precedents. Ajouter un buffer des N derniers echanges pourrait ameliorer la comprehension ("mets la aussi" apres "joue du jazz").

2. **Prompt caching** : Le system prompt est identique a chaque requete (sauf date/heure). Groq/OpenAI supportent le prompt caching pour reduire la latence.

3. **Modele** : `llama-3.1-8b-instant` est rapide mais peut halluciner sur des requetes ambigues. Un modele plus gros (`llama-3.1-70b`) pourrait etre utilise pour les cas complexes avec retry.

4. **Validation JSON schema** : Actuellement le JSON est parse "best effort". Un schema JSON strict (jsonschema) avec validation permettrait de detecter les reponses malformees plus tot.

5. **Tests unitaires** : Les prompts et le parsing JSON gagneraient a avoir une suite de tests avec des cas limites (dates ambigues, noms de contacts similaires, commandes imbriquees).

---

## 12. Fichiers Cles

| Fichier | Role |
|---|---|
| `lib/services/voice_input_processor.dart` | Orchestrateur pipeline complet |
| `lib/services/groq_client.dart` | Client LLM + prompt few-shot + retry |
| `lib/services/json_sanitizer.dart` | Nettoyage JSON des reponses LLM |
| `lib/models/ai_action.dart` | Modeles d'actions (sealed classes) + parsing |
| `lib/services/local_action_dispatcher.dart` | Routage et execution des actions |
| `lib/services/ai_sorter_service.dart` | Categorisation notes + prompt few-shot |
| `lib/services/transcription_service.dart` | STT Groq Whisper |
| `lib/services/validated_contacts_service.dart` | Validation securisee des contacts |
