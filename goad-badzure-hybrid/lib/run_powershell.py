#!/usr/bin/env python3
"""Copie un script PowerShell local sur un hôte Windows distant et l'exécute
via pypsrp/WinRM (Python), à travers un tunnel SSH->WinRM déjà établi par le
script Bash appelant (cf. scripts/30-goad-hardening-fix.sh).

Réutilisé par tous les scripts B4/B5 (et au-delà) : ce module ne connaît rien
de la logique métier (crypto fix, GPO...), seulement du transport.

Usage :
    WINRM_PASSWORD=*** run_powershell.py --host HOST --port PORT --user USER \
        --script /chemin/local/script.ps1 [--arg -Block] [--arg -TargetOU] [...] \
        [--dry-run]

Le mot de passe est lu depuis la variable d'environnement WINRM_PASSWORD, PAS
depuis un argument --password : un argument de ligne de commande apparaît en
clair dans les logs de run_cmd (lib/common.sh) et dans `ps aux` pour tout
utilisateur local. --password reste accepté en repli (pratique pour un test
manuel ponctuel hors orchestrateur), mais n'est jamais utilisé par
scripts/30-goad-hardening-fix.sh.
"""
import argparse
import ntpath
import os
import sys


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", required=True, help="Hôte WinRM (généralement 127.0.0.1, via le tunnel SSH)")
    parser.add_argument("--port", type=int, required=True, help="Port WinRM local du tunnel (ex. 15985)")
    parser.add_argument("--user", required=True, help="Utilisateur WinRM/local admin sur l'hôte distant")
    parser.add_argument(
        "--password",
        default=None,
        help="Mot de passe (déconseillé : préférer la variable d'environnement WINRM_PASSWORD)",
    )
    parser.add_argument("--script", required=True, help="Chemin local du script .ps1 à copier puis exécuter")
    parser.add_argument(
        "--arg",
        action="append",
        default=[],
        dest="script_args",
        help="Argument à passer au script PowerShell distant (répétable, ex. --arg -Block)",
    )
    parser.add_argument("--dry-run", action="store_true", help="Affiche les actions sans rien exécuter/copier")
    return parser.parse_args(argv)


def build_invocation(remote_path, script_args):
    # À VÉRIFIER : pas d'échappement des guillemets/backticks dans les
    # arguments — suffisant pour les arguments actuels (-Block, -Unblock,
    # sans espaces ni caractères spéciaux). À revoir si des arguments plus
    # complexes sont introduits.
    quoted_args = " ".join(script_args)
    return f"& '{remote_path}' {quoted_args}".strip()


def remote_temp_path(local_script_path):
    return ntpath.join("C:\\Windows\\Temp", ntpath.basename(local_script_path))


def run(args):
    remote_path = remote_temp_path(args.script)
    invocation = build_invocation(remote_path, args.script_args)

    if args.dry_run:
        print(f"[DRY-RUN] pypsrp Client({args.host}, port={args.port}, username={args.user}, ssl=False, auth=ntlm)")
        print(f"[DRY-RUN] copy({args.script} -> {remote_path})")
        print(f"[DRY-RUN] execute_ps({invocation!r})")
        print(f"[DRY-RUN] cleanup : Remove-Item -Path '{remote_path}' -Force -ErrorAction SilentlyContinue")
        return 0

    password = args.password or os.environ.get("WINRM_PASSWORD")
    if not password:
        print("Mot de passe manquant : définir WINRM_PASSWORD (ou --password en dépannage).", file=sys.stderr)
        return 2

    # Import différé : pypsrp n'est nécessaire qu'en exécution réelle, pas en
    # --dry-run (permet de tester la logique de ce module sans le paquet installé).
    from pypsrp.client import Client

    client = Client(
        args.host,
        port=args.port,
        username=args.user,
        password=password,
        ssl=False,
        auth="ntlm",
        cert_validation=False,
    )

    client.copy(args.script, remote_path)
    try:
        stdout, streams, had_errors = client.execute_ps(invocation)
        if stdout:
            print(stdout)
        for error in streams.error:
            print(f"[STDERR] {error}", file=sys.stderr)
        if had_errors:
            return 1
        return 0
    finally:
        cleanup_cmd = f"Remove-Item -Path '{remote_path}' -Force -ErrorAction SilentlyContinue"
        client.execute_ps(cleanup_cmd)


def main(argv=None):
    args = parse_args(argv)
    return run(args)


if __name__ == "__main__":
    sys.exit(main())
