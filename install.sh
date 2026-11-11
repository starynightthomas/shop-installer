#!/usr/bin/env bash
# Mağaza kurulumu — boş ya da içinde başka siteler olan bir Ubuntu/Debian sunucuya.
#
#   curl -fsSL https://raw.githubusercontent.com/starynightthomas/shop-installer/main/install.sh | sudo bash
#
# (Bu dosyanın asıl yeri gizli depodaki deploy/install.sh; npm run release onu herkese açık shop-installer deposuna kopyalar.)
#
# Ekranda alan adını ve kurulum adını sorar, ne yapacağını gösterip onay ister. Sunucudaki diğer sitelere
# dokunmaz: mağaza kendi klasöründe (/srv/<ad>), kendi kullanıcısı, kendi Node'u ve kendi servisiyle çalışır;
# mevcut web sunucusuna (Nginx / Apache / Caddy) sadece bu alan adı için ayrı bir dosya ekler.
#
# Seçenekler (sormadan kurmak için): --domain magazam.com --name magazam --yes   |   --dry-run: sadece planı göster
# Kaldırmak için: --uninstall <ad>   (önce /root'a son yedek alınır, adı yazarak onay istenir)
set -euo pipefail

REPO=git@github.com:starynightthomas/go-lob.git
REPO_KEYS_URL=https://github.com/starynightthomas/go-lob/settings/keys
GITHUB_ED25519=SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU
NODE_MAJOR=22
ADMIN_PATH=/minad

DOMAIN='' NAME='' YES=0 DRY=0 UNINSTALL=''
while [ $# -gt 0 ]; do
  case "$1" in
    --domain) DOMAIN=${2:-}; shift 2 ;;
    --name) NAME=${2:-}; shift 2 ;;
    --yes|-y) YES=1; shift ;;
    --dry-run) DRY=1; shift ;;
    --uninstall) UNINSTALL=${2:-}; shift 2 ;;
    *) echo "Bilinmeyen seçenek: $1" >&2; exit 2 ;;
  esac
done

# ---------- yardımcılar ----------
bold() { printf '\033[1m%s\033[0m\n' "$*"; }
ok() { printf '\033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '\033[33m!\033[0m %s\n' "$*"; }
die() { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1;34m▸ %s\033[0m\n' "$*"; }
# curl | bash ile çalışırken standart girdi script'in kendisidir: sorular terminalden okunur.
ask() { local reply; read -r -p "$1" reply < /dev/tty; printf %s "$reply"; }
confirm() {
  [ "$YES" = 1 ] && return 0
  case "$(ask "$1 [e/H] ")" in e|E|evet|y|Y|yes) return 0 ;; *) return 1 ;; esac
}
backup_file() { if [ -f "$1" ]; then cp -a "$1" "$1.bak-$(date +%Y%m%d-%H%M%S)"; fi; }

# Ad kullanılabilir mi? (geçerli biçim, kurulu değil, aynı adda başka bir sistem kullanıcısı yok)
name_problem() {
  local n=$1
  [[ $n =~ ^[a-z][a-z0-9-]{1,19}$ ]] || { echo "Ad küçük harfle başlamalı; sadece küçük harf, rakam ve tire (2–20 karakter)."; return; }
  [ -e "/srv/$n/app" ] && { echo "/srv/$n zaten kurulu. Başka bir ad seç."; return; }
  if id "$n" > /dev/null 2>&1 && [ "$(getent passwd "$n" | cut -d: -f6)" != "/srv/$n" ]; then
    echo "'$n' adında başka bir sistem kullanıcısı var. Başka bir ad seç."
  fi
}

# ---------- 1. ön kontroller ----------
[ "$(id -u)" = 0 ] || die "Root olarak çalıştır: curl -fsSL https://raw.githubusercontent.com/starynightthomas/shop-installer/main/install.sh | sudo bash"
command -v apt-get > /dev/null || die "Bu kurulum Ubuntu/Debian içindir (apt bulunamadı)."
if [ "$YES" != 1 ] && ! { : < /dev/tty; } 2> /dev/null; then die "Terminal bulunamadı; --domain, --name ve --yes ile çalıştır."; fi
if [ -d /usr/local/cpanel ] || [ -d /usr/local/psa ]; then
  die "Bu sunucuda cPanel/Plesk var: web sunucusu ayarlarını o panel yönetir, script dokunmaz."
fi
case "$(uname -m)" in x86_64) NODE_ARCH=x64 ;; aarch64|arm64) NODE_ARCH=arm64 ;; *) die "Desteklenmeyen işlemci: $(uname -m)" ;; esac

