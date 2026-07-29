# Bad_GoadL

Lab de cybersécurité hybride sur Azure Free Trial, combinant deux projets tiers
dans le même tenant Microsoft Entra ID :

- **[GOAD](https://github.com/Orange-Cyberdefense/GOAD)** (GPL-3.0) : simulation
  d'un Active Directory on-prem vulnérable.
- **[BadZure](https://github.com/mvelazc0/BadZure)** (Apache-2.0) : misconfigurations
  Entra ID et ressources Azure.

## Structure de ce dépôt

- `GOAD/`, `BadZure/` : les deux outils tiers, inclus tels quels (vendorisés,
  pas en submodule : les remotes upstream ne sont pas des forks contrôlés par
  ce dépôt). Voir `goad-badzure-hybrid/NOTICE` pour l'attribution des licences.
- `goad-badzure-hybrid/` : **le projet réel de ce dépôt**, celui qui fusionne
  les deux outils ci-dessus. Contient les scripts d'orchestration (peering
  réseau, hardening, préparation Entra Connect, cycle de vie), la
  documentation d'installation et l'historique des changements.

Pour déployer ou comprendre le lab, commencer par
`goad-badzure-hybrid/README.md`.
