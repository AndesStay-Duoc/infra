# Prueba de punta a punta de RabbitMQ

Guía para comprobar, en un computador propio y con Docker, que la mensajería de AndesStay funciona
completa:

1. el **administrador de la mensajería** (`ms-andesstay-mq`) crea, consulta y elimina colas,
   exchanges y bindings, y protege la topología del sistema;
2. **`ms-andesstay-reservations` publica** un mensaje cuando cambia una reserva;
3. **`ms-andesstay-notify` lo consume** y envía el correo;
4. un mensaje que falla **termina en su DLQ** y queda **registrado en los logs**;
5. todo se puede **ver en la consola de RabbitMQ**.

Está escrita para alguien del equipo que no participó en la configuración. Cada comando va
precedido de lo que hace y seguido del resultado esperado.

---

## Qué está verificado y qué no

La guía se ejecutó completa el **2026-10-15** en Windows 11 con Docker Desktop 29.5.3, partiendo de
volúmenes vacíos. Cada paso lleva una de estas marcas:

| Marca | Significado |
|---|---|
| ✅ **Verificado** | Se ejecutó y el resultado mostrado es el real |
| 🔑 **Verificado con token local** | Se ejecutó con un JWT de prueba firmado localmente (ver abajo). **Falta repetirlo con un token real de Entra ID** |
| ⚠️ **No verificado** | No se pudo ejecutar; el resultado esperado sale del código |

**Por qué un token local.** Las llamadas a `mq`, `catalog`, `reservations` y a las métricas de
`notify` exigen un JWT de Entra ID, y obtener uno requiere iniciar sesión en el frontend con un
usuario real. Para la verificación se usó un JWT con el **mismo `iss`, `aud`, `roles` y `scp`** que
emite Entra ID, pero firmado con una llave RSA generada para la prueba, y se apuntó la validación a
esa llave mediante la variable `SPRING_SECURITY_OAUTH2_RESOURCESERVER_JWT_JWK_SET_URI`, pasada solo
en esa ejecución. Eso comprueba de verdad la validación de firma, emisor, audiencia y rol en los
cuatro servicios; lo que **no** comprueba es que Entra ID emita el token como se espera. Ni la llave
ni esa variable quedaron en el repositorio. **Para la prueba con token real basta seguir esta guía
tal cual**: no usa nada de ese montaje.

**Versiones con las que se verificó.** Las ramas que se probaron, porque varias todavía están en
revisión:

| Repositorio | Rama | Qué depende de ella |
|---|---|---|
| `ms-andesstay-mq` | `feat/mq-proteccion-y-validacion` | Pasos 4.3 a 4.5: la protección de bindings, que `forzar=true` no la levante, la validación de formato y `GET /exchanges/{nombre}`. Con `develop`, `forzar=true` sí borra una cola protegida y los bindings no están protegidos |
| `ms-andesstay-notify` | `feat/notify-centraliza-y-separa`, que incluye `feat/notify-seguridad-jwt` | Paso 6.3: que `/actuator/metrics` exija el rol Admin |
| `ms-andesstay-reservations` | `develop` más dos arreglos locales que no tocan RabbitMQ (eventos Kafka y reservas por correo) | Nada de esta guía |
| `ms-andesstay-catalog` | `develop` | — |

---

## Requisitos

| Requisito | Notas |
|---|---|
| Docker Desktop con Compose v2 | Con al menos 4 GB asignados. Los ocho contenedores usan en conjunto unos 3 GB |
| Git Bash | Los comandos son de bash. En PowerShell cambian las comillas y las variables |
| Los repositorios clonados como carpetas hermanas | `infra`, `ms-andesstay-notify`, `ms-andesstay-mq`, `ms-andesstay-reservations`, `ms-andesstay-catalog`. Ver `deploy/scripts/clonar-repos.sh` |
| Una cuenta de Entra ID con el rol **Admin** | Para el token. Ver el paso 3 |
| Node.js | Para armar el cuerpo de una publicación en el paso 6.1 y, opcionalmente, revisar el token en el paso 3 |

**Todos los comandos se ejecutan desde la carpeta raíz** que contiene los repositorios
(`AndesStay/`), no desde dentro de `infra`.

> **Ojo con las tildes en Windows.** En Git Bash, un `curl -d '…'` con `ó` o `ñ` se envía en la
> codificación de la consola y no en UTF-8, y el servicio responde `400 Invalid UTF-8 middle byte`.
> Los ejemplos de esta guía usan solo ASCII; si se necesitan tildes, poner el JSON en un archivo
> guardado en UTF-8 y enviarlo con `--data-binary @archivo.json`.

---

## Paso 0. Preparar las variables

**Qué hace.** Crea `infra/.env` a partir de la plantilla. Ese archivo **no se versiona** (está en el
`.gitignore`).

```bash
cp infra/.env.example infra/.env
```

Abrirlo y completar, como mínimo:

| Variable | Valor para esta prueba |
|---|---|
| `RABBITMQ_USER` | `andesstay` |
| `RABBITMQ_PASSWORD` | Cualquier contraseña |
| `RABBITMQ_ERLANG_COOKIE` | Cualquier texto largo; lo comparten los dos nodos |
| `MYSQL_ROOT_PASSWORD`, `MYSQL_APP_PASSWORD` | Cualquier contraseña |
| `MYSQL_DATABASE`, `MYSQL_APP_USER` | `andesstay` (dejar los de la plantilla) |
| `MAIL_HOST` | `mailpit` (o vacío: el compose usa `mailpit` por omisión) |
| `MAIL_PORT` | `1025`. **Hay que cambiarlo**: la plantilla trae `587`, y con ese puerto notify no alcanza a Mailpit y todos los correos terminan en la DLQ |
| `MAIL_USER`, `MAIL_PASS` | Pueden quedar como están: el compose desactiva la autenticación SMTP y Mailpit acepta cualquiera |

`AZURE_TENANT_ID` y `AZURE_CLIENT_ID` pueden quedar vacíos: los compose usan los del sistema por
omisión. Las variables de Oracle no se usan.

