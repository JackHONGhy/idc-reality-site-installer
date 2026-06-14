# IDC 双语官网一键安装教程

## 一键安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/JackHONGhy/idc-reality-site-installer/main/install.sh)
```

## 安装前准备

1. 准备一台 Ubuntu / Debian / CentOS / RHEL 服务器。
2. 将域名 `A` 记录解析到服务器公网 IP。
3. 确认服务器 `80` 和 `443` 端口已开放。
4. 使用 `root` 用户执行安装命令。

## 安装时需要填写

```text
请输入域名，例如 example.com：
请输入中文网站名称：
请输入英文网站名称：
请输入证书和联系邮箱：
请输入网站安装基础目录：
是否自动申请 Let's Encrypt SSL 证书：
```

## 安装完成后

脚本会输出：

```text
网站地址
中文页面
英文页面
状态页面
网站目录
Nginx 配置
证书目录
```

## 重新安装

再次执行一键安装命令即可。脚本会在覆盖 Nginx 配置前自动创建备份。
