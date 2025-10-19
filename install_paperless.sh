#!/bin/bash
set -euo pipefail

# Test Änderung lokal
# ist jetzt öffentlich

# Funktion zur sicheren Passworteingabe mit Bestätigung
function prompt_for_password() {
 local password password_confirm

 # Falls PAPERLESS_PASSWORD eingegeben wird, zusätzliche Erklärung ausgeben
 if [[ "$1" == "PAPERLESS_PASSWORD" ]]; then
   echo -e "\n💡 Hinweis: Dieses Passwort wird für den Linux-Benutzer 'paperless' und den Samba-Server verwendet."
   echo -e "Es wird für den Zugriff auf freigegebene Samba-Ordner benötigt.\n"
 fi

 while true; do
   echo -e "\n🔒 Bitte geben Sie das Passwort für **$1** ein:"
   read -s password
   echo -e "\n🔒 Bitte bestätigen Sie das Passwort:"
   read -s password_confirm

   if [[ "$password" == "$password_confirm" ]]; then
     echo -e "\n✅ Passwort erfolgreich gesetzt für **$1**.\n"
     eval "$2='$password'"
     break
   else
     echo -e "\n❌ Die Passwörter stimmen nicht überein. Bitte erneut eingeben.\n"
   fi
 done
}

# Funktion zur Eingabe des Admin-Benutzernamens mit Standardwert
function prompt_for_admin_user() {
 echo -e "\n👤 Bitte geben Sie den **Admin-Benutzernamen** ein (Standard: paperless):"
 read admin_user_input
 ADMIN_USER="${admin_user_input:-paperless}"
 echo -e "\n✅ Admin-Benutzer wurde auf **'$ADMIN_USER'** gesetzt.\n"
}

# Passwörter abfragen
prompt_for_password "PAPERLESS_PASSWORD" PAPERLESS_PASSWORD
prompt_for_admin_user
prompt_for_password "ADMIN_PASSWORD" ADMIN_PASSWORD

# Weitere Konfigurationen
SAMBA_PASSWORD="$PAPERLESS_PASSWORD"
DB_PASSWORD="paperless"

# System aktualisieren und benötigte Pakete installieren
update_and_install_dependencies() {
 echo "Aktualisiere Paketliste und installiere benötigte Pakete..."
 sudo apt update
 sudo apt install -y apt-transport-https curl jq gnupg openssh-server samba samba-common-bin
}

# Docker-Repository hinzufügen
add_docker_repo() {
 echo "Füge Docker GPG-Schlüssel und Repository hinzu..."
 sudo mkdir -p /etc/apt/keyrings
 if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
   curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
 fi

 . /etc/os-release
 DOCKER_REPO="deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $VERSION_CODENAME stable"
 echo "$DOCKER_REPO" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
 sudo apt update
}

# Paperless-Benutzer und Gruppe anlegen
ensure_paperless_user_and_group() {
 if ! getent group paperless &>/dev/null; then
   echo "Erstelle Gruppe 'paperless' mit GID 1002..."
   sudo groupadd -g 1002 paperless
 fi

 if ! id -u paperless &>/dev/null; then
   echo "Erstelle Benutzer 'paperless' mit UID 1002 und GID 1002..."
   sudo useradd -m -s /bin/bash -u 1002 -g paperless paperless
   echo "paperless:$PAPERLESS_PASSWORD" | sudo chpasswd
 fi
}

# Docker installieren
install_docker() {
 if ! command -v docker &>/dev/null; then
   echo "Docker wird installiert..."
   sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
   sudo systemctl enable --now docker
 fi

 if ! groups paperless | grep -q "\bdocker\b"; then
   echo "Füge Benutzer 'paperless' zur Docker-Gruppe hinzu..."
   sudo usermod -aG docker paperless
 fi
}

# Installation Portainer
install_portainer() {
  if [ ! "$(sudo docker ps -q -f name=portainer)" ]; then   
    echo "Portainer wird installiert..."
    docker volume create portainer_data
    docker run -d \
    -p 8000:8000 \
    -p 9443:9443 \
    --name=portainer \
    --restart=always \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v portainer_data:/data \
    portainer/portainer-ce:latest

  fi
}