Para no repetir el comando largo, se define un alias de sesión:

```bash
DC="docker compose --env-file infra/.env -f infra/mq/compose.yml -f infra/mq/compose.e2e.yml"
```

`infra/mq/compose.yml` trae RabbitMQ (dos nodos), notify y el administrador `mq`. El overlay
`infra/mq/compose.e2e.yml` agrega MySQL, catalog, reservations y **Mailpit**, un servidor de correo
de prueba con bandeja web. El overlay es **solo para pruebas locales**; el despliegue en AWS usa
`infra/deploy/compose.yml`.

> No usar `infra/apps/compose.yml` para esta prueba: está desactualizado (apunta los servicios a
> Oracle, pero solo tienen el driver de MySQL) y exige la red de Kafka.

---

## Paso 1. Levantar el entorno — ✅ Verificado

**Qué hace.** Construye las imágenes de notify, mq, catalog y reservations (compila cada uno con
Maven dentro de su `Dockerfile`), descarga las de RabbitMQ, MySQL y Mailpit, y arranca los
contenedores en orden de dependencia.

```bash
$DC up -d --build
```

**Cuánto tarda.** La primera vez, entre 5 y 10 minutos, casi todo en compilar las cuatro imágenes.
Con las imágenes ya construidas y los volúmenes vacíos, el `up` tardó **91 segundos** en la
verificación: los dos nodos de RabbitMQ arrancan a la vez y quedan listos en unos 45.

**Comprobar** que estén sanos:

```bash
docker ps -a --format 'table {{.Names}}\t{{.Status}}'
```

Resultado obtenido al terminar el `up` (`rabbitmq-init` termina con código 0 después de aplicar la
política; reservations es el último en arrancar y pasa a `healthy` alrededor de un minuto después):

```
NAMES                        STATUS
andesstay-e2e-reservations   Up Less than a second (health: starting)
andesstay-mq                 Up 38 seconds (healthy)
andesstay-notify             Up 38 seconds (healthy)
andesstay-rabbitmq2          Up About a minute (healthy)
andesstay-e2e-catalog        Up 49 seconds (healthy)
andesstay-rabbitmq-init      Exited (0) 38 seconds ago
andesstay-rabbitmq1          Up About a minute (healthy)
andesstay-e2e-mysql          Up About a minute (healthy)
andesstay-e2e-mailpit        Up About a minute (healthy)
```

| Dirección | Qué es | Usuario |
|---|---|---|
| `http://localhost:15672` | Consola de RabbitMQ | `RABBITMQ_USER` / `RABBITMQ_PASSWORD` |
| `http://localhost:8025` | Bandeja de Mailpit | Sin login |
| `http://localhost:8086` | Administrador `mq` | JWT con rol Admin |
| `http://localhost:8081` | Reservations | JWT |
| `http://localhost:8082` | Catalog | JWT |

Todos los puertos se publican solo en `127.0.0.1`, salvo el 5672 de AMQP: no son alcanzables desde
otro equipo.

---

## Paso 2. Revisar la topología en la consola — ✅ Verificado

**Qué se comprueba.** Que el clúster tiene dos nodos y que notify declaró al arrancar los 3
exchanges, las 9 colas y los 9 bindings del contrato (`docs/contracts/events/rabbit.md`): por cada
flujo (correo, voucher, housekeeping) una cola de trabajo, su DLQ y su cola de espera para los
reintentos.

Entrar a `http://localhost:15672` con `RABBITMQ_USER` y `RABBITMQ_PASSWORD`, y revisar:

| Pestaña | Qué se debe ver |
|---|---|
| **Overview → Nodes** | `rabbit@rabbitmq1` y `rabbit@rabbitmq2`, los dos en ejecución |
| **Exchanges** (vhost `andesstay`) | `cmd.direct` (direct), `cmd.topic` (topic) y `cmd.dead.dlx` (direct), los tres durables |
| **Queues** | Las 9 colas. Las tres de trabajo y las tres DLQ con **1 consumidor**; las tres `.retry`, con **0** |
| **Queues → `q.cmd.email` → Bindings** | Desde `cmd.direct` con `email.send` y desde `cmd.topic` con `email.*` |
| **Admin → Policies** | `ha-colas-cmd`, patrón `^q\.cmd\.`, `ha-mode: all` |

> Los **valores** de esta tabla se verificaron por línea de comandos y por la API de gestión, que
> es la misma fuente que alimenta la consola. La vista web en sí no se revisó visualmente: los
> nombres exactos de columnas o pestañas pueden variar con la versión de RabbitMQ.

**Lo mismo por línea de comandos**, útil para una captura de evidencia:

```bash
# Nodos del clúster
docker exec andesstay-rabbitmq1 rabbitmqctl -q cluster_status | grep -A3 "Running Nodes"
# Colas con sus argumentos
docker exec andesstay-rabbitmq1 rabbitmqctl -q -p andesstay list_queues name type durable arguments
# Bindings del sistema
docker exec andesstay-rabbitmq1 rabbitmqctl -q -p andesstay list_bindings source_name destination_name routing_key | grep -E "^cmd"
```

Resultado obtenido en la verificación:

```
rabbit@rabbitmq1
rabbit@rabbitmq2

q.cmd.voucher.retry       classic true [{"x-dead-letter-exchange","cmd.direct"},{"x-dead-letter-routing-key","voucher.gen"}]
q.cmd.email.retry         classic true [{"x-dead-letter-exchange","cmd.direct"},{"x-dead-letter-routing-key","email.send"}]
q.cmd.voucher.dlq         classic true [{"x-message-ttl",86400000}]
q.cmd.housekeeping.dlq    classic true [{"x-message-ttl",86400000}]
q.cmd.email               classic true [{"x-dead-letter-exchange","cmd.dead.dlx"},{"x-message-ttl",300000},{"x-max-length",1000},{"x-dead-letter-routing-key","email.dead"}]
q.cmd.housekeeping.retry  classic true [{"x-dead-letter-exchange","cmd.direct"},{"x-dead-letter-routing-key","housekeeping.ticket"}]
q.cmd.email.dlq           classic true [{"x-message-ttl",86400000}]
q.cmd.housekeeping        classic true [{"x-dead-letter-exchange","cmd.dead.dlx"},{"x-message-ttl",300000},{"x-max-length",1000},{"x-dead-letter-routing-key","housekeeping.dead"}]
q.cmd.voucher             classic true [{"x-dead-letter-exchange","cmd.dead.dlx"},{"x-message-ttl",300000},{"x-max-length",1000},{"x-dead-letter-routing-key","voucher.dead"}]

cmd.dead.dlx  q.cmd.email.dlq         email.dead
cmd.dead.dlx  q.cmd.housekeeping.dlq  housekeeping.dead
cmd.dead.dlx  q.cmd.voucher.dlq       voucher.dead
cmd.direct    q.cmd.email             email.send
cmd.direct    q.cmd.housekeeping      housekeeping.ticket
cmd.direct    q.cmd.voucher           voucher.gen
cmd.topic     q.cmd.email             email.*
cmd.topic     q.cmd.housekeeping      housekeeping.#
cmd.topic     q.cmd.voucher           voucher.*
```

Que cada DLQ tenga **un consumidor** es correcto: es `DeadLetterConsumer` de notify, que registra en
el log cada mensaje que llega. Se ve en el paso 6.

Las colas `.retry` **no tienen consumidor a propósito**: notify deja ahí el mensaje que falló con un
TTL por mensaje (1, 2 y 4 segundos), y al vencer RabbitMQ lo devuelve a `cmd.direct` con la routing
key original, de vuelta a su cola de trabajo. Su `x-message-ttl` no aparece en los argumentos porque
va en cada mensaje.

---

## Paso 3. Obtener un token de Entra ID — ⚠️ No verificado con token real

**Qué se necesita.** Un *access token* de la App Registration de AndesStay con el rol **Admin**. Se
obtiene iniciando sesión en el frontend:

1. Iniciar sesión en el frontend con una cuenta que tenga el rol **Admin** asignado.
2. F12 → **Application → Local Storage** → la clave que contiene `accesstoken` y
   `api://704a544f-3d92-44f5-aef9-8559574cff34/AndesStay.Access` → copiar el campo `secret`.
3. Guardarlo en una variable de la sesión, junto con la base de la API del administrador:

```bash
export TOKEN="<el token copiado>"
export API=http://localhost:8086/api/v1/mq
export H="Content-Type: application/json"
```

El token dura alrededor de una hora. **El mismo token sirve para los pasos 4, 5 y 6**: los cuatro
servicios validan el mismo emisor y la misma audiencia.

Opcionalmente, para revisar qué trae el token sin enviarlo a ningún sitio:

```bash
node -e 'console.log(JSON.parse(Buffer.from(process.argv[1].split(".")[1],"base64url")))' "$TOKEN"
```

Debe tener `"roles": ["Admin"]` y un `aud` igual a `api://704a544f-…` o al GUID del cliente.

---

## Paso 4. Administrar la mensajería con `ms-andesstay-mq` — 🔑 Verificado con token local

Todo lo que se crea aquí usa nombres `q.demo.*` y `ex.demo*`, ajenos al sistema, y se elimina al
final del paso. Las respuestas de error de `mq` tienen siempre la forma
`{"error":"<CÓDIGO>","detalle":"<texto>",…}`; la tabla completa de códigos está en el README de
`ms-andesstay-mq`.

### 4.1 Seguridad

**Qué hace.** Llama sin token y con un token sin el rol Admin.

```bash
curl -s -w "[HTTP %{http_code}]\n" $API/queues
curl -s -w " [HTTP %{http_code}]\n" $API/queues -H "Authorization: Bearer <token de un usuario Operador o Cliente>"
```

```
[HTTP 401]
{"error":"ROL_INSUFICIENTE","detalle":"esta operación exige el rol Admin"} [HTTP 403]
```

El `401` viene **sin cuerpo**. El `401` sin token se verificó también **sin token local**, contra la
configuración real de Entra ID.

### 4.2 Crear un exchange, dos colas y sus bindings, y consultarlos

**Qué hace.** Crea un exchange `topic` para los mensajes y un `direct` que hará de dead letter
exchange; luego una cola de trabajo que manda sus mensajes rechazados o vencidos a ese exchange, la
cola que los recibe, y los dos bindings. Los argumentos de la cola se pasan tal cual al broker.

```bash
curl -s -X POST $API/exchanges -H "Authorization: Bearer $TOKEN" -H "$H" -d '{"nombre":"ex.demo","tipo":"TOPIC"}'
curl -s -X POST $API/exchanges -H "Authorization: Bearer $TOKEN" -H "$H" -d '{"nombre":"ex.demo.dlx","tipo":"DIRECT"}'
curl -s -X POST $API/queues -H "Authorization: Bearer $TOKEN" -H "$H" \
  -d '{"nombre":"q.demo.email","argumentos":{"x-dead-letter-exchange":"ex.demo.dlx","x-dead-letter-routing-key":"demo.dead","x-message-ttl":60000,"x-max-length":1000}}'
curl -s -X POST $API/queues -H "Authorization: Bearer $TOKEN" -H "$H" -d '{"nombre":"q.demo.email.dlq"}'
curl -s -X POST $API/bindings -H "Authorization: Bearer $TOKEN" -H "$H" -d '{"exchange":"ex.demo","destino":"q.demo.email","routingKey":"demo.#"}'
curl -s -X POST $API/bindings -H "Authorization: Bearer $TOKEN" -H "$H" -d '{"exchange":"ex.demo.dlx","destino":"q.demo.email.dlq","routingKey":"demo.dead"}'
```

Cada uno responde `201`:

