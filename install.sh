#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="IDC 双语官网一键安装器"
DEFAULT_INSTALL_BASE="/var/www"
DEFAULT_REPO_NAME="idc-reality-site-installer"

red() { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
blue() { printf '\033[34m%s\033[0m\n' "$*"; }

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    red "请使用 root 用户执行安装脚本。"
    exit 1
  fi
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

prompt_required() {
  local var_name="$1"
  local prompt="$2"
  local value=""
  while [ -z "$value" ]; do
    read -r -p "$prompt" value
    value="$(printf '%s' "$value" | xargs)"
  done
  printf -v "$var_name" '%s' "$value"
}

prompt_default() {
  local var_name="$1"
  local prompt="$2"
  local default_value="$3"
  local value=""
  read -r -p "$prompt [$default_value]: " value
  value="$(printf '%s' "$value" | xargs)"
  if [ -z "$value" ]; then value="$default_value"; fi
  printf -v "$var_name" '%s' "$value"
}

prompt_yes_no() {
  local var_name="$1"
  local prompt="$2"
  local default_value="$3"
  local value=""
  local suffix="Y/n"
  if [ "$default_value" = "n" ]; then suffix="y/N"; fi
  read -r -p "$prompt [$suffix]: " value
  value="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]' | xargs)"
  if [ -z "$value" ]; then value="$default_value"; fi
  case "$value" in
    y|yes) printf -v "$var_name" '%s' "y" ;;
    *) printf -v "$var_name" '%s' "n" ;;
  esac
}

normalize_domain() {
  local value="$1"
  value="${value#http://}"
  value="${value#https://}"
  value="${value%%/*}"
  value="${value%%:*}"
  printf '%s' "$value" | tr '[:upper:]' '[:lower:]'
}

validate_domain() {
  local domain="$1"
  if ! printf '%s' "$domain" | grep -Eq '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$'; then
    red "域名格式不正确：$domain"
    exit 1
  fi
}

html_escape() {
  local s="$1"
  s="${s//&/&amp;}"
  s="${s//</&lt;}"
  s="${s//>/&gt;}"
  s="${s//\"/&quot;}"
  s="${s//\'/&#39;}"
  printf '%s' "$s"
}

install_packages() {
  blue "正在安装 Nginx、Certbot、OpenSSL、Curl..."
  if command_exists apt-get; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y nginx certbot openssl curl ca-certificates dnsutils
  elif command_exists dnf; then
    dnf install -y nginx certbot openssl curl ca-certificates bind-utils
  elif command_exists yum; then
    yum install -y epel-release || true
    yum install -y nginx certbot openssl curl ca-certificates bind-utils
  else
    red "当前系统暂不支持自动安装依赖，请使用 Debian/Ubuntu/CentOS/RHEL 系统。"
    exit 1
  fi

  systemctl enable nginx >/dev/null 2>&1 || true
  systemctl start nginx >/dev/null 2>&1 || true
}

detect_public_ip() {
  local ip=""
  ip="$(curl -4fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
  if [ -z "$ip" ]; then
    ip="$(curl -4fsS --max-time 8 https://ipv4.icanhazip.com 2>/dev/null | tr -d '\n' || true)"
  fi
  printf '%s' "$ip"
}

check_dns_hint() {
  local domain="$1"
  local public_ip="$2"
  local records=""
  if command_exists dig; then
    records="$(dig +short A "$domain" | tr '\n' ' ')"
  elif command_exists getent; then
    records="$(getent ahostsv4 "$domain" | awk '{print $1}' | sort -u | tr '\n' ' ')"
  fi

  if [ -z "$records" ]; then
    yellow "警告：没有查询到 $domain 的 A 记录。证书申请可能失败，请确认域名已解析到本机。"
    return
  fi

  if [ -n "$public_ip" ] && ! printf '%s' "$records" | grep -qw "$public_ip"; then
    yellow "警告：$domain 当前 A 记录为：$records"
    yellow "本机公网 IP 可能是：$public_ip"
    yellow "如果域名没有解析到本机，证书申请会失败。"
  else
    green "DNS 检查通过：$domain -> $records"
  fi
}

prepare_paths() {
  SITE_ROOT="${INSTALL_BASE%/}/${DOMAIN}"
  NGINX_CONF=""

  mkdir -p "$SITE_ROOT"
  mkdir -p "$SITE_ROOT/en" "$SITE_ROOT/en/legal" "$SITE_ROOT/en/status" "$SITE_ROOT/en/products" "$SITE_ROOT/en/login" "$SITE_ROOT/en/register" "$SITE_ROOT/en/console" "$SITE_ROOT/en/support" "$SITE_ROOT/en/docs" "$SITE_ROOT/en/announcements" "$SITE_ROOT/assets" "$SITE_ROOT/legal" "$SITE_ROOT/status" "$SITE_ROOT/products" "$SITE_ROOT/login" "$SITE_ROOT/register" "$SITE_ROOT/console" "$SITE_ROOT/support" "$SITE_ROOT/docs" "$SITE_ROOT/announcements" "$SITE_ROOT/.well-known"

  if [ -d /etc/nginx/sites-available ] && [ -d /etc/nginx/sites-enabled ]; then
    NGINX_CONF="/etc/nginx/sites-available/${DOMAIN}.conf"
    NGINX_LINK="/etc/nginx/sites-enabled/${DOMAIN}.conf"
  else
    mkdir -p /etc/nginx/conf.d
    NGINX_CONF="/etc/nginx/conf.d/${DOMAIN}.conf"
    NGINX_LINK=""
  fi

  if [ -f "$NGINX_CONF" ]; then
    cp -a "$NGINX_CONF" "${NGINX_CONF}.bak-$(date +%Y%m%d%H%M%S)"
  fi
}

