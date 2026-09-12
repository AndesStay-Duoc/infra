# Guía — Configuración de AWS: API Gateway y EC2

Paso a paso para el **API Manager** y el despliegue. Cubre el **55% de la EP2** (rutas 13%,
CORS 7%, validación JWT 20%, evidencia 15%) más los prerrequisitos de "backend y frontend
desplegados, activos e integrados".

Requiere tener listos los dos tenants: ver [`azure-identidad.md`](azure-identidad.md).

---

# Parte 0 — Verificación del Learner Lab · HACER PRIMERO

**De esto depende más de la mitad de la nota de la EP2.** No se descubre la semana de la
entrega.

1. Entrar al AWS Academy Learner Lab y pulsar **Start Lab**. Esperar el punto verde.
2. Abrir **AWS Details → AWS** para entrar a la consola.
3. En el buscador, ir a **API Gateway**.
4. Pulsar **Create API** y comprobar que **HTTP API** ofrece el botón *Build*.
5. Crear una HTTP API llamada `prueba-permisos`, sin rutas, y luego **borrarla**.
6. Ir a **EC2** y comprobar que se puede llegar al asistente de **Launch instance**.

### Si API Gateway está bloqueado

Activar el plan B y avisarle al docente el mismo día:

- **Spring Cloud Gateway** o **Nginx** en `ec2-apps`, cumpliendo el mismo rol: rutas, CORS y
  validación de JWT antes de llegar al BFF.
- La rúbrica habla de "API Manager" de forma genérica, así que un gateway propio es defendible,
  pero conviene que quede por escrito que fue una restricción del laboratorio y no una decisión
  del equipo.

## Cómo opera el Learner Lab

| Restricción | Consecuencia práctica |
|---|---|
| La sesión caduca en unas 4 horas | Las instancias se detienen. Los datos del disco EBS sobreviven; la IP pública **no** |
| No se pueden crear roles de IAM | Usar el rol preexistente `LabRole` donde se pida uno |
| Región fija, normalmente `us-east-1` | No cambiarla |
| Tipos de instancia limitados | `t2.micro` o `t3.micro`, según lo que permita el lab |

Por eso el `.env` está parametrizado por host y hay un script que reescribe las IPs. Ver la
Parte 5.

---

# Parte 1 — Crear la HTTP API

Debe ser **HTTP API**, no REST API: el JWT Authorizer nativo —que es justo lo que evalúa el
indicador 7— pertenece a HTTP API.

1. **API Gateway → Create API → HTTP API → Build**.
2. API name: `andesstay-api`
3. Sin integraciones ni rutas por ahora: se agregan en orden.
4. Crear.
5. Copiar el **Invoke URL**: `https://<api-id>.execute-api.us-east-1.amazonaws.com`

> No crear la ruta `$default`. Una ruta comodín sin authorizer deja el backend expuesto y tira
> abajo el indicador 7 completo, que es el de mayor peso individual de la EP2.

---

# Parte 2 — Los dos authorizers

Un JWT Authorizer valida **un solo issuer**, y el sistema tiene dos tenants. De ahí que las
rutas se partan en `/staff` y `/guest`.

**Authorization → Manage authorizers → Create → JWT**.

### `entra-staff`

| Campo | Valor |
|---|---|
| Name | `entra-staff` |
| Identity source | `$request.header.Authorization` |
| Issuer URL | `https://login.microsoftonline.com/<staff-tenant-id>/v2.0` |
| Audience | `api://<staff-client-id>` |

### `entra-guest`

| Campo | Valor |
|---|---|
| Name | `entra-guest` |
| Identity source | `$request.header.Authorization` |
| Issuer URL | `https://<subdominio>.ciamlogin.com/<guest-tenant-id>/v2.0` |
| Audience | `api://<guest-client-id>` |

> El Issuer URL debe coincidir **carácter por carácter** con el claim `iss` del token. No
> escribirlo de memoria: sacarlo del documento de descubrimiento, como indica la Parte C de la
> guía de Azure. Una barra final de más y todo responde 401.

API Gateway descarga el JWKS solo desde `<issuer>/.well-known/openid-configuration`. No hay que
subir claves.

---

# Parte 3 — Las 16 rutas

La tabla canónica está en [`../contracts/rutas-gateway.md`](../contracts/rutas-gateway.md).
Acá el procedimiento.

## 3.1 Crear la integración al BFF

**Integrations → Manage integrations → Create**:

| Campo | Valor |
|---|---|
| Integration type | **HTTP URI** |
| Method | `ANY` |
| URL | `http://<ip-publica-de-ec2-apps>:8080/{proxy}` |

