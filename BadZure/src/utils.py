import requests

def get_public_ip():

    # À VÉRIFIER / patch d'environnement (pas un bug BadZure) : api64.ipify.org
    # est injoignable dans ce sandbox précis (restriction réseau sortante),
    # confirmé via curl direct — ifconfig.me/ip fonctionne, donc substitué ici.
    # Dans un environnement opérateur normal (egress non restreint),
    # l'endpoint d'origine fonctionnerait probablement aussi.
    try:
        response = requests.get("https://ifconfig.me/ip")
        response.raise_for_status()
        return response.text.strip()
    except requests.RequestException as e:
        print(f"Error fetching public IP: {e}")
        return None