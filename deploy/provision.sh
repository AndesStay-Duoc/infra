#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# AndesStay — aprovisionamiento de la instancia EC2 (Ubuntu 24.04 LTS)
#
# Deja la máquina lista para levantar el stack: Docker, swap, estructura de
# directorios y los ocho repositorios clonados como hermanos.
#
# Se ejecuta UNA VEZ, dentro de la instancia recién creada:
#   curl -fsSL <url-del-script> -o provision.sh && bash provision.sh
#
# o, si el repositorio infra ya está clonado:
#   bash infra/deploy/provision.sh
#
# Es idempotente: volver a ejecutarlo no rompe nada.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/andesstay}"
GIT_ORG="${GIT_ORG:-https://github.com/AndesStay-Duoc}"
GIT_BRANCH="${GIT_BRANCH:-develop}"

# SKIP_CLONE=1 omite el paso de clonado. Sirve para desplegar el árbol de
# trabajo local —con cambios todavía sin commitear— subiéndolo por scp en lugar
# de bajarlo de GitHub. El resto del aprovisionamiento no cambia.
SKIP_CLONE="${SKIP_CLONE:-0}"

REPOS=(
    infra
    frontend-andesstay
    ms-andesstay-bff
    ms-andesstay-reservations
    ms-andesstay-catalog
    ms-andesstay-report
    ms-andesstay-audit
)

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[aviso] %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m[error] %s\033[0m\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] && die "Conviene ejecutarlo como el usuario ubuntu, no como root. El script usa sudo donde hace falta."

# ── 1. Comprobaciones previas ────────────────────────────────────────────────
log "Comprobando el sistema"

if ! grep -q 'Ubuntu' /etc/os-release; then
    warn "Esta instancia no parece Ubuntu. El script asume apt y el repositorio oficial de Docker."
fi

TOTAL_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
echo "RAM disponible: ${TOTAL_MB} MB"

if (( TOTAL_MB < 1800 )); then
    warn "Menos de 2 GB de RAM. Compilar cinco servicios Spring Boot va a fallar por falta de memoria."
    warn "Se recomienda t3.medium. El swap que crea este script ayuda, pero no sustituye a la RAM."
fi

# ── 2. Paquetes base ─────────────────────────────────────────────────────────
log "Actualizando el índice de paquetes"
sudo apt-get update -y

log "Instalando utilidades base"
# ca-certificates y curl son requisitos del repositorio de Docker;
# git clona los repositorios; jq se usa en los scripts de verificación.
sudo apt-get install -y --no-install-recommends \
    ca-certificates curl git jq openssl gnupg

log "Fijando la zona horaria en America/Santiago"
# Los logs y los timestamps de auditoría se leen mucho mejor en hora local.
# La base de datos, en cambio, trabaja en UTC (ver --default-time-zone del compose).
sudo timedatectl set-timezone America/Santiago

# ── 3. Swap ──────────────────────────────────────────────────────────────────
# Un build de Maven puede superar el límite de RAM de una instancia pequeña. El
# swap evita que el OOM killer mate el proceso a mitad de compilación.
if [[ -f /swapfile ]]; then
    echo "El swap ya existe, se omite"
else
    log "Creando 2 GB de swap"
    sudo fallocate -l 2G /swapfile
    sudo chmod 600 /swapfile
    sudo mkswap /swapfile
    sudo swapon /swapfile
    echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab > /dev/null
    # Con swappiness bajo, el kernel usa el swap como red de seguridad y no como
    # almacenamiento habitual, que en un disco EBS sería muy lento.
    echo 'vm.swappiness=10' | sudo tee /etc/sysctl.d/99-andesstay.conf > /dev/null
    sudo sysctl -p /etc/sysctl.d/99-andesstay.conf
fi

# ── 4. Docker ────────────────────────────────────────────────────────────────
# Se instala desde el repositorio oficial de Docker y no con "apt install
# docker.io": el paquete de Ubuntu va por detrás y no trae el plugin
# docker-compose-plugin, que es lo que aporta el comando "docker compose".
if command -v docker > /dev/null 2>&1; then
    echo "Docker ya está instalado: $(docker --version)"
else
    log "Instalando Docker CE desde el repositorio oficial"

    sudo install -m 0755 -d /etc/apt/keyrings
    sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
        | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    sudo apt-get update -y
    sudo apt-get install -y \
        docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin
fi

log "Habilitando Docker al arranque"
sudo systemctl enable --now docker

