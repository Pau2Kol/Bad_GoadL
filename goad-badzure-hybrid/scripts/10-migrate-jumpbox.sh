#!/usr/bin/env bash
# 10-migrate-jumpbox.sh — migration cross-région du jumpbox GOAD
# (région des DC -> $REGION_JUMPBOX). Snapshot incrémental du disque OS, copie
# cross-région, recréation de la VM dans la région cible (nouveau VNet non
# chevauchant + NSG explicite), suppression de l'ancienne VM et nettoyage des
# ressources orphelines (disque, IP publique, NIC de l'ancienne région).
#
# Idempotent : si le jumpbox est déjà dans $REGION_JUMPBOX, ne fait rien.
# Nécessaire uniquement pour un redéploiement from-scratch où GOAD a créé le
# jumpbox dans la région des DC (comportement par défaut du template GOAD :
# le jumpbox naît dans le même VNet que les DC).
#
# Sourçable : `source scripts/10-migrate-jumpbox.sh` ne fait que définir les
# fonctions ci-dessous ; rien n'est exécuté avant l'appel explicite de
# migrate_jumpbox (ou d'une fonction individuelle, pour les tests sur
# fixtures, cf. test/README.md).
#
# Toutes les commandes d'écriture passent par run_cmd (lib/common.sh), qui
# respecte --dry-run.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh disable=SC1091
source "${SCRIPT_DIR}/../lib/common.sh"

# snapshot_source_disk <disk_id> <snapshot_name> <rg> <region> — snapshot
# incrémental du disque source, dans la région source. --incremental true dès
# la création est requis : sans ça, --copy-start échouera ensuite
# (CreateOption.CopyStart n'est supporté que pour un snapshot incrémental).
snapshot_source_disk() {
  local disk_id="$1" snapshot_name="$2" rg="$3" region="$4"

  if resource_exists snapshot show --name "$snapshot_name" --resource-group "$rg"; then
    log_info "Snapshot $snapshot_name déjà présent, réutilisation."
    return 0
  fi

  run_cmd az snapshot create \
    --name "$snapshot_name" \
    --resource-group "$rg" \
    --location "$region" \
    --source "$disk_id" \
    --incremental true
}

# wait_for_snapshot_copy <snapshot_name> <rg> — gate bloquante sur le transfert
# de données. IMPORTANT : on poll completionPercent, PAS provisioningState
# (qui passe à "Succeeded" avant la fin réelle du transfert cross-région).
wait_for_snapshot_copy() {
  local snapshot_name="$1" rg="$2"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY-RUN] Attente de la copie du snapshot $snapshot_name (completionPercent=100) ignorée."
    return 0
  fi

  local percent
  while true; do
    percent="$(az snapshot show --name "$snapshot_name" --resource-group "$rg" --query completionPercent -o tsv)"
    log_info "Copie du snapshot $snapshot_name en cours : ${percent}%"
    # completionPercent peut être un flottant (ex. "100.0") : awk plutôt qu'un
    # test arithmétique entier Bash.
    if awk -v p="$percent" 'BEGIN{exit !(p>=100)}'; then
      break
    fi
    sleep 15
  done
  log_info "Copie du snapshot $snapshot_name terminée (100%)."
}

# copy_snapshot_cross_region <source_snapshot_id> <copy_name> <rg> <region_cible>
copy_snapshot_cross_region() {
  local source_snapshot_id="$1" copy_name="$2" rg="$3" target_region="$4"

  if resource_exists snapshot show --name "$copy_name" --resource-group "$rg"; then
    log_info "Snapshot copié $copy_name déjà présent, réutilisation."
    return 0
  fi

  run_cmd az snapshot create \
    --name "$copy_name" \
    --resource-group "$rg" \
    --location "$target_region" \
    --source "$source_snapshot_id" \
    --copy-start true \
    --incremental true

  wait_for_snapshot_copy "$copy_name" "$rg"
}

