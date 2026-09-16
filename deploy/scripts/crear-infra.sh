#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# AndesStay — crea y despliega toda la infraestructura en AWS
#
# Reproduce de punta a punta el despliegue documentado en infra/deploy/README.md:
#
#    1. Security Group, par de claves, instancia EC2 y Elastic IP
#    2. HTTP API "andesstay-web" (sirve la SPA)
#    3. HTTP API "andesstay-api" con el JWT Authorizer y sus 20 rutas
#    4. Aprovisionamiento de la instancia, código, secretos, build y arranque
#    5. Pruebas de humo y resumen con los Redirect URI para Entra ID
#
# Es idempotente: cada recurso se busca antes de crearlo, primero en el archivo
# de estado y luego por nombre o etiqueta en la cuenta. Si la ejecución se corta
# —por ejemplo porque caducó la sesión del laboratorio— basta recargar las
# credenciales y volver a lanzarlo. También adopta un despliegue hecho a mano.
#
# Uso, desde Git Bash en la carpeta infra/deploy:
#   bash scripts/crear-infra.sh                  # todo, subiendo el código local
#   bash scripts/crear-infra.sh --origen github  # clona develop en la instancia
#   bash scripts/crear-infra.sh --origen github --rama feat/mi-rama
#   bash scripts/crear-infra.sh --solo-infra     # solo recursos AWS, sin desplegar
#   bash scripts/crear-infra.sh --sin-build      # reaplica configuración sin recompilar
#
# Requisitos: AWS CLI v2 (o Docker), Git Bash, y el perfil "andesstay" cargado
# con scripts/aws-session.sh.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# shellcheck source=lib-aws.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-aws.sh"

ORIGEN="local"
RAMA="develop"
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.medium}"
SOLO_INFRA=0
SIN_BUILD=0

while (( $# > 0 )); do
    case "$1" in
        --origen)     ORIGEN="$2"; shift 2 ;;
        --rama)       RAMA="$2"; shift 2 ;;
        --tipo)       INSTANCE_TYPE="$2"; shift 2 ;;
        --solo-infra) SOLO_INFRA=1; shift ;;
        --sin-build)  SIN_BUILD=1; shift ;;
        -h|--help)    sed -n '2,30p' "$0"; exit 0 ;;
        *)            die "Opción desconocida: $1 (ver --help)" ;;
    esac
done

[[ "$ORIGEN" == "local" || "$ORIGEN" == "github" ]] || die "--origen admite 'local' o 'github'"

REPOS=(infra frontend-andesstay ms-andesstay-bff ms-andesstay-reservations
       ms-andesstay-catalog ms-andesstay-report ms-andesstay-audit)

INSTALL_DIR="/opt/andesstay"
AMI_PARAM="/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"

# Rutas del contrato (infra/docs/contracts/rutas-gateway.md). Cada una lleva su
# propia integración: API Gateway exige que toda variable de path de la URI de
# integración exista en la route key, así que no pueden compartir una con {proxy}.
RUTAS_CONTRATO=(
    "POST /guest/reservations"
    "GET /guest/reservations"
    "GET /guest/reservations/{id}"
    "PUT /guest/reservations/{id}/status"
    "GET /guest/catalog/units"
    "POST /staff/reservations"
    "GET /staff/reservations"
    "GET /staff/reservations/{id}"
    "PUT /staff/reservations/{id}/status"
    "GET /staff/catalog/units"
    "POST /staff/catalog/units"
    "PUT /staff/catalog/units/{id}"
    "GET /staff/report/kpis"
    "GET /staff/report/top-units"
    "GET /staff/audit/events"
    "GET /staff/audit/reservations/{id}/timeline"
)

# Rutas que consume la SPA, que llama a /api/*. Un método por ruta y nunca ANY:
# ANY captura también el OPTIONS del preflight, el authorizer lo rechaza con 401
# porque el navegador no envía Authorization, y la petición real no llega a salir.
METODOS_API=(GET POST PUT DELETE)

# ═════════════════════════════════════════════════════════════════════════════
# 1. Comprobaciones previas
# ═════════════════════════════════════════════════════════════════════════════
log "Comprobando herramientas locales"

for cmd in ssh scp tar curl openssl sed; do
    command -v "$cmd" > /dev/null 2>&1 || die "Falta '$cmd'. En Windows, ejecutar este script desde Git Bash."
done
ok "ssh, scp, tar, curl, openssl y sed disponibles"

if [[ "$ORIGEN" == "local" && $SOLO_INFRA -eq 0 ]]; then
    for repo in "${REPOS[@]}"; do
        [[ -d "$PROJECT_ROOT/$repo" ]] || die "No está $PROJECT_ROOT/$repo.
