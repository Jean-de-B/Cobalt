# Cobalt Task - Guide d'installation et d'onboarding

## Qu'est-ce que Cobalt Task ?

Cobalt Task est un assistant vocal Android qui transforme ta voix en actions. Connecte-le a ton bracelet Cobalt Voice, appuie sur le bouton, parle -- et Cobalt execute : envoyer un SMS, lancer de la musique, creer un evenement, naviguer quelque part, passer un appel, controler le volume, et bien plus.

L'app fonctionne aussi sans le bracelet : appuie sur le bouton micro rouge dans l'app, ou configure le bouton Power de ton telephone comme raccourci.

---

## Etape 1 -- Installer l'application

1. Installe l'APK `cobalt_task.apk` sur ton telephone Android
2. Ouvre l'app -- elle va demander plusieurs permissions au premier lancement

---

## Etape 2 -- Permissions Android

L'app demande ces permissions au demarrage. **Accepte-les toutes** pour un fonctionnement complet :

| Permission | Pourquoi |
|---|---|
| Microphone | Enregistrer ta voix |
| Bluetooth | Se connecter au bracelet Cobalt |
| Localisation | Necessaire pour le scan Bluetooth sur Android |
| Contacts | Trouver les numeros quand tu dis "appelle maman" |
| Calendrier | Creer des evenements quand tu dis "RDV dentiste demain 14h" |
| Telephone | Passer des appels vocaux |
| SMS | Envoyer des SMS en arriere-plan |
| Notifications | Afficher le bouton micro persistant |
| Stockage | Mise a jour du firmware du bracelet |

---

## Etape 3 -- Parametres Android speciaux

Certaines fonctions necessitent des reglages manuels dans les parametres Android :

### 3.1 Assistant vocal par defaut (recommande)

Permet d'activer l'assistant avec un appui long sur le bouton Power.

1. Parametres > Applications > Applications par defaut > Application d'assistance
2. Selectionne **Cobalt Task**

*Sur Samsung : Parametres > Fonctions avancees > Touche laterale > Maintien enfonce > Assistant numerique > Cobalt Task*

### 3.2 Notifications (obligatoire pour la messagerie)

Permet a Cobalt de voir les messages entrants de WhatsApp, Telegram, etc.

1. Parametres > Applications > Acces special > Acces aux notifications
2. Active **Cobalt Task**

### 3.3 Affichage par-dessus les autres apps (recommande)

Permet l'animation de l'assistant quand tu parles depuis l'ecran verrouille.

1. Parametres > Applications > Acces special > Afficher par-dessus les autres apps
2. Active **Cobalt Task**

### 3.4 Optimisation de la batterie (recommande)

Empeche Android de tuer l'app en arriere-plan.

1. Parametres > Batterie > Optimisation de la batterie
2. Cherche **Cobalt Task** > Selectionne "Ne pas optimiser"

---

## Etape 4 -- Cle API Groq (obligatoire)

Groq est le moteur de transcription vocale et d'intelligence artificielle. **Sans cette cle, rien ne fonctionne.**

1. Va sur **https://console.groq.com**
2. Cree un compte (gratuit)
3. Va dans **API Keys** > **Create API Key**
4. Copie la cle (format `gsk_...`)

### Configurer la cle

Cree un fichier `.env` a la racine du projet :

```
GROQ_API_KEY=gsk_ta_cle_ici
```

### Passer en Dev Tier (recommande, gratuit)

Le Free Tier limite a 6000 tokens/minute (2 commandes rapprochees = rate limit).

