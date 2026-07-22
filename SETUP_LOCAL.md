# Levantar Dolibarr en local (entorno de desarrollo)

Guía paso a paso para correr el proyecto en tu máquina usando Docker.

---

## Requisitos previos

- [Docker Desktop](https://www.docker.com/products/docker-desktop/) instalado y **corriendo**
- Git
- Puertos disponibles: **80**, **3306**, **8080**, **8081**, **25**

| Sistema operativo | Notas |
|---|---|
| macOS (Intel) | Sin requisitos adicionales |
| macOS (Apple Silicon M1/M2/M3) | Docker Desktop ≥ 4.x con soporte ARM64 |
| Windows 10/11 | WSL 2 habilitado + Docker Desktop con integración WSL 2 |

---

## 1. Clonar el repositorio

**macOS / Linux / WSL 2 (Windows):**
```bash
git clone --depth 1 <url-del-repo> dolibarr_modernization
cd dolibarr_modernization
```

**Windows (PowerShell o CMD):**
```powershell
git clone <url-del-repo> dolibarr_modernization
cd dolibarr_modernization
```

---

## 2. Preparar archivos necesarios

### 2a. Crear el directorio de documentos

Dolibarr guarda archivos subidos en una carpeta `documents/` fuera del webroot.

**macOS / Linux / WSL 2:**
```bash
mkdir -p documents
```

**Windows (PowerShell):**
```powershell
New-Item -ItemType Directory -Force -Path documents
```

### 2b. Crear el archivo de configuración vacío

El instalador web necesita poder escribir este archivo.

**macOS / Linux / WSL 2:**
```bash
touch htdocs/conf/conf.php
chmod 777 htdocs/conf/conf.php
```

**Windows (PowerShell):**
```powershell
New-Item -ItemType File -Force -Path htdocs\conf\conf.php
```
> En Windows los permisos los gestiona Docker internamente, no es necesario el `chmod`.

---

## 3. Exportar variables de entorno

El contenedor PHP necesita los IDs de tu usuario para sincronizar permisos de archivos entre el host y el contenedor.

**macOS / Linux / WSL 2:**
```bash
export HOST_USER_ID=$(id -u)
export HOST_GROUP_ID=$(id -g)
export PHP_INI_DATE_TIMEZONE=America/Mexico_City   # ajusta a tu zona horaria
export PHP_INI_MEMORY_LIMIT=256M
```

**Windows (PowerShell):**
```powershell
$env:HOST_USER_ID = 1000
$env:HOST_GROUP_ID = 1000
$env:PHP_INI_DATE_TIMEZONE = "America/Mexico_City"
$env:PHP_INI_MEMORY_LIMIT = "256M"
```

> En Windows no existe el comando `id -u`. Los valores `1000`/`1000` funcionan correctamente porque Docker Desktop en Windows maneja los permisos a través de su capa de virtualización.

> Estas variables deben estar definidas en la misma sesión de terminal donde ejecutes los comandos de Docker Compose.

---

## 4. Construir y levantar los contenedores

Entra al directorio del setup de desarrollo (desde la raíz del repositorio):

**macOS / Linux / WSL 2:**
```bash
cd dev/build/docker-dev
```

**Windows (PowerShell o CMD):**
```powershell
cd dev\build\docker-dev
```

Copia el archivo de variables de entorno para la integración con el
microservicio de Tickets (ver `htdocs/ticket/class/ticketsmicroserviceclient.class.php`):

```bash
cp .env.example .env
```

> Los valores por defecto funcionan para el setup local descrito en esta
> guía. Este `.env` está en `.gitignore` — no se sube al repositorio.

Construye las imágenes y levanta todos los servicios en segundo plano:

```bash
docker compose -f docker-compose.yml -f mariadb.yml up -d --build
```

> Este comando es igual en todos los sistemas operativos.

La primera vez descargará imágenes y compilará extensiones PHP — puede tardar **5-10 minutos** dependiendo de tu conexión.

### Servicios que se levantan

| Servicio     | URL                         | Descripción                        |
|--------------|-----------------------------|------------------------------------|
| Dolibarr     | http://localhost            | Aplicación principal               |
| PhpMyAdmin   | http://localhost:8080       | Gestor visual de la base de datos  |
| MailDev      | http://localhost:8081       | Bandeja de correos de prueba       |
| MariaDB      | localhost:3306              | Base de datos (acceso directo)     |

---

## 5. Verificar que todo está corriendo

```bash
docker compose -f docker-compose.yml -f mariadb.yml ps
```

Deberías ver los 4 contenedores con estado `Up`:

```
docker-dev-web-1         Up    0.0.0.0:80->80/tcp
docker-dev-mariadb-1     Up    0.0.0.0:3306->3306/tcp
docker-dev-phpmyadmin-1  Up    0.0.0.0:8080->80/tcp
docker-dev-mail-1        Up    0.0.0.0:8081->1080/tcp
```

---

## 6. Instalar Dolibarr (primera vez)

1. Abre http://localhost/install/ en tu navegador
2. Sigue el asistente de instalación con estos datos:
   - **Servidor de base de datos**: `mariadb`
   - **Puerto**: `3306`
   - **Nombre de BD**: `dolibarr`
   - **Usuario**: `root`
   - **Contraseña**: `rootpassfordev`
3. Completa la configuración y crea el usuario administrador
4. Al terminar, el directorio `htdocs/install/` puede dejarse tal cual en desarrollo

---

## 7. Flujo de desarrollo (cambios en código)

El código fuente en `htdocs/` está montado como volumen en el contenedor:

```yaml
volumes:
  - ../../../htdocs:/var/www/html/
```

Esto significa que **editas un archivo en tu editor → guardas → recargas el navegador** y el cambio ya está activo. No necesitas reiniciar ni reconstruir nada.

Lo único que requiere `--build` es si modificas el `Dockerfile` o el `docker-run.sh`.

---

## 8. Comandos útiles del día a día

```bash
# Ver logs del servidor web en tiempo real
docker logs -f docker-dev-web-1

# Reiniciar solo el contenedor web
docker compose -f docker-compose.yml -f mariadb.yml restart web

# Apagar todos los contenedores (los datos persisten)
docker compose -f docker-compose.yml -f mariadb.yml down

# Apagar y eliminar volúmenes (borra la base de datos)
docker compose -f docker-compose.yml -f mariadb.yml down -v

# Entrar al contenedor web
docker exec -it docker-dev-web-1 bash

# Entrar al contenedor de base de datos
docker exec -it docker-dev-mariadb-1 mariadb -u root -prootpassfordev dolibarr
```

---

## 9. Credenciales de referencia

| Servicio | Usuario | Contraseña      |
|----------|---------|-----------------|
| MariaDB  | root    | rootpassfordev  |

> Estas credenciales son **solo para desarrollo local**, no las uses en producción.

---

## Notas técnicas

- El contenedor web incluye **Xdebug 3** en modo debug, escuchando en el puerto `9003`. Configura tu IDE para conectarse a ese puerto.
- Los correos enviados por Dolibarr son interceptados por **MailDev** (no salen a internet). Vélos en http://localhost:8081.
- La imagen base es `php:8.2-apache-bookworm`, compatible con **AMD64 y ARM64** (Apple Silicon).

### Fixes aplicados al repo original

Estos cambios fueron necesarios para que el setup funcionara correctamente:

| Archivo | Problema | Solución |
|---|---|---|
| `docker-compose.yml` | Faltaba `HOST_GROUP_ID` en el `environment` del servicio `web` | Se agregó la variable |
| `Dockerfile` | Imagen `php:8.1-apache-bullseye` sin soporte ARM64, xdebug fallaba al compilar | Se actualizó a `php:8.2-apache-bookworm` |
| `docker-run.sh` | `groupmod` abortaba el arranque con `exit 1` cuando el GID ya existía en el contenedor | Se agregó `|| true` para ignorar ese error |

---

## Solución de problemas comunes

### El contenedor web no arranca

```bash
docker logs docker-dev-web-1
```

Causa más frecuente: las variables `HOST_USER_ID` o `HOST_GROUP_ID` no estaban definidas. Defínelas y vuelve a levantar:

**macOS / Linux / WSL 2:**
```bash
export HOST_USER_ID=$(id -u) HOST_GROUP_ID=$(id -g)
docker compose -f docker-compose.yml -f mariadb.yml up -d
```

**Windows (PowerShell):**
```powershell
$env:HOST_USER_ID = 1000; $env:HOST_GROUP_ID = 1000
docker compose -f docker-compose.yml -f mariadb.yml up -d
```

### Puerto 80 ocupado

Edita `docker-compose.yml` y cambia el mapeo del servicio `web`:

```yaml
ports:
  - "8082:80"   # accede por http://localhost:8082
```

### Docker no está corriendo

**macOS:**
```bash
open -a Docker
```

**Windows:** Abre Docker Desktop desde el menú de inicio. Espera a que el ícono de la ballena en la barra de tareas deje de animarse.

### Windows: líneas de fin de archivo (CRLF)

Si en Windows el script `docker-run.sh` falla con un error de `/bin/bash^M: bad interpreter`, es un problema de saltos de línea. Corrígelo con:

```bash
# Dentro de WSL 2 o Git Bash
sed -i 's/\r//' dev/build/docker-dev/docker-run.sh
```

O configura Git para no convertir saltos de línea automáticamente:

```bash
git config core.autocrlf false
git checkout dev/build/docker-dev/docker-run.sh
```
