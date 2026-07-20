#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import argparse
import csv
import json
import sys
import time
import random
from dataclasses import dataclass
from datetime import datetime
from typing import Optional, Tuple
from urllib.parse import urlencode
from urllib.request import build_opener
from urllib.error import HTTPError


# =========================
# Couleurs terminal
# =========================
class Color:
    RESET = "\033[0m"
    RED = "\033[91m"
    GREEN = "\033[92m"
    YELLOW = "\033[93m"
    BLUE = "\033[94m"
    CYAN = "\033[96m"


def supports_color() -> bool:
    return sys.stdout.isatty()


def colorize(text: str, color: str, use_color: bool = True) -> str:
    if not use_color or not supports_color():
        return text
    return f"{color}{text}{Color.RESET}"


# =========================
# Exit codes
# =========================
EXIT_FULL_ACTIVE = 0
EXIT_ERROR = 1
EXIT_EXPIRED = 2
EXIT_ACTIVE_TRIAL = 3


# =========================
# Résultat
# =========================
@dataclass
class CheckResult:
    mode: str
    target: str
    http_status: Optional[int]
    auth: Optional[int] = None
    status: Optional[str] = None
    is_trial: Optional[str] = None
    exp_date: Optional[str] = None
    active_cons: Optional[str] = None
    max_connections: Optional[str] = None
    error: Optional[str] = None
    exit_code: int = EXIT_ERROR
    verdict_fr: str = "Problème détecté"


# =========================
# Helpers
# =========================
def normalize_host(host: str) -> str:
    host = host.strip()
    if not host.startswith("http://") and not host.startswith("https://"):
        host = "http://" + host
    return host.rstrip("/")


def build_xtream_url(host: str, username: str, password: str) -> str:
    host = normalize_host(host)
    query = urlencode({"username": username, "password": password})
    return f"{host}/player_api.php?{query}"


def build_http_client(user_agent: str):
    opener = build_opener()
    opener.addheaders = [
        ("User-Agent", user_agent),
        ("Accept", "*/*"),
        ("Connection", "close"),
    ]
    return opener


def format_exp_date(exp_date: Optional[str]) -> str:
    if not exp_date:
        return "Inconnue"
    try:
        return datetime.fromtimestamp(int(exp_date)).strftime("%d/%m/%Y %H:%M:%S")
    except Exception:
        return str(exp_date)


def classify_xtream(auth, status, is_trial, error) -> Tuple[int, str]:
    if error:
        return EXIT_ERROR, "Problème détecté (accès non fonctionnel)"
    if auth == 1 and status == "Active" and str(is_trial) == "0":
        return EXIT_FULL_ACTIVE, "Compte valide et prêt à l'utilisation"
    if auth == 1 and status == "Active" and str(is_trial) == "1":
        return EXIT_ACTIVE_TRIAL, "Compte actif en mode test"
    if status == "Expired":
        return EXIT_EXPIRED, "Compte expiré"
    return EXIT_ERROR, "Problème détecté (accès non fonctionnel)"


def classify_m3u(body: str, error: Optional[str]) -> Tuple[int, str]:
    if error:
        return EXIT_ERROR, "Lien M3U non fonctionnel"
    if not body:
        return EXIT_ERROR, "Lien M3U vide"
    if "#EXTM3U" in body:
        return EXIT_FULL_ACTIVE, "Lien M3U valide et exploitable"
    return EXIT_ERROR, "Réponse M3U invalide"


