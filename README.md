# Cobalt

**Bracelet vocal connecté qui transforme la voix en actions.**

Cobalt est un wearable open-source composé d'un bracelet hardware (nRF52840) et d'une app Android (Flutter). Appuyez sur le bouton, parlez — Cobalt transcrit, comprend et exécute : envoyer un SMS, lancer un timer, contrôler Spotify, payer via PayPal, dicter du texte, ou simplement prendre une note.

<p align="center">
  <img src="App/cobalt_task/assets/logo.png" alt="Cobalt Logo" width="120"/>
</p>

---

## Comment ça marche

```
┌─────────────────┐         BLE          ┌──────────────────────────────────────┐
│  Bracelet Cobalt │ ──────────────────> │           App Android                │
│                  │                      │                                      │
│  nRF52840 Sense  │                      │  Audio ADPCM ──> WAV                │
│  Micro PDM       │                      │       ↓                              │
│  Flash QSPI      │                      │  Whisper STT (transcription)         │
│  Bouton + LED    │                      │       ↓                              │
│  Batterie LiPo   │                      │  Llama 3.1 (compréhension)           │
│                  │                      │       ↓                              │
│                  │                      │  Action locale OU Note catégorisée   │
└─────────────────┘                      └──────────────────────────────────────┘
```

**Deux modes d'entrée vocale :**
- **Bouton du bracelet** (long press) — enregistre sur le bracelet, transfère via BLE
- **Bouton Power du téléphone** (long press) — enregistre directement sur le micro du téléphone, fonctionne depuis n'importe quelle app

---

## Fonctionnalités

### Actions vocales (12 types)

| Commande | Action |
|---|---|
| "Réveille-moi à 7h" | Alarme Android |
| "Timer 5 minutes" | Timer système |
| "SMS à maman : j'arrive" | SMS envoyé directement |
| "Appelle Paul" | Appel téléphonique |
| "Dis à Marie que c'est ok" | WhatsApp / Telegram / Signal (routage intelligent) |
| "RDV dentiste vendredi 14h" | Événement calendrier |
| "Emmène-moi gare de Lyon" | Navigation Google Maps |
| "Joue du jazz sur Spotify" | Lecture Spotify |
| "Rembourse 20€ à Paul" | Paiement PayPal |
| "Son à fond" / "Allume la lampe" | Contrôle système (volume, lampe, mode silencieux) |
| "Ouvre Instagram" | Lancement d'app (120+ apps reconnues) |
| "Rappelle-moi d'acheter du pain" | Note catégorisée (TODO, SHOPPING, MEMO, EVENT, CONTACT) |

### Mode dictée

Quand un clavier est ouvert dans n'importe quelle app, le long press Power active le **mode dictée** : le texte est transcrit et injecté directement dans le champ de saisie, segment par segment, sans animation ni pipeline IA.

### Notes intelligentes

Les mémos vocaux qui ne correspondent à aucune action sont automatiquement catégorisés et organisés en fiches :
- **TODO** — tâches avec échéance optionnelle
- **SHOPPING** — extraction automatique des articles
- **EVENT** — rendez-vous avec date/lieu
- **CONTACT** — nom, téléphone, email, digicode
- **MEMO** — idées, réflexions, avec analyse de sentiment

### Gestes bracelet

| Geste | Action |
|---|---|
| Long press | Enregistrement vocal (push-to-talk) |
| Simple clic | Play / Pause média |
| Double clic | Piste suivante |
| Triple clic | Bookmark GPS |

### Intégrations

- **Google** — Tasks, Calendar, Contacts, Docs (sync bidirectionnelle)
- **Spotify** — OAuth2 PKCE, recherche et contrôle de lecture
- **PayPal** — Paiements P2P via API REST
- **Groq** — Whisper (STT) + Llama 3.1 (NLU), temp basse pour la fiabilité
- **Gemini** — Briefing de navigation en 3 phrases

---

## Architecture