# ---------- kaldırma ----------
if [ -n "$UNINSTALL" ]; then
  N=$UNINSTALL
  [[ $N =~ ^[a-z][a-z0-9-]{1,19}$ ]] || die "Geçersiz ad: $N"
  if ! grep -qs 'install.sh' "/etc/systemd/system/$N.service" || [ ! -d "/srv/$N/app" ]; then
    die "'$N' bu script'le kurulmuş bir mağaza değil; hiçbir şeye dokunmadım."
  fi
  bold "Kaldırılacak: $N"
  echo "  Servis $N, güncelleyici zamanlayıcıları, günlük yedek görevi, web sunucusundaki $N site dosyası,"
  echo "  $N kullanıcısı ve /srv/$N klasörü (kod, veritabanı, fotoğraflar, yedekler)."
  FINAL=/root/$N-son-yedek-$(date +%Y%m%d-%H%M%S).tar.gz
  echo "  Önce son yedek alınacak: $FINAL"
  if [ "$YES" != 1 ] && [ "$(ask "Onaylamak için mağaza adını yaz ($N): ")" != "$N" ]; then die "Vazgeçildi; hiçbir şey değiştirilmedi."; fi
  DB=$(sed -n 's/^DB_PATH=//p' "/srv/$N/$N.env")
  if [ -f "$DB" ]; then sqlite3 "$DB" ".backup '/srv/$N/data/son-yedek.db'"; fi
  tar -czf "$FINAL" -C "/srv/$N" data uploads
  chmod 600 "$FINAL"
  ok "Son yedek: $FINAL"
  systemctl disable -q --now "$N" "shop-updater@$N.path" "shop-updater-check@$N.timer" 2> /dev/null || true
  rm -f "/etc/systemd/system/$N.service" "/etc/shop-updater/$N.conf" "/etc/cron.daily/$N-backup"
  if [ -f "/etc/caddy/sites/$N.caddy" ]; then rm -f "/etc/caddy/sites/$N.caddy"; systemctl reload caddy || true; fi
  if [ -e "/etc/nginx/sites-available/$N" ] || [ -e "/etc/nginx/conf.d/$N.conf" ]; then
    rm -f "/etc/nginx/sites-enabled/$N" "/etc/nginx/sites-available/$N" "/etc/nginx/conf.d/$N.conf"
    if nginx -t > /dev/null 2>&1; then systemctl reload nginx; fi
  fi
  if [ -e "/etc/apache2/sites-available/$N.conf" ]; then
    a2dissite -q "$N" > /dev/null 2>&1 || true
    rm -f "/etc/apache2/sites-available/$N.conf" "/etc/apache2/sites-available/$N-le-ssl.conf"
    if apachectl configtest > /dev/null 2>&1; then systemctl reload apache2; fi
  fi
  systemctl daemon-reload
  userdel "$N" 2> /dev/null || true
  rm -rf --one-file-system "/srv/$N"
  ok "$N kaldırıldı. Diğer siteler ve paylaşılan güncelleyici yerinde."
  echo "  GitHub'daki '$N' deploy anahtarını da silebilirsin: $REPO_KEYS_URL"
  exit 0
fi

bold "Mağaza kurulumu"
echo "Bu script sunucundaki diğer sitelere dokunmaz. Ne yapacağını gösterip başlamadan önce onay isteyecek."

