#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# AndesStay — certificado autofirmado para nginx
#
# Genera infra/deploy/nginx/certs/andesstay.{crt,key}, que usa el server block
# de :443.
#
# Alcance: este certificado sirve para el acceso administrativo directo a la
# instancia. NO está en la ruta del login, por dos motivos que conviene tener
# presentes:
#
#   · API Gateway rechaza las integraciones HTTP_PROXY contra backends cuyo
#     certificado no esté firmado por una CA pública, así que el tramo
#     API Gateway -> nginx viaja por HTTP (puerto 80) protegido con la cabecera
#     X-Gateway-Secret.
#   · Entra ID no acepta Redirect URI con una IP cruda, de modo que el navegador
#     nunca llega a https://<ip> durante el login.
#
# El TLS que ve el navegador lo entrega API Gateway con su certificado de AWS.
#
# Uso:
#   bash infra/deploy/gen-selfsigned-cert.sh [ip-o-dominio]
#
# Sin argumento, consulta la IP pública al servicio de metadatos de la instancia.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CERT_DIR="$SCRIPT_DIR/nginx/certs"
DAYS=825   # máximo que aceptan los navegadores actuales para un certificado de servidor

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

HOST="${1:-}"

if [[ -z "$HOST" ]]; then
    log "Consultando la IP pública en el servicio de metadatos (IMDSv2)"
    # IMDSv2 exige un token; en Ubuntu 24.04 sobre EC2 es el modo por defecto.
    TOKEN=$(curl -fsS -X PUT "http://169.254.169.254/latest/api/token" \
        -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null || true)

    if [[ -n "$TOKEN" ]]; then
        HOST=$(curl -fsS -H "X-aws-ec2-metadata-token: $TOKEN" \
            "http://169.254.169.254/latest/meta-data/public-ipv4" 2>/dev/null || true)
    fi
fi

if [[ -z "$HOST" ]]; then
    HOST="localhost"
    echo "No se pudo determinar la IP pública; se emite para localhost"
fi

echo "Emitiendo para: $HOST"

mkdir -p "$CERT_DIR"

# El SAN es obligatorio: los navegadores ignoran el Common Name desde hace años.
# Si HOST es una IP va como IP:, y si es un nombre como DNS:.
if [[ "$HOST" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    SAN="IP:$HOST,IP:127.0.0.1,DNS:localhost"
else
    SAN="DNS:$HOST,DNS:localhost,IP:127.0.0.1"
fi

log "Generando clave y certificado"
# Se usa un archivo de configuración en lugar de -subj y -addext a propósito.
# Git Bash y MSYS en Windows convierten cualquier argumento que empiece por "/"
# en una ruta del sistema, y dejan el subject convertido en
# "C:/Program Files/Git/C=CL/...". Con el archivo de configuración el problema
# desaparece y el script se comporta igual en la EC2 y en la máquina de
# desarrollo, que es donde se prueba antes de subirlo a la instancia.
CONF=$(mktemp)
trap 'rm -f "$CONF"' EXIT

cat > "$CONF" <<CONFIG
[req]
distinguished_name = dn
x509_extensions    = v3_req
prompt             = no

[dn]
C  = CL
ST = Region Metropolitana
L  = Santiago
O  = AndesStay
OU = Infraestructura
CN = $HOST

[v3_req]
subjectAltName   = $SAN
keyUsage         = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
basicConstraints = critical, CA:FALSE
CONFIG

openssl req -x509 -nodes \
    -newkey rsa:2048 \
    -days "$DAYS" \
    -keyout "$CERT_DIR/andesstay.key" \
    -out    "$CERT_DIR/andesstay.crt" \
    -config "$CONF"

# La clave privada solo la lee nginx dentro del contenedor, que corre como root
# antes de bajar a nginx en los workers.
chmod 600 "$CERT_DIR/andesstay.key"
chmod 644 "$CERT_DIR/andesstay.crt"

log "Certificado generado"
openssl x509 -in "$CERT_DIR/andesstay.crt" -noout -subject -dates -ext subjectAltName

cat <<'NOTA'

Recordatorio: al ser autofirmado, el navegador muestra una advertencia si se
entra por https://<ip> directamente. Es lo esperado y no afecta al login, que
pasa por el dominio de API Gateway.

Para sustituirlo por Let's Encrypt cuando exista un dominio real, ver la
sección 12.1 de docs/DESPLIEGUE-EC2.md.

NOTA
