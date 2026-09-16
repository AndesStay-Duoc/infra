#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# AndesStay — clona los repositorios como carpetas hermanas de infra
#
# crear-infra.sh sube el código desde el equipo local y espera encontrar los
# siete repositorios del despliegue en la misma carpeta que infra:
#
#   AndesStay/
#   ├── infra/                  ← donde está este script
#   ├── frontend-andesstay/
#   ├── ms-andesstay-bff/
#   ├── ms-andesstay-reservations/
#   ├── ms-andesstay-catalog/
#   ├── ms-andesstay-report/
#   └── ms-andesstay-audit/
#
# Uso, desde Git Bash:
#   git clone https://github.com/AndesStay-Duoc/infra.git AndesStay/infra
#   bash AndesStay/infra/deploy/scripts/clonar-repos.sh            # rama develop
#   bash AndesStay/infra/deploy/scripts/clonar-repos.sh --rama main
#   bash AndesStay/infra/deploy/scripts/clonar-repos.sh --pr       # ramas de los PR abiertos
#
# Con --pr usa, en cada repositorio, la rama de su pull request abierto hacia
# develop; si no tiene ninguno, se queda en develop. Sirve para probar cambios
# todavía no integrados.
#
# Un repositorio ya clonado no se vuelve a clonar: se actualiza, y solo si no
# tiene cambios locales sin commitear.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

ORG_URL="${ORG_URL:-https://github.com/AndesStay-Duoc}"
RAMA="develop"
USAR_PR=0

while (( $# > 0 )); do
    case "$1" in
        --rama) RAMA="$2"; shift 2 ;;
        --pr)   USAR_PR=1; shift ;;
        -h|--help) sed -n '2,28p' "$0"; exit 0 ;;
        *) echo "Opción desconocida: $1" >&2; exit 1 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

REPOS=(infra frontend-andesstay ms-andesstay-bff ms-andesstay-reservations
       ms-andesstay-catalog ms-andesstay-report ms-andesstay-audit)

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m[ok]\033[0m %s\n' "$*"; }
warn() { printf '  \033[1;33m[aviso]\033[0m %s\n' "$*" >&2; }

command -v git > /dev/null 2>&1 || { echo "Falta git" >&2; exit 1; }

if (( USAR_PR )) && ! command -v gh > /dev/null 2>&1; then
    warn "--pr necesita GitHub CLI (gh) autenticado; sin él se usa $RAMA en todos"
    USAR_PR=0
fi

# Rama del PR abierto hacia develop, o vacío si no hay
rama_pr() {
    gh pr list --repo "AndesStay-Duoc/$1" --base develop --state open \
        --json headRefName --jq '.[0].headRefName // empty' 2>/dev/null || true
}

log "Repositorios en $PROJECT_ROOT"

for repo in "${REPOS[@]}"; do
    destino="$PROJECT_ROOT/$repo"
    rama="$RAMA"

    if (( USAR_PR )); then
        pr=$(rama_pr "$repo")
        [[ -n "$pr" ]] && rama="$pr"
    fi

    if [[ -d "$destino/.git" ]]; then
        if [[ -n "$(git -C "$destino" status --porcelain --untracked-files=no)" ]]; then
            warn "$repo tiene cambios sin commitear; no se toca"
            continue
        fi
        git -C "$destino" fetch --quiet origin
        if git -C "$destino" rev-parse --verify --quiet "origin/$rama" > /dev/null; then
            git -C "$destino" checkout --quiet "$rama" 2>/dev/null \
                || git -C "$destino" checkout --quiet -b "$rama" "origin/$rama"
            git -C "$destino" pull --quiet --ff-only origin "$rama"
            ok "$repo actualizado en $rama"
        else
            warn "$repo no tiene la rama $rama; queda en $(git -C "$destino" rev-parse --abbrev-ref HEAD)"
        fi
    else
        if git clone --quiet --branch "$rama" "$ORG_URL/$repo.git" "$destino" 2>/dev/null; then
            ok "$repo clonado en $rama"
        else
            git clone --quiet "$ORG_URL/$repo.git" "$destino"
            warn "$repo no tiene la rama $rama; se clonó la rama por defecto"
        fi
    fi
done

log "Listo"
cat <<TEXTO

  Siguiente paso, desde Git Bash:

    cd "$PROJECT_ROOT/infra/deploy"
    cp credenciales-aws.example credenciales-aws.txt

  y seguir infra/deploy/README.md.

TEXTO
