# Identificadores de los tenants

Plantilla a completar tras seguir [`../guias/azure-identidad.md`](../guias/azure-identidad.md).

**Nada de lo que va acá es secreto**: son identificadores públicos que terminan en la
configuración del frontend y en los authorizers del API Gateway. Las contraseñas de los usuarios
de prueba **no van en este archivo**, ni en ningún archivo versionado.

## Tenant corporativo — Microsoft Entra ID

| Dato | Valor | Verificado |
|---|---|---|
| Tenant ID | `cfe8706e-e5ae-44dd-8092-b4941bda8bd9` | ✅ el tenant existe |
| Tenant domain | `appdemo113.onmicrosoft.com` | ✅ apunta al mismo tenant |
| Client ID | `da4e2482-c0e7-41d8-a298-b45a59c8d6bc` | ✅ es una app real del tenant |
| Application ID URI | `api://da4e2482-c0e7-41d8-a298-b45a59c8d6bc` | ✅ API expuesta |
| Scope completo | `api://da4e2482-c0e7-41d8-a298-b45a59c8d6bc/access_as_staff` | ✅ aceptado en `/authorize` |
| Authority | `https://login.microsoftonline.com/cfe8706e-e5ae-44dd-8092-b4941bda8bd9` | ✅ |
| Issuer (`iss` del token) | `https://login.microsoftonline.com/cfe8706e-e5ae-44dd-8092-b4941bda8bd9/v2.0` | ✅ del documento de descubrimiento |
| JWKS | `https://login.microsoftonline.com/cfe8706e-e5ae-44dd-8092-b4941bda8bd9/discovery/v2.0/keys` | ✅ del documento de descubrimiento |
| Roles de aplicación | `Admin`, `Recepcionista`, `Auditor` | ❓ no verificable desde fuera |
| Plataforma del registro | Debe ser **SPA**, no Web | ❓ confirmar en el portal |

> **Verificación del scope, 2026-09-11.** `access_as_staff` es aceptado por `/authorize`,
> mientras que un scope inventado sobre el mismo Application ID URI devuelve `AADSTS65005`. El
> control negativo es lo que hace concluyente la prueba.

> El tenant se llama `appdemo113`, no parece creado para AndesStay. No es problema en sí, pero el
> indicador 3 de la EP2 pide un tenant con los roles y usuarios de prueba que el sistema
> necesita: hay que crear ahí los tres roles y un usuario por rol.

### Usuarios de prueba

| Usuario | Rol asignado |
|---|---|
| `<completar>` | `Admin` |
| `<completar>` | `Recepcionista` |
| `<completar>` | `Auditor` |

## Tenant de huéspedes — Microsoft Entra External ID

| Dato | Valor |
|---|---|
| Tenant ID | `<completar>` |
| Tenant domain | `<completar>.onmicrosoft.com` |
| Subdominio CIAM | `<completar>` |
| Client ID (`AndesStay-Guest`) | `<completar>` |
| Application ID URI | `api://<client-id>` |
| Scope completo | `api://<client-id>/access_as_guest` |
| Authority | `https://<subdominio>.ciamlogin.com/<tenant-id>` |
| Issuer (`iss` del token) | `https://<subdominio>.ciamlogin.com/<tenant-id>/v2.0` |
| JWKS | `https://<subdominio>.ciamlogin.com/<tenant-id>/discovery/v2.0/keys` |
| Rol de aplicación | `Huesped` |
| User flow | `AndesStay-SignUpSignIn` |
| Fecha de creación del tenant | `<completar>` |

> Anotar la fecha de creación: si el tenant se creó con la prueba gratuita de 30 días, hay que
> saber cuándo vence para no quedarse sin identidad el día de la presentación.

### Usuarios de prueba

| Usuario | Registrado por | Rol asignado |
|---|---|---|
| `<completar>` | User flow de auto-registro | `Huesped` |

## Redirect URIs registradas

Deben estar en **ambas** app registrations.

| Entorno | URI | Registrada |
|---|---|---|
| Desarrollo | `http://localhost:4200` | [ ] staff · [ ] guest |
| Producción | `<completar la URL publica del frontend>` | [ ] staff · [ ] guest |

## Verificación de los issuers

No escribir los issuers de memoria: leerlos del documento de descubrimiento, porque una barra
final de diferencia hace que todas las rutas respondan 401.

```bash
curl -s https://login.microsoftonline.com/<staff-tenant-id>/v2.0/.well-known/openid-configuration | python -c "import sys,json; print(json.load(sys.stdin)['issuer'])"
```

```bash
curl -s https://<subdominio>.ciamlogin.com/<guest-tenant-id>/v2.0/.well-known/openid-configuration | python -c "import sys,json; print(json.load(sys.stdin)['issuer'])"
```

El valor que devuelven es el que va en los authorizers del API Gateway y en la configuración del
BFF.

## Dónde se usa cada dato

| Dato | Frontend | BFF y servicios | API Gateway |
|---|---|---|---|
| Authority | ✔ configuración de MSAL | — | — |
| Client ID | ✔ configuración de MSAL | — | — |
| Scope completo | ✔ al pedir el token | — | — |
| Issuer | — | ✔ validación | ✔ authorizer |
| Audience (`api://<client-id>`) | — | ✔ validación | ✔ authorizer |
| Nombres de rol | ✔ guards por rol | ✔ authorities | — |
