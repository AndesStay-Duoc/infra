# Despliegue de AndesStay en AWS

Scripts para crear, desplegar, pausar y eliminar toda la infraestructura de
AndesStay en AWS desde cualquier equipo, con una sesión del **AWS Academy
Learner Lab**.

El resultado es la arquitectura completa funcionando: la SPA de Angular servida
detrás de AWS API Gateway, el login con Entra ID, el BFF y los cuatro
microservicios con MySQL, todo en una instancia EC2 Ubuntu 24.04.

```
Navegador ──► API Gateway "andesstay-web" ──► nginx (SPA)
          └─► API Gateway "andesstay-api" ──► JWT Authorizer ──► nginx ──► BFF ──► microservicios ──► MySQL
```

---

## Resumen para quien tenga prisa

Desde **Git Bash**, en un equipo con Windows:

```bash
# 0. Una sola vez por equipo: instalar AWS CLI y Git (en PowerShell)
powershell -ExecutionPolicy Bypass -File infra/deploy/scripts/instalar-aws-cli.ps1

# 1. Una sola vez por equipo: clonar los repositorios
git clone https://github.com/AndesStay-Duoc/infra.git AndesStay/infra
bash AndesStay/infra/deploy/scripts/clonar-repos.sh

# 2. Cada vez que se abre el laboratorio: cargar credenciales
cd AndesStay/infra/deploy
cp credenciales-aws.example credenciales-aws.txt   # solo la primera vez
#    pegar en credenciales-aws.txt el bloque de AWS Details → AWS CLI
bash scripts/aws-session.sh

# 3. Crear y desplegar todo (20 a 30 minutos la primera vez)
bash scripts/crear-infra.sh

# 4. Registrar en Entra ID los dos Redirect URI que imprime el paso 3

# 5. Al terminar la sesión de trabajo
bash scripts/destruir-infra.sh --detener
```

---

## Archivos

| Archivo | Para qué |
|---|---|
| `credenciales-aws.example` | Plantilla para pegar las credenciales del laboratorio |
| `scripts/instalar-aws-cli.ps1` | Instala AWS CLI v2 y Git en Windows |
| `scripts/clonar-repos.sh` | Clona los siete repositorios como carpetas hermanas |
| `scripts/aws-session.sh` / `.ps1` | Carga las credenciales en el perfil `andesstay` |
| `scripts/check-aws-session.sh` | Indica si la sesión sigue viva y cuánto le queda |
| `scripts/crear-infra.sh` | Crea y despliega todo, de punta a punta |
| `scripts/destruir-infra.sh` | Detiene la instancia o elimina todo |
| `scripts/push-env.sh` | Vuelve a enviar las variables a la instancia |
| `scripts/lib-aws.sh` | Funciones compartidas; no se ejecuta directamente |
| `compose.yml`, `nginx/`, `mysql/` | Configuración que corre dentro de la instancia |
| `provision.sh` | Prepara la instancia; lo invoca `crear-infra.sh` |

Archivos que se generan y **nunca se suben a git**:

| Archivo | Contenido |
|---|---|
| `credenciales-aws.txt` | Credenciales temporales del laboratorio de cada persona |
| `.estado-aws.env` | Identificadores de los recursos creados en la cuenta propia |
| `../../secrets/andesstay.env` | Contraseñas de MySQL, secreto del gateway y URL del despliegue |
| `~/.ssh/andesstay-key.pem` | Clave privada para entrar a la instancia |

---

## 0. Preparar el equipo

Se hace **una sola vez** por computador.

Abrir **PowerShell** y ejecutar, desde la carpeta donde vaya a quedar el proyecto:

```powershell
powershell -ExecutionPolicy Bypass -File infra\deploy\scripts\instalar-aws-cli.ps1
```

Si todavía no se clonó nada, el script se puede descargar primero:

```powershell
Invoke-WebRequest https://raw.githubusercontent.com/AndesStay-Duoc/infra/develop/deploy/scripts/instalar-aws-cli.ps1 -OutFile instalar-aws-cli.ps1
powershell -ExecutionPolicy Bypass -File .\instalar-aws-cli.ps1
```

Instala, si faltan, **AWS CLI v2** y **Git para Windows**. Git trae Git Bash, y
con él `bash`, `ssh`, `scp`, `tar`, `curl` y `openssl`, que es todo lo que usan
los scripts. **Docker no hace falta** en el equipo: las imágenes se construyen
dentro de la instancia.