```json
{"recurso":"exchange","nombre":"ex.demo","operacion":"declarado","detalle":"declarado de tipo topic"}
{"recurso":"exchange","nombre":"ex.demo.dlx","operacion":"declarado","detalle":"declarado de tipo direct"}
{"recurso":"cola","nombre":"q.demo.email","operacion":"declarada","detalle":"declarada"}
{"recurso":"cola","nombre":"q.demo.email.dlq","operacion":"declarada","detalle":"declarada"}
{"recurso":"binding","nombre":"ex.demo -> q.demo.email (rk=demo.#)","operacion":"declarado","detalle":"declarado"}
{"recurso":"binding","nombre":"ex.demo.dlx -> q.demo.email.dlq (rk=demo.dead)","operacion":"declarado","detalle":"declarado"}
```

`tipo` es `DIRECT`, `TOPIC`, `FANOUT` o `HEADERS`, en mayúsculas. Declarar es idempotente: repetir
la misma petición vuelve a responder `201` sin duplicar nada.

**Consultar** un exchange, una cola y algo que no existe:

```bash
curl -s $API/exchanges/ex.demo -H "Authorization: Bearer $TOKEN"
curl -s $API/queues/q.demo.email -H "Authorization: Bearer $TOKEN"
curl -s -w " [HTTP %{http_code}]\n" $API/exchanges/ex.no.existe -H "Authorization: Bearer $TOKEN"
```

```
{"nombre":"ex.demo","tipo":"topic","durable":true,"autoDelete":false,"interno":false,"argumentos":{},"protegido":false}
{"nombre":"q.demo.email","mensajes":0,"consumidores":0,"protegida":false}
{"error":"RECURSO_NO_ENCONTRADO","detalle":"no existe la exchange 'ex.no.existe'","recurso":"exchange","nombre":"ex.no.existe"} [HTTP 404]
```

La consulta de una cola va por AMQP y solo trae mensajes y consumidores; el listado
(`GET $API/queues`) va por la API de gestión y trae además argumentos, nodo y política.

**En la consola:** *Queues* muestra `q.demo.email` con `DLX`, `DLK`, `TTL` y `Lim`, y en su detalle,
el binding desde `ex.demo` con `demo.#`.

### 4.3 La topología del sistema está protegida

**Qué hace.** Intenta, **con `forzar=true`**, eliminar una cola, purgar una DLQ y eliminar un
exchange del sistema; luego crear un binding hacia una cola del sistema y quitar uno de los nueve
bindings del contrato.

```bash
curl -s -X DELETE "$API/queues/q.cmd.email?forzar=true" -H "Authorization: Bearer $TOKEN"
curl -s -X POST "$API/queues/q.cmd.email.dlq/purge?forzar=true" -H "Authorization: Bearer $TOKEN"
curl -s -X DELETE "$API/exchanges/cmd.dead.dlx?forzar=true" -H "Authorization: Bearer $TOKEN"
curl -s -X POST $API/bindings -H "Authorization: Bearer $TOKEN" -H "$H" -d '{"exchange":"ex.demo","destino":"q.cmd.email","routingKey":"demo.#"}'
curl -s -X DELETE "$API/bindings?exchange=cmd.direct&destino=q.cmd.email&routingKey=email.send" -H "Authorization: Bearer $TOKEN"
```

Los cinco responden `409`:

```
{"error":"RECURSO_PROTEGIDO","detalle":"No se permite eliminar la cola 'q.cmd.email': forma parte de la topología de AndesStay (andesstay.mq.protegidos) y esta API no la modifica, ni siquiera con ?forzar=true","nombre":"q.cmd.email"}
{"error":"RECURSO_PROTEGIDO","detalle":"No se permite purgar la cola 'q.cmd.email.dlq': …","nombre":"q.cmd.email.dlq"}
{"error":"RECURSO_PROTEGIDO","detalle":"No se permite eliminar el exchange 'cmd.dead.dlx': …","nombre":"cmd.dead.dlx"}
{"error":"RECURSO_PROTEGIDO","detalle":"No se permite crear un binding hacia la cola 'q.cmd.email': …","nombre":"q.cmd.email"}
{"error":"RECURSO_PROTEGIDO","detalle":"No se permite eliminar un binding desde el exchange 'cmd.direct': …","nombre":"cmd.direct"}
```

Sí se permite crear un binding **desde** un exchange del sistema hacia una cola nueva, porque solo
agrega una copia de los mensajes:

```bash
curl -s -w " [HTTP %{http_code}]\n" -X POST $API/bindings -H "Authorization: Bearer $TOKEN" -H "$H" \
  -d '{"exchange":"cmd.topic","destino":"q.demo.email","routingKey":"email.*"}'
```

```
{"recurso":"binding","nombre":"cmd.topic -> q.demo.email (rk=email.*)","operacion":"declarado","detalle":"declarado"} [HTTP 201]
```

Pero ese binding **no se puede quitar por la API**, porque sale de un exchange protegido (responde
`409` como el último de arriba). Desaparece al eliminar `q.demo.email` en el paso 4.5.

Al terminar el paso siguen los nueve bindings del sistema:

```bash
docker exec andesstay-rabbitmq1 rabbitmqctl -q -p andesstay list_bindings source_name | grep -c "^cmd"
```

### 4.4 Validación de la entrada

**Qué hace.** Envía peticiones mal formadas. Todas responden `400` **sin tocar el broker**.

```bash
curl -s -X POST $API/queues -H "Authorization: Bearer $TOKEN" -H "$H" -d '{"nombre":"q demo"}'
curl -s -X POST $API/bindings -H "Authorization: Bearer $TOKEN" -H "$H" \
  -d '{"exchange":"ex.demo","destino":"q/demo","tipoDestino":"COLA","routingKey":"demo #"}'
curl -s -X DELETE "$API/bindings?exchange=ex.demo&destino=q.demo.email&tipoDestino=COLA&routingKey=demo.%23" -H "Authorization: Bearer $TOKEN"
curl -s -X POST $API/exchanges -H "Authorization: Bearer $TOKEN" -H "$H" -d '{"nombre":"amq.mio","tipo":"DIRECT"}'
curl -s -X POST $API/exchanges -H "Authorization: Bearer $TOKEN" -H "$H" -d '{"nombre":"ex.demo.x","tipo":"x-delayed"}'
```

