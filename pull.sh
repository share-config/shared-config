#!/usr/bin/env bash
# =============================================================================
#  make-tar-from-registry.sh
#
#  USAGE:
#    ./make-tar-from-registry.sh --file images.txt \
#                                --registry rgitry.git.local.c/grpo/project \
#                               [--output bundle.tar]
# =============================================================================
set -euo pipefail

# ── couleurs ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

log_info()  { printf "${CYAN}[INFO]${RESET}  %s\n" "$*"; }
log_ok()    { printf "${GREEN}[ OK ]${RESET}  %s\n" "$*"; }
log_warn()  { printf "${YELLOW}[WARN]${RESET}  %s\n" "$*"; }
log_error() { printf "${RED}[ERR ]${RESET}  %s\n" "$*" >&2; }
log_step()  { printf "\n${BOLD}══════════════════════════════════════${RESET}\n${BOLD} %s${RESET}\n${BOLD}══════════════════════════════════════${RESET}\n" "$*"; }

# ── valeurs par défaut ────────────────────────────────────────────────────────
IMAGE_LIST_FILE=""
LOCAL_REGISTRY=""
OUTPUT_TAR="images-bundle_$(date +%Y%m%d_%H%M%S).tar"
DOCKER_CMD="docker"

# ── aide ──────────────────────────────────────────────────────────────────────
usage() {
  printf "${BOLD}USAGE${RESET}\n"
  printf "  %s --file <image-list> --registry <local-registry>\n" "$0"
  printf "       [--output <bundle.tar>]\n\n"
  printf "${BOLD}OPTIONS${RESET}\n"
  printf "  --file       Fichier : une image par ligne, format docker.io/org/img:tag\n"
  printf "  --registry   Registre local sans slash final\n"
  printf "               ex: rgitry.git.local.c/grpo/project\n"
  printf "  --output     Nom du tar de sortie (défaut: images-bundle_DATE.tar)\n"
  exit 0
}

[[ $# -eq 0 ]] && usage

while [[ $# -gt 0 ]]; do
  case "$1" in
    --file)     IMAGE_LIST_FILE="$2";    shift 2 ;;
    --registry) LOCAL_REGISTRY="${2%/}"; shift 2 ;;
    --output)   OUTPUT_TAR="$2";         shift 2 ;;
    --help|-h)  usage ;;
    *)          log_error "Argument inconnu: $1"; usage ;;
  esac
done

# ── vérifications ─────────────────────────────────────────────────────────────
log_step "Vérifications"

[[ -z "$IMAGE_LIST_FILE" ]] && { log_error "--file est obligatoire";     exit 1; }
[[ -z "$LOCAL_REGISTRY"  ]] && { log_error "--registry est obligatoire"; exit 1; }
[[ -f "$IMAGE_LIST_FILE" ]] || { log_error "Fichier introuvable: $IMAGE_LIST_FILE"; exit 1; }
command -v "$DOCKER_CMD" &>/dev/null || { log_error "$DOCKER_CMD introuvable"; exit 1; }

log_ok "Fichier liste    : $IMAGE_LIST_FILE"
log_ok "Registre local   : $LOCAL_REGISTRY"
log_ok "Fichier de sortie: $OUTPUT_TAR"

# ── lecture de la liste ───────────────────────────────────────────────────────
log_step "Lecture de la liste"

IMAGES=()
while IFS= read -r line || [[ -n "$line" ]]; do
  # Ignore commentaires et lignes vides
  [[ "$line" =~ ^[[:space:]]*#  ]] && continue
  [[ "$line" =~ ^[[:space:]]*$  ]] && continue

  img="${line// /}"   # supprime espaces parasites
  IMAGES+=("$img")
done < "$IMAGE_LIST_FILE"

TOTAL=${#IMAGES[@]}
log_info "$TOTAL image(s) à traiter"
[[ $TOTAL -eq 0 ]] && { log_error "Liste vide. Abandon."; exit 1; }

# ── traitement séquentiel ─────────────────────────────────────────────────────
log_step "Pull & retag des images"

OK_IMAGES=()
FAIL_IMAGES=()
IDX=0

for original in "${IMAGES[@]}"; do
  IDX=$((IDX + 1))
  printf "\n${BOLD}[%d/%d]${RESET} %s\n" "$IDX" "$TOTAL" "$original"

  # ── calcul du nom dans le registre local ──────────────────────────────────
  #   docker.io/rancher/img:tag  →  LOCAL_REGISTRY/rancher/img:tag
  stripped="${original#docker.io/}"
  local_ref="${LOCAL_REGISTRY}/${stripped}"

  log_info "pull  → $local_ref"

  # ── 1. pull ───────────────────────────────────────────────────────────────
  if ! $DOCKER_CMD pull "$local_ref"; then
    log_error "Pull échoué : $local_ref"
    FAIL_IMAGES+=("$original")
    continue   # passe à l'image suivante
  fi

  # ── 2. retag vers le nom d'origine ────────────────────────────────────────
  if ! $DOCKER_CMD tag "$local_ref" "$original"; then
    log_error "Tag échoué : $local_ref → $original"
    FAIL_IMAGES+=("$original")
    continue
  fi
  log_ok "tag   ✓  $original"

  # ── 3. supprime le tag local (non bloquant) ───────────────────────────────
  $DOCKER_CMD rmi --no-prune "$local_ref" > /dev/null 2>&1 || true

  OK_IMAGES+=("$original")
done

# ── bilan ─────────────────────────────────────────────────────────────────────
log_step "Bilan des pulls"
log_ok   "${#OK_IMAGES[@]} image(s) réussie(s)"

if [[ ${#FAIL_IMAGES[@]} -gt 0 ]]; then
  log_warn "${#FAIL_IMAGES[@]} image(s) en échec :"
  for f in "${FAIL_IMAGES[@]}"; do
    log_warn "  ✗ $f"
  done
fi

if [[ ${#OK_IMAGES[@]} -eq 0 ]]; then
  log_error "Aucune image disponible pour le tar. Abandon."
  exit 1
fi

# ── création du tar ───────────────────────────────────────────────────────────
log_step "Création du tar → $OUTPUT_TAR"

printf "  Images incluses :\n"
for img in "${OK_IMAGES[@]}"; do
  printf "    • %s\n" "$img"
done
echo ""

if ! $DOCKER_CMD save -o "$OUTPUT_TAR" "${OK_IMAGES[@]}"; then
  log_error "Échec de 'docker save'"
  exit 1
fi

TAR_SIZE=$(du -sh "$OUTPUT_TAR" | cut -f1)
log_ok "Tar créé : ${BOLD}${OUTPUT_TAR}${RESET}  (${TAR_SIZE})"

# ── résumé final ──────────────────────────────────────────────────────────────
log_step "Résumé final"
printf "  %-20s %s\n"  "Fichier tar :"  "$OUTPUT_TAR"
printf "  %-20s %s\n"  "Taille :"       "$TAR_SIZE"
printf "  %-20s ${GREEN}%d${RESET} / %d\n"  "Images OK :"   "${#OK_IMAGES[@]}"   "$TOTAL"
if [[ ${#FAIL_IMAGES[@]} -gt 0 ]]; then
  printf "  %-20s ${RED}%d${RESET}\n"   "Images KO :"  "${#FAIL_IMAGES[@]}"
fi
echo ""
log_ok "Terminé ✓"