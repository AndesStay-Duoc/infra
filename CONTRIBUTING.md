# Guía de contribución — AndesStay

Este documento es común a los 8 repositorios de la organización
[AndesStay-Duoc](https://github.com/AndesStay-Duoc).

## Ramas

| Rama | Uso |
|---|---|
| `main` | Solo el README. **Protegida: no se toca.** |
| `develop` | Rama de integración y despliegues. Es la rama por defecto. |
| `feature/<servicio>-<descripcion>` | Trabajo nuevo. Sale de `develop`. |
| `fix/<servicio>-<descripcion>` | Corrección de un defecto. Sale de `develop`. |

Ejemplos: `feature/reservations-maquina-estados`, `fix/notify-ack-duplicado`.

```bash
git checkout develop
git pull
git checkout -b feature/bff-validar-audience
```

## Commits

Se usa [Conventional Commits](https://www.conventionalcommits.org/), en español y en
imperativo:

```
<tipo>(<scope>): <descripción>
```

| Tipo | Cuándo |
|---|---|
| `feat` | Funcionalidad nueva |
| `fix` | Corrección de un defecto |
| `docs` | Solo documentación |
| `refactor` | Cambio interno sin alterar el comportamiento |
| `test` | Agregar o corregir pruebas |
| `chore` | Tareas de mantenimiento, configuración, dependencias |
| `ci` | Integración continua |
| `build` | Sistema de construcción o dependencias de empaquetado |

El `scope` es el servicio o módulo afectado: `reservations`, `catalog`, `bff`, `frontend`,
`notify`, `audit`, `report`, `infra`.

Ejemplos:

```
feat(reservations): agregar endpoint PUT /status con validacion de transicion
fix(bff): validar el audience ademas del issuer en el resource server
docs(infra): documentar la topologia de colas y DLQ
```

Se escribe **una línea de asunto de 72 caracteres o menos**, sin punto final. Si hace falta más
contexto, va en el cuerpo tras una línea en blanco.

## Pull Requests

- Siempre desde `feature/*` o `fix/*` hacia **`develop`**. Nunca hacia `main`.
- **Mínimo un revisor.** El PR se mergea con **squash**, para mantener el historial legible.
- La descripción usa la plantilla del repositorio e indica qué casilla del `CHECKLIST.md` cierra.
- Antes de pedir revisión: el proyecto compila y los tests pasan localmente.

## Qué nunca se versiona

La EP1 evalúa explícitamente que solo se suba lo que corresponde a cada tecnología.

- `node_modules/`, `dist/`, `.angular/` en el frontend.
- `target/` y artefactos compilados en los microservicios.
- Archivos `.env`, claves `.pem` y cualquier credencial. Se versiona un `.env.example` con los
  nombres de las variables y valores de ejemplo, nunca los reales.
- Volúmenes y datos de contenedores.

Los `clientId`, `tenantId` y contraseñas se configuran por variables de entorno. Si un secreto
llega a subirse, hay que rotarlo: borrar el commit no basta.

## Convenciones de código

- **Java 21 / Spring Boot 3.5.** Paquetes en `cl.andesstay.<servicio>`, con separación
  `domain` / `application` / `infrastructure`.
- **Angular 20.** Estructura `core/` (auth, interceptors, guards), `features/`, `shared/`.
- Los contratos de API, eventos y rutas del gateway son canónicos y viven en el repositorio
  `infra`, bajo `docs/contracts/`. Si un cambio los afecta, se actualizan **en el mismo PR**.

## Cómo levantar el entorno local

### Requisitos

| Herramienta | Versión |
|---|---|
| JDK | 21 |
| Maven | 3.9+ |
| Node.js | 20+ |
| Angular CLI | 20 |
| Docker Compose | v2 (`docker compose`, sin guion) |

### Configuración

Cada repositorio trae un `.env.example`. Se copia como `.env` y se completan los valores
siguiendo [`docs/guias/azure-identidad.md`](https://github.com/AndesStay-Duoc/infra/blob/develop/docs/guias/azure-identidad.md)
del repositorio `infra`. El `.env` nunca se versiona.

```bash
cp .env.example .env
```

Ningún identificador de tenant, `clientId` ni contraseña vive en un archivo versionado: todo
llega por variable de entorno, con el `.env.example` como única referencia de los nombres.

### Puertos por servicio

Son los valores por defecto que declara cada `application.yml`. Si se cambia uno, se actualiza
esta tabla y el `.env.example` del servicio en el mismo PR.

| Servicio | Puerto |
|---|---|
| `ms-andesstay-bff` | 8080 |
| `ms-andesstay-reservations` | 8081 |
| `ms-andesstay-catalog` | 8082 |
| `ms-andesstay-audit` | 8084 |
| `ms-andesstay-report` | 8085 |
| `ms-andesstay-notify` | sin puerto HTTP: es consumidor de RabbitMQ |
| `frontend-andesstay` | 4200 |

### Orden de arranque

La infraestructura va primero, desde el repositorio `infra`. Los servicios de dominio fallan al
iniciar si Oracle o la mensajería no están disponibles.

```bash
docker compose -f oracle/compose.yml up -d    # base de datos
docker compose -f mq/compose.yml up -d        # RabbitMQ
docker compose -f kafka/compose.yml up -d     # Kafka
```

### Microservicios (Spring Boot)

```bash
mvn clean verify                    # compila y ejecuta las pruebas
mvn spring-boot:run                 # levanta el servicio
SPRING_PROFILES_ACTIVE=dev mvn spring-boot:run    # con el perfil de desarrollo
```

`mvn clean verify` en verde es requisito para pedir revisión, no una recomendación.

### Frontend (Angular)

```bash
npm install
ng serve                                  # http://localhost:4200
ng test                                   # pruebas unitarias
ng build --configuration production       # build de producción
```

## Qué verificar antes de pedir revisión

Un cambio que toca un endpoint se prueba en los tres casos que exige el contrato de rutas del
gateway, no solo en el camino feliz:

| Caso | Esperado |
|---|---|
| Token válido con el rol correcto | `200` y el JSON del contrato |
| Sin cabecera `Authorization` | `401` |
| Token válido con rol insuficiente | `403` |

Un cuarto caso aplica cuando la ruta pertenece a `/staff/*` o `/guest/*`: un token emitido para
la otra audiencia debe dar `401`. Es la prueba de que la separación entre personal y huéspedes
funciona.

Los roles del sistema son **Admin**, **Recepcionista**, **Huésped** y **Auditor**. La matriz
completa de endpoint por rol está en el contrato de roles.

## Contratos que se revisan antes de escribir código

Son canónicos y viven en `infra`. Si un cambio los afecta, se actualizan **en el mismo PR**.

| Contrato | Para qué |
|---|---|
| [`estados.md`](https://github.com/AndesStay-Duoc/infra/blob/develop/docs/contracts/estados.md) | Transiciones válidas de una reserva y quién puede ejecutarlas |
| [`roles.md`](https://github.com/AndesStay-Duoc/infra/blob/develop/docs/contracts/roles.md) | Mapeo de claims a authorities y matriz endpoint × rol |
| [`rutas-gateway.md`](https://github.com/AndesStay-Duoc/infra/blob/develop/docs/contracts/rutas-gateway.md) | Rutas del API Gateway, authorizers y CORS |
| [`events/envelope.md`](https://github.com/AndesStay-Duoc/infra/blob/develop/docs/contracts/events/envelope.md) | Envelope común de todo mensaje y evento |
| [`events/kafka.md`](https://github.com/AndesStay-Duoc/infra/blob/develop/docs/contracts/events/kafka.md) | Tópicos y esquemas de eventos |
| [`events/rabbit.md`](https://github.com/AndesStay-Duoc/infra/blob/develop/docs/contracts/events/rabbit.md) | Exchanges, colas, DLQ y esquemas de mensajes |
| [`openapi/`](https://github.com/AndesStay-Duoc/infra/tree/develop/docs/contracts/openapi) | Contrato REST de cada servicio |

Ningún microservicio de dominio se expone directo al frontend. El camino es siempre
`JWT → API Gateway → BFF → servicio de dominio`.