# =========================
# Vérification Xtream
# =========================
def check_xtream_account(
    host: str,
    username: str,
    password: str,
    timeout: int = 10,
    retries: int = 2,
    backoff: float = 2.0,
    user_agent: str = "Mozilla/5.0",
) -> CheckResult:
    url = build_xtream_url(host, username, password)
    opener = build_http_client(user_agent)
    target = f"{normalize_host(host)} | {username}"

    for attempt in range(1, retries + 1):
        try:
            with opener.open(url, timeout=timeout) as resp:
                http_status = resp.getcode()
                body = resp.read().decode("utf-8", errors="replace").strip()

            if not body:
                exit_code, verdict = classify_xtream(None, None, None, "Réponse vide")
                return CheckResult(
                    mode="xstream",
                    target=target,
                    http_status=http_status,
                    error="Réponse vide",
                    exit_code=exit_code,
                    verdict_fr=verdict,
                )

            try:
                data = json.loads(body)
            except json.JSONDecodeError:
                exit_code, verdict = classify_xtream(None, None, None, "Réponse non JSON")
                return CheckResult(
                    mode="xstream",
                    target=target,
                    http_status=http_status,
                    error="Réponse non JSON",
                    exit_code=exit_code,
                    verdict_fr=verdict,
                )

            user_info = data.get("user_info", {})
            auth = user_info.get("auth")
            status = user_info.get("status")
            is_trial = user_info.get("is_trial")
            exp_date = user_info.get("exp_date")
            active_cons = user_info.get("active_cons")
            max_connections = user_info.get("max_connections")

            exit_code, verdict = classify_xtream(auth, status, is_trial, None)

            return CheckResult(
                mode="xstream",
                target=target,
                http_status=http_status,
                auth=auth,
                status=status,
                is_trial=str(is_trial) if is_trial is not None else None,
                exp_date=str(exp_date) if exp_date is not None else None,
                active_cons=str(active_cons) if active_cons is not None else None,
                max_connections=str(max_connections) if max_connections is not None else None,
                exit_code=exit_code,
                verdict_fr=verdict,
            )

        except HTTPError as e:
            # Retry only on transient HTTP codes
            if e.code in (429, 500, 502, 503, 504) and attempt < retries:
                time.sleep(backoff * attempt + random.uniform(0.2, 0.8))
                continue

            exit_code, verdict = classify_xtream(None, None, None, f"HTTP Error {e.code}")
            return CheckResult(
                mode="xstream",
                target=target,
                http_status=e.code,
                error=f"HTTP Error {e.code}",
                exit_code=exit_code,
                verdict_fr=verdict,
            )

        except Exception as e:
            if attempt < retries:
                time.sleep(backoff * attempt + random.uniform(0.2, 0.8))
                continue

            exit_code, verdict = classify_xtream(None, None, None, str(e))
            return CheckResult(
                mode="xstream",
                target=target,
                http_status=None,
                error=str(e),
                exit_code=exit_code,
                verdict_fr=verdict,
            )

    return CheckResult(
        mode="xstream",
        target=target,
        http_status=None,
        error="Erreur inconnue",
        exit_code=EXIT_ERROR,
        verdict_fr="Problème détecté",
    )


# =========================
# Vérification M3U
# =========================
def check_m3u_url(
    m3u_url: str,
    timeout: int = 10,
    retries: int = 2,
    backoff: float = 2.0,
    user_agent: str = "Mozilla/5.0",
) -> CheckResult:
    opener = build_http_client(user_agent)
    target = m3u_url

    for attempt in range(1, retries + 1):
        try:
            with opener.open(m3u_url, timeout=timeout) as resp:
                http_status = resp.getcode()
                body = resp.read(4096).decode("utf-8", errors="replace")

            exit_code, verdict = classify_m3u(body, None)

            return CheckResult(
                mode="m3u",
                target=target,
                http_status=http_status,
                exit_code=exit_code,
                verdict_fr=verdict,
                error=None if exit_code == EXIT_FULL_ACTIVE else "Réponse M3U invalide",
            )

        except HTTPError as e:
            if e.code in (429, 500, 502, 503, 504) and attempt < retries:
                time.sleep(backoff * attempt + random.uniform(0.2, 0.8))
                continue

            exit_code, verdict = classify_m3u("", f"HTTP Error {e.code}")
            return CheckResult(
                mode="m3u",
                target=target,
                http_status=e.code,
                error=f"HTTP Error {e.code}",
                exit_code=exit_code,
                verdict_fr=verdict,
            )

        except Exception as e:
            if attempt < retries:
                time.sleep(backoff * attempt + random.uniform(0.2, 0.8))
                continue

            exit_code, verdict = classify_m3u("", str(e))
            return CheckResult(
                mode="m3u",
                target=target,
                http_status=None,
                error=str(e),
                exit_code=exit_code,
                verdict_fr=verdict,
            )

    return CheckResult(
        mode="m3u",
        target=target,
        http_status=None,
        error="Erreur inconnue",
        exit_code=EXIT_ERROR,
        verdict_fr="Lien M3U non fonctionnel",
    )