Se reutiliza la misma integración en las 16 rutas. Cuando el Learner Lab cambie la IP, se edita
**una sola vez** acá.

## 3.2 Crear las rutas

**Routes → Create**, una por fila:

| # | Método | Ruta | Authorizer |
|---|---|---|---|
| 1 | `POST` | `/guest/reservations` | `entra-guest` |
| 2 | `GET` | `/guest/reservations` | `entra-guest` |
| 3 | `GET` | `/guest/reservations/{id}` | `entra-guest` |
| 4 | `PUT` | `/guest/reservations/{id}/status` | `entra-guest` |
| 5 | `GET` | `/guest/catalog/units` | `entra-guest` |
| 6 | `POST` | `/staff/reservations` | `entra-staff` |
| 7 | `GET` | `/staff/reservations` | `entra-staff` |
| 8 | `GET` | `/staff/reservations/{id}` | `entra-staff` |
| 9 | `PUT` | `/staff/reservations/{id}/status` | `entra-staff` |
| 10 | `GET` | `/staff/catalog/units` | `entra-staff` |
| 11 | `POST` | `/staff/catalog/units` | `entra-staff` |
| 12 | `PUT` | `/staff/catalog/units/{id}` | `entra-staff` |
| 13 | `GET` | `/staff/report/kpis` | `entra-staff` |
| 14 | `GET` | `/staff/report/top-units` | `entra-staff` |
| 15 | `GET` | `/staff/audit` | `entra-staff` |
| 16 | `GET` | `/staff/audit/{reservationId}` | `entra-staff` |

Para cada una: **Attach integration** a la del punto 3.1, y en la pestaña del authorizer,
**Attach authorizer** el que corresponda.

## 3.3 Reescritura de path

El gateway recibe `/staff/reservations` y el BFF espera `/api/reservations`. Dos opciones:

**Opción recomendada:** que el BFF acepte los prefijos `/staff` y `/guest` directamente, con un
filtro que los quite antes de enrutar. Menos configuración en el gateway, y el BFF gana un dato
útil: de qué audiencia viene la petición, que puede cruzar contra el `iss` del token.

**Alternativa:** un *parameter mapping* por ruta en el gateway que reescriba el path. Son 16
mapeos a mano y es más fácil equivocarse.

## 3.4 Verificar que ninguna ruta queda abierta

**Routes** → recorrer la lista y confirmar que las 16 muestran su authorizer. Capturar esa
pantalla: es la evidencia directa del indicador 7.

---

# Parte 4 — CORS · indicador 2, 7%

La rúbrica penaliza explícitamente los sobrepermisos: al 100% pide orígenes "definidos
correctamente" y métodos y encabezados "habilitados sin sobrepermisos". **Nada de `*`.**

**CORS → Configure**:

| Campo | Valor |
|---|---|
| `Access-Control-Allow-Origin` | `http://localhost:4200` y la URL pública del frontend. Nunca `*` |
| `Access-Control-Allow-Methods` | `GET`, `POST`, `PUT`, `OPTIONS`. Sin `DELETE` ni `PATCH`: el API no los usa |
| `Access-Control-Allow-Headers` | `authorization`, `content-type` |
| `Access-Control-Expose-Headers` | *(vacío)* |
| `Access-Control-Allow-Credentials` | **desmarcado** — el token va en la cabecera, no en cookies |
| `Access-Control-Max-Age` | `300` |

> `Allow-Credentials` activado junto con un origen comodín es una combinación que los navegadores
> rechazan, y es el tipo de detalle que la rúbrica llama "configuración insegura".

## Verificación de CORS

Preflight desde un origen permitido:

```bash
curl -i -X OPTIONS "https://<api-id>.execute-api.us-east-1.amazonaws.com/staff/reservations" -H "Origin: http://localhost:4200" -H "Access-Control-Request-Method: GET" -H "Access-Control-Request-Headers: authorization"
```

Se espera `204` con las cabeceras de la tabla.

Preflight desde un origen no autorizado, que **no** debe devolver `Access-Control-Allow-Origin`:

```bash
curl -i -X OPTIONS "https://<api-id>.execute-api.us-east-1.amazonaws.com/staff/reservations" -H "Origin: https://sitio-no-autorizado.example" -H "Access-Control-Request-Method: GET"
```

Ambas capturas van a `../evidencias/cors/`.

---

# Parte 5 — Las instancias EC2

