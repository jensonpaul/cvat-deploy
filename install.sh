# Prepare OS
sudo apt-get update -y
sudo apt-get upgrade -y

# Install Docker & Docker Compose
sudo apt-get --no-install-recommends install -y \
  apt-transport-https \
  ca-certificates \
  curl \
  gnupg-agent \
  software-properties-common
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
sudo add-apt-repository \
  "deb [arch=amd64] https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) \
  stable"
sudo apt-get update -y
sudo apt-get --no-install-recommends install -y docker-ce docker-ce-cli containerd.io
sudo apt-get --no-install-recommends install -y python3-pip python3-setuptools
sudo python3 -m pip install setuptools docker-compose

# Install Portainer for Docker Management (Optional)
docker volume create portainer_data
docker run -d -p 8000:8000 -p 9000:9000 \
    --name=portainer \
    --restart=always \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v portainer_data:/data portainer/portainer-ce

# Install CVAT
sudo apt-get --no-install-recommends install -y git
git clone https://github.com/opencv/cvat /root/cvat

# Create S3 bucket

# Create mount point
sudo mkdir /mnt/s3-cvat-default-volume

# Install S3FS & setup auto-mount
sudo apt install s3fs

sed -i "s/#user_allow_other/user_allow_other/g" /etc/fuse.conf

echo ACCESS_KEY_ID:SECRET_ACCESS_KEY > /etc/passwd-s3fs
chmod 640 /etc/passwd-s3fs

cat > /etc/systemd/system/s3fs.service << 'EOF'
[Unit]
Description=FUSE filesystem over AWS S3 bucket
After=network.target

[Service]
Environment="MOUNT_POINT=/mnt/s3-cvat-default-volume"
User=root
Group=root
ExecStart=s3fs cvat-default-volume ${MOUNT_POINT} -o passwd_file=/etc/passwd-s3fs -o allow_other -o umask=0022 -o endpoint='us-west-1'
ExecStop=fusermount -u ${MOUNT_POINT}
Restart=always
Type=forking

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable s3fs.service
sudo systemctl start s3fs.service

# Create RDS PostgreSQL

# Remove PostgresSQL image, Add DB details (AWS RDS), Change volumes to S3
cat > /root/cvat/docker-compose.yml << 'EOF'
version: '3.3'
services:
  cvat_redis:
    container_name: cvat_redis
    image: redis:4.0-alpine
    networks:
      default:
        aliases:
          - redis
    restart: always

  cvat:
    container_name: cvat
    image: cvat/server
    restart: always
    depends_on:
      - cvat_redis
    build:
      context: .
      args:
        http_proxy:
        https_proxy:
        no_proxy: nuclio,${no_proxy}
        socks_proxy:
        USER: 'django'
        DJANGO_CONFIGURATION: 'production'
        TZ: 'Etc/UTC'
        CLAM_AV: 'no'
    environment:
      DJANGO_MODWSGI_EXTRA_ARGS: ''
      ALLOWED_HOSTS: '*'
      CVAT_REDIS_HOST: 'cvat_redis'
      CVAT_POSTGRES_HOST: 'cvat-database.dbid.region.rds.amazonaws.com'
      CVAT_POSTGRES_DBNAME: 'db_name'
      CVAT_POSTGRES_USER: 'db_username'
      CVAT_POSTGRES_PASSWORD: 'db_password'
    volumes:
      - cvat_data:/home/django/data
      - cvat_keys:/home/django/keys
      - cvat_logs:/home/django/logs
      - cvat_models:/home/django/models

  cvat_ui:
    container_name: cvat_ui
    image: cvat/ui
    restart: always
    build:
      context: .
      args:
        http_proxy:
        https_proxy:
        no_proxy:
        socks_proxy:
      dockerfile: Dockerfile.ui

    networks:
      default:
        aliases:
          - ui
    depends_on:
      - cvat

  cvat_proxy:
    container_name: cvat_proxy
    image: nginx:stable-alpine
    restart: always
    depends_on:
      - cvat
      - cvat_ui
    environment:
      CVAT_HOST: localhost
    ports:
      - '8080:80'
    volumes:
      - ./cvat_proxy/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./cvat_proxy/conf.d/cvat.conf.template:/etc/nginx/conf.d/cvat.conf.template:ro
    command: /bin/sh -c "envsubst '$$CVAT_HOST' < /etc/nginx/conf.d/cvat.conf.template > /etc/nginx/conf.d/default.conf && nginx -g 'daemon off;'"

networks:
  default:
    ipam:
      driver: default
      config:
        - subnet: 172.28.0.0/24

