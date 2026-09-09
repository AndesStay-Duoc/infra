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