| Instancia | Contiene | Puerto | Abierto para |
|---|---|---|---|
| `ec2-apps` | BFF y microservicios de dominio | 8080–8085 | Ver Parte 5.3 |
| `ec2-data` | Oracle Free en Docker | 1521 | Solo el SG de apps |
| `ec2-mq` | RabbitMQ, 2 nodos + Management UI | 5672, 15672 | Solo el SG de apps |
| `ec2-kafka` | 3 Zookeeper + 3 brokers + Kafka UI | 9092 | Solo el SG de apps |

Para EP1 y EP2 alcanzan `ec2-apps` y `ec2-data`. Las otras dos llegan con las fases de
mensajería.

## 5.1 Lanzar una instancia

1. **EC2 → Launch instance**.
2. Name: `ec2-apps`
3. AMI: **Amazon Linux 2023**
4. Instance type: `t3.micro`, o `t2.micro` si es lo único disponible
5. Key pair: crear `andesstay-key` y **guardar el `.pem` fuera de los repositorios**. El
   `.gitignore` ya excluye `*.pem`, pero conviene no tentar a la suerte
6. Network: la VPC por defecto, con **Auto-assign public IP** habilitado
7. Storage: 20 GiB para `ec2-apps`; **30 GiB para `ec2-data`**, que Oracle necesita espacio
8. Lanzar

> `ec2-data` con `t3.micro` y 1 GB de RAM **no alcanza para Oracle Free**. Necesita al menos
> `t3.small` con 2 GB. Si el lab no lo permite, hay que reconsiderar la base de datos: ver el
> riesgo R1 del plan.

## 5.2 Instalar Docker

Por SSH en cada instancia:

```bash
sudo dnf update -y && sudo dnf install -y docker git
sudo systemctl enable --now docker
sudo usermod -aG docker ec2-user
```

Cerrar la sesión y volver a entrar para que tome el grupo. Después:

```bash
docker compose version
```

## 5.3 Security Groups

Crear un SG por instancia y referenciarlos entre sí, **no por IP**: las IPs del Learner Lab
cambian en cada reinicio, los ids de SG no.

### `sg-apps`

| Tipo | Puerto | Origen | Motivo |
|---|---|---|---|
| SSH | 22 | Tu IP | Administración |
| Custom TCP | 8080 | `0.0.0.0/0` | Ver la nota de abajo |

### `sg-data`

| Tipo | Puerto | Origen |
|---|---|---|
| SSH | 22 | Tu IP |
| Custom TCP | 1521 | **`sg-apps`** |

### La limitación honesta del puerto del BFF

El plan decía "BFF solo desde API Gateway". Con una integración **HTTP URI pública eso no es
alcanzable**: API Gateway sale por IPs de AWS que no son fijas ni están en un SG referenciable.

Dos caminos:

1. **VPC Link con integración privada** hacia un balanceador interno. Es la solución correcta y
   permite cerrar el puerto de verdad, pero suma bastante configuración y el Learner Lab puede
   restringirla.
2. **Puerto abierto más secreto compartido.** El gateway inyecta una cabecera
   `X-Gateway-Secret` mediante *parameter mapping*, y el BFF rechaza con `403` cualquier petición
   que no la traiga. El puerto queda abierto pero el backend no es utilizable sin pasar por el
   gateway.

Para el alcance del curso, la opción 2 es suficiente y defendible, **siempre que se explique en
la presentación**: la defensa real del backend es la validación de JWT, y el secreto compartido
cierra el acceso directo. Decir esto es mejor que dejar el puerto abierto sin mencionarlo.

## 5.4 Cuando la sesión del lab caduca

Al reiniciar, las IPs públicas cambian y hay que actualizar tres lugares:

1. El `.env` de `infra` — con el script de la Parte 5.5.
2. La **integración** del API Gateway (Parte 3.1). Un solo cambio.
3. Nada en Azure, salvo que también haya cambiado la URL del frontend.

Si el lab permite **Elastic IP**, asignar una a `ec2-apps` elimina el punto 2 para siempre. Vale
la pena probarlo.

## 5.5 Script de reescritura de IPs

Guardar como `infra/scripts/actualizar-ips.sh`:

```bash
#!/usr/bin/env bash
# Reescribe los hosts del .env con las IPs publicas actuales del Learner Lab.
set -euo pipefail
ENV_FILE="${1:-.env}"

get_ip () {
  aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=$1" "Name=instance-state-name,Values=running" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text
}

for nombre in apps data mq kafka; do
  ip="$(get_ip "ec2-$nombre")"
  clave="EC2_$(echo "$nombre" | tr '[:lower:]' '[:upper:]')_HOST"
  if [ "$ip" != "None" ] && [ -n "$ip" ]; then
    sed -i "s|^${clave}=.*|${clave}=${ip}|" "$ENV_FILE"
    echo "$clave = $ip"
  else
    echo "$clave sin instancia en ejecucion"
  fi
done
```

