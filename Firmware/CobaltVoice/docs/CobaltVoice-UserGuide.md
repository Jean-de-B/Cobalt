# Cobalt Voice — Guide Utilisateur & Spécifications Techniques

**Montre enregistreur vocal BLE ultra basse consommation**

Version firmware : 1.0.0 | Plateforme : XIAO nRF52840 Sense

---

## 1. Présentation

Cobalt Voice est une montre connectée minimaliste conçue pour l'enregistrement vocal instantané. Appuyez sur le bouton, parlez, relâchez — votre note vocale est automatiquement transférée vers votre smartphone via Bluetooth Low Energy.

**Cas d'usage :**
- Capture d'idées à la volée
- Mémos vocaux mains libres
- Journalisation vocale quotidienne
- Prototypage wearable IoT

---

## 2. Boutons & Interactions

Le device dispose de **3 boutons physiques** :

### Bouton principal (D1) — Enregistrement

| Action | Fonction |
|---|---|
| **Appui long maintenu** | Enregistrement push-to-talk (parlez tant que vous maintenez) |
| **Relâchement** | Arrêt enregistrement → transfert BLE automatique |
| **Appui depuis veille** | Réveil du device (sortie du mode deep sleep) |
| **Clic court** | Annule l'enregistrement en cours |

> **Mode offline** : si le smartphone n'est pas connecté, l'enregistrement est sauvegardé sur la mémoire flash interne. La synchronisation se fait automatiquement à la prochaine connexion BLE.

### Bouton D2 — Volume +

| Action | Fonction |
|---|---|
| **Appui simple** | Augmente le volume du smartphone |

### Bouton D3 — Volume -

| Action | Fonction |
|---|---|
| **Appui simple** | Diminue le volume du smartphone |

> Les boutons D2 et D3 réveillent également le device depuis le mode veille.

---

## 3. Codes couleurs LED

La LED RGB intégrée indique l'état du device :

### Au démarrage (1.5 seconde)

| Couleur | Signification |
|---|---|
| 🟢 **Vert fixe** | Batterie > 50% |
| 🟡 **Jaune fixe** | Batterie 20–50% |
| 🔴 **Rouge fixe** | Batterie < 20% |

### En fonctionnement

| Couleur | Mode | Signification |
|---|---|---|
| 🔴 **Rouge clignotant lent** | Recherche | Advertising BLE — en attente de connexion smartphone |
| 🔴 **Rouge fixe** | Enregistrement | Capture audio en cours (push-to-talk) |
| 🟢 **Vert fixe** | Confirmation | Enregistrement terminé avec succès |
| 🔵 **Bleu fixe** | Transfert | Envoi des données audio vers le smartphone |
| 🟢 **Vert flash (0.5s)** | Bouton volume | Confirmation d'appui sur D2 ou D3 |

### Alertes

| Couleur | Signification |
|---|---|
| 🔴 **Rouge 3× flash rapide** | Batterie critique — extinction automatique (protection LiPo) |
| 🔴 **Rouge clignotant rapide** | Mémoire flash pleine — enregistrement bloqué |
| ⚪ **Blanc clignotant** | Erreur système |

### LED éteinte

| Contexte | Signification |
|---|---|
| Connecté au smartphone | Fonctionnement normal, prêt à enregistrer |
| Aucune activité | Le device entre en veille profonde automatiquement |

---

## 4. Modes de fonctionnement

### Mode veille (System OFF)
- Consommation : **~0.4 µA** (plusieurs mois sur batterie LiPo)
- Réveil par appui sur n'importe quel bouton (D1, D2 ou D3)
- Le réveil déclenche un redémarrage complet

### Mode connecté
- Le device se connecte automatiquement à l'application Cobalt Voice
- Les enregistrements sont transférés en temps réel
- Les boutons volume contrôlent le smartphone à distance

### Mode offline
- Sans connexion BLE, les enregistrements sont stockés sur la flash interne (2 Mo)
- Synchronisation automatique dès que la connexion BLE est rétablie