# =========================
# Affichage
# =========================
def print_human_result(result: CheckResult, use_color: bool = True) -> None:
    print(colorize("\n================= RÉSULTAT =================", Color.CYAN, use_color))
    print(f"Mode               : {result.mode.upper()}")
    print(f"Cible              : {result.target}")
    print(f"Réponse HTTP       : {result.http_status if result.http_status is not None else 'Aucune réponse'}")

    if result.mode == "xstream" and not result.error:
        print(f"Connexion          : {colorize('OK' if result.auth == 1 else 'ÉCHEC', Color.GREEN if result.auth == 1 else Color.RED, use_color)}")

        status_fr = result.status
        if result.status == "Active":
            status_fr = "Actif"
        elif result.status == "Expired":
            status_fr = "Expiré"

        print(f"Statut             : {status_fr}")
        print(f"Type               : {'Compte test' if result.is_trial == '1' else 'Compte complet'}")
        print(f"Expiration         : {format_exp_date(result.exp_date)}")
        print(f"Connexions actives : {result.active_cons or 'Inconnu'}")
        print(f"Connexions max     : {result.max_connections or 'Inconnu'}")

    if result.error:
        print(f"Erreur             : {colorize(result.error, Color.RED, use_color)}")

    print(colorize("----------------- ANALYSE ------------------", Color.CYAN, use_color))

    if result.exit_code == EXIT_FULL_ACTIVE:
        print(colorize(f"✔ {result.verdict_fr}", Color.GREEN, use_color))
    elif result.exit_code in (EXIT_ACTIVE_TRIAL, EXIT_EXPIRED):
        print(colorize(f"⚠ {result.verdict_fr}", Color.YELLOW, use_color))
    else:
        print(colorize(f"✘ {result.verdict_fr}", Color.RED, use_color))


# =========================
# Bulk CSV
# =========================
def run_bulk(
    csv_path: str,
    mode: str,
    timeout: int,
    retries: int,
    backoff: float,
    user_agent: str,
    use_color: bool,
    output_csv: Optional[str] = None,
) -> int:
    rows_out = []
    max_exit = 0

    with open(csv_path, newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)

        if mode == "xstream":
            required = {"host", "username", "password"}
        else:
            required = {"m3u_url"}

        if not required.issubset(set(reader.fieldnames or [])):
            print(f"Le CSV doit contenir les colonnes : {', '.join(sorted(required))}")
            return EXIT_ERROR

        for row in reader:
            if mode == "xstream":
                result = check_xtream_account(
                    host=row["host"].strip(),
                    username=row["username"].strip(),
                    password=row["password"].strip(),
                    timeout=timeout,
                    retries=retries,
                    backoff=backoff,
                    user_agent=user_agent,
                )
            else:
                result = check_m3u_url(
                    m3u_url=row["m3u_url"].strip(),
                    timeout=timeout,
                    retries=retries,
                    backoff=backoff,
                    user_agent=user_agent,
                )

            print_human_result(result, use_color=use_color)
            print()

            rows_out.append({
                "mode": result.mode,
                "target": result.target,
                "http_status": result.http_status,
                "auth": result.auth,
                "status": result.status,
                "is_trial": result.is_trial,
                "exp_date": result.exp_date,
                "active_cons": result.active_cons,
                "max_connections": result.max_connections,
                "error": result.error,
                "exit_code": result.exit_code,
                "verdict_fr": result.verdict_fr,
            })

            max_exit = max(max_exit, result.exit_code)

    if output_csv:
        with open(output_csv, "w", newline="", encoding="utf-8") as f:
            writer = csv.DictWriter(
                f,
                fieldnames=[
                    "mode",
                    "target",
                    "http_status",
                    "auth",
                    "status",
                    "is_trial",
                    "exp_date",
                    "active_cons",
                    "max_connections",
                    "error",
                    "exit_code",
                    "verdict_fr",
                ],
            )
            writer.writeheader()
            writer.writerows(rows_out)

        print(colorize(f"Rapport exporté : {output_csv}", Color.BLUE, use_color))

    return max_exit


