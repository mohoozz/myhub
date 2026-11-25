"""门户页面：单文件 HTML（内嵌 CSS/JS），不依赖任何前端构建。

放在 Python 字符串里而不是 static 目录，是为了 ``pip install -e .`` 后
不额外配置 package_data 也能直接跑。
"""

HTML = r"""<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>MyHub 采集器 · 本地门户</title>
<style>
:root{
  --bg:#0d1117;--panel:#161b22;--panel2:#1c2128;--line:#21262d;
  --text:#e6edf3;--muted:#8b949e;--dim:#6e7681;
  --blue:#388bfd;--green:#3fb950;--red:#f85149;--yellow:#d29922;
}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--text);
  font:14px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI","Microsoft YaHei",system-ui,sans-serif;
  -webkit-font-smoothing:antialiased}
button,input,select,textarea{font:inherit;color:inherit}
button{cursor:pointer}
::-webkit-scrollbar{width:10px;height:10px}
::-webkit-scrollbar-thumb{background:#30363d;border-radius:6px;border:2px solid var(--bg)}
.app{display:grid;grid-template-columns:228px 1fr;min-height:100vh}
aside{border-right:1px solid var(--line);background:#0b0f14;padding:20px 12px;
  display:flex;flex-direction:column;gap:4px;position:sticky;top:0;height:100vh}
.brand{display:flex;align-items:center;gap:10px;padding:2px 10px 16px}
.logo{width:30px;height:30px;border-radius:9px;display:grid;place-items:center;
  background:linear-gradient(135deg,#1f6feb,#58a6ff);font-weight:800;font-size:15px}
.brand b{font-size:15px}
.brand small{display:block;color:var(--dim);font-size:11px;font-weight:400}
nav{display:flex;flex-direction:column;gap:2px}
nav button{border:0;background:transparent;color:var(--muted);text-align:left;
  padding:9px 12px;border-radius:8px;display:flex;align-items:center;gap:9px}
nav button:hover{background:var(--panel);color:var(--text)}
nav button.active{background:#1f6feb22;color:#79c0ff;font-weight:600}
nav button .dot{width:6px;height:6px;border-radius:50%;background:currentColor;opacity:.6}
.aside-foot{margin-top:auto;padding:12px 10px 4px;border-top:1px solid var(--line);
  color:var(--dim);font-size:11.5px;word-break:break-all}
.aside-foot b{color:var(--muted);display:block;margin-top:8px}
main{padding:22px 26px 70px;max-width:1180px}
header.top{display:flex;align-items:flex-end;justify-content:space-between;
  gap:14px;margin-bottom:18px;flex-wrap:wrap}
header.top h1{margin:0;font-size:21px}
header.top p{margin:4px 0 0;color:var(--muted);font-size:12.5px}
.top-actions{display:flex;gap:8px;flex-wrap:wrap}
.btn{border:1px solid var(--line);background:var(--panel2);border-radius:8px;
  padding:7px 13px;display:inline-flex;align-items:center;gap:7px;white-space:nowrap;
  transition:.15s border-color,.15s background}
.btn:hover{border-color:#3d444d;background:#22282f}
.btn.primary{background:#1f6feb;border-color:#1f6feb;color:#fff}
.btn.primary:hover{background:var(--blue)}
.btn.ghost{background:transparent}
.btn.sm{padding:4px 10px;font-size:12.5px}
.btn:disabled{opacity:.5;cursor:not-allowed}
.card{background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:16px 18px}
.card+.card{margin-top:14px}
.card h3{margin:0 0 4px;font-size:14.5px;display:flex;align-items:center;gap:8px}
.card .hint{color:var(--muted);font-size:12.5px;margin:0 0 12px}
.grid-3{display:grid;grid-template-columns:repeat(3,1fr);gap:14px}
.grid-2{display:grid;grid-template-columns:1fr 1.15fr;gap:14px}
@media(max-width:1020px){.grid-3,.grid-2{grid-template-columns:1fr}}
.icon{width:38px;height:38px;border-radius:10px;display:grid;place-items:center;
  font-weight:800;font-size:16px;flex:none}
.icon.bilibili{background:linear-gradient(135deg,#fb7299,#ff9eb5)}
.icon.youtube{background:linear-gradient(135deg,#ff0033,#ff5c5c)}
.icon.douyin{background:linear-gradient(135deg,#20222c,#343846);border:1px solid #3a3f4d}
.plat .head{display:flex;align-items:center;gap:11px;margin-bottom:12px}
.plat .name{font-weight:600;font-size:14.5px}
.plat .sub{color:var(--dim);font-size:11.5px}
.badge{display:inline-flex;align-items:center;gap:6px;border-radius:999px;
  padding:2px 9px;font-size:11.5px;font-weight:600;border:1px solid transparent}
.badge.ok{color:#56d364;background:#23863622;border-color:#2b5d33}
.badge.bad{color:#ff8b84;background:#da363322;border-color:#5b2b2b}
.badge.run{color:#e3b341;background:#9e6a0322;border-color:#5c4403}
.pulse{width:6px;height:6px;border-radius:50%;background:currentColor;
  animation:pulse 1.1s infinite}
@keyframes pulse{0%,100%{opacity:1}50%{opacity:.25}}
.kv{display:grid;grid-template-columns:auto 1fr;gap:4px 10px;font-size:12.5px;
  color:var(--muted);margin-bottom:14px;word-break:break-all}
.kv span:nth-child(odd){color:var(--dim)}
.bar{height:7px;border-radius:999px;background:#21262d;overflow:hidden;display:flex}
.bar .done{background:var(--green)}.bar .running{background:var(--yellow)}
.bar .failed{background:var(--red)}
.bar-wrap{display:flex;align-items:center;gap:10px}
.bar-wrap .bar{flex:1}
.num{font-variant-numeric:tabular-nums;color:var(--muted);font-size:12px;white-space:nowrap}
.days{display:flex;flex-direction:column;gap:6px;max-height:560px;overflow:auto;padding-right:4px}
.day-item{border:1px solid var(--line);background:var(--panel2);border-radius:9px;
  padding:10px 12px;text-align:left;display:flex;flex-direction:column;gap:7px}
.day-item:hover{border-color:#3d444d}
.day-item.active{border-color:var(--blue);background:#1f6feb22}
.day-item .row{display:flex;justify-content:space-between;align-items:center;gap:8px}
.day-item .d{font-weight:600;font-variant-numeric:tabular-nums;font-size:13px}
.day-item .s{font-size:11.5px;color:var(--dim)}
.stat-row{display:flex;gap:10px;flex-wrap:wrap;margin-bottom:14px}
.stat{flex:1;min-width:84px;background:var(--panel2);border:1px solid var(--line);
  border-radius:9px;padding:9px 12px}
.stat .v{font-size:18px;font-weight:700;font-variant-numeric:tabular-nums}
.stat .l{color:var(--dim);font-size:11px}
.stat.green .v{color:#56d364}.stat.red .v{color:#ff8b84}.stat.yellow .v{color:#e3b341}
table{width:100%;border-collapse:collapse;font-size:12.5px}
th{color:var(--dim);font-weight:500;text-align:left;padding:6px 8px;
  border-bottom:1px solid var(--line);white-space:nowrap}
td{padding:7px 8px;border-bottom:1px solid #1b2027;vertical-align:top}
tr:last-child td{border-bottom:0}
td.mono{font-variant-numeric:tabular-nums;color:var(--muted);white-space:nowrap}
td .t{display:block;max-width:520px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.tag{font-size:11px;color:var(--muted);border:1px solid var(--line);
  border-radius:5px;padding:1px 6px;margin-right:5px;white-space:nowrap}
.err{color:#ff8b84;font-size:12px;max-width:520px;word-break:break-word}
.empty{color:var(--dim);text-align:center;padding:24px 10px;font-size:13px}
.form-grid{display:grid;grid-template-columns:1fr 1fr;gap:12px 18px}
@media(max-width:900px){.form-grid{grid-template-columns:1fr}}
.field{display:flex;flex-direction:column;gap:5px;min-width:0}
.field label{font-size:12.5px;color:var(--muted);display:flex;align-items:center;gap:6px}
.field .help{font-size:11.5px;color:var(--dim)}
.field input[type=text],.field select,.field textarea{background:#0d1117;
  border:1px solid var(--line);border-radius:7px;padding:7px 10px;outline:none;width:100%}
.field input:focus,.field select:focus,.field textarea:focus{border-color:var(--blue)}
.field textarea{resize:vertical;min-height:62px;
  font-family:ui-monospace,Consolas,monospace;font-size:12.5px}
.field .restart{color:#e3b341;font-size:11px}
.switch{position:relative;display:inline-block;width:38px;height:21px;flex:none}
.switch input{opacity:0;width:0;height:0;position:absolute}
.switch .track{position:absolute;inset:0;background:#30363d;border-radius:999px;transition:.18s}
.switch .track:before{content:"";position:absolute;width:15px;height:15px;border-radius:50%;
  left:3px;top:3px;background:#8b949e;transition:.18s}
.switch input:checked+.track{background:#1f6feb}
.switch input:checked+.track:before{transform:translateX(17px);background:#fff}
details.adv{margin-top:10px;border-top:1px dashed var(--line);padding-top:8px}
details.adv summary{cursor:pointer;color:var(--dim);font-size:12px}
details.adv .form-grid{margin-top:10px}
.save-bar{position:sticky;bottom:0;margin-top:16px;background:#0d1117ee;
  backdrop-filter:blur(6px);border-top:1px solid var(--line);padding:12px 0;
  display:flex;gap:10px;align-items:center}
.save-bar .msg{color:var(--muted);font-size:12.5px}
.drawer{position:fixed;right:0;bottom:0;width:min(680px,96vw);height:46vh;
  background:#0b0f14ee;backdrop-filter:blur(8px);border:1px solid var(--line);
  border-radius:14px 0 0 0;display:none;flex-direction:column;z-index:50;
  box-shadow:-8px -8px 30px #0008}
.drawer.show{display:flex}
.drawer header{display:flex;align-items:center;gap:10px;padding:10px 14px;
  border-bottom:1px solid var(--line)}
.drawer header .title{font-weight:600;font-size:13px;flex:1;overflow:hidden;
  text-overflow:ellipsis;white-space:nowrap}
.drawer .prog{display:flex;flex-direction:column;gap:6px;padding:9px 14px;
  border-bottom:1px solid var(--line);background:#0d1117aa}
.drawer .prog .bar{height:6px}
.drawer .prog .row{display:flex;align-items:center;gap:10px;font-size:12px;color:var(--muted)}
.drawer .prog .txt{flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.drawer .log{flex:1;overflow:auto;padding:10px 14px;font-size:12px;line-height:1.6;
  color:#adbac7;font-family:ui-monospace,Consolas,monospace}
.drawer .log div{white-space:pre-wrap;word-break:break-word}
.path-ctl{display:flex;gap:8px;align-items:center}
.path-ctl input{flex:1;min-width:0}
.picker{position:fixed;inset:0;background:#0b0f14cc;backdrop-filter:blur(3px);
  display:none;align-items:center;justify-content:center;padding:20px;z-index:90}
.picker.show{display:flex}
.picker-box{width:min(720px,96vw);max-height:82vh;background:var(--panel);
  border:1px solid var(--line);border-radius:14px;display:flex;flex-direction:column;
  overflow:hidden;box-shadow:0 20px 60px #000a}
.picker-box header{display:flex;align-items:center;gap:10px;padding:12px 14px;
  border-bottom:1px solid var(--line)}
.picker-box header .title{flex:1;min-width:0;font-size:13px;font-weight:600;
  overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.picker-roots{display:flex;gap:6px;flex-wrap:wrap;padding:10px 14px 0}
.picker-list{flex:1;overflow:auto;padding:10px 14px}
.picker-dir{padding:8px 10px;border-radius:7px;cursor:pointer;font-size:13px;
  display:flex;gap:8px;align-items:flex-start;word-break:break-all}
.picker-dir:hover{background:#1f6feb22}
.picker-dir .i{color:var(--dim);font-size:11px;flex:none;margin-top:2px}
.picker-box footer{display:flex;gap:8px;align-items:center;padding:10px 14px;
  border-top:1px solid var(--line);background:#0d1117aa}
.picker-box footer .msg{flex:1;min-width:0;color:var(--muted);font-size:11.5px;
  overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
#toast{position:fixed;right:20px;top:18px;display:flex;flex-direction:column;gap:8px;z-index:80}
.toast{background:var(--panel);border:1px solid var(--line);border-left:3px solid var(--blue);
  border-radius:9px;padding:10px 14px;min-width:220px;max-width:380px;font-size:12.5px;
  box-shadow:0 8px 24px #0007}
.toast.ok{border-left-color:var(--green)}
.toast.err{border-left-color:var(--red)}
@media(max-width:820px){
  .app{grid-template-columns:1fr}
  aside{position:static;height:auto;flex-direction:row;align-items:center;
    overflow:auto;padding:10px}
  .brand{padding:0 10px 0 4px}.brand small{display:none}
  nav{flex-direction:row}.aside-foot{display:none}
  main{padding:18px 16px 70px}
}
</style>
</head>
<body>
<div class="app">
  <aside>
    <div class="brand"><div class="logo">M</div>
      <div><b>MyHub 采集器</b><small>本地门户</small></div></div>
    <nav>
      <button data-view="overview" class="active"><i class="dot"></i>概览</button>
      <button data-view="platforms"><i class="dot"></i>平台登录</button>
      <button data-view="progress"><i class="dot"></i>下载进度</button>
      <button data-view="config"><i class="dot"></i>环境配置</button>
    </nav>
    <div class="aside-foot">
      <b>数据目录</b><div id="footData">…</div>
      <b>下载目录</b><div id="footDown">…</div>
      <b>报告目录</b><div id="footReport">…</div>
    </div>
  </aside>
  <main>
    <header class="top">
      <div><h1 id="viewTitle">概览</h1><p id="viewSub">…</p></div>
      <div class="top-actions">
        <button class="btn sm ghost" id="btnInit">环境自检</button>
        <button class="btn sm ghost" id="btnSync">同步订阅源</button>
        <button class="btn sm primary" id="btnCollectTop">立即采集</button>
      </div>
    </header>
    <section id="view-overview">
      <div class="grid-3" id="platCards"></div>
      <div class="card" style="margin-top:14px">
        <h3>开始采集</h3>
        <p class="hint">默认采集前一天：同步关注 → 抓取 → 下载 → 生成日报。后台运行，可随时关页面。</p>
        <div style="display:flex;gap:10px;flex-wrap:wrap;align-items:center">
          <input type="date" id="collectDay" style="background:#0d1117;border:1px solid var(--line);border-radius:7px;padding:7px 10px">
          <select id="collectPlatform" style="background:#0d1117;border:1px solid var(--line);border-radius:7px;padding:7px 10px">
            <option value="all">全部平台</option>
            <option value="bilibili">B站</option>
            <option value="youtube">YouTube</option>
            <option value="douyin">抖音</option>
          </select>
          <label style="display:flex;align-items:center;gap:6px;color:var(--muted);font-size:12.5px">
            <input type="checkbox" id="collectDownload" checked> 同时下载</label>
          <label style="display:flex;align-items:center;gap:6px;color:var(--muted);font-size:12.5px">
            <input type="checkbox" id="collectSync" checked> 先同步关注</label>
          <button class="btn primary" id="btnCollect">开始采集</button>
        </div>
      </div>
      <div class="card"><h3>本次服务运行的任务</h3>
        <p class="hint">进程内记录，重启服务后清空。</p>
        <div id="jobList"><div class="empty">暂无任务</div></div></div>
      <div class="card"><h3>历史运行日志</h3>
        <div id="runList"><div class="empty">还没有运行记录</div></div></div>
    </section>
    <section id="view-platforms" hidden>
      <div class="card">
        <h3>登录态</h3>
        <p class="hint">点「登录」会弹出浏览器窗口，正常登录即可；检测到登录态后自动保存并关闭。</p>
        <div style="display:flex;gap:10px;align-items:center;flex-wrap:wrap">
          <button class="btn primary" id="btnLoginAll">一键登录全部平台</button>
          <label style="color:var(--muted);font-size:12.5px;display:flex;gap:6px;align-items:center">
            等待时长
            <select id="loginWait" style="background:#0d1117;border:1px solid var(--line);border-radius:7px;padding:5px 8px">
              <option value="120">2 分钟</option>
              <option value="300" selected>5 分钟</option>
              <option value="600">10 分钟</option>
            </select>
          </label>
        </div>
      </div>
      <div class="grid-3" id="platformFull" style="margin-top:14px"></div>
    </section>
    <section id="view-progress" hidden>
      <div class="grid-2">
        <div class="card"><h3>按天查看</h3>
          <p class="hint">以内容发布时间归档，展示每条内容的下载状态。</p>
          <div class="days" id="dayList"><div class="empty">还没有采集记录</div></div></div>
        <div class="card"><h3 id="dayTitle">选择一天</h3>
          <p class="hint" id="daySub">点左边任意一天查看明细</p>
          <div class="stat-row" id="dayStats"></div>
          <div class="bar-wrap" style="margin-bottom:14px">
            <div class="bar" id="dayBar"></div><span class="num" id="dayPct">0%</span></div>
          <div id="dayPlatforms"></div>
          <div id="dayFailures"></div>
          <div style="margin-top:12px" id="dayActions"></div>
          <div style="margin-top:14px;max-height:460px;overflow:auto" id="dayItems"></div></div>
      </div>
    </section>
    <section id="view-config" hidden>
      <div id="configForm"></div>
      <div class="save-bar">
        <button class="btn primary" id="btnSaveEnv">保存配置</button>
        <button class="btn ghost" id="btnReloadEnv">重新读取</button>
        <span class="msg" id="saveMsg"></span></div>
    </section>
  </main>
</div>
<div class="drawer" id="drawer">
  <header><span class="badge run" id="jobBadge"><i class="pulse"></i>运行中</span>
    <span class="title" id="jobTitle">任务日志</span>
    <button class="btn sm ghost" id="btnCloseDrawer">收起</button></header>
  <div class="prog" id="jobProg" hidden>
    <div class="bar"><div class="done" id="jobBar" style="width:0"></div></div>
    <div class="row"><span class="txt" id="jobProgText">准备中…</span>
      <span class="num" id="jobPct"></span></div>
  </div>
  <div class="log" id="logBox"></div>
</div>
<div class="picker" id="picker">
  <div class="picker-box">
    <header>
      <span class="title" id="pickerPath">选择目录</span>
      <button class="btn sm ghost" id="pickerClose">关闭</button>
    </header>
    <div class="picker-roots" id="pickerRoots"></div>
    <div class="picker-list" id="pickerList"></div>
    <footer>
      <span class="msg" id="pickerMsg"></span>
      <button class="btn sm ghost" id="pickerBlank">留空用默认</button>
      <button class="btn sm ghost" id="pickerUp">上一级</button>
      <button class="btn sm primary" id="pickerPick">选择此目录</button>
    </footer>
  </div>
</div>
<div id="toast"></div>
<script>
const TOKEN = "__TOKEN__";
const $ = (s) => document.querySelector(s);
const $$ = (s) => Array.from(document.querySelectorAll(s));
const esc = (s) => String(s == null ? "" : s).replace(/[&<>"']/g, (c) =>
  ({ "&":"&amp;", "<":"&lt;", ">":"&gt;", '"':"&quot;", "'":"&#39;" }[c]));
const PLAT = { bilibili:"B站", youtube:"YouTube", douyin:"抖音" };
function fmtSize(n){
  n = Number(n) || 0;
  if (n < 1024) return n + " B";
  const u = ["KB","MB","GB","TB"]; let i = -1;
  do { n /= 1024; i++; } while (n >= 1024 && i < u.length - 1);
  return n.toFixed(n >= 100 ? 0 : 1) + " " + u[i];
}
const S = { overview:null, days:null, day:null, env:null, view:"overview" };
let jobTimer = null, jobId = null;

async function api(path, opt){
  opt = opt || {};
  const res = await fetch(path, {
    method: opt.method || "GET",
    headers: { "Content-Type":"application/json", "X-MyHub-Token": TOKEN },
    body: opt.body ? JSON.stringify(opt.body) : undefined,
  });
  let data = null;
  try { data = await res.json(); } catch (e) { data = { error:"响应不是合法 JSON" }; }
  if (!res.ok || (data && data.ok === false)) throw new Error((data && data.error) || ("HTTP " + res.status));
  return data;
}
function toast(text, kind){
  const el = document.createElement("div");
  el.className = "toast " + (kind || "");
  el.textContent = text;
  $("#toast").appendChild(el);
  setTimeout(() => el.remove(), kind === "err" ? 6000 : 3600);
}

const META = {
  overview: ["概览", "三个平台的登录态、昨天的下载情况和最近的运行记录"],
  platforms: ["平台登录", "登录一次长期有效，登录态存在 data/credentials/"],
  progress: ["下载进度", "按内容发布时间查看每天的采集与下载情况"],
  config: ["环境配置", "直接改 .env；保存后立即生效（目录类改动需重启服务）"],
};
function switchView(view){
  S.view = view;
  $$("nav button").forEach((b) => b.classList.toggle("active", b.dataset.view === view));
  ["overview","platforms","progress","config"].forEach((v) => {
    document.getElementById("view-" + v).hidden = v !== view;
  });
  $("#viewTitle").textContent = META[view][0];
  $("#viewSub").textContent = META[view][1];
  if (view === "overview" || view === "platforms") loadOverview();
  if (view === "progress") loadProgress();
  if (view === "config") loadConfig();
}
$$("nav button").forEach((b) => b.addEventListener("click", () => switchView(b.dataset.view)));

/* ---------- 平台卡 ---------- */
function platCard(p, compact){
  const badge = p.ok ? '<span class="badge ok">已登录</span>' : '<span class="badge bad">未登录</span>';
  return '<div class="card plat">' +
    '<div class="head"><div class="icon ' + esc(p.platform) + '">' + esc(p.brand) + '</div>' +
    '<div style="flex:1;min-width:0"><div class="name">' + esc(p.title) + '</div>' +
    '<div class="sub">' + (p.ok ? "登录态可用" : "未登录，无法同步关注") + '</div></div>' + badge + '</div>' +
    '<div class="kv"><span>过期</span><span>' + esc(p.ok ? p.expires : "—") + '</span>' +
    '<span>来源</span><span>' + esc(p.source) + '</span></div>' +
    '<div style="display:flex;gap:8px">' +
    '<button class="btn primary sm" data-login="' + esc(p.platform) + '">' + (p.ok ? "重新登录" : "登录") + '</button>' +
    (compact ? "" : '<button class="btn sm ghost" data-sync="' + esc(p.platform) + '">同步订阅</button>') +
    '</div></div>';
}
function bindCards(root){
  root.querySelectorAll("[data-login]").forEach((b) =>
    b.addEventListener("click", () => startLogin(b.dataset.login)));
  root.querySelectorAll("[data-sync]").forEach((b) =>
    b.addEventListener("click", async () => {
      try { watchJob((await api("/api/sync", { method:"POST", body:{ platform:b.dataset.sync } })).job_id); }
      catch (e) { toast(e.message, "err"); }
    }));
}

async function loadOverview(){
  try {
    const d = await api("/api/overview");
    S.overview = d;
    $("#footData").textContent = d.env.data_dir;
    $("#footDown").textContent = d.env.download_dir;
    $("#footReport").textContent = d.env.report_dir;
    $("#platCards").innerHTML = d.platforms.map((p) => platCard(p, true)).join("");
    bindCards($("#platCards"));
    $("#platformFull").innerHTML = d.platforms.map((p) => platCard(p, false)).join("");
    bindCards($("#platformFull"));
    renderJobs(d.jobs);
    renderRuns(d.runs);
    if (!$("#collectDay").value) $("#collectDay").value = d.last_day;
  } catch (e) { toast(e.message, "err"); }
}

function jobBadge(status){
  if (status === "running") return '<span class="badge run"><i class="pulse"></i>运行中</span>';
  if (status === "queued") return '<span class="badge run">排队中</span>';
  if (status === "done") return '<span class="badge ok">完成</span>';
  if (status === "failed") return '<span class="badge bad">失败</span>';
  return '<span class="badge">' + esc(status) + '</span>';
}
function fmtEta(sec){
  sec = Math.max(0, Math.round(Number(sec) || 0));
  if (!sec) return "";
  const m = Math.floor(sec / 60), s = sec % 60;
  return m ? (m + ":" + String(s).padStart(2, "0")) : (s + " 秒");
}
function progressBrief(pr){
  pr = pr || {};
  const bits = [];
  if (pr.stage) bits.push(pr.stage);
  if (pr.current && pr.total) bits.push(pr.current + "/" + pr.total);
  if (pr.size) bits.push((Number(pr.percent) || 0).toFixed(0) + "%");
  if (pr.speed) bits.push(fmtSize(pr.speed) + "/s");
  return bits.join(" · ");
}
/* 抽屉里的实时进度：百分比条 + 已下/总量 + 速度 + 剩余 + 当前文件 */
function renderJobProgress(job){
  const box = $("#jobProg"), pr = job.progress || {};
  const live = job.status === "running" || job.status === "queued";
  const has = live && !!(pr.stage || pr.current || pr.title);
  box.hidden = !has;
  if (!has) return;
  const pct = Math.max(0, Math.min(100, Number(pr.percent) || 0));
  $("#jobBar").style.width = pct.toFixed(1) + "%";
  const bits = [];
  if (pr.stage) bits.push(pr.stage);
  if (pr.current && pr.total) bits.push("第 " + pr.current + " / " + pr.total + " 个");
  if (pr.size) bits.push(fmtSize(pr.downloaded || 0) + " / " + fmtSize(pr.size));
  if (pr.speed) bits.push(fmtSize(pr.speed) + "/s");
  if (pr.eta) bits.push("剩余 " + fmtEta(pr.eta));
  if (pr.title) bits.push(pr.title);
  $("#jobProgText").textContent = bits.join(" · ");
  $("#jobPct").textContent = pr.size ? pct.toFixed(1) + "%" : "";
}
function updateJobRow(job){
  const cell = document.querySelector('[data-jobrow="' + job.id + '"]');
  if (!cell) return;
  cell.textContent = job.status === "running"
    ? (progressBrief(job.progress) || "运行中…")
    : (job.summary || job.error || "—");
}
function renderJobs(list){
  const box = $("#jobList");
  if (!list || !list.length) { box.innerHTML = '<div class="empty">暂无任务</div>'; return; }
  box.innerHTML = '<table><thead><tr><th>任务</th><th>状态</th><th>时间</th><th>结果</th></tr></thead><tbody>' +
    list.map((j) => '<tr><td>' + esc(j.title) + '</td><td>' + jobBadge(j.status) + '</td>' +
      '<td class="mono">' + esc(j.started_at || "") + (j.finished_at ? " → " + esc(j.finished_at) : "") + '</td>' +
      '<td style="color:var(--muted)" data-jobrow="' + esc(j.id) + '">' +
      esc(j.status === "running"
        ? (progressBrief(j.progress) || "运行中…")
        : (j.summary || j.error || "—")) + '</td></tr>').join("") +
    '</tbody></table>';
}

/* ---------- 登录 ---------- */
async function startLogin(platform){
  const wait = Number($("#loginWait").value || 300);
  try {
    const res = await api("/api/login", { method:"POST", body:{ platform, wait } });
    watchJob(res.job_id);
    toast(platform === "all" ? "已开始逐个登录" : "已打开登录窗口，请在浏览器里完成登录");
  } catch (e) { toast(e.message, "err"); }
}
$("#btnLoginAll").addEventListener("click", () => startLogin("all"));

/* ---------- 任务 ---------- */
function openDrawer(title){
  $("#drawer").classList.add("show");
  $("#jobTitle").textContent = title;
  $("#logBox").innerHTML = "";
  $("#jobProg").hidden = true;
  $("#jobBar").style.width = "0";
  $("#jobProgText").textContent = "准备中…";
  $("#jobPct").textContent = "";
}
$("#btnCloseDrawer").addEventListener("click", () => {
  // 只收起面板：轮询继续，概览表格里仍能看到进度，任务结束自动停
  $("#drawer").classList.remove("show");
});
function watchJob(id){
  jobId = id;
  openDrawer("任务运行中…");
  clearInterval(jobTimer);
  jobTimer = setInterval(pollJob, 900);
  pollJob();
}
async function pollJob(){
  if (!jobId) return;
  let job;
  try { job = await api("/api/jobs/" + encodeURIComponent(jobId)); } catch (e) { return; }
  if (!job || !job.id) return;
  $("#jobTitle").textContent = job.title || "任务";
  const cls = job.status === "failed" ? "bad" : job.status === "done" ? "ok" : "run";
  $("#jobBadge").className = "badge " + cls;
  $("#jobBadge").innerHTML = (job.status === "running" ? '<i class="pulse"></i>' : "") +
    ({ running:"运行中", done:"已完成", failed:"失败", queued:"排队中" }[job.status] || job.status);
  renderJobProgress(job);
  updateJobRow(job);
  const box = $("#logBox");
  const atBottom = box.scrollHeight - box.scrollTop - box.clientHeight < 40;
  box.innerHTML = (job.lines || []).map((l) =>
    '<div class="' + (/error|失败|Traceback/.test(l) ? "err" : /warn|注意|失败/.test(l) ? "warn" : "") + '">' +
    esc(l) + '</div>').join("") || '<div style="color:var(--dim)">等待输出…</div>';
  if (atBottom) box.scrollTop = box.scrollHeight;
  if (job.status === "done" || job.status === "failed") {
    clearInterval(jobTimer); jobTimer = null;
    $("#jobProg").hidden = true;
    toast(job.status === "done" ? "任务完成" : ("任务失败：" + (job.error || "")), job.status === "done" ? "ok" : "err");
    loadOverview();
    if (S.view === "progress") loadProgress();
  }
}
/* ---------- 进度 ---------- */
function statusBadge(status){
  if (status === "done") return '<span class="badge ok">完成</span>';
  if (status === "failed") return '<span class="badge bad">失败</span>';
  if (status === "running") return '<span class="badge run"><i class="pulse"></i>下载中</span>';
  if (status === "skipped") return '<span class="badge">已跳过</span>';
  return '<span class="badge">待下载</span>';
}

function barOf(node){
  const total = Math.max(node.total, 1);
  const pct = (n) => ((n || 0) / total * 100).toFixed(1);
  return '<div class="bar"><div class="done" style="width:' + pct(node.done) + '%"></div>' +
    '<div class="running" style="width:' + pct(node.running) + '%"></div>' +
    '<div class="failed" style="width:' + pct(node.failed) + '%"></div></div>';
}
async function loadProgress(){
  let d;
  try { d = await api("/api/days"); } catch (e) { return toast(e.message, "err"); }
  S.days = d.days;
  renderRuns(d.runs);
  const box = $("#dayList");
  if (!d.days.length) {
    box.innerHTML = '<div class="empty">还没有采集记录，先去「概览」跑一次采集</div>';
    return;
  }
  box.innerHTML = d.days.map((node) => {
    const done = node.done + node.skipped;
    return '<button class="day-item' + (S.day === node.day ? " active" : "") + '" data-day="' + esc(node.day) + '">' +
      '<div class="row"><span class="d">' + esc(node.day) + '</span>' +
      '<span class="s">' + done + '/' + node.total + ' · ' + fmtSize(node.size) + '</span></div>' +
      barOf(node) + '</button>';
  }).join("");
  box.querySelectorAll("[data-day]").forEach((b) =>
    b.addEventListener("click", () => loadDay(b.dataset.day)));
  if (!S.day || !d.days.some((n) => n.day === S.day)) S.day = d.days[0].day;
  loadDay(S.day);
}

function renderRuns(runs){
  const box = $("#runList");
  if (!runs || !runs.length) { box.innerHTML = '<div class="empty">还没有运行记录</div>'; return; }
  box.innerHTML = '<table><thead><tr><th>日期</th><th>平台</th><th>状态</th><th>新增</th><th>下载</th><th>失败</th><th>备注</th></tr></thead><tbody>' +
    runs.map((r) => '<tr><td class="mono">' + esc(r.day) + '</td><td>' + esc(PLAT[r.platform] || r.platform) + '</td>' +
      '<td>' + jobBadge(r.status === "ok" ? "done" : r.status === "error" ? "failed" : "running") + '</td>' +
      '<td class="mono">' + r.new_items + '</td><td class="mono">' + r.downloaded + '</td>' +
      '<td class="mono">' + r.failed + '</td><td style="color:var(--dim);max-width:300px">' +
      esc((r.message || "").slice(0, 120)) + '</td></tr>').join("") + '</tbody></table>';
}

async function loadDay(day){
  S.day = day;
  let d;
  try { d = await api("/api/day/" + encodeURIComponent(day)); } catch (e) { return toast(e.message, "err"); }
  S.day = day;
  $$(".day-item").forEach((b) => b.classList.toggle("active", b.dataset.day === day));
  const s = d.summary;
  $("#dayTitle").textContent = day;
  $("#daySub").textContent = s.total ? ("共 " + s.total + " 条 · " + fmtSize(s.size)) : "这一天没有内容";
  $("#dayStats").innerHTML =
    '<div class="stat"><div class="v">' + s.total + '</div><div class="l">总条数</div></div>' +
    '<div class="stat green"><div class="v">' + s.done + '</div><div class="l">已完成</div></div>' +
    '<div class="stat red"><div class="v">' + s.failed + '</div><div class="l">失败</div></div>' +
    '<div class="stat yellow"><div class="v">' + (s.pending + s.running) + '</div><div class="l">待下载</div></div>' +
    '<div class="stat"><div class="v">' + fmtSize(s.size) + '</div><div class="l">已占空间</div></div>';
  $("#dayBar").outerHTML = barOf(s).replace('class="bar"', 'class="bar" id="dayBar"');
  const total = Math.max(s.total, 1);
  $("#dayPct").textContent = Math.round((s.done + s.skipped) / total * 100) + "%";

  const plats = Object.entries(s.platforms || {});
  $("#dayPlatforms").innerHTML = plats.length > 1
    ? '<table style="margin-bottom:12px"><thead><tr><th>平台</th><th>总数</th><th>完成</th><th>失败</th><th>待下载</th><th>占用</th></tr></thead><tbody>' +
      plats.map(([p, n]) => '<tr><td>' + esc(PLAT[p] || p) + '</td>' +
        '<td class="mono">' + n.total + '</td><td class="mono">' + n.done + '</td>' +
        '<td class="mono">' + n.failed + '</td><td class="mono">' + (n.pending + n.running) + '</td>' +
        '<td class="mono">' + fmtSize(n.size) + '</td></tr>').join("") + '</tbody></table>'
    : "";

  $("#dayFailures").innerHTML = d.failures.length
    ? '<h3 style="font-size:13px;margin:0 0 6px;color:#ff8b84">失败 ' + d.failures.length + '</h3>' +
      d.failures.slice(0, 20).map((f) => '<div class="err" style="margin-bottom:4px">· ' +
        esc(PLAT[f.platform] || f.platform) + ' · ' + esc(f.author) + '：' + esc((f.error || "未知错误").slice(0, 200)) + '</div>').join("")
    : "";
  $("#dayActions").innerHTML =
    '<button class="btn sm ghost" data-recollect="' + esc(day) + '">重新采集这一天</button>' +
    (d.skipped_duration ? ' <button class="btn sm ghost" data-retry-duration="' + esc(day) + '">重试超时长 ' + d.skipped_duration + ' 条</button>' : "") +
    (d.report ? ' <a class="btn sm primary" href="' + esc(d.report) + '" target="_blank">打开日报</a>' : "");

  const rows = d.items.slice(0, 120);
  $("#dayItems").innerHTML = rows.length
    ? '<table><thead><tr><th>时间</th><th>作者</th><th>标题</th><th>状态</th><th>大小</th></tr></thead><tbody>' +
      rows.map((it) => '<tr><td class="mono">' + esc(it.published_at) + '</td><td>' + esc(it.author) + '</td>' +
        '<td><span class="t" title="' + esc(it.title) + '">' + esc(it.title) + '</span>' +
        '<span class="tag" style="margin-left:6px">' + esc(PLAT[it.platform] || it.platform) + '</span>' +
        '<span class="tag">' + esc(it.media_type || "-") + '</span></td>' +
        '<td' + (it.error ? ' title="' + esc(it.error) + '"' : '') + '>' + statusBadge(it.status) + '</td>' +
        '<td class="mono">' + (it.size ? fmtSize(it.size) : "—") + '</td></tr>').join("") +
      '</tbody></table>' + (d.items.length > rows.length ? '<div class="empty">仅显示前 120 条</div>' : "")
    : '<div class="empty">这一天没有采集到内容</div>';
}

/* ---------- 配置 ---------- */
function control(item){
  const k = esc(item.key), v = item.value == null ? "" : item.value;
  if (item.type === "bool") {
    return '<label class="switch"><input type="checkbox" data-key="' + k + '"' + (v === "true" ? " checked" : "") +
      '><span class="track"></span></label>';
  }
  if (item.type === "select") {
    return '<select data-key="' + k + '">' + item.options.map((o) =>
      '<option value="' + esc(o) + '"' + (o === v ? " selected" : "") + '>' + esc(o || "（空，用默认）") + '</option>').join("") +
      '</select>';
  }
  if (item.type === "textarea") {
    return '<textarea data-key="' + k + '" placeholder="' + esc(item.default) + '">' + esc(v) + '</textarea>';
  }
  if (item.type === "path") {
    return '<div class="path-ctl"><input type="text" data-key="' + k + '" value="' + esc(v) +
      '" placeholder="' + esc(item.default) + '"><button type="button" class="btn sm ghost" data-pick="' +
      k + '">选择…</button></div>';
  }
  return '<input type="text" data-key="' + k + '" value="' + esc(v) + '" placeholder="' + esc(item.default) + '">';
}
function fieldHtml(item){
  const wide = (item.type === "textarea" || item.type === "path") ? ' style="grid-column:1/-1"' : "";
  return '<div class="field"' + wide + '><label>' + esc(item.label) +
    (item.restart ? '<span class="restart">重启后生效</span>' : "") + '</label>' +
    control(item) + (item.help ? '<span class="help">' + esc(item.help) + '</span>' : "") + '</div>';
}
function renderConfig(groups){
  $("#configForm").innerHTML = groups.map((g) => {
    const normal = g.items.filter((i) => !i.advanced);
    const adv = g.items.filter((i) => i.advanced);
    return '<div class="card"><h3>' + esc(g.name) + '</h3>' +
      (g.help ? '<p class="hint">' + esc(g.help) + '</p>' : '<div style="height:8px"></div>') +
      '<div class="form-grid">' + normal.map(fieldHtml).join("") + '</div>' +
      (adv.length ? '<details class="adv"><summary>进阶项（' + adv.length + '）</summary><div class="form-grid">' +
        adv.map(fieldHtml).join("") + '</div></details>' : "") + '</div>';
  }).join("");
}
async function loadConfig(){
  let d;
  try { d = await api("/api/env"); } catch (e) { return toast(e.message, "err"); }
  S.env = d;
  renderConfig(d.groups);
  $("#saveMsg").textContent = "配置文件：" + d.status.path;
}
async function saveConfig(){
  const values = {};
  $$("#configForm [data-key]").forEach((el) => {
    values[el.dataset.key] = el.type === "checkbox" ? (el.checked ? "true" : "false") : el.value;
  });
  const btn = $("#btnSaveEnv");
  btn.disabled = true;
  try {
    const res = await api("/api/env", { method:"POST", body:{ values } });
    if (!res.changed.length) { toast("没有改动"); $("#saveMsg").textContent = "没有改动"; return; }
    let msg = "已保存 " + res.changed.length + " 项：" + res.changed.join("、");
    if (res.restart_required && res.restart_required.length) msg += "（" + res.restart_required.join("、") + " 需重启服务）";
    toast(msg, "ok");
    $("#saveMsg").textContent = msg + " · 备份 " + (res.backup || "—");
    await loadConfig();
  } catch (e) { toast(e.message, "err"); $("#saveMsg").textContent = e.message; }
  finally { btn.disabled = false; }
}

/* ---------- 目录选择 ---------- */
const PICK = { key:"", path:"", parent:"" };
function pickerClose(){ $("#picker").classList.remove("show"); }
function pickerQuick(){
  const st = (S.env && S.env.status) || {};
  return [["数据目录", st.data_dir], ["下载目录", st.download_dir], ["报告目录", st.report_dir]]
    .filter((x) => x[1])
    .map((x) => '<button class="btn sm ghost" data-pick-dir="' + esc(x[1]) + '">' + esc(x[0]) + '</button>')
    .join("");
}
function renderPicker(d){
  PICK.path = d.path || "";
  PICK.parent = d.parent || "";
  $("#pickerPath").textContent = PICK.path || "选择起点";
  $("#pickerUp").disabled = !PICK.parent;
  $("#pickerPick").disabled = !PICK.path;
  $("#pickerMsg").textContent = d.truncated ? "目录太多，只显示前 500 个" : "";
  const roots = (d.roots || []).map((r) =>
    '<button class="btn sm ghost" data-pick-dir="' + esc(r.path) + '">' + esc(r.name) + '</button>').join("");
  $("#pickerRoots").innerHTML = roots + pickerQuick();
  $("#pickerList").innerHTML = (d.dirs || []).length
    ? d.dirs.map((x) => '<div class="picker-dir" data-pick-dir="' + esc(x.path) + '"><span class="i">▸</span>' +
        esc(x.name) + '</div>').join("")
    : '<div class="empty">' + (PICK.path ? "没有子目录" : "先选一个起点") + '</div>';
}
async function pickerLoad(path){
  try { renderPicker(await api("/api/browse?path=" + encodeURIComponent(path))); }
  catch (e) { toast(e.message, "err"); }
}
async function pickerOpen(key, current){
  PICK.key = key;
  PICK.path = "";
  PICK.parent = "";
  $("#picker").classList.add("show");
  $("#pickerPath").textContent = "选择目录";
  $("#pickerRoots").innerHTML = "";
  $("#pickerMsg").textContent = "";
  $("#pickerList").innerHTML = '<div class="empty">读取中…</div>';
  $("#pickerUp").disabled = true;
  $("#pickerPick").disabled = true;
  const start = (current || "").trim();
  if (!start) {
    try { renderPicker(await api("/api/browse")); } catch (e) { toast(e.message, "err"); }
    return;
  }
  try {
    renderPicker(await api("/api/browse?path=" + encodeURIComponent(start)));
  } catch (e) {
    // 当前值是相对路径或目录已被删除：回到起点列表让用户重新选
    toast(e.message, "err");
    try { renderPicker(await api("/api/browse")); } catch (e2) { toast(e2.message, "err"); }
  }
}
$("#picker").addEventListener("click", (e) => {
  if (e.target === $("#picker")) { pickerClose(); return; }
  const dir = e.target.closest("[data-pick-dir]");
  if (dir) pickerLoad(dir.dataset.pickDir);
});
$("#pickerClose").addEventListener("click", pickerClose);
$("#pickerUp").addEventListener("click", () => { if (PICK.parent) pickerLoad(PICK.parent); });
$("#pickerPick").addEventListener("click", () => {
  if (!PICK.path) return;
  const input = $('#configForm [data-key="' + PICK.key + '"]');
  if (input) input.value = PICK.path;
  pickerClose();
});
$("#pickerBlank").addEventListener("click", () => {
  const input = $('#configForm [data-key="' + PICK.key + '"]');
  if (input) input.value = "";
  pickerClose();
});
document.addEventListener("keydown", (e) => { if (e.key === "Escape") pickerClose(); });
$("#configForm").addEventListener("click", (e) => {
  const btn = e.target.closest("[data-pick]");
  if (!btn) return;
  const input = $('#configForm [data-key="' + btn.dataset.pick + '"]');
  pickerOpen(btn.dataset.pick, input ? input.value : "");
});

/* ---------- 动作 ---------- */
async function collect(useForm){
  const day = useForm ? ($("#collectDay").value || "") : "";
  const platform = useForm ? $("#collectPlatform").value : "all";
  const download = useForm ? $("#collectDownload").checked : true;
  const sync = useForm ? $("#collectSync").checked : true;
  try {
    const res = await api("/api/collect", { method:"POST", body:{ day, platform, download, sync } });
    watchJob(res.job_id);
    toast("采集已开始，进度见右下角日志");
  } catch (e) { toast(e.message, "err"); }
}
$("#btnCollect").addEventListener("click", () => collect(true));
$("#btnCollectTop").addEventListener("click", () => collect(false));
$("#btnSaveEnv").addEventListener("click", saveConfig);
$("#btnReloadEnv").addEventListener("click", loadConfig);
$("#btnInit").addEventListener("click", async () => {
  try { watchJob((await api("/api/init", { method:"POST" })).job_id); } catch (e) { toast(e.message, "err"); }
});
$("#btnSync").addEventListener("click", async () => {
  try { watchJob((await api("/api/sync", { method:"POST", body:{ platform:"all" } })).job_id); }
  catch (e) { toast(e.message, "err"); }
});
document.addEventListener("click", (e) => {
  const redo = e.target.closest("[data-recollect]");
  if (redo) {
    const day = redo.dataset.recollect;
    $("#collectDay").value = day;
    collect(true);
    return;
  }
  const retry = e.target.closest("[data-retry-duration]");
  if (!retry) return;
  const day = retry.dataset.retryDuration;
  api("/api/collect", {
    method: "POST",
    body: { day, platform: "all", download: true, sync: false, retry_skipped: true },
  }).then((res) => {
    watchJob(res.job_id);
    toast("正在重试超时长跳过的内容");
  }).catch((err) => toast(err.message, "err"));
});

/* ---------- 启动 ---------- */
switchView("overview");
loadOverview().then(() => {
  if (S.overview && S.overview.busy) watchJob(S.overview.busy.id);
});
setInterval(() => {
  if (document.hidden) return;
  if (S.view === "progress") loadProgress();
  else if (S.view === "overview") loadOverview();
}, 8000);
</script>
</body>
</html>
"""