# create_disk_from_snapshot <disk_name> <snapshot_name> <rg> <region>
create_disk_from_snapshot() {
  local disk_name="$1" snapshot_name="$2" rg="$3" region="$4"

  if resource_exists disk show --name "$disk_name" --resource-group "$rg"; then
    log_info "Disque $disk_name déjà présent, réutilisation."
    return 0
  fi

  run_cmd az disk create \
    --name "$disk_name" \
    --resource-group "$rg" \
    --location "$region" \
    --source "$snapshot_name"
}

# create_target_network <vnet_name> <subnet_name> <rg> <region> <vnet_cidr> <subnet_cidr>
# CIDR non chevauchant avec le lab GOAD (10.200.10.0/24) : 10.201.0.0/16 par
# défaut, subnet 10.201.1.0/24.
create_target_network() {
  local vnet_name="$1" subnet_name="$2" rg="$3" region="$4" vnet_cidr="$5" subnet_cidr="$6"

  if resource_exists network vnet show --name "$vnet_name" --resource-group "$rg"; then
    log_info "VNet $vnet_name déjà présent, réutilisation."
    return 0
  fi

  run_cmd az network vnet create \
    --name "$vnet_name" \
    --resource-group "$rg" \
    --location "$region" \
    --address-prefix "$vnet_cidr" \
    --subnet-name "$subnet_name" \
    --subnet-prefixes "$subnet_cidr"
}

# create_target_nsg <nsg_name> <rg> <region> <ssh_source_ip> — un subnet créé
# from scratch n'a aucun NSG associé -> DenyAllInBound implicite bloque tout
# SSH. On crée donc une règle SSH explicite d'emblée, restreinte à
# $ssh_source_ip (pas de fenêtre "ouverte à *" même temporaire), cf. B3 pour la
# cohérence avec les autres NSG du lab.
create_target_nsg() {
  local nsg_name="$1" rg="$2" region="$3" ssh_source_ip="$4"

  if resource_exists network nsg show --name "$nsg_name" --resource-group "$rg"; then
    log_info "NSG $nsg_name déjà présent, réutilisation."
  else
    run_cmd az network nsg create \
      --name "$nsg_name" \
      --resource-group "$rg" \
      --location "$region"
  fi

  if resource_exists network nsg rule show --nsg-name "$nsg_name" --resource-group "$rg" --name "AllowSSHInbound"; then
    log_info "Règle AllowSSHInbound déjà présente sur $nsg_name."
    return 0
  fi

  run_cmd az network nsg rule create \
    --nsg-name "$nsg_name" \
    --resource-group "$rg" \
    --name "AllowSSHInbound" \
    --priority 100 \
    --direction Inbound \
    --access Allow \
    --protocol Tcp \
    --destination-port-ranges 22 \
    --source-address-prefixes "$ssh_source_ip"
}

# associate_nsg_to_subnet <vnet_name> <subnet_name> <nsg_name> <rg> — l'update
# est intrinsèquement idempotent (réassocier le même NSG est sans effet), pas
# de garde nécessaire avant l'appel.
associate_nsg_to_subnet() {
  local vnet_name="$1" subnet_name="$2" nsg_name="$3" rg="$4"

  run_cmd az network vnet subnet update \
    --vnet-name "$vnet_name" \
    --name "$subnet_name" \
    --resource-group "$rg" \
    --network-security-group "$nsg_name"
}

# create_target_public_ip <pip_name> <rg> <region>
create_target_public_ip() {
  local pip_name="$1" rg="$2" region="$3"

  if resource_exists network public-ip show --name "$pip_name" --resource-group "$rg"; then
    log_info "IP publique $pip_name déjà présente, réutilisation."
    return 0
  fi

  run_cmd az network public-ip create \
    --name "$pip_name" \
    --resource-group "$rg" \
    --location "$region" \
    --sku Standard \
    --allocation-method Static
}

# create_target_nic <nic_name> <rg> <region> <vnet_name> <subnet_name> <pip_name>
create_target_nic() {
  local nic_name="$1" rg="$2" region="$3" vnet_name="$4" subnet_name="$5" pip_name="$6"

  if resource_exists network nic show --name "$nic_name" --resource-group "$rg"; then
    log_info "NIC $nic_name déjà présente, réutilisation."
    return 0
  fi

  run_cmd az network nic create \
    --name "$nic_name" \
    --resource-group "$rg" \
    --location "$region" \
    --vnet-name "$vnet_name" \
    --subnet "$subnet_name" \
    --public-ip-address "$pip_name"
}