```
Cobalt/
├── Firmware/CobaltVoice-PIO/     # Firmware PlatformIO (C++)
│   ├── include/                   # Headers (config, BLE, audio, LED, power, NFC)
│   └── src/                       # Sources (main loop, ADPCM, PDM, flash, bouton)
│
├── App/cobalt_task/               # App Flutter principale
│   ├── lib/
│   │   ├── models/                # VoiceNote, Fiche, AiAction (sealed class)
│   │   ├── services/              # 40+ services singleton
│   │   ├── screens/               # HomeScreen
│   │   └── widgets/               # MemoCard, BleStatusIndicator
│   └── android/.../kotlin/        # Code natif Android (Kotlin)
│       ├── AssistantActivity.kt   # Intercepte ASSIST (Power long press)
│       ├── CobaltOverlayManager.kt # Overlay vocal (EdgeGlow + VoiceRing)
│       ├── CobaltAccessibilityService.kt # Détection clavier + injection texte
│       └── MainActivity.kt        # 14 MethodChannels Flutter ↔ Android
│
└── App/cobalt_memo/               # App notes vocales (version initiale)
```

### Pipeline vocal

```
Audio (ADPCM/WAV)
  → Whisper STT (Groq cloud ou Sherpa local)
  → Llama 3.1 : extraction d'intent + paramètres (JSON)
  → Si action détectée :
      → LocalActionDispatcher → Service natif Android → Exécution
      → Confirmation TTS
  → Si aucune action :
      → Llama 3.1 : catégorisation (TODO/SHOPPING/EVENT/CONTACT/MEMO)
      → Fusion avec fiches existantes (matching flou de titres)
      → Stockage SQLite + sync Google
```

---

## Hardware

| Composant | Détail |
|---|---|
| MCU | Seeed XIAO nRF52840 Sense (Cortex-M4F, 64 MHz) |
| Micro | MSM261D3526H1CPM (PDM, 16 kHz mono) |
| Flash | P25Q16H 2 MB (QSPI, LittleFS) |
| BLE | 5.0, 2 Mbps PHY, MTU 247, NUS service |
| Batterie | LiPo 3.5-4.2V, charge USB |
| LED | RGB onboard (rouge=rec, bleu=transfert, vert=charge) |
| Bouton | Push-to-talk sur D1 (debounce 50ms, multi-press 300ms) |
| NFC | Emulation Type 2 Tag (test antenne) |

**Consommation :** ~20-50 mA actif, ~0.4 µA en System OFF. Auto-off après 10s d'inactivité.

**Format audio CVOX :** Header 34 octets + données IMA ADPCM (compression 4:1).

---

## Setup

### Prérequis

- Flutter 3.10.8+
- Android SDK 31+ (Android 12)
- PlatformIO (pour le firmware)
- Un Seeed XIAO nRF52840 Sense (pour le bracelet)

### Configuration

1. Cloner le repo :
```bash
git clone https://github.com/votre-user/Cobalt.git
cd Cobalt/App/cobalt_task
```

2. Créer le fichier `.env` à la racine de `cobalt_task/` :
```env
GROQ_API_KEY=your_groq_api_key
GOOGLE_MAPS_API_KEY=your_google_maps_key
GEMINI_API_KEY=your_gemini_key
```

3. Installer les dépendances et lancer :
```bash
flutter pub get
flutter run
```

4. Dans l'app, activer les permissions et services :
   - **Assistant par défaut** — Paramètres > Apps par défaut > Assistant numérique > Cobalt
   - **Touche latérale** (Samsung) — Paramètres > Fonctions avancées > Touche latérale > Maintien > Assistant
   - **Service d'accessibilité** — Paramètres > Accessibilité > Cobalt Dictation (pour le mode dictée)
   - **Overlay** — Permission de superposition d'apps

### Firmware

```bash
cd Firmware/CobaltVoice-PIO
pio run -t upload
```

---

## Stack technique

| Couche | Technologies |
|---|---|
| Firmware | C++ / Arduino (Adafruit nRF52 BSP), PlatformIO |
| App | Flutter / Dart, Kotlin (code natif Android) |
| IA | Groq (Whisper large-v3 + Llama 3.1 8B), Sherpa-ONNX (offline), Gemini Flash |
| BLE | flutter_blue_plus, Nordic UART Service (NUS) |
| Base de données | SQLite (sqflite), 5 tables, version 8 |
| Auth | Google Sign-In, Spotify OAuth2 PKCE, PayPal OAuth2 |
| Services natifs | 14 MethodChannels, AccessibilityService, VoiceInteractionService, NotificationListener |

---

## Licence

Projet personnel — licence à définir.
