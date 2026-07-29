#!/usr/bin/env bash
# teardown-fixtures.sh — détruit l'environnement factice monté par
# setup-fixtures.sh. Idempotent : si le resource group fixtures n'existe pas
# (déjà détruit, ou jamais créé), ne fait rien.
#
# Tout le contenu des fixtures vit dans un seul resource group dédié
# ($FIXTURE_RG, défaut hybrid-fixtures-rg) — jamais $RG_GOAD/$RG_BADZURE — la
# suppression de ce RG suffit donc à tout nettoyer d'un coup, sans devoir
# lister/supprimer chaque ressource individuellement.
#
# Sourçable : `source test/teardown-fixtures.sh` ne fait que définir les
# fonctions ci-dessous ; rien n'est exécuté avant l'appel explicite de
# teardown_fixtures.

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh disable=SC1091
source "${TEST_DIR}/../lib/common.sh"

# teardown_fixtures — supprime le resource group fixtures dans son ensemble.
teardown_fixtures() {
  local rg="${FIXTURE_RG:-hybrid-fixtures-rg}"

  if ! resource_exists group show --name "$rg"; then
    log_info "Resource group fixtures $rg introuvable, rien à détruire (idempotent)."
    return 0
  fi

  run_cmd az group delete --name "$rg" --yes --no-wait
  log_info "Suppression du resource group fixtures $rg lancée (--no-wait : peut prendre quelques minutes côté Azure)."
}

main() {
  parse_common_flags "$@"
  set -- "${REMAINING_ARGS[@]}"
  teardown_fixtures
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -euo pipefail
  main "$@"
fi