# delete_old_vm <vm_name> <rg> <region_cible> — supprime l'ancienne VM. Garde
# de sécurité : si la VM est déjà dans la région cible, ne la supprime pas
# (protection contre un appel accidentel après une migration déjà faite).
delete_old_vm() {
  local vm_name="$1" rg="$2" target_region="$3"

  if ! vm_exists "$vm_name" "$rg"; then
    log_info "VM $vm_name déjà absente, rien à supprimer."
    return 0
  fi

  local current_location
  current_location="$(az vm show --name "$vm_name" --resource-group "$rg" --query location -o tsv)"
  if [[ "$current_location" == "$target_region" ]]; then
    log_warn "VM $vm_name déjà dans la région cible ($target_region) : suppression refusée par sécurité."
    return 0
  fi

  run_cmd az vm delete --name "$vm_name" --resource-group "$rg" --yes
}

# create_vm_from_disk <vm_name> <rg> <region> <disk_name> <nic_name> —
# recrée la VM à partir du disque OS copié. Pas de credentials à fournir : ils
# sont déjà dans le disque OS attaché.
create_vm_from_disk() {
  local vm_name="$1" rg="$2" region="$3" disk_name="$4" nic_name="$5"

  if vm_exists "$vm_name" "$rg"; then
    log_info "VM $vm_name existe déjà, recréation ignorée."
    return 0
  fi

  run_cmd az vm create \
    --name "$vm_name" \
    --resource-group "$rg" \
    --location "$region" \
    --attach-os-disk "$disk_name" \
    --os-type Linux \
    --nics "$nic_name" \
    --size "${JUMPBOX_VM_SIZE:-Standard_B1ms}"
}

# cleanup_orphans <rg> <old_disk_id> <old_pip_name> <old_nic_name> — nettoie
# les ressources laissées par az vm delete (qui ne supprime que la VM, pas son
# disque/IP/NIC). Ordre : NIC (libère l'IP publique associée) puis IP puis
# disque.
cleanup_orphans() {
  local rg="$1" old_disk_id="$2" old_pip_name="$3" old_nic_name="$4"

  if resource_exists network nic show --name "$old_nic_name" --resource-group "$rg"; then
    run_cmd az network nic delete --name "$old_nic_name" --resource-group "$rg"
  else
    log_info "NIC $old_nic_name déjà absente."
  fi

  if resource_exists network public-ip show --name "$old_pip_name" --resource-group "$rg"; then
    run_cmd az network public-ip delete --name "$old_pip_name" --resource-group "$rg"
  else
    log_info "IP publique $old_pip_name déjà absente."
  fi

  if [[ -n "$old_disk_id" ]] && az disk show --ids "$old_disk_id" >/dev/null 2>&1; then
    run_cmd az disk delete --ids "$old_disk_id" --yes
  else
    log_info "Disque d'origine déjà absent ou introuvable (id: ${old_disk_id:-inconnu})."
  fi
}

