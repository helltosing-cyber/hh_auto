#!/bin/bash

# Настройки контейнера Proxmox (измените при необходимости)
CT_ID=$(pvesh get /cluster/nextid) # Автоматически берет свободный ID
CT_NAME="humhub-portal"
STORAGE="local-lvm"                # Имя вашего хранилища для дисков LXC
BRIDGE="vmbr0"                     # Ваша сеть Proxmox
PASSWORD="SuperSecurePassword123!" # Пароль root для LXC и MySQL

echo "=== 1. Скачивание шаблона Debian 12 ==="
pveam update
pveam download local debian-12-standard_12.2-1_amd64.tar.zst || true

echo "=== 2. Создание LXC-контейнера №${CT_ID} с DHCP ==="
pct create $CT_ID local:vztmpl/debian-12-standard_12.2-1_amd64.tar.zst \
  -cores 2 -memory 4096 -swap 512 \
  -hostname $CT_NAME -storage $STORAGE -rootfs $STORAGE:8 \
  -net0 name=eth0,bridge=$BRIDGE,firewall=0,ip=dhcp \
  -password $PASSWORD -unprivileged 1 -start 1

echo "Ожидание загрузки контейнера и получения IP по DHCP..."
sleep 15

# Получаем назначенный по DHCP IP-адрес для вывода в конце
LXC_IP=$(pct exec $CT_ID -- hostname -I | awk '{print $1}')

echo "=== 3. Обновление системы внутри LXC ==="
pct exec $CT_ID -- apt update
pct exec $CT_ID -- apt upgrade -y

echo "=== 4. Установка Nginx, MariaDB и PHP 8.2 ==="
pct exec $CT_ID -- apt install -y nginx mariadb-server curl unzip \
  php8.2-fpm php8.2-mysql php8.2-cli php8.2-common php8.2-gd \
  php8.2-ldap php8.2-curl php8.2-mbstring php8.2-zip php8.2-intl php8.2-xml

echo "=== 5. Настройка базы данных MariaDB ==="
pct exec $CT_ID -- mysql -e "CREATE DATABASE humhub CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
pct exec $CT_ID -- mysql -e "CREATE USER 'humhub_user'@'localhost' IDENTIFIED BY '${PASSWORD}';"
pct exec $CT_ID -- mysql -e "GRANT ALL PRIVILEGES ON humhub.* TO 'humhub_user'@'localhost';"
pct exec $CT_ID -- mysql -e "FLUSH PRIVILEGES;"

echo "=== 6. Скачивание и распаковка HumHub ==="
pct exec $CT_ID -- mkdir -p /var/www/humhub
HUMHUB_VER=$(curl -s https://github.com | grep -oP '"tag_name": "\K[^"]*')
pct exec $CT_ID -- curl -L -o /tmp/humhub.tar.gz "https://download.humhub.com/downloads/install/humhub-1.13.0.tar.gz"
pct exec $CT_ID -- tar -xzf /tmp/humhub.tar.gz -C /var/www/humhub --strip-components=1

echo "=== 7. Настройка прав доступа ==="
pct exec $CT_ID -- chown -R www-data:www-data /var/www/humhub
pct exec $CT_ID -- chmod -R 755 /var/www/humhub

echo "=== 8. Оптимизация PHP (Лимиты на файлы 200M) ==="
pct exec $CT_ID -- sed -i 's/upload_max_filesize = .*/upload_max_filesize = 200M/' /etc/php/8.2/fpm/php.ini
pct exec $CT_ID -- sed -i 's/post_max_size = .*/post_max_size = 200M/' /etc/php/8.2/fpm/php.ini
pct exec $CT_ID -- systemctl restart php8.2-fpm

echo "=== 9. Создание конфигурации Nginx ==="
pct exec $CT_ID -- bash -c "cat << 'EOF' > /etc/nginx/sites-available/humhub
server {
    listen 80;
    server_name _;
    root /var/www/humhub;
    index index.html index.htm index.php;

    charset utf-8;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~* \.(?:favicon\.ico|png|jpg|jpeg|gif|svg|js|css|pdf|gz|zip|rar)\$ {
        expires 1M;
        access_log off;
        add_header Cache-Control \"public\";
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php8.2-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.(?!well-known).* {
        deny all;
    }
}
EOF"

pct exec $CT_ID -- ln -s /etc/nginx/sites-available/humhub /etc/nginx/sites-enabled/
pct exec $CT_ID -- rm -f /etc/nginx/sites-enabled/default
pct exec $CT_ID -- systemctl restart nginx

echo "=== 10. Настройка Cron-задач ==="
pct exec $CT_ID -- bash -c "(crontab -l 2>/dev/null; echo '* * * * * /usr/bin/php /var/www/humhub/protected/yii queue/run >/dev/null 2>&1') | crontab -"
pct exec $CT_ID -- bash -c "(crontab -l 2>/dev/null; echo '* * * * * /usr/bin/php /var/www/humhub/protected/yii cron/run >/dev/null 2>&1') | crontab -"

echo "========================================================"
echo " Установка завершена успешно!"
echo " Адрес вашего портала: http://${LXC_IP}"
echo "========================================================"
echo "Данные для веб-установщика (Шаг базы данных):"
echo " Database Host: localhost"
echo " Database Name: humhub"
echo " Database User: humhub_user"
echo " Database Pass: $PASSWORD"
echo "========================================================"
