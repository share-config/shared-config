# ─────────────────────────────────────────────────────────────
# README — RKE2 Platform Projects
# ─────────────────────────────────────────────────────────────

## Structure des projets

```
platform/
├── tools/
│   ├── skopeo-image/        → Image Docker custom Skopeo (avec CA + wget/zstd/jq/tar)
│   └── ansible-image/       → Image Docker custom Ansible (avec CA + wget)
├── rke2-artefacts/          → Pipeline sync images + binaires (PROJECT 1)
└── rke2-cluster-deploy/     → Pipeline déploiement cluster RKE2 (PROJECT 2)
```

---

## Project 1 — rke2-artefacts

### Objectif
- Synchroniser les images RKE2 (core + Calico) vers le GitLab Container Registry
- Stocker les binaires RKE2 dans le GitLab Package Registry

### Pipeline (.gitlab-ci.yml)

| Job | Stage | Description |
|-----|-------|-------------|
| `sync-rke2-images` | sync | Télécharge les tarballs, pousse les images via skopeo |
| `download-rke2-binaries` | sync | Télécharge le binaire RKE2 et le publie dans le Package Registry |
| `verify-rke2-images` | verify | Vérifie les images poussées contre les listes officielles |

### Variables CI/CD requises

| Variable | Type | Description |
|----------|------|-------------|
| `RKE2_VERSION` | Variable | Version RKE2 cible (ex: v1.32.1+rke2r1) |
| `SKOPEO_IMAGE` | Variable | Référence de l'image skopeo custom |

### Image skopeo custom (tools/skopeo-image/Dockerfile)
- Base : `quay.io/skopeo/stable`
- Ajouts : `wget`, `zstd`, `jq`, `tar` via dnf
- CA self-signed intégré

---

## Project 2 — rke2-cluster-deploy

### Objectif
Déployer un cluster RKE2 via le playbook `rancherfederal/rke2-ansible` (commit 76ff1c4c)

### Pipeline (.gitlab-ci.yml)

| Job | Stage | Description |
|-----|-------|-------------|
| `download-artifacts` | prepare | Télécharge binaires depuis Package Registry project1 |
| `bootstrap-users` | bootstrap | Crée l'utilisateur sudoer sur les nœuds (idempotent) |
| `check-inventory` | validate | Vérifie la syntaxe de l'inventaire Ansible |
| `check-connectivity` | validate | Teste la connectivité SSH (`ansible ping`) |
| `deploy-cluster` | deploy | Lance `ansible-playbook playbooks/site.yml` |

### Variables CI/CD requises

| Variable | Type | Description |
|----------|------|-------------|
| `RKE2_VERSION` | Variable | Version RKE2 cible |
| `ANSIBLE_IMAGE` | Variable | Référence de l'image Ansible custom |
| `GITLAB_URL` | Variable | URL de base GitLab (ex: https://gitlab.example.com) |
| `P1_PROJECT_ID` | Variable | ID numérique du projet rke2-artefacts |
| `P1_DEPLOY_TOKEN` | Variable (masked) | Deploy token avec scope `read_package_registry` |
| `DEPLOY_USER` | Variable | Nom du nouvel utilisateur sudoer (ex: rke2) |
| `ANSIBLE_SSH_PRIVATE_KEY` | **File** | Clé SSH privée pour accès aux nœuds |
| `REGISTRY_DEPLOY_USERNAME` | Variable (masked) | Username deploy token container registry |
| `REGISTRY_DEPLOY_PASSWORD` | Variable (masked) | Password deploy token container registry |

### Fichiers à compléter avant le premier run

1. **`inventory/cluster/hosts.yml`** — renseigner les IPs réelles des nœuds
2. **`registries.yaml`** — remplacer les placeholders par les vraies credentials
3. Construire et pousser les deux images Docker (skopeo + ansible)

### Image Ansible custom (tools/ansible-image/Dockerfile)
- Base : `python:3.12-alpine`
- Ajouts : `openssh-client`, `sshpass`, `git`, `wget`, `ca-certificates`, `ansible`
- CA self-signed intégré
- Utilisée pour TOUS les jobs du pipeline project2 (Option B)

---

## Ordre d'exécution recommandé

```
Project 1 — rke2-artefacts :
  1. sync-rke2-images        (pousse les images)
  2. download-rke2-binaries  (stocke les binaires)
  3. verify-rke2-images      (vérifie les images)

Project 2 — rke2-cluster-deploy :
  1. download-artifacts      (récupère les binaires depuis project1)
  2. bootstrap-users         (crée l'utilisateur sudoer sur les nœuds)
  3. check-inventory         (valide l'inventaire)
  4. check-connectivity      (teste SSH)
  5. deploy-cluster          (déploie RKE2)
```

---

## Références

- rke2-ansible : https://github.com/rancherfederal/rke2-ansible/tree/76ff1c4c
- RKE2 releases : https://github.com/rancher/rke2/releases
- RKE2 air-gap install : https://docs.rke2.io/install/airgap
- RKE2 private registry : https://docs.rke2.io/install/private_registry