Con --origen local, los siete repositorios tienen que estar clonados como carpetas
hermanas de infra. Alternativa: --origen github, que los clona en la instancia."
    done
    ok "los siete repositorios están en $PROJECT_ROOT"
fi

require_session

ACCOUNT_ID=$(awsq sts get-caller-identity --query Account)

load_state
if [[ -n "${ACCOUNT_ID_ESTADO:-}" && "$ACCOUNT_ID_ESTADO" != "$ACCOUNT_ID" ]]; then
    warn "El archivo de estado es de la cuenta $ACCOUNT_ID_ESTADO y la sesión es de $ACCOUNT_ID"
    warn "Se aparta como $(basename "$STATE_FILE").bak y se empieza de cero en esta cuenta"
    mv "$STATE_FILE" "$STATE_FILE.bak.$(date +%s)"
    load_state
fi
save_state ACCOUNT_ID_ESTADO "$ACCOUNT_ID"

# ═════════════════════════════════════════════════════════════════════════════
# 2. Variables y secretos del despliegue
# ═════════════════════════════════════════════════════════════════════════════
log "Preparando $ENV_FILE"

if [[ ! -f "$ENV_FILE" ]]; then
    mkdir -p "$(dirname "$ENV_FILE")"
    # La plantilla de la carpeta secrets no está versionada; la de infra sí.
    if [[ -f "$PROJECT_ROOT/secrets/andesstay.env.example" ]]; then
        cp "$PROJECT_ROOT/secrets/andesstay.env.example" "$ENV_FILE"
    else
        cp "$DEPLOY_DIR/.env.example" "$ENV_FILE"
    fi
    ok "creado a partir de la plantilla"
fi

# Los secretos se generan solo si están vacíos, así una segunda ejecución no
# invalida la base de datos ya inicializada. En hexadecimal para que no lleven
# caracteres que rompan sed, la shell o una cabecera HTTP.
[[ -n "$(get_env_var MYSQL_ROOT_PASSWORD)" ]] || { set_env_var MYSQL_ROOT_PASSWORD "$(openssl rand -hex 24)"; ok "MYSQL_ROOT_PASSWORD generado"; }
[[ -n "$(get_env_var MYSQL_APP_PASSWORD)"  ]] || { set_env_var MYSQL_APP_PASSWORD  "$(openssl rand -hex 24)"; ok "MYSQL_APP_PASSWORD generado"; }
[[ -n "$(get_env_var GATEWAY_SECRET)"      ]] || { set_env_var GATEWAY_SECRET      "$(openssl rand -hex 32)"; ok "GATEWAY_SECRET generado"; }
[[ -n "$(get_env_var MYSQL_APP_USER)"      ]] || set_env_var MYSQL_APP_USER andesstay
[[ -n "$(get_env_var MYSQL_DATABASE)"      ]] || set_env_var MYSQL_DATABASE andesstay
[[ -n "$(get_env_var AZURE_TENANT_ID)"     ]] || set_env_var AZURE_TENANT_ID 055d11d1-8ae0-4221-a6f7-b50be0a623b4
[[ -n "$(get_env_var AZURE_CLIENT_ID)"     ]] || set_env_var AZURE_CLIENT_ID 704a544f-3d92-44f5-aef9-8559574cff34
[[ -n "$(get_env_var EC2_SSH_USER)"        ]] || set_env_var EC2_SSH_USER ubuntu

GATEWAY_SECRET=$(get_env_var GATEWAY_SECRET)
AZURE_TENANT_ID=$(get_env_var AZURE_TENANT_ID)
AZURE_CLIENT_ID=$(get_env_var AZURE_CLIENT_ID)
ok "variables listas"

# ═════════════════════════════════════════════════════════════════════════════
# 3. Red: VPC, AMI y Security Group
# ═════════════════════════════════════════════════════════════════════════════
log "Resolviendo VPC por defecto y AMI de Ubuntu 24.04"

