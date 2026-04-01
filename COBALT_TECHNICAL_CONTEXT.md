# COBALT -- Contexte Technique Complet

> Ce document est un prompt de contexte. Donne-le a Claude pour qu'il comprenne l'ensemble du projet Cobalt (firmware + apps) avant de travailler sur le code.

---

## 1. VUE D'ENSEMBLE

Cobalt est un **bracelet vocal connecte** compose de :

- **Firmware** (`Firmware/CobaltVoice-PIO/`) : embarque sur un Seeed XIAO nRF52840 Sense. Capture audio via micro PDM, compresse en IMA ADPCM, stocke en flash QSPI (offline) ou transfere en BLE vers le telephone.
- **cobalt_memo** (`App/cobalt_memo/`) : app Flutter de prise de notes vocales. Recoit l'audio via BLE, transcrit (Groq Whisper), categorise (Groq Llama), affiche en fiches thematiques.
- **cobalt_task** (`App/cobalt_task/`) : evolution de cobalt_memo. Ajoute l'execution d'actions locales Android (appels, SMS, alarmes, navigation, Spotify, paiements PayPal) via commandes vocales + integration Google (Tasks, Calendar, Contacts, Docs).

```
[Bracelet Cobalt]              [Telephone Android]
 nRF52840 Sense                 Flutter App
 Micro PDM -> ADPCM     -BLE->  Decodage ADPCM -> WAV
 Flash QSPI (offline)           Whisper STT -> Llama AI
 Bouton (gestes)         -BLE->  Actions / Notes
 LED RGB                         UI + Services Google/Spotify/PayPal
 NFC Tag (test)
```

---

## 2. FIRMWARE -- Seeed XIAO nRF52840 Sense

### 2.1 Build

| Parametre | Valeur |
|---|---|
| MCU | nRF52840 (Cortex-M4F, 64 MHz, 256 KB RAM, 1 MB Flash) |
| Board PlatformIO | `seeed-xiao-afruitnrf52-nrf52840-sense` |
| Framework | Arduino (Adafruit nRF52 BSP via Seeed fork) |
| Lib principale | `Adafruit SPIFlash@^4.3.4` |
| Build flags | `CFG_DEBUG=0`, `CFG_TUD_MSC=0`, `SPIFLASH_SDFAT=0` |

### 2.2 Brochage

| Pin | Fonction |
|---|---|
| `D1` | Bouton Push-to-Talk (INPUT_PULLUP, actif LOW) |
| `LED_RED/GREEN/BLUE` | LED RGB onboard (actif LOW) |
| `P0.31` | ADC batterie (diviseur R1=1M, R2=510K) |
| `P0.14` | Enable diviseur batterie (MOSFET, LOW=actif) |
| Pins 24-29 | QSPI flash (SCK, CS, IO0-IO3) |
| `P0.09`, `P0.10` | Antenne NFC |

### 2.3 Audio

| Parametre | Valeur |
|---|---|
| Micro | MSM261D3526H1CPM (onboard), protocole PDM |
| Sample rate | 16 000 Hz, mono, 16-bit PCM |
| Compression | IMA ADPCM (4:1) -> 4-bit, 8 000 octets/s |
| Buffer RAM | 120 KB (max ~15 secondes) |
| Gain PDM | 40 |
| Buffer PDM | 512 samples = 32 ms |

**Format CVOX (header 34 octets):**
```
Offset  Champ            Taille   Valeur
0       magic            4        "CVOX"
4       version          2        1
6       sampleRate       2        16000
8       channels         1        1
9       bitsPerSample    1        4
10      blockSize        2        256
12      totalSamples     4        (variable)
16      dataSize         4        (variable)
20      initialSample    2        (etat ADPCM initial)
22      initialIndex     1        (index step ADPCM initial)
23-33   reserved         11       0
```

### 2.4 Flash externe

| Parametre | Valeur |
|---|---|
| Puce | P25Q16H (Puya), 2 MB |
| Interface | QSPI |
| Filesystem | LittleFS (secteur 4 KB, page 256 B, 512 blocs) |
| Fichiers | `/note_XXXXX.cvox`, max 50 fichiers |
| Ecriture | blocs de 512 octets |

