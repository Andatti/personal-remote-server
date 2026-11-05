# Personal Remote Server

Servidor SSH para la app Android Personal Remote en CachyOS/Arch con systemd. La app usa RSA y comprueba la huella del servidor. Puerto 2222, scripts en `/home/maetti/.personalScripts`.

## Instalación

En el PC original ejecuta `bash setup.sh` como tu usuario desde este directorio. El asistente pide sudo para instalar las dependencias que falten y configurar systemd. Autoriza GitHub mediante la CLI oficial, que muestra la URL y el código para el navegador. El asistente crea el repositorio privado `personal-remote-server` en tu cuenta, publica el código del servidor y registra una clave de despliegue de lectura para este PC. Si el nombre ya está ocupado, el asistente se detiene antes de adoptar el repositorio existente.

Para otro equipo con el usuario local `maetti`, copia solamente `setup.sh` y ejecuta `bash setup.sh PROPIETARIO/personal-remote-server`. La cuenta de GitHub utilizada en la instalación necesita permiso para registrar la clave de despliegue. En una instalación nueva, copia la huella mostrada a la app y pega su clave pública al final del asistente. En una actualización se conservan las claves SSH, los teléfonos autorizados y los scripts.

## Publicar cambios

En el directorio de trabajo del servidor, confirma tus cambios y ejecuta `git push origin main`. También puedes guardar cambios en la rama main desde GitHub. El acceso de escritura al repositorio permite distribuir código que se ejecuta como root en los equipos suscritos.

El temporizador comprueba main una vez al día entre las 12:00 y las 12:15, hora local. Si el servidor estaba apagado, recupera la comprobación pendiente al encenderse. El actualizador exige continuidad del historial Git, valida el código Python, la sintaxis de Bash, la configuración SSH y las unidades systemd antes de sustituir archivos. Tras el despliegue comprueba el servicio y la clave RSA presentada por el puerto local. Si la aplicación o comprobación falla se restauran los archivos anteriores. Para retirar una actualización ya publicada, usa `git revert` y publica el nuevo commit. Una actualización de la unidad del servidor puede reiniciar sus sesiones.

El despliegue gestiona el ejecutor, la configuración de sshd, la herramienta de autorización, el actualizador y sus unidades. El asistente de instalación se usa al instalar una máquina. La clave de lectura de cada equipo queda en `/var/lib/personal-remote-update`, accesible por root. El demonio usa esa clave para GitHub.

```sh
systemctl list-timers personal-remote-update.timer
sudo systemctl start personal-remote-update.service
journalctl -u personal-remote-update.service -n 40 --no-pager
sudo cat /var/lib/personal-remote-update/installed
sudo systemctl disable --now personal-remote-update.timer
```

El último comando desactiva las comprobaciones automáticas. Para volver a activarlas usa `sudo systemctl enable --now personal-remote-update.timer`.
