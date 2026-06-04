# Cobalt — Journal des fonctionnalités

Suivi des évolutions du firmware (XIAO nRF52840 Sense) et de l'application (Flutter/Android).
Format : `v FIRMWARE / APP` · Date · Description.

---

## [1.0.5 - EN COURS] — 2026-06-04

### Firmware
- **Watchdog matériel 8s** — réinitialisation automatique en cas de freeze (hard fault, boucle infinie, PDM bloqué). Démarré après l'init, rafraîchi à chaque itération de `loop()`. (`src/main.cpp`)
- **Advertising étendu à 10 minutes** — 60s rapide (20-30ms) + 540s lent (1-1.5s). (`include/config.h : ADV_SLOW_TIMEOUT_S`)
- **Comportement advertising post-déconnexion** — une seule phase automatique au réveil et après déconnexion ; les suivantes nécessitent un appui court sur le bouton. (`src/ble_services.cpp : restartOnDisconnect(true)`)
- **5 flashs verts à la reconnexion BLE** — feedback visuel de confirmation de connexion. (`src/main.cpp`)

### Application
- *(aucune modification dans cette session)*

---

## [1.0.4] — 2026-05-28 / 2026-05-29

### Firmware — Séquence d'appairage et boutons volume
- **Triple appui hors connexion** → dissociation (`clearBondsAndRestartPairing`) et retour en mode appairage général, LED blanche clignotante rapide.
- **Boutons volume D2/D3** — envoi d'événements `BTN_EVT_VOLUME_UP` / `BTN_EVT_VOLUME_DOWN` via caractéristique BLE custom. Feedback LED vert bref à l'appui.
- **Machine à états bouton multi-gestes** — `ButtonManager` : PRESS_DOWN anticipé, SINGLE, DOUBLE, TRIPLE, LONG_START, LONG_STOP.
- **5 notes vocales hors ligne** — stockage flash LittleFS (QSPI 2MB), sync automatique à la reconnexion BLE.
- **Reformat LittleFS automatique** en cas de corruption détectée à l'écriture.
- **QSPI deep power-down** entre les accès flash (~0 µA quand idle). (`src/power_manager.cpp`)