# =========================
# Main
# =========================
def main():
    parser = argparse.ArgumentParser(description="Outil CLI IPTV Xtream + M3U")
    parser.add_argument("--timeout", type=int, default=10, help="Timeout en secondes")
    parser.add_argument("--retries", type=int, default=2, help="Nombre de tentatives")
    parser.add_argument("--backoff", type=float, default=2.0, help="Pause entre tentatives")
    parser.add_argument("--user-agent", default="Mozilla/5.0", help="User-Agent HTTP")
    parser.add_argument("--no-color", action="store_true", help="Désactiver les couleurs")

    subparsers = parser.add_subparsers(dest="command")

    # check
    parser_check = subparsers.add_parser("check", help="Vérifier un accès")
    check_sub = parser_check.add_subparsers(dest="check_mode")

    parser_xtream = check_sub.add_parser("xstream", help="Vérifier un accès Xtream")
    parser_xtream.add_argument("host", help="Ex: line.liondnscloud.ru:80")
    parser_xtream.add_argument("username", help="Nom d'utilisateur Xtream")
    parser_xtream.add_argument("password", help="Mot de passe Xtream")

    parser_m3u = check_sub.add_parser("m3u", help="Vérifier un lien M3U")
    parser_m3u.add_argument("m3u_url", help="Lien M3U complet")

    # bulk
    parser_bulk = subparsers.add_parser("bulk", help="Vérifier plusieurs accès via CSV")
    bulk_sub = parser_bulk.add_subparsers(dest="bulk_mode")

    parser_bulk_xtream = bulk_sub.add_parser("xstream", help="Bulk Xtream")
    parser_bulk_xtream.add_argument("csvfile", help="CSV avec host,username,password")
    parser_bulk_xtream.add_argument("--output-csv", help="Exporter le rapport en CSV")

    parser_bulk_m3u = bulk_sub.add_parser("m3u", help="Bulk M3U")
    parser_bulk_m3u.add_argument("csvfile", help="CSV avec m3u_url")
    parser_bulk_m3u.add_argument("--output-csv", help="Exporter le rapport en CSV")

    args = parser.parse_args()
    use_color = not args.no_color

    if args.command == "check":
        if args.check_mode == "xstream":
            result = check_xtream_account(
                host=args.host,
                username=args.username,
                password=args.password,
                timeout=args.timeout,
                retries=args.retries,
                backoff=args.backoff,
                user_agent=args.user_agent,
            )
            print_human_result(result, use_color=use_color)
            sys.exit(result.exit_code)

        elif args.check_mode == "m3u":
            result = check_m3u_url(
                m3u_url=args.m3u_url,
                timeout=args.timeout,
                retries=args.retries,
                backoff=args.backoff,
                user_agent=args.user_agent,
            )
            print_human_result(result, use_color=use_color)
            sys.exit(result.exit_code)

    elif args.command == "bulk":
        if args.bulk_mode == "xstream":
            code = run_bulk(
                csv_path=args.csvfile,
                mode="xstream",
                timeout=args.timeout,
                retries=args.retries,
                backoff=args.backoff,
                user_agent=args.user_agent,
                use_color=use_color,
                output_csv=args.output_csv,
            )
            sys.exit(code)

        elif args.bulk_mode == "m3u":
            code = run_bulk(
                csv_path=args.csvfile,
                mode="m3u",
                timeout=args.timeout,
                retries=args.retries,
                backoff=args.backoff,
                user_agent=args.user_agent,
                use_color=use_color,
                output_csv=args.output_csv,
            )
            sys.exit(code)

    parser.print_help()
    sys.exit(1)


if __name__ == "__main__":
    main()