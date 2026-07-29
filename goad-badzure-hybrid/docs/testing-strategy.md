# Stratégie de test

Le lab complet est long et coûteux à redéployer (30 à 45 minutes de
provisioning, quota Azure Free Trial serré). Aucun script ne doit exiger un
redéploiement complet pour être validé. Trois niveaux, du moins cher au plus
cher :

1. **Validation statique** (instantané, zéro Azure) : `bash -n` et
   `shellcheck` pour tout script Bash, `Invoke-ScriptAnalyzer` pour tout
   PowerShell.
2. **Dry-run** (minutes, Azure en lecture seule) : chaque script supporte
   `--dry-run`, qui logue les commandes d'écriture sans rien modifier. Une
   fonction individuelle peut aussi être testée seule via
   `source scripts/xx-....sh` puis un appel direct.
3. **Fixtures jetables** (le levier principal pour les scripts réseau/infra) :
   voir `test/README.md`. Un environnement Azure factice minimal permet de
   tester `10-migrate-jumpbox.sh`, `20-peer-networks.sh`, `21-nsg-rules.sh`
   sans dépendre du lab réel. Les scripts touchant dc01 en durci
   (`30-goad-hardening-fix.sh`, `50-goad-gpo-unblock.sh`) et Entra Connect
   (`40-prepare-entra-connect.sh`) ne sont testables que sur le vrai lab.

Workflow avant de considérer un script validé : `shellcheck`/
`Invoke-ScriptAnalyzer`, relecture, `--dry-run` sur l'infra réelle, puis si
testable sur fixtures, exécution ciblée dessus. Le déploiement complet réel
n'est fait qu'en fin de projet, comme test d'acceptation, jamais comme
méthode de debug d'un script individuel.
