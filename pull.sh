#!/usr/bin/env bash
# =============================================================================
#  make-tar-from-registry.sh
#
#  USAGE:
#    ./make-tar-from-registry.sh --file images.txt \
#                                --registry rgitry.git.local.c/grpo/project \
#                               [--output bundle.tar] \
#                               [--workers 4]
#
#  DESCRIPTION:
#    Pour chaque image listée au format "docker.io/rancher/image:tag"
#    le script :
#      1. Calcule le nom dans le registre local
#            docker.io/rancher/image:tag
#         => rgitry.git.local.c/grpo/project/rancher/image:tag
#      2. Pull l'image depuis le registre local
#      3. Retag en nom d'origine  docker.io/rancher/image:tag
#      4. Supprime le tag local temporaire
#    Puis crée un tar contenant TOUTES les images (docker save).
# =============================================================================
set -euo pipefail

# ── couleurs ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

log_info()  { echo -e "${CYAN}[INFO]${RESET}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${RESET}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
log_error() { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
log_step()  { echo -e "\n${BOLD}════════════════════════════════${RESET}"; echo -e "${BOLD} $*${RESET}"; echo -e "${BOLD}════════════════════════════════${RESET}"; }

# ── valeurs par défaut ────────────────────────────────────────────────────────
IMAGE_LIST_FILE=""
LOCAL_REGISTRY=""
OUTPUT_TAR="images-bundle_$(date +%Y%m%d_%H%M%S).tar"
MAX_WORKERS=4
DOCKER_CMD="docker"                    # remplacez par "podman" si besoin
PULLED_IMAGES=()                       # images retaggées (noms d'origine)
FAILED_IMAGES=()

# ── aide ──────────────────────────────────────────────────────────────────────
usage() {
  echo -e "${BOLD}USAGE${RESET}"
  echo "  $0 --file <image-list> --registry <local-registry-path>"
  echo "     [--output <bundle.tar>] [--workers <N>]"
  echo ""
  echo -e "${BOLD}OPTIONS${RESET}"
  echo "  --file       Fichier texte : une image par ligne, format docker.io/org/img:tag"
  echo "  --registry   Chemin du registre local sans slash final"
  echo "               ex : rgitry.git.local.c/grpo/project"
  echo "  --output     Nom du fichier tar de sortie (défaut : images-bundle_DATE.tar)"
  echo "  --workers    Parallélisme pour les pulls (défaut : 4)"
  echo ""
  echo -e "${BOLD}EXEMPLE${RESET}"
  echo "  $0 --file images.txt --registry rgitry.git.local.c/grpo/project --output bundle.tar"
  exit 0
}

# ── parse des arguments ───────────────────────────────────────────────────────
[[ $# -eq 0 ]] && usage

while [[ $# -gt 0 ]]; do
  case "$1" in
    --file)       IMAGE_LIST_FILE="$2"; shift 2 ;;
    --registry)   LOCAL_REGISTRY="${2%/}"; shift 2 ;;   # retire le slash final
    --output)     OUTPUT_TAR="$2"; shift 2 ;;
    --workers)    MAX_WORKERS="$2"; shift 2 ;;
    --help|-h)    usage ;;
    *) log_error "Argument inconnu : $1"; usage ;;
  esac
done

# ── vérifications préalables ──────────────────────────────────────────────────
log_step "Vérifications"

[[ -z "$IMAGE_LIST_FILE" ]] && { log_error "--file est obligatoire"; exit 1; }
[[ -z "$LOCAL_REGISTRY"  ]] && { log_error "--registry est obligatoire"; exit 1; }
[[ -f "$IMAGE_LIST_FILE" ]] || { log_error "Fichier introuvable : $IMAGE_LIST_FILE"; exit 1; }

command -v "$DOCKER_CMD" &>/dev/null || { log_error "$DOCKER_CMD n'est pas disponible"; exit 1; }

log_ok "Fichier liste    : $IMAGE_LIST_FILE"
log_ok "Registre local   : $LOCAL_REGISTRY"
log_ok "Fichier de sortie: $OUTPUT_TAR"
log_ok "Workers max      : $MAX_WORKERS"

# ── fonction : transforme docker.io/a/b:t → LOCAL/a/b:t ──────────────────────
#
#  Règle de mapping :
#    docker.io/<reste>  =>  LOCAL_REGISTRY/<reste>
#
#  Cas particulier docker.io/library/<image> (images officielles) :
#    docker.io/library/nginx:1.25  => LOCAL_REGISTRY/library/nginx:1.25
#    (conservé tel quel pour que le retag soit exact)
#
local_name() {
  local original="$1"
  # Supprime uniquement le préfixe "docker.io/"
  local stripped="${original#docker.io/}"
  echo "${LOCAL_REGISTRY}/${stripped}"
}

# ── fonction : pull + retag d'une image ───────────────────────────────────────
process_image() {
  local original="$1"
  local local_ref
  local_ref="$(local_name "$original")"

  echo -e "${CYAN}[PULL]${RESET}  $local_ref"

  # Pull depuis le registre local
  if ! $DOCKER_CMD pull "$local_ref" 2>&1 | sed 's/^/        /'; then
    log_error "Pull échoué pour : $local_ref"
    echo "FAILED:${original}" >> /tmp/.make_tar_failures_$$
    return 1
  fi

  # Retag vers le nom d'origine
  if ! $DOCKER_CMD tag "$local_ref" "$original"; then
    log_error "Tag échoué : $local_ref → $original"
    echo "FAILED:${original}" >> /tmp/.make_tar_failures_$$
    return 1
  fi

  log_ok "Retagué : $local_ref → $original"

  # Supprime le tag local (libère de la confusion, l'image reste en cache)
  $DOCKER_CMD rmi "$local_ref" --no-prune 2>/dev/null || true

  echo "OK:${original}" >> /tmp/.make_tar_results_$$
}