volumes:
  cvat_data:
    driver_opts:
      type: none
      device: /mnt/s3-cvat-default-volume/data
      o: bind
  cvat_keys:
    driver_opts:
      type: none
      device: /mnt/s3-cvat-default-volume/keys
      o: bind
  cvat_logs:
    driver_opts:
      type: none
      device: /mnt/s3-cvat-default-volume/logs
      o: bind
  cvat_models:
    driver_opts:
      type: none
      device: /mnt/s3-cvat-default-volume/models
      o: bind
EOF

cat > /root/cvat/components/analytics/docker-compose.analytics.yml << 'EOF'
version: '3.3'
services:
  cvat_elasticsearch:
    container_name: cvat_elasticsearch
    image: cvat_elasticsearch
    networks:
      default:
        aliases:
          - elasticsearch
    build:
      context: ./components/analytics/elasticsearch
      args:
        ELK_VERSION: 6.4.0
    volumes:
      - cvat_events:/usr/share/elasticsearch/data
    restart: always

  cvat_kibana:
    container_name: cvat_kibana
    image: cvat_kibana
    networks:
      default:
        aliases:
          - kibana
    build:
      context: ./components/analytics/kibana
      args:
        ELK_VERSION: 6.4.0
    depends_on: ['cvat_elasticsearch']
    restart: always

  cvat_kibana_setup:
    container_name: cvat_kibana_setup
    image: cvat/server
    volumes: ['./components/analytics/kibana:/home/django/kibana:ro']
    depends_on: ['cvat']
    working_dir: '/home/django'
    entrypoint:
      [
        'bash',
        'wait-for-it.sh',
        'elasticsearch:9200',
        '-t',
        '0',
        '--',
        '/bin/bash',
        'wait-for-it.sh',
        'kibana:5601',
        '-t',
        '0',
        '--',
        'python3',
        'kibana/setup.py',
        'kibana/export.json',
      ]
    environment:
      no_proxy: elasticsearch,kibana,${no_proxy}

  cvat_logstash:
    container_name: cvat_logstash
    image: cvat_logstash
    networks:
      default:
        aliases:
          - logstash
    build:
      context: ./components/analytics/logstash
      args:
        ELK_VERSION: 6.4.0
        http_proxy: ${http_proxy}
        https_proxy: ${https_proxy}
    depends_on: ['cvat_elasticsearch']
    restart: always

  cvat:
    environment:
      DJANGO_LOG_SERVER_HOST: logstash
      DJANGO_LOG_SERVER_PORT: 5000
      DJANGO_LOG_VIEWER_HOST: kibana
      DJANGO_LOG_VIEWER_PORT: 5601
      CVAT_ANALYTICS: 1
      no_proxy: kibana,logstash,nuclio,${no_proxy}

volumes:
  cvat_events:
    driver_opts:
      type: none
      device: /mnt/s3-cvat-default-volume/events
      o: bind
EOF

# Upgrade Nuclio to latest 1.5.14
cat > /root/cvat/components/serverless/docker-compose.serverless.yml << 'EOF'
version: '3.3'
services:
  serverless:
    container_name: nuclio
    image: quay.io/nuclio/dashboard:1.5.14-amd64
    restart: always
    networks:
      default:
        aliases:
          - nuclio
    volumes:
      - /tmp:/tmp
      - /var/run/docker.sock:/var/run/docker.sock
    environment:
      http_proxy:
      https_proxy:
      no_proxy: 172.28.0.1,${no_proxy}
      NUCLIO_CHECK_FUNCTION_CONTAINERS_HEALTHINESS: 'true'
    ports:
      - '8070:8070'

  cvat:
    environment:
      CVAT_SERVERLESS: 1
      no_proxy: kibana,logstash,nuclio,${no_proxy}

volumes:
  cvat_events:
    driver_opts:
      type: none
      device: /mnt/s3-cvat-default-volume/events
      o: bind
EOF

# Add Host, Port, S3 file share, SSL dirs
cat > /root/cvat/docker-compose.override.yml << 'EOF'
version: '3.3'
services:
  cvat_proxy:
    environment:
      CVAT_HOST: .example.com
    ports:
      - '80:80'
      - '443:443'
    volumes:
      - ./letsencrypt-webroot:/var/tmp/letsencrypt-webroot
      - /mnt/s3-cvat-default-volume/ssl:/root/ssl/
  cvat:
    environment:
      ALLOWED_HOSTS: '*'
      CVAT_SHARE_URL: 'AWS S3 Bucket'
    volumes:
      - cvat_share:/home/django/share:ro