render_assets() {
  cat > "$SITE_ROOT/assets/site.css" <<'EOF'
:root {
  color-scheme: light;
  --ink: #101828;
  --muted: #667085;
  --line: #d9e2ec;
  --soft: #f5f7fb;
  --panel: #ffffff;
  --primary: #1463ff;
  --primary-dark: #0b3ea8;
  --accent: #00a68a;
  --warning: #f5a524;
}
* { box-sizing: border-box; }
html { scroll-behavior: smooth; }
body {
  margin: 0;
  font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", "PingFang SC", "Microsoft YaHei", sans-serif;
  color: var(--ink);
  background: var(--soft);
  line-height: 1.6;
}
a { color: inherit; text-decoration: none; }
.container { width: min(1180px, calc(100% - 32px)); margin: 0 auto; }
.topbar {
  background: #0d1b2f;
  color: rgba(255,255,255,.82);
  font-size: 13px;
}
.topbar .container { display: flex; justify-content: space-between; gap: 16px; padding: 8px 0; flex-wrap: wrap; }
.nav {
  position: sticky;
  top: 0;
  z-index: 20;
  background: rgba(255,255,255,.92);
  backdrop-filter: blur(14px);
  border-bottom: 1px solid rgba(16,24,40,.08);
}
.nav-inner { display: flex; align-items: center; justify-content: space-between; height: 72px; gap: 18px; }
.brand { display: flex; align-items: center; gap: 12px; font-weight: 800; letter-spacing: .2px; }
.brand-mark {
  width: 38px; height: 38px; border-radius: 10px;
  background: linear-gradient(135deg, var(--primary), var(--accent));
  display: grid; place-items: center; color: white; font-weight: 900;
}
.nav-links { display: flex; align-items: center; gap: 22px; color: #344054; font-size: 14px; }
.nav-links a:hover { color: var(--primary); }
.lang { display: inline-flex; border: 1px solid var(--line); border-radius: 999px; overflow: hidden; background: white; }
.lang a { padding: 6px 10px; font-size: 13px; color: #475467; }
.lang a.active { background: var(--primary); color: white; }
.hero {
  position: relative;
  overflow: hidden;
  background:
    linear-gradient(135deg, rgba(13,27,47,.96), rgba(20,99,255,.72)),
    radial-gradient(circle at 80% 20%, rgba(0,166,138,.45), transparent 30%);
  color: white;
}
.hero .container { display: grid; grid-template-columns: 1.12fr .88fr; gap: 48px; align-items: center; min-height: 610px; padding: 72px 0; }
.eyebrow { display: inline-flex; align-items: center; gap: 8px; color: #b9fff2; font-size: 14px; font-weight: 700; }
.eyebrow::before { content: ""; width: 8px; height: 8px; border-radius: 999px; background: #26e0b7; box-shadow: 0 0 18px #26e0b7; }
h1 { font-size: clamp(42px, 6vw, 76px); line-height: 1.02; margin: 18px 0 22px; letter-spacing: 0; }
.hero p { color: rgba(255,255,255,.82); font-size: 18px; max-width: 660px; }
.hero-actions { display: flex; gap: 14px; flex-wrap: wrap; margin-top: 30px; }
.btn {
  display: inline-flex; align-items: center; justify-content: center;
  min-height: 44px; border-radius: 8px; padding: 0 18px;
  font-weight: 700; font-size: 14px;
}
.btn.primary { background: white; color: var(--primary-dark); }
.btn.secondary { border: 1px solid rgba(255,255,255,.34); color: white; }
.auth-card .btn.primary, .contact-box .btn.primary, footer .btn.primary { background: var(--primary); color: white; }
.infra-card {
  background: rgba(255,255,255,.1);
  border: 1px solid rgba(255,255,255,.2);
  border-radius: 16px;
  padding: 22px;
  box-shadow: 0 24px 80px rgba(0,0,0,.22);
}
.rack {
  display: grid; gap: 10px;
  background: rgba(0,0,0,.24);
  border-radius: 12px;
  padding: 14px;
}
.rack-row { height: 34px; border-radius: 6px; background: linear-gradient(90deg, rgba(255,255,255,.14), rgba(255,255,255,.05)); border: 1px solid rgba(255,255,255,.12); display: flex; align-items: center; padding: 0 10px; gap: 8px; }
.dot { width: 7px; height: 7px; border-radius: 50%; background: #26e0b7; box-shadow: 0 0 12px #26e0b7; }
.metrics { display: grid; grid-template-columns: repeat(3, 1fr); gap: 12px; margin-top: 14px; }
.metric { background: rgba(255,255,255,.1); border-radius: 10px; padding: 12px; }
.metric strong { display: block; font-size: 20px; }
section { padding: 76px 0; }
.section-head { display: flex; align-items: end; justify-content: space-between; gap: 24px; margin-bottom: 30px; }
h2 { font-size: clamp(28px, 4vw, 44px); line-height: 1.1; margin: 0; letter-spacing: 0; }
.section-head p { max-width: 620px; color: var(--muted); margin: 0; }
.grid-3 { display: grid; grid-template-columns: repeat(3, 1fr); gap: 18px; }
.grid-2 { display: grid; grid-template-columns: repeat(2, 1fr); gap: 18px; }
.card {
  background: var(--panel);
  border: 1px solid var(--line);
  border-radius: 12px;
  padding: 24px;
  box-shadow: 0 10px 30px rgba(16,24,40,.04);
}
.card h3 { margin: 0 0 10px; font-size: 19px; }
.card p { margin: 0; color: var(--muted); }
.list { display: grid; gap: 12px; margin-top: 18px; color: #344054; }
.list span { display: flex; gap: 10px; align-items: flex-start; }
.list span::before { content: ""; width: 8px; height: 8px; margin-top: 8px; border-radius: 50%; background: var(--accent); flex: 0 0 auto; }
.band { background: #0d1b2f; color: white; }
.band .card { background: rgba(255,255,255,.07); border-color: rgba(255,255,255,.16); box-shadow: none; }
.band .card p, .band .section-head p { color: rgba(255,255,255,.72); }
.status-pill { display: inline-flex; align-items: center; gap: 8px; padding: 8px 12px; border-radius: 999px; background: #e9fbf7; color: #027a62; font-weight: 800; font-size: 13px; }
.status-pill::before { content: ""; width: 8px; height: 8px; border-radius: 50%; background: #12b886; }
.contact-box { display: grid; grid-template-columns: 1fr auto; gap: 20px; align-items: center; background: white; border: 1px solid var(--line); border-radius: 14px; padding: 28px; }
.spec-table { width: 100%; border-collapse: collapse; overflow: hidden; border-radius: 12px; background: white; border: 1px solid var(--line); }
.spec-table th, .spec-table td { padding: 14px 16px; border-bottom: 1px solid var(--line); text-align: left; }
.spec-table th { background: #eef3fb; color: #344054; font-size: 13px; text-transform: uppercase; }
.spec-table tr:last-child td { border-bottom: 0; }
.notice-list { display: grid; gap: 12px; }
.notice { display: flex; justify-content: space-between; gap: 16px; padding: 14px 0; border-bottom: 1px solid var(--line); color: #344054; }
.notice:last-child { border-bottom: 0; }
.auth-wrap { min-height: calc(100vh - 160px); display: grid; place-items: center; padding: 56px 0; }
.auth-card { width: min(460px, calc(100vw - 32px)); background: white; border: 1px solid var(--line); border-radius: 14px; padding: 28px; box-shadow: 0 18px 60px rgba(16,24,40,.08); }
.field { display: grid; gap: 8px; margin-top: 16px; font-size: 14px; font-weight: 700; }
.field input, .field textarea { width: 100%; min-height: 44px; border: 1px solid var(--line); border-radius: 8px; padding: 10px 12px; font: inherit; }
.field textarea { min-height: 110px; resize: vertical; }
.console-shell { display: grid; grid-template-columns: 240px 1fr; gap: 22px; align-items: start; }
.console-nav { background: white; border: 1px solid var(--line); border-radius: 12px; padding: 14px; display: grid; gap: 6px; }
.console-nav span { padding: 10px 12px; border-radius: 8px; color: #475467; }
.console-nav span.active { background: #eef4ff; color: var(--primary-dark); font-weight: 800; }
.kbd { display: inline-flex; padding: 2px 7px; border: 1px solid var(--line); border-radius: 6px; background: #f8fafc; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 12px; }
footer { padding: 32px 0; border-top: 1px solid var(--line); color: var(--muted); font-size: 14px; background: white; }
footer .container { display: flex; justify-content: space-between; gap: 16px; flex-wrap: wrap; }
@media (max-width: 900px) {
  .hero .container, .grid-3, .grid-2, .contact-box, .console-shell { grid-template-columns: 1fr; }
  .nav-inner { height: auto; padding: 14px 0; align-items: flex-start; }
  .nav-links { flex-wrap: wrap; gap: 12px; }
  .metrics { grid-template-columns: 1fr; }
  section { padding: 52px 0; }
}
EOF

  cat > "$SITE_ROOT/assets/site.js" <<'EOF'
(() => {
  const year = document.querySelector('[data-year]');
  if (year) year.textContent = new Date().getFullYear();
  document.querySelectorAll('[data-static-form]').forEach((form) => {
    form.addEventListener('submit', (event) => {
      event.preventDefault();
      const target = form.querySelector('[data-form-message]');
      if (target) target.textContent = form.getAttribute('data-success') || 'Request received. Please contact support for the next step.';
    });
  });
})();
EOF
}

render_site() {
  local brand_cn_html brand_en_html domain_html email_html
  brand_cn_html="$(html_escape "$BRAND_CN")"
  brand_en_html="$(html_escape "$BRAND_EN")"
  domain_html="$(html_escape "$DOMAIN")"
  email_html="$(html_escape "$CONTACT_EMAIL")"

  render_assets

  cat > "$SITE_ROOT/index.html" <<EOF
<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${brand_cn_html} - IDC 与云基础设施服务</title>
  <meta name="description" content="${brand_cn_html} 提供云服务器、独立服务器、机柜托管、网络接入和企业级运维支持。">
  <link rel="stylesheet" href="/assets/site.css">
</head>
<body>
  <div class="topbar"><div class="container"><span>企业级 IDC、网络与云基础设施服务</span><span>7x24 运维支持 · SLA 保障 · 多线路接入</span></div></div>
  <nav class="nav"><div class="container nav-inner">
    <a class="brand" href="/"><span class="brand-mark">I</span><span>${brand_cn_html}</span></a>
    <div class="nav-links">
      <a href="/products/cloud.html">产品</a><a href="/docs/">文档</a><a href="/support/">支持</a><a href="/status/">状态</a><a href="/login/">登录</a>
      <span class="lang"><a class="active" href="/">中文</a><a href="/en/">English</a></span>
    </div>
  </div></nav>
  <header class="hero"><div class="container">
    <div>
      <span class="eyebrow">Reliable Infrastructure</span>
      <h1>面向企业业务的稳定云与 IDC 基础设施</h1>
      <p>${brand_cn_html} 为企业提供云服务器、独立服务器、机柜托管、BGP 网络接入和持续运维支持，帮助业务在安全、稳定、可扩展的环境中运行。</p>
      <div class="hero-actions"><a class="btn primary" href="/register/">获取方案</a><a class="btn secondary" href="/login/">客户登录</a></div>
    </div>
    <div class="infra-card">
      <div class="rack">
        <div class="rack-row"><span class="dot"></span> Compute Cluster A</div>
        <div class="rack-row"><span class="dot"></span> Storage Pool NVMe</div>
        <div class="rack-row"><span class="dot"></span> Border Gateway</div>
        <div class="rack-row"><span class="dot"></span> Monitoring & Backup</div>
      </div>
      <div class="metrics"><div class="metric"><strong>99.9%</strong><span>SLA</span></div><div class="metric"><strong>24/7</strong><span>NOC</span></div><div class="metric"><strong>10G+</strong><span>Uplink</span></div></div>
    </div>
  </div></header>
  <main>
    <section id="services"><div class="container">
      <div class="section-head"><h2>基础设施服务</h2><p>从轻量云服务器到独立物理资源，为不同阶段的业务提供清晰、可靠的部署选项。</p></div>
      <div class="grid-3">
        <article class="card"><h3>云服务器</h3><p>弹性计算实例、快照备份、独立公网 IP 和按需扩容。</p><div class="list"><span>适合网站、API、业务后台</span><span>支持快速交付和资源升级</span></div></article>
        <article class="card"><h3>独立服务器</h3><p>独享 CPU、内存、磁盘和网络资源，适合高负载业务。</p><div class="list"><span>可选 NVMe 与大容量存储</span><span>硬件监控与远程协助</span></div></article>
        <article class="card"><h3>机柜托管</h3><p>标准机柜、电力、带宽、IP 资源和现场运维支持。</p><div class="list"><span>规范化上架与资产记录</span><span>远程重启与工单支持</span></div></article>
      </div>
    </div></section>
    <section><div class="container">
      <div class="section-head"><h2>常用交付规格</h2><p>公开展示常见配置，让访客能判断这是一家真实的基础设施服务网站，而不是空白落地页。</p></div>
      <table class="spec-table">
        <thead><tr><th>产品</th><th>计算资源</th><th>存储</th><th>网络</th><th>适用场景</th></tr></thead>
        <tbody>
          <tr><td>云服务器 S2</td><td>2 vCPU / 4 GB</td><td>60 GB NVMe</td><td>1 Gbps shared</td><td>企业官网、轻量 API</td></tr>
          <tr><td>云服务器 C4</td><td>4 vCPU / 8 GB</td><td>120 GB NVMe</td><td>1 Gbps shared</td><td>业务后台、数据库从库</td></tr>
          <tr><td>独立服务器 D1</td><td>8C / 32 GB</td><td>2 x 960 GB SSD</td><td>10 TB transfer</td><td>高负载应用、私有部署</td></tr>
        </tbody>
      </table>
    </div></section>
    <section id="network" class="band"><div class="container">
      <div class="section-head"><h2>网络与安全</h2><p>面向生产业务设计的网络接入、监控和基础安全策略。</p></div>
      <div class="grid-3">
        <article class="card"><h3>多线路接入</h3><p>BGP 与优质国际线路可选，按业务区域优化访问路径。</p></article>
        <article class="card"><h3>边界监控</h3><p>节点可用性、延迟、丢包和带宽趋势持续监控。</p></article>
        <article class="card"><h3>基础防护</h3><p>安全响应、访问控制、日志留存和异常流量告警。</p></article>
      </div>
    </div></section>
    <section id="sla"><div class="container">
      <div class="section-head"><h2>服务承诺</h2><p>透明的服务等级、明确的响应流程和可持续的运维保障。</p></div>
      <div class="grid-2">
        <article class="card"><span class="status-pill">Operational</span><h3>平台状态</h3><p>核心网络、计算资源和客户支持服务当前运行正常。</p></article>
        <article class="card"><h3>响应流程</h3><p>紧急故障优先响应，常规需求通过工单系统跟踪，所有变更保留操作记录。</p></article>
      </div>
    </div></section>
    <section><div class="container">
      <div class="section-head"><h2>客户门户</h2><p>客户可以通过门户查看服务、账单、工单、网络状态和维护公告。演示页面不会采集真实密码。</p></div>
      <div class="grid-3">
        <article class="card"><h3>服务管理</h3><p>查看实例状态、到期时间、带宽用量和基础资源信息。</p></article>
        <article class="card"><h3>工单支持</h3><p>提交故障、变更、续费、网络排查和远程协助请求。</p></article>
        <article class="card"><h3>维护公告</h3><p>展示线路维护、机房变更、证书续期和安全通知。</p></article>
      </div>
    </div></section>
    <section><div class="container">
      <div class="section-head"><h2>最新公告</h2><p>正常运营的网站通常会展示清晰的维护和服务通知。</p></div>
      <div class="card notice-list">
        <div class="notice"><span>核心网络例行巡检完成，未发现异常。</span><strong>2026-06-14</strong></div>
        <div class="notice"><span>新增云服务器 NVMe 存储池，适合数据库和低延迟业务。</span><strong>2026-06-08</strong></div>
        <div class="notice"><span>客户门户工单分类已更新，支持网络、账务、硬件和系统协助。</span><strong>2026-06-01</strong></div>
      </div>
    </div></section>
    <section id="contact"><div class="container">
      <div class="contact-box"><div><h2>需要定制方案？</h2><p>请发送你的业务区域、预算、带宽和资源需求，我们会给出合适的部署建议。</p></div><a class="btn primary" href="mailto:${email_html}">${email_html}</a></div>
    </div></section>
  </main>
  <footer><div class="container"><span>© <span data-year></span> ${brand_cn_html}. All rights reserved.</span><span><a href="/legal/terms.html">服务条款</a> · <a href="/legal/privacy.html">隐私政策</a> · <a href="/en/">English</a></span></div></footer>
  <script src="/assets/site.js"></script>
</body>
</html>
EOF

  cat > "$SITE_ROOT/en/index.html" <<EOF
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${brand_en_html} - IDC and Cloud Infrastructure</title>
  <meta name="description" content="${brand_en_html} provides cloud servers, dedicated servers, colocation, network access and managed operations.">
  <link rel="stylesheet" href="/assets/site.css">
</head>
<body>
  <div class="topbar"><div class="container"><span>Enterprise IDC, network and cloud infrastructure</span><span>24/7 operations · SLA backed · Multi-carrier connectivity</span></div></div>
  <nav class="nav"><div class="container nav-inner">
    <a class="brand" href="/en/"><span class="brand-mark">I</span><span>${brand_en_html}</span></a>
    <div class="nav-links">
      <a href="/en/products/cloud.html">Products</a><a href="/en/docs/">Docs</a><a href="/en/support/">Support</a><a href="/en/status/">Status</a><a href="/en/login/">Login</a>
      <span class="lang"><a href="/">中文</a><a class="active" href="/en/">English</a></span>
    </div>
  </div></nav>
  <header class="hero"><div class="container">
    <div>
      <span class="eyebrow">Reliable Infrastructure</span>
      <h1>Stable cloud and IDC infrastructure for production workloads</h1>
      <p>${brand_en_html} delivers cloud servers, dedicated servers, colocation, BGP connectivity and managed support for teams that need predictable infrastructure.</p>
      <div class="hero-actions"><a class="btn primary" href="/en/register/">Request a plan</a><a class="btn secondary" href="/en/login/">Client login</a></div>
    </div>
    <div class="infra-card">
      <div class="rack">
        <div class="rack-row"><span class="dot"></span> Compute Cluster A</div>
        <div class="rack-row"><span class="dot"></span> NVMe Storage Pool</div>
        <div class="rack-row"><span class="dot"></span> Border Gateway</div>
        <div class="rack-row"><span class="dot"></span> Monitoring & Backup</div>
      </div>
      <div class="metrics"><div class="metric"><strong>99.9%</strong><span>SLA</span></div><div class="metric"><strong>24/7</strong><span>NOC</span></div><div class="metric"><strong>10G+</strong><span>Uplink</span></div></div>
    </div>
  </div></header>
  <main>
    <section id="services"><div class="container">
      <div class="section-head"><h2>Infrastructure Services</h2><p>Clear deployment choices from elastic virtual machines to dedicated hardware resources.</p></div>
      <div class="grid-3">
        <article class="card"><h3>Cloud Servers</h3><p>Elastic compute, snapshots, dedicated public IPs and practical scaling options.</p><div class="list"><span>Websites, APIs and business systems</span><span>Fast delivery and resource upgrades</span></div></article>
        <article class="card"><h3>Dedicated Servers</h3><p>Dedicated CPU, memory, disks and network resources for demanding workloads.</p><div class="list"><span>NVMe and high-capacity storage options</span><span>Hardware monitoring and remote support</span></div></article>
        <article class="card"><h3>Colocation</h3><p>Rack space, power, bandwidth, IP resources and remote-hands support.</p><div class="list"><span>Structured deployment and asset tracking</span><span>Remote reboot and ticket support</span></div></article>
      </div>
    </div></section>
    <section><div class="container">
      <div class="section-head"><h2>Common Delivery Profiles</h2><p>Clear public profiles help visitors understand the available infrastructure options.</p></div>
      <table class="spec-table">
        <thead><tr><th>Product</th><th>Compute</th><th>Storage</th><th>Network</th><th>Use case</th></tr></thead>
        <tbody>
          <tr><td>Cloud Server S2</td><td>2 vCPU / 4 GB</td><td>60 GB NVMe</td><td>1 Gbps shared</td><td>Websites and lightweight APIs</td></tr>
          <tr><td>Cloud Server C4</td><td>4 vCPU / 8 GB</td><td>120 GB NVMe</td><td>1 Gbps shared</td><td>Business systems and database replicas</td></tr>
          <tr><td>Dedicated Server D1</td><td>8C / 32 GB</td><td>2 x 960 GB SSD</td><td>10 TB transfer</td><td>High-load apps and private deployments</td></tr>
        </tbody>
      </table>
    </div></section>
    <section id="network" class="band"><div class="container">
      <div class="section-head"><h2>Network and Security</h2><p>Connectivity, monitoring and baseline security controls designed for production services.</p></div>
      <div class="grid-3">
        <article class="card"><h3>Multi-carrier Access</h3><p>BGP and premium international routes can be selected by target region.</p></article>
        <article class="card"><h3>Edge Monitoring</h3><p>Availability, latency, packet loss and bandwidth trends are continuously tracked.</p></article>
        <article class="card"><h3>Baseline Protection</h3><p>Operational response, access control, log retention and abnormal traffic alerts.</p></article>
      </div>
    </div></section>
    <section id="sla"><div class="container">
      <div class="section-head"><h2>Service Commitment</h2><p>Transparent service levels, clear response workflows and sustainable operations.</p></div>
      <div class="grid-2">
        <article class="card"><span class="status-pill">Operational</span><h3>Platform Status</h3><p>Core network, compute resources and customer support are operating normally.</p></article>
        <article class="card"><h3>Response Workflow</h3><p>Urgent incidents are prioritized, regular requests are tracked by tickets, and changes are logged.</p></article>
      </div>
    </div></section>
    <section><div class="container">
      <div class="section-head"><h2>Client Portal</h2><p>Customers can review services, billing, tickets, network status and maintenance notices. Demo pages do not collect real passwords.</p></div>
      <div class="grid-3">
        <article class="card"><h3>Service Management</h3><p>Review instance status, expiration dates, bandwidth usage and resource details.</p></article>
        <article class="card"><h3>Ticket Support</h3><p>Submit incident, change, billing, network and remote-hands requests.</p></article>
        <article class="card"><h3>Maintenance Notices</h3><p>Publish route maintenance, facility changes, certificate renewals and security notices.</p></article>
      </div>
    </div></section>
    <section><div class="container">
      <div class="section-head"><h2>Latest Notices</h2><p>A real operations website should show service updates and maintenance history.</p></div>
      <div class="card notice-list">
        <div class="notice"><span>Core network routine inspection completed with no abnormalities.</span><strong>2026-06-14</strong></div>
        <div class="notice"><span>New NVMe storage pool is available for database and low-latency workloads.</span><strong>2026-06-08</strong></div>
        <div class="notice"><span>Client portal ticket categories now include network, billing, hardware and system assistance.</span><strong>2026-06-01</strong></div>
      </div>
    </div></section>
    <section id="contact"><div class="container">
      <div class="contact-box"><div><h2>Need a custom plan?</h2><p>Send your target regions, budget, bandwidth and resource requirements. We will recommend a practical deployment plan.</p></div><a class="btn primary" href="mailto:${email_html}">${email_html}</a></div>
    </div></section>
  </main>
  <footer><div class="container"><span>© <span data-year></span> ${brand_en_html}. All rights reserved.</span><span><a href="/en/legal/terms.html">Terms</a> · <a href="/en/legal/privacy.html">Privacy</a> · <a href="/">中文</a></span></div></footer>
  <script src="/assets/site.js"></script>
</body>
</html>
EOF

  cat > "$SITE_ROOT/legal/terms.html" <<EOF
<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>服务条款 - ${brand_cn_html}</title><link rel="stylesheet" href="/assets/site.css"></head><body><nav class="nav"><div class="container nav-inner"><a class="brand" href="/"><span class="brand-mark">I</span><span>${brand_cn_html}</span></a><div class="nav-links"><a href="/">首页</a><a href="/en/">English</a></div></div></nav><section><div class="container"><h1>服务条款</h1><div class="card"><p>客户应合法、合规使用本网站展示的基础设施服务，不得用于垃圾邮件、恶意扫描、攻击、侵权或其他违反适用法律法规的行为。</p><p>服务交付、续费、退款、变更和故障处理以双方确认的订单、合同或工单记录为准。</p></div></div></section><footer><div class="container"><span>© <span data-year></span> ${brand_cn_html}</span><span><a href="/legal/privacy.html">隐私政策</a></span></div></footer><script src="/assets/site.js"></script></body></html>
EOF

  cat > "$SITE_ROOT/en/legal/terms.html" <<EOF
<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Terms of Service - ${brand_en_html}</title><link rel="stylesheet" href="/assets/site.css"></head><body><nav class="nav"><div class="container nav-inner"><a class="brand" href="/en/"><span class="brand-mark">I</span><span>${brand_en_html}</span></a><div class="nav-links"><a href="/en/">Home</a><a href="/legal/terms.html">中文</a></div></div></nav><section><div class="container"><h1>Terms of Service</h1><div class="card"><p>Customers must use the infrastructure services described on this website lawfully and must not use them for spam, malicious scanning, attacks, infringement or other activities prohibited by applicable laws and regulations.</p><p>Service delivery, renewal, refund, change requests and incident handling are governed by confirmed orders, contracts or ticket records.</p></div></div></section><footer><div class="container"><span>© <span data-year></span> ${brand_en_html}</span><span><a href="/en/legal/privacy.html">Privacy Policy</a></span></div></footer><script src="/assets/site.js"></script></body></html>
EOF

  cat > "$SITE_ROOT/legal/privacy.html" <<EOF
<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>隐私政策 - ${brand_cn_html}</title><link rel="stylesheet" href="/assets/site.css"></head><body><nav class="nav"><div class="container nav-inner"><a class="brand" href="/"><span class="brand-mark">I</span><span>${brand_cn_html}</span></a><div class="nav-links"><a href="/">首页</a><a href="/en/">English</a></div></div></nav><section><div class="container"><h1>隐私政策</h1><div class="card"><p>我们仅在业务沟通、服务交付、账务处理和安全运营所需范围内处理客户信息。</p><p>如需咨询数据处理或删除请求，请通过 ${email_html} 联系我们。</p></div></div></section><footer><div class="container"><span>© <span data-year></span> ${brand_cn_html}</span><span><a href="/legal/terms.html">服务条款</a></span></div></footer><script src="/assets/site.js"></script></body></html>
EOF

  cat > "$SITE_ROOT/en/legal/privacy.html" <<EOF
<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Privacy Policy - ${brand_en_html}</title><link rel="stylesheet" href="/assets/site.css"></head><body><nav class="nav"><div class="container nav-inner"><a class="brand" href="/en/"><span class="brand-mark">I</span><span>${brand_en_html}</span></a><div class="nav-links"><a href="/en/">Home</a><a href="/legal/privacy.html">中文</a></div></div></nav><section><div class="container"><h1>Privacy Policy</h1><div class="card"><p>We process customer information only as needed for business communication, service delivery, billing and security operations.</p><p>For data processing questions or deletion requests, please contact us at ${email_html}.</p></div></div></section><footer><div class="container"><span>© <span data-year></span> ${brand_en_html}</span><span><a href="/en/legal/terms.html">Terms of Service</a></span></div></footer><script src="/assets/site.js"></script></body></html>
EOF

  cat > "$SITE_ROOT/status/index.html" <<EOF
<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>服务状态 - ${brand_cn_html}</title><link rel="stylesheet" href="/assets/site.css"></head><body><nav class="nav"><div class="container nav-inner"><a class="brand" href="/"><span class="brand-mark">I</span><span>${brand_cn_html}</span></a><div class="nav-links"><a href="/">首页</a><a href="/en/">English</a></div></div></nav><section><div class="container"><h1>服务状态</h1><div class="grid-3"><div class="card"><span class="status-pill">Operational</span><h3>核心网络</h3><p>运行正常</p></div><div class="card"><span class="status-pill">Operational</span><h3>计算资源</h3><p>运行正常</p></div><div class="card"><span class="status-pill">Operational</span><h3>客户支持</h3><p>运行正常</p></div></div></div></section><footer><div class="container"><span>© <span data-year></span> ${brand_cn_html}</span><span>${domain_html}</span></div></footer><script src="/assets/site.js"></script></body></html>
EOF

  cat > "$SITE_ROOT/en/status/index.html" <<EOF
<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Service Status - ${brand_en_html}</title><link rel="stylesheet" href="/assets/site.css"></head><body><nav class="nav"><div class="container nav-inner"><a class="brand" href="/en/"><span class="brand-mark">I</span><span>${brand_en_html}</span></a><div class="nav-links"><a href="/en/">Home</a><a href="/status/">中文</a></div></div></nav><section><div class="container"><h1>Service Status</h1><div class="grid-3"><div class="card"><span class="status-pill">Operational</span><h3>Core Network</h3><p>Operating normally</p></div><div class="card"><span class="status-pill">Operational</span><h3>Compute Resources</h3><p>Operating normally</p></div><div class="card"><span class="status-pill">Operational</span><h3>Customer Support</h3><p>Operating normally</p></div></div></div></section><footer><div class="container"><span>© <span data-year></span> ${brand_en_html}</span><span>${domain_html}</span></div></footer><script src="/assets/site.js"></script></body></html>
EOF

  cat > "$SITE_ROOT/products/cloud.html" <<EOF
<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>云服务器 - ${brand_cn_html}</title><link rel="stylesheet" href="/assets/site.css"></head><body><nav class="nav"><div class="container nav-inner"><a class="brand" href="/"><span class="brand-mark">I</span><span>${brand_cn_html}</span></a><div class="nav-links"><a href="/products/cloud.html">云服务器</a><a href="/products/dedicated.html">独立服务器</a><a href="/products/colocation.html">托管</a><a href="/login/">登录</a><a href="/en/products/cloud.html">English</a></div></div></nav><section><div class="container"><div class="section-head"><h1>云服务器</h1><p>适合企业官网、业务后台、API 服务、轻量数据库和持续集成环境。</p></div><table class="spec-table"><thead><tr><th>型号</th><th>CPU</th><th>内存</th><th>系统盘</th><th>带宽</th><th>交付</th></tr></thead><tbody><tr><td>S2</td><td>2 vCPU</td><td>4 GB</td><td>60 GB NVMe</td><td>1 Gbps shared</td><td>15 分钟内</td></tr><tr><td>C4</td><td>4 vCPU</td><td>8 GB</td><td>120 GB NVMe</td><td>1 Gbps shared</td><td>15 分钟内</td></tr><tr><td>M8</td><td>8 vCPU</td><td>16 GB</td><td>240 GB NVMe</td><td>2 Gbps shared</td><td>按需开通</td></tr></tbody></table><div class="grid-3" style="margin-top:18px"><div class="card"><h3>镜像支持</h3><p>Ubuntu、Debian、AlmaLinux、Rocky Linux 与 Windows Server 可选。</p></div><div class="card"><h3>备份策略</h3><p>支持快照、周期备份和迁移窗口安排。</p></div><div class="card"><h3>网络选项</h3><p>可选独立 IPv4、IPv6、BGP 与固定带宽方案。</p></div></div></div></section><footer><div class="container"><span>© <span data-year></span> ${brand_cn_html}</span><span><a href="/register/">申请开通</a></span></div></footer><script src="/assets/site.js"></script></body></html>
EOF

  cat > "$SITE_ROOT/products/dedicated.html" <<EOF
<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>独立服务器 - ${brand_cn_html}</title><link rel="stylesheet" href="/assets/site.css"></head><body><nav class="nav"><div class="container nav-inner"><a class="brand" href="/"><span class="brand-mark">I</span><span>${brand_cn_html}</span></a><div class="nav-links"><a href="/products/cloud.html">云服务器</a><a href="/products/dedicated.html">独立服务器</a><a href="/support/">支持</a><a href="/en/products/dedicated.html">English</a></div></div></nav><section><div class="container"><div class="section-head"><h1>独立服务器</h1><p>独享硬件资源，适合数据库、虚拟化、游戏服务、私有部署和高并发业务。</p></div><div class="grid-3"><div class="card"><h3>D1 标准型</h3><p>8C / 32 GB / 2 x SSD，适合业务独立部署。</p></div><div class="card"><h3>D2 性能型</h3><p>16C / 64 GB / NVMe，可承载高并发与低延迟任务。</p></div><div class="card"><h3>定制型</h3><p>按 CPU、内存、磁盘、IP 和带宽需求定制。</p></div></div><section style="padding-bottom:0"><div class="card"><h3>交付流程</h3><div class="list"><span>确认配置、线路、IP 数量和交付时间</span><span>完成硬件检测、系统安装和网络连通性测试</span><span>交付资产信息、远程管理方式和维护窗口</span></div></div></section></div></section><footer><div class="container"><span>© <span data-year></span> ${brand_cn_html}</span><span><a href="/register/">咨询配置</a></span></div></footer><script src="/assets/site.js"></script></body></html>
EOF

  cat > "$SITE_ROOT/products/colocation.html" <<EOF
<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>机柜托管 - ${brand_cn_html}</title><link rel="stylesheet" href="/assets/site.css"></head><body><nav class="nav"><div class="container nav-inner"><a class="brand" href="/"><span class="brand-mark">I</span><span>${brand_cn_html}</span></a><div class="nav-links"><a href="/products/cloud.html">云服务器</a><a href="/products/colocation.html">机柜托管</a><a href="/status/">状态</a><a href="/en/products/colocation.html">English</a></div></div></nav><section><div class="container"><div class="section-head"><h1>机柜托管</h1><p>提供上架、布线、电力、带宽、IP、远程协助和资产记录服务。</p></div><div class="grid-3"><div class="card"><h3>1U / 2U 托管</h3><p>适合少量自有服务器上架和远程维护。</p></div><div class="card"><h3>半柜 / 整柜</h3><p>适合规模化部署、独立交换设备和专属网络规划。</p></div><div class="card"><h3>远程协助</h3><p>支持电源重启、线缆检查、硬盘更换和现场拍照记录。</p></div></div></div></section><footer><div class="container"><span>© <span data-year></span> ${brand_cn_html}</span><span><a href="/support/">联系 NOC</a></span></div></footer><script src="/assets/site.js"></script></body></html>
EOF

  cat > "$SITE_ROOT/login/index.html" <<EOF
<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>客户登录 - ${brand_cn_html}</title><link rel="stylesheet" href="/assets/site.css"></head><body><nav class="nav"><div class="container nav-inner"><a class="brand" href="/"><span class="brand-mark">I</span><span>${brand_cn_html}</span></a><div class="nav-links"><a href="/register/">申请开通</a><a href="/support/">支持中心</a><a href="/en/login/">English</a></div></div></nav><main class="auth-wrap"><form class="auth-card" data-static-form data-success="客户门户入口已收到请求。此静态页面不会处理密码，请通过支持邮箱联系团队。"><h1>客户门户登录</h1><p>管理云服务器、独立服务器、工单、账单和维护通知。</p><label class="field">邮箱<input type="email" placeholder="name@example.com" autocomplete="email"></label><label class="field">密码<input type="password" placeholder="请输入密码" autocomplete="current-password"></label><button class="btn primary" style="width:100%;margin-top:20px" type="submit">登录</button><p class="codex-muted" data-form-message style="color:#667085"></p><p style="color:#667085;font-size:14px">忘记密码？请联系 <a href="mailto:${email_html}">${email_html}</a></p></form></main><footer><div class="container"><span>© <span data-year></span> ${brand_cn_html}</span><span><a href="/legal/privacy.html">隐私政策</a></span></div></footer><script src="/assets/site.js"></script></body></html>
EOF

  cat > "$SITE_ROOT/register/index.html" <<EOF
<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>申请开通 - ${brand_cn_html}</title><link rel="stylesheet" href="/assets/site.css"></head><body><nav class="nav"><div class="container nav-inner"><a class="brand" href="/"><span class="brand-mark">I</span><span>${brand_cn_html}</span></a><div class="nav-links"><a href="/products/cloud.html">产品</a><a href="/login/">登录</a><a href="/en/register/">English</a></div></div></nav><main class="auth-wrap"><form class="auth-card" data-static-form data-success="申请信息已记录在当前页面。请通过页面邮箱提交正式需求。"><h1>申请开通服务</h1><p>填写业务类型、区域、资源和带宽需求，便于售前给出建议。</p><label class="field">联系邮箱<input type="email" placeholder="name@company.com"></label><label class="field">需求说明<textarea placeholder="例如：云服务器 4C8G，香港/新加坡线路，月流量 5TB"></textarea></label><button class="btn primary" style="width:100%;margin-top:20px" type="submit">提交咨询</button><p data-form-message style="color:#027a62"></p></form></main><footer><div class="container"><span>© <span data-year></span> ${brand_cn_html}</span><span>${email_html}</span></div></footer><script src="/assets/site.js"></script></body></html>
EOF

  cat > "$SITE_ROOT/console/index.html" <<EOF
<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>控制台概览 - ${brand_cn_html}</title><link rel="stylesheet" href="/assets/site.css"></head><body><nav class="nav"><div class="container nav-inner"><a class="brand" href="/"><span class="brand-mark">I</span><span>${brand_cn_html}</span></a><div class="nav-links"><a href="/login/">登录</a><a href="/support/">工单</a><a href="/en/console/">English</a></div></div></nav><section><div class="container"><div class="section-head"><h1>控制台概览</h1><p>用于展示客户门户结构。真实业务系统可在后续接入认证和 API。</p></div><div class="console-shell"><aside class="console-nav"><span class="active">总览</span><span>云服务器</span><span>独立服务器</span><span>账单</span><span>工单</span><span>安全设置</span></aside><div><div class="grid-3"><div class="card"><h3>运行服务</h3><p><strong>12</strong> 个资源处于正常状态</p></div><div class="card"><h3>本月流量</h3><p><strong>8.4 TB</strong> 已记录</p></div><div class="card"><h3>待处理工单</h3><p><strong>0</strong> 个紧急事项</p></div></div><div class="card" style="margin-top:18px"><h3>最近操作</h3><div class="notice-list"><div class="notice"><span>云服务器 C4 快照完成</span><strong>09:20</strong></div><div class="notice"><span>工单分类规则更新</span><strong>昨天</strong></div></div></div></div></div></div></section><footer><div class="container"><span>© <span data-year></span> ${brand_cn_html}</span><span>Client Portal Preview</span></div></footer><script src="/assets/site.js"></script></body></html>
EOF

  cat > "$SITE_ROOT/support/index.html" <<EOF
<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>支持中心 - ${brand_cn_html}</title><link rel="stylesheet" href="/assets/site.css"></head><body><nav class="nav"><div class="container nav-inner"><a class="brand" href="/"><span class="brand-mark">I</span><span>${brand_cn_html}</span></a><div class="nav-links"><a href="/docs/">文档</a><a href="/status/">状态</a><a href="/en/support/">English</a></div></div></nav><section><div class="container"><div class="section-head"><h1>支持中心</h1><p>7x24 NOC、工单、远程协助和变更窗口管理。</p></div><div class="grid-3"><div class="card"><h3>故障工单</h3><p>网络中断、丢包、实例异常、硬件告警等紧急问题。</p></div><div class="card"><h3>变更请求</h3><p>系统重装、带宽调整、IP 增减、路由策略变更。</p></div><div class="card"><h3>账务支持</h3><p>续费、发票、订单变更和合同信息核对。</p></div></div><div class="card" style="margin-top:18px"><h3>联系方式</h3><p>支持邮箱：<a href="mailto:${email_html}">${email_html}</a></p><p>建议提交时附带资源 ID、故障时间、源地址、目标地址和测试结果。</p></div></div></section><footer><div class="container"><span>© <span data-year></span> ${brand_cn_html}</span><span><a href="/login/">客户登录</a></span></div></footer><script src="/assets/site.js"></script></body></html>
EOF

  cat > "$SITE_ROOT/docs/index.html" <<EOF
<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>文档中心 - ${brand_cn_html}</title><link rel="stylesheet" href="/assets/site.css"></head><body><nav class="nav"><div class="container nav-inner"><a class="brand" href="/"><span class="brand-mark">I</span><span>${brand_cn_html}</span></a><div class="nav-links"><a href="/products/cloud.html">产品</a><a href="/support/">支持</a><a href="/en/docs/">English</a></div></div></nav><section><div class="container"><div class="section-head"><h1>文档中心</h1><p>常见交付、网络、系统和安全操作指南。</p></div><div class="grid-3"><div class="card"><h3>快速开始</h3><p>登录门户、查看服务、绑定安全邮箱、创建工单。</p><p><span class="kbd">GETTING STARTED</span></p></div><div class="card"><h3>网络排查</h3><p>如何提交 MTR、Ping、Traceroute 和端口测试结果。</p><p><span class="kbd">NETWORK</span></p></div><div class="card"><h3>安全建议</h3><p>SSH 密钥、系统更新、防火墙和备份策略建议。</p><p><span class="kbd">SECURITY</span></p></div></div></div></section><footer><div class="container"><span>© <span data-year></span> ${brand_cn_html}</span><span>Docs</span></div></footer><script src="/assets/site.js"></script></body></html>
EOF

  cat > "$SITE_ROOT/announcements/index.html" <<EOF
<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>公告 - ${brand_cn_html}</title><link rel="stylesheet" href="/assets/site.css"></head><body><nav class="nav"><div class="container nav-inner"><a class="brand" href="/"><span class="brand-mark">I</span><span>${brand_cn_html}</span></a><div class="nav-links"><a href="/status/">状态</a><a href="/support/">支持</a><a href="/en/announcements/">English</a></div></div></nav><section><div class="container"><div class="section-head"><h1>公告</h1><p>维护窗口、服务调整和安全通知。</p></div><div class="card notice-list"><div class="notice"><span>核心网络例行巡检完成，未发现异常。</span><strong>2026-06-14</strong></div><div class="notice"><span>新增云服务器 NVMe 存储池。</span><strong>2026-06-08</strong></div><div class="notice"><span>客户门户工单分类已更新。</span><strong>2026-06-01</strong></div></div></div></section><footer><div class="container"><span>© <span data-year></span> ${brand_cn_html}</span><span>Announcements</span></div></footer><script src="/assets/site.js"></script></body></html>
EOF

  cat > "$SITE_ROOT/en/products/cloud.html" <<EOF
<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Cloud Servers - ${brand_en_html}</title><link rel="stylesheet" href="/assets/site.css"></head><body><nav class="nav"><div class="container nav-inner"><a class="brand" href="/en/"><span class="brand-mark">I</span><span>${brand_en_html}</span></a><div class="nav-links"><a href="/en/products/cloud.html">Cloud</a><a href="/en/products/dedicated.html">Dedicated</a><a href="/en/products/colocation.html">Colocation</a><a href="/en/login/">Login</a><a href="/products/cloud.html">中文</a></div></div></nav><section><div class="container"><div class="section-head"><h1>Cloud Servers</h1><p>Elastic virtual machines for websites, APIs, back-office systems and lightweight databases.</p></div><table class="spec-table"><thead><tr><th>Plan</th><th>CPU</th><th>Memory</th><th>Disk</th><th>Network</th><th>Delivery</th></tr></thead><tbody><tr><td>S2</td><td>2 vCPU</td><td>4 GB</td><td>60 GB NVMe</td><td>1 Gbps shared</td><td>Within 15 minutes</td></tr><tr><td>C4</td><td>4 vCPU</td><td>8 GB</td><td>120 GB NVMe</td><td>1 Gbps shared</td><td>Within 15 minutes</td></tr><tr><td>M8</td><td>8 vCPU</td><td>16 GB</td><td>240 GB NVMe</td><td>2 Gbps shared</td><td>On request</td></tr></tbody></table></div></section><footer><div class="container"><span>© <span data-year></span> ${brand_en_html}</span><span><a href="/en/register/">Request service</a></span></div></footer><script src="/assets/site.js"></script></body></html>
EOF

  cat > "$SITE_ROOT/en/products/dedicated.html" <<EOF
<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Dedicated Servers - ${brand_en_html}</title><link rel="stylesheet" href="/assets/site.css"></head><body><nav class="nav"><div class="container nav-inner"><a class="brand" href="/en/"><span class="brand-mark">I</span><span>${brand_en_html}</span></a><div class="nav-links"><a href="/en/products/cloud.html">Cloud</a><a href="/en/products/dedicated.html">Dedicated</a><a href="/en/support/">Support</a><a href="/products/dedicated.html">中文</a></div></div></nav><section><div class="container"><div class="section-head"><h1>Dedicated Servers</h1><p>Dedicated hardware for databases, virtualization, private deployments and high-concurrency workloads.</p></div><div class="grid-3"><div class="card"><h3>D1 Standard</h3><p>8C / 32 GB / 2 x SSD for isolated business deployments.</p></div><div class="card"><h3>D2 Performance</h3><p>16C / 64 GB / NVMe for latency-sensitive workloads.</p></div><div class="card"><h3>Custom Build</h3><p>CPU, memory, disks, IP allocation and bandwidth can be tailored.</p></div></div></div></section><footer><div class="container"><span>© <span data-year></span> ${brand_en_html}</span><span><a href="/en/register/">Request quote</a></span></div></footer><script src="/assets/site.js"></script></body></html>
EOF

  cat > "$SITE_ROOT/en/products/colocation.html" <<EOF
<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Colocation - ${brand_en_html}</title><link rel="stylesheet" href="/assets/site.css"></head><body><nav class="nav"><div class="container nav-inner"><a class="brand" href="/en/"><span class="brand-mark">I</span><span>${brand_en_html}</span></a><div class="nav-links"><a href="/en/products/cloud.html">Cloud</a><a href="/en/products/colocation.html">Colocation</a><a href="/en/status/">Status</a><a href="/products/colocation.html">中文</a></div></div></nav><section><div class="container"><div class="section-head"><h1>Colocation</h1><p>Rack space, cabling, power, bandwidth, IP resources, remote-hands and asset records.</p></div><div class="grid-3"><div class="card"><h3>1U / 2U</h3><p>For small hardware deployments and remote maintenance.</p></div><div class="card"><h3>Half / Full Rack</h3><p>For scaled deployments and dedicated network planning.</p></div><div class="card"><h3>Remote Hands</h3><p>Power cycle, cable checks, disk replacement and on-site photo records.</p></div></div></div></section><footer><div class="container"><span>© <span data-year></span> ${brand_en_html}</span><span><a href="/en/support/">Contact NOC</a></span></div></footer><script src="/assets/site.js"></script></body></html>
EOF

  cat > "$SITE_ROOT/en/login/index.html" <<EOF
<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Client Login - ${brand_en_html}</title><link rel="stylesheet" href="/assets/site.css"></head><body><nav class="nav"><div class="container nav-inner"><a class="brand" href="/en/"><span class="brand-mark">I</span><span>${brand_en_html}</span></a><div class="nav-links"><a href="/en/register/">Request service</a><a href="/en/support/">Support</a><a href="/login/">中文</a></div></div></nav><main class="auth-wrap"><form class="auth-card" data-static-form data-success="The static portal page does not process passwords. Please contact support for access."><h1>Client Portal Login</h1><p>Manage cloud servers, dedicated servers, tickets, billing and maintenance notices.</p><label class="field">Email<input type="email" placeholder="name@example.com" autocomplete="email"></label><label class="field">Password<input type="password" placeholder="Password" autocomplete="current-password"></label><button class="btn primary" style="width:100%;margin-top:20px" type="submit">Login</button><p data-form-message style="color:#667085"></p><p style="color:#667085;font-size:14px">Forgot password? Contact <a href="mailto:${email_html}">${email_html}</a></p></form></main><footer><div class="container"><span>© <span data-year></span> ${brand_en_html}</span><span><a href="/en/legal/privacy.html">Privacy</a></span></div></footer><script src="/assets/site.js"></script></body></html>
EOF

  cat > "$SITE_ROOT/en/register/index.html" <<EOF
<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Request Service - ${brand_en_html}</title><link rel="stylesheet" href="/assets/site.css"></head><body><nav class="nav"><div class="container nav-inner"><a class="brand" href="/en/"><span class="brand-mark">I</span><span>${brand_en_html}</span></a><div class="nav-links"><a href="/en/products/cloud.html">Products</a><a href="/en/login/">Login</a><a href="/register/">中文</a></div></div></nav><main class="auth-wrap"><form class="auth-card" data-static-form data-success="Your request has been noted on this static page. Please send formal requirements by email."><h1>Request Service</h1><p>Share your region, resources and bandwidth needs so our team can recommend a plan.</p><label class="field">Email<input type="email" placeholder="name@company.com"></label><label class="field">Requirements<textarea placeholder="Example: 4C8G cloud server, Singapore route, 5 TB monthly transfer"></textarea></label><button class="btn primary" style="width:100%;margin-top:20px" type="submit">Submit request</button><p data-form-message style="color:#027a62"></p></form></main><footer><div class="container"><span>© <span data-year></span> ${brand_en_html}</span><span>${email_html}</span></div></footer><script src="/assets/site.js"></script></body></html>
EOF

  cat > "$SITE_ROOT/en/console/index.html" <<EOF
<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Console Overview - ${brand_en_html}</title><link rel="stylesheet" href="/assets/site.css"></head><body><nav class="nav"><div class="container nav-inner"><a class="brand" href="/en/"><span class="brand-mark">I</span><span>${brand_en_html}</span></a><div class="nav-links"><a href="/en/login/">Login</a><a href="/en/support/">Tickets</a><a href="/console/">中文</a></div></div></nav><section><div class="container"><div class="section-head"><h1>Console Overview</h1><p>A static preview of the client portal structure. Authentication and APIs can be integrated later.</p></div><div class="console-shell"><aside class="console-nav"><span class="active">Overview</span><span>Cloud Servers</span><span>Dedicated</span><span>Billing</span><span>Tickets</span><span>Security</span></aside><div><div class="grid-3"><div class="card"><h3>Active Services</h3><p><strong>12</strong> resources operating normally</p></div><div class="card"><h3>Monthly Transfer</h3><p><strong>8.4 TB</strong> recorded</p></div><div class="card"><h3>Open Tickets</h3><p><strong>0</strong> urgent items</p></div></div></div></div></div></section><footer><div class="container"><span>© <span data-year></span> ${brand_en_html}</span><span>Client Portal Preview</span></div></footer><script src="/assets/site.js"></script></body></html>
EOF

  cat > "$SITE_ROOT/en/support/index.html" <<EOF
<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Support Center - ${brand_en_html}</title><link rel="stylesheet" href="/assets/site.css"></head><body><nav class="nav"><div class="container nav-inner"><a class="brand" href="/en/"><span class="brand-mark">I</span><span>${brand_en_html}</span></a><div class="nav-links"><a href="/en/docs/">Docs</a><a href="/en/status/">Status</a><a href="/support/">中文</a></div></div></nav><section><div class="container"><div class="section-head"><h1>Support Center</h1><p>24/7 NOC, ticket support, remote-hands and change window management.</p></div><div class="grid-3"><div class="card"><h3>Incident Tickets</h3><p>Network outage, packet loss, instance faults and hardware alerts.</p></div><div class="card"><h3>Change Requests</h3><p>OS reinstall, bandwidth changes, IP allocation and route policy updates.</p></div><div class="card"><h3>Billing Support</h3><p>Renewal, invoices, order changes and contract verification.</p></div></div><div class="card" style="margin-top:18px"><h3>Contact</h3><p>Support email: <a href="mailto:${email_html}">${email_html}</a></p></div></div></section><footer><div class="container"><span>© <span data-year></span> ${brand_en_html}</span><span><a href="/en/login/">Client Login</a></span></div></footer><script src="/assets/site.js"></script></body></html>
EOF

  cat > "$SITE_ROOT/en/docs/index.html" <<EOF
<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Documentation - ${brand_en_html}</title><link rel="stylesheet" href="/assets/site.css"></head><body><nav class="nav"><div class="container nav-inner"><a class="brand" href="/en/"><span class="brand-mark">I</span><span>${brand_en_html}</span></a><div class="nav-links"><a href="/en/products/cloud.html">Products</a><a href="/en/support/">Support</a><a href="/docs/">中文</a></div></div></nav><section><div class="container"><div class="section-head"><h1>Documentation</h1><p>Delivery, network, system and security operation guides.</p></div><div class="grid-3"><div class="card"><h3>Getting Started</h3><p>Login, review services, set security email and create tickets.</p><p><span class="kbd">GETTING STARTED</span></p></div><div class="card"><h3>Network Diagnosis</h3><p>Submit MTR, Ping, Traceroute and port test results.</p><p><span class="kbd">NETWORK</span></p></div><div class="card"><h3>Security Advice</h3><p>SSH keys, system updates, firewall and backup policies.</p><p><span class="kbd">SECURITY</span></p></div></div></div></section><footer><div class="container"><span>© <span data-year></span> ${brand_en_html}</span><span>Docs</span></div></footer><script src="/assets/site.js"></script></body></html>
EOF

  cat > "$SITE_ROOT/en/announcements/index.html" <<EOF
<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Announcements - ${brand_en_html}</title><link rel="stylesheet" href="/assets/site.css"></head><body><nav class="nav"><div class="container nav-inner"><a class="brand" href="/en/"><span class="brand-mark">I</span><span>${brand_en_html}</span></a><div class="nav-links"><a href="/en/status/">Status</a><a href="/en/support/">Support</a><a href="/announcements/">中文</a></div></div></nav><section><div class="container"><div class="section-head"><h1>Announcements</h1><p>Maintenance windows, service adjustments and security notices.</p></div><div class="card notice-list"><div class="notice"><span>Core network routine inspection completed with no abnormalities.</span><strong>2026-06-14</strong></div><div class="notice"><span>New NVMe storage pool is available.</span><strong>2026-06-08</strong></div><div class="notice"><span>Client portal ticket categories have been updated.</span><strong>2026-06-01</strong></div></div></div></section><footer><div class="container"><span>© <span data-year></span> ${brand_en_html}</span><span>Announcements</span></div></footer><script src="/assets/site.js"></script></body></html>
EOF

  cat > "$SITE_ROOT/robots.txt" <<EOF
User-agent: *
Allow: /
Sitemap: https://${DOMAIN}/sitemap.xml
EOF

  cat > "$SITE_ROOT/sitemap.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
  <url><loc>https://${DOMAIN}/</loc></url>
  <url><loc>https://${DOMAIN}/en/</loc></url>
  <url><loc>https://${DOMAIN}/products/cloud.html</loc></url>
  <url><loc>https://${DOMAIN}/products/dedicated.html</loc></url>
  <url><loc>https://${DOMAIN}/products/colocation.html</loc></url>
  <url><loc>https://${DOMAIN}/login/</loc></url>
  <url><loc>https://${DOMAIN}/register/</loc></url>
  <url><loc>https://${DOMAIN}/console/</loc></url>
  <url><loc>https://${DOMAIN}/support/</loc></url>
  <url><loc>https://${DOMAIN}/docs/</loc></url>
  <url><loc>https://${DOMAIN}/announcements/</loc></url>
  <url><loc>https://${DOMAIN}/status/</loc></url>
  <url><loc>https://${DOMAIN}/en/products/cloud.html</loc></url>
  <url><loc>https://${DOMAIN}/en/products/dedicated.html</loc></url>
  <url><loc>https://${DOMAIN}/en/products/colocation.html</loc></url>
  <url><loc>https://${DOMAIN}/en/login/</loc></url>
  <url><loc>https://${DOMAIN}/en/register/</loc></url>
  <url><loc>https://${DOMAIN}/en/console/</loc></url>
  <url><loc>https://${DOMAIN}/en/support/</loc></url>
  <url><loc>https://${DOMAIN}/en/docs/</loc></url>
  <url><loc>https://${DOMAIN}/en/announcements/</loc></url>
  <url><loc>https://${DOMAIN}/en/status/</loc></url>
  <url><loc>https://${DOMAIN}/legal/terms.html</loc></url>
  <url><loc>https://${DOMAIN}/legal/privacy.html</loc></url>
  <url><loc>https://${DOMAIN}/en/legal/terms.html</loc></url>
  <url><loc>https://${DOMAIN}/en/legal/privacy.html</loc></url>
</urlset>
EOF
}

write_http_nginx() {
  cat > "$NGINX_CONF" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};
    root ${SITE_ROOT};
    index index.html;

    location ^~ /.well-known/acme-challenge/ {
        root ${SITE_ROOT};
        default_type "text/plain";
        try_files \$uri =404;
    }

    location / {
        try_files \$uri \$uri/ /index.html;
    }
}
EOF

  if [ -n "${NGINX_LINK:-}" ]; then
    ln -sfn "$NGINX_CONF" "$NGINX_LINK"
  fi
}

write_https_nginx() {
  cat > "$NGINX_CONF" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    location ^~ /.well-known/acme-challenge/ {
        root ${SITE_ROOT};
        default_type "text/plain";
        try_files \$uri =404;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${DOMAIN};
    root ${SITE_ROOT};
    index index.html;

    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ecdh_curve X25519:prime256v1:secp384r1;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
    ssl_prefer_server_ciphers off;
    ssl_session_timeout 1d;
    ssl_session_cache shared:IDCSSL:10m;
    ssl_session_tickets off;

    add_header Strict-Transport-Security "max-age=31536000" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    server_tokens off;

    location ~ /\.(?!well-known) {
        return 404;
    }

    location ~* \.(env|git|svn|bak|old|sql|ini|log|conf)$ {
        return 404;
    }

    location / {
        try_files \$uri \$uri/ /index.html;
    }
}
EOF
}

issue_certificate() {
  blue "正在申请 Let's Encrypt 证书..."
  certbot certonly \
    --webroot \
    -w "$SITE_ROOT" \
    -d "$DOMAIN" \
    --email "$CONTACT_EMAIL" \
    --agree-tos \
    --non-interactive
}

install_renew_hook() {
  mkdir -p /etc/letsencrypt/renewal-hooks/deploy
  cat > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh <<'EOF'
#!/usr/bin/env bash
systemctl reload nginx >/dev/null 2>&1 || true
EOF
  chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
  systemctl enable --now certbot.timer >/dev/null 2>&1 || true
}

nginx_test_reload() {
  nginx -t
  systemctl reload nginx
}

run_tls_tests() {
  blue "正在进行安装后测试..."
  local ok=1

  if curl -fsSIk --resolve "${DOMAIN}:443:127.0.0.1" "https://${DOMAIN}/" >/tmp/idc-site-curl-test.txt 2>&1; then
    green "HTTPS 本机回环测试通过。"
  else
    ok=0
    yellow "HTTPS 本机回环测试未通过，输出："
    cat /tmp/idc-site-curl-test.txt || true
  fi

  local s_client_out
  s_client_out="$(echo | openssl s_client -connect 127.0.0.1:443 -servername "$DOMAIN" -tls1_3 -alpn h2 2>/dev/null || true)"

  if printf '%s' "$s_client_out" | grep -q 'Protocol  *: TLSv1.3'; then
    green "TLS 1.3 测试通过。"
  else
    ok=0
    yellow "TLS 1.3 未能确认，请检查 OpenSSL/Nginx 版本。"
  fi

  if printf '%s' "$s_client_out" | grep -q 'ALPN protocol: h2'; then
    green "HTTP/2 ALPN 测试通过。"
  else
    ok=0
    yellow "HTTP/2 ALPN 未能确认，请检查 Nginx http2 支持。"
  fi

  if printf '%s' "$s_client_out" | grep -qi 'Server Temp Key: X25519'; then
    green "X25519 曲线测试通过。"
  else
    yellow "未从 OpenSSL 输出中确认 X25519；配置已写入 ssl_ecdh_curve X25519。"
  fi

  if [ "$ok" -eq 1 ]; then
    green "核心测试通过。"
  else
    yellow "安装完成，但部分测试需要人工复核。"
  fi
}

print_summary() {
  cat <<EOF

安装完成。

网站地址：https://${DOMAIN}
中文页面：https://${DOMAIN}/
英文页面：https://${DOMAIN}/en/
状态页面：https://${DOMAIN}/status/

网站目录：${SITE_ROOT}
Nginx 配置：${NGINX_CONF}
证书目录：/etc/letsencrypt/live/${DOMAIN}

Reality 目标站常见检查项：
- HTTPS 不跳转到其他域名
- 支持 TLS 1.3
- 配置 X25519 曲线
- 支持 HTTP/2 ALPN h2
- 域名证书与 SNI 匹配

EOF
}

main() {
  need_root
  clear || true
  blue "$APP_NAME"
  echo
  echo "该脚本会部署一个真实可访问的中英双语 IDC 官网，并自动配置 Nginx、HTTPS、TLS 1.3、X25519 与 HTTP/2。"
  echo "请先确认域名 A 记录已经解析到本机公网 IP。"
  echo

  prompt_required RAW_DOMAIN "请输入域名，例如 example.com："
  DOMAIN="$(normalize_domain "$RAW_DOMAIN")"
  validate_domain "$DOMAIN"
  prompt_default BRAND_CN "请输入中文网站名称" "凌云数据中心"
  prompt_default BRAND_EN "请输入英文网站名称" "Lingyun Data Center"
  prompt_required CONTACT_EMAIL "请输入用于申请 SSL 证书的联系邮箱："
  prompt_default INSTALL_BASE "请输入网站安装基础目录" "$DEFAULT_INSTALL_BASE"
  prompt_yes_no INSTALL_CERT "是否自动申请 Let's Encrypt SSL 证书" "y"

  PUBLIC_IP="$(detect_public_ip)"
  if [ -n "$PUBLIC_IP" ]; then green "检测到本机公网 IP：$PUBLIC_IP"; fi
  check_dns_hint "$DOMAIN" "$PUBLIC_IP"

  install_packages
  prepare_paths
  render_site
  write_http_nginx
  nginx_test_reload

  if [ "$INSTALL_CERT" = "y" ]; then
    issue_certificate
    write_https_nginx
    install_renew_hook
    nginx_test_reload
    run_tls_tests
  else
    yellow "已跳过证书申请，仅部署 HTTP 站点。"
  fi

  print_summary
}

main "$@"
