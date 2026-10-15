"""Privately transfer service account credentials to GitHub Actions secrets.

Run locally on Kylian's authenticated PC. Values go to gh via stdin, are
encrypted by gh and never written to the repository, command line or logs.
This script does NOT start the producer or set its UTC activation time.
"""
import subprocess

from check_nadeo_discovery import read_hidden


REPO = "chakymi/progressive-medals"


def store_secret(name, value):
    result = subprocess.run(["gh", "secret", "set", name, "-R", REPO, "--app", "actions"],
                            input=value, text=True, capture_output=True, timeout=25, check=False)
    if result.returncode != 0:
        raise ValueError("GitHub refused secret " + name)


def main():
    print("Configuration GitHub du compte de service ; aucun identifiant affiché ni stocké en fichier.")
    login = read_hidden("Server Login exact (saisie masquée) : ").strip()
    if not login or len(login) > 25 or "\n" in login or "\r" in login:
        print("Identifiant invalide ; aucune valeur envoyée.")
        return 1
    password = read_hidden("Mot de passe de service (saisie masquée) : ")
    if not password:
        print("Mot de passe absent ; aucune valeur envoyée.")
        return 1
    try:
        store_secret("PM_NADEO_SERVICE_LOGIN", login)
        store_secret("PM_NADEO_SERVICE_PASSWORD", password)
        print("Deux secrets Nadeo enregistrés dans GitHub Actions. Producteur non activé : heure UTC encore absente.")
        return 0
    except Exception as exc:
        print("Enregistrement GitHub incomplet (" + type(exc).__name__ + "). Vérifier les noms des secrets, sans exposer leurs valeurs.")
        return 1
    finally:
        password = ""


if __name__ == "__main__":
    raise SystemExit(main())
