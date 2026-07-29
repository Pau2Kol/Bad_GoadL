#!/bin/bash

# Tes groupes de ressources
RG_GOAD="GOAD-LIGHT-CD2EEC-GOAD-LIGHT-AZURE"
RG_VAULT="AI-ML-Services-RG"

# Le lab GOAD (dc01/dc02/srv02) est en denmarkeast (quota 4/4 vCPU, sature).
# Le jumpbox a ete migre en indiasouthcentral pour liberer 1 vCPU sur denmarkeast
# (necessaire pour passer dc01 en Standard_B2s). Meme RG, region differente :
# az vm start/deallocate par nom/id fonctionne sans changement, la region
# n'a besoin d'etre precisee que pour info dans les messages ci-dessous.
LOC_GOAD="denmarkeast"
LOC_JUMPBOX="indiasouthcentral"

if [ "$1" == "start" ]; then
    echo -e "🚀 \e[1;32m1/4 - Allumage des Contrôleurs de Domaine (DC01 & DC02) [$LOC_GOAD]...\e[0m"
    az vm start --resource-group $RG_GOAD --name goad-vm-dc01 --no-wait
    az vm start --resource-group $RG_GOAD --name goad-vm-dc02 --no-wait

    echo -e "🚀 \e[1;33m2/4 - Allumage du Serveur (SRV02) [$LOC_GOAD]...\e[0m"
    az vm start --resource-group $RG_GOAD --name goad-vm-srv02 --no-wait

    echo -e "🚀 \e[1;34m3/4 - Allumage de la Jumpbox (Ubuntu) [$LOC_JUMPBOX]...\e[0m"
    az vm start --resource-group $RG_GOAD --name ubuntu-jumpbox --no-wait
    
    echo -e "🚀 \e[1;35m4/4 - Allumage de Comp-Vault...\e[0m"
    az vm start --resource-group $RG_VAULT --name Comp-Vault-01-a3 --no-wait
    
    echo -e "✅ \e[1;32mToutes les requêtes de démarrage ont été envoyées à Azure !\e[0m"

elif [ "$1" == "stop" ]; then
    echo -e "🛑 \e[1;31mExtinction et désallocation de toutes les machines (Lab + Vault)...\e[0m"
    
    # Désallocation du lab GOAD complet
    az vm deallocate --ids $(az vm list --resource-group $RG_GOAD --query "[].id" -o tsv) --no-wait
    
    # Désallocation spécifique de la machine Vault
    az vm deallocate --resource-group $RG_VAULT --name Comp-Vault-01-a3 --no-wait
    
    echo -e " \e[1;31mRequêtes envoyées ! Le compteur Azure s'arrêtera pour TOUTES les machines.\e[0m"

else
    echo -e "❌ \e[1;33mUsage incorrect.\e[0m Utilise :"
    echo "  ./azure.sh start  -> Pour allumer"
    echo "  ./azure.sh stop   -> Pour tout éteindre (désallouer)"
fi
