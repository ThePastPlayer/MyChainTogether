# Chained Together LAN

Lanceurs Windows pour heberger et rejoindre une partie LAN de Chained Together.
Chaque joueur utilise automatiquement son pseudo Steam ; si aucun compte ne peut
etre choisi avec certitude, le lanceur demande un pseudo. Les deux PC conservent
des identites LAN distinctes. Le jeu doit deja etre installe sur chaque PC.

## Installation

Telechargez le depot avec **Code > Download ZIP**, puis extrayez-le entierement.
Ouvrez le dossier `ChainedTogether-LAN` :

- Hote : `Heberger-LAN.cmd`.
- Client : `Rejoindre-LAN.cmd`.
- Choix manuel du pseudo : `Heberger-LAN.cmd -AskPlayerName` ou
  `Rejoindre-LAN.cmd -AskPlayerName`.
- Mise a jour manuelle : `Mettre-A-Jour.cmd`.
- Rapport sans lancer le jeu : `Diagnostic-LAN.cmd`.
- Retour aux fichiers d'origine : `Restaurer-Steam.cmd`.

Le dossier du jeu est recherche dans Steam, les bibliotheques et les disques
locaux. Les menus automatiques sont verifies pour le build Steam **25325926**.
Les details et les limites des essais sont dans `ChainedTogether-LAN/README.txt`
et `ChainedTogether-LAN/ANALYSE.txt`. Une partie sur deux PC physiques reste a
valider ; les tests isoles ne la remplacent pas.

## Mises a jour automatiques

Les raccourcis de jeu verifient la branche `main` de ce depot, au maximum une
fois toutes les 15 minutes. Ils telechargent seulement les fichiers differents,
tous depuis le meme commit, puis verifient le manifest `SHA256SUMS.txt`.
Une erreur de copie provoque une restauration ; un fichier modifie manuellement
est protege. Sans reseau, le lancement reste possible avec la version locale.
`-SkipUpdate` saute cette verification. Les diagnostics, restaurations et
preparations sans lancement restent sans verification reseau.

Un depot prive necessite un acces de lecture : variable d'environnement
`CHAINED_LAN_GITHUB_TOKEN`, jeton finement limite a **Contents: read** pour ce
seul depot. Le jeton ne doit jamais etre commite ou partage dans le ZIP.
Un depot public permet la mise a jour sans compte GitHub.

Le serveur ne recoit aucun pseudo, SteamID, journal ou chemin de jeu : le client
lit uniquement les fichiers du depot. Les mises a jour concernent le lanceur,
pas l'installation du jeu.

## Developpement et distribution

Windows PowerShell 5.1 est pris en charge. Depuis la racine du depot :

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ChainedTogether-LAN/tests/Test-GamePaths.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ChainedTogether-LAN/tests/Test-PlayerNames.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ChainedTogether-LAN/tests/Test-Updates.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/Build-Package.ps1 -RefreshHashes
```

Apres une modification, augmentez `launcher-version.txt`, reconstruisez le
manifest et le ZIP, puis commitez les sources et `SHA256SUMS.txt` ensemble.
Sans `-RefreshHashes`, la construction verifie les empreintes existantes.
Le ZIP de `dist/` contient uniquement les fichiers distribues, sans journaux,
preferences personnelles, installation de jeu ni identite locale.

Le payload Goldberg est accompagne de sa licence GPL et des licences de ses
dependances, avec le commit source et la provenance de compilation. Les modules
de menus, leurs empreintes et leur methode de generation sont documentes dans
`payload/menu/menu-provenance.json`. Aucun fichier du jeu complet n'est inclus.
