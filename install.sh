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
# Alan adını değiştirmek için: --alanadi <ad>  (yeni alan adı sorulur; Cloudflare'e eklenir, nameserver'lar söylenir)
# Kaldırmak için: --uninstall <ad>   (önce /root'a son yedek alınır, adı yazarak onay istenir)
set -euo pipefail
# Yeni sunucularda ilk açılış güncellemesi apt'yi kilitleyebilir: kilit kalkana kadar bekle (en fazla 10 dk).
# needrestart (Ubuntu) servisleri sormadan yeniden başlatsın.
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
APT_LOCK=(-o DPkg::Lock::Timeout=600)

GITHUB_REPO=starynightthomas/go-lob
REPO=git@github.com:$GITHUB_REPO.git
REPO_KEYS_URL=https://github.com/starynightthomas/go-lob/settings/keys
GITHUB_ED25519=SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU
NODE_MAJOR=22
ADMIN_PATH=/minad

DOMAIN='' NAME='' YES=0 DRY=0 UNINSTALL='' SETUP=0 LIST=0 CHANGE=''
while [ $# -gt 0 ]; do
  case "$1" in
    --domain) DOMAIN=${2:-}; shift 2 ;;
    --name) NAME=${2:-}; shift 2 ;;
    --yes|-y) YES=1; shift ;;
    --dry-run) DRY=1; shift ;;
    --setup) SETUP=1; shift ;;
    --list) LIST=1; shift ;;
    --alanadi|--change-domain) CHANGE=${2:-}; shift 2 ;;
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
ask() { local reply; read -r -p "$1" reply < /dev/tty || die "Giriş kapandı; kurulum durdu (hiçbir şey kaydedilmedi)."; printf %s "$reply"; }
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

INSTALLER_URL=https://raw.githubusercontent.com/starynightthomas/shop-installer/main/install.sh

# /usr/local/bin/yenisite: "yenisite" yazınca yeni mağaza kurar, "yenisite --uninstall <ad>" kaldırır.
install_yenisite() {
  cat > /usr/local/bin/yenisite <<EOF
#!/bin/sh
# Bu sunucuya yeni bir mağaza kurar (en güncel kurulum script'iyle). Kaldırmak için: yenisite --uninstall <ad>
[ "\$(id -u)" = 0 ] || exec sudo "\$0" "\$@"
SCRIPT=\$(curl -fsSL $INSTALLER_URL) || { echo "Kurulum script'i indirilemedi." >&2; exit 1; }
exec bash -c "\$SCRIPT" yenisite "\$@"
EOF
  chmod 755 /usr/local/bin/yenisite
}

# ---------- sunucu ayarları: Cloudflare ve GitHub anahtarları ----------
# Sunucu kurulumunda bir kez sorulur, sadece root'un okuyabileceği dosyada saklanır. Her "yenisite" bunları
# kullanarak DNS kaydını açar ve gizli depoya o sitenin salt okunur anahtarını ekler.
DOMAIN_RE='^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,}$'
CONF_DIR=/etc/shop-installer
CRED=$CONF_DIR/credentials
SITES_DIR=$CONF_DIR/sites
CF_API_TOKEN='' CF_ACCOUNT_ID='' GITHUB_TOKEN=''

ask_secret() { local reply; read -r -s -p "$1" reply < /dev/tty || die "Giriş kapandı; kurulum durdu (hiçbir şey kaydedilmedi)."; echo > /dev/tty; printf %s "$reply"; }
load_creds() { if [ -f "$CRED" ]; then . "$CRED"; fi; }

cf_api() { # METHOD PATH [JSON]
  curl -fsS --max-time 20 -X "$1" -H "Authorization: Bearer $CF_API_TOKEN" -H 'Content-Type: application/json' \
    "https://api.cloudflare.com/client/v4$2" ${3:+--data "$3"}
}
gh_api() { # METHOD PATH [JSON]
  curl -fsS --max-time 20 -X "$1" -H "Authorization: Bearer $GITHUB_TOKEN" -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' "https://api.github.com$2" ${3:+--data "$3"}
}

check_cf_token() { cf_api GET '/zones?per_page=50' 2> /dev/null | jq -e '.success' > /dev/null 2>&1; }
check_gh_token() { gh_api GET "/repos/$GITHUB_REPO/keys" > /dev/null 2>&1; }

