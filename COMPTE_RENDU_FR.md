# Progressive Medals — Rapport de refactorisation v0.8.0

**Base :** v0.7.2 Code clair (25 cartes Fall 2026, calendrier TOTD).
**Objectif :** appliquer les retours de Xertox sans modifier les seuils, images,
positions natives du calendrier ni paramètres de taille des médailles.

## Volume de code AngelScript

Lignes physiques, commentaires et lignes vides compris :

| Fichier | v0.7.2 | v0.8.0 | Différence |
|---|---:|---:|---:|
| `Main.as` | 181 | 193 | +12 |
| `MenuBadges.as` | 249 | 107 | −142 |
| `TotdBadges.as` | 320 | 251 | −69 |
| `SheetCatalogue.as` | 357 | 338 | −19 |
| `OfficialPbs.as` | 83 | 81 | −2 |
| `BadgeCommon.as` (nouveau) | 0 | 172 | +172 |
| **TOTAL** | **1 190** | **1 142** | **−48 (−4,0 %)** |

Le but n'est pas de minimiser artificiellement les lignes : les validations
réseau, le code de protection et les commentaires utiles restent explicites.

## Retours de Xertox : suivi point par point

| Observation | Correctif |
|---|---|
| Rendu NVG dupliqué | Fonction partagée `DrawBadge` et configuration `BadgeLayout` dans `BadgeCommon.as`. |
| Échelle, fallback, bord de l'écran répétés | Calculs communs `MakeBadgeLayout` et `MeasureGridSpacing`. |
| Recherche UILayers dupliquée | `FindBadgeMenuPage(calendar)`, sans conserver de pointeurs. |
| Gestion compte Nadeo à plusieurs endroits | `PlayerPbs`, `SynchronizeAccount`, `RememberBestPb`, `MergeOfficialPbs`. |
| `MenuTarget` identique à `Goals` | Supprimé. Les deux menus consultent les objectifs Sheets `Goals`. |
| `IsMenuUid` et recherche Fall UID | Une recherche unique indexée `FindFall2026IndexByUid`. |
| Liste PNG dupliquée | `ICON_PATHS` utilisée pour les deux types de textures. |
| Ordre des seuils validé 3 fois | `AreValidMedalTimes`, appelée par les deux lecteurs et la comparaison. |
| Code mort / variable `name` | Supprimés lors de la simplification des lecteurs et de l'initialisation. |
| Ternaire inutile du chargement TOTD | Remplacé par des conditions simples de délai. |
| Taille HTTP vérifiée 3 fois | Une garde de téléchargement + une vérification du texte final. |
| Validation des PB incohérente | Même limite `MAX_TIME_MS`, même cache de meilleur temps, même synchronisation de compte. |
| Noms et préfixes de logs incohérents | Nom et préfixe unifiés : `Progressive Medals`. |
| Nombre de cartes « 25 » en dur | Constante `FALL_MAP_COUNT` ; grille séparée `FALL_GRID_SIDE`. |
| Commentaires français/anglais | **Tous les commentaires dans les `.as` sont en anglais**. Interface affichée en français. |
| 80 ans × 12 mois testés par image | Lecture de l'année du titre + cache `(titre, premier jour, version catalogue)`. |
| `GetKeys()` TOTD à chaque image | Index par premier jour du mois recalculé seulement lors d'un nouveau catalogue. |
| `fall-2026-goals.json` duplique le Sheet | Conserve les **25 UID uniquement** (et une note sur les 2 exceptions). |

## Ce qui n'a pas changé

- Les 25 UID Fall 2026 et leur ordre exact.
- Les deux exceptions historiques de Fall 2026, déjà enregistrées dans le snapshot
  Google Sheets : aucune valeur n'a été réécrite ou recalculée.
- Les 12 TOTD du snapshot de secours ; les nouvelles cartes continuent de venir
  du Google Sheet en ligne.
- Les trois PNG, leurs positions de secours `(0,72 ; 0,35)`, la taille par défaut
  **61 px campagne / 56 px TOTD**, les offsets et la disposition des grilles.
- L'accès aux PB Nadeo, le cache local et le rafraîchissement du Sheet.
- Aucune dépendance à Supabase.

## Contrôles réalisés

- Contrôle statique de la structure des six fichiers `.as`.
- Vérification des délimiteurs et absence de commentaires non anglais.
- Vérification des 25 UID de la v0.7.2 dans leur ordre initial.
- Comparaison SHA-256 du snapshot JSON et des PNG : fichiers inchangés.
- Contrôle des 37 entrées du snapshot (25 campagnes et 12 TOTD).
- Contrôle des seuils Platine ≥ Émeraude ≥ Diamant, et de l'exemple de la TOTD
  du 11 novembre (41,885 s → Émeraude).
- Vérification que le rendu NVG et la recherche de la médaille native sont
  factorisés et qu'il n'y a pas de requête réseau dans les fonctions de rendu.
- Script reproductible : `developer_tests/validate_project.py`.

## Limites importantes

**Le plugin n'a PAS été compilé ni exécuté dans Openplanet / Trackmania dans cet
environnement.** Malgré les tests statiques, une régression de compilation ou
un nouveau crash d'interface est encore possible. Les modifications du rendu
et de l'état des PB doivent être validées en jeu avant remplacement définitif.

Recommandation : conserver la v0.7.2 en sauvegarde, tester la v0.8.0 en Developer
et faire relire la branche par Xertox avant toute publication/signature.
Les sources restent identifiées comme ayant été réalisées avec assistance IA.