VPC_ID=$(awsq ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId')
[[ -n "$VPC_ID" ]] || die "La cuenta no tiene VPC por defecto en $AWS_REGION"
AMI_ID=$(awsq ssm get-parameter --name "$AMI_PARAM" --query Parameter.Value)
[[ -n "$AMI_ID" ]] || die "No se pudo resolver la AMI de Ubuntu 24.04"
save_state VPC_ID "$VPC_ID"
ok "VPC $VPC_ID, AMI $AMI_ID"

log "Security Group"

MY_IP=$(my_public_ip) || die "No se pudo obtener la IP pública de este equipo"

if [[ -n "${SG_ID:-}" ]] && [[ -z "$(awsq ec2 describe-security-groups --group-ids "$SG_ID" --query 'SecurityGroups[0].GroupId')" ]]; then
    clear_state_key SG_ID
fi
SG_ID=${SG_ID:-$(awsq ec2 describe-security-groups \
    --filters Name=group-name,Values=andesstay-app "Name=vpc-id,Values=$VPC_ID" \
    --query 'SecurityGroups[0].GroupId')}

if [[ -z "$SG_ID" ]]; then
    # El nombre no puede empezar por "sg-": AWS reserva ese prefijo
    SG_ID=$(awsq ec2 create-security-group --group-name andesstay-app \
        --description "AndesStay - instancia de aplicacion" --vpc-id "$VPC_ID" \
        --query GroupId)
    [[ -n "$SG_ID" ]] || die "No se pudo crear el Security Group"
    ok "creado $SG_ID"
else
    ok "existente $SG_ID"
fi
save_state SG_ID "$SG_ID"

# Cada regla por separado, para que una duplicada no impida agregar las demás
authorize_rule() {
    local port="$1" cidr="$2" desc="$3" salida
    if salida=$(awsx ec2 authorize-security-group-ingress --group-id "$SG_ID" \
        --ip-permissions "[{\"IpProtocol\":\"tcp\",\"FromPort\":$port,\"ToPort\":$port,\"IpRanges\":[{\"CidrIp\":\"$cidr\",\"Description\":\"$desc\"}]}]" 2>&1); then
        ok "puerto $port abierto a $cidr"
    elif [[ "$salida" == *Duplicate* ]]; then
        info "puerto $port ya autorizado para $cidr"
    else
        warn "no se pudo autorizar el puerto $port: $salida"
    fi
}

# 22 y 443 solo desde este equipo. Si otra persona despliega o la IP cambió, se
# agrega su IP sin quitar las anteriores.
authorize_rule 22  "$MY_IP/32" "SSH operador"
authorize_rule 443 "$MY_IP/32" "HTTPS administrativo"
# 80 abierto: las integraciones de API Gateway salen desde IPs de AWS que no se
# pueden acotar. Lo protege la cabecera X-Gateway-Secret en nginx.
authorize_rule 80  "0.0.0.0/0" "API Gateway protegido por X-Gateway-Secret"

# ═════════════════════════════════════════════════════════════════════════════
# 4. Instancia EC2 y par de claves
# ═════════════════════════════════════════════════════════════════════════════
log "Instancia EC2"

if [[ -n "${INSTANCE_ID:-}" ]]; then
    estado=$(awsq ec2 describe-instances --instance-ids "$INSTANCE_ID" --query 'Reservations[0].Instances[0].State.Name')
    [[ -z "$estado" || "$estado" == "terminated" || "$estado" == "shutting-down" ]] && clear_state_key INSTANCE_ID
fi
INSTANCE_ID=${INSTANCE_ID:-$(awsq ec2 describe-instances \
    --filters "Name=tag:Name,Values=$NAME_TAG" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[0].Instances[0].InstanceId')}

INSTANCIA_NUEVA=0

if [[ -n "$INSTANCE_ID" ]]; then
    # Una instancia existente solo sirve si se tiene la clave con que se lanzó
    KEY_NAME=$(awsq ec2 describe-instances --instance-ids "$INSTANCE_ID" --query 'Reservations[0].Instances[0].KeyName')
    KEY_FILE="$HOME/.ssh/$KEY_NAME.pem"
    [[ -f "$KEY_FILE" ]] || die "La instancia $INSTANCE_ID se lanzó con el par de claves '$KEY_NAME', pero no está $KEY_FILE.
La clave privada solo se descarga al crearla. Opciones: pedir el .pem a quien la creó,
o destruir la infraestructura con scripts/destruir-infra.sh y volver a crearla."

    estado=$(awsq ec2 describe-instances --instance-ids "$INSTANCE_ID" --query 'Reservations[0].Instances[0].State.Name')
    case "$estado" in
        stopping) info "deteniéndose; se espera y se arranca"; awsx ec2 wait instance-stopped --instance-ids "$INSTANCE_ID"
                  awsx ec2 start-instances --instance-ids "$INSTANCE_ID" > /dev/null ;;
        stopped)  info "detenida; se arranca"; awsx ec2 start-instances --instance-ids "$INSTANCE_ID" > /dev/null ;;
    esac
    ok "existente $INSTANCE_ID ($estado), clave $KEY_NAME"
else
    mkdir -p "$HOME/.ssh"
    KEY_NAME="${KEY_NAME:-andesstay-key}"
    KEY_FILE="$HOME/.ssh/$KEY_NAME.pem"

    if [[ -n "$(awsq ec2 describe-key-pairs --key-names "$KEY_NAME" --query 'KeyPairs[0].KeyName')" ]]; then
        if [[ -f "$KEY_FILE" ]]; then
            info "par de claves $KEY_NAME existente, con su .pem local"
        else
            # Existe en AWS pero no se tiene la privada: no se puede recuperar
            KEY_NAME="andesstay-key-$(date +%Y%m%d%H%M%S)"
            KEY_FILE="$HOME/.ssh/$KEY_NAME.pem"
            warn "el par andesstay-key existe en la cuenta sin su .pem local; se crea $KEY_NAME"
        fi
    fi

    if [[ ! -f "$KEY_FILE" ]]; then
        awsx ec2 create-key-pair --key-name "$KEY_NAME" --query KeyMaterial --output text > "$KEY_FILE"
        chmod 600 "$KEY_FILE" 2>/dev/null || true
        grep -q "BEGIN" "$KEY_FILE" || { rm -f "$KEY_FILE"; die "No se pudo crear el par de claves $KEY_NAME"; }
        ok "par de claves creado: $KEY_FILE"
    fi

    # El Learner Lab no permite crear roles IAM; el perfil disponible es
    # LabInstanceProfile (LabRole es el rol que contiene, no el perfil).
    PERFIL_ARG=()
    if awsq iam list-instance-profiles --query 'InstanceProfiles[].InstanceProfileName' | tr '\t' '\n' | grep -qx LabInstanceProfile; then
        PERFIL_ARG=(--iam-instance-profile Name=LabInstanceProfile)
    fi

    INSTANCE_ID=$(awsq ec2 run-instances \
        --image-id "$AMI_ID" \
        --instance-type "$INSTANCE_TYPE" \
        --key-name "$KEY_NAME" \
        --security-group-ids "$SG_ID" \
        --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":30,"VolumeType":"gp3","DeleteOnTermination":true}}]' \
        "${PERFIL_ARG[@]}" \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$NAME_TAG},{Key=Proyecto,Value=andesstay}]" \
                             "ResourceType=volume,Tags=[{Key=Name,Value=$NAME_TAG},{Key=Proyecto,Value=andesstay}]" \
        --query 'Instances[0].InstanceId')
    [[ -n "$INSTANCE_ID" ]] || die "No se pudo lanzar la instancia"
    INSTANCIA_NUEVA=1
    ok "lanzada $INSTANCE_ID ($INSTANCE_TYPE)"
fi

save_state INSTANCE_ID "$INSTANCE_ID"
save_state KEY_NAME "$KEY_NAME"
save_state KEY_FILE "$KEY_FILE"

info "esperando el estado running..."
awsx ec2 wait instance-running --instance-ids "$INSTANCE_ID"
ok "running"

# ═════════════════════════════════════════════════════════════════════════════
# 5. Elastic IP
# ═════════════════════════════════════════════════════════════════════════════
log "Elastic IP"

if [[ -n "${ALLOCATION_ID:-}" ]] && [[ -z "$(awsq ec2 describe-addresses --allocation-ids "$ALLOCATION_ID" --query 'Addresses[0].AllocationId')" ]]; then
    clear_state_key ALLOCATION_ID
fi
ALLOCATION_ID=${ALLOCATION_ID:-$(awsq ec2 describe-addresses --filters "Name=tag:Name,Values=$NAME_TAG" --query 'Addresses[0].AllocationId')}

if [[ -z "$ALLOCATION_ID" ]]; then
    ALLOCATION_ID=$(awsq ec2 allocate-address --domain vpc \
        --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=$NAME_TAG},{Key=Proyecto,Value=andesstay}]" \
        --query AllocationId)