# check_stale_migration_orphans <rg> <vm_name> <region_cible> — lecture seule,
# appelée uniquement depuis le chemin idempotent (jumpbox déjà dans la région
# cible) : dans ce cas migrate_jumpbox retourne AVANT de calculer old_disk_id
# / old_nic_name / old_pip_name et n'appelle jamais cleanup_orphans. Si une
# migration antérieure (via ce script interrompu après la recréation de la VM
# mais avant cleanup_orphans, ou via une migration manuelle hors de ce
# script) a laissé des ressources orphelines aux noms par défaut, elles ne
# seraient donc plus jamais détectées ni signalées par les runs suivants. On
# se contente ici de signaler (log_warn), sans rien supprimer : le disque OS
# d'origine n'est plus déterminable de façon fiable une fois l'ancienne VM
# supprimée (son storageProfile.osDisk.managedDisk.id n'est plus interrogeable),
# donc pas de suppression automatique sûre possible ici.
check_stale_migration_orphans() {
  local rg="$1" vm_name="$2" target_region="$3"
  local old_nic_name="${JUMPBOX_OLD_NIC_NAME:-ubuntu-jumbox-nic}"
  local old_pip_name="${JUMPBOX_OLD_PIP_NAME:-ubuntu-public-ip}"
  local found=false

  if resource_exists network nic show --name "$old_nic_name" --resource-group "$rg"; then
    log_warn "NIC potentiellement orpheline détectée : $old_nic_name (rg=$rg) — cleanup_orphans n'est pas rejoué sur le chemin idempotent, vérifier/nettoyer manuellement si obsolète."
    found=true
  fi

  if resource_exists network public-ip show --name "$old_pip_name" --resource-group "$rg"; then
    log_warn "IP publique potentiellement orpheline détectée : $old_pip_name (rg=$rg) — cleanup_orphans n'est pas rejoué sur le chemin idempotent, vérifier/nettoyer manuellement si obsolète."
    found=true
  fi

  local stale_disk_ids
  stale_disk_ids="$(az disk list --resource-group "$rg" --query "[?starts_with(name, '${vm_name}_OsDisk_1_') && location!='${target_region}'].id" -o tsv 2>/dev/null || true)"
  if [[ -n "$stale_disk_ids" ]]; then
    log_warn "Disque(s) OS potentiellement orphelin(s) hors de $target_region : $stale_disk_ids"
    found=true
  fi

  if [[ "$found" == "true" ]]; then
    log_warn "Ressources orphelines probables issues d'une migration déjà effectuée (avant ce run) : nettoyage manuel recommandé (az network nic delete / az network public-ip delete / az disk delete --ids), car le disque OS d'origine n'est plus déterminable via l'ancienne VM (déjà supprimée)."
  fi
}

