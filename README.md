# Progressive Medals — v0.7.2 (code clarifié)

Plugin Openplanet pour Trackmania 2020. Affiche Platine, Émeraude et Diamant
sur le menu **Fall 2026** et le calendrier **TOTD**, selon le PB du joueur.

## Sources et responsabilités

| Fichier | Responsabilité |
| --- | --- |
| `Main.as` | Paramètres, PB local, fenêtre d'information, démarrage des tâches. |
| `SheetCatalogue.as` | Export CSV public du Sheet, validation, cache, objectifs par UID/date. |
| `OfficialPbs.as` | Une requête Nadeo groupée et une validation communes aux deux menus. |
| `MenuBadges.as` | Ordre et superposition des 25 cartes Fall 2026, PB de campagne. |
| `TotdBadges.as` | Mois/jours visibles, PB du mois, superposition TOTD. |

**Temps des médailles** : onglet `Medals` du Google Sheet. Seules les lignes `PUBLISHED` sont utilisées.
**PB personnels** : API Nadeo. Aucune requête aux classements mondiaux pour recalculer les seuils.
**Mode hors ligne** : dernier export validé, ou snapshot du Sheet intégré au ZIP.
**Fichier `fall-2026-goals.json`** : liste ordonnée des 25 UID, plus temps
historiques de secours pour ne pas vider le menu avant le chargement du Sheet.
Ces temps ne remplacent jamais des valeurs du Sheet validées plus récentes.
Pas de Supabase ; pas besoin de modifier Apps Script.

## Exécution

1. `Main()` initialise les textures et les objectifs, puis lance trois tâches :
   actualisation du Sheet, PB de campagne, PB TOTD.
2. Le rendu lit la page visible du jeu sans stocker de contrôles ManiaLink.
3. Les deux menus utilisent `HighestBadge(...)` pour calculer la meilleure médaille.
4. Les tâches réseau conservent les PB locaux plus rapides et ne doivent pas
   écraser les PB d'un autre compte Nadeo.

Pour augmenter la taille, modifier les réglages **Taille des badges menu** et
**Taille des badges TOTD**. Valeurs par défaut : **61** et **56** (base 1080p).

## Installation

Fermer Trackmania. Remplacer l'ancien dossier `ProgressiveMedals_Sheets` dans
`OpenplanetNext/Plugins`, sans conserver une autre version du même plugin.
Relancer en **Developer**. Contrôler d'abord Fall 2026, puis les TOTD.
Le mode Regular nécessite une signature reconnue par Openplanet.

## Relecture humaine et tests

Voir `REVIEW.md` pour le périmètre exact des changements et `TESTS.md` pour
les vérifications manuelles. **Ce code n'a pas été recompilé dans Openplanet par
l'assistant** : les tests statiques ne remplacent pas un essai dans le jeu.