```
{"error":"VALIDACION","detalle":"el cuerpo no es válido","campos":{"nombre":"solo admite letras sin tilde, dígitos y los caracteres . _ - :"}}
{"error":"VALIDACION","detalle":"el cuerpo no es válido","campos":{"tipoDestino":"debe ser QUEUE o EXCHANGE","destino":"solo admite letras sin tilde, dígitos y los caracteres . _ - :","routingKey":"no puede contener espacios"}}
{"error":"VALIDACION","detalle":"los parámetros no son válidos","campos":{"tipoDestino":"debe ser QUEUE o EXCHANGE"}}
{"error":"PETICION_INVALIDA","detalle":"el prefijo amq. está reservado por AMQP para los recursos que genera el broker; elige otro nombre"}
{"error":"CUERPO_ILEGIBLE","detalle":"Cannot deserialize value of type `cl.andesstay.mq.dto.TipoExchange` from String \"x-delayed\": not one of the values accepted for Enum class: [DIRECT, FANOUT, HEADERS, TOPIC] …"}
```

El tercero muestra que **los parámetros de la baja de un binding** se validan igual que el cuerpo
del alta. `tipoDestino` admite `QUEUE` o `EXCHANGE` sin distinguir mayúsculas.

Y una redeclaración con argumentos distintos, que es el conflicto clásico de AMQP:

```bash
curl -s -X POST $API/queues -H "Authorization: Bearer $TOKEN" -H "$H" -d '{"nombre":"q.demo.email","argumentos":{"x-message-ttl":1}}'
```

```
{"error":"TOPOLOGIA_INCOMPATIBLE","detalle":"ya existe con una definición distinta y AMQP no permite redefinirla","detalleDelBroker":"PRECONDITION_FAILED - inequivalent arg 'x-message-ttl' for queue 'q.demo.email' in vhost 'andesstay': received '1' but current is '60000'"}
```

Responde `409`. El mensaje del broker nombra el argumento que difiere.

### 4.5 Purgar, eliminar y limpiar

**Qué hace.** Publica un mensaje en la cola desde la API de gestión de RabbitMQ (lo mismo que el
botón *Publish message* de la consola), comprueba que llegó, vacía la cola con `mq` y elimina todo
lo creado.

```bash
source infra/.env   # para RABBITMQ_USER y RABBITMQ_PASSWORD
curl -s -u "$RABBITMQ_USER:$RABBITMQ_PASSWORD" -H "$H" -X POST \
  -d '{"properties":{},"routing_key":"demo.prueba","payload":"hola","payload_encoding":"string"}' \
  http://localhost:15672/api/exchanges/andesstay/ex.demo/publish
curl -s $API/queues/q.demo.email -H "Authorization: Bearer $TOKEN"
curl -s -X POST $API/queues/q.demo.email/purge -H "Authorization: Bearer $TOKEN"
curl -s -w "%{http_code}\n" -X DELETE "$API/bindings?exchange=ex.demo&destino=q.demo.email&routingKey=demo.%23" -H "Authorization: Bearer $TOKEN"
curl -s -w "%{http_code}\n" -X DELETE $API/queues/q.demo.email -H "Authorization: Bearer $TOKEN"
curl -s -w "%{http_code}\n" -X DELETE $API/queues/q.demo.email.dlq -H "Authorization: Bearer $TOKEN"
curl -s -w "%{http_code}\n" -X DELETE $API/exchanges/ex.demo -H "Authorization: Bearer $TOKEN"
curl -s -w "%{http_code}\n" -X DELETE $API/exchanges/ex.demo.dlx -H "Authorization: Bearer $TOKEN"
```

```
{"routed":true}
{"nombre":"q.demo.email","mensajes":1,"consumidores":0,"protegida":false}
{"recurso":"cola","nombre":"q.demo.email","operacion":"purgada","detalle":"1 mensaje(s) eliminado(s)","mensajesPurgados":1}
204
204
204
204
204
```

El `#` de la routing key va como `%23`. Eliminar una cola **no pide confirmación aunque tenga
mensajes**: solo las protegidas se rechazan.

Al final, en *Queues* quedan solo las nueve `q.cmd.*`, y los nueve bindings del sistema siguen
intactos. En la verificación también desapareció con la cola el binding `cmd.topic -> q.demo.email`
del paso 4.3.

> **Ojo con el `404` de una baja.** Un `DELETE` sobre una cola o un exchange que **no existe**
> responde `204`, no `404`: RabbitMQ 3.13 trata `queue.delete` y `exchange.delete` como
> idempotentes. La purga y las consultas de algo inexistente sí responden `404`. Ver *Hallazgos*.

---

## Paso 5. Publicar desde reservations y consumir en notify — 🔑 Verificado con token local

**Qué hace.** Prepara un hostal y una unidad en catalog (reservations la consulta antes de crear una
reserva), crea una reserva y la confirma. Al crearla, reservations publica `email.send`; al
confirmarla, publica `email.send` y `voucher.gen`. Notify consume los tres.

Los `id` se toman de cada respuesta: catalog puede traer unidades de ejemplo, así que no hay que
suponer que la nueva será la 1. En la verificación, sobre una base vacía, la unidad salió con el
`id` 9.