# migrate_jumpbox — orchestration complète de la migration. Toutes les
# valeurs de ressources ont un défaut correspondant à la convention de
# nommage GOAD observée (stable, non aléatoire, cf.
# GOAD/template/provider/azure/jumpbox.tf), mais restent surchargeables par
# variable d'environnement (utile pour les fixtures de test, cf.
# test/README.md).
migrate_jumpbox() {
  require_vars RG_GOAD REGION_JUMPBOX ALLOWED_IP || return 1

  local vm_name="${JUMPBOX_VM_NAME:-ubuntu-jumpbox}"
  local rg="$RG_GOAD"

  if ! vm_exists "$vm_name" "$rg"; then
    log_error "VM $vm_name introuvable dans $rg. GOAD doit être déployé avant cette migration."
    return 1
  fi

  local current_location
  current_location="$(az vm show --name "$vm_name" --resource-group "$rg" --query location -o tsv)"

  if [[ "$current_location" == "$REGION_JUMPBOX" ]]; then
    log_info "Jumpbox déjà dans $REGION_JUMPBOX. Rien à faire (idempotent)."
    check_stale_migration_orphans "$rg" "$vm_name" "$REGION_JUMPBOX"
    return 0
  fi

  log_info "Jumpbox trouvé dans $current_location, migration vers $REGION_JUMPBOX."

  local old_disk_id
  old_disk_id="$(az vm show --name "$vm_name" --resource-group "$rg" --query storageProfile.osDisk.managedDisk.id -o tsv)"
  local old_nic_name="${JUMPBOX_OLD_NIC_NAME:-ubuntu-jumbox-nic}"
  local old_pip_name="${JUMPBOX_OLD_PIP_NAME:-ubuntu-public-ip}"

  local snapshot_name="${JUMPBOX_SNAPSHOT_NAME:-jumpbox-snap}"
  local snapshot_copy_name="${JUMPBOX_SNAPSHOT_COPY_NAME:-jumpbox-snap-c}"
  local new_disk_name="${JUMPBOX_NEW_DISK_NAME:-jumpbox-osdisk-c}"
  local new_vnet_name="${JUMPBOX_NEW_VNET_NAME:-vnet-jumpbox-c}"
  local new_subnet_name="${JUMPBOX_NEW_SUBNET_NAME:-snet-jump}"
  local new_vnet_cidr="${JUMPBOX_NEW_VNET_CIDR:-10.201.0.0/16}"
  local new_subnet_cidr="${JUMPBOX_NEW_SUBNET_CIDR:-10.201.1.0/24}"
  local new_nsg_name="${JUMPBOX_NEW_NSG_NAME:-jumpbox-nsg-c}"
  local new_pip_name="${JUMPBOX_NEW_PIP_NAME:-jumpbox-pip-c}"
  local new_nic_name="${JUMPBOX_NEW_NIC_NAME:-jumpbox-nic-c}"

  snapshot_source_disk "$old_disk_id" "$snapshot_name" "$rg" "$current_location" || return 1

  local source_snapshot_id
  source_snapshot_id="$(az snapshot show --name "$snapshot_name" --resource-group "$rg" --query id -o tsv)"

  copy_snapshot_cross_region "$source_snapshot_id" "$snapshot_copy_name" "$rg" "$REGION_JUMPBOX" || return 1
  create_disk_from_snapshot "$new_disk_name" "$snapshot_copy_name" "$rg" "$REGION_JUMPBOX" || return 1
  create_target_network "$new_vnet_name" "$new_subnet_name" "$rg" "$REGION_JUMPBOX" "$new_vnet_cidr" "$new_subnet_cidr" || return 1
  create_target_nsg "$new_nsg_name" "$rg" "$REGION_JUMPBOX" "$ALLOWED_IP" || return 1
  associate_nsg_to_subnet "$new_vnet_name" "$new_subnet_name" "$new_nsg_name" "$rg" || return 1
  create_target_public_ip "$new_pip_name" "$rg" "$REGION_JUMPBOX" || return 1
  create_target_nic "$new_nic_name" "$rg" "$REGION_JUMPBOX" "$new_vnet_name" "$new_subnet_name" "$new_pip_name" || return 1

  # L'ancienne VM doit être supprimée avant de créer la nouvelle : GOAD nomme
  # toujours le jumpbox "ubuntu-jumpbox" (nom en dur, non templaté), et Azure
  # interdit deux ressources de même nom dans le même resource group, même
  # dans des régions différentes. Le reste (réseau, NSG, IP, NIC) est préparé
  # avant la suppression pour minimiser la coupure.
  #
  # Si create_vm_from_disk échoue après que delete_old_vm a réussi (quota,
  # SKU indisponible), le jumpbox n'existe plus nulle part mais le disque
  # copié ($new_disk_name) reste intact et attachable : on s'arrête alors
  # avec un message de récupération clair, sans lancer cleanup_orphans (qui
  # supprimerait le disque d'origine, la seule autre référence utilisable).
  delete_old_vm "$vm_name" "$rg" "$REGION_JUMPBOX" || return 1

  if ! create_vm_from_disk "$vm_name" "$rg" "$REGION_JUMPBOX" "$new_disk_name" "$new_nic_name"; then
    log_error "create_vm_from_disk a échoué : $vm_name n'existe plus nulle part (l'ancienne VM a déjà été supprimée)."
    log_error "Récupération : le disque copié '$new_disk_name' (rg=$rg, région=$REGION_JUMPBOX) est intact — réessayer la création de la VM manuellement à partir de ce disque (az vm create --attach-os-disk $new_disk_name ...) une fois la cause de l'échec résolue (quota/capacité Azure notamment)."
    log_error "cleanup_orphans n'est PAS exécuté : l'ancien disque ($old_disk_id) est conservé au cas où."
    return 1
  fi

  cleanup_orphans "$rg" "$old_disk_id" "$old_pip_name" "$old_nic_name"

  log_info "Migration du jumpbox vers $REGION_JUMPBOX terminée."
}

main() {
  parse_common_flags "$@"
  set -- "${REMAINING_ARGS[@]}"
  load_lab_env
  migrate_jumpbox
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -euo pipefail
  main "$@"
fi