### Application — Indicateur BLE amélioré
- Redesign `BleStatusIndicator` avec bouton "Oublier" (dissociation pilotée depuis l'app).
- Gestion des états BLE plus fine (scanning, connecting, connected, disconnected).

---

## [1.0.3] — 2026-05-20 / 2026-05-21

### Application — Écran de paramètres et choix de service IA
- **Écran Paramètres** complet : clé API Groq saisie dans l'app (plus de `.env`), sélection du service IA actif.
- **Google Bridge Service** — pont vers l'API Google (Agenda, Tâches).
- **Google Calendar Service** — lecture et création d'événements depuis une note vocale.
- **Local Calendar Service** — accès au calendrier Android natif.
- Sécurité : suppression de la clé API du dépôt public, stockage chiffré dans `SharedPreferences`.

---

## [1.0.2] — 2026-04-30

### Firmware — Stabilité BLE et debug
- **Négociation PHY 2M / DLE / MTU** post-connexion en machine à états non-bloquante (`BleServices::update()`). PHY 2M → DLE 251 → MTU 247.
- **Caractéristique Debug Log BLE** (`UUID_DEBUG_LOG`) — log firmware streamé en temps réel vers l'app sans câble USB.
- **Intervalles de connexion adaptatifs** : mode rapide (30-50ms) pendant un transfert, mode idle (500ms-1s) au repos connecté.
- **Samsung compatibility** — intervalles min. 30ms pour éviter les refus de paramètres BLE.
- **Nom BLE dynamique** "Cobalt XXXX" généré depuis les 4 derniers octets de l'adresse MAC FICR.
- **Diagnostic OTA** — 3 flashs cyan au boot confirment que le firmware post-DFU démarre correctement.

### Application — Console de debug et overlay
- Écran de debug (`debug_screen.dart`) avec log temps réel depuis la caractéristique BLE.
- `DebugConsoleService` — capture les `print()` Flutter et les affiche dans un panneau glissant.
- Overlay service persistant pour accès rapide hors focus app.

---

## [1.0.1] — 2026-04-01 / 2026-04-02

### Firmware — Mode basse consommation (PR #1)
- **System OFF** (~0.4 µA) — deep sleep après inactivité (90s timeout). Réveil par GPIO sur les 3 boutons (D9, D2, D3).
- **WFE dans loop()** — `sd_app_evt_wait()` remplace `delay(10)` ; le CPU dort jusqu'à la prochaine interruption.
- **Advertising multi-phase** — Fast (20-30ms, 60s) → Slow (1-1.5s, variable) → arrêt → System OFF.
- **NFC désactivé** en production (`NFC_ENABLED 0`), économie ~0.5 mA.
- **UART/Serial désactivé** en production (`DEBUG_SERIAL 0`).
- **Heartbeat conditionnel** — `[HB] #N t=Xms Rec:Y Xfer:Z BLE:W Adv:V Bat:V(P%)` uniquement en debug.
- **Push-to-Wake** — bouton maintenu au réveil → enregistrement immédiat sans appui long supplémentaire.

### Application — Connexion BLE stable
- Refonte `BleService` : reconnexion automatique, gestion des états, scan filtré par nom "Cobalt".
- Retransmission automatique des notifications ADPCM perdues.
- Écran de paramètres minimal (premier accès à la clé API).

---

## [1.0.0] — 2026-03-03 / 2026-04-30

### Firmware — Première version proto
- Enregistrement vocal push-to-talk (PDM, 16kHz, mono).
- Compression ADPCM 4:1 en RAM (120 KB ≈ 15s).
- Transfert BLE chunked : header CVOX + données ADPCM, MTU 247, DLE 251.
- LED RGB : statuts enregistrement (rouge), transfert (bleu), idle (bleu clignotant), batterie (vert/jaune/rouge).
- Affichage statut batterie 1.5s au réveil.
- Protection batterie critique → System OFF automatique.
- Service batterie BLE standard (0x180F).
- DFU OTA Adafruit (commande `0xFD` depuis l'app).
- Envoi version firmware sur commande `0xFE`.

### Application — Première version proto
- Interface Flutter Android avec connexion BLE au bracelet.
- Décodage ADPCM → PCM, lecture audio et transcription via Groq Whisper.
- Traitement IA des actions vocales (tâches, rappels, navigation, SMS, appels).
- `VoiceInputProcessor` — pipeline transcription → IA → action locale.
- Services locaux : navigation, SMS, calendrier, Spotify, lancement d'applis.

---

## À faire / Backlog

### Firmware
- [ ] **Limiter la durée max d'enregistrement** à 15s même en mode debug (`timedRecordingDuration` déjà prévu).
- [ ] **Indicateur visuel de charge flash** — signaler à l'utilisateur quand les 5 emplacements sont occupés avant même d'appuyer.
- [ ] **RESETREAS** — détecter au boot si le reset vient du watchdog et afficher un signal LED distinct (ex. 2 flashs orange).
- [ ] **OTA DFU sans câble** — documenter et tester le flow complet depuis l'app.
- [ ] **Augmenter la capacité offline** > 5 notes (reformat LittleFS ou pages de 4KB plus petites).

### Application
- [ ] **Affichage des notes en attente de sync** — compteur visible sur l'écran principal quand des notes sont stockées en flash.
- [ ] **Confirmation de réception** — feedback visuel dans l'app quand une note a été traitée avec succès.
- [ ] **iOS** — portage BLE (CoreBluetooth) et transcription.
- [ ] **Mode mains-libres étendu** — réponse vocale dictée sans sortir le téléphone pour les messages entrants.
