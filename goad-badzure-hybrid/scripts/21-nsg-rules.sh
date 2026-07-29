#!/usr/bin/env bash
# 21-nsg-rules.sh — règles NSG post-déploiement.
# - WinRM 5985 (subnet jumpbox -> dc01) sur le NSG GOAD : désactivée par
#   défaut (ENABLE_WINRM_NSG_RULE=true pour l'activer), le trafic passe déjà
#   par AllowVnetInBound.
# - Restriction SSH sur le NSG du subnet des DC : remplace la source "*" par
#   $ALLOWED_IP (le NSG de la jumpbox est déjà restreint à $ALLOWED_IP dès sa
#   création par Terraform, cf. GOAD/template/provider/azure/jumpbox.tf).
# - Restriction RDP temporaire éventuelle à $ALLOWED_IP, si une telle règle
#   existe déjà.
#
# Sourçable : `source scripts/21-nsg-rules.sh` ne fait que définir les
# fonctions ci-dessous ; rien n'est exécuté avant l'appel explicite de
# apply_nsg_hardening (ou d'une fonction individuelle, pour les tests sur
# fixtures — cf. test/README.md).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh disable=SC1091
source "${SCRIPT_DIR}/../lib/common.sh"

# nsg_rule_exists <nsg_name> <rg> <rule_name>
nsg_rule_exists() {
  local nsg_name="$1" rg="$2" rule_name="$3"
  resource_exists network nsg rule show --nsg-name "$nsg_name" --resource-group "$rg" --name "$rule_name"
}

# ensure_nsg_rule <nsg_name> <rg> <rule_name> <priority> <port> <source_prefix>
# — idempotent : met à jour la source si la règle existe déjà (create échoue
# sinon), la crée sinon.
ensure_nsg_rule() {
  local nsg_name="$1" rg="$2" rule_name="$3" priority="$4" port="$5" source_prefix="$6"

  if nsg_rule_exists "$nsg_name" "$rg" "$rule_name"; then
    log_info "Règle $rule_name sur $nsg_name déjà présente, mise à jour de la source -> $source_prefix."
    run_cmd az network nsg rule update \
      --nsg-name "$nsg_name" \
      --resource-group "$rg" \
      --name "$rule_name" \
      --source-address-prefixes "$source_prefix"
    return 0
  fi

  run_cmd az network nsg rule create \
    --nsg-name "$nsg_name" \
    --resource-group "$rg" \
    --name "$rule_name" \
    --priority "$priority" \
    --direction Inbound \
    --access Allow \
    --protocol Tcp \
    --destination-port-ranges "$port" \
    --source-address-prefixes "$source_prefix"
}

# restrict_ssh_to_allowed_ip <ssh_source_ip> <goad_nsg> <goad_rg>
# — remplace la source "*" de la règle SSH du subnet des DC par
# $ssh_source_ip.
restrict_ssh_to_allowed_ip() {
  local ssh_source_ip="$1" goad_nsg="$2" goad_rg="$3"

  ensure_nsg_rule "$goad_nsg" "$goad_rg" "AllowSSHInboundOnly" 100 22 "$ssh_source_ip"
}

# add_winrm_rule <goad_nsg> <goad_rg> <jumpbox_subnet_cidr> — règle WinRM
# explicite, désactivée par défaut (cf. ENABLE_WINRM_NSG_RULE).
add_winrm_rule() {
  local goad_nsg="$1" goad_rg="$2" jumpbox_subnet_cidr="$3"

  ensure_nsg_rule "$goad_nsg" "$goad_rg" "AllowWinRMFromJumpbox" 200 5985 "$jumpbox_subnet_cidr"
}

# restrict_rdp_if_present <ssh_source_ip> <goad_nsg> <goad_rg> <rdp_rule_name>
# — ne restreint que si une règle RDP temporaire existe déjà (ne crée rien).
restrict_rdp_if_present() {
  local ssh_source_ip="$1" goad_nsg="$2" goad_rg="$3" rdp_rule_name="$4"

  if ! nsg_rule_exists "$goad_nsg" "$goad_rg" "$rdp_rule_name"; then
    log_info "Aucune règle RDP temporaire ($rdp_rule_name) trouvée sur $goad_nsg, rien à restreindre."
    return 0
  fi

  run_cmd az network nsg rule update \
    --nsg-name "$goad_nsg" \
    --resource-group "$goad_rg" \
    --name "$rdp_rule_name" \
    --source-address-prefixes "$ssh_source_ip"
}

# apply_nsg_hardening — orchestration complète. Nom de NSG par défaut aligné
# sur la convention GOAD observée ("{{lab_name}}-subnet-nsg", stable — cf.
# GOAD/template/provider/azure/network.tf). CIDR du subnet jumpbox aligné sur
# GOAD/template/provider/azure/jumpbox.tf (10.201.0.0/16).
apply_nsg_hardening() {
  require_vars RG_GOAD ALLOWED_IP || return 1

  local goad_rg="$RG_GOAD"
  local goad_nsg="${GOAD_NSG_NAME:-GOAD-Light-subnet-nsg}"
  local jumpbox_subnet_cidr="${JUMPBOX_SUBNET_CIDR:-10.201.0.0/16}"
  local rdp_rule_name="${GOAD_RDP_RULE_NAME:-rdp_temporaire}"

  restrict_ssh_to_allowed_ip "$ALLOWED_IP" "$goad_nsg" "$goad_rg"

  if [[ "${ENABLE_WINRM_NSG_RULE:-false}" == "true" ]]; then
    add_winrm_rule "$goad_nsg" "$goad_rg" "$jumpbox_subnet_cidr"
  else
    log_info "Règle WinRM explicite non créée (ENABLE_WINRM_NSG_RULE=false)."
  fi

  restrict_rdp_if_present "$ALLOWED_IP" "$goad_nsg" "$goad_rg" "$rdp_rule_name"
}

main() {
  parse_common_flags "$@"
  set -- "${REMAINING_ARGS[@]}"
  load_lab_env
  apply_nsg_hardening
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -euo pipefail
  main "$@"
fi