fi

if [[ -n "$ALLOCATION_ID" ]]; then
    save_state ALLOCATION_ID "$ALLOCATION_ID"
    asociada=$(awsq ec2 describe-addresses --allocation-ids "$ALLOCATION_ID" --query 'Addresses[0].InstanceId')
    if [[ "$asociada" != "$INSTANCE_ID" ]]; then
        awsx ec2 associate-address --instance-id "$INSTANCE_ID" --allocation-id "$ALLOCATION_ID" --allow-reassociation > /dev/null
    fi
    PUBLIC_IP=$(awsq ec2 describe-addresses --allocation-ids "$ALLOCATION_ID" --query 'Addresses[0].PublicIp')
    ok "$PUBLIC_IP asociada a $INSTANCE_ID"
else
    # Algunos laboratorios bloquean las Elastic IP. Funciona igual, pero la IP
    # cambia al detener la instancia y hay que volver a ejecutar este script.
    PUBLIC_IP=$(awsq ec2 describe-instances --instance-ids "$INSTANCE_ID" --query 'Reservations[0].Instances[0].PublicIpAddress')
    warn "no se pudo asignar Elastic IP; se usa la IP pública $PUBLIC_IP, que cambia al detener la instancia"
fi
[[ -n "$PUBLIC_IP" ]] || die "La instancia no tiene IP pública"
save_state PUBLIC_IP "$PUBLIC_IP"