Usa `winget` y, si no está disponible o la política del equipo lo bloquea,
descarga el instalador oficial de Amazon, que pide permisos de administrador.
En un equipo institucional sin esos permisos, la instalación la tiene que hacer
quien administre el equipo.

Al terminar, **cerrar la terminal y abrir Git Bash** (menú Inicio → "Git Bash")
para que tome el PATH nuevo. Todos los pasos siguientes se ejecutan en Git Bash.

---

## 1. Clonar los repositorios

```bash
git clone https://github.com/AndesStay-Duoc/infra.git AndesStay/infra
bash AndesStay/infra/deploy/scripts/clonar-repos.sh
```

Deja esta estructura, que es la que espera `crear-infra.sh`:

```
AndesStay/
├── infra/
├── frontend-andesstay/
├── ms-andesstay-bff/
├── ms-andesstay-reservations/
├── ms-andesstay-catalog/
├── ms-andesstay-report/
└── ms-andesstay-audit/
```

Variantes:

```bash
bash .../clonar-repos.sh --rama main   # otra rama en todos
bash .../clonar-repos.sh --pr          # la rama del PR abierto de cada repo
```

`--pr` sirve para probar cambios que todavía no se integraron a `develop`, y
necesita GitHub CLI (`gh`) autenticado. Si el repositorio ya está clonado, el
script lo actualiza, salvo que tenga cambios sin commitear.

---

## 2. Credenciales del laboratorio

Se repite **cada vez que se inicia el laboratorio**: las credenciales caducan a
las ~4 horas o al pulsar *End Lab*.

**Paso 1.** En el Learner Lab: *Start Lab*, esperar el círculo verde y pulsar
**AWS Details → AWS CLI → Show**. Aparecen tres líneas:

```
aws_access_key_id=ASIA...
aws_secret_access_key=...
aws_session_token=...
```

**Paso 2.** La primera vez, crear el archivo desde la plantilla:

```bash
cd AndesStay/infra/deploy
cp credenciales-aws.example credenciales-aws.txt
```

Abrirlo con cualquier editor y reemplazar las tres líneas de ejemplo por las del
laboratorio. En las sesiones siguientes basta con volver a pegar las tres
líneas: el archivo se sobrescribe, no se crea otro.

**Paso 3.** Cargarlas:

```bash
bash scripts/aws-session.sh
```

Lee `credenciales-aws.txt`, escribe el perfil `andesstay` en `~/.aws/credentials`
y verifica la sesión. Si el archivo todavía tiene los valores de la plantilla,
lo avisa y se detiene.

> **Las credenciales son personales.** Cada integrante abre su propio laboratorio
> y usa las suyas. Pertenecen a una cuenta AWS individual: los recursos que crea
> una persona no los ve la otra. `credenciales-aws.txt` está en `.gitignore`; no
> se pega en chats ni se comparte por ningún medio.

Para saber en cualquier momento si la sesión sigue viva:

```bash
bash scripts/check-aws-session.sh
```

---

## 3. Crear y desplegar

```bash
bash scripts/crear-infra.sh
```

Hace todo en orden y muestra cada paso:

| # | Qué crea o hace |
|---|---|
| 1 | Comprueba herramientas, repositorios y sesión |
| 2 | Genera las contraseñas de MySQL y el secreto del gateway, si no existen |
| 3 | Security Group `andesstay-app`: 22 y 443 desde la IP del equipo, 80 abierto |
| 4 | Par de claves en `~/.ssh/`, instancia `t3.medium` con Ubuntu 24.04 |
| 5 | Elastic IP asociada a la instancia |
| 6 | HTTP API `andesstay-web`, que sirve la SPA |
| 7 | HTTP API `andesstay-api` con el JWT Authorizer y 20 rutas protegidas |
| 8 | Aprovisiona la instancia: Docker, swap, cortafuegos |
| 9 | Sube el código local, instala las variables y construye las imágenes |
| 10 | Levanta los siete contenedores y espera que estén sanos |
| 11 | Pruebas de humo contra las URL públicas |
| 12 | Imprime las URL y los Redirect URI para Entra ID |

La primera vez tarda **20 a 30 minutos**, casi todo compilando los cinco
servicios Spring Boot dentro de la instancia. Las siguientes, bastante menos.

### Es idempotente

