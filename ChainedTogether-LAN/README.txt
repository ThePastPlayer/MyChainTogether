CHAINED TOGETHER - LANCEUR LAN

La partie complete entre deux PC reste a confirmer. Les verifications realisees
sont detaillees dans ANALYSE.txt. Version du jeu analysee : build Steam 25325926.

UTILISATION
1. Installez la meme version de Chained Together sur les deux ordinateurs.
2. Extrayez tout le ZIP dans un vrai dossier sur chacun des PC. Ne lancez pas
   les raccourcis directement depuis la vue ZIP de Windows.
3. PC hote : double-cliquez Heberger-LAN.cmd. Le jeu ouvre directement le menu
   Create Session avec 2 Players selectionne, mode Beginner et Opened Chain.
   Validez Create Session pour ouvrir le salon. Une fois les joueurs reunis,
   terminez les choix du jeu puis cliquez Play.
4. Second PC : double-cliquez Rejoindre-LAN.cmd. Le jeu ouvre directement
   le navigateur des parties. Actualisez puis choisissez la partie de l'hote.
   Les invitations Steam sont inutiles.

Les logos de demarrage peuvent encore apparaitre. L'ouverture du bon menu
se fait dans le jeu, sans coordonnees de clic ni simulation du clavier.
Le dernier role est memorise sur chaque PC ; Lancer-LAN.cmd le reprend.
Le pseudo du compte Steam actif est repris automatiquement sur chaque PC.
Steam ferme, le compte marque MostRecent ou utilise le plus recemment est choisi.
En l'absence de pseudo fiable, le lanceur demande un pseudo au demarrage.
Les accents sont conserves. Une saisie manuelle est memorisee uniquement sur
ce PC et proposee la fois suivante ; Entree la conserve. Le nom de la machine
n'est plus utilise. Un changement de pseudo est applique automatiquement au
prochain lancement, apres verification des sauvegardes et des fichiers du jeu.
Pour choisir un autre pseudo meme si Steam est disponible :
  Heberger-LAN.cmd -AskPlayerName
  Rejoindre-LAN.cmd -AskPlayerName
Un pseudo explicite reste prioritaire : Rejoindre-LAN.cmd -PlayerName "Leo".
Pour retrouver les menus habituels, lancez Lancer-LAN.cmd -Role Manual.
Fermez le jeu avant de changer de role ou de restaurer Steam.

Le dossier du jeu est recherche depuis Steam et ses bibliotheques. Si Steam
ne le declare pas, le lanceur scanne les dossiers de jeux et les disques
locaux/USB disponibles pour trouver ChainedTogether-Win64-Shipping.exe.
Le dossier du jeu peut avoir un nom quelconque. L'executable x64 et la DLL
Steam doivent etre presents. Les dossiers proteges de Windows et les liens
ne sont pas parcourus. La recherche est limitee a 30 secondes dans les
dossiers habituels, puis 90 secondes sur les disques. Si aucun jeu n'est
trouve, une fenetre permet de choisir son dossier ; plusieurs installations
peuvent etre selectionnees par leur numero. Les diagnostics restent sans
selection interactive. Heberger, Rejoindre, Lancer, Restaurer et Autoriser
partagent cette detection. Aucun disque d'installation n'est fixe.
Un ancien gamePath dans launcher-settings.json qui n'existe plus declenche
une nouvelle recherche. Un chemin relatif dans ce fichier part du dossier
du lanceur. Le chemin utilise avec succes est memorise uniquement dans le
profil de chaque PC, pas dans le ZIP. -GamePath reste disponible pour choisir
explicitement le dossier. Copiez toujours le dossier du lanceur complet.

Les menus automatiques sont prevus pour le build Steam 25325926 : le lanceur
verifie le build dans le manifeste Steam, l'empreinte de l'executable et
les deux paquets de menus. Si le jeu est deplace sans manifeste, le SHA256
complet du PAK original est aussi verifie ; cela peut prendre quelques minutes.
Apres une mise a jour incompatible, utilisez
le role Manual ou un pack adapte a la nouvelle version.

Verification sur ce PC : demarrage Host et Join depuis le vrai lanceur,
menu Host a deux joueurs, creation d'un salon et retour depuis le menu Join.
Une partie entre deux PC physiques, Internet coupe, reste a confirmer.

Les deux PC doivent etre sur le meme reseau local. Vous pouvez deconnecter
la connexion Internet du routeur en gardant le Wi-Fi/Ethernet actif.
Le lanceur prepare automatiquement la configuration et lance le jeu.
Il genere une identite distincte sur chaque ordinateur.

SI LA PARTIE N'APPARAIT PAS
- Si Windows demande l'autorisation reseau du jeu, autorisez le reseau prive.
- Autoriser-LAN.cmd permet d'ajouter une regle limitee au jeu, au reseau prive
  et au sous-reseau local (TCP/UDP 47584). Windows demandera les droits admin
  pour cette operation. Ce helper est facultatif et n'est pas lance automatiquement.