### 2.5 BLE

| Parametre | Valeur |
|---|---|
| Nom | `"Cobalt Voice 1"` |
| TX Power | +8 dBm |
| MTU | 247 octets |
| PHY | 2 Mbps |
| Conn interval | 20-100 ms |

**Services et caracteristiques :**

| Element | UUID | Direction |
|---|---|---|
| Audio Service | `6E400001-B5A3-F393-E0A9-E50E24DCCA9E` | -- |
| Audio TX | `6E400003-...` | Firmware -> Phone (Notify) |
| Audio RX | `6E400002-...` | Phone -> Firmware (Write) |
| Button Event | `6E400004-...` | Firmware -> Phone (Notify, 1 byte) |
| Battery Service | `0x180F` / `0x2A19` | Read + Notify |

Batterie : `valeur = pourcentage | (en_charge ? 0x80 : 0x00)` (bit 7 = charge USB).

**Transfert audio :** header CVOX (34B) suivi des donnees ADPCM, envoyes en chunks de MTU-3 octets via notifications.

### 2.6 Bouton (gestes)

| Evenement | Code | Usage |
|---|---|---|
| PRESS_DOWN | `0x10` | Demarre l'enregistrement immediatement (0ms latence) |
| SINGLE | `0x01` | Annule l'enregistrement, envoie geste via BLE |
| DOUBLE | `0x02` | Idem |
| TRIPLE | `0x03` | Idem |
| LONG_START | `0x04` | Appui > 500ms (enregistrement deja en cours) |
| LONG_STOP | `0x05` | Relachement apres appui long -> finalise + transfert |

Debounce 50ms, fenetre multi-press 300ms, seuil long press 500ms.
Enregistrement minimum : 300ms (sinon discard).

**Strategie "Record-Then-Cancel"** : l'enregistrement demarre des PRESS_DOWN. Si c'est un clic court (SINGLE/DOUBLE/TRIPLE), l'enregistrement est annule. Si c'est un appui long (LONG_STOP), l'audio est transfere.

### 2.7 LED

| Etat systeme | Couleur | Mode |
|---|---|---|
| Idle | OFF | OFF |
| Enregistrement | Rouge | Fixe |
| Transfert BLE | Bleu | Clignotement rapide (100ms) |
| Batterie faible | Jaune | Flash bref (200ms) |
| En charge USB | Vert | Fixe |
| Erreur | Blanc | Clignotement rapide |

Au boot : vert (>50%), jaune (20-50%), rouge (<20%) pendant 1.5s.

### 2.8 Alimentation

| Mode | Consommation | Condition |
|---|---|---|
| Actif | ~20-50 mA | BLE + PDM |
| System OFF | ~0.4 uA | Reveil par bouton (GPIO SENSE) |

Auto-off apres 10s d'inactivite (pas de BLE, pas de charge USB, pas d'enregistrement).
Batterie : LiPo 3.5-4.2V, ADC 12-bit, reference 3.0V, 8 echantillons moyennes.

### 2.9 NFC

Emulation NFC-A Type 2 Tag via peripherique NFCT hardware. Record NDEF texte "Cobalt Voice" en francais. Usage actuel : test d'antenne uniquement.

### 2.10 Flux principal (loop)

```
1. powerManager.update()           -- Batterie toutes les 30s
2. Notification batterie BLE       -- Si connecte + valeur changee
3. Commandes serie debug           -- h/s/b/l/r/t/x/d
4. buttonManager.update()          -- Detection gestes
5. Pompe de transfert BLE          -- continueTransfer()
6. Auto-sync flash -> BLE          -- Si fichiers pending + BLE connecte
7. Auto-off                        -- System OFF apres timeout
8. ledController.update()          -- Clignotements
9. delay(10) si pas de transfert   -- Economie CPU
```

**Scenario offline :** si BLE deconnecte, l'audio est sauvegarde en flash. A la reconnexion, les fichiers sont synchronises un par un puis supprimes.

---

## 3. APP FLUTTER -- cobalt_memo

### 3.1 Architecture

- Pattern **Singleton** pour tous les services
- Reactivite par **StreamController.broadcast()** + **StreamBuilder**
- Pas de state management framework (pas de Provider/BLoC/Riverpod)
- Base de donnees **SQLite** (`cobalt_voice.db`, version 5)
- Pipeline lineaire : `BLE -> ADPCM decode -> WAV -> Groq Whisper -> Groq Llama -> SQLite -> UI`

### 3.2 Pipeline audio

1. Reception BLE : accumulation de paquets dans un buffer
2. Detection header CVOX a l'offset 0 (magic "CVOX", taille a l'offset 16)
3. Quand le buffer atteint la taille attendue, transfert complet
4. Decodage IMA ADPCM -> PCM 16-bit
5. Generation WAV (44 octets header + PCM, 16kHz mono)
6. Envoi a Groq Whisper pour transcription
7. Envoi a Groq Llama pour categorisation

### 3.3 AI / APIs

| Service | Endpoint | Modele | Usage |
|---|---|---|---|
| STT | `api.groq.com/.../transcriptions` | `whisper-large-v3` | Transcription FR |
| Categorisation | `api.groq.com/.../chat/completions` | `llama-3.1-8b-instant` | JSON: category, summary, content, items |

**Categories :** TODO, SHOPPING, EVENT, CONTACT, MEMO, SYSTEM

### 3.4 UI