volumes:
  cvat_share:
    driver_opts:
      type: none
      device: /mnt/s3-cvat-default-volume/share
      o: bind
EOF

# Email verification
sed -i "/ACCOUNT_EMAIL_VERIFICATION = 'none'/c \
    ACCOUNT_AUTHENTICATION_METHOD = 'username'\n \
    ACCOUNT_CONFIRM_EMAIL_ON_GET = True\n \
    ACCOUNT_EMAIL_REQUIRED = True\n \
    ACCOUNT_EMAIL_VERIFICATION = 'mandatory'\n \
    # Email backend settings for Django\n \
    EMAIL_BACKEND = 'django.core.mail.backends.smtp.EmailBackend'\n \
    EMAIL_HOST = 'localhost'\n \
    EMAIL_PORT = 25\n \
    EMAIL_HOST_USER = 'username'\n \
    EMAIL_HOST_PASSWORD = 'password'\n \
    EMAIL_USE_TLS = True\n \
    DEFAULT_FROM_EMAIL = 'webmaster@localhost'" /root/cvat/cvat/settings/base.py

# Serving over HTTPS
sudo apt install socat
sudo mkdir -p /root/cvat/letsencrypt-webroot/.well-known/acme-challenge

git clone https://github.com/Neilpang/acme.sh.git
cd acme.sh
./acme.sh --install  \
--cert-home  /mnt/s3-cvat-default-volume/ssl

# Add https to Nginx
cat > /root/cvat/cvat_proxy/conf.d/cvat.conf.template << 'EOF'
server {
    listen       80;
    server_name  _ default;
    return       404;
}

server {
    listen       80;
    server_name  ${CVAT_HOST};

    location ^~ /.well-known/acme-challenge/ {
      default_type "text/plain";
      root /var/tmp/letsencrypt;
    }

    location / {
      return 301 https://$server_name$request_uri;
    }
}

server {
    listen 443 ssl;
    ssl_certificate /root/ssl/example.com/example.com.cer;
    ssl_certificate_key /root/ssl/example.com/example.com.key;
    ssl_trusted_certificate /root/ssl/example.com/fullchain.cer;

    # security options
    ssl_protocols TLSv1 TLSv1.1 TLSv1.2;
    ssl_prefer_server_ciphers on;
    ssl_stapling on;
    ssl_session_timeout 24h;
    ssl_session_cache shared:SSL:2m;
    ssl_ciphers 'ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-AES256-GCM-SHA384:DHE-RSA-AES128-GCM-SHA256:DHE-DSS-AES128-GCM-SHA256:kEDH+AESGCM:ECDHE-RSA-AES128-SHA256:ECDHE-ECDSA-AES128-SHA256:ECDHE-RSA-AES128-SHA:ECDHE-ECDSA-AES128-SHA:ECDHE-RSA-AES256-SHA384:ECDHE-ECDSA-AES256-SHA384:ECDHE-RSA-AES256-SHA:ECDHE-ECDSA-AES256-SHA:DHE-RSA-AES128-SHA256:DHE-RSA-AES128-SHA:DHE-DSS-AES128-SHA256:DHE-RSA-AES256-SHA256:DHE-DSS-AES256-SHA:DHE-RSA-AES256-SHA:AES128-GCM-SHA256:AES256-GCM-SHA384:AES128-SHA256:AES256-SHA256:AES128-SHA:AES256-SHA:AES:CAMELLIA:DES-CBC3-SHA:!aNULL:!eNULL:!EXPORT:!DES:!RC4:!MD5:!PSK:!aECDH:!EDH-DSS-DES-CBC3-SHA:!EDH-RSA-DES-CBC3-SHA:!KRB5-DES-CBC3-SHA:!3DES';

    # security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "no-referrer-when-downgrade" always;
    add_header Content-Security-Policy "default-src 'self' http: https: data: blob: 'unsafe-inline'" always;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;

    server_name  ${CVAT_HOST};

    proxy_pass_header       X-CSRFToken;
    proxy_set_header        Host $http_host;
    proxy_pass_header       Set-Cookie;

    location ~* /api/.*|git/.*|analytics/.*|static/.*|admin(?:/(.*))?.*|documentation/.*|django-rq(?:/(.*))? {
        proxy_pass              http://cvat:8080;
    }

    location / {
        proxy_pass              http://cvat_ui;
    }
}
EOF

# Build docker images
docker-compose -f /root/cvat/docker-compose.yml \
    -f /root/cvat/docker-compose.override.yml \
    -f /root/cvat/components/analytics/docker-compose.analytics.yml \
    -f /root/cvat/components/serverless/docker-compose.serverless.yml \
    build