# ---------- 2. sorular ----------
DOMAIN_RE='^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,}$'
DOMAIN=${DOMAIN,,}
while ! [[ $DOMAIN =~ $DOMAIN_RE ]]; do
  [ -n "$DOMAIN" ] && warn "Geçersiz alan adı: $DOMAIN"
  [ "$YES" = 1 ] && die "Geçerli bir --domain ver."
  DOMAIN=$(ask "Alan adı (ör. magazam.com): ")
  DOMAIN=${DOMAIN#http://}; DOMAIN=${DOMAIN#https://}; DOMAIN=${DOMAIN%%/*}; DOMAIN=${DOMAIN#www.}; DOMAIN=${DOMAIN,,}
done
SUGGESTED=$(printf %s "${DOMAIN%%.*}" | tr -cd 'a-z0-9-' | cut -c1-20)
[[ $SUGGESTED =~ ^[a-z] ]] || SUGGESTED="shop-$SUGGESTED"
while [ -z "$NAME" ] || [ -n "$(name_problem "$NAME")" ]; do
  if [ -n "$NAME" ]; then
    warn "$(name_problem "$NAME")"
    [ "$YES" = 1 ] && die "Geçerli bir --name ver."
  fi
  NAME=$(ask "Kurulum adı — klasör ve servis adı olur [$SUGGESTED]: ")
  NAME=${NAME:-$SUGGESTED}
done

BASE=/srv/$NAME
APP=$BASE/app
NODE_DIR=$BASE/node

# ---------- 3. sunucuyu tanı ----------
step "Sunucu inceleniyor"
port_used() { ss -Hltn "sport = :$1" 2> /dev/null | grep -q .; }
PORT=3000
while port_used "$PORT" || grep -qs "^PORT=$PORT\$" /srv/*/*.env; do PORT=$((PORT + 1)); done

WEB=none
if systemctl is-active --quiet nginx 2> /dev/null; then WEB=nginx
elif systemctl is-active --quiet apache2 2> /dev/null; then WEB=apache
elif systemctl is-active --quiet caddy 2> /dev/null; then WEB=caddy
elif port_used 80 || port_used 443; then
  die "80/443 portlarını tanımadığım bir program kullanıyor. Sunucundaki siteleri bozmamak için kurulumu yarıda bırakıyorum."
fi

PUBLIC_IP=$(curl -fsS --max-time 5 https://api.ipify.org 2> /dev/null || true)
DOMAIN_IP=$(getent ahostsv4 "$DOMAIN" 2> /dev/null | awk 'NR==1{print $1}' || true)
# www. de bu sunucuyu gösteriyorsa eklenir (yoksa sertifika boşuna denenmesin).
WWW=0
if [ -n "$PUBLIC_IP" ] && [ "$(getent ahostsv4 "www.$DOMAIN" 2> /dev/null | awk 'NR==1{print $1}')" = "$PUBLIC_IP" ]; then WWW=1; fi
WWW_HOST=''
if [ "$WWW" = 1 ]; then WWW_HOST="www.$DOMAIN"; fi
case "$WEB" in
  none) WEB_TEXT="Web sunucusu yok → Caddy kurulacak (HTTPS otomatik)" ;;
  caddy) WEB_TEXT="Caddy çalışıyor → /etc/caddy/sites/$NAME.caddy eklenecek" ;;
  nginx) WEB_TEXT="Nginx çalışıyor → bu alan adı için ayrı site dosyası + Let's Encrypt (certbot)" ;;
  apache) WEB_TEXT="Apache çalışıyor → bu alan adı için ayrı sanal sunucu dosyası + Let's Encrypt (certbot)" ;;
esac

echo
bold "Plan"
echo "  Alan adı      : https://$DOMAIN$([ "$WWW" = 1 ] && echo " (www.$DOMAIN buraya yönlenir)")"
echo "  Kurulum adı   : $NAME   (klasör $BASE, kullanıcı ve servis '$NAME')"
echo "  İç port       : 127.0.0.1:$PORT (dışarıya açık değil)"
echo "  Node.js       : $NODE_MAJOR (sadece bu mağazanın klasörüne; sistemdeki Node'a dokunulmaz)"
echo "  Web sunucusu  : $WEB_TEXT"
echo "  Güncelleme    : panelden (günlük kontrol, tek tık, otomatik yedek ve geri alma)"
echo "  Yedek         : her gün veritabanı + görseller, 14 gün ($BASE/backups)"
if [ -n "$PUBLIC_IP" ] && [ "$DOMAIN_IP" != "$PUBLIC_IP" ]; then
  echo
  warn "$DOMAIN şu an ${DOMAIN_IP:-hiçbir adrese} yönleniyor; bu sunucu $PUBLIC_IP."
  warn "HTTPS için DNS'te A kaydını $PUBLIC_IP yap (Cloudflare'de proxy şimdilik kapalı olsun)."
fi
if [ "$DRY" = 1 ]; then echo; ok "Deneme modu: hiçbir şey değiştirilmedi."; exit 0; fi
echo
confirm "Kuruluma başlansın mı?" || die "Vazgeçildi; hiçbir şey değiştirilmedi."

# ---------- 4. paketler ----------
step "Gerekli paketler"
NEED=()
for p in git curl ca-certificates sqlite3 xz-utils openssl; do dpkg -s "$p" > /dev/null 2>&1 || NEED+=("$p"); done
if [ ${#NEED[@]} -gt 0 ]; then
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${NEED[@]}" > /dev/null
fi
ok "Gerekli paketler hazır (sadece eksikler kuruldu; sistem paketleri güncellenmedi)"

# ---------- 5. kullanıcı ve klasörler ----------
step "Kullanıcı ve klasörler"
id "$NAME" > /dev/null 2>&1 || useradd --system --home-dir "$BASE" --create-home --shell /usr/sbin/nologin "$NAME"
install -d -o "$NAME" -g "$NAME" -m 750 "$BASE" "$BASE/data" "$BASE/uploads" "$BASE/backups"
install -d -o "$NAME" -g "$NAME" -m 700 "$BASE/.ssh"
ok "$BASE ($NAME kullanıcısına ait)"

# ---------- 6. Node.js (mağazaya özel) ----------
step "Node.js $NODE_MAJOR"
if [ ! -x "$NODE_DIR/bin/node" ]; then
  DIST=https://nodejs.org/dist/latest-v$NODE_MAJOR.x
  SUMS=$(curl -fsSL "$DIST/SHASUMS256.txt")
  TARBALL=$(printf '%s\n' "$SUMS" | awk -v a="linux-$NODE_ARCH.tar.xz" '$2 ~ a"$" {print $2}')
  [ -n "$TARBALL" ] || die "Node.js indirme adresi bulunamadı."
  TMP=$(mktemp -d)
  curl -fsSL -o "$TMP/$TARBALL" "$DIST/$TARBALL"
  (cd "$TMP" && printf '%s\n' "$SUMS" | grep " $TARBALL\$" | sha256sum -c --quiet -) || die "Node.js dosyası doğrulanamadı (sha256)."
  install -d -o "$NAME" -g "$NAME" "$NODE_DIR"
  tar -xJf "$TMP/$TARBALL" -C "$NODE_DIR" --strip-components=1
  chown -R "$NAME:$NAME" "$NODE_DIR"
  rm -rf "$TMP"
fi
ok "Node $("$NODE_DIR/bin/node" -v) → $NODE_DIR"
as_app() { sudo -u "$NAME" -H env "PATH=$NODE_DIR/bin:/usr/local/bin:/usr/bin:/bin" "$@"; }

# ---------- 7. GitHub erişimi (gizli depo, salt okunur anahtar) ----------
step "GitHub erişimi"
KEY=$BASE/.ssh/github_deploy
[ -f "$KEY" ] || as_app ssh-keygen -q -t ed25519 -N '' -C "$NAME@$(hostname)" -f "$KEY"
printf 'Host github.com\n  IdentityFile %s\n  IdentitiesOnly yes\n' "$KEY" > "$BASE/.ssh/config"
SCAN=$(ssh-keyscan -t ed25519 github.com 2> /dev/null)
[ "$(printf '%s\n' "$SCAN" | ssh-keygen -lf - | awk '{print $2}')" = "$GITHUB_ED25519" ] || die "GitHub'ın sunucu anahtarı doğrulanamadı (ağda bir sorun olabilir)."
printf '%s\n' "$SCAN" > "$BASE/.ssh/known_hosts"
chown -R "$NAME:$NAME" "$BASE/.ssh"
chmod 600 "$BASE/.ssh/config" "$BASE/.ssh/known_hosts"
until as_app git ls-remote --exit-code "$REPO" HEAD > /dev/null 2>&1; do
  echo
  bold "Bu sunucunun koda erişmesi için aşağıdaki anahtarı GitHub'a ekle:"
  echo "  1) $REPO_KEYS_URL → 'Add deploy key'"
  echo "  2) Title: $NAME ($DOMAIN)   — 'Allow write access' İŞARETLEME"
  echo "  3) Key:"
  echo
  cat "$KEY.pub"
  echo
  [ "$YES" = 1 ] && die "Anahtar GitHub'da tanımlı değil."
  ask "Ekledikten sonra Enter'a bas… " > /dev/null
done
ok "Depoya salt okunur erişim var"

# ---------- 8. kod (son sürüm) ----------
step "Mağaza kodu"
[ -d "$APP/.git" ] || as_app git clone -q "$REPO" "$APP"
as_app git -C "$APP" fetch -q --tags --force origin
VERSION=$(as_app git -C "$APP" tag -l 'v*' --sort=-v:refname | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -1 || true)
[ -n "$VERSION" ] || die "Depoda sürüm (vX.Y.Z) bulunamadı."
as_app git -C "$APP" checkout -q --force "refs/tags/$VERSION"
NPM_CI="cd '$APP' && npm ci --omit=dev --no-audit --no-fund --no-update-notifier --loglevel=error"
if ! as_app sh -c "$NPM_CI"; then
  warn "Hazır paketler bu sunucuya uymadı; derleme araçları kurulup tekrar deneniyor"
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq build-essential python3 > /dev/null
  as_app sh -c "$NPM_CI"
fi
ok "$VERSION kuruldu"

# ---------- 9. ayarlar ve servis ----------
step "Servis"
ENV=$BASE/$NAME.env
if [ ! -f "$ENV" ]; then
  SETUP_TOKEN=$(openssl rand -hex 16)
  install -m 640 -o root -g "$NAME" /dev/null "$ENV"
  cat > "$ENV" <<EOF
NODE_ENV=production
HOST=127.0.0.1
PORT=$PORT
DB_PATH=$BASE/data/$NAME.db
UPLOADS_DIR=$BASE/uploads
SESSION_SECRET=$(openssl rand -hex 32)
SETUP_TOKEN=$SETUP_TOKEN
UPDATER_ENABLED=1
RESEND_API_KEY=
EOF
else
  SETUP_TOKEN=$(sed -n 's/^SETUP_TOKEN=//p' "$ENV")
  PORT=$(sed -n 's/^PORT=//p' "$ENV")
fi
cat > "/etc/systemd/system/$NAME.service" <<EOF
# Mağaza: $DOMAIN (install.sh ile kuruldu)
[Unit]
Description=Shop $NAME ($DOMAIN)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$NAME
Group=$NAME
WorkingDirectory=$APP
EnvironmentFile=$ENV
ExecStart=$NODE_DIR/bin/node src/server.js
Restart=always
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
ReadWritePaths=$BASE/data $BASE/uploads
UMask=0027

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable -q --now "$NAME"
for _ in $(seq 1 30); do curl -fsS "http://127.0.0.1:$PORT/api/health" > /dev/null 2>&1 && break; sleep 1; done
curl -fsS "http://127.0.0.1:$PORT/api/health" > /dev/null || die "Mağaza açılmadı. Günlük: journalctl -u $NAME -n 50"
ok "$NAME servisi çalışıyor (127.0.0.1:$PORT)"

# ---------- 10. web sunucusu + HTTPS ----------
step "Web sunucusu ve HTTPS"
caddy_site() {
  cat <<EOF
# Mağaza: $NAME (install.sh)
$DOMAIN {
	encode zstd gzip
	request_body {
		max_size 12MB
	}
	reverse_proxy 127.0.0.1:$PORT {
		lb_try_duration 10s
		lb_try_interval 250ms
	}
	log
}
EOF
  if [ "$WWW" = 1 ]; then printf 'www.%s {\n\tredir https://%s{uri} permanent\n}\n' "$DOMAIN" "$DOMAIN"; fi
}
caddy_valid() { caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile > /dev/null 2>&1; }
certbot_for() { # $1 eklenti (nginx|apache)
  local names=(-d "$DOMAIN")
  if [ "$WWW" = 1 ]; then names+=(-d "www.$DOMAIN"); fi
  certbot "--$1" -n --agree-tos --register-unsafely-without-email --redirect "${names[@]}" > /dev/null 2>&1 \
    || warn "HTTPS sertifikası alınamadı (DNS henüz bu sunucuyu göstermiyor olabilir). Sonra: certbot --$1 -d $DOMAIN"
}
case "$WEB" in
  none)
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq debian-keyring debian-archive-keyring apt-transport-https gnupg > /dev/null
    curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/gpg.key | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt > /etc/apt/sources.list.d/caddy-stable.list
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq caddy > /dev/null
    install -d /etc/caddy/sites
    backup_file /etc/caddy/Caddyfile
    printf '# Her mağaza kendi dosyasında: /etc/caddy/sites/*.caddy\nimport sites/*.caddy\n' > /etc/caddy/Caddyfile
    caddy_site > "/etc/caddy/sites/$NAME.caddy"
    caddy_valid || die "Caddy ayarı geçersiz."
    systemctl reload caddy || systemctl restart caddy
    ;;
  caddy)
    install -d /etc/caddy/sites
    if ! grep -qE '^[[:space:]]*import[[:space:]]+(/etc/caddy/)?sites/\*' /etc/caddy/Caddyfile; then
      backup_file /etc/caddy/Caddyfile
      printf '\n# Mağazalar (install.sh): her biri kendi dosyasında\nimport sites/*.caddy\n' >> /etc/caddy/Caddyfile
    fi
    caddy_site > "/etc/caddy/sites/$NAME.caddy"
    if ! caddy_valid; then
      rm -f "/etc/caddy/sites/$NAME.caddy"
      die "Caddy ayarı geçersiz çıktı; eklediğim dosyayı geri aldım, diğer siteler etkilenmedi."
    fi
    systemctl reload caddy
    ;;
  nginx)
    { dpkg -s certbot && dpkg -s python3-certbot-nginx; } > /dev/null 2>&1 || DEBIAN_FRONTEND=noninteractive apt-get install -y -qq certbot python3-certbot-nginx > /dev/null
    SITE=/etc/nginx/sites-available/$NAME
    [ -d /etc/nginx/sites-available ] || SITE=/etc/nginx/conf.d/$NAME.conf
    cat > "$SITE" <<EOF
# Mağaza: $NAME (install.sh)
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN $WWW_HOST;
    client_max_body_size 12m;
    location / {
        proxy_pass http://127.0.0.1:$PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
    if [ -d /etc/nginx/sites-enabled ]; then ln -sf "$SITE" "/etc/nginx/sites-enabled/$NAME"; fi
    if ! nginx -t > /dev/null 2>&1; then
      rm -f "$SITE" "/etc/nginx/sites-enabled/$NAME"
      die "Nginx ayarı geçersiz çıktı; eklediğim dosyayı geri aldım, diğer siteler etkilenmedi."
    fi
    systemctl reload nginx
    certbot_for nginx
    ;;
  apache)
    { dpkg -s certbot && dpkg -s python3-certbot-apache; } > /dev/null 2>&1 || DEBIAN_FRONTEND=noninteractive apt-get install -y -qq certbot python3-certbot-apache > /dev/null
    a2enmod -q proxy proxy_http headers > /dev/null
    SITE=/etc/apache2/sites-available/$NAME.conf
    cat > "$SITE" <<EOF
# Mağaza: $NAME (install.sh)
<VirtualHost *:80>
    ServerName $DOMAIN
$(if [ "$WWW" = 1 ]; then echo "    ServerAlias www.$DOMAIN"; fi)
    ProxyPreserveHost On
    RequestHeader set X-Forwarded-Proto expr=%{REQUEST_SCHEME}
    ProxyPass / http://127.0.0.1:$PORT/
    ProxyPassReverse / http://127.0.0.1:$PORT/
</VirtualHost>
EOF
    a2ensite -q "$NAME" > /dev/null
    if ! apachectl configtest > /dev/null 2>&1; then
      a2dissite -q "$NAME" > /dev/null
      rm -f "$SITE"
      die "Apache ayarı geçersiz çıktı; eklediğim dosyayı geri aldım, diğer siteler etkilenmedi."
    fi
    systemctl reload apache2
    certbot_for apache
    ;;
esac
if command -v ufw > /dev/null && ufw status | grep -q 'Status: active'; then ufw allow 80/tcp > /dev/null; ufw allow 443 > /dev/null; fi
ok "$DOMAIN → mağaza"

# ---------- 11. güncelleyici ve yedek ----------
step "Güncelleyici ve günlük yedek"
install -d -o root -g root -m 755 /usr/local/lib/shop-updater /etc/shop-updater
install -o root -g root -m 755 "$APP/deploy/updater.sh" /usr/local/lib/shop-updater/updater.sh
install -o root -g root -m 644 "$APP/deploy/shop-updater@.service" "$APP/deploy/shop-updater@.path" \
  "$APP/deploy/shop-updater-check@.service" "$APP/deploy/shop-updater-check@.timer" /etc/systemd/system/
install -m 600 -o root -g root /dev/null "/etc/shop-updater/$NAME.conf"
cat > "/etc/shop-updater/$NAME.conf" <<EOF
APP_DIR=$APP
DATA_DIR=$BASE/data
BACKUP_DIR=$BASE/backups
DB_FILE=$BASE/data/$NAME.db
APP_USER=$NAME
SERVICE=$NAME
HEALTH_URL=http://127.0.0.1:$PORT/api/health
NODE_BIN_DIR=$NODE_DIR/bin
EOF
cat > "/etc/cron.daily/$NAME-backup" <<EOF
#!/bin/sh
# $NAME: her gün veritabanı + görseller, son 14 gün (install.sh)
set -eu
STAMP=\$(date +%F)
DEST=$BASE/backups
if [ -f $BASE/data/$NAME.db ]; then
  sqlite3 $BASE/data/$NAME.db ".backup '\$DEST/$NAME-\$STAMP.db'"
  gzip -f "\$DEST/$NAME-\$STAMP.db"
fi
tar -czf "\$DEST/uploads-\$STAMP.tar.gz" -C $BASE uploads
chown $NAME:$NAME "\$DEST"/*-"\$STAMP".*
chmod 640 "\$DEST"/*-"\$STAMP".*
find "\$DEST" -type f -mtime +14 -delete
EOF
chmod 755 "/etc/cron.daily/$NAME-backup"
systemctl daemon-reload
systemctl enable -q --now "shop-updater@$NAME.path" "shop-updater-check@$NAME.timer"
ok "Panelden güncelleme ve günlük yedek açık"

# ---------- bitti ----------
echo
bold "Kurulum tamamlandı ($VERSION)"
echo
echo "  1) Tarayıcıda aç:   https://$DOMAIN/setup"
echo "  2) Kurulum kodu:    $SETUP_TOKEN"
echo "     (kurulum ekranı bunu ister; sunucuda $ENV dosyasında da yazar)"
echo "  3) Mağaza adını, logoyu ve yönetici hesabını gir."
echo
echo "  Yönetim paneli:     https://$DOMAIN$ADMIN_PATH"
echo "  Servis günlüğü:     journalctl -u $NAME -f"
if [ -n "$PUBLIC_IP" ] && [ "$DOMAIN_IP" != "$PUBLIC_IP" ]; then
  echo
  warn "DNS henüz bu sunucuyu göstermiyor: A kaydını $PUBLIC_IP yap; HTTPS birkaç dakika içinde kendiliğinden gelir."
fi