export -f process_image local_name log_ok log_error
export LOCAL_REGISTRY DOCKER_CMD

# ── lecture et nettoyage de la liste ─────────────────────────────────────────
log_step "Lecture de la liste d'images"

mapfile -t RAW_LINES < <(grep -v '^\s*#' "$IMAGE_LIST_FILE" | grep -v '^\s*$')

IMAGES=()
for line in "${RAW_LINES[@]}"; do
  img="$(echo "$line" | tr -d '[:space:]')"
  # Normalise : si pas de registre explicite, ajoute docker.io/
  if [[ "$img" != *"/"* ]]; then
    img="docker.io/library/${img}"
  elif [[ "$img" != *"."* && "$img" != "localhost"* ]]; then
    # pas de point dans la première composante → pas de registre → docker.io
    img="docker.io/${img}"
  fi
  IMAGES+=("$img")
done

log_info "${#IMAGES[@]} image(s) à traiter"

# ── initialisation des fichiers temporaires ───────────────────────────────────
rm -f /tmp/.make_tar_results_$$ /tmp/.make_tar_failures_$$
touch /tmp/.make_tar_results_$$ /tmp/.make_tar_failures_$$

# ── pull en parallèle ─────────────────────────────────────────────────────────
log_step "Pull & retag des images (parallélisme: ${MAX_WORKERS})"

PIDS=()
RUNNING=0

for img in "${IMAGES[@]}"; do
  # Lance le traitement en arrière-plan
  ( process_image "$img" ) &
  PIDS+=($!)
  (( RUNNING++ ))

  # Limite le parallélisme
  if [[ $RUNNING -ge $MAX_WORKERS ]]; then
    wait "${PIDS[0]}" 2>/dev/null || true
    PIDS=("${PIDS[@]:1}")
    (( RUNNING-- ))
  fi
done

# Attend tous les jobs restants
for pid in "${PIDS[@]}"; do
  wait "$pid" 2>/dev/null || true
done

# ── bilan des pulls ───────────────────────────────────────────────────────────
log_step "Bilan des pulls"

mapfile -t OK_LINES    < <(grep '^OK:'     /tmp/.make_tar_results_$$ | cut -d: -f2-)
mapfile -t FAILED_LINES < <(grep '^FAILED:' /tmp/.make_tar_failures_$$ | cut -d: -f2-)

log_ok "${#OK_LINES[@]} image(s) récupérée(s) avec succès"

if [[ ${#FAILED_LINES[@]} -gt 0 ]]; then
  log_warn "${#FAILED_LINES[@]} image(s) en échec :"
  for f in "${FAILED_LINES[@]}"; do
    log_warn "  ✗ $f"
  done
fi

if [[ ${#OK_LINES[@]} -eq 0 ]]; then
  log_error "Aucune image disponible pour créer le tar. Abandon."
  rm -f /tmp/.make_tar_results_$$ /tmp/.make_tar_failures_$$
  exit 1
fi

# ── création du tar ───────────────────────────────────────────────────────────
log_step "Création du tar : $OUTPUT_TAR"

log_info "Images incluses dans le tar :"
for img in "${OK_LINES[@]}"; do
  echo "    • $img"
done

echo ""
log_info "Exécution de : $DOCKER_CMD save -o \"$OUTPUT_TAR\" ${OK_LINES[*]}"

if $DOCKER_CMD save -o "$OUTPUT_TAR" "${OK_LINES[@]}"; then
  TAR_SIZE=$(du -sh "$OUTPUT_TAR" | cut -f1)
  log_ok "Tar créé avec succès : ${BOLD}$OUTPUT_TAR${RESET} (${TAR_SIZE})"
else
  log_error "Échec lors de la création du tar"
  rm -f /tmp/.make_tar_results_$$ /tmp/.make_tar_failures_$$
  exit 1
fi

# ── vérification du tar ───────────────────────────────────────────────────────
log_step "Vérification du contenu du tar"

echo ""
log_info "Images présentes dans $OUTPUT_TAR :"
$DOCKER_CMD image load --input "$OUTPUT_TAR" --quiet 2>/dev/null \
  | grep -E "^Loaded image" \
  | sed 's/^/    ✓ /' \
  || $DOCKER_CMD inspect \
       $(docker load -i "$OUTPUT_TAR" 2>/dev/null | awk '/Loaded image/{print $NF}') \
       --format '    ✓ {{.RepoTags}}' 2>/dev/null \
  || log_warn "Impossible de lister le contenu (non bloquant)"

# ── nettoyage ─────────────────────────────────────────────────────────────────
rm -f /tmp/.make_tar_results_$$ /tmp/.make_tar_failures_$$

# ── résumé final ─────────────────────────────────────────────────────────────
log_step "Résumé"
echo -e "  Fichier tar  : ${BOLD}${OUTPUT_TAR}${RESET}"
echo -e "  Taille       : ${TAR_SIZE}"
echo -e "  Images OK    : ${GREEN}${#OK_LINES[@]}${RESET} / ${#IMAGES[@]}"
[[ ${#FAILED_LINES[@]} -gt 0 ]] && \
  echo -e "  Images KO    : ${RED}${#FAILED_LINES[@]}${RESET}"
echo ""
log_ok "Terminé."