# Una instancia nueva puede reutilizar una IP con otra huella SSH registrada
if (( INSTANCIA_NUEVA )) && [[ -f "$HOME/.ssh/known_hosts_andesstay" ]]; then
    ssh-keygen -R "$PUBLIC_IP" -f "$HOME/.ssh/known_hosts_andesstay" > /dev/null 2>&1 || true
fi

# ═════════════════════════════════════════════════════════════════════════════
# 6. HTTP API "andesstay-web"
# ═════════════════════════════════════════════════════════════════════════════
log "HTTP API andesstay-web (hosting de la SPA)"

WEB_API_ID=$(awsq apigatewayv2 get-apis --query "Items[?Name=='andesstay-web'].ApiId | [0]")
WEB_API_NUEVA=0

if [[ -z "$WEB_API_ID" ]]; then
    # --target crea de una vez la integración, la ruta $default y el stage
    WEB_API_ID=$(awsq apigatewayv2 create-api --name andesstay-web --protocol-type HTTP \
        --target "http://$PUBLIC_IP/" --query ApiId)
    [[ -n "$WEB_API_ID" ]] || die "No se pudo crear andesstay-web"
    WEB_API_NUEVA=1
    ok "creada $WEB_API_ID"
else
    for integ in $(awsq apigatewayv2 get-integrations --api-id "$WEB_API_ID" --query 'Items[].IntegrationId'); do
        awsx apigatewayv2 update-integration --api-id "$WEB_API_ID" --integration-id "$integ" \
            --integration-uri "http://$PUBLIC_IP/" > /dev/null
    done
    ok "existente $WEB_API_ID, integración apuntando a $PUBLIC_IP"
fi

WEB_ORIGIN=$(awsq apigatewayv2 get-api --api-id "$WEB_API_ID" --query ApiEndpoint)
save_state WEB_API_ID "$WEB_API_ID"
save_state WEB_ORIGIN "$WEB_ORIGIN"
info "$WEB_ORIGIN"

# ═════════════════════════════════════════════════════════════════════════════
# 7. HTTP API "andesstay-api", authorizer y rutas
# ═════════════════════════════════════════════════════════════════════════════
log "HTTP API andesstay-api (rutas protegidas)"

# Origen exacto y sin comodines: la rúbrica penaliza los sobrepermisos de CORS.
# DELETE es necesario porque catalog.service.ts borra unidades.
CORS_JSON="{\"AllowOrigins\":[\"$WEB_ORIGIN\"],\"AllowMethods\":[\"GET\",\"POST\",\"PUT\",\"DELETE\",\"OPTIONS\"],\"AllowHeaders\":[\"authorization\",\"content-type\"],\"AllowCredentials\":false,\"MaxAge\":300}"

API_ID=$(awsq apigatewayv2 get-apis --query "Items[?Name=='andesstay-api'].ApiId | [0]")
if [[ -z "$API_ID" ]]; then
    API_ID=$(awsq apigatewayv2 create-api --name andesstay-api --protocol-type HTTP \
        --cors-configuration "$CORS_JSON" --query ApiId)
    [[ -n "$API_ID" ]] || die "No se pudo crear andesstay-api"
    ok "creada $API_ID"
else
    awsx apigatewayv2 update-api --api-id "$API_ID" --cors-configuration "$CORS_JSON" > /dev/null
    ok "existente $API_ID, CORS actualizado"
fi

API_ORIGIN=$(awsq apigatewayv2 get-api --api-id "$API_ID" --query ApiEndpoint)
save_state API_ID "$API_ID"
save_state API_ORIGIN "$API_ORIGIN"
info "$API_ORIGIN"

# Las dos formas de audiencia y en JSON. Con requestedAccessTokenVersion=2 Entra
# emite aud como el GUID pelado; api://<client-id> es la forma de los v1.0. La
# sintaxis abreviada Audience=a,Audience=b conserva solo el último valor.
JWT_JSON="{\"Issuer\":\"https://login.microsoftonline.com/$AZURE_TENANT_ID/v2.0\",\"Audience\":[\"$AZURE_CLIENT_ID\",\"api://$AZURE_CLIENT_ID\"]}"

