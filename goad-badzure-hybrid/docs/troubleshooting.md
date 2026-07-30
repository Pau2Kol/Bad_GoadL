# Problèmes connus au déploiement de GOAD-Light

Rencontrés lors d'un redéploiement complet from scratch. Symptôme, cause,
solution.

## `BadZure.py build` échoue avec "tenant_id is required"

**Symptôme** : `[!] tenant_id is required. Set BADZURE_TENANT_ID
environment variable or specify 'tenant_id' in the YAML configuration.`

**Cause** : `badzure.yml` n'est pas rempli, et les variables d'environnement
`BADZURE_TENANT_ID`/`BADZURE_SUBSCRIPTION_ID`/`BADZURE_DOMAIN` n'ont pas été
exportées avant de lancer `BadZure.py build`.

**Solution** : exporter ces trois variables depuis la session az active
avant de relancer (voir étape 1 de `README.md`) :

```bash
export BADZURE_TENANT_ID=$(az account show --query tenantId -o tsv)
export BADZURE_SUBSCRIPTION_ID=$(az account show --query id -o tsv)
export BADZURE_DOMAIN=$(az rest --method get --url "https://graph.microsoft.com/v1.0/organization" --query "value[0].verifiedDomains[?isDefault]|[0].name" -o tsv)
```

## `goad.py -t install` reste bloqué sur une confirmation Terraform

**Symptôme** : le terminal affiche `Do you want to perform these actions?
... Only 'yes' will be accepted` et ne répond plus, même en ayant pipé une
réponse (`echo "y" | python3 goad.py ...`).

**Cause** : `goad.py` pose deux prompts différents l'un après l'autre (le
sien, puis celui de Terraform qu'il lance en sous-processus). Une réponse
piped ne peut satisfaire que le premier.

**Solution** : lancer Terraform directement, sans passer par `goad.py` :

```bash
cd GOAD/workspace/<instance>/provider/
terraform apply -auto-approve
```

Si vous faites ça, `goad.py` n'aura pas exécuté sa phase Ansible (promotion
du contrôleur de domaine, GPOs, utilisateurs AD) : les VM existeront mais le
domaine ne sera pas configuré. Il faut la lancer manuellement, depuis le
dossier `GOAD/` :

```python
# fichier temporaire, ex. run_provisioning.py
import sys, os, importlib.util

GOAD_DIR = os.path.abspath(".")
sys.path.insert(0, GOAD_DIR)

spec = importlib.util.spec_from_file_location("goad_cli", os.path.join(GOAD_DIR, "goad.py"))
goad_cli = importlib.util.module_from_spec(spec)
spec.loader.exec_module(goad_cli)

sys.argv = ["goad.py", "-i", "<instance>", "-l", "GOAD-Light", "-p", "azure"]
args = goad_cli.parse_args()
g = goad_cli.Goad(args)
g.do_load("<instance>")

provisioner = g.lab_manager.get_current_instance_provisioner()
provisioner.prepare_jumpbox("<IP publique actuelle du jumpbox>")
provisioner.run()
```

```bash
python3 run_provisioning.py
```

Remplacer `<instance>` par l'identifiant d'instance GOAD (nom du dossier
sous `workspace/`) et `<IP publique actuelle du jumpbox>` par sa vraie IP
(`az vm show --name ubuntu-jumpbox -d --query publicIps -o tsv`).

## Le wizard Azure AD Connect échoue avec "Incorrect version of TLS"

**Symptôme** : le wizard affiche "Incorrect version of TLS : TLS 1.2 is not
configured on this server" dès son lancement sur dc01.

**Cause** : TLS 1.2 (SCHANNEL + `SchUseStrongCrypto` .NET Framework) n'est
jamais activé par défaut sur l'image Windows Server utilisée par GOAD, même
si l'OS le supporte nativement.

**Ce cas est géré automatiquement** par `./scripts/00-deploy.sh link`
(`scripts/35-install-entra-connect.sh` → `powershell/enable-tls12.ps1`,
avant l'installation elle-même) : si un redémarrage de dc01 est nécessaire
(SCHANNEL chargé au boot), le script le déclenche et attend que WinRM
réponde de nouveau avant de continuer. Si le wizard échoue quand même avec
cette erreur (ex. wizard relancé bien après `link`, ou dc01 modifié
entre-temps), relancer `powershell/enable-tls12.ps1` sur dc01 (WinRM) puis
redémarrer dc01 avant de relancer le wizard.