### Cycle d'advertising (recherche de connexion)
1. **Phase rapide** (60s) : balayage intensif à 20-30ms
2. **Phase lente** (2 min) : balayage économique à 1-1.5s
3. **Extinction automatique** : si aucune connexion → retour en veille profonde

---

## 5. Spécifications techniques

### Processeur & Radio

| Paramètre | Valeur |
|---|---|
| MCU | Nordic nRF52840 (ARM Cortex-M4F, 64 MHz) |
| RAM | 256 KB |
| Flash programme | 1 MB |
| Radio | Bluetooth 5.0 Low Energy |
| PHY | 2M (2 Mbps) |
| Puissance TX | +8 dBm (portée maximale) |
| Plateforme | Seeed XIAO nRF52840 Sense |

### Audio

| Paramètre | Valeur |
|---|---|
| Microphone | PDM intégré (XIAO Sense) |
| Fréquence d'échantillonnage | 16 kHz |
| Résolution | 16 bits PCM |
| Canaux | Mono |
| Compression | ADPCM (4:1 — 16 bits → 4 bits) |
| Débit compressé | 8 Ko/s |
| Durée max par enregistrement | ~15 secondes |

### Stockage

| Paramètre | Valeur |
|---|---|
| Flash externe | P25Q16H (QSPI, 2 Mo) |
| Système de fichiers | LittleFS |
| Mode veille flash | Deep power-down (~1 µA) |
| Capacité offline | Plusieurs dizaines d'enregistrements |

### Transfert BLE

| Paramètre | Valeur |
|---|---|
| MTU | 247 bytes (maximum) |
| DLE (Data Length Extension) | 251 bytes |
| Connection Event Extension | Activé |
| Intervalle de connexion | 7.5–15 ms |
| Queue HVN | 30 notifications |
| Event length | 50 ms |
| Format de transfert | Header CVOX (34 bytes) + données ADPCM |

### Batterie & Consommation

| Mode | Consommation estimée |
|---|---|
| Deep sleep (System OFF) | ~0.4 µA |
| Advertising rapide | ~1–3 mA |
| Advertising lent | ~0.3–0.5 mA |
| Connecté (idle) | ~1–2 mA |
| Enregistrement + BLE | ~5–8 mA |
| Transfert BLE actif | ~4–6 mA |

| Paramètre | Valeur |
|---|---|
| Type de batterie | LiPo 3.7V |
| Tension pleine charge | 4.2V |
| Seuil batterie faible | 3.6V (~15%) |
| Seuil critique (extinction) | 3.5V (protection LiPo) |
| Autonomie en veille | Plusieurs mois |

### Mise à jour firmware

| Paramètre | Valeur |
|---|---|
| OTA DFU | Supporté (bootloader Adafruit nRF52) |
| Port série | USB-C (debug & flash filaire) |
| Framework | Arduino (PlatformIO) |

---

## 6. Schéma de brochage

```
XIAO nRF52840 Sense
┌─────────────────────┐
│  D1  → Bouton REC   │  (push-to-talk, wake)
│  D2  → Bouton VOL+  │  (volume up, wake)
│  D3  → Bouton VOL-  │  (volume down, wake)
│                      │
│  LED_RED   (intégré) │  Active LOW
│  LED_GREEN (intégré) │  Active LOW
│  LED_BLUE  (intégré) │  Active LOW
│                      │
│  PDM_CLK   (intégré) │  Microphone
│  PDM_DATA  (intégré) │  Microphone
│                      │
│  PIN_VBAT  (intégré) │  ADC batterie (pont diviseur)
│  USB-C              │  Charge + programmation
└─────────────────────┘
```

**Câblage des boutons** : chaque bouton relie le pin correspondant (D1/D2/D3) au GND. Les pull-ups internes du nRF52840 sont activés par le firmware.

---

## 7. Application compagnon

L'application **Cobalt Voice** (Android) se connecte automatiquement au device et :
- Reçoit les enregistrements en temps réel
- Synchronise les enregistrements stockés offline
- Contrôle le volume via les boutons D2/D3
- Affiche le niveau de batterie

---

*Cobalt Voice — Conçu pour les makers et passionnés d'électronique embarquée*
