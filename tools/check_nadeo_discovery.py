"""Read-only live verification of a dedicated Nadeo service account.

Run manually in a private terminal. The password is requested with no echo,
never written to disk and never printed. No Supabase writes or map captures.
"""
import getpass
import hmac
import os
import re
import sys

from discover_official_maps import fetch_official, request_token


def read_hidden(prompt):
    """Read a whole console line without echo; unlike msvcrt.getwch, accepts paste."""
    if os.name != "nt":
        return getpass.getpass(prompt)
    import ctypes
    from ctypes import wintypes

    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.GetStdHandle.argtypes = [wintypes.DWORD]
    kernel.GetStdHandle.restype = wintypes.HANDLE
    kernel.GetConsoleMode.argtypes = [wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD)]
    kernel.GetConsoleMode.restype = wintypes.BOOL
    kernel.SetConsoleMode.argtypes = [wintypes.HANDLE, wintypes.DWORD]
    kernel.SetConsoleMode.restype = wintypes.BOOL
    console = kernel.GetStdHandle(wintypes.DWORD(-10))  # STD_INPUT_HANDLE
    mode = wintypes.DWORD()
    if console in (None, 0, ctypes.c_void_p(-1).value) or not kernel.GetConsoleMode(console, ctypes.byref(mode)):
        return getpass.getpass(prompt)
    # Cooked line input handles Ctrl+V/right-click paste. Disable ONLY echo;
    # always restore the console mode, including on Ctrl+C or EOF.
    if not kernel.SetConsoleMode(console, (mode.value | 0x0002) & ~0x0004):
        return getpass.getpass(prompt)
    try:
        return input(prompt)
    finally:
        kernel.SetConsoleMode(console, mode.value)
        print()


def main():
    print("Contrôle Nadeo v2 — diagnostic par étape")
    if "--test-paste" in sys.argv[1:]:
        print("Copie uniquement cette chaîne fictive : PM-COLLER-123")
        pasted = read_hidden("Colle-la ici (saisie invisible), puis Entrée : ")
        correct = hmac.compare_digest(pasted, "PM-COLLER-123")
        print("Collage masqué OK." if correct else "Collage masqué différent de la chaîne test.")
        if not correct:
            print("Diagnostic : entrée vide=" + ("oui" if not pasted else "non") +
                  ", raccourci Ctrl+V reçu littéralement=" + ("oui" if "\x16" in pasted else "non"))
        return 0 if correct else 1
    login = input("Server Login du compte de service : ").strip()
    if not login or len(login) > 25 or "\n" in login or "\r" in login:
        print("Identifiant de service invalide.")
        return 1
    password = read_hidden("Mot de passe de service (masqué) : ")
    if not password:
        print("Mot de passe manquant.")
        return 1
    os.environ["PM_NADEO_SERVICE_LOGIN"] = login
    os.environ["PM_NADEO_SERVICE_PASSWORD"] = password
    try:
        maps = fetch_official()
        campaigns = [item for item in maps if item["type"] == "campaign"]
        totds = [item for item in maps if item["type"] == "totd"]
        print(f"Listes officielles lues : {len(campaigns)} cartes campagne, {len(totds)} TOTD récentes.")
        if maps:
            print("Exemple d'heure de sortie UTC : " + maps[-1]["releaseAt"])
        print("Aucune carte enregistrée ou publiée.")
        return 0
    except Exception as exc:
        # Never print exception bodies, URLs containing auth, or tracebacks.
        diagnostic = str(exc) if isinstance(exc, ValueError) else ""
        safe = re.fullmatch(r"Nadeo (?:HTTP \d{3}|réponse inattendue|réponse trop volumineuse|JSON invalide|jeton absent|listes officielles incompatibles) \((?:authentification|campagnes|TOTD|validation(?::[a-z-]+)?)\)", diagnostic)
        reason = diagnostic if safe else type(exc).__name__
        print("Lecture Nadeo impossible (" + reason + "). Aucun secret affiché.")
        if reason == "Nadeo HTTP 401 (authentification)":
            try:
                request_token(login, password, "NadeoServices")
            except ValueError as core_error:
                if str(core_error) == "Nadeo HTTP 401 (authentification)":
                    print("Authentification Core refusée aussi : vérifier le compte ou la saisie masquée.")
                else:
                    print("Authentification Core non concluante (aucun secret affiché).")
            except Exception:
                print("Authentification Core non concluante (aucun secret affiché).")
            else:
                print("Compte accepté pour Core, mais audience Live refusée.")
        return 1
    finally:
        os.environ.pop("PM_NADEO_SERVICE_LOGIN", None)
        os.environ.pop("PM_NADEO_SERVICE_PASSWORD", None)
        password = ""


if __name__ == "__main__":
    raise SystemExit(main())