1. Sur https://console.groq.com > **Settings** > **Billing**
2. Clique **Upgrade to Dev Tier**
3. Ajoute une carte bancaire (rien n'est facture tant que tu restes sous les limites)
4. Limite passe a **100 000 tokens/minute** -- aucune limitation en usage normal

---

## Etape 5 -- Connecter Spotify (optionnel)

Permet de controler la musique par la voix : "joue du jazz", "pause", "like ce titre", "mets la musique sur mon ordinateur".

### 5.1 Creer une app Spotify Developer

1. Va sur **https://developer.spotify.com/dashboard**
2. Clique **Create App**
3. Nom : `Cobalt Task`, Description : `Assistant vocal`
4. **Redirect URI** : `cobalttask://spotify-callback` (IMPORTANT : copie exactement)
5. Coche **Web API**
6. Copie le **Client ID**

### 5.2 Ajouter ton compte en utilisateur test

En mode Development (avant publication), seuls les comptes ajoutes manuellement peuvent utiliser l'app :

1. Dans le dashboard Spotify > ton app > **Settings** > **User Management**
2. Ajoute l'email de ton compte Spotify

### 5.3 Configurer dans Cobalt

Ajoute dans le fichier `.env` :

```
SPOTIFY_CLIENT_ID=ton_client_id_ici
```

Puis dans l'app : **Parametres** (tap sur "Cobalt Task") > **Comptes** > **Connecter Spotify**

---

## Etape 6 -- Connecter Google (optionnel)

Permet la synchronisation avec Google Tasks, Calendar, Contacts et Docs.

### Dans l'app

**Parametres** > **Comptes** > **Connecter Google**

L'app ouvre la page de connexion Google. Connecte-toi avec ton compte et accepte les permissions (Tasks, Calendar, Contacts, Docs, Drive).

### Prerequis technique (pour les developpeurs)

L'app utilise `google_sign_in`. Le SHA1 de l'APK doit etre enregistre dans la Google Cloud Console :

1. https://console.cloud.google.com > ton projet
2. APIs & Services > Credentials > OAuth 2.0 Client IDs
3. Ajoute le SHA1 de ton keystore (`keytool -list -v -keystore ~/.android/debug.keystore`)

---

## Etape 7 -- Navigation (optionnel)

### Google Maps avec briefing vocal

Pour avoir un resume vocal du trajet avant le lancement de Maps :

```
GOOGLE_MAPS_API_KEY=ta_cle_ici
GEMINI_API_KEY=ta_cle_ici
```

- Google Maps API Key : https://console.cloud.google.com > APIs > Directions API > Enable > Credentials
- Gemini API Key : https://aistudio.google.com/apikey

Sans ces cles, la navigation fonctionne quand meme (Maps s'ouvre directement, sans briefing vocal).

---

## Etape 8 -- Connecter le bracelet Cobalt Voice (optionnel)

1. Charge le bracelet et allume-le (appuie sur un bouton)
2. Ouvre Cobalt Task -- le bracelet apparait dans la liste (icone montre en haut a droite)
3. Tape sur le bracelet pour le connecter
4. L'icone passe en vert = connecte

### Comment utiliser le bracelet

| Geste | Action |
|---|---|
| Appui simple (D1) | Play/Pause musique |
| Double appui (D1) | Piste suivante |
| Triple appui (D1) | Bookmark GPS |
| Appui long (D1) | Enregistrer une commande vocale |
| Vol+ simple | Volume + |
| Vol+ double | Piste suivante |
| Vol+ triple | Mute/Unmute |
| Vol- simple | Volume - |
| Vol- double | Piste precedente |
| Vol- triple | Assistant vocal |

### Reconnexion automatique

Le bracelet se met en veille apres 30 secondes sans connexion. Pour le reveiller, appuie sur n'importe quel bouton. L'app se reconnecte automatiquement en quelques secondes.

---

## Etape 9 -- Configurer les services preferes

Tape sur **"Cobalt Task"** en haut a gauche pour ouvrir les **Parametres**.

### Services

| Service | Options | Par defaut |
|---|---|---|
| Musique | Spotify, Deezer, YouTube Music | Spotify |
| Calendrier | Google Calendar, Samsung Calendar, Calendly | Google Calendar |
| Notes | Google Docs, Samsung Notes, Notion | Google Docs |
| Navigation | Google Maps, Waze | Google Maps |
| Messagerie | WhatsApp, Telegram, Signal, Messenger, SMS | WhatsApp |
| Transport | Velo, Voiture, A pied, Transports en commun | Velo |

### Systeme

| Option | Description |
|---|---|
| Bouton Power > Assistant | Active l'assistant via appui long sur Power |
| Notification persistante | Affiche le micro dans les notifications |
| Retour vocal (TTS) | L'assistant parle apres chaque action |
| Son de confirmation | Vibration au debut/fin de l'enregistrement |
| Auto-connexion bracelet | Se reconnecte au bracelet au demarrage |

---

## Fichier .env complet

Voici un template avec toutes les cles possibles :

```env
# OBLIGATOIRE - Transcription vocale et IA
GROQ_API_KEY=gsk_...

# OPTIONNEL - Controle musical
SPOTIFY_CLIENT_ID=...

# OPTIONNEL - Briefing vocal navigation
GOOGLE_MAPS_API_KEY=...
GEMINI_API_KEY=...

# OPTIONNEL - Paiement Open Banking
FINTECTURE_ENV=sandbox
FINTECTURE_APP_ID=...
FINTECTURE_APP_SECRET=...
FINTECTURE_PRIVATE_KEY=-----BEGIN RSA PRIVATE KEY-----\n...\n-----END RSA PRIVATE KEY-----
```

---

## Commandes vocales disponibles

### Musique
- "Joue du jazz" / "Mets Stromae" / "Ecoute Bohemian Rhapsody"
- "Pause" / "Play" / "Suivant" / "Precedent"
- "Like ce titre"
- "Joue sur mon ordinateur" / "Mets la musique sur le telephone"
- "Monte le son" / "Baisse le volume" / "Son a fond" / "Mute"

### Communication
- "SMS a maman : j'arrive"
- "WhatsApp a Pierre : en route"
- "Dis a Marie que je serai en retard"
- "Appelle papa"

### Calendrier et rappels
- "RDV dentiste demain 14h30"
- "Rappelle-moi d'appeler le medecin"
- "Acheter du lait" (cree un memo)

### Navigation
- "Emmene-moi gare de Lyon"
- "Emmene-moi au travail en velo"
- "Amene-moi au cinema en bus"

### Alarmes et timers
- "Reveille-moi a 7h"
- "Timer de 5 minutes"

### Systeme
- "Allume la lampe"
- "Ouvre Instagram"

### Paiement (si Fintecture configure)
- "Rembourse 20 euros a Paul"
- "Paye 30 euros a Julie pour le resto"

---

## Depannage

### "Rate limit reached" (erreur 429)
Passe au Dev Tier Groq (gratuit). Voir Etape 4.

### La montre ne se connecte pas
1. Appuie sur un bouton du bracelet pour le reveiller
2. Verifie que le Bluetooth et la localisation sont actives
3. Ouvre la fiche montre (icone en haut a droite) pour voir les appareils visibles

### "Erreur like: 403" sur Spotify
Ton compte n'est pas ajoute dans le dashboard Spotify Developer. Voir Etape 5.2.

### Les messages de groupe apparaissent
L'app filtre automatiquement les groupes WhatsApp, Messenger, etc. Si certains passent encore, c'est un faux positif du filtre -- ils seront ameliores au fil des mises a jour.

### L'assistant ne comprend pas ma commande
- Parle clairement et en francais
- Les commandes simples (pause, play, suivant) sont traitees localement sans API
- Les commandes complexes necessitent une connexion Internet (API Groq)