# ---------- sunucuyu hazırlama (sunucu kurulumunun ilk adımı) ----------
# Sistemi tamamen günceller, eksik araçları kurar, otomatik güvenlik güncellemelerini, gerekirse swap'i,
# güvenlik duvarını (SSH portu açık kalır) ve fail2ban'ı açar. SSH giriş ayarlarına dokunmaz.
ssh_ports() { sshd -T 2> /dev/null | awk '$1 == "port" {print $2}' | sort -u | tr '\n' ' '; }
prepare_server() {
  local ram_mb swap_mb ports
  ram_mb=$(awk '/^MemTotal:/{print int($2/1024)}' /proc/meminfo)
  swap_mb=$(awk '/^SwapTotal:/{print int($2/1024)}' /proc/meminfo)
  ports=$(ssh_ports); ports=${ports:-22 }
  bold "Sunucu hazırlığı"
  echo "  • Tüm sistem paketleri son sürüme yükseltilir (apt full-upgrade), gereksizler temizlenir"
  echo "  • Araçlar: git, curl, jq, sqlite3, htop, unattended-upgrades, ufw, fail2ban"
  echo "  • Otomatik güvenlik güncellemeleri ve saat eşitleme açılır"
  if [ "$swap_mb" -lt 256 ] && [ "$ram_mb" -lt 4096 ]; then echo "  • RAM ${ram_mb} MB, swap yok → $(( ram_mb < 2048 ? ram_mb : 2048 )) MB swap dosyası oluşturulur"; fi
  echo "  • Güvenlik duvarı (ufw): SSH (port ${ports% }), 80 ve 443 açık; diğerleri kapalı"
  echo "  • fail2ban: SSH'ye art arda hatalı girişleri geçici olarak engeller"
  echo "  SSH giriş ayarların (şifre / anahtar, root girişi) değiştirilmez."
  echo
  confirm "Sunucu hazırlansın mı?" || { warn "Hazırlık atlandı; sadece gerekli paketler kurulacak."; return 0; }

  step "Sistem güncelleniyor (birkaç dakika sürebilir)"
  export DEBIAN_FRONTEND=noninteractive
  local apt_opts=(-y -qq "${APT_LOCK[@]}" -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
  apt-get "${APT_LOCK[@]}" update -qq
  apt-get "${apt_opts[@]}" full-upgrade > /dev/null
  apt-get "${apt_opts[@]}" install git curl ca-certificates gnupg jq sqlite3 xz-utils openssl htop \
    unattended-upgrades ufw fail2ban > /dev/null
  apt-get -y -qq "${APT_LOCK[@]}" autoremove --purge > /dev/null
  ok "Sistem güncel"

  step "Otomatik güvenlik güncellemeleri ve saat"
  printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\nAPT::Periodic::AutocleanInterval "7";\n' > /etc/apt/apt.conf.d/20auto-upgrades
  systemctl enable -q --now unattended-upgrades 2> /dev/null || true
  timedatectl set-ntp true 2> /dev/null || true
  ok "Güvenlik güncellemeleri her gün otomatik kurulur; saat eşitleniyor ($(timedatectl show -p Timezone --value 2> /dev/null || echo UTC))"

  if [ "$swap_mb" -lt 256 ] && [ "$ram_mb" -lt 4096 ] && [ ! -e /swapfile ]; then
    step "Swap"
    local size=$(( ram_mb < 2048 ? ram_mb : 2048 ))
    fallocate -l "${size}M" /swapfile 2> /dev/null || dd if=/dev/zero of=/swapfile bs=1M count="$size" status=none
    chmod 600 /swapfile
    mkswap /swapfile > /dev/null
    swapon /swapfile
    grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    ok "${size} MB swap açık"
  fi

  step "Güvenlik duvarı ve fail2ban"
  local p
  for p in $ports; do ufw allow "$p/tcp" > /dev/null; done
  ufw allow 80/tcp > /dev/null
  ufw allow 443 > /dev/null
  ufw --force enable > /dev/null
  systemctl enable -q --now fail2ban 2> /dev/null || true
  ok "ufw açık (SSH ${ports% }, 80, 443); fail2ban çalışıyor"
}

# Çekirdek ya da temel kütüphaneler güncellendiyse yeniden başlatmayı önerir.
offer_reboot() {
  [ -f /var/run/reboot-required ] || return 0
  echo
  warn "Güncellemelerin tamamlanması için sunucunun yeniden başlatılması gerekiyor."
  if [ "$YES" != 1 ] && confirm "Şimdi yeniden başlatılsın mı? (bağlantın kopar, 1 dakika sonra tekrar bağlanabilirsin)"; then
    echo "Yeniden başlatılıyor…"
    systemctl reboot
  else
    echo "  Uygun bir zamanda yeniden başlat: sudo reboot   (siteler açılışta kendiliğinden başlar)"
  fi
}

server_setup() {
  bold "Sunucu kurulumu (bir kez)"
  echo
  prepare_server
  echo
  echo "Siteleri tamamen otomatik kurabilmem için iki anahtar gerekiyor. Yazdıkların ekranda görünmez;"
  echo "sadece bu sunucuda, root'un okuyabileceği $CRED dosyasında saklanır."
  echo
  bold "1) Cloudflare API anahtarı"
  echo "   dash.cloudflare.com → sağ üst profil → API Tokens → Create Token → Custom token → Get started"
  echo "   Permissions:  Zone · Zone · Edit   ve   Zone · DNS · Edit   (istersen: Account · Account Settings · Read)"
  echo "   Zone Resources: Include · All zones from an account · <hesabın>  → Continue → Create Token → kopyala."
  until [ -n "$CF_API_TOKEN" ] && check_cf_token; do
    [ -n "$CF_API_TOKEN" ] && warn "Bu anahtarla Cloudflare'e bağlanılamadı (yanlış ya da yetkisi eksik)."
    CF_API_TOKEN=$(ask_secret "   Cloudflare API anahtarı: ")
  done
  ok "Cloudflare: $(cf_api GET '/zones?per_page=50' | jq -r '[.result[].name] | join(", ") | if . == "" then "henüz alan adı yok" else . end')"
  # Yeni alan adlarını hesaba ekleyebilmek için hesap numarası: anahtar okuyabiliyorsa otomatik, yoksa sorulur.
  CF_ACCOUNT_ID=$(cf_api GET '/accounts?per_page=5' 2> /dev/null | jq -r 'if (.result | length) == 1 then .result[0].id else empty end') || CF_ACCOUNT_ID=''
  [ -n "$CF_ACCOUNT_ID" ] || CF_ACCOUNT_ID=$(cf_api GET '/zones?per_page=1' 2> /dev/null | jq -r '.result[0].account.id // empty') || CF_ACCOUNT_ID=''
  while ! [[ $CF_ACCOUNT_ID =~ ^[0-9a-f]{32}$ ]]; do
    echo "   Cloudflare hesap numarası (Account ID): dash.cloudflare.com açıkken adres çubuğundaki 32 karakterlik kod."
    CF_ACCOUNT_ID=$(ask "   Account ID: ")
  done
  ok "Cloudflare hesabı: $CF_ACCOUNT_ID"
  echo
  bold "2) GitHub anahtarı"
  echo "   github.com/settings/personal-access-tokens/new → Repository access: Only select → $GITHUB_REPO"
  echo "   Permissions → Repository → Administration: Read and write → Generate → anahtarı kopyala."
  until [ -n "$GITHUB_TOKEN" ] && check_gh_token; do
    [ -n "$GITHUB_TOKEN" ] && warn "Bu anahtarla $GITHUB_REPO deposunun anahtarlarına erişilemedi (Administration: Read and write gerekli)."
    GITHUB_TOKEN=$(ask_secret "   GitHub anahtarı: ")
  done
  ok "GitHub: $GITHUB_REPO erişimi var"
  install -d -m 700 -o root -g root "$CONF_DIR" "$SITES_DIR"
  install -m 600 -o root -g root /dev/null "$CRED"
  printf 'CF_API_TOKEN=%q\nCF_ACCOUNT_ID=%q\nGITHUB_TOKEN=%q\n' "$CF_API_TOKEN" "$CF_ACCOUNT_ID" "$GITHUB_TOKEN" > "$CRED"
  install_yenisite
  ok "Anahtarlar kaydedildi; 'yenisite' komutu hazır."
}

# Alan adının Cloudflare'deki bölgesi (en uzun eşleşen): "zone_id zone_name" ya da boş.
cf_zone_for() {
  local d=$1
  while [[ $d == *.* ]]; do
    local r; r=$(cf_api GET "/zones?name=$d" 2> /dev/null | jq -r '.result[0] | select(.) | "\(.id) \(.name)"') || r=''

    if [ -n "$r" ]; then printf %s "$r"; return; fi
    d=${d#*.}
  done
}

# Alan adının kayıtlı kökü: magaza.example.com → example.com, shop.example.com.tr → example.com.tr
registrable() {
  local d=$1
  case ".$d" in
    *.com.tr|*.net.tr|*.org.tr|*.gen.tr|*.web.tr|*.co.uk|*.org.uk|*.com.au|*.net.au|*.co.nz|*.com.br|*.co.jp|*.co.za|*.com.mx)
      while [ "$(printf %s "$d" | tr -cd . | wc -c)" -gt 2 ]; do d=${d#*.}; done ;;
    *) while [ "$(printf %s "$d" | tr -cd . | wc -c)" -gt 1 ]; do d=${d#*.}; done ;;
  esac
  printf %s "$d"
}

# Alan adını Cloudflare hesabına ekler; "zone_id ns1 ns2" yazar.
cf_create_zone() { # alan_adı
  local res; res=$(curl -sS --max-time 20 -X POST -H "Authorization: Bearer $CF_API_TOKEN" -H 'Content-Type: application/json' \
    https://api.cloudflare.com/client/v4/zones --data "$(jq -nc --arg n "$1" --arg a "$CF_ACCOUNT_ID" '{name:$n,account:{id:$a},type:"full"}')")
  if [ "$(printf %s "$res" | jq -r .success)" != true ]; then
    die "$1 Cloudflare'e eklenemedi: $(printf %s "$res" | jq -r '[.errors[].message] | join("; ")')"
  fi
  printf %s "$res" | jq -r '"\(.result.id) \(.result.name_servers | join(" "))"'
}

zone_status() { cf_api GET "/zones/$1" 2> /dev/null | jq -r '.result.status // "?"' || echo '?'; }

# A kaydını açar/günceller (proxy kapalı); başka türde bir kayıt varsa dokunmaz. Kayıt id'sini yazar.
cf_upsert_a() { # zone_id host ip site
  local existing other
  existing=$(cf_api GET "/zones/$1/dns_records?name=$2" | jq -c '.result')
  other=$(printf %s "$existing" | jq -r '[.[] | select(.type != "A" and .type != "AAAA")][0].type // empty')
  [ -z "$other" ] || die "$2 için Cloudflare'de zaten bir $other kaydı var; sitelerini bozmamak için dokunmadım."
  local id; id=$(printf %s "$existing" | jq -r '[.[] | select(.type == "A")][0].id // empty')
  local body; body=$(jq -nc --arg n "$2" --arg ip "$3" --arg c "yenisite: $4" '{type:"A",name:$n,content:$ip,ttl:1,proxied:false,comment:$c}')
  if [ -n "$id" ]; then cf_api PUT "/zones/$1/dns_records/$id" "$body" | jq -r '.result.id'
  else cf_api POST "/zones/$1/dns_records" "$body" | jq -r '.result.id'; fi
}

# Cloudflare'in kendi çözücüsü kaydı görene kadar bekler (en fazla ~2 dk).
wait_dns() { # host ip
  for _ in $(seq 1 40); do
    [ "$(curl -fsS --max-time 5 -H 'accept: application/dns-json' "https://cloudflare-dns.com/dns-query?name=$1&type=A" | jq -r '[.Answer[]?.data][0] // empty')" = "$2" ] && return 0
    sleep 3
  done
  return 1
}


# ---------- web sunucusu ayarı (yeni site ve alan adı değişikliği ortak) ----------
# Kullanır: NAME DOMAIN PORT WWW WWW_HOST, isteğe bağlı REDIRECT_HOSTS (eski alan adları → yeni adrese yönlenir)
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
  if [ -n "${REDIRECT_HOSTS:-}" ]; then
    printf '# Eski alan adları → %s\n%s {\n\tredir https://%s{uri} permanent\n}\n' "$DOMAIN" "$(printf %s "$REDIRECT_HOSTS" | sed 's/ /, /g')" "$DOMAIN"
  fi
}
caddy_valid() { caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile > /dev/null 2>&1; }
certbot_for() { # $1 eklenti (nginx|apache)
  local names=(-d "$DOMAIN")
  if [ "$WWW" = 1 ]; then names+=(-d "www.$DOMAIN"); fi
  certbot "--$1" -n --agree-tos --register-unsafely-without-email --redirect "${names[@]}" > /dev/null 2>&1 \
    || warn "HTTPS sertifikası alınamadı (DNS henüz bu sunucuyu göstermiyor olabilir). Sonra: certbot --$1 -d $DOMAIN"
}
nginx_site_path() { if [ -d /etc/nginx/sites-available ]; then echo "/etc/nginx/sites-available/$NAME"; else echo "/etc/nginx/conf.d/$NAME.conf"; fi; }
write_nginx_site() {
  cat > "$(nginx_site_path)" <<EOF
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
}
write_apache_site() {
  cat > "/etc/apache2/sites-available/$NAME.conf" <<EOF
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
}

# ---------- DNS planı ve uygulaması (yeni site ve alan adı değişikliği ortak) ----------
# dns_plan: ZONE ZONE_ID ZONE_NAME NEW_ZONE WWW WWW_HOST ayarlar (hiçbir şey değiştirmez)
dns_plan() {
  ZONE='' ZONE_ID='' ZONE_NAME='' NEW_ZONE='' WWW=0 WWW_HOST=''
  if [ -n "$CF_API_TOKEN" ]; then ZONE=$(cf_zone_for "$DOMAIN"); fi
  if [ -n "$ZONE" ]; then ZONE_ID=${ZONE%% *}; ZONE_NAME=${ZONE#* }; fi
  if [ -z "$ZONE" ] && [ -n "$CF_API_TOKEN" ] && [ -n "$CF_ACCOUNT_ID" ]; then NEW_ZONE=$(registrable "$DOMAIN"); fi
  if { [ -n "$ZONE" ] || [ -n "$NEW_ZONE" ]; } && [ -z "$PUBLIC_IP" ]; then die "Sunucunun dış IP adresi bulunamadı (internet bağlantısını kontrol et)."; fi
  if [ -n "$NEW_ZONE" ] && [ "$DOMAIN" = "$NEW_ZONE" ]; then WWW=1
  elif [ -n "$ZONE" ] && [ "$DOMAIN" = "$ZONE_NAME" ]; then WWW=1
  # Cloudflare'de değilse: www. de bu sunucuyu gösteriyorsa eklenir (yoksa sertifika boşuna denenmesin).
  elif [ -n "$PUBLIC_IP" ] && [ "$(getent ahostsv4 "www.$DOMAIN" 2> /dev/null | awk 'NR==1{print $1}')" = "$PUBLIC_IP" ]; then WWW=1; fi
  if [ "$WWW" = 1 ]; then WWW_HOST="www.$DOMAIN"; fi
}
dns_plan_text() {
  if [ -n "$ZONE" ]; then
    echo "  DNS           : Cloudflare ($ZONE_NAME) → $DOMAIN$([ "$WWW" = 1 ] && echo " ve www.$DOMAIN") → $PUBLIC_IP (otomatik)"
  elif [ -n "$NEW_ZONE" ]; then
    echo "  DNS           : $NEW_ZONE Cloudflare hesabına eklenecek, $DOMAIN$([ "$WWW" = 1 ] && echo " ve www.$DOMAIN") → $PUBLIC_IP"
    echo "                  (sonunda alan adını aldığın yerde değiştireceğin nameserver'lar yazılacak)"
  else
    echo "  DNS           : $DOMAIN bu Cloudflare hesabında yok → kaydı elle yapman gerekecek"
  fi
}
# dns_apply: gerekirse bölgeyi oluşturur (NAMESERVERS), A kayıtlarını açar (CF_RECORD_IDS)
dns_apply() {
  CF_RECORD_IDS='' NAMESERVERS=''
  if [ -n "$NEW_ZONE" ]; then
    step "Alan adı Cloudflare'e ekleniyor"
    local created; created=$(cf_create_zone "$NEW_ZONE") || exit 1
    ZONE_ID=${created%% *}; NAMESERVERS=${created#* }; ZONE="$ZONE_ID $NEW_ZONE"; ZONE_NAME=$NEW_ZONE
    ok "$NEW_ZONE Cloudflare'e eklendi (nameserver'lar: $NAMESERVERS)"
  fi
  [ -n "$ZONE" ] || return 0
  step "DNS kaydı (Cloudflare)"
  CF_RECORD_IDS=$(cf_upsert_a "$ZONE_ID" "$DOMAIN" "$PUBLIC_IP" "$NAME") || exit 1
  if [ "$WWW" = 1 ]; then
    local www_id; www_id=$(cf_upsert_a "$ZONE_ID" "www.$DOMAIN" "$PUBLIC_IP" "$NAME") || exit 1
    CF_RECORD_IDS="$CF_RECORD_IDS $www_id"
  fi
  ok "$DOMAIN$([ "$WWW" = 1 ] && echo " ve www.$DOMAIN") → $PUBLIC_IP"
}
dns_wait_or_warn() {
  if [ -n "$ZONE" ] && [ "$(zone_status "$ZONE_ID")" = active ]; then
    wait_dns "$DOMAIN" "$PUBLIC_IP" && ok "DNS yayıldı" || warn "DNS henüz yayılmadı; HTTPS sertifikası birkaç dakika içinde kendiliğinden alınır."
  elif [ -n "$ZONE" ]; then
    warn "$ZONE_NAME Cloudflare'de henüz aktif değil (nameserver değişikliği bekleniyor); HTTPS o zaman kendiliğinden gelir."
  fi
}
nameserver_box() {
  [ -n "$NAMESERVERS" ] || return 0
  echo
  bold "  ÖNEMLİ — nameserver'ları değiştir:"
  echo "  $ZONE_NAME alan adını aldığın firmanın panelinde (GoDaddy, Namecheap, Natro, isimtescil…)"
  echo "  'Nameserver / DNS sunucuları' bölümünü 'özel' yapıp şunları yaz:"
  for ns in $NAMESERVERS; do echo "      $ns"; done
  echo "  Değişiklik birkaç dakika ile birkaç saat sürer. Durumu görmek için: yenisite --list"
  echo "  Aktif olunca https://$DOMAIN kendiliğinden açılır (HTTPS'i web sunucusu kendisi alır)."
}
# Site kaydı (yenisite --list / --uninstall / --alanadi için)
save_site() {
  install -d -m 700 -o root -g root "$CONF_DIR" "$SITES_DIR"
  install -m 600 -o root -g root /dev/null "$SITES_DIR/$NAME.env"
  printf 'NAME=%q\nDOMAIN=%q\nPORT=%q\nCF_ZONE_ID=%q\nCF_ZONE_CREATED=%q\nCF_RECORD_IDS=%q\nGH_KEY_ID=%q\nCREATED=%q\nREDIRECT_HOSTS=%q\nEXTRA_CF_RECORDS=%q\n' \
    "$NAME" "$DOMAIN" "$PORT" "${ZONE_ID:-}" "${CF_ZONE_CREATED:-0}" "$CF_RECORD_IDS" "${GH_KEY_ID:-}" "${CREATED:-$(date +%F)}" \
    "${REDIRECT_HOSTS:-}" "${EXTRA_CF_RECORDS:-}" > "$SITES_DIR/$NAME.env"
}

# ---------- 1. ön kontroller ----------
[ "$(id -u)" = 0 ] || die "Root olarak çalıştır: curl -fsSL https://raw.githubusercontent.com/starynightthomas/shop-installer/main/install.sh | sudo bash"
command -v apt-get > /dev/null || die "Bu kurulum Ubuntu/Debian içindir (apt bulunamadı)."
if [ "$YES" != 1 ] && ! { : < /dev/tty; } 2> /dev/null; then die "Terminal bulunamadı; --domain, --name ve --yes ile çalıştır."; fi
if [ -d /usr/local/cpanel ] || [ -d /usr/local/psa ]; then
  die "Bu sunucuda cPanel/Plesk var: web sunucusu ayarlarını o panel yönetir, script dokunmaz."
fi
case "$(uname -m)" in x86_64) NODE_ARCH=x64 ;; aarch64|arm64) NODE_ARCH=arm64 ;; *) die "Desteklenmeyen işlemci: $(uname -m)" ;; esac

# Sadece eksik paketleri kurar (sistem paketleri güncellenmez).
ensure_pkgs() {
  local need=() p
  for p in "$@"; do dpkg -s "$p" > /dev/null 2>&1 || need+=("$p"); done
  [ ${#need[@]} -eq 0 ] && return 0
  apt-get "${APT_LOCK[@]}" update -qq
  DEBIAN_FRONTEND=noninteractive apt-get "${APT_LOCK[@]}" install -y -qq "${need[@]}" > /dev/null
}
ensure_pkgs curl ca-certificates jq
load_creds

# ---------- kurulu siteler ----------
if [ "$LIST" = 1 ]; then
  bold "Bu sunucudaki siteler"
  found=0
  for f in "$SITES_DIR"/*.env; do
    [ -f "$f" ] || continue
    found=1
    ( . "$f"
      zs=''; if [ -n "${CF_ZONE_ID:-}" ] && [ -n "$CF_API_TOKEN" ]; then zs=$(zone_status "$CF_ZONE_ID"); fi
      case "$zs" in active) zs='Cloudflare: aktif' ;; pending) zs="Cloudflare: nameserver bekleniyor ($(cf_api GET "/zones/$CF_ZONE_ID" | jq -r '.result.name_servers | join(", ")'))" ;; '') ;; *) zs="Cloudflare: $zs" ;; esac
      printf '  %-14s https://%-32s servis: %-8s %s\n' "$NAME" "$DOMAIN" "$(systemctl is-active "$NAME" 2> /dev/null)" "$zs"
      if [ -n "${REDIRECT_HOSTS:-}" ]; then printf '  %-14s yönlenen eski adresler: %s\n' '' "$REDIRECT_HOSTS"; fi )
  done
  [ "$found" = 1 ] || echo "  Henüz site yok. Kurmak için: yenisite"
  exit 0
fi

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
  if [ -f "$SITES_DIR/$N.env" ]; then echo "  Cloudflare'de bu site için açılan DNS kayıtları ve GitHub'daki salt okunur anahtarı."; fi
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
  if [ -f "$SITES_DIR/$N.env" ]; then
    # shellcheck disable=SC1090
    ( . "$SITES_DIR/$N.env"
      for id in $CF_RECORD_IDS; do cf_api DELETE "/zones/$CF_ZONE_ID/dns_records/$id" > /dev/null 2>&1 || warn "DNS kaydı silinemedi ($id); Cloudflare'den elle silebilirsin."; done
      for zr in ${EXTRA_CF_RECORDS:-}; do cf_api DELETE "/zones/${zr%%:*}/dns_records/${zr#*:}" > /dev/null 2>&1 || warn "Eski alan adının DNS kaydı silinemedi (${zr#*:})."; done
      if [ -n "${GH_KEY_ID:-}" ]; then gh_api DELETE "/repos/$GITHUB_REPO/keys/$GH_KEY_ID" > /dev/null 2>&1 || warn "GitHub anahtarı silinemedi; $REPO_KEYS_URL"; fi )
    if grep -qs '^CF_ZONE_CREATED=1' "$SITES_DIR/$N.env"; then
      echo "  Not: alan adının kendisi Cloudflare hesabında kaldı (başka kayıtların olabilir); istersen Cloudflare'den silebilirsin."
    fi
    rm -f "$SITES_DIR/$N.env"
    ok "DNS kayıtları ve GitHub anahtarı silindi"
  else
    echo "  GitHub'daki '$N' deploy anahtarını da silebilirsin: $REPO_KEYS_URL"
  fi
  ok "$N kaldırıldı. Diğer siteler ve paylaşılan güncelleyici yerinde."
  exit 0
fi

# ---------- alan adı değişikliği ----------
if [ -n "$CHANGE" ]; then
  N=$CHANGE
  [[ $N =~ ^[a-z][a-z0-9-]{1,19}$ ]] || die "Geçersiz ad: $N"
  [ -f "$SITES_DIR/$N.env" ] || die "'$N' yenisite ile kurulmuş bir site değil. Kurulu siteler: yenisite --list"
  ARG_DOMAIN=$DOMAIN
  # shellcheck disable=SC1090
  . "$SITES_DIR/$N.env"
  OLD_DOMAIN=$DOMAIN OLD_ZONE_ID=$CF_ZONE_ID OLD_RECORD_IDS=$CF_RECORD_IDS OLD_ZONE_CREATED=${CF_ZONE_CREATED:-0}
  if [ -f "/etc/caddy/sites/$NAME.caddy" ]; then WEB=caddy
  elif [ -e "/etc/nginx/sites-available/$NAME" ] || [ -e "/etc/nginx/conf.d/$NAME.conf" ]; then WEB=nginx
  elif [ -e "/etc/apache2/sites-available/$NAME.conf" ]; then WEB=apache
  else die "$NAME için web sunucusu ayarı bulunamadı."; fi
  OLD_HOSTS=$OLD_DOMAIN
  if [ "$WEB" = caddy ] && grep -q "^www\.$OLD_DOMAIN " "/etc/caddy/sites/$NAME.caddy"; then OLD_HOSTS="$OLD_DOMAIN www.$OLD_DOMAIN"; fi

  bold "Alan adı değişikliği: $NAME"
  echo "Şu anki adres: https://$OLD_DOMAIN"
  DOMAIN=${ARG_DOMAIN,,}
  while ! [[ $DOMAIN =~ $DOMAIN_RE ]] || [ "$DOMAIN" = "$OLD_DOMAIN" ]; do
    [ -n "$DOMAIN" ] && warn "Geçersiz ya da aynı alan adı: $DOMAIN"
    [ "$YES" = 1 ] && die "Geçerli ve farklı bir --domain ver."
    DOMAIN=$(ask "Yeni alan adı (ör. yenimagaza.com): ")
    DOMAIN=${DOMAIN#http://}; DOMAIN=${DOMAIN#https://}; DOMAIN=${DOMAIN%%/*}; DOMAIN=${DOMAIN#www.}; DOMAIN=${DOMAIN,,}
  done
  PUBLIC_IP=$(curl -fsS --max-time 5 https://api.ipify.org 2> /dev/null || true)
  dns_plan
  REDIRECT=0
  if [ "$WEB" = caddy ]; then
    confirm "Eski adres ($OLD_DOMAIN) yeni adrese yönlensin mi? (eski linkler ve Google kayıtları kaybolmaz)" && REDIRECT=1
  fi
  echo
  bold "Plan"
  echo "  Site          : $NAME"
  echo "  Eski adres    : https://$OLD_DOMAIN → $([ "$REDIRECT" = 1 ] && echo "https://$DOMAIN adresine yönlenecek" || echo "kaldırılacak (DNS kayıtları da silinir)")"
  echo "  Yeni adres    : https://$DOMAIN$([ "$WWW" = 1 ] && echo " (www.$DOMAIN buraya yönlenir)")"
  dns_plan_text
  echo "  HTTPS         : yeni alan adı için sertifika otomatik alınır"
  if [ "$DRY" = 1 ]; then echo; ok "Deneme modu: hiçbir şey değiştirilmedi."; exit 0; fi
  echo
  confirm "Değişiklik yapılsın mı?" || die "Vazgeçildi; hiçbir şey değiştirilmedi."

  dns_apply
  CF_ZONE_CREATED=$([ -n "$NEW_ZONE" ] && echo 1 || echo 0)
  if [ "$REDIRECT" = 1 ]; then
    REDIRECT_HOSTS=$(printf '%s\n' ${REDIRECT_HOSTS:-} $OLD_HOSTS | { grep -vxF -e "$DOMAIN" -e "www.$DOMAIN" || true; } | sort -u | tr '\n' ' ' | sed 's/ $//')
    for id in $OLD_RECORD_IDS; do EXTRA_CF_RECORDS="${EXTRA_CF_RECORDS:-} $OLD_ZONE_ID:$id"; done
    EXTRA_CF_RECORDS=${EXTRA_CF_RECORDS# }
  fi

  step "Web sunucusu ve HTTPS"
  dns_wait_or_warn
  case "$WEB" in
    caddy)
      F=/etc/caddy/sites/$NAME.caddy
      cp -a "$F" "$F.eski"
      caddy_site > "$F"
      if ! caddy_valid; then mv -f "$F.eski" "$F"; die "Caddy ayarı geçersiz çıktı; eski hali geri yüklendi, site eski adresinde çalışmaya devam ediyor."; fi
      rm -f "$F.eski"
      systemctl reload caddy
      ;;
    nginx)
      F=$(nginx_site_path)
      cp -a "$F" "$F.eski"
      write_nginx_site
      if ! nginx -t > /dev/null 2>&1; then mv -f "$F.eski" "$F"; die "Nginx ayarı geçersiz çıktı; eski hali geri yüklendi."; fi
      rm -f "$F.eski"
      systemctl reload nginx
      certbot_for nginx
      ;;
    apache)
      F=/etc/apache2/sites-available/$NAME.conf
      cp -a "$F" "$F.eski"
      a2dissite -q "$NAME-le-ssl" > /dev/null 2>&1 || true
      rm -f "/etc/apache2/sites-available/$NAME-le-ssl.conf"
      write_apache_site
      if ! apachectl configtest > /dev/null 2>&1; then mv -f "$F.eski" "$F"; die "Apache ayarı geçersiz çıktı; eski hali geri yüklendi."; fi
      rm -f "$F.eski"
      systemctl reload apache2
      certbot_for apache
      ;;
  esac
  ok "$DOMAIN → $NAME"

  if [ "$REDIRECT" != 1 ] && [ -n "$OLD_ZONE_ID" ]; then
    for id in $OLD_RECORD_IDS; do cf_api DELETE "/zones/$OLD_ZONE_ID/dns_records/$id" > /dev/null 2>&1 || warn "Eski DNS kaydı silinemedi ($id)."; done
    ok "Eski alan adının DNS kayıtları silindi"
    [ "$OLD_ZONE_CREATED" = 1 ] && echo "  Not: $OLD_DOMAIN alan adı Cloudflare hesabında kaldı; istersen Cloudflare'den silebilirsin."
  fi
  sed -i "s|^Description=.*|Description=Shop $NAME ($DOMAIN)|" "/etc/systemd/system/$NAME.service" && systemctl daemon-reload
  save_site

  echo
  bold "Alan adı değişti: https://$DOMAIN"
  [ "$REDIRECT" = 1 ] && echo "  https://$OLD_DOMAIN artık https://$DOMAIN adresine yönleniyor."
  echo "  Yönetim paneli:  https://$DOMAIN$ADMIN_PATH   (giriş bilgilerin aynı)"
  echo "  Panelde E-posta bildirimleri'ndeki gönderen adres eski alan adındaysa onu da değiştirmeyi unutma."
  nameserver_box
  exit 0
fi

# ---------- sunucu kurulumu (anahtarlar yoksa ya da --setup) ----------
if [ "$SETUP" = 1 ] || [ ! -f "$CRED" ]; then
  [ "$YES" = 1 ] && [ ! -f "$CRED" ] && die "Önce sunucu kurulumu gerekli: script'i --setup ile, terminalde çalıştır."
  server_setup
  echo
  confirm "Şimdi ilk siteyi kuralım mı?" || { echo "Site kurmak için istediğin zaman: yenisite"; offer_reboot; exit 0; }
  echo
fi

bold "Yeni site"
echo "Sunucundaki diğer sitelere dokunulmaz. Ne yapılacağı gösterilip başlamadan önce onay istenir."

# ---------- 2. sorular ----------
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
dns_plan
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
dns_plan_text
echo "  GitHub        : bu siteye salt okunur erişim anahtarı otomatik eklenecek"
if [ -z "$ZONE" ] && [ -z "$NEW_ZONE" ] && [ -n "$PUBLIC_IP" ] && [ "$DOMAIN_IP" != "$PUBLIC_IP" ]; then
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
for p in git curl ca-certificates sqlite3 xz-utils openssl jq; do dpkg -s "$p" > /dev/null 2>&1 || NEED+=("$p"); done
if [ ${#NEED[@]} -gt 0 ]; then
  apt-get "${APT_LOCK[@]}" update -qq
  DEBIAN_FRONTEND=noninteractive apt-get "${APT_LOCK[@]}" install -y -qq "${NEED[@]}" > /dev/null
fi
ok "Gerekli paketler hazır (sadece eksikler kuruldu; sistem paketleri güncellenmedi)"

# ---------- DNS (Cloudflare) ----------
dns_apply
CF_ZONE_CREATED=$([ -n "$NEW_ZONE" ] && echo 1 || echo 0)

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
GH_KEY_ID=''
if [ -n "$GITHUB_TOKEN" ] && ! as_app git ls-remote --exit-code "$REPO" HEAD > /dev/null 2>&1; then
  GH_KEY_ID=$(gh_api POST "/repos/$GITHUB_REPO/keys" "$(jq -nc --arg t "$NAME ($DOMAIN)" --arg k "$(cat "$KEY.pub")" '{title:$t,key:$k,read_only:true}')" | jq -r '.id // empty' || true)
  [ -n "$GH_KEY_ID" ] && ok "GitHub'a salt okunur anahtar eklendi" || warn "GitHub anahtarı otomatik eklenemedi; elle eklemen gerekecek."
  for _ in 1 2 3 4 5; do as_app git ls-remote --exit-code "$REPO" HEAD > /dev/null 2>&1 && break; sleep 2; done
fi
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
  DEBIAN_FRONTEND=noninteractive apt-get "${APT_LOCK[@]}" install -y -qq build-essential python3 > /dev/null
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
dns_wait_or_warn
case "$WEB" in
  none)
    DEBIAN_FRONTEND=noninteractive apt-get "${APT_LOCK[@]}" install -y -qq debian-keyring debian-archive-keyring apt-transport-https gnupg > /dev/null
    curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/gpg.key | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt > /etc/apt/sources.list.d/caddy-stable.list
    apt-get "${APT_LOCK[@]}" update -qq
    DEBIAN_FRONTEND=noninteractive apt-get "${APT_LOCK[@]}" install -y -qq caddy > /dev/null
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
    { dpkg -s certbot && dpkg -s python3-certbot-nginx; } > /dev/null 2>&1 || DEBIAN_FRONTEND=noninteractive apt-get "${APT_LOCK[@]}" install -y -qq certbot python3-certbot-nginx > /dev/null
    SITE=$(nginx_site_path)
    write_nginx_site
    if [ -d /etc/nginx/sites-enabled ]; then ln -sf "$SITE" "/etc/nginx/sites-enabled/$NAME"; fi
    if ! nginx -t > /dev/null 2>&1; then
      rm -f "$SITE" "/etc/nginx/sites-enabled/$NAME"
      die "Nginx ayarı geçersiz çıktı; eklediğim dosyayı geri aldım, diğer siteler etkilenmedi."
    fi
    systemctl reload nginx
    certbot_for nginx
    ;;
  apache)
    { dpkg -s certbot && dpkg -s python3-certbot-apache; } > /dev/null 2>&1 || DEBIAN_FRONTEND=noninteractive apt-get "${APT_LOCK[@]}" install -y -qq certbot python3-certbot-apache > /dev/null
    a2enmod -q proxy proxy_http headers > /dev/null
    SITE=/etc/apache2/sites-available/$NAME.conf
    write_apache_site
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

# Bu sunucuda sonraki mağazalar için kısa komut: yenisite (her seferinde en güncel kurulum script'ini indirir).
install_yenisite

# ---------- site kaydı ----------
save_site

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
nameserver_box
echo "  Servis günlüğü:     journalctl -u $NAME -f"
if [ -z "$ZONE" ] && [ -n "$PUBLIC_IP" ] && [ "$DOMAIN_IP" != "$PUBLIC_IP" ]; then
  echo
  warn "DNS henüz bu sunucuyu göstermiyor: A kaydını $PUBLIC_IP yap; HTTPS birkaç dakika içinde kendiliğinden gelir."
fi
offer_reboot
