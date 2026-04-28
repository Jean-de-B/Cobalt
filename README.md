[🇫🇷 Lire en français](README.fr.md)

# Cobalt

**Website:** https://cobalt-watch.com/

**Voice-connected bracelet that turns speech into actions.**

Cobalt is an open-source wearable made of a hardware bracelet (nRF52840) and an Android app (Flutter). Press the button, speak — Cobalt transcribes, understands, and executes: send an SMS, set a timer, control Spotify, or simply take a note.

<p align="center">
  <img src="App/cobalt_task/assets/logo.png" alt="Cobalt Logo" width="120"/>
</p>

---

## How it works

```
┌─────────────────┐         BLE          ┌──────────────────────────────────────┐
│  Cobalt Bracelet │ ──────────────────> │           Android App                │
│                  │                      │                                      │
│  nRF52840 Sense  │                      │  Audio ADPCM ──> WAV                │
│  PDM Microphone  │                      │       ↓                              │
│  QSPI Flash      │                      │  Whisper STT (transcription)         │
│  Button + LED    │                      │       ↓                              │
│  LiPo Battery    │                      │  Llama 3.1 (understanding)           │
│                  │                      │       ↓                              │
│                  │                      │  Local action OR Categorized note    │
└─────────────────┘                      └──────────────────────────────────────┘
```

**Two voice input modes:**
- **Bracelet button** (long press) — records on the bracelet, transfers via BLE
- **Phone power button** (long press) — records directly on the phone microphone, works from any app

---

## Features

### Voice actions (12 types)

| Command | Action |
|---|---|
| "Wake me up at 7am" | Android alarm |
| "Timer 5 minutes" | System timer |
| "Text mom: on my way" | SMS sent directly |
| "Call Paul" | Phone call |
| "Tell Marie it's ok" | WhatsApp / Telegram / Signal (smart routing) |
| "Dentist appointment Friday 2pm" | Calendar event |
| "Take me to Gare de Lyon" | Google Maps navigation |
| "Play jazz on Spotify" | Spotify playback |
| "Pay back Paul €20" | PayPal payment |
| "Full volume" / "Turn on the light" | System control (volume, lamp, silent mode) |
| "Open Instagram" | App launch (120+ recognized apps) |
| "Remind me to buy bread" | Categorized note (TODO, SHOPPING, MEMO, EVENT, CONTACT) |

### Smart notes

Voice memos that don't match any action are automatically categorized and organized as cards:
- **TODO** — tasks with optional deadline
- **SHOPPING** — automatic item extraction
- **EVENT** — appointments with date/location
- **CONTACT** — name, phone, email, door code
- **MEMO** — ideas, thoughts, with sentiment analysis

### Bracelet gestures

| Gesture | Action |
|---|---|
| Long press | Voice recording (push-to-talk) |
| Single click | Play / Pause media |
| Double click | Next track |
| Triple click | GPS Bookmark |

### Integrations

- **Google** — Tasks, Calendar, Contacts, Docs (two-way sync)
- **Spotify** — OAuth2 PKCE, search and playback control
- **Groq** — Whisper (STT) + Llama 3.1 (NLU), low temperature for reliability

---

## Architecture

```
Cobalt/
├── Firmware/CobaltVoice-PIO/     # PlatformIO firmware (C++)
│   ├── include/                   # Headers (config, BLE, audio, LED, power, NFC)
│   └── src/                       # Sources (main loop, ADPCM, PDM, flash, button)
│
├── App/cobalt_task/               # Main Flutter app
│   ├── lib/
│   │   ├── models/                # VoiceNote, Fiche, AiAction (sealed class)
│   │   ├── services/              # 40+ singleton services
│   │   ├── screens/               # HomeScreen
│   │   └── widgets/               # MemoCard, BleStatusIndicator
│   └── android/.../kotlin/        # Native Android code (Kotlin)
│       ├── AssistantActivity.kt   # Intercepts ASSIST (Power long press)
│       ├── CobaltOverlayManager.kt # Voice overlay (EdgeGlow + VoiceRing)
│       ├── CobaltAccessibilityService.kt # Keyboard detection + text injection
│       └── MainActivity.kt        # 14 Flutter ↔ Android MethodChannels
│
└── App/cobalt_memo/               # Voice notes app (initial version)
```

### Voice pipeline

```
Audio (ADPCM/WAV)
  → Whisper STT (Groq cloud or Sherpa local)
  → Llama 3.1: intent extraction + parameters (JSON)
  → If action detected:
      → LocalActionDispatcher → Native Android service → Execution
      → TTS confirmation
  → If no action:
      → Llama 3.1: categorization (TODO/SHOPPING/EVENT/CONTACT/MEMO)
      → Merge with existing cards (fuzzy title matching)
      → SQLite storage + Google sync
```

---

## Hardware

| Component | Details |
|---|---|
| MCU | Seeed XIAO nRF52840 Sense (Cortex-M4F, 64 MHz) |
| Microphone | MSM261D3526H1CPM (PDM, 16 kHz mono) |
| Flash | P25Q16H 2 MB (QSPI, LittleFS) |
| BLE | 5.0, 2 Mbps PHY, MTU 247, NUS service |
| Battery | LiPo 3.5-4.2V, USB charging |
| LED | Onboard RGB (red=rec, blue=transfer, green=charge) |
| Button | Push-to-talk on D1 (50ms debounce, 300ms multi-press) |
| NFC | Type 2 Tag emulation (antenna test) |

**Power consumption:** ~20-50 mA active, ~0.4 µA in System OFF. Auto-off after 10s of inactivity.

**CVOX audio format:** 34-byte header + IMA ADPCM data (4:1 compression).

---

## Setup

### Requirements

- Flutter 3.10.8+
- Android SDK 31+ (Android 12)
- PlatformIO (for firmware)
- A Seeed XIAO nRF52840 Sense (for the bracelet)

### Configuration

1. Clone the repo:
```bash
git clone https://github.com/Jean-de-B/Cobalt.git
cd Cobalt/App/cobalt_task
```

2. Create the `.env` file at the root of `cobalt_task/`:
```env
GROQ_API_KEY=your_groq_api_key
GOOGLE_MAPS_API_KEY=your_google_maps_key
```

3. Install dependencies and run:
```bash
flutter pub get
flutter run
```

4. In the app, enable permissions and services:
   - **Default assistant** — Settings > Default apps > Digital assistant > Cobalt
   - **Side key** (Samsung) — Settings > Advanced features > Side key > Press and hold > Assistant
   - **Overlay** — App overlay permission

### Firmware

```bash
cd Firmware/CobaltVoice-PIO
pio run -t upload
```

---

## Tech stack

| Layer | Technologies |
|---|---|
| Firmware | C++ / Arduino (Adafruit nRF52 BSP), PlatformIO |
| App | Flutter / Dart, Kotlin (native Android code) |
| AI | Groq (Whisper large-v3 + Llama 3.1 8B), Sherpa-ONNX (offline) |
| BLE | flutter_blue_plus, Nordic UART Service (NUS) |
| Database | SQLite (sqflite), 5 tables, version 8 |
| Auth | Google Sign-In, Spotify OAuth2 PKCE |
| Native services | 14 MethodChannels, AccessibilityService, VoiceInteractionService, NotificationListener |

---

## License

Personal project — license to be defined.
