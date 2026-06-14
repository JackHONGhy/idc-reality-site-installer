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
  mkdir -p "$SITE_ROOT/en" "$SITE_ROOT/en/legal" "$SITE_ROOT/en/status" "$SITE_ROOT/assets" "$SITE_ROOT/legal" "$SITE_ROOT/status" "$SITE_ROOT/.well-known"

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
footer { padding: 32px 0; border-top: 1px solid var(--line); color: var(--muted); font-size: 14px; background: white; }
footer .container { display: flex; justify-content: space-between; gap: 16px; flex-wrap: wrap; }
@media (max-width: 900px) {
  .hero .container, .grid-3, .grid-2, .contact-box { grid-template-columns: 1fr; }
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
      <a href="#services">服务</a><a href="#network">网络</a><a href="#sla">SLA</a><a href="#contact">联系</a>
      <span class="lang"><a class="active" href="/">中文</a><a href="/en/">English</a></span>
    </div>
  </div></nav>
  <header class="hero"><div class="container">
    <div>
      <span class="eyebrow">Reliable Infrastructure</span>
      <h1>面向企业业务的稳定云与 IDC 基础设施</h1>
      <p>${brand_cn_html} 为企业提供云服务器、独立服务器、机柜托管、BGP 网络接入和持续运维支持，帮助业务在安全、稳定、可扩展的环境中运行。</p>
      <div class="hero-actions"><a class="btn primary" href="#contact">获取方案</a><a class="btn secondary" href="#network">查看网络能力</a></div>
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
      <a href="#services">Services</a><a href="#network">Network</a><a href="#sla">SLA</a><a href="#contact">Contact</a>
      <span class="lang"><a href="/">中文</a><a class="active" href="/en/">English</a></span>
    </div>
  </div></nav>
  <header class="hero"><div class="container">
    <div>
      <span class="eyebrow">Reliable Infrastructure</span>
      <h1>Stable cloud and IDC infrastructure for production workloads</h1>
      <p>${brand_en_html} delivers cloud servers, dedicated servers, colocation, BGP connectivity and managed support for teams that need predictable infrastructure.</p>
      <div class="hero-actions"><a class="btn primary" href="#contact">Request a plan</a><a class="btn secondary" href="#network">View network</a></div>
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
  <url><loc>https://${DOMAIN}/status/</loc></url>
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
  prompt_required CONTACT_EMAIL "请输入证书和联系邮箱："
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