- Si la decouverte par broadcast ne passe pas, indiquez l'IPv4 locale du partenaire :
  Rejoindre-LAN.cmd -PeerIP 192.168.1.20
  Si le jeu a deja ete prepare, lancez d'abord Restaurer-Steam.cmd avant de
  changer cette option. Faites la meme chose sur l'autre PC avec l'IP inverse.
- Evitez un reseau Wi-Fi invite qui isole ses utilisateurs ; gardez les memes mods.

AUTRES OPTIONS
Lancer-LAN.cmd -GamePath "F:\SteamLibrary\steamapps\common\ChainedTogether"
Lancer-LAN.cmd -PlayerName "Joueur1"
Lancer-LAN.cmd -AskPlayerName
Lancer-LAN.cmd -SkipUpdate
Lancer-LAN.cmd -PrepareOnly
Lancer-LAN.cmd -Diagnose
Heberger-LAN.cmd -Diagnose
Rejoindre-LAN.cmd -Diagnose
Diagnostic-LAN.cmd
Restaurer-Steam.cmd -Diagnose
Autoriser-LAN.cmd -WhatIf
Heberger-LAN.cmd -PrepareOnly
Rejoindre-LAN.cmd -GamePath "F:\SteamLibrary\steamapps\common\ChainedTogether"

Les diagnostics verifient les chemins sans lancer le jeu ni modifier ses
fichiers. Les roles Host et Join verifient aussi leur menu automatique.
Diagnostic-LAN.cmd cree Diagnostic-LAN.txt dans le dossier du lanceur.
En cas d'erreur, Rejoindre-LAN.log conserve aussi le message et les chemins
detectes. Le debut du lancement affiche la version du paquet :
2026-10-14-pseudos-autoupdate-v2. Un ancien ZIP n'affiche pas cette version.
Tests isoles de detection (depuis le dossier du lanceur) :
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\Test-GamePaths.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\Test-PlayerNames.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\Test-Updates.ps1

MISES A JOUR
Heberger, Rejoindre et Lancer verifient automatiquement le depot
https://github.com/ThePastPlayer/MyChainTogether sur sa branche main.
La verification est espacee de 15 minutes. Sans Internet ou si GitHub est
indisponible, le lancement continue avec le paquet local. -SkipUpdate permet
de sauter la verification ; -Diagnose, -Restore et -PrepareOnly ne la font pas.
Mettre-A-Jour.cmd force la verification et affiche les erreurs detaillees.
Mettre-A-Jour.cmd -CheckOnly verifie sans installer de mise a jour.
Les fichiers proviennent tous d'un meme commit GitHub et leurs SHA256 sont
verifies avant installation. Une erreur de copie declenche une restauration.
Les fichiers locaux modifies manuellement ne sont pas ecrases. Les journaux,
preferences personnelles et fichiers du jeu ne font pas partie des mises a jour.
La mise a jour du lanceur ne met pas le jeu lui-meme a jour.
Un depot public est lisible sans compte. Pour un depot prive, un jeton GitHub
limite a la lecture Contents de ce seul depot peut etre fourni dans la variable
d'environnement CHAINED_LAN_GITHUB_TOKEN. Il n'est ni journalise ni copie dans
le paquet. Ne partagez pas un jeton personnel dans un ZIP ou sur GitHub.

REVENIR A STEAM
Fermez le jeu puis double-cliquez Restaurer-Steam.cmd.
Les originaux sont sauvegardes dans <jeu>\.chained-lan ; la restauration
verifie les SHA256 et refuse d'ecraser des fichiers modifies entre-temps.
Une mise a jour Steam peut donc necessiter une nouvelle preparation.
Pour retirer les regles du helper : Autoriser-LAN.cmd -Remove.

INFORMATIONS
La DLL Goldberg regular x64 a ete compilee localement depuis les sources
epinglees. Elle remplace uniquement la DLL SteamCorePro identifiee au runtime.
Aucune exclusion antivirus ni modification globale de Steam n'est faite.
Le lanceur n'a besoin d'aucun telechargement pour preparer et demarrer le jeu.
La configuration offline=0 maintient BLoggedOn() vraie, sans exiger Internet.
SHA256, provenance et licences : dossier payload.

L'identite par PC est conservee dans
%LOCALAPPDATA%\ChainedTogether-LAN\identity.json ; ne copiez pas ce fichier
sur le second ordinateur. Le dossier du lanceur, lui, est portable.
Le role local est conserve dans launcher-preferences.json dans le meme dossier.
Le chemin du jeu est conserve dans game-location.json dans le meme dossier ;
ne copiez pas ce fichier de profil sur le second ordinateur.
Les pseudos manuels sont conserves dans player-preferences.json et les dates
de verification GitHub dans update-check.json, toujours dans le profil local.

Source : https://github.com/Detanup01/gbe_fork
