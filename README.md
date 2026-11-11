# Mağaza kurulumu

Ubuntu/Debian bir sunucuya tek komutla mağaza kurar:

```bash
curl -fsSL https://raw.githubusercontent.com/starynightthomas/shop-installer/main/install.sh | sudo bash
```

Alan adı ve kurulum adı ekranda sorulur. Sunucudaki diğer sitelere dokunulmaz: mağaza kendi klasöründe, kendi kullanıcısı, kendi Node'u ve kendi servisiyle çalışır; mevcut Caddy / Nginx / Apache'ye sadece bu alan adı için ayrı bir dosya eklenir.

Kaldırmak için:

```bash
curl -fsSL https://raw.githubusercontent.com/starynightthomas/shop-installer/main/install.sh | sudo bash -s -- --uninstall <ad>
```

Mağazanın kodu gizli bir depoda durur; bu depo sadece kurulum script'ini içerir ve her sürümde otomatik güncellenir.