AUTHORIZER_ID=$(awsq apigatewayv2 get-authorizers --api-id "$API_ID" --query "Items[?Name=='entra-andesstay'].AuthorizerId | [0]")
if [[ -z "$AUTHORIZER_ID" ]]; then
    AUTHORIZER_ID=$(awsq apigatewayv2 create-authorizer --api-id "$API_ID" --name entra-andesstay \
        --authorizer-type JWT --identity-source '$request.header.Authorization' \
        --jwt-configuration "$JWT_JSON" --query AuthorizerId)
    [[ -n "$AUTHORIZER_ID" ]] || die "No se pudo crear el authorizer"
    ok "authorizer entra-andesstay creado ($AUTHORIZER_ID)"
else
    awsx apigatewayv2 update-authorizer --api-id "$API_ID" --authorizer-id "$AUTHORIZER_ID" \
        --jwt-configuration "$JWT_JSON" > /dev/null
    ok "authorizer entra-andesstay existente ($AUTHORIZER_ID)"
fi
save_state AUTHORIZER_ID "$AUTHORIZER_ID"

# Un despliegue anterior pudo dejar la ruta ANY, que rompe el preflight
legacy=$(awsq apigatewayv2 get-routes --api-id "$API_ID" --query "Items[?RouteKey=='ANY /api/{proxy+}'].RouteId | [0]")
if [[ -n "$legacy" ]]; then
    awsx apigatewayv2 delete-route --api-id "$API_ID" --route-id "$legacy" > /dev/null
    warn "eliminada la ruta ANY /api/{proxy+}, que capturaba el preflight"
fi

PARAMS="overwrite:header.X-Gateway-Secret=$GATEWAY_SECRET"

# Crea la ruta con su integración, o si ya existe actualiza la integración con
# la IP y el secreto vigentes. Devuelve el id de la integración usada.
ensure_route() {
    local route_key="$1" method="$2" uri="$3" shared_integration="${4:-}"
    local target integ

    target=$(awsq apigatewayv2 get-routes --api-id "$API_ID" --query "Items[?RouteKey=='$route_key'].Target | [0]")

    if [[ -n "$target" ]]; then
        integ="${target#integrations/}"
        awsx apigatewayv2 update-integration --api-id "$API_ID" --integration-id "$integ" \
            --integration-uri "$uri" --request-parameters "$PARAMS" > /dev/null
        printf '%s' "$integ"
        return
    fi

    if [[ -n "$shared_integration" ]]; then
        integ="$shared_integration"
    else
        integ=$(awsq apigatewayv2 create-integration --api-id "$API_ID" \
            --integration-type HTTP_PROXY --integration-method "$method" \
            --integration-uri "$uri" --payload-format-version 1.0 \
            --request-parameters "$PARAMS" --query IntegrationId)
    fi

    awsx apigatewayv2 create-route --api-id "$API_ID" --route-key "$route_key" \
        --target "integrations/$integ" \
        --authorization-type JWT --authorizer-id "$AUTHORIZER_ID" > /dev/null
    printf '%s' "$integ"
}

info "rutas del contrato..."
for rk in "${RUTAS_CONTRATO[@]}"; do
    metodo="${rk%% *}"
    ruta="${rk#* }"
    ensure_route "$rk" "$metodo" "http://$PUBLIC_IP$ruta" > /dev/null
done
ok "${#RUTAS_CONTRATO[@]} rutas /staff y /guest"

info "rutas de consumo de la SPA..."
INT_API=""
for m in "${METODOS_API[@]}"; do
    # Las cuatro comparten una integración: al ser rutas comodín, {proxy} sí es válido
    INT_API=$(ensure_route "$m /api/{proxy+}" ANY "http://$PUBLIC_IP/api/{proxy}" "$INT_API")
done
ok "${#METODOS_API[@]} rutas /api/{proxy+}"

if [[ -z "$(awsq apigatewayv2 get-stages --api-id "$API_ID" --query "Items[?StageName=='\$default'].StageName | [0]")" ]]; then
    awsx apigatewayv2 create-stage --api-id "$API_ID" --stage-name '$default' --auto-deploy > /dev/null
    ok "stage \$default con auto-deploy"
fi

total=$(awsq apigatewayv2 get-routes --api-id "$API_ID" --query 'length(Items)')
abiertas=$(awsq apigatewayv2 get-routes --api-id "$API_ID" --query "length(Items[?AuthorizationType=='NONE'])")
[[ "$abiertas" == "0" ]] || die "Hay $abiertas rutas sin authorizer en andesstay-api; revisar antes de seguir"
ok "$total rutas, ninguna sin authorizer"

# ═════════════════════════════════════════════════════════════════════════════
# 8. Registro de los orígenes en el .env
# ═════════════════════════════════════════════════════════════════════════════
set_env_var PUBLIC_WEB_ORIGIN "$WEB_ORIGIN"
set_env_var PUBLIC_API_ORIGIN "$API_ORIGIN"
set_env_var EC2_PUBLIC_IP "$PUBLIC_IP"
set_env_var EC2_SSH_KEY "$KEY_FILE"

