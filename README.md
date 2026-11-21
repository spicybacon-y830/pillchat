# PillChat

Réponds à tes iMessage sans ouvrir Messages : une pilule flottante en haut de l'écran, façon notification, pour lire et répondre en deux secondes.

## Installer

1. Télécharge **PillChat.zip** dans la dernière [release](https://github.com/spicybacon-y830/pillchat/releases/latest) et ouvre-le.
2. Glisse **PillChat.app** dans le dossier **Applications**.
3. Ouvre PillChat. L'app n'est pas signée par Apple : la première fois, macOS refuse de l'ouvrir.
   Va dans **Réglages Système → Confidentialité et sécurité**, tout en bas, et clique **Ouvrir quand même**.
   Si macOS dit que l'app est « endommagée », lance cette commande dans le Terminal puis rouvre-la :
   ```bash
   xattr -dr com.apple.quarantine /Applications/PillChat.app
   ```
4. Au premier lancement, PillChat demande l'**Accès complet au disque** (pour lire tes messages) :
   clique « Ouvrir les réglages », active PillChat dans la liste, puis relance l'app.
5. Au premier envoi, autorise PillChat à contrôler **Messages**.

Fonctionne sur les Mac Apple (M1 et suivants) et Intel, macOS 14 ou plus récent, avec iMessage configuré dans Messages.

## Ce que ça fait

- **Notifs compactes** : un message reçu fait apparaître la pilule (nom + derniers messages). Elle disparaît seule après 5 s si tu ne la survoles pas ; au survol, elle se déplie avec la zone de saisie.
- **Accueil** : tes conversations récentes en grille, avec une bulle d'aperçu du dernier message reçu sur chaque photo, et une recherche.
- **Conversation** : texte, emojis rapides, réactions (tapbacks), pièces jointes (trombone, ⌘V, glisser-déposer, jusqu'à 5 fichiers), messages vocaux, appel FaceTime audio.
- **Messages peut rester fermée** : la lecture passe par la base de Messages ; pour envoyer, PillChat ouvre Messages masquée puis la referme.

## Raccourcis

| Raccourci | Action |
|---|---|
| ⌃⌘R | Ouvrir la pilule depuis n'importe quelle app |
| ⌘W | Fermer la pilule |
| @ | Fermer la pilule (quand le curseur n'est pas dans un champ) |
| Échap | Annuler le vocal en cours, sinon rendre le clavier à l'app d'avant |
| Entrée / ⌥ Entrée | Envoyer / aller à la ligne |
| Barre du bas | Glisser pour rallonger ou raccourcir la pilule |
| Bords de la pilule | Glisser pour la déplacer |

## Prérequis pour compiler

- macOS 14 ou plus récent (le verre « liquid glass » demande macOS 26)
- Un compte iMessage configuré dans Messages
- Pour compiler : les outils en ligne de commande Xcode (`xcode-select --install`) — Xcode n'est pas nécessaire

## Compiler soi-même

```bash
./scripts/build.sh                     # produit build/PillChat.app (universelle : Apple + Intel)
cp -R build/PillChat.app /Applications/
open /Applications/PillChat.app
```

Pour publier une version : `./scripts/release.sh` produit `build/PillChat.zip`, à joindre à une release GitHub.

Pour garder les autorisations macOS d'une compilation à l'autre, crée un certificat de signature de code nommé **PillChat Dev** dans Trousseau d'accès ; le script l'utilise s'il existe (sinon signature ad hoc).

## Autorisations demandées

- **Accès complet au disque** : lire `~/Library/Messages/chat.db` (au premier lancement, PillChat explique comment l'activer).
- **Automatisation → Messages** : envoyer les messages via AppleScript.
- **Contacts** : afficher les noms et les photos.
- **Micro** : enregistrer les messages vocaux.

## Structure

```
Sources/PillChat/
  App.swift            Fenêtre, raccourcis, barre des menus
  ChatController.swift État de la pilule (accueil, conversation, notifs, focus)
  Views.swift          Interface SwiftUI
  MessagesDB.swift     Lecture de chat.db (SQLite)
  MessagesStore.swift  Suivi des nouveaux messages, aperçus, non-lus
  Sender.swift         Envoi via Messages (AppleScript)
  Attachments.swift    Photos, vidéos, fichiers, vocaux reçus
  VoiceRecorder.swift  Enregistrement des vocaux
  Contacts.swift       Noms et photos des contacts
  HotKey.swift         Raccourci global ⌃⌘R
  Design.swift         Couleurs, tailles, icônes, journal
scripts/build.sh       Compilation + assemblage de l'app
icon/                  Source et générateur de l'icône
```

Journal de débogage : `~/Library/Logs/PillChat.log`.
