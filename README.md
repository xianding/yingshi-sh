# DebInstall
常用一键安装脚本 - gemini编写


#安装DNS本地缓存
```bash
bash <(curl -Ls https://raw.githubusercontent.com/xianding/yingshi-sh/refs/heads/main/deb_dns_cache_install.sh)
```

#安装DNS本地缓存 + 禁用IPV6
```bash
bash <(curl -Ls https://raw.githubusercontent.com/xianding/yingshi-sh/refs/heads/main/deb_dns_not_ipv6.sh)
```
#sysctl 一键优化
```bash
bash <(curl -Ls https://raw.githubusercontent.com/xianding/yingshi-sh/refs/heads/main/sysctl_auto.sh)
```

#设置或修改swap
```bash
bash <(curl -Ls https://raw.githubusercontent.com/xianding/yingshi-sh/refs/heads/main/set_swap.sh)
```

#Realm
```bash
curl -L https://raw.githubusercontent.com/xianding/yingshi-sh/refs/heads/main/realm.sh -o realm.sh && chmod +x realm.sh && ./realm.sh
```
