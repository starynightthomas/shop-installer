# Mağaza sunucusu

Ubuntu/Debian bir sunucuyu, tek komutla yeni mağaza açılabilen bir sunucuya çevirir.

## 1. Sunucu kurulumu (bir kez)

```bash
curl -fsSL https://raw.githubusercontent.com/starynightthomas/shop-installer/main/install.sh | sudo bash
```

İki anahtar sorar (yazdıkların ekranda görünmez, sadece sunucuda root'un okuyabileceği bir dosyada saklanır):

- **Cloudflare API anahtarı** — dash.cloudflare.com → API Tokens → Create Token → Custom token
  - Permissions: `Zone · Zone · Edit` ve `Zone · DNS · Edit`
  - Zone Resources: `Include · All zones from an account · <hesabın>`
- **GitHub anahtarı** — github.com/settings/personal-access-tokens/new
  - Repository access: sadece mağaza deposu
  - Permissions → Repository → `Administration: Read and write`

Sonra `yenisite` komutu kurulur.

## 2. Yeni site

```bash
yenisite
```

Alan adını ve kurulum adını sorar, sonra hepsini kendisi yapar:

- Alan adı Cloudflare hesabında yoksa **ekler** ve sonunda alan adını aldığın firmada yazman gereken **nameserver'ları** gösterir
- DNS kayıtlarını açar, GitHub'a o sitenin salt okunur anahtarını ekler
- Mağazayı kendi klasörüne, kendi kullanıcısı / Node'u / servisiyle kurar; HTTPS'i alır (Caddy, Nginx veya Apache)
- Panelden güncelleme ve günlük yedek kurar
- Kurulum adresini (`https://alanadin.com/setup`) ve tek kullanımlık kurulum kodunu yazar

## Diğer komutlar

```bash
yenisite --list              # bu sunucudaki siteler ve Cloudflare durumu
yenisite --alanadi <ad>      # sitenin alan adını değiştirir: yeni alan adı Cloudflare'e eklenir, DNS ve HTTPS ayarlanır,
                             # nameserver'lar söylenir; eski adres istersen yeni adrese yönlenir
yenisite --uninstall <ad>    # siteyi kaldırır (önce /root'a son yedek; DNS kayıtları ve GitHub anahtarı da silinir)
yenisite --dry-run           # sadece planı gösterir
```

Sunucudaki diğer sitelere dokunulmaz. Mağazanın kodu gizli bir depoda durur; bu depo sadece kurulum script'ini içerir ve her sürümde otomatik güncellenir.
