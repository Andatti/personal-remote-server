# Personal Remote Server

Servidor SSH para la app Android Personal Remote para Debian/Ubuntu y Arch/CachyOS con systemd y Python 3.9 o posterior. La app usa RSA y comprueba la huella del servidor. Puerto 2222, scripts en `~/.personalScripts` de la cuenta elegida.

## Instalar en otra PC desde GitHub

Entra por SSH a la nueva PC como root o con una cuenta que tenga sudo. Pega este bloque completo en la terminal (también funciona desde fish):

```sh
curl -fsSL https://github.com/Andatti/personal-remote-server/raw/main/get.sh | bash
```

Se requiere curl para descargar el instalador. El asistente instala las dependencias mediante apt o pacman, configura el servidor y activa las actualizaciones diarias por HTTPS. El repositorio es público y permite instalar y actualizar sin cuenta de GitHub.

Para elegir otra cuenta local al instalar:

```sh
curl -fsSL https://github.com/Andatti/personal-remote-server/raw/main/get.sh | bash -s -- --user NOMBRE
```

Al terminar, pega la clave pública RSA de tu app cuando la solicite. En Android agrega el servidor con su IP de VPN, puerto 2222 y la huella SHA256 que mostró el asistente. Guarda los scripts en la carpeta indicada durante la instalación. Al entrar como root, se usa `/root/.personalScripts`. Quien pueda escribir en esa carpeta controla scripts que el teléfono puede ejecutar como root. Al reinstalar se conserva la carpeta configurada por defecto.

## Publicar cambios

En el directorio de trabajo del servidor, confirma tus cambios y ejecuta `git push origin main`. También puedes guardar cambios en la rama main desde GitHub. El acceso de escritura al repositorio permite distribuir código que se ejecuta como root en los equipos suscritos.

El temporizador comprueba main una vez al día entre las 12:00 y las 12:15, hora local. Si el servidor estaba apagado, recupera la comprobación pendiente al encenderse. El actualizador exige continuidad del historial Git, valida el código Python, la sintaxis de Bash, la configuración SSH y las unidades systemd antes de sustituir archivos. Tras el despliegue comprueba el servicio y la clave RSA presentada por el puerto local. Si la aplicación o comprobación falla se restauran los archivos anteriores. Para retirar una actualización ya publicada, usa `git revert` y publica el nuevo commit. Una actualización de la unidad del servidor puede reiniciar sus sesiones.

El despliegue gestiona el ejecutor, la configuración de sshd, la herramienta de autorización, el actualizador y sus unidades. El asistente de instalación se usa al instalar una máquina. El código descargado y el estado de las actualizaciones quedan en `/var/lib/personal-remote-update`, accesible por root. Las instalaciones anteriores migran a HTTPS al ejecutar el actualizador nuevo. Las claves RSA de los equipos y los teléfonos autorizados se almacenan en cada servidor.

```sh
systemctl list-timers personal-remote-update.timer
sudo systemctl start personal-remote-update.service
journalctl -u personal-remote-update.service -n 40 --no-pager
sudo cat /var/lib/personal-remote-update/installed
sudo systemctl disable --now personal-remote-update.timer
```

El último comando desactiva las comprobaciones automáticas. Para volver a activarlas usa `sudo systemctl enable --now personal-remote-update.timer`.