if (( SOLO_INFRA )); then
    log "Infraestructura lista (--solo-infra: no se despliega la aplicación)"
    info "Instancia : $INSTANCE_ID ($PUBLIC_IP)"
    info "Web       : $WEB_ORIGIN"
    info "API       : $API_ORIGIN"
    exit 0
fi

# ═════════════════════════════════════════════════════════════════════════════
# 9. Aprovisionamiento y código
# ═════════════════════════════════════════════════════════════════════════════
mapfile -t SSHO < <(ssh_opts "$KEY_FILE")
TARGET="ubuntu@$PUBLIC_IP"

log "Esperando que SSH responda en $PUBLIC_IP"
intentos=0
until ssh "${SSHO[@]}" "$TARGET" 'echo listo' 2>/dev/null | grep -q listo; do
    (( ++intentos > 40 )) && die "SSH no responde tras 7 minutos. Revisar que el puerto 22 esté autorizado para $MY_IP."
    sleep 10
done
ok "conectado"

if [[ "$ORIGEN" == "local" ]]; then
    log "Subiendo el código local"
    PAQUETE="$(mktemp -d)/andesstay-src.tgz"
    tar czf "$PAQUETE" -C "$PROJECT_ROOT" \
        --exclude='node_modules' --exclude='target' --exclude='.git' --exclude='dist' \
        --exclude='.angular' --exclude='*.pem' --exclude='credenciales-aws.txt' \
        --exclude='.estado-aws.env*' --exclude='nginx/certs/*.key' --exclude='nginx/certs/*.crt' \
        "${REPOS[@]}"
    info "paquete de $(du -h "$PAQUETE" | cut -f1)"
    scp "${SSHO[@]}" -q "$PAQUETE" "$TARGET:/tmp/andesstay-src.tgz"
    rm -rf "$(dirname "$PAQUETE")"

    # Se reemplaza cada repositorio entero para no dejar archivos borrados en
    # local. El .env vive en /opt/andesstay, fuera de ellos, y se conserva.
    ssh "${SSHO[@]}" "$TARGET" "bash -s" <<REMOTE
set -e
sudo mkdir -p $INSTALL_DIR
sudo chown ubuntu:ubuntu $INSTALL_DIR
cd $INSTALL_DIR
rm -rf ${REPOS[*]}
tar xzf /tmp/andesstay-src.tgz -C $INSTALL_DIR
rm -f /tmp/andesstay-src.tgz
REMOTE
    ok "código en $INSTALL_DIR"
    PROVISION_ENV="SKIP_CLONE=1"
else
    PROVISION_ENV="GIT_BRANCH=$RAMA"
    info "el código se clonará de GitHub, rama $RAMA"
fi

log "Aprovisionando la instancia (Docker, swap, cortafuegos)"
scp "${SSHO[@]}" -q "$DEPLOY_DIR/provision.sh" "$TARGET:/tmp/provision.sh"
if ! ssh "${SSHO[@]}" "$TARGET" "$PROVISION_ENV bash /tmp/provision.sh > /tmp/provision.log 2>&1"; then
    ssh "${SSHO[@]}" "$TARGET" 'tail -30 /tmp/provision.log' || true
    die "Falló el aprovisionamiento. Log completo en la instancia: /tmp/provision.log"
fi
ok "instancia aprovisionada"

log "Instalando las variables del despliegue"
ENV_FILE="$ENV_FILE" bash "$LIB_DIR/push-env.sh" --no-restart > /dev/null
ok "$INSTALL_DIR/.env con permisos 600"

# ═════════════════════════════════════════════════════════════════════════════
# 10. Build y arranque
# ═════════════════════════════════════════════════════════════════════════════
if (( SIN_BUILD )); then
    log "Arrancando el stack (--sin-build: se reutilizan las imágenes existentes)"
else
    log "Construyendo las imágenes en la instancia (10 a 20 minutos la primera vez)"
fi

# De a un servicio: compilar varios Spring Boot a la vez agota la memoria
ssh "${SSHO[@]}" "$TARGET" "bash -s" <<REMOTE
set -e
cd $INSTALL_DIR
C="docker compose --env-file .env -f infra/deploy/compose.yml"

bash infra/deploy/gen-selfsigned-cert.sh "$PUBLIC_IP" > /tmp/cert.log 2>&1

if [ "$SIN_BUILD" != "1" ]; then
    for s in reservations catalog report audit bff web; do
        inicio=\$(date +%s)
        if ! \$C build "\$s" > "/tmp/build-\$s.log" 2>&1; then
            echo "  [error] falló el build de \$s:"
            tail -30 "/tmp/build-\$s.log"
            exit 1
        fi
        echo "  [ok] \$s (\$(( \$(date +%s) - inicio ))s)"
    done
