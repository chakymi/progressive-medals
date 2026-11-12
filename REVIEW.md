# Relecture technique — v0.7.2

## Changements ciblés

- **`MenuBadges.as`** : la campagne appelle maintenant `ReadOfficialPbs(...)`,
  déjà utilisé par les TOTD. Cela supprime la duplication de la construction de
  requête HTTP, du timeout et de la validation du JSON.
- **`MenuBadges.as`** : suppression de `ReadMenuMs(...)` : `ReadPositiveMs(...)`
  dans `OfficialPbs.as` effectuait exactement la même validation.
- **`MenuBadges.as` / `TotdBadges.as`** : calcul unique de la meilleure médaille
  avec `HighestBadge(...)`. Les fonctions d'une ligne pour la taille et le
  décalage de la campagne ont été intégrées directement au rendu.
- **`Main.as`** : en-tête mis à jour. **Tailles préservées** : 61 campagne et 56 TOTD.
- **`SheetCatalogue.as`**, ancrages ManiaLink du calendrier/campagne, valeurs
  Google Sheets, images PNG et récupération PB locaux : **non modifiés**.
- Fichier `info.toml` : numéro de version corrigé en 0.7.2.

## Lignes AngelScript (commentaires et lignes vides compris)

| Fichier | Avant (v0.7.1) | Après (v0.7.2) |
| --- | ---: | ---: |
| `Main.as` | 181 | 181 |
| `SheetCatalogue.as` | 357 | 357 |
| `OfficialPbs.as` | 83 | 83 |
| `MenuBadges.as` | 304 | 249 |
| `TotdBadges.as` | 322 | 320 |
| **Total** | **1247** | **1190** |

Ces nombres sont les lignes des fichiers `.as` uniquement. Ils incluent les
commentaires et les lignes vides, mais pas les JSON/PNG/README.

## Pourquoi ne pas tout réécrire ?

La v0.7 était la première version signalée comme fonctionnelle dans le calendrier
TOTD. Ses ancrages ManiaLink (`FindTotdPage`, cases, positions) sont fragiles aux
mises à jour du jeu : les modifier pour gagner quelques lignes risquerait de
réintroduire les crashs précédents. Le parseur CSV valide aussi explicitement
les champs avant d'accepter un nouvel export : il reste volontairement détaillé.

## Points de vigilance

1. La campagne est codée pour **Fall 2026 et 25 UID** ; une nouvelle saison
   exige d'adapter ce mécanisme, ce n'est pas une découverte de campagne automatique.
2. Le fallback de détection de mois TOTD par disposition de calendrier peut
   rester ambigu lorsque plusieurs mois partagent le même premier jour ; dans
   ce cas, aucun badge n'est dessiné (comportement prudent).
3. Les PB dépendent de l'authentification, de la permission ViewRecords et de
   la disponibilité des serveurs Nadeo. Les objectifs dépendent de l'export CSV.
4. Un contrôle statique ne garantit ni la compilation AngelScript ni la
   stabilité en jeu. Consulter `TESTS.md` après installation.
