namespace PM {
    string selfCheckResult = "";
    string menuCheckResult = "";
    void RenderWindow() {
        UI::SetNextWindowSize(440, 570, UI::Cond::FirstUseEver);
        if (UI::Begin("Progressive Medals", S_ShowWindow)) {
            UI::TextWrapped(currentTitle);
            UI::Text("UID : " + (currentUid.Length == 0 ? "—" : currentUid));
            UI::Text("Auteur : " + (currentAuthor == 0 ? "indisponible" : FormatTime(currentAuthor)));
            UI::Text("Record personnel : " + (currentPb == 0 ? "indisponible" : FormatTime(currentPb)));
            if (UI::Button(demo ? "Revenir à la carte" : "Voir les cartes fictives")) {
                demo = !demo; currentUid = ""; currentPb = 0;
                PollMap();
            }
            if (demo) {
                UI::SameLine();
                if (UI::Button("Carte suivante")) { demoIndex = (demoIndex + 1) % DEMOS.Length; currentPb = 0; PollMap(); }
                int samplePb = UI::InputInt("PB fictif (ms, 0 = aucun)", int(currentPb), 100);
                if (samplePb >= 0 && samplePb <= int(MAX_TIME)) currentPb = uint(samplePb);
                UI::TextDisabled("Simulation locale : aucun résultat de jeu modifié.");
            }
            UI::Separator();
            MapGoals@ goals = FindGoals(currentUid);
            if (goals is null) {
                string state = WorldStatusFor(currentUid);
                if (state == "waiting_initial_delay") UI::TextWrapped("Médailles mondiales : en attente du délai initial.");
                else if (state == "waiting_for_players") UI::TextWrapped("Médailles mondiales : en attente de 5 000 joueurs classés.");
                else if (state == "waiting_extra_hour") {
                    UI::TextWrapped("Médailles mondiales : délai supplémentaire après détection du seuil.");
                    int64 due = WorldDueFor(currentUid);
                    if (due > 0) UI::Text("Capture possible à partir du " + Time::FormatStringUTC("%Y-%m-%d %H:%M UTC", due));
                }
                else if (state == "temporarily_unavailable") UI::TextWrapped("Médailles mondiales : données temporairement indisponibles.");
                else if (state == "ready_to_capture") UI::TextWrapped("Médailles mondiales : capture en attente de publication.");
                else UI::TextWrapped("Aucun objectif publié pour cet UID. Le mode démo contient trois cartes fictives.");
            } else if (!demo && !MatchesAuthor(goals, currentAuthor)) {
                UI::TextWrapped("Temps Auteur différent du catalogue : objectifs suspendus (carte modifiée ?).");
            } else if (!IsReleased(goals)) {
                UI::TextWrapped("Médailles non disponibles avant la publication commune.");
                UI::Text("Disponibles à partir du " + Time::FormatStringUTC("%Y-%m-%d %H:%M UTC", goals.publishedAtUtc));
            } else {
                int level = HighestLevel(goals, currentPb);
                if (currentPb == 0) UI::Text("Prochain objectif : Platine (établir un PB)");
                else if (level == int(COUNT) - 1) UI::Text("Toutes les médailles obtenues !");
                else {
                    uint target = goals.times[level + 1];
                    UI::TextWrapped("Prochaine médaille : " + NAMES[level + 1] + " | à améliorer : " + FormatTime(currentPb - target));
                }
                UI::Separator();
                for (uint i = 0; i < COUNT; i++) {
                    string marker = level >= int(i) ? "[OK] " : (int(i) == level + 1 ? ">> " : "    ");
                    bool hasIcon = i < medalTextures.Length && medalTextures[i] !is null;
                    if (hasIcon) {
                        UI::Image(medalTextures[i], vec2(42, 42));
                        UI::SameLine();
                    }
                    UI::Text(marker + (hasIcon ? "" : ICONS[i] + "  ") + NAMES[i] + "  —  " + FormatTime(goals.times[i]));
                }
                UI::Separator();
                UI::TextDisabled("Source : " + (goals.calculationVersion >= 5 ? goals.source + " v" + worldVersion : catalogSource + " v" + catalogVersion) + (goals.calculationVersion >= 5 ? " | WR témoin : " : " | WR figé : ") + FormatTime(goals.referenceWrMs));
            }
#if DEPENDENCY_WARRIORMEDALS
            if (!demo && S_ShowWarrior && currentUid.Length > 0) {
                uint warrior = WarriorMedals::GetWMTime(currentUid);
                UI::Text("Warrior (référence indépendante) : " + (warrior == 0 ? "indisponible" : FormatTime(warrior)));
            }
#endif
            UI::TextDisabled("Champion : interface publique non vérifiée (non connectée).");
            UI::TextWrapped("Badges campagne Fall 2026 : " + menuStatus);
            UI::TextDisabled("PB officiels en mémoire pour le menu : " + menuPbs.GetSize() + "/25");
            if (UI::Button("Actualiser les PB officiels de la campagne")) startnew(RefreshMenuPbs);
            UI::SameLine();
            if (UI::Button("Vérifier menu / positions")) menuCheckResult = CheckMenuLoader();
            if (menuCheckResult.Length > 0) UI::TextWrapped(menuCheckResult);
            UI::Separator();
            if (UI::Button("Actualiser le catalogue HTTPS")) startnew(RefreshCatalog);
            if (S_WorldCatalogUrl.Length > 0) {
                UI::SameLine();
                if (UI::Button("Actualiser les rangs mondiaux")) startnew(RefreshWorld);
                UI::TextDisabled("Catalogue mondial : " + (worldVersion == 0 ? "non chargé" : "v" + worldVersion + " — " + worldStatus.GetSize() + " carte(s)"));
                if (worldError.Length > 0) UI::TextWrapped("Diagnostic mondial : " + worldError);
            }
            UI::SameLine();
            if (UI::Button("Vérifier le chargeur")) selfCheckResult = CheckLoader();
            if (selfCheckResult.Length > 0) UI::TextWrapped(selfCheckResult);
            if (downloading) UI::Text("Chargement en cours...");
            if (catalogError.Length > 0) UI::TextWrapped("Diagnostic : " + catalogError);
        }
        UI::End();
    }
}