```bash
id() { grep -o '"id":[0-9]*' | head -1 | cut -d: -f2; }
IN=$(date -d "+10 days" +%F); OUT=$(date -d "+12 days" +%F)

# Un hostal y una unidad con un cupo (requiere rol Admin)
HOSTAL=$(curl -s -X POST http://localhost:8082/api/v1/catalog/hostales -H "Authorization: Bearer $TOKEN" -H "$H" \
  -d '{"codigo":"E2E-01","nombre":"Hostal E2E","comuna":"Pucon"}' | id)
UNIDAD=$(curl -s -X POST http://localhost:8082/api/v1/catalog/units -H "Authorization: Bearer $TOKEN" -H "$H" \
  -d "{\"hostalId\":$HOSTAL,\"name\":\"Cabana E2E\",\"type\":\"CABANA\",\"capacity\":2,\"pricePerNight\":45000,\"availableSlots\":1}" | id)

# La reserva: publica email.send
RESERVA=$(curl -s -X POST http://localhost:8081/api/v1/reservations -H "Authorization: Bearer $TOKEN" -H "$H" \
  -d "{\"guestId\":\"huesped-e2e\",\"guestEmail\":\"huesped@andesstay.test\",\"unitId\":$UNIDAD,\"checkIn\":\"$IN\",\"checkOut\":\"$OUT\",\"huespedes\":2}" | id)

# Confirmarla: publica email.send y voucher.gen
curl -s -X PUT http://localhost:8081/api/v1/reservations/$RESERVA/status -H "Authorization: Bearer $TOKEN" -H "$H" \
  -d '{"status":"CONFIRMADA"}'
```

Resultado esperado: la última respuesta, con `200`,
`{"id":1,…,"unitId":9,…,"status":"CONFIRMADA","totalPrice":90000.00,…}`.

**Lo que publicó reservations:**

```bash
docker logs andesstay-e2e-reservations 2>&1 | grep "\[RabbitMQ\]"
```

```
[RabbitMQ] Publicando email.send → reserva=1 eventId=b5c818f3-… traceId=…
[RabbitMQ] Broker confirmó la publicación · email.send eventId=b5c818f3-…
[RabbitMQ] Publicando email.send → reserva=1 eventId=35949de7-… traceId=…
[RabbitMQ] Publicando voucher.gen → reserva=1 eventId=6b1927c2-… traceId=…
[RabbitMQ] Broker confirmó la publicación · email.send eventId=35949de7-…
[RabbitMQ] Broker confirmó la publicación · voucher.gen eventId=6b1927c2-…
```

*Broker confirmó la publicación* es el *publisher confirm*: el broker aceptó y enrutó el mensaje.

**Lo que consumió notify:**

```bash
docker logs andesstay-notify 2>&1 | grep -E "\[Email\]|\[Voucher\]|\[Housekeeping\]"
```

```
[Email] Enviando a=huesped@andesstay.test asunto='Reserva recibida - AndesStay #1' traceId=b6303f23-…
[Email] Enviado correctamente traceId=b6303f23-…
[Email] ACK tag=1 intento=1/4 traceId=b6303f23-…
[Voucher] VOUCHER generado reserva=1 destinatario=huesped@andesstay.test datos={unitId=9, fechaEntrada=…, fechaSalida=…, noches=2, moneda=CLP, tarifaTotal=90000.0} traceId=41c19a78-…
[Voucher] ACK tag=1 intento=1/4 traceId=41c19a78-…
[Email] Enviando a=huesped@andesstay.test asunto='Reserva confirmada - AndesStay #1' traceId=41c19a78-…
[Email] Enviado correctamente traceId=41c19a78-…
[Email] ACK tag=2 intento=1/4 traceId=41c19a78-…
```

Cada `ACK` es la confirmación **explícita** que notify envía al broker después de procesar el
mensaje (`acknowledge-mode: manual`); `intento=1/4` dice que salió al primer intento. El `traceId`
permite seguir cada mensaje desde que reservations lo publica hasta que notify lo confirma.

**Los correos:** abrir `http://localhost:8025`. Deben estar *Reserva recibida - AndesStay #1* y
*Reserva confirmada - AndesStay #1*, para `huesped@andesstay.test`.

**En la consola:** *Queues → `q.cmd.email`* muestra actividad en los gráficos de *Publish* y
*Deliver*, y la cola vuelve a 0 mensajes porque notify confirmó cada uno.

---

## Paso 6. Provocar errores y ver los mensajes en la DLQ

Notify distingue dos clases de error (ver el Javadoc de `ConsumidorDeTrabajo`):

| Error | Ejemplo | Qué hace notify |
|---|---|---|
| **Permanente** | Destinatario inválido, cuerpo ilegible | `NACK` **sin reintentar**: el mensaje va de inmediato a la DLQ |
| **Transitorio** | El servidor de correo no responde | Confirma el original y deja una copia en la cola `.retry` con un TTL de 1, 2 y 4 segundos. Son **4 intentos** en total; agotados, `NACK` y a la DLQ |

En los dos casos el mensaje viaja por `cmd.dead.dlx` a `q.cmd.email.dlq`, donde `DeadLetterConsumer`
lo registra en el log con el motivo que RabbitMQ deja en la cabecera `x-death`.

### 6.1 Error permanente: destinatario inválido — ✅ Verificado

No necesita token: el mensaje se publica directamente en el broker, imitando a reservations.

**Qué hace.** Publica en `cmd.direct`, con la routing key `email.send`, un envelope válido cuyo
destinatario no es un correo.

**Desde la consola:** *Exchanges → `cmd.direct` → Publish message*, con *Routing key* `email.send`,
la propiedad `content_type` = `application/json` y como *Payload*:

```json
{"type":"email.send","eventId":"e2e-permanente-001","timestamp":"2026-10-15T12:00:00Z","traceId":"e2e-traza-permanente","correlationId":"e2e","source":"prueba-e2e","actor":{"userId":"e2e","role":"Admin","tenant":"staff"},"payload":{"plantilla":"RESERVA_CONFIRMADA","destinatario":"no-es-un-correo","reservationId":999,"datos":{}}}
```

> La publicación desde el formulario de la consola **no se probó visualmente**; se verificó su
> equivalente exacto por la API de gestión:

```bash
PAYLOAD='{"type":"email.send","eventId":"e2e-permanente-001","timestamp":"2026-10-15T12:00:00Z","traceId":"e2e-traza-permanente","correlationId":"e2e","source":"prueba-e2e","actor":{"userId":"e2e","role":"Admin","tenant":"staff"},"payload":{"plantilla":"RESERVA_CONFIRMADA","destinatario":"no-es-un-correo","reservationId":999,"datos":{}}}'
BODY=$(node -e 'console.log(JSON.stringify({properties:{content_type:"application/json"},routing_key:"email.send",payload:process.argv[1],payload_encoding:"string"}))' "$PAYLOAD")
curl -s -u "$RABBITMQ_USER:$RABBITMQ_PASSWORD" -H "$H" -X POST -d "$BODY" \
  http://localhost:15672/api/exchanges/andesstay/cmd.direct/publish
```

Responde `{"routed":true}`. Si se repite, cambiar el `eventId`: notify descarta los duplicados.

**En los logs de notify**, en el mismo segundo y **sin reintentos**:

```bash
docker logs andesstay-notify 2>&1 | grep -E "NACK|\[DLQ\]" | tail -2
```

```
[Email] NACK sin requeue por error PERMANENTE → DLQ. tag=3 traceId=e2e-traza-permanente motivo=destinatario inválido 'no-es-un-correo': Missing final '@domain'
[DLQ] Mensaje en cuarentena en q.cmd.email.dlq · motivo=rejected colaOrigen=q.cmd.email routingKeys=[email.send] · intentosConsumidos=0 (error permanente: no gastó reintentos) · cuerpo={"type":"email.send","eventId":"e2e-permanente-001",…}
```

En la verificación, entre el `NACK` y la línea `[DLQ]` pasaron 5 ms.

### 6.2 Error transitorio: el servidor de correo cae — 🔑 Verificado con token local

**Qué hace.** Detiene Mailpit y provoca un correo cancelando la reserva del paso 5. Notify no puede
conectarse, reintenta por la cola de espera y finalmente lo manda a la DLQ.

```bash
docker stop andesstay-e2e-mailpit
curl -s -X PUT http://localhost:8081/api/v1/reservations/$RESERVA/status -H "Authorization: Bearer $TOKEN" -H "$H" \
  -d '{"status":"CANCELADA"}'
```

**Esperar unos 30 segundos**, sin levantar Mailpit todavía (si se levanta antes, el intento
siguiente tiene éxito y el mensaje no llega a la DLQ). Luego:

```bash
docker logs -t andesstay-notify 2>&1 | grep -E "cancelada|ACK del original|agotados|intentosConsumidos=3"
```

Resultado de la verificación: cuatro intentos y la DLQ, en 27 segundos.

```
22:18:40  [Email] Enviando a=huesped@andesstay.test asunto='Reserva cancelada - AndesStay #1' traceId=9547ecaa-…
22:18:45  [Email] ACK del original tras programar el intento 2/4. tag=4 traceId=9547ecaa-… motivo=Mail server connection failed…
22:18:46  [Email] Enviando a=huesped@andesstay.test asunto='Reserva cancelada - AndesStay #1' traceId=9547ecaa-…
22:18:51  [Email] ACK del original tras programar el intento 3/4. tag=5 traceId=9547ecaa-… motivo=Mail server connection failed…
22:18:53  [Email] Enviando a=huesped@andesstay.test asunto='Reserva cancelada - AndesStay #1' traceId=9547ecaa-…
22:18:58  [Email] ACK del original tras programar el intento 4/4. tag=6 traceId=9547ecaa-… motivo=Mail server connection failed…
22:19:02  [Email] Enviando a=huesped@andesstay.test asunto='Reserva cancelada - AndesStay #1' traceId=9547ecaa-…
22:19:07  [Email] NACK sin requeue: agotados los 4 intentos → DLQ. tag=7 traceId=9547ecaa-… motivo=Mail server connection failed…
22:19:07  [DLQ] Mensaje en cuarentena en q.cmd.email.dlq · motivo=rejected colaOrigen=q.cmd.email routingKeys=[email.send] · intentosConsumidos=3 · cuerpo=…
```

Cada intento tarda 5 segundos en fallar: es el plazo de conexión del cliente SMTP
(`MAIL_TIMEOUT_MS`). Entre un intento y el siguiente están las esperas de 1, 2 y 4 segundos de la
cola `.retry`.

El mismo resultado se obtuvo **sin token**, publicando por la API de gestión, como en el 6.1, un
envelope con un destinatario válido mientras Mailpit estaba detenido.

**Volver a levantar Mailpit al terminar:**

```bash
docker start andesstay-e2e-mailpit
```

> **Hacerlo pronto.** Mientras el SMTP está caído, `/actuator/health` de notify responde `503` (ver
> *Hallazgos*) y, pasados unos dos minutos y medio, Docker marcaría el contenedor `unhealthy`. En la
> verificación, al levantar Mailpit el health volvió a `UP` sin reiniciar notify.

### 6.3 Ver la DLQ — ✅ Verificado (las métricas, 🔑 con token local)

**En los logs:** las líneas `[DLQ]` de arriba. El campo `motivo` sale de la cabecera `x-death`:
`rejected` cuando el consumidor rechazó el mensaje, `expired` si venció su TTL de 5 minutos y
`maxlen` si la cola superó los 1000 mensajes. `intentosConsumidos` cuenta los pasos por la cola
`.retry`: 0 en un error permanente y 3 cuando se agotaron los reintentos.

**En la consola:** *Queues → `q.cmd.email.dlq`*. **La columna de mensajes listos sigue en 0**: la
DLQ tiene un consumidor, `DeadLetterConsumer`, que toma cada mensaje, lo registra y lo confirma. La
evidencia en la consola son los contadores de entregas y confirmaciones. Valores obtenidos al
terminar los pasos 5, 6.1 y 6.2, por la API de gestión:

```bash
curl -s -u "$RABBITMQ_USER:$RABBITMQ_PASSWORD" \
  "http://localhost:15672/api/queues/andesstay?columns=name,message_stats.publish,message_stats.deliver_get,message_stats.ack"
```

```
q.cmd.email        publicados=4  entregados=7  ack=5
q.cmd.email.dlq    publicados=0  entregados=2  ack=2
q.cmd.email.retry  publicados=3  entregados=0  ack=0
q.cmd.voucher      publicados=1  entregados=1  ack=1
```