# Run docker containers
docker-compose -f /root/cvat/docker-compose.yml \
    -f /root/cvat/docker-compose.override.yml \
    -f /root/cvat/components/analytics/docker-compose.analytics.yml \
    -f /root/cvat/components/serverless/docker-compose.serverless.yml \
    up -d

# Removing tensorflow functions
cat > /root/cvat/serverless/deploy_cpu.sh << 'EOF'
#!/bin/bash

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

nuctl create project cvat
nuctl deploy --project-name cvat \
    --path "$SCRIPT_DIR/openvino/omz/public/faster_rcnn_inception_v2_coco/nuclio" \
    --volume "$SCRIPT_DIR/openvino/common:/opt/nuclio/common" \
    --platform local

nuctl deploy --project-name cvat \
    --path "$SCRIPT_DIR/openvino/omz/public/mask_rcnn_inception_resnet_v2_atrous_coco/nuclio" \
    --volume "$SCRIPT_DIR/openvino/common:/opt/nuclio/common" \
    --platform local

nuctl deploy --project-name cvat \
    --path "$SCRIPT_DIR/openvino/omz/public/yolo-v3-tf/nuclio" \
    --volume "$SCRIPT_DIR/openvino/common:/opt/nuclio/common" \
    --platform local

nuctl deploy --project-name cvat \
    --path "$SCRIPT_DIR/openvino/omz/intel/text-detection-0004/nuclio" \
    --volume "$SCRIPT_DIR/openvino/common:/opt/nuclio/common" \
    --platform local

nuctl deploy --project-name cvat \
    --path "$SCRIPT_DIR/openvino/omz/intel/semantic-segmentation-adas-0001/nuclio" \
    --volume "$SCRIPT_DIR/openvino/common:/opt/nuclio/common" \
    --platform local

nuctl deploy --project-name cvat \
    --path "$SCRIPT_DIR/openvino/omz/intel/person-reidentification-retail-300/nuclio" \
    --volume "$SCRIPT_DIR/openvino/common:/opt/nuclio/common" \
    --platform local

nuctl deploy --project-name cvat \
    --path "$SCRIPT_DIR/openvino/dextr/nuclio" \
    --volume "$SCRIPT_DIR/openvino/common:/opt/nuclio/common" \
    --platform local

nuctl deploy --project-name cvat \
    --path "$SCRIPT_DIR/pytorch/foolwood/siammask/nuclio" \
    --platform local

nuctl deploy --project-name cvat \
    --path "$SCRIPT_DIR/pytorch/saic-vul/fbrs/nuclio" \
    --platform local

nuctl get function
EOF

# Install Nuclio
wget https://github.com/nuclio/nuclio/releases/download/1.5.14/nuctl-1.5.14-linux-amd64 -O /root/cvat/nuctl-1.5.14-linux-amd64
sudo chmod +x /root/cvat/nuctl-1.5.14-linux-amd64
sudo ln -sf /root/cvat/nuctl-1.5.14-linux-amd64 /usr/local/bin/nuctl

# Setup Nuclio functions reload on boot
cat > /root/cvat/nuclio-container-restart.sh << 'EOF'
#!/bin/bash
while [ "$( docker container inspect -f '{{.State.Status}}' cvat )" != "running" ]; do sleep 3; done;
nuctl delete function openvino-dextr
nuctl delete function openvino-mask-rcnn-inception-resnet-v2-atrous-coco
nuctl delete function openvino-omz-intel-person-reidentification-retail-0300
nuctl delete function openvino-omz-intel-text-detection-0004
nuctl delete function openvino-omz-public-faster_rcnn_inception_v2_coco
nuctl delete function openvino-omz-public-yolo-v3-tf
nuctl delete function openvino-omz-semantic-segmentation-adas-0001
nuctl delete function pth-foolwood-siammask
nuctl delete function pth-saic-vul-fbrs
nuctl delete project cvat
/root/cvat/serverless/deploy_cpu.sh
exit 0
EOF

chmod u+x /root/cvat/nuclio-container-restart.sh

cat > /etc/systemd/system/nuclio-container-restart.service << 'EOF'
[Unit]
Description=Restart all Nuclio Containers at boot after CVAT is loaded
After=network.target

[Service]
User=root
Group=root
ExecStart=/root/cvat/nuclio-container-restart.sh
Type=oneshot
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
sudo systemctl enable nuclio-container-restart.service

/root/cvat/serverless/deploy_cpu.sh