# Permite usar docker sin sudo. Requiere reabrir la sesión SSH para que el
# cambio de grupo tenga efecto.
if id -nG "$USER" | grep -qw docker; then
    echo "El usuario $USER ya pertenece al grupo docker"
else
    log "Agregando $USER al grupo docker"
    sudo usermod -aG docker "$USER"
    NEEDS_RELOGIN=1
fi

# Sin rotación, los logs de los contenedores llenan el disco de la instancia.
log "Limitando el tamaño de los logs de Docker"
sudo tee /etc/docker/daemon.json > /dev/null <<'JSON'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
JSON
sudo systemctl restart docker

# ── 5. Cortafuegos ───────────────────────────────────────────────────────────
# El Security Group de AWS es la primera línea de defensa; UFW añade una segunda
# dentro de la instancia. El 443 queda abierto aquí y se acota en el Security
# Group, que es donde se puede restringir por IP de origen.
log "Configurando UFW"
sudo ufw --force reset > /dev/null
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22/tcp   comment 'SSH'
sudo ufw allow 80/tcp   comment 'API Gateway -> nginx'
sudo ufw allow 443/tcp  comment 'Acceso administrativo directo'
sudo ufw --force enable
sudo ufw status verbose

# ── 6. Directorios y repositorios ────────────────────────────────────────────
log "Preparando $INSTALL_DIR"
sudo mkdir -p "$INSTALL_DIR"
sudo chown "$USER:$USER" "$INSTALL_DIR"

cd "$INSTALL_DIR"

if [[ "$SKIP_CLONE" == "1" ]]; then
    echo "SKIP_CLONE=1: se omite el clonado. Se espera que el código ya esté en $INSTALL_DIR"
fi

for repo in "${REPOS[@]}"; do
    if [[ "$SKIP_CLONE" == "1" ]]; then
        if [[ -d "$repo" ]]; then
            echo "  $repo presente"
        else
            warn "$repo no está en $INSTALL_DIR y SKIP_CLONE=1; el compose fallará al construirlo"
        fi
        continue
    fi

    if [[ -d "$repo/.git" ]]; then
        echo "  $repo ya está clonado, actualizando"
        git -C "$repo" fetch --quiet origin
        git -C "$repo" checkout --quiet "$GIT_BRANCH"
        git -C "$repo" pull --quiet --ff-only origin "$GIT_BRANCH"
    else
        log "Clonando $repo"
        git clone --quiet --branch "$GIT_BRANCH" "$GIT_ORG/$repo.git" "$repo"
    fi
done

# ms-andesstay-notify no se clona: es consumidor puro de RabbitMQ, no expone
# endpoints REST y no forma parte de este despliegue.

# ── 7. Certificado autofirmado ───────────────────────────────────────────────
if [[ ! -f "$INSTALL_DIR/infra/deploy/gen-selfsigned-cert.sh" ]]; then
    warn "Todavía no está infra/deploy/; el certificado se genera cuando el código esté en su sitio"
elif [[ -f "$INSTALL_DIR/infra/deploy/nginx/certs/andesstay.crt" ]]; then
    echo "El certificado ya existe, se omite"
else
    log "Generando el certificado autofirmado"
    bash "$INSTALL_DIR/infra/deploy/gen-selfsigned-cert.sh"
fi

# ── 8. Resumen ───────────────────────────────────────────────────────────────
log "Aprovisionamiento terminado"

cat <<RESUMEN

Estado de la instancia:
  Directorio      : $INSTALL_DIR
  Docker          : $(docker --version 2>/dev/null || echo 'requiere reabrir la sesión')
  Compose         : $(docker compose version --short 2>/dev/null || echo 'requiere reabrir la sesión')
  Swap            : $(free -h | awk '/Swap/ {print $2}')

Pasos siguientes:

  1. Copiar el .env compartido desde la máquina local:
       bash infra/deploy/scripts/push-env.sh

  2. Construir las imágenes de a una, para no agotar la memoria:
       cd $INSTALL_DIR
       for s in mysql reservations catalog report audit bff web; do
           docker compose --env-file .env -f infra/deploy/compose.yml build \$s
       done

  3. Levantar el stack:
       docker compose --env-file .env -f infra/deploy/compose.yml up -d

  4. Verificar:
       docker compose --env-file .env -f infra/deploy/compose.yml ps
       curl -s localhost/healthz

RESUMEN

if [[ -n "${NEEDS_RELOGIN:-}" ]]; then
    warn "Cerrar y reabrir la sesión SSH antes de usar docker sin sudo."
fi