Cómo se leen:

- `q.cmd.email` recibió **4 publicaciones**: recibida, confirmada, el mensaje del 6.1 y la
  cancelación del 6.2. Las **7 entregas** son esas 4 más las 3 vueltas desde la cola de espera. Hubo
  **5 ACK** (los dos correos enviados y los tres originales confirmados al programar un reintento);
  las otras 2 entregas terminaron en `NACK` y fueron a la DLQ.
- `q.cmd.email.retry` recibió las 3 copias de los reintentos y no entrega nada: no tiene consumidor,
  los mensajes vencen y vuelven a `cmd.direct`.
- `publicados=0` en la DLQ no es un error: RabbitMQ no cuenta el *dead lettering* como una
  publicación, y tampoco la vuelta desde `.retry`.

Las estadísticas de la API de gestión se actualizan cada 5 segundos: si se consultan justo después
del 6.2, la DLQ puede mostrar todavía una entrega.

**En las métricas de notify** (su puerto no se publica, así que se consulta desde dentro del
contenedor). `/actuator/metrics` **exige un token con el rol Admin**, el mismo `$TOKEN` del paso 3:

```bash
docker exec andesstay-notify wget -qO- --header "Authorization: Bearer $TOKEN" \
  http://127.0.0.1:8085/actuator/metrics/notify.messages.dlq
```

```json
{"name":"notify.messages.dlq","description":"Mensajes que llegaron a una DLQ","measurements":[{"statistic":"COUNT","value":2.0}],"availableTags":[{"tag":"queue","values":["q.cmd.email.dlq"]}]}
```

Sin token responde `401` y con un token de otro rol, `403`: los tres casos se verificaron con token
local. La métrica responde `404` hasta que llega el primer mensaje a una DLQ, y se reinicia con el
contenedor.

---

## Paso 7. Apagar y limpiar — ✅ Verificado

**Qué hace.** Detiene y elimina los contenedores y la red, y **borra los volúmenes**: las colas, los
mensajes y la base de datos de la prueba. Las imágenes construidas se conservan para la próxima
vez.

```bash
$DC down -v
```

Sin `-v` se conservan los datos y el siguiente `up` arranca más rápido, pero la base y las colas
mantienen lo de la prueba anterior, y los `id` del paso 5 ya no empiezan desde cero.

---

## Hallazgos durante la verificación

| # | Hallazgo | Estado |
|---|---|---|
| 1 | **Primer arranque de RabbitMQ.** Con el volumen vacío, `rabbitmq1` tardaba unos 3 minutos en arrancar porque buscaba a `rabbitmq2`, que compose todavía no creaba. | **Resuelto** en `develop`: `rabbitmq2` depende de `rabbitmq1` con `service_started` y los dos arrancan a la vez. En la verificación, con volúmenes vacíos, quedaron listos en unos 45 s. El `start_period` de 240 s se mantiene como margen |
| 2 | **Notify no tenía timeout de SMTP.** Un servidor que resolviera pero no respondiera dejaba al consumidor bloqueado sin reintentar ni llegar a la DLQ. | **Resuelto** en `develop` de `ms-andesstay-notify`: `connectiontimeout`, `timeout` y `writetimeout` de 5 s. Verificado: cada intento del 6.2 falla a los 5 s |
| 3 | **El health de notify depende del SMTP.** Spring Boot agrega el indicador de salud del correo; con el SMTP caído, `/actuator/health` responde `503` y el contenedor quedaría `unhealthy`, aunque sigue consumiendo y mandando a la DLQ. | **Pendiente**, en `ms-andesstay-notify`: `management.health.mail.enabled: false` o tratarlo aparte. Vuelto a observar en esta verificación |
| 4 | **"intentos" en el log de la DLQ** mostraba el `count` de `x-death`, que no cuenta los intentos de entrega. | **Resuelto** en `develop` de notify: el log muestra `intentosConsumidos`, 0 en un error permanente y 3 al agotar los reintentos |
| 5 | **`apps/compose.yml` está desactualizado**: apunta a Oracle y exige la red de Kafka. | Sin cambios; esta guía usa `mq/compose.yml` y el overlay |
| 6 | **Tildes en `curl -d` desde Git Bash** se envían mal codificadas (`400 Invalid UTF-8 middle byte`). | Documentado en *Requisitos* |
| 7 | **El `DELETE` de una cola o un exchange inexistentes responde `204`** y no el `404` que documenta `ms-andesstay-mq`: RabbitMQ 3.13 trata las dos bajas como idempotentes y `deleteQueue` devuelve `true`. | **Pendiente**, en `ms-andesstay-mq`: decidir si se acepta así (es idempotente) o se consulta antes de borrar. Ocurre igual en `develop` |
| 8 | **El mensaje del 404 de un exchange** dice "no existe **la** exchange". | Cosmético, en `ms-andesstay-mq` (`RecursoNoEncontradoException`) |

---

## Resumen del estado de verificación

| Paso | Estado |
|---|---|
| 1. Levantar el entorno | ✅ Verificado, con volúmenes vacíos |
| 2. Topología en la consola | ✅ Verificado (valores por línea de comandos y API de gestión; vista web no revisada visualmente) |
| 3. Token de Entra ID | ⚠️ **No verificado con token real** |
| 4. `mq`: seguridad, creación, consulta, protección, validación y limpieza | 🔑 Verificado con token local — **falta con token real**. El `401` sin token, ✅ verificado |
| 5. Reservations publica y notify consume | 🔑 Verificado con token local — **falta con token real** |
| 6.1 DLQ por error permanente | ✅ Verificado (no requiere token); el formulario de la consola no se probó visualmente |
| 6.2 DLQ por error transitorio | 🔑 Verificado con token local; ✅ también sin token, publicando por la API de gestión |
| 6.3 Ver la DLQ en logs, consola y métricas | ✅ Logs y contadores. 🔑 Métrica con token local (200 con Admin, 403 con otro rol, 401 sin token) |
| 7. Apagar | ✅ Verificado |
