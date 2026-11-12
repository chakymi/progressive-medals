# Tests manuels après installation

- [ ] Lancer Trackmania sans erreur de compilation dans Openplanet.
- [ ] Ouvrir Fall 2026 : vérifier les 25 badges (comportement identique à la v0.6.3).
- [ ] Ouvrir le calendrier TOTD novembre 2026 sans crash.
- [ ] Laisser 5 à 15 secondes aux PB officiels pour se charger et consulter la ligne « Calendrier TOTD » du panneau.
- [ ] Vérifier un PB connu (11 novembre : 41.885 s, objectif Émeraude 42.440 s dans le snapshot de référence).
- [ ] Changer de mois vers octobre 2026, puis revenir à novembre. Aucun badge ne doit être placé sur une case d'un mois erroné.
- [ ] Vérifier qu'un état « mois non identifié » laisse le jeu utilisable même s'il n'affiche pas de badge.
- [ ] Vérifier le comportement hors connexion (objectifs en cache, PB déjà récupérés seulement).
- [ ] En cas de crash, revenir à la dernière version de campagne fonctionnelle et transmettre Openplanet.log + rapport de crash.

Validation statique effectuée : les fichiers campagne et SheetCatalogue n'ont pas été modifiés ; absence de `ControlsCache`, de cache de `CGameManialinkPage@` global et de requêtes réseau dans `RenderTotdBadges`.