- Ecran unique `HomeScreen` avec 2 onglets : "Fiches" (cartes thematiques consolidees) et "Archive" (notes vocales brutes)
- Filtres par categorie (chips)
- Filtre favoris
- Bouton micro phone (hold-to-record, 15s max)
- Barre de progression lors du transfert BLE
- Theme sombre retro-minimaliste (fond #000000, accent #00FF88, police monospace)

### 3.5 Modeles de donnees

- **VoiceNote** : id, text, summary, category, date, audioPath, duration, isFavorite, isCompleted, eventDateTime, contactName
- **Fiche** : id, title, category, content, items (FicheItem[]), createdAt, updatedAt, isFavorite, eventDateTime, eventLocation, contactFirstName/LastName/Phone/Email/BuildingCode, sourceNoteIds

---

## 4. APP FLUTTER -- cobalt_task

### 4.1 Architecture

Evolution de cobalt_memo avec **double pipeline** :

1. **Pipeline notes** (identique a cobalt_memo) : BLE -> ADPCM -> WAV -> Whisper -> Llama AI Sorter -> Fiche -> SQLite + sync Google
2. **Pipeline actions** : Micro phone/Overlay/ASSIST -> WAV -> Whisper -> Groq LLM extraction d'action -> LocalActionDispatcher -> 12+ services natifs Android

40+ fichiers Dart dans `lib/`.

### 4.2 Actions supportees (AiAction, sealed class)

| Action | Parametres | Service Android |
|---|---|---|
| CalendarAction | title, startTime, endTime, location | device_calendar |
| SmsAction | recipient, message | SmsManager (MethodChannel) ou Intent SENDTO |
| AlarmAction | time, label | Intent SET_ALARM |
| TimerAction | durationSeconds, label | Intent SET_TIMER |
| SystemControlAction | controlType, value | volume_controller / Settings intents |
| CallAction | contact | Intent ACTION_CALL |
| MessagingAction | app, recipient, message | Deep links WhatsApp/Telegram/Signal/Messenger |
| MessageAction | recipient, message | Auto-routage intelligent |
| NavigationAction | destination, mode | Google Maps URI + briefing Gemini |
| MediaAction | controlType, query, app | MethodChannel media_keys + Spotify API |
| AppLaunchAction | appName | 120+ mappings nom -> packageName |
| PaymentAction | recipient, amount, note | PayPal REST API + app |
| NoAction | memo | Sauvegarde comme note |

### 4.3 AI / APIs supplementaires

| Service | Modele | Usage |
|---|---|---|
| Extraction d'actions | `llama-3.1-8b-instant` (temp 0.3) | JSON: intent + parametres |
| STT offline | `sherpa-onnx-whisper-tiny` (ONNX) | Transcription locale FR |
| Navigation briefing | `gemini-2.0-flash` | Synthese d'itineraire en 3 phrases |
| Spotify | Web API OAuth2 PKCE | Recherche, lecture, controle |
| PayPal | REST API OAuth2 Client Credentials | Paiements |
| Google Tasks/Calendar/People/Docs | googleapis | Sync bidirectionnelle |

### 4.4 Routage intelligent des messages

Quand l'utilisateur dit "Dis a Pierre que j'arrive" :
1. **Contacts valides** (SQLite) : si "Pierre" deja valide, envoi immediat
2. **Historique contacts** (SQLite) : derniere app utilisee pour contacter Pierre
3. **Correspondance floue** (Levenshtein) : recherche dans les contacts du telephone
4. **Si non valide** : affiche un dialogue de confirmation, le message n'est PAS envoye
5. **Choix de l'app** : historique entrant (IncomingHistoryService) > historique sortant > SMS par defaut
6. **Ecran verrouille** : force SMS (WhatsApp/Telegram necessitent l'UI)

### 4.5 Bouton hardware (via BLE)

| Geste | Action |
|---|---|
| Single click | Play/Pause media |
| Double click | Piste suivante |
| Triple click | Bookmark GPS (cree une Fiche avec coordonnees) |
| Long press | Push-to-Talk (gere par le firmware) |

### 4.6 Overlay et Assistant

- **Overlay natif Android** : bulle flottante pour saisie vocale depuis n'importe quelle app
- **Assistant par defaut** : peut remplacer Google Assistant (ASSIST intent, appui long Home, bouton casque)
- **Detection adaptive du silence** : calibration ambiante, marge voix (+0.08), marge silence (+0.04), seuil 4 ticks = 0.8s
- **TTS** : confirmations vocales (flutter_tts, fr-FR)

### 4.7 MethodChannels natifs Android

| Channel | Methodes |
|---|---|
| `com.cobalt_task/sms` | `sendSms` |
| `com.cobalt_task/media_keys` | `play`, `pause`, `next`, `previous`, `stop`, `playSearch` |
| `com.cobalt_task/cobalt_overlay` | `showOverlay`, `hideOverlay`, `updateAmplitude` |
| `com.cobalt_task/custom_notification` | `showMicNotification`, `onMicButtonPressed` |
| `com.cobalt_task/assistant` | `onAssistLaunch`, `checkPendingAssist` |
| `com.cobalt_task/device_state` | `isScreenLocked` |
| `com.cobalt_task/notification_listener` | `getIncomingHistory` |
| `com.cobalt_task/payment` | `launchPackage` |
| `com.cobalt_task/spotify_auth` | `onAuthCode` |
| `com.cobalt_task/overlay_permission` | `canDrawOverlays` |
| `com.cobalt_task/assistant_diagnostics` | `getAssistantStatus`, `requestAssistantRole` |

### 4.8 UI

- Ecran unique `HomeScreen` avec liste chronologique de MemoCards
- Theme clair creme (#F5F0EB, accent #00C471)
- Parametres : BLE, Google Sign-in, Spotify, PayPal, diagnostics assistant

### 4.9 Base de donnees

SQLite `cobalt_voice.db`, version 8. Tables : `voice_notes` (16 colonnes), `fiches` (16 colonnes), `validated_contacts`, `pending_validations`, `contact_history`.

---

## 5. BLE -- PROTOCOLE COMMUN

| Parametre | Valeur |
|---|---|
| Service UUID | `6E400001-B5A3-F393-E0A9-E50E24DCCA9E` (NUS) |
| TX (device->phone) | `6E400003-...` (Notify) |
| RX (phone->device) | `6E400002-...` (Write) |
| Button Event | `6E400004-...` (Notify, 1 byte) |
| Battery | `0x180F` / `0x2A19` |
| MTU prefere | 512 (phone) / 247 (firmware) |
| Nom device | "Cobalt Voice" / "Cobalt Task" |
| Auto-reconnexion | Backoff progressif (1s, 3s, 5s, 10s, 30s) |

**Protocole de transfert :**
1. Firmware envoie header CVOX (34B) + donnees ADPCM via notifications TX
2. App accumule les paquets dans un buffer
3. Quand `buffer.length >= dataSize` (lu dans le header), transfert complet
4. App decode ADPCM -> WAV -> pipeline AI

---

## 6. DEPENDANCES PRINCIPALES

### Firmware
- `Adafruit SPIFlash ^4.3.4`, `Bluefruit` (BSP), `PDM` (BSP), `Adafruit_LittleFS` (BSP)

### Flutter (communes)
- `flutter_blue_plus ^1.31.0`, `sqflite ^2.3.0`, `flutter_dotenv ^6.0.0`, `http ^1.2.0`, `audioplayers ^5.2.0`, `record ^6.0.0`, `permission_handler ^11.0.0`, `wakelock_plus ^1.2.0`

### Flutter (cobalt_task uniquement)
- `sherpa_onnx ^1.12.23`, `flutter_tts ^3.8.5`, `device_calendar ^4.3.1`, `android_intent_plus ^5.0.2`, `flutter_contacts ^1.1.7+1`, `flutter_secure_storage ^9.2.4`, `google_sign_in ^6.2.1`, `googleapis ^13.2.0`, `geolocator ^13.0.2`, `volume_controller ^2.0.7`, `torch_light ^1.0.0`, `url_launcher ^6.2.4`, `crypto ^3.0.0`

---

## 7. VARIABLES D'ENVIRONNEMENT (.env)

| Variable | Usage |
|---|---|
| `GROQ_API_KEY` | Whisper STT + Llama categorisation/actions |
| `GOOGLE_MAPS_API_KEY` | Google Directions API (cobalt_task) |
| `GEMINI_API_KEY` | Gemini Flash briefing navigation (cobalt_task) |

Spotify et PayPal utilisent OAuth2 avec tokens stockes localement.

---

## 8. STRUCTURE DES FICHIERS

```
Cobalt/
  Firmware/
    CobaltVoice-PIO/
      platformio.ini
      include/
        config.h, adpcm_codec.h, audio_storage.h, ble_services.h,
        button_manager.h, external_flash.h, led_controller.h,
        nfc_tag.h, pdm_audio.h, power_manager.h
      src/
        main.cpp, adpcm_codec.cpp, audio_storage.cpp, ble_services.cpp,
        button_manager.cpp, external_flash.cpp, led_controller.cpp,
        nfc_tag.cpp, pdm_audio.cpp, power_manager.cpp
  App/
    cobalt_memo/
      lib/
        main.dart, app.dart
        models/    voice_note.dart, fiche.dart
        screens/   home_screen.dart
        services/  ble_service.dart, adpcm_decoder.dart, audio_service.dart,
                   transcription_service.dart, ai_sorter_service.dart,
                   database_service.dart, foreground_service.dart
        widgets/   ble_status_indicator.dart, voice_note_card.dart, fiche_card.dart
    cobalt_task/
      lib/
        main.dart, app.dart
        constants/ app_constants.dart
        models/    voice_note.dart, fiche.dart, ai_action.dart
        screens/   home_screen.dart
        services/  (30+ fichiers) ble_service.dart, adpcm_decoder.dart,
                   audio_service.dart, transcription_service.dart,
                   ai_sorter_service.dart, groq_client.dart,
                   local_action_dispatcher.dart, local_sms_service.dart,
                   local_calendar_service.dart, local_phone_service.dart,
                   local_navigation_service.dart, local_media_service.dart,
                   local_spotify_service.dart, local_app_launcher_service.dart,
                   local_alarm_service.dart, local_system_control_service.dart,
                   local_messaging_service.dart, paypal_payment_service.dart,
                   google_auth_service.dart, google_bridge_service.dart,
                   google_tasks_service.dart, google_calendar_service.dart,
                   google_people_service.dart, google_docs_service.dart,
                   contact_lookup_service.dart, validated_contacts_service.dart,
                   contact_history_service.dart, incoming_history_service.dart,
                   hardware_button_service.dart, cobalt_overlay_service.dart,
                   assistant_launch_service.dart, audio_feedback_service.dart,
                   sherpa_transcription_service.dart, voice_input_processor.dart,
                   foreground_service.dart, database_service.dart,
                   lock_screen_service.dart, overlay_permission_service.dart
        widgets/   ble_status_indicator.dart, memo_card.dart
```