fi

\$C up -d > /tmp/up.log 2>&1

# Al reemplazar el código se borran y recrean los directorios que nginx monta
# (nginx.conf, conf.d, snippets, certs). Un contenedor ya en marcha seguiría
# apuntando a los directorios eliminados, así que se recrea siempre.
\$C up -d --force-recreate --no-deps web >> /tmp/up.log 2>&1

echo "  esperando que los siete contenedores estén sanos..."
for i in \$(seq 1 60); do
    sanos=\$(\$C ps --format '{{.Status}}' | grep -c healthy || true)
    [ "\$sanos" -ge 7 ] && break
    sleep 10
done
\$C ps --format '  {{.Name}}\t{{.Status}}'
[ "\$sanos" -ge 7 ] || { echo "  [error] no todos los contenedores quedaron sanos"; exit 1; }
REMOTE
ok "stack en ejecución"

# ═════════════════════════════════════════════════════════════════════════════
# 11. Pruebas de humo
# ═════════════════════════════════════════════════════════════════════════════
log "Pruebas de humo"

FALLOS=0
check() {
    local desc="$1" esperado="$2" obtenido="$3"
    if [[ "$obtenido" == "$esperado" ]]; then
        ok "$desc → $obtenido"
    else
        warn "$desc → $obtenido (se esperaba $esperado)"
        FALLOS=$((FALLOS + 1))
    fi
}

# API Gateway tarda unos segundos en propagar integraciones recién creadas
for _ in 1 2 3 4 5 6; do
    [[ "$(curl -s -o /dev/null -w '%{http_code}' "$WEB_ORIGIN/")" == "200" ]] && break
    sleep 5
done

check "SPA por API Gateway"               200 "$(curl -s -o /dev/null -w '%{http_code}' "$WEB_ORIGIN/")"
check "ruta del router (/dashboard)"      200 "$(curl -s -o /dev/null -w '%{http_code}' "$WEB_ORIGIN/dashboard")"
check "config.json apunta a la API"       "$API_ORIGIN" "$(curl -s "$WEB_ORIGIN/assets/config.json" | sed -n 's/.*"apiUri": *"\([^"]*\)".*/\1/p')"
check "API sin token (authorizer)"        401 "$(curl -s -o /dev/null -w '%{http_code}' "$API_ORIGIN/api/me")"
check "preflight CORS desde la SPA"       204 "$(curl -s -o /dev/null -w '%{http_code}' -X OPTIONS "$API_ORIGIN/api/me" -H "Origin: $WEB_ORIGIN" -H 'Access-Control-Request-Method: GET' -H 'Access-Control-Request-Headers: authorization')"
check "instancia sin X-Gateway-Secret"    403 "$(curl -s -o /dev/null -w '%{http_code}' "http://$PUBLIC_IP/api/me")"

# ═════════════════════════════════════════════════════════════════════════════
# 12. Resumen
# ═════════════════════════════════════════════════════════════════════════════
log "Despliegue terminado"

cat <<RESUMEN

  Aplicación : $WEB_ORIGIN
  API        : $API_ORIGIN
  Instancia  : $INSTANCE_ID  ($PUBLIC_IP)
  SSH        : ssh -i "$KEY_FILE" ubuntu@$PUBLIC_IP

  Estado guardado en : $STATE_FILE
  Variables en       : $ENV_FILE

RESUMEN

cat <<ENTRA
  ┌──────────────────────────────────────────────────────────────────────────┐
  │ Entra ID: registrar estos Redirect URI                                   │
  └──────────────────────────────────────────────────────────────────────────┘
  Portal de Azure → App registrations → 704a544f-3d92-44f5-aef9-8559574cff34
  → Authentication → plataforma "Single-page application" existente → Add URI

      $WEB_ORIGIN
      $WEB_ORIGIN/login

  Sin barra final. Sin ellos el login falla con AADSTS50011.
ENTRA

if (( WEB_API_NUEVA )); then
    printf '\n  \033[1;33mEl API web se creó en esta ejecución: su dirección es nueva y los Redirect\n  URI anteriores no sirven. Registrarlos es obligatorio antes de probar el login.\033[0m\n'
fi

if (( FALLOS > 0 )); then
    printf '\n  \033[1;33m%s prueba(s) de humo fallaron. Si el despliegue es reciente, esperar un\n  minuto y verificar de nuevo; ver "Problemas frecuentes" en infra/deploy/README.md.\033[0m\n' "$FALLOS"
fi
echo
