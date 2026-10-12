/* ============================================================
   MyHub PC 原型 · 统一单色线形图标集
   - 全部图标使用 currentColor，颜色由上下文文字色决定
   - 对齐《需求分析文档》§2.10「图标：线形风格统一图标集」
   - 用法：<i data-i="folder"></i>，脚本自动替换为内联 SVG
   ============================================================ */

const MYHUB_ICONS = {
  /* ---- 导航 ---- */
  book:        '<path d="M4 19.5A2.5 2.5 0 0 1 6.5 17H20"/><path d="M6.5 2H20v20H6.5A2.5 2.5 0 0 1 4 19.5v-15A2.5 2.5 0 0 1 6.5 2z"/>',
  star:        '<path d="M12 2.5l2.9 5.88 6.5.95-4.7 4.58 1.1 6.47L12 17.33l-5.8 3.05 1.1-6.47-4.7-4.58 6.5-.95z"/>',
  zap:         '<path d="M13 2L3 14h9l-1 8 10-12h-9z"/>',
  folder:      '<path d="M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z"/>',
  globe:       '<circle cx="12" cy="12" r="9"/><path d="M3 12h18"/><path d="M12 3a14 14 0 0 1 3.6 9 14 14 0 0 1-3.6 9 14 14 0 0 1-3.6-9A14 14 0 0 1 12 3z"/>',
  settings:    '<path d="M20 7h-8"/><path d="M14 17H4"/><circle cx="17" cy="17" r="3"/><circle cx="7" cy="7" r="3"/>',

  /* ---- 文件类型 ---- */
  film:        '<rect x="2.5" y="3" width="19" height="18" rx="2"/><path d="M7 3v18M17 3v18M2.5 12h19M2.5 7.5h4.5M2.5 16.5h4.5M17 16.5h4.5M17 7.5h4.5"/>',
  music:       '<path d="M9 18V5l11-2v13"/><circle cx="6" cy="18" r="3"/><circle cx="17" cy="16" r="3"/>',
  'book-open': '<path d="M2 4h5.5A3.5 3.5 0 0 1 11 7.5V21a3 3 0 0 0-3-2.5H2z"/><path d="M22 4h-5.5A3.5 3.5 0 0 0 13 7.5V21a3 3 0 0 1 3-2.5h6z"/>',
  comic:       '<rect x="4" y="2.5" width="15" height="19" rx="1.6"/><path d="M4 7h15M8 2.5v19"/>',
  image:       '<rect x="3" y="3" width="18" height="18" rx="2"/><circle cx="8.5" cy="9" r="1.6"/><path d="M21 15.5l-4.5-4.5L5.5 21"/>',
  'file-text': '<path d="M14 2.5H6.5a2 2 0 0 0-2 2v15a2 2 0 0 0 2 2h11a2 2 0 0 0 2-2V8z"/><path d="M14 2.5V8h5.5"/><path d="M8.5 13h7M8.5 17h5"/>',
  subtitle:    '<rect x="3" y="5" width="18" height="14" rx="2"/><path d="M7 14.5h4M14.5 14.5h2.5M7 10.5h2.5M13 10.5h4"/>',

  /* ---- 连接源 ---- */
  server:      '<rect x="2.5" y="3" width="19" height="7" rx="2"/><rect x="2.5" y="14" width="19" height="7" rx="2"/><path d="M6.5 6.5h.01M6.5 17.5h.01"/>',
  cloud:       '<path d="M17.5 19H7a4.5 4.5 0 1 1 1.2-8.84A6 6 0 0 1 19 12.4a3.3 3.3 0 0 1-1.5 6.6z"/>',
  'hard-drive':'<path d="M22 12.5H2"/><path d="M5.6 5.2L2 12.5V18a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-5.5l-3.6-7.3A2 2 0 0 0 16.6 4H7.4a2 2 0 0 0-1.8 1.2z"/><path d="M6 16.5h.01M10 16.5h.01"/>',
  database:    '<ellipse cx="12" cy="5.5" rx="8.5" ry="3"/><path d="M20.5 12c0 1.66-3.8 3-8.5 3s-8.5-1.34-8.5-3"/><path d="M3.5 5.5v13c0 1.66 3.8 3 8.5 3s8.5-1.34 8.5-3v-13"/>',

  /* ---- 导航控制 ---- */
  'arrow-left':  '<path d="M19 12H5M12 19l-7-7 7-7"/>',
  'arrow-right': '<path d="M5 12h14M12 5l7 7-7 7"/>',
  'chevron-left':  '<path d="M15 18l-6-6 6-6"/>',
  'chevron-right': '<path d="M9 18l6-6-6-6"/>',
  'chevron-down':  '<path d="M6 9.5l6 6 6-6"/>',
  refresh:     '<path d="M21.5 4.5v6h-6"/><path d="M2.5 19.5v-6h6"/><path d="M4.6 9.5a8 8 0 0 1 13.2-3L21.5 10"/><path d="M19.4 14.5a8 8 0 0 1-13.2 3L2.5 14"/>',
  menu:        '<path d="M3.5 12h17M3.5 6h17M3.5 18h17"/>',

  /* ---- 视图与工具栏 ---- */
  grid:        '<rect x="3" y="3" width="7.5" height="7.5" rx="1.4"/><rect x="13.5" y="3" width="7.5" height="7.5" rx="1.4"/><rect x="13.5" y="13.5" width="7.5" height="7.5" rx="1.4"/><rect x="3" y="13.5" width="7.5" height="7.5" rx="1.4"/>',
  list:        '<path d="M8.5 6.5h12M8.5 12h12M8.5 17.5h12"/><path d="M3.8 6.5h.01M3.8 12h.01M3.8 17.5h.01"/>',
  sort:        '<path d="M3.5 16l3.5 3.5L10.5 16"/><path d="M7 19.5V4.5"/><path d="M20.5 8L17 4.5 13.5 8"/><path d="M17 4.5v15"/>',
  search:      '<circle cx="11" cy="11" r="7.5"/><path d="M20.5 20.5l-4.2-4.2"/>',
  plus:        '<path d="M12 5v14M5 12h14"/>',
  x:           '<path d="M18 6L6 18M6 6l12 12"/>',
  check:       '<path d="M20 6.5L9.2 17.3 4 12.1"/>',
  more:        '<circle cx="12" cy="12" r="1.3" fill="currentColor" stroke="none"/><circle cx="19" cy="12" r="1.3" fill="currentColor" stroke="none"/><circle cx="5" cy="12" r="1.3" fill="currentColor" stroke="none"/>',
  minus:       '<path d="M5 12h14"/>',

  /* ---- 文件操作 ---- */
  upload:      '<path d="M21 15.5V19a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-3.5"/><path d="M17 8l-5-5-5 5"/><path d="M12 3v13"/>',
  download:    '<path d="M21 15.5V19a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-3.5"/><path d="M7 10l5 5 5-5"/><path d="M12 15V2.5"/>',
  trash:       '<path d="M3.5 6h17"/><path d="M19 6v13.5a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a1.8 1.8 0 0 1 1.8-1.8h4.4A1.8 1.8 0 0 1 16 4v2"/><path d="M10 11v6M14 11v6"/>',
  edit:        '<path d="M11 4H4.5a2 2 0 0 0-2 2v13.5a2 2 0 0 0 2 2H18a2 2 0 0 0 2-2V13"/><path d="M18.4 2.6a2.1 2.1 0 0 1 3 3L12 15l-4 1 1-4z"/>',
  copy:        '<rect x="9" y="9" width="12.5" height="12.5" rx="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4.5a2 2 0 0 1 2-2h8.5a2 2 0 0 1 2 2V5"/>',
  move:        '<path d="M15 14l5-5-5-5"/><path d="M4 20v-7a4 4 0 0 1 4-4h12"/>',
  target:      '<circle cx="12" cy="12" r="9"/><circle cx="12" cy="12" r="5"/><circle cx="12" cy="12" r="1.4" fill="currentColor" stroke="none"/>',
  info:        '<circle cx="12" cy="12" r="9"/><path d="M12 16.5v-5M12 8h.01"/>',
  'check-square':'<path d="M9 11l3 3 9.5-9.5"/><path d="M20.5 12v7a2 2 0 0 1-2 2h-13a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2h11"/>',
  'external':  '<path d="M18 13.5V19a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h5.5"/><path d="M15 3h6v6"/><path d="M10 14L21 3"/>',
  'folder-open':'<path d="M6 19l3-8h13l-3 8z"/><path d="M19 11V9a2 2 0 0 0-2-2h-5.5l-2-2.5H4a2 2 0 0 0-2 2V19h4"/>',

  /* ---- 播放器 ---- */
  play:        '<path d="M6 3.5l14 8.5-14 8.5z" fill="currentColor" stroke="none"/>',
  pause:       '<rect x="6" y="4" width="4" height="16" rx="1" fill="currentColor" stroke="none"/><rect x="14" y="4" width="4" height="16" rx="1" fill="currentColor" stroke="none"/>',
  'skip-back': '<path d="M19.5 19.5L9.5 12l10-7.5z" fill="currentColor" stroke="none"/><path d="M5 19.5v-15"/>',
  'skip-fwd':  '<path d="M4.5 4.5l10 7.5-10 7.5z" fill="currentColor" stroke="none"/><path d="M19 4.5v15"/>',
  rewind:      '<path d="M11 19L2.5 12 11 5z" fill="currentColor" stroke="none"/><path d="M21.5 19L13 12l8.5-7z" fill="currentColor" stroke="none"/>',
  forward:     '<path d="M13 19l8.5-7L13 5z" fill="currentColor" stroke="none"/><path d="M2.5 19L11 12 2.5 5z" fill="currentColor" stroke="none"/>',
  volume:      '<path d="M11 5L6.5 9H3v6h3.5L11 19z"/><path d="M15.5 9.2a4 4 0 0 1 0 5.6"/><path d="M18.4 6.3a8 8 0 0 1 0 11.4"/>',
  lock:        '<rect x="4" y="10.5" width="16" height="11" rx="2"/><path d="M7.5 10.5V7a4.5 4.5 0 0 1 9 0v3.5"/>',
  maximize:    '<path d="M8 3.5H5.5a2 2 0 0 0-2 2V8"/><path d="M20.5 8V5.5a2 2 0 0 0-2-2H16"/><path d="M3.5 16v2.5a2 2 0 0 0 2 2H8"/><path d="M16 20.5h2.5a2 2 0 0 0 2-2V16"/>',
  pip:         '<rect x="2.5" y="4" width="19" height="16" rx="2"/><rect x="12" y="11.5" width="8" height="6.5" rx="1.2"/>',
  replay:      '<path d="M3 3.5v6h6"/><path d="M3.6 14.5a9 9 0 1 0 1.9-9.3L3 8"/>',
  speed:       '<circle cx="12" cy="13" r="8"/><path d="M12 13l4-4"/><path d="M12 5V2.5"/>',

  /* ---- 阅读器 ---- */
  'type-aa':   '<path d="M4 8V4.5h16V8"/><path d="M9.5 20h5"/><path d="M12 4.5V20"/>',
  sun:         '<circle cx="12" cy="12" r="4.2"/><path d="M12 2.5v2M12 19.5v2M4.2 4.2l1.4 1.4M18.4 18.4l1.4 1.4M2.5 12h2M19.5 12h2M4.2 19.8l1.4-1.4M18.4 5.6l1.4-1.4"/>',
  bookmark:    '<path d="M19 21l-7-5-7 5V5a2 2 0 0 1 2-2h10a2 2 0 0 1 2 2z"/>',
  clock:       '<circle cx="12" cy="12" r="9"/><path d="M12 6.5V12l3.5 2"/>',

  /* ---- 设置 / 系统 ---- */
  link:        '<path d="M9.5 17H7.5a5 5 0 0 1 0-10h2"/><path d="M14.5 7h2a5 5 0 0 1 0 10h-2"/><path d="M8 12h8"/>',
  palette:     '<path d="M12 21.5a9.5 9.5 0 1 1 9.5-9.5c0 2.2-1.8 4-4 4h-1.8a1.7 1.7 0 0 0-1.3 2.8 1.7 1.7 0 0 1-1.3 2.7z"/><circle cx="7.5" cy="11" r="1.2" fill="currentColor" stroke="none"/><circle cx="11" cy="7.5" r="1.2" fill="currentColor" stroke="none"/><circle cx="15.5" cy="9" r="1.2" fill="currentColor" stroke="none"/>',
  'play-circle':'<circle cx="12" cy="12" r="9"/><path d="M10 8.5l6 3.5-6 3.5z" fill="currentColor" stroke="none"/>',
  shield:      '<path d="M12 21.5s7.5-3.6 7.5-9.5V5.2L12 2.5 4.5 5.2V12c0 5.9 7.5 9.5 7.5 9.5z"/>',
  package:     '<path d="M16.5 9.4L7.5 4.2"/><path d="M21 16V8a2 2 0 0 0-1-1.73l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 3 8v8a2 2 0 0 0 1 1.73l7 4a2 2 0 0 0 2 0l7-4A2 2 0 0 0 21 16z"/><path d="M3.3 7l8.7 5 8.7-5"/><path d="M12 22V12"/>',
  user:        '<path d="M20 21v-2a4 4 0 0 0-4-4H8a4 4 0 0 0-4 4v2"/><circle cx="12" cy="7.5" r="4"/>',
  'eye-off':   '<path d="M17.9 17.9A9.9 9.9 0 0 1 12 20c-7 0-10.5-8-10.5-8a18 18 0 0 1 4.8-5.6"/><path d="M9.9 4.4A9.1 9.1 0 0 1 12 4c7 0 10.5 8 10.5 8a18 18 0 0 1-2.1 3.1"/><path d="M14.1 14.1a3 3 0 1 1-4.2-4.2"/><path d="M2 2l20 20"/>',
  alert:       '<path d="M10.3 3.9L2 18a2 2 0 0 0 1.7 3h16.6a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0z"/><path d="M12 9.5v4M12 17.5h.01"/>',
  monitor:     '<rect x="2.5" y="3.5" width="19" height="13" rx="2"/><path d="M8 20.5h8M12 16.5v4"/>',
  'cloud-off': '<path d="M17.5 19H7a4.5 4.5 0 0 1-.6-8.96"/><path d="M2 2l20 20"/>',
  wifi:        '<path d="M5 12.5a10 10 0 0 1 14 0"/><path d="M8.5 16a5 5 0 0 1 7 0"/><path d="M12 19.5h.01"/>',

  /* ---- 品牌 ---- */
  logo:        '<path d="M4 19V5.5l8 7 8-7V19" stroke-width="2.2"/>'
};

(function () {
  const SPRITE = '<svg xmlns="http://www.w3.org/2000/svg" style="display:none" aria-hidden="true">'
    + Object.entries(MYHUB_ICONS)
        .map(([k, v]) => `<symbol id="i-${k}" viewBox="0 0 24 24">${v}</symbol>`)
        .join('')
    + '</svg>';

  function render() {
    document.body.insertAdjacentHTML('afterbegin', SPRITE);
    document.querySelectorAll('[data-i]').forEach(el => {
      const n = el.getAttribute('data-i');
      if (!MYHUB_ICONS[n]) { console.warn('[icons] 未定义:', n); return; }
      el.innerHTML = `<svg class="svgic" aria-hidden="true"><use href="#i-${n}"></use></svg>`;
    });
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', render);
  } else {
    render();
  }
})();
