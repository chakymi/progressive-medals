# Progressive Medals — prototype Openplanet (Trackmania 2020)

Plugin natif AngelScript dans [`plugin/`](plugin/), indépendant de tout serveur. Le catalogue embarqué **ne contient que trois UID fictifs** : il permet de tester l'interface, mais ne décerne aucune médaille sur les vraies cartes tant qu'un catalogue contenant leurs UID n'est pas publié. Les **trois** objectifs Platine → Émeraude → Diamant sont identiques pour tous les joueurs utilisant la même version du catalogue ; Champion reste une référence externe distincte, jamais utilisée pour leur calcul. Il n'est donc pas garanti que Diamant soit toujours plus facile que Champion. Le WR utilisé pour la génération est figé ; la fenêtre ne recalcule jamais les seuils. La version 4 répartit les trois objectifs à **30 / 60 / 90 %** de l'écart Auteur→WR figé.

## Installer et vérifier dans le jeu

1. Installer Trackmania 2020 et [Openplanet](https://openplanet.dev/docs/tutorials/installation). Le chargement d'un plugin non signé nécessite le mode **Developer** et, selon [la documentation Openplanet](https://openplanet.dev/docs/tutorials/writing-plugins), **Club Edition**. Dans le jeu, ouvrir Openplanet avec **F3**, puis `Openplanet → Signature Mode → Developer` ; redémarrer si nécessaire. Ce mode active aussi [School Mode](https://openplanet.dev/docs/school-mode) : les nouveaux temps ne sont généralement pas enregistrés dans les classements officiels.
2. Dans F3, ouvrir le dossier utilisateur Openplanet, puis `Plugins` (habituellement `%USERPROFILE%\OpenplanetNext\Plugins`). Copier **uniquement le dossier `plugin`** de ce projet sous le nom `ProgressiveMedals` : on doit obtenir `Plugins\ProgressiveMedals\info.toml`, `Main.as`, `Catalog.as`, `Medals.as`, `Window.as`, `UME.as`, `catalog\catalog-v2.json` et les trois PNG de `assets/`. Ne pas copier `tools/`. Le fichier `catalog-v1.json` est conservé pour les tests historiques, mais n'est plus chargé par la nouvelle version.
3. Ouvrir `F3 → Developer`, charger `Progressive Medals` ; ouvrir sa fenêtre par le menu `Progressive Medals`. Lire les éventuelles erreurs de compilation dans la console/journal Openplanet.
4. Cliquer `Vérifier le chargeur` : attendre `Chargeur v2 OK : 3 paliers, doublon et WR anticipé refusés`. Puis cliquer `Voir les cartes fictives` et `Carte suivante` : trois temps ordonnés s'affichent pour chacune des trois cartes. Saisir `59780` puis `53593` dans le PB fictif de la première carte : vérifier Platine, Émeraude, Diamant, le prochain objectif et l'écart. Saisir `0` pour l'état sans PB. La deuxième carte teste un écart Auteur–WR de 10 ms.
5. Cliquer `Revenir à la carte`, charger une **carte Fall 2026** : nom, UID, temps Auteur, PB officiel déjà enregistré (s'il est accessible en TimeAttack), trois PNG et trois objectifs du catalogue HTTPS v3 doivent apparaître. Une carte non publiée reste sans objectif. Changer de carte pour vérifier la réinitialisation. En School Mode, le résultat d'une nouvelle course peut apparaître sur l'écran d'arrivée sans être enregistré comme PB officiel ; le plugin ne le présente pas comme tel.
6. Facultatif : installer Ultimate Medals Extended et Warrior Medals. Recharger le plugin ; UME peut afficher les trois niveaux pour les UID publiés, Warrior est affiché séparément quand il dispose déjà d'un temps en cache. Vérifier leur compatibilité sur une vraie carte **après publication d'un vrai UID**. Champion reste explicitement désactivé jusqu'à vérification de son interface publique officielle.

L'ancienne version à dix niveaux a été chargée dans Trackmania/Openplanet : trois démos, décodeur réel, PB officiels préexistants et changement de carte ont fonctionné selon les captures reçues. La version du calendrier a ensuite été copiée et son test « WR anticipé refusé » confirmé. La version **0.2.0** à trois niveaux a été rechargée : catalogue HTTPS v3, visuels PNG et progression ont été confirmés sur Fall 2026 - 06 (PB préexistant). Le retour hors ligne, le cycle horaire et UME restent à tester en jeu. Le mode démo ne modifie ni les résultats ni les médailles natives du jeu.

## Règle commune d'apparition (UTC)

| `release.kind` | Point de départ commun (`anchorAtUtc`) | Heure minimale de relevé du WR et de publication |
| --- | --- | --- |
| `campaign` | ouverture officielle de la campagne | + 604 800 s = 7 jours |
| `totd` | ouverture officielle du circuit du jour | + 3 600 s = 1 heure |
| `launchCampaign` | lancement commun fixé **une seule fois** pour la campagne déjà en cours | + 3 600 s = 1 heure |

L'heure d'installation locale **n'est jamais** un point de départ. À l'heure minimale, l'éditeur du catalogue relève un WR public et l'horodate (`wrCapturedAtUtc`), génère trois seuils et publie le même JSON pour tous (`publishedAtUtc`). Si le relevé ou la publication a du retard, la carte n'a pas d'objectifs tant que le JSON n'est pas publié ; aucun temps provisoire n'est inventé. Le décodeur vérifie que `availableAtUtc = anchorAtUtc + délai`, que le WR a été capturé à cette heure ou après et que la publication n'a pas précédé le relevé. Le générateur refuse également une date de publication dans le futur. Le client masque les seuils avant leur date de publication ; UME applique le même contrôle. Le WR n'est jamais demandé depuis le jeu pour générer un objectif. Champion reste indépendant.

Pour Fall 2026 (exception `launchCampaign`), l'auteur a fixé le **T0 commun au 13 octobre 2026 à 21:03:09 UTC**, soit `launchAtUtc = 1791925389`. L'heure minimale de relevé des WR est le **13 octobre 2026 à 22:03:09 UTC**, soit `availableAtUtc = 1791928989`. Cette heure n'est liée à aucune installation individuelle. Le catalogue v3 des 25 cartes a été publié après cette heure sur GitHub Pages ; la version 4 rééquilibre uniquement les paliers et garde [l'ancien catalogue v3](https://chakymi.github.io/progressive-medals/catalogue-v3.json) consultable. [Les preuves](https://chakymi.github.io/progressive-medals/catalogue.evidence.json) donnent les WR d'origine et leurs heures de relevé, **inchangés** entre v3 et v4.

### Préparation automatique des 25 cartes Fall 2026

`tools/fall-2026-roster.json` contient les **25 UID et temps Auteur** préparés depuis les fiches Trackmania Exchange (cartes 01–20 et 21–25, ces dernières portant des noms de pays). `python -B tools/publish_fall_2026.py --check-roster` vérifie à nouveau **chaque UID, auteur et provenance Nadeo** via les 25 fiches publiques Trackmania.io ; cela n'interroge aucun WR et peut se faire avant T0+1 h.

À partir de **22:03:09 UTC seulement**, `python -B tools/publish_fall_2026.py --publish` interroge les 25 classements publics Trackmania.io une seule fois, horodate chaque relevé, refuse les cartes manquantes, un auteur modifié, un WR non classé premier ou un écart inférieur à **3 ms** ; puis génère `catalogue-fall-2026-v3.json` (25 cartes et 3 démos, trois objectifs chacune) et `catalogue-fall-2026-v3.evidence.json` (UID, WR, date et URL de source). Entre deux lectures publiques, il attend 2,5 s ; sur HTTP 429, il respecte `Retry-After` avec au plus deux nouveaux essais bornés. En cas d'échec, **aucun catalogue partiel** n'est créé et le workflow GitHub peut retenter l'heure suivante. Une version 3 déjà présente n'est jamais écrasée par un WR plus récent. L'option `--wait --publish` permet de laisser le script ouvert avant l'heure minimale : il attend puis tente **une fois** la capture. Le PC doit rester allumé et le script en cours ; aucun déclencheur Windows n'est installé automatiquement.

Ces commandes CLI produisent des fichiers **locaux uniquement**. Elles ne téléchargent aucun jeton d'authentification, ne modifient pas le plugin installé, n'ouvrent aucun serveur, ne publient rien sur Internet et ne créent pas de tâche planifiée. Le catalogue commun est maintenant servi à `https://chakymi.github.io/progressive-medals/catalogue.json`, configuré par défaut dans `plugin/Main.as`. Le plugin vérifie au démarrage et au plus une fois par heure (en plus du bouton manuel). Vider l'URL dans les réglages Openplanet supprime les requêtes ; le catalogue déjà mis en cache reste consultable. La réponse HTTPS et le **chargement réel de v3 sur Fall 2026 - 06 dans Openplanet** ont été confirmés ; le cycle horaire et le cache hors ligne ne l'ont pas encore été. Le producteur pour les **futurs** TOTD et campagnes reste à développer ; les délais sont déjà imposés par le catalogue.

### Dépôt GitHub public et publication effective

Une liste positive `.gitignore` ne retient que les sources/JSON publics et `.github/workflows/publish-fall-2026.yml` ; la note privée du Second Cerveau, caches, secrets éventuels et fichiers locaux produits hors `docs/` sont exclus. Le workflow GitHub lance les tests et vérifie **chaque heure à la minute 17 UTC** si T0+1 h est passé. Le premier essai de 22:03 UTC a échoué sur HTTP 429 sans publier de catalogue. Après correction et ralentissement des appels, [l'exécution suivante](https://github.com/chakymi/progressive-medals/actions/runs/38476821948) a publié le lot complet de 25 cartes, enregistré `docs/catalogue.json` et `docs/catalogue.evidence.json` dans la branche `main` puis déployé **seulement `docs/`** sur GitHub Pages. La version 3 n'est plus recalculée ; le déploiement Pages reste réessayable. Aucune clé Nadeo ni jeton personnel requis pour ces deux endpoints publics Trackmania.io ; GitHub fournit son jeton de workflow pour écrire dans son propre dépôt.

Le [dépôt public](https://github.com/chakymi/progressive-medals) et GitHub Pages (source GitHub Actions) sont actifs. Le catalogue v3 original avait été vérifié en HTTPS : schéma 2, 28 entrées dont 25 UID réels et 25 preuves WR correspondantes. `tools/rebalance_v4.py` compare tous ces éléments avant de proposer la v4 à **30 / 60 / 90 %** ; `python -B tools/rebalance_v4.py` réalise uniquement la vérification locale, `--publish` archive v3 et prépare localement les fichiers v4 à revoir/commiter. Aucune nouvelle requête au classement WR n'est effectuée. Le workflow Fall 2026 ne recalcule pas un catalogue déjà présent. L'automatisation des saisons et TOTD suivants demandera un producteur supplémentaire.

## Publier des cartes réelles

1. Après la date définie ci-dessus, relever l'UID réel, le temps Auteur en ms et le WR à cet instant, avec source et date UTC. Créer un **nouveau** JSON source de schéma 2 avec `version` **4 minimum** pour la politique actuelle, les cartes voulues et les trois démos si leur mode doit rester utilisable. Laisser au moins **3 ms** entre WR et Auteur. Une carte éditée avec le même UID mais un nouveau temps Auteur est désactivée par sécurité jusqu'à publication corrigée.
2. Depuis ce dossier, exécuter `python tools/generate.py source-v4.json catalogue-public.json`. La politique v4 est linéaire : 30 % (Platine), 60 % (Émeraude), 90 % (Diamant) de l'écart Auteur→WR, arrondis à la milliseconde avec correction des doublons ; trois temps strictement décroissants dans `[WR, Auteur[`. `--power` ne concerne que les anciennes versions 1–3 utilisant smoothstep. Un écart de moins de 3 ms échoue explicitement. Le générateur contrôle aussi l'heure UTC courante : un fichier antidaté ou préparé à l'avance échoue.
3. Vérifier le JSON, le WR et les UID **avant** distribution. Pour un usage hors ligne, remplacer `plugin/catalog/catalog-v2.json` par le catalogue validé (conserver le nom du fichier). Pour les mises à jour automatiques ou manuelles : héberger le JSON sur un HTTPS public en lecture seule, renseigner son URL dans les réglages Openplanet ; la vérification automatique se fait au démarrage puis chaque heure, ou via `Actualiser le catalogue HTTPS`. Sans URL, aucune requête n'est lancée ; le cache est dans le dossier de stockage propre au plugin. La mise à jour est limitée à une tentative/5 min, 12 s, 512 Kio. Seules les versions strictement croissantes remplacent l'état actif. Si le téléchargement ou le JSON échoue, l'ancien catalogue reste actif.
4. Une installation hors ligne embarquant une nouvelle version doit remplacer la version précédente du JSON. Une installation ayant déjà reçu une version plus récente en cache garde celle-ci, même hors ligne.

Source de génération, pour une carte **fictive d'illustration** :

```json
{
  "schema": 2,
  "version": 4,
  "launchAtUtc": 1800000000,
  "maps": {
    "EXAMPLE-UID-NOT-REAL": {
      "name": "Exemple (fictif)", "authorMs": 60000, "referenceWrMs": 51000,
      "release": {
        "kind": "launchCampaign", "anchorAtUtc": 1800000000,
        "wrCapturedAtUtc": 1800003600, "publishedAtUtc": 1800003600
      }
    }
  }
}
```

Les horodatages sont des **secondes Unix UTC**, pas des millisecondes. Pour une nouvelle campagne ou un TOTD, utiliser `kind: "campaign"` ou `"totd"` et prendre pour `anchorAtUtc` l'ouverture officielle correspondante ; `launchAtUtc` ne s'applique qu'à l'exception de la campagne en cours. La sortie ajoute `availableAtUtc` calculé et `timesMs` ; les démos dans un catalogue de schéma 2 emploient `"release":{"kind":"demo"}`. Le schéma 1 version 1 conserve l'ancienne démo à dix niveaux **uniquement comme historique local** ; la version 2 contient les démos actuelles à trois paliers. Les niveaux sont ordonnés Platine → Émeraude → Diamant. Les PNG fournis par chakymi se trouvent dans `plugin/assets/` et sont chargés une fois par `UI::LoadTexture`, puis affichés dans la fenêtre via `UI::Image` ; les badges texte 01–03 servent de repli si une texture est indisponible. Leurs inscriptions intégrées sont en anglais (PLATINUM/EMERALD/DIAMOND) tandis que les libellés de la fenêtre restent en français. L'API publique IMedal d'UME ne prévoit qu'une icône textuelle : un cercle reste utilisé dans cette intégration facultative.

## Architecture et contrôles

| Fichier | Rôle |
| --- | --- |
| `plugin/Main.as` | cycle de vie, détection de carte/PB et paramètres |
| `plugin/Catalog.as` | validation atomique, cache, HTTPS facultatif |
| `plugin/Medals.as`, `plugin/Window.as` | noms, attribution, affichage |
| `plugin/assets/` | trois PNG originaux fournis par chakymi |
| `plugin/UME.as` | adaptateur facultatif `IMedal` |
| `tools/generate.py` | calcul hors jeu en fractions exactes, aucune dépendance externe |

Vérification locale : `python -B -m unittest discover -s tools -p 'test_*.py' -v`. Les tests contrôlent écarts serrés, bornes, déterminisme, calendrier, publication prématurée, lot complet de 25 cartes, limitation HTTP 429, concordance de la nouvelle démo, conservation du catalogue historique v1 et intégrité/dimensions/alpha des trois PNG. En jeu, le bouton `Vérifier le chargeur` a confirmé le décodeur v2 ; les trois PNG, le catalogue HTTPS v3, les trois seuils et le PB préexistant ont été contrôlés sur Fall 2026 - 06. UME, rafraîchissement horaire et cache hors ligne n'ont pas encore été validés en jeu.

Références : [API Openplanet](https://openplanet.dev/docs/api), [dépendances facultatives](https://openplanet.dev/docs/tutorials/plugin-dependencies), [interface IMedal UME](https://github.com/ArEyeses79/tm-ultimate-medals-extended/blob/HEAD/Medals/IMedal.as), [exports UME](https://github.com/ArEyeses79/tm-ultimate-medals-extended/blob/HEAD/Exports.as), [exports Warrior](https://github.com/ezio416/tm-warrior-medals/blob/HEAD/src/Export.as). Aucun appel à l'API privée Champion.