Requiere las credenciales del lab en `~/.aws/credentials`, que se copian desde **AWS Details →
AWS CLI**. Caducan con la sesión.

---

# Parte 6 — Batería de pruebas · indicador 8, 15%

La rúbrica pide al 100% "evidencias completas del funcionamiento de todas las rutas", mostrando
"llamadas con y sin token" y confirmando que "los microservicios responden con el JSON
esperado".

## Los cuatro casos por ruta

| Caso | Esperado | Quién lo rechaza |
|---|---|---|
| Token válido con el rol correcto | `200` + JSON | — |
| Sin cabecera `Authorization` | `401` | El gateway |
| Token válido con rol insuficiente | `403` | El BFF |
| **Token del tenant equivocado** | `401` | El gateway, porque el authorizer no reconoce ese issuer |

El cuarto caso no lo pide la rúbrica, pero es la demostración más clara de que la separación
`/staff` y `/guest` funciona. Vale mostrarlo.

## Comandos

```bash
API="https://<api-id>.execute-api.us-east-1.amazonaws.com"
TOKEN="<access token del tenant corporativo>"
```

Con token:

```bash
curl -i "$API/staff/reservations" -H "Authorization: Bearer $TOKEN"
```

Sin token, debe dar 401:

```bash
curl -i "$API/staff/reservations"
```

Con un token de huésped contra una ruta de personal, debe dar 401:

```bash
curl -i "$API/staff/report/kpis" -H "Authorization: Bearer $TOKEN_HUESPED"
```

Conviene además armar una **colección Postman** con las 16 rutas por 3 casos, guardarla en
`../evidencias/postman/` y exportar los resultados. Es más presentable que capturas de terminal
y cubre el indicador de una sola vez.

---

# Checklist de cierre

## Fase 0.2 — verificación del lab

- [ ] Se puede crear una HTTP API
- [ ] Se puede lanzar una instancia EC2
- [ ] Si algo está bloqueado, plan B activado y docente avisado

## Fase 3 — API Manager

- [ ] HTTP API `andesstay-api` creada, sin ruta `$default`
- [ ] Authorizer `entra-staff` con issuer y audience correctos
- [ ] Authorizer `entra-guest` con issuer y audience correctos
- [ ] Integración HTTP URI al BFF
- [ ] Las 16 rutas creadas, **todas con authorizer**
- [ ] Reescritura de path resuelta
- [ ] CORS con orígenes explícitos, sin comodines
- [ ] Preflight permitido y preflight rechazado, capturados
- [ ] El frontend consume el gateway, no el BFF directo

## Fase 4 — despliegue

- [ ] `ec2-apps` con Docker y el BFF corriendo
- [ ] `ec2-data` con Oracle Free y los 4 esquemas
- [ ] `sg-data` permite 1521 solo desde `sg-apps`
- [ ] Puerto del BFF resuelto por VPC Link o por secreto compartido, y **explicado**
- [ ] Frontend desplegado, con su URL en las redirect URIs de ambas app registrations
- [ ] Script de IPs funcionando
- [ ] Snapshot de EBS antes de la entrega

## Evidencia

- [ ] Los 4 casos por cada una de las 16 rutas
- [ ] Colección Postman versionada
- [ ] Captura de la lista de rutas mostrando sus authorizers
- [ ] Capturas de CORS

---

# Errores frecuentes

| Síntoma | Causa | Solución |
|---|---|---|
| Todas las rutas dan 401 con un token que parece válido | Issuer URL con una barra final de más o de menos | Copiarlo del documento de descubrimiento |
| 401 en todas las rutas de un solo tenant | Audience mal escrita en ese authorizer | Debe ser `api://<client-id>`, no el client id solo |
| 500 desde el gateway | La integración apunta a una IP que ya cambió | Actualizar la integración; considerar Elastic IP |
| Error de CORS en el navegador, pero `curl` funciona | Falta el origen exacto, o falta `authorization` en los headers permitidos | Revisar la Parte 4 |
| 404 del gateway en una ruta que existe | El path del gateway no coincide con el del BFF | Ver 3.3 |
| El lab se apagó y se perdió la base de datos | El volumen no era persistente | Verificar que EBS no esté marcado *Delete on termination* |
| `aws` CLI da error de credenciales | Caducaron con la sesión | Recopiar desde AWS Details → AWS CLI |