Cada recurso se busca antes de crearlo, así que el script **se puede volver a
ejecutar sin riesgo**. Si se corta a mitad de camino —lo más común: caduca la
sesión del laboratorio durante el build— basta recargar las credenciales y
lanzarlo otra vez. Retoma desde donde estaba y no duplica nada.

Esto también sirve para actualizar un despliegue existente después de cambiar
código: sube la versión nueva, recompila y reinicia.

### Opciones

```bash
bash scripts/crear-infra.sh --origen github            # la instancia clona develop en vez de subir el código local
bash scripts/crear-infra.sh --origen github --rama X   # otra rama
bash scripts/crear-infra.sh --sin-build                # reaplica configuración sin recompilar
bash scripts/crear-infra.sh --solo-infra               # solo recursos AWS, sin desplegar la aplicación
bash scripts/crear-infra.sh --tipo t3.large            # otro tamaño de instancia
```

Con `--origen local` (por defecto) se despliega exactamente lo que está en las
carpetas del equipo, incluidos cambios sin commitear. Con `--origen github` no
hace falta tener clonados los microservicios, solo `infra`.

---

## 4. Registrar los Redirect URI en Entra ID

Al terminar, `crear-infra.sh` imprime un recuadro como este:

```
Portal de Azure → App registrations → 704a544f-3d92-44f5-aef9-8559574cff34
→ Authentication → plataforma "Single-page application" existente → Add URI

    https://abc123xyz.execute-api.us-east-1.amazonaws.com
    https://abc123xyz.execute-api.us-east-1.amazonaws.com/login
```

Hay que agregar **esas dos direcciones exactas**, sin barra final, en la App
Registration **existente**. No se crea ninguna aplicación nueva: el sistema usa
una sola, con el tenant `055d11d1-8ae0-4221-a6f7-b50be0a623b4`.

**Sin este paso el login falla con `AADSTS50011`.**

Cada despliegue en una cuenta distinta tiene su propia dirección, así que si dos
integrantes despliegan cada uno en su laboratorio, se registran **las dos parejas
de URI**. Conviven sin problema. Hace falta permiso sobre la App Registration en
el portal de Azure; quien no lo tenga, le pasa las dos direcciones a quien sí.

El script no lo automatiza porque modificar la App Registration requiere permisos
de administración en el tenant de Entra ID, que no forman parte de la sesión de
AWS.

---

## 5. Verificar

Abrir en el navegador la URL de **Aplicación** que imprimió el script e iniciar
sesión con una cuenta del tenant.

| Comprobación | Resultado esperado |
|---|---|
| La página carga | Pantalla de login de AndesStay |
| Iniciar sesión | Vuelve al panel con el nombre del usuario |
| Recargar `/dashboard` | Sigue en el panel, sin error 404 |
| DevTools → Network → petición `me` | `200`, con cabecera `authorization: Bearer ...` |
| Usuario con rol `Admin` | Ve Reservas, Catálogo, Reportería y Auditoría |
| Cuenta nueva autorregistrada | Rol `Cliente`, solo ve Reservas |

Para entrar a la instancia:

```bash
ssh -i ~/.ssh/andesstay-key.pem ubuntu@<ip-que-imprimió-el-script>
cd /opt/andesstay
docker compose --env-file .env -f infra/deploy/compose.yml ps
docker compose --env-file .env -f infra/deploy/compose.yml logs -f bff
```

---

## 6. Pausar, retomar y eliminar

### Pausar al terminar una sesión de trabajo

```bash
bash scripts/destruir-infra.sh --detener
```

Detiene la instancia. **Conserva** la base de datos, la Elastic IP y los dos API,
así que las URL y los Redirect URI siguen valiendo. El laboratorio también detiene
las instancias por su cuenta al terminar la sesión.

### Retomar

```bash
bash scripts/aws-session.sh             # con las credenciales nuevas del laboratorio
bash scripts/crear-infra.sh --sin-build
```

### Eliminar todo

```bash
bash scripts/destruir-infra.sh
```

Pide escribir `destruir` para confirmar. Elimina los dos API, la Elastic IP, la
instancia **con su disco** —la base de datos se pierde—, el Security Group y el
par de claves. Es irreversible, y al volver a crear, el API web tendrá otra
dirección que habrá que registrar en Entra ID.

Las contraseñas de `secrets/andesstay.env` se conservan para el próximo
despliegue; solo se vacían las URL que dejaron de existir.

---

## Variables del despliegue

`crear-infra.sh` crea `AndesStay/secrets/andesstay.env` la primera vez, a partir
de `.env.example`, y completa lo que falte:

| Variable | Origen |
|---|---|
| `MYSQL_ROOT_PASSWORD`, `MYSQL_APP_PASSWORD` | Generadas al azar la primera vez |
| `GATEWAY_SECRET` | Generado al azar; lo comparten API Gateway y nginx |
| `AZURE_TENANT_ID`, `AZURE_CLIENT_ID` | Identificadores públicos de Entra ID |
| `PUBLIC_WEB_ORIGIN`, `PUBLIC_API_ORIGIN` | Las URL de los dos API creados |
| `EC2_PUBLIC_IP`, `EC2_SSH_KEY` | La instancia y su clave |

Los valores ya presentes no se tocan: una segunda ejecución no cambia las
contraseñas de una base de datos ya inicializada.

Si el equipo comparte la carpeta `AndesStay/secrets` por OneDrive, quien despliega
reutiliza esos valores. Si no, cada persona obtiene los suyos, y es correcto:
cada despliegue vive en una cuenta AWS distinta.

---

## Problemas frecuentes

| Síntoma | Causa | Solución |
|---|---|---|
| `aws: command not found` | Git Bash se abrió antes de instalar el CLI | Cerrar y abrir Git Bash; los scripts también buscan `C:\Program Files\Amazon\AWSCLIV2` |
| `Las credenciales del laboratorio caducaron` | Pasaron ~4 horas o se pulsó *End Lab* | Nuevo bloque en `credenciales-aws.txt` y `bash scripts/aws-session.sh`; luego relanzar el script |
| `todavía tiene los valores de la plantilla` | Las credenciales se pegaron en otro archivo, o no se guardó | Completar y guardar `credenciales-aws.txt` |
| `credenciales-aws.example contiene credenciales reales` | Se pegaron en la plantilla, que **sí se sube a git** a un repositorio público | `cp credenciales-aws.example credenciales-aws.txt` y `git checkout -- credenciales-aws.example`. No commitear nada antes |
| `No está .../ms-andesstay-...` | Faltan repositorios hermanos | `bash scripts/clonar-repos.sh`, o `--origen github` |
| `SSH no responde` | La IP del equipo cambió respecto de la autorizada | Volver a ejecutar `crear-infra.sh`: agrega la IP actual al Security Group |
| `se lanzó con el par de claves ... pero no está el .pem` | La instancia la creó otra persona u otro equipo | Pedir el `.pem`, o `destruir-infra.sh` y crear de nuevo |
| `AADSTS50011` al iniciar sesión | Redirect URI no registrado | Sección 4 |
| `401 ... does not have a valid audience` | Authorizer con una sola forma de audiencia | Volver a ejecutar `crear-infra.sh`, que declara las dos |
| La página carga pero dice que no se puede conectar | API Gateway todavía propaga las integraciones | Esperar un minuto y recargar |
| Un contenedor queda `unhealthy` | Falta de memoria o error de arranque | `docker compose ... logs <servicio>` dentro de la instancia |
| Falla el build de un servicio | Normalmente memoria en instancias pequeñas | Relanzar; con `--tipo t3.large` si persiste |

---

## Qué decide la arquitectura, en una línea cada cosa

- **Una sola instancia.** Kafka, Zookeeper y RabbitMQ no se despliegan: no caben
  junto al resto. `reservations` omite la publicación de eventos con
  `ANDESSTAY_EVENTS_ENABLED=false`, y `report` y `audit` sirven sus endpoints
  REST sin consumir de Kafka.
- **MySQL en contenedor**, que es lo que usan los `application.yml`.
- **El TLS lo da API Gateway.** Entra ID no acepta Redirect URI con IP, y API
  Gateway no integra contra certificados autofirmados; por eso la SPA se sirve a
  través de API Gateway y el tramo hacia la instancia va por HTTP.
- **El puerto 80 queda abierto** porque las integraciones de API Gateway salen
  desde IPs de AWS no acotables. Lo protege la cabecera `X-Gateway-Secret`: nginx
  responde `403` sin ella.
- **20 rutas, todas con authorizer.** 16 del contrato `/staff` y `/guest`, y 4
  `/api/{proxy+}` que consume la SPA, una por método: una ruta `ANY` captura el
  preflight de CORS y lo rompe.

El contrato completo de rutas está en `infra/docs/contracts/rutas-gateway.md` y
los identificadores de Entra ID en `infra/docs/idaas/tenants.md`.