# Samba Konfiguration
configure_samba() {
  # Backup der Original-Samba-Konfiguration
  sudo cp /etc/samba/smb.conf /etc/samba/smb.conf.bak
  sudo mkdir -p /data/paperless/{backup,restore}
  sudo chown -R paperless:paperless /data/paperless/
  sudo chmod -R 770 /data/paperless/

  # Für den Share [consume] soll nur der Ordner /data/paperless/consume freigegeben werden:
  if ! grep -q "^\[consume\]" /etc/samba/smb.conf; then
    sudo tee -a /etc/samba/smb.conf > /dev/null <<'EOF'

[consume]
   comment = Paperless Daten
   path = /data/paperless/consume
   browsable = yes
   writable = yes
   guest ok = no
   create mask = 0770
   directory mask = 0770
   valid users = paperless
EOF
  fi

  # Share für Backup
  if ! grep -q "^\[backup\]" /etc/samba/smb.conf; then
    sudo tee -a /etc/samba/smb.conf > /dev/null <<'EOF'

[backup]
   comment = Paperless Backup Daten
   path = /data/paperless/backup
   browsable = yes
   writable = yes
   guest ok = no
   create mask = 0770
   directory mask = 0770
   valid users = paperless
EOF
  fi

  # Share für Restore
  if ! grep -q "^\[restore\]" /etc/samba/smb.conf; then
    sudo tee -a /etc/samba/smb.conf > /dev/null <<'EOF'

[restore]
   comment = Paperless Restore Daten
   path = /data/paperless/restore
   browsable = yes
   writable = yes
   guest ok = no
   create mask = 0770
   directory mask = 0770
   valid users = paperless
EOF
  fi

  sudo systemctl restart smbd
  echo "Samba Shares [consume], [backup] und [restore] wurden konfiguriert."

 (echo "$SAMBA_PASSWORD"; echo "$SAMBA_PASSWORD") | sudo smbpasswd -a paperless -s
 sudo systemctl restart smbd
}


# Docker-Compose-Datei erstellen
deploy_containers() {
 echo "Erstelle docker-compose.yml im Verzeichnis von 'paperless'..."
 sudo mkdir -p /home/paperless

 cat <<EOL | sudo tee /home/paperless/docker-compose.yml > /dev/null
services:
 broker:
   image: redis:7
   container_name: paperless-redis-broker
   restart: unless-stopped
   volumes:
     - /data/paperless/redis/_data:/data

 db:
   image: postgres:16
   container_name: paperless-db
   restart: unless-stopped
   volumes:
     - /data/paperless/postgresql/_data:/var/lib/postgresql/data
   environment:
     POSTGRES_DB: paperless
     POSTGRES_USER: paperless
     POSTGRES_PASSWORD: $DB_PASSWORD

 paperless:
   image: ghcr.io/paperless-ngx/paperless-ngx:latest
   container_name: paperless-webserver
   restart: unless-stopped
   depends_on:
     - db
     - broker
     - gotenberg
     - tika
   ports:
     - "8001:8000"
   volumes:
     - /data/paperless/consume:/usr/src/paperless/consume
     - /data/paperless/data:/usr/src/paperless/data
     - /data/paperless/media:/usr/src/paperless/media
     - /data/paperless/export:/usr/src/paperless/export
   environment:
     PAPERLESS_ADMIN_USER: $ADMIN_USER
     PAPERLESS_ADMIN_PASSWORD: $ADMIN_PASSWORD
     PAPERLESS_REDIS: redis://broker:6379
     PAPERLESS_DBHOST: db
     PAPERLESS_TIKA_ENABLED: 1
     PAPERLESS_TIKA_GOTENBERG_ENDPOINT: http://gotenberg:3000
     PAPERLESS_TIKA_ENDPOINT: http://tika:9998
     PAPERLESS_OCR_LANGUAGE: deu
     PAPERLESS_TIME_ZONE: Europe/Berlin
     PAPERLESS_CONSUMER_ENABLE_BARCODES: "true"
     PAPERLESS_CONSUMER_ENABLE_ASN_BARCODE: "true"
     PAPERLESS_CONSUMER_BARCODE_SCANNER: ZXING
     PAPERLESS_EMAIL_TASK_CRON: '*/10 * * * *'
     USERMAP_UID: "1002"
     USERMAP_GID: "1002"

 gotenberg:
   image: gotenberg/gotenberg:8.8
   restart: unless-stopped
   command:
     - "gotenberg"
     - "--chromium-disable-javascript=false"
     - "--chromium-allow-list=.*"

 tika:
   image: ghcr.io/paperless-ngx/tika:latest
   container_name: tika
   restart: unless-stopped
EOL

 cd /home/paperless
 sudo docker compose up -d
}

# Hauptprogramm
update_and_install_dependencies
add_docker_repo
ensure_paperless_user_and_group
install_docker
configure_samba
deploy_containers

sleep 60
sudo chown -R paperless:paperless /data/paperless 

# Lokale IP-Adresse ermitteln
LOCAL_IP=$(hostname -I | awk '{print $1}')

echo -e "\n🚀 **Paperless ist jetzt bereit!**"
echo -e "🔗 **Zugriff im Browser:** http://$LOCAL_IP:8001\n"
echo -e "🔗 ** Bitte einmal neu booten"