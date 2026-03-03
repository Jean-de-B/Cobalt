# Cobalt Task - Guide de prise en main

Bienvenue ! Ce guide t'accompagne pas-a-pas pour installer et configurer Cobalt Task sur ton telephone Android.

Temps estime : environ 10 minutes.

---

## Etape 1 - Installer l'application

Tu as recu un fichier `cobalt-task.apk`. C'est le fichier d'installation de l'application.

### 1.1 Autoriser les sources inconnues

Comme l'application n'est pas sur le Play Store, Android va te demander une autorisation speciale.

1. Ouvre le fichier APK (depuis tes fichiers, Telegram, Drive, ou la ou tu l'as recu)
2. Android affiche un message : **"Installation bloquee"** ou **"Source inconnue"**
3. Appuie sur **"Parametres"**
4. Active l'option **"Autoriser cette source"** (ou "Autoriser les installations depuis cette application")
5. Reviens en arriere et appuie sur **"Installer"**

> C'est normal, c'est juste parce que l'app n'est pas encore sur le Play Store. Tu peux desactiver cette option apres l'installation si tu veux.

### 1.2 Installer

1. Appuie sur **"Installer"**
2. Attends quelques secondes
3. Appuie sur **"Ouvrir"**

L'application est installee !

---

## Etape 2 - Premier lancement et permissions

Au premier lancement, l'app va te demander plusieurs autorisations. **Accepte-les toutes**, elles sont necessaires au bon fonctionnement :

| Permission demandee | A quoi ca sert |
|---|---|
| **Microphone** | Enregistrer ta voix (c'est le coeur de l'app !) |
| **Contacts** | Trouver les bons destinataires quand tu dictes un SMS ou un appel |
| **Telephone** | Passer des appels vocaux directement |
| **SMS** | Envoyer des SMS par la voix |
| **Localisation** | Necessaire pour le Bluetooth et la navigation GPS |
| **Bluetooth** | Se connecter au bracelet Cobalt (si tu en as un) |

> Si tu refuses une permission par erreur, tu peux la reactiver dans : Parametres Android > Applications > Cobalt Task > Autorisations

### Permissions speciales (optionnelles mais recommandees)

L'app peut aussi te proposer :

- **Superposition d'ecran** : permet d'utiliser Cobalt meme ecran verrouille (un bouton "Autoriser" te redirige vers les parametres)
- **Acces aux notifications** : permet a Cobalt de savoir de quelle app vient un message pour y repondre intelligemment
- **Assistant par defaut** : permet d'activer Cobalt avec un appui long sur le bouton Power

Pour chacune, l'app t'explique ce qu'elle fait. Accepte celles qui t'interessent.

---

## Etape 3 - Connecter ton compte Google

C'est **l'etape la plus importante**. Sans Google, l'app fonctionne en local, mais avec Google, tes notes, taches et evenements se synchronisent automatiquement.

### 3.1 Se connecter

1. Sur l'ecran principal, regarde en haut a droite : il y a une **icone nuage grise**
2. Appuie dessus
3. Un menu s'ouvre en bas de l'ecran : appuie sur **"Connecter Google"**
4. Choisis ton compte Google (ou connecte-toi)
5. **Ecran important** : Google affiche un avertissement :

> **"Cette application n'a pas ete validee par Google"**
>
> C'est **normal** ! L'app est en phase de test. Pour continuer :
> 1. Appuie sur **"Avance"** (ou "Advanced") en bas a gauche
> 2. Puis sur **"Acceder a Cobalt Task (non securise)"** (ou "Go to Cobalt Task (unsafe)")

6. Google te demande d'autoriser l'acces a :
   - Google Tasks (tes listes de taches)
   - Google Calendar (ton agenda)
   - Google Contacts (tes contacts)
   - Google Drive et Docs (tes memos)
7. Appuie sur **"Tout autoriser"** puis **"Continuer"**

### 3.2 Verifier la connexion

- L'icone nuage en haut a droite devient **bleue**
- En appuyant dessus, tu vois ton nom et ton email

C'est bon, tu es connecte !

> **Note** : le token Google expire tous les 7 jours en mode test. Si l'app te redemande de te connecter, c'est normal : refais l'etape 3.1.

---

## Etape 4 - Connecter Spotify (optionnel)

Si tu veux controler ta musique par la voix (lecture, pause, piste suivante, recherche de chanson...), connecte Spotify.

### 4.1 Prerequis

- Avoir l'app **Spotify** installee sur ton telephone
- Avoir un **compte Spotify** (gratuit ou premium)

### 4.2 Se connecter

1. Sur l'ecran principal, repere l'**icone note de musique** en haut a droite (a cote du nuage Google)
2. Appuie dessus
3. Appuie sur **"Connecter Spotify"**
4. Spotify s'ouvre dans le navigateur : connecte-toi avec ton compte
5. Autorise l'acces
6. Tu es redirige automatiquement vers Cobalt Task

### 4.3 Verifier la connexion

- L'icone note de musique devient **verte**
- En appuyant dessus, tu vois "Spotify connecte" et le morceau en cours si tu ecoutes de la musique

> **Note** : Si la connexion Spotify ne fonctionne pas, verifie que ton compte a bien ete ajoute a la liste des testeurs. Demande-moi de t'ajouter si besoin.

---

## Etape 5 - C'est pret ! Comment utiliser l'app

### Enregistrer un memo vocal

1. **Appui long** sur le gros **bouton rouge micro** en bas de l'ecran
2. Parle naturellement en francais
3. **Relache** le bouton quand tu as fini

L'app va automatiquement :
- Transcrire ta voix en texte
- Comprendre ce que tu veux faire (tache, courses, evenement, contact, memo)
- Classer ta note dans la bonne categorie
- Synchroniser avec Google si tu es connecte

### Lire tes notes

- Chaque note apparait comme une **carte coloree** sur l'ecran principal
- **Appuie** sur une carte pour la deplier et voir le texte complet + ecouter l'audio
- **Glisse vers la gauche** pour supprimer une note

### Les categories (automatiques)

L'app decide toute seule quelle categorie utiliser :

| Couleur | Categorie | Exemple de ce que tu dis |
|---|---|---|
| Bleu | **Tache** | "Faut que j'appelle le plombier" |
| Cyan | **Courses** | "Acheter du lait, des oeufs et du pain" |
| Vert | **Evenement** | "Rendez-vous chez le medecin vendredi 14h" |
| Violet | **Contact** | "Marie, 06 12 34 56 78" |
| Orange | **Memo** | "Idee : refaire la deco du salon" |

---

## Etape 6 - Les commandes vocales

Tu peux faire bien plus que des notes ! Voici tout ce que tu peux dire :

### Messagerie et appels
- *"Envoie un SMS a Pierre : je suis en route"*
- *"Appelle Maman"*
- *"WhatsApp a Sarah : t'es libre ce soir ?"*

### Alarmes et minuteurs
- *"Mets une alarme pour 7h demain"*
- *"Minuteur 10 minutes"*

### Musique (si Spotify connecte)
- *"Joue du jazz"*
- *"Piste suivante"*
- *"Pause"*

### Navigation
- *"Navigue vers la gare Saint-Lazare"*
- *"Itineraire a pied vers le parc"*

### Controles systeme
- *"Augmente le volume"*
- *"Active la lampe torche"*
- *"Mode silencieux"*

---

## Depannage

### "L'app me dit que le contact n'est pas confirme"
La premiere fois que tu envoies un message a quelqu'un, Cobalt te demande de confirmer que c'est le bon contact. Ouvre l'app, valide le contact, et les prochains messages partiront automatiquement.

### "Google me redemande de me connecter"
En mode test, la connexion expire tous les 7 jours. Refais simplement l'etape 3.

### "Spotify ne repond pas"
Verifie que Spotify est ouvert en arriere-plan sur ton telephone. L'app controle Spotify a distance mais il doit etre actif.

### "L'app ne capte pas ma voix"
- Verifie que la permission Microphone est bien accordee
- Essaie dans un endroit plus calme
- Parle a volume normal, pas besoin de crier

### "Je n'arrive pas a installer l'APK"
Verifie que tu as bien autorise les sources inconnues (etape 1.1). Sur certains telephones Samsung, le chemin est : Parametres > Biometrie et securite > Installation applis inconnues.

---

## En resume

| Etape | Quoi faire | Temps |
|---|---|---|
| 1 | Installer l'APK | 2 min |
| 2 | Accepter les permissions | 1 min |
| 3 | Connecter Google (obligatoire pour la synchro) | 3 min |
| 4 | Connecter Spotify (optionnel) | 2 min |
| 5 | Parler dans le micro ! | Immediat |

**C'est tout !** Amuse-toi bien avec Cobalt Task. Si tu as un bug ou une question, n'hesite pas a me contacter directement.
