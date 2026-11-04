(() => {
  'use strict';

  const $ = (id) => document.getElementById(id);
  const MB = 1024 * 1024;
  const GB = 1024 * MB;
  const MAX_POINTS = 90;

  const CX = 120, CY = 120, R = 92, START = 225, SWEEP = 270;

  const ui = {
    data: null,
    online: false,
    failures: 0,
    series: [],
    tasksSig: '',
    srcSig: '',
    logLen: -1,
    baseInit: false,
    busy: false,
    adapterSig: ''
  };

  // ---------------------------------------------------------------- format

  function fmtBytes(n, digits) {
    n = Number(n) || 0;
    if (n < 1024) return Math.round(n) + ' B';
    const units = ['KB', 'MB', 'GB', 'TB', 'PB'];
    let i = -1;
    do { n /= 1024; i++; } while (n >= 1024 && i < units.length - 1);
    const d = (digits === undefined) ? (n >= 100 ? 0 : 1) : digits;
    return n.toFixed(d) + ' ' + units[i];
  }

  function fmtRate(n) {
    const v = Number(n) || 0;
    if (v <= 0) return '0 B/s';
    return fmtBytes(v, v >= 10 * MB ? 1 : 2) + '/s';
  }

  function fmtRatio(n) {
    if (!n || !isFinite(n)) return '—';
    if (n >= 100) return n.toFixed(0) + '×';
    return n.toFixed(2) + '×';
  }

  function fmtUptime(ms) {
    const s = Math.floor((ms || 0) / 1000);
    const h = Math.floor(s / 3600);
    const m = Math.floor((s % 3600) / 60);
    if (h > 0) return '已运行 ' + h + ' 小时 ' + m + ' 分';
    return '已运行 ' + m + ' 分钟';
  }

  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, (c) => (
      { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]
    ));
  }

  function hostOf(url) {
    try { return new URL(url).host; } catch (e) { return ''; }
  }

  // ---------------------------------------------------------------- gauge

  function polar(deg, r) {
    const a = (deg - 90) * Math.PI / 180;
    return [CX + r * Math.cos(a), CY + r * Math.sin(a)];
  }

  function arcPath(a0, a1, r) {
    const p0 = polar(a0, r);
    const p1 = polar(a1, r);
    const large = (a1 - a0) > 180 ? 1 : 0;
    return 'M ' + p0[0].toFixed(2) + ' ' + p0[1].toFixed(2) +
      ' A ' + r + ' ' + r + ' 0 ' + large + ' 1 ' + p1[0].toFixed(2) + ' ' + p1[1].toFixed(2);
  }

  function initGauge() {
    const d = arcPath(START, START + SWEEP, R);
    $('gaugeTrack').setAttribute('d', d);
    $('gaugeValue').setAttribute('d', d);
    $('gaugeValue').style.strokeDasharray = '0 100';
  }

  function renderGauge(ratio, target, hasData) {
    const scale = Math.max(4, Math.ceil((target || 2) * 1.6));
    const pct = hasData ? Math.max(0, Math.min(1, ratio / scale)) : 0;
    const value = $('gaugeValue');
    value.style.strokeDasharray = (pct * 100).toFixed(2) + ' 100';
    value.style.opacity = pct > 0.002 ? '1' : '0';

    const tPct = Math.max(0, Math.min(1, (target || 0) / scale));
    const ang = START + tPct * SWEEP;
    const p1 = polar(ang, R - 15);
    const p2 = polar(ang, R + 15);
    const tick = $('gaugeTarget');
    tick.setAttribute('x1', p1[0].toFixed(2));
    tick.setAttribute('y1', p1[1].toFixed(2));
    tick.setAttribute('x2', p2[0].toFixed(2));
    tick.setAttribute('y2', p2[1].toFixed(2));
    tick.style.opacity = '0.55';
  }

  // ---------------------------------------------------------------- chart

  function niceMax(v) {
    if (v <= 0) return MB;
    const exp = Math.pow(10, Math.floor(Math.log10(v)));
    const f = v / exp;
    let n;
    if (f <= 1) n = 1;
    else if (f <= 2) n = 2;
    else if (f <= 5) n = 5;
    else n = 10;
    return n * exp;
  }

  function seriesPath(ctx, xs, ys) {
    if (!xs.length) return null;
    ctx.beginPath();
    ctx.moveTo(xs[0], ys[0]);
    for (let i = 1; i < xs.length - 1; i++) {
      const mx = (xs[i] + xs[i + 1]) / 2;
      const my = (ys[i] + ys[i + 1]) / 2;
      ctx.quadraticCurveTo(xs[i], ys[i], mx, my);
    }
    if (xs.length > 1) {
      ctx.lineTo(xs[xs.length - 1], ys[ys.length - 1]);
    }
    return ctx;
  }

  function drawChart() {
    const canvas = $('chart');
    if (!canvas) return;
    const dpr = window.devicePixelRatio || 1;
    const w = canvas.clientWidth;
    const h = canvas.clientHeight;
    if (!w || !h) return;
    if (canvas.width !== Math.round(w * dpr) || canvas.height !== Math.round(h * dpr)) {
      canvas.width = Math.round(w * dpr);
      canvas.height = Math.round(h * dpr);
    }
    const ctx = canvas.getContext('2d');
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, w, h);

    const padL = 0, padR = 46, padT = 12, padB = 8;
    const plotW = Math.max(10, w - padL - padR);
    const plotH = Math.max(10, h - padT - padB);

    const data = ui.series;
    let maxV = MB;
    for (const p of data) maxV = Math.max(maxV, p.rx, p.tx);
    const top = niceMax(maxV * 1.12);

    ctx.strokeStyle = 'rgba(255,255,255,0.055)';
    ctx.lineWidth = 1;
    ctx.setLineDash([3, 5]);
    for (let i = 0; i <= 3; i++) {
      const y = padT + plotH * (i / 3);
      ctx.beginPath();
      ctx.moveTo(padL, y);
      ctx.lineTo(padL + plotW, y);
      ctx.stroke();
    }
    ctx.setLineDash([]);

    ctx.fillStyle = 'rgba(138,154,172,0.75)';
    ctx.font = '10.5px "Segoe UI", "Microsoft YaHei UI", sans-serif';
    ctx.textAlign = 'left';
    ctx.textBaseline = 'middle';
    for (let i = 0; i <= 2; i++) {
      const val = top * (1 - i / 2);
      const y = padT + plotH * (i / 2);
      ctx.fillText(val >= MB ? (val / MB).toFixed(0) + ' MB/s' : (val / 1024).toFixed(0) + ' KB/s', padL + plotW + 8, y);
    }

    if (data.length < 2) {
      ctx.fillStyle = 'rgba(100,117,138,0.85)';
      ctx.textAlign = 'center';
      ctx.fillText('正在采集速率…', padL + plotW / 2, padT + plotH / 2);
      return;
    }

    const stepX = plotW / (MAX_POINTS - 1);
    const offset = MAX_POINTS - data.length;
    const xOf = (i) => padL + (offset + i) * stepX;
    const yOf = (v) => padT + plotH - Math.min(1, v / top) * plotH;

    const drawSeries = (key, color, fill1, fill2) => {
      const xs = data.map((_, i) => xOf(i));
      const ys = data.map((p) => yOf(p[key]));

      const grad = ctx.createLinearGradient(0, padT, 0, padT + plotH);
      grad.addColorStop(0, fill1);
      grad.addColorStop(1, fill2);
      ctx.beginPath();
      ctx.moveTo(xs[0], padT + plotH);
      for (let i = 0; i < xs.length; i++) ctx.lineTo(xs[i], ys[i]);
      ctx.lineTo(xs[xs.length - 1], padT + plotH);
      ctx.closePath();
      ctx.fillStyle = grad;
      ctx.fill();

      seriesPath(ctx, xs, ys);
      ctx.strokeStyle = color;
      ctx.lineWidth = 2;
      ctx.lineJoin = 'round';
      ctx.lineCap = 'round';
      ctx.stroke();

      const last = xs.length - 1;
      ctx.beginPath();
      ctx.arc(xs[last], ys[last], 3, 0, Math.PI * 2);
      ctx.fillStyle = color;
      ctx.fill();
      ctx.beginPath();
      ctx.arc(xs[last], ys[last], 6.5, 0, Math.PI * 2);
      ctx.fillStyle = color.replace('rgb', 'rgba').replace(')', ',0.18)');
      ctx.fill();
    };

    drawSeries('tx', 'rgb(251,191,36)', 'rgba(251,191,36,0.16)', 'rgba(251,191,36,0)');
    drawSeries('rx', 'rgb(56,224,164)', 'rgba(56,224,164,0.2)', 'rgba(56,224,164,0)');
  }

  // ---------------------------------------------------------------- render

  function setPill(cls, text) {
    const pill = $('statusPill');
    pill.className = 'pill ' + cls;
    $('statusText').textContent = text;
  }

  function renderStatus(s) {
    if (!ui.online) { setPill('offline', '连接断开'); return; }
    const eng = s.engine;
    if (eng.paused) { setPill('paused', '已暂停'); return; }
    if (eng.active) { setPill('running', '运行中'); return; }
    setPill('idle', '待机中');
  }

  function renderHero(s, ratio, deficit) {
    const cfg = s.config;
    const stats = s.stats;
    const eng = s.engine;
    const target = Number(cfg.targetRatio) || 2;
    let title = '正在采集数据';
    let sub = '读取本机网卡计数器，稍等片刻…';

    if (!ui.online) {
      title = '后台服务未连接';
      sub = '请重新启动程序，或稍候自动重试。';
    } else if (eng.paused) {
      title = '已暂停下载';
      sub = '点击右上角「继续」恢复自动补量。';
    } else if (stats.totalUp <= 0 && stats.totalDown <= 0) {
      title = '正在采集数据';
      sub = '正常上网后，这里会自动统计上传与下载。';
    } else if (ratio >= target) {
      title = '下载比例健康';
      sub = '当前 ' + fmtRatio(ratio) + '，已高于 ' + target.toFixed(1) + '× 目标。没有上传流量时会自动待机。';
    } else if (eng.active) {
      title = '正在补充下载';
      sub = '当前 ' + fmtRatio(ratio) + '，距离 ' + target.toFixed(1) + '× 目标还差 ' + fmtBytes(deficit) + '。';
    } else {
      title = '等待上传流量';
      sub = '当前 ' + fmtRatio(ratio) + '，检测到上传后会自动按比例补充下载。';
    }
    $('heroTitle').textContent = title;
    $('heroSub').textContent = sub;

    $('mTarget').textContent = target.toFixed(1) + '×';
    $('mDeficit').textContent = deficit > 0 ? fmtBytes(deficit) : '已达标';
    $('mAppDown').textContent = fmtBytes(stats.appDownloaded || 0);
    const rate = Number(eng.rate) || 0;
    if (cfg.mode === 'full' && (Number(cfg.maxRateMBs) || 0) <= 0) $('mRate').textContent = '不限速';
    else $('mRate').textContent = rate > 0 ? fmtRate(rate) : '—';
  }

  function renderStats(stats) {
    $('sDown').textContent = fmtBytes(stats.totalDown, 2);
    $('sUp').textContent = fmtBytes(stats.totalUp, 2);
    $('sTodayDown').textContent = fmtBytes(stats.todayDown, 2);
    $('sTodayUp').textContent = fmtBytes(stats.todayUp, 2);

    const hasBase = (Number(stats.baselineUp) || 0) + (Number(stats.baselineDown) || 0) > 0;
    $('sDownSub').textContent = hasBase ? '本月 · 含校准 ' + fmtBytes(stats.baselineDown) : '本月';
    $('sUpSub').textContent = hasBase ? '本月 · 含校准 ' + fmtBytes(stats.baselineUp) : '本月';
  }

  function renderTasks(s) {
    const list = $('taskList');
    const tasks = (s.tasks || []).slice(0, 7);
    const active = (s.tasks || []).filter((t) => t.state === 'running' || t.state === 'queued').length;
    $('taskCount').textContent = active > 0 ? (active + ' 个活动任务') : ((s.tasks || []).length ? '空闲' : '暂无任务');

    if (!tasks.length) {
      if (ui.tasksSig !== 'empty') {
        list.innerHTML = '<div class="empty">暂无下载任务 · 有上传流量时会自动开始</div>';
        ui.tasksSig = 'empty';
      }
      return;
    }

    const sig = tasks.map((t) => t.id + ':' + t.state).join('|');
    if (sig !== ui.tasksSig) {
      ui.tasksSig = sig;
      list.innerHTML = tasks.map((t) => {
        const stateText = { running: '下载中', queued: '排队中', done: '已完成', failed: '失败' }[t.state] || t.state;
        return '<div class="task ' + esc(t.state) + '" data-id="' + esc(t.id) + '">' +
          '<div class="t-head">' +
            '<div class="t-src">' + esc(t.source) + '<span class="t-host">' + esc(hostOf(t.url)) + '</span></div>' +
            '<span class="chip ' + esc(t.state) + '">' + esc(stateText) + '</span>' +
          '</div>' +
          '<div class="bar"><i></i></div>' +
          '<div class="t-foot"><span class="t-bytes"></span><span class="t-speed"></span></div>' +
        '</div>';
      }).join('');
    }

    for (const t of tasks) {
      const node = list.querySelector('[data-id="' + t.id + '"]');
      if (!node) continue;
      const pct = t.target > 0 ? Math.max(0, Math.min(100, t.bytes / t.target * 100)) : 0;
      const bar = node.querySelector('.bar i');
      if (bar) bar.style.width = pct.toFixed(1) + '%';
      const b = node.querySelector('.t-bytes');
      if (b) b.textContent = fmtBytes(t.bytes) + ' / ' + fmtBytes(t.target);
      const sp = node.querySelector('.t-speed');
      if (sp) {
        if (t.state === 'running') sp.textContent = fmtRate(t.speed);
        else if (t.state === 'failed') sp.textContent = t.error || '失败';
        else if (t.state === 'queued') sp.textContent = '等待中';
        else sp.textContent = '';
      }
    }
  }

  function renderSources(s) {
    const cfg = s.config;
    const health = s.health || {};
    const now = s.now || Date.now();
    const sources = cfg.sources || [];
    const sig = sources.map((x) => x.id + ':' + (x.enabled ? 1 : 0) + ':' + ((health[x.id] && health[x.id].badUntil > now) ? 1 : 0)).join('|');
    if (sig === ui.srcSig) return;
    ui.srcSig = sig;

    const list = $('srcList');
    if (!sources.length) {
      list.innerHTML = '<div class="empty">还没有数据源</div>';
      return;
    }
    list.innerHTML = sources.map((src) => {
      const bad = health[src.id] && health[src.id].badUntil > now;
      return '<div class="src">' +
        '<div class="src-info"><span class="src-name">' + esc(src.name) + '</span>' +
        '<span class="src-host">' + esc(hostOf(src.url) || src.url) + '</span></div>' +
        (bad ? '<span class="src-badge">不可用</span>' : '') +
        '<label class="switch"><input type="checkbox" data-src="' + esc(src.id) + '"' + (src.enabled ? ' checked' : '') + '><i></i></label>' +
        '<button class="icon-btn" data-del="' + esc(src.id) + '" title="删除">×</button>' +
      '</div>';
    }).join('');
  }

  function renderLog(s) {
    const log = s.log || [];
    if (log.length === ui.logLen) return;
    ui.logLen = log.length;
    const box = $('log');
    const atBottom = box.scrollHeight - box.scrollTop - box.clientHeight < 26;
    box.innerHTML = log.slice(-40).map((line) => '<div>' + esc(line) + '</div>').join('');
    if (atBottom) box.scrollTop = box.scrollHeight;
  }

  function render() {
    const s = ui.data;
    if (!s) return;
    const stats = s.stats || {};
    const net = s.net || {};
    const eng = s.engine || {};
    const target = Number(s.config.targetRatio) || 2;
    const ratio = Number(stats.ratio) || 0;
    const deficit = Math.max(0, target * (Number(stats.totalUp) || 0) - (Number(stats.totalDown) || 0));
    const hasData = (Number(stats.totalUp) || 0) > 0;

    renderStatus(s);
    $('hdrUp').textContent = fmtRate(net.txRate);
    $('hdrDown').textContent = fmtRate(net.rxRate);

    renderGauge(ratio, target, hasData);
    $('ratioValue').innerHTML = hasData ? fmtRatio(ratio) : '—';
    renderHero(s, ratio, deficit);
    renderStats(stats);
    renderTasks(s);
    renderSources(s);
    renderLog(s);

    if (eng.paused) $('btnToggle').textContent = '继续';
    else $('btnToggle').textContent = '暂停';

    $('footerUptime').textContent = fmtUptime(s.uptime);

    ui.series.push({ rx: Number(net.rxRate) || 0, tx: Number(net.txRate) || 0 });
    while (ui.series.length > MAX_POINTS) ui.series.shift();
    drawChart();

    syncConfig(s);
  }

  // ---------------------------------------------------------------- controls

  function sliderFill(el) {
    if (!el) return;
    const min = Number(el.min) || 0;
    const max = Number(el.max) || 100;
    const val = Number(el.value) || 0;
    const pct = max > min ? ((val - min) / (max - min)) * 100 : 0;
    el.style.setProperty('--pct', pct.toFixed(1) + '%');
  }

  function setSlider(id, value, label, formatter) {
    const el = $(id);
    if (!el) return;
    if (document.activeElement !== el) el.value = value;
    sliderFill(el);
    const out = $(label);
    if (out) out.textContent = formatter(Number(el.value));
  }

  function buildAdapterOptions(cfg, net) {
    const adapters = (net && net.adapters) || [];
    const sig = adapters.map((a) => a.name).join('|') + '#' + cfg.adapter;
    if (sig === ui.adapterSig) return;
    ui.adapterSig = sig;
    const sel = $('adapterSel');
    const current = cfg.adapter || 'auto';
    let html = '<option value="auto">自动（推荐）</option><option value="all">全部接口</option>';
    for (const a of adapters) {
      html += '<option value="' + esc(a.name) + '">' + esc(a.label || a.name) + '</option>';
    }
    sel.innerHTML = html;
    const exists = Array.from(sel.options).some((o) => o.value === current);
    sel.value = exists ? current : 'auto';
  }

  function syncConfig(s) {
    const cfg = s.config;
    setSlider('targetRatio', cfg.targetRatio, 'ratioOut', (v) => v.toFixed(1) + '×');
    setSlider('maxRate', cfg.maxRateMBs, 'maxRateOut', (v) => v <= 0 ? '不限速' : v.toFixed(0) + ' MB/s');
    setSlider('manualRate', cfg.manualRateMBs, 'manualOut', (v) => v.toFixed(0) + ' MB/s');
    setSlider('concurrency', cfg.concurrency, 'concOut', (v) => v.toFixed(0));
    setSlider('chunkMB', cfg.chunkMB, 'chunkOut', (v) => v + ' MB');

    const disk = $('diskCapMB');
    if (document.activeElement !== disk) disk.value = cfg.diskCapMB;

    const only = $('onlyWhenUploading');
    if (document.activeElement !== only) only.checked = !!cfg.onlyWhenUploading;
    const keep = $('keepFiles');
    if (document.activeElement !== keep) keep.checked = !!cfg.keepFiles;

    for (const btn of $('modeSeg').children) {
      btn.classList.toggle('active', btn.dataset.mode === cfg.mode);
    }
    const hints = {
      auto: '按上传速度动态补充下载，让比例稳定在目标之上。',
      full: '持续以最大速度下载，最快拉高比例，适合临时冲刺。',
      manual: '使用固定速度下载，速度由下方滑块决定。'
    };
    $('modeHint').textContent = hints[cfg.mode] || hints.auto;

    buildAdapterOptions(cfg, s.net);

    if (!ui.baseInit) {
      ui.baseInit = true;
      const st = s.stats || {};
      $('baseUpGB').value = (Number(st.baselineUp) || 0) > 0 ? +(st.baselineUp / GB).toFixed(2) : '';
      $('baseDownGB').value = (Number(st.baselineDown) || 0) > 0 ? +(st.baselineDown / GB).toFixed(2) : '';
    }
  }

  async function post(path, body) {
    try {
      const res = await fetch(path, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body || {})
      });
      return await res.json();
    } catch (e) {
      showToast('操作失败，后台服务可能已断开');
      return null;
    }
  }

  function saveConfig(patch) {
    return post('/api/config', patch).then((r) => {
      if (r && r.ok && ui.data) {
        ui.data.config = r.config;
        syncConfig(ui.data);
      }
    });
  }

  let toastTimer = null;
  function showToast(msg) {
    const el = $('toast');
    el.textContent = msg;
    el.classList.add('show');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => el.classList.remove('show'), 2600);
  }

  function bindControls() {
    const bindSlider = (id, key, transform) => {
      const el = $(id);
      el.addEventListener('input', () => {
        sliderFill(el);
        const outId = { targetRatio: 'ratioOut', maxRate: 'maxRateOut', manualRate: 'manualOut', concurrency: 'concOut', chunkMB: 'chunkOut' }[id];
        if (outId) {
          const v = Number(el.value);
          $(outId).textContent = id === 'targetRatio' ? v.toFixed(1) + '×'
            : id === 'maxRate' ? (v <= 0 ? '不限速' : v + ' MB/s')
            : id === 'manualRate' ? v + ' MB/s'
            : id === 'chunkMB' ? v + ' MB' : String(v);
        }
      });
      el.addEventListener('change', () => {
        const v = Number(el.value);
        const patch = {};
        patch[key] = transform ? transform(v) : v;
        saveConfig(patch);
      });
      sliderFill(el);
    };

    bindSlider('targetRatio', 'targetRatio');
    bindSlider('maxRate', 'maxRateMBs');
    bindSlider('manualRate', 'manualRateMBs');
    bindSlider('concurrency', 'concurrency');
    bindSlider('chunkMB', 'chunkMB');

    for (const btn of $('modeSeg').children) {
      btn.addEventListener('click', () => {
        saveConfig({ mode: btn.dataset.mode });
      });
    }

    $('onlyWhenUploading').addEventListener('change', (e) => saveConfig({ onlyWhenUploading: e.target.checked }));
    $('keepFiles').addEventListener('change', (e) => saveConfig({ keepFiles: e.target.checked }));

    $('diskCapMB').addEventListener('change', (e) => {
      const v = Math.max(128, Number(e.target.value) || 2048);
      e.target.value = v;
      saveConfig({ diskCapMB: v });
    });

    $('adapterSel').addEventListener('change', (e) => saveConfig({ adapter: e.target.value }));

    $('btnClean').addEventListener('click', async () => {
      await post('/api/control', { action: 'clean' });
      showToast('已清理下载缓存');
    });

    $('btnToggle').addEventListener('click', async () => {
      const paused = ui.data && ui.data.engine && ui.data.engine.paused;
      await post('/api/control', { action: paused ? 'start' : 'pause' });
      showToast(paused ? '已继续自动补量' : '已暂停下载');
      poll();
    });

    $('btnQuit').addEventListener('click', async () => {
      if (!confirm('确定退出比例守护吗？后台下载会立即停止。')) return;
      await post('/api/control', { action: 'shutdown' });
      $('overlay').hidden = false;
    });

    $('btnSaveBase').addEventListener('click', async () => {
      const up = Math.max(0, Number($('baseUpGB').value) || 0) * GB;
      const down = Math.max(0, Number($('baseDownGB').value) || 0) * GB;
      await post('/api/baseline', { up: Math.round(up), down: Math.round(down) });
      showToast('校准已保存');
      poll();
    });

    $('btnResetStats').addEventListener('click', async () => {
      if (!confirm('确定清零本月统计（含校准值）吗？')) return;
      await post('/api/baseline', { reset: true });
      $('baseUpGB').value = '';
      $('baseDownGB').value = '';
      showToast('统计已清零');
      poll();
    });

    $('btnAddSource').addEventListener('click', () => {
      $('srcAdd').hidden = !$('srcAdd').hidden;
      if (!$('srcAdd').hidden) $('srcUrl').focus();
    });

    $('btnCancelSource').addEventListener('click', () => {
      $('srcAdd').hidden = true;
      $('srcUrl').value = '';
      $('srcName').value = '';
    });

    $('btnSaveSource').addEventListener('click', async () => {
      const url = $('srcUrl').value.trim();
      if (!url) { showToast('请填写下载链接'); return; }
      const r = await post('/api/sources', { action: 'add', url: url, name: $('srcName').value.trim() });
      if (r && r.ok) {
        showToast('数据源已添加');
        $('srcUrl').value = '';
        $('srcName').value = '';
        ui.srcSig = '';
        ui.data.config = r.config;
        poll();
      } else if (r && r.error) {
        showToast(r.error);
      }
    });

    $('srcList').addEventListener('click', async (e) => {
      const del = e.target.closest('[data-del]');
      if (del) {
        await post('/api/sources', { action: 'remove', id: del.dataset.del });
        ui.srcSig = '';
        poll();
        return;
      }
    });

    $('srcList').addEventListener('change', async (e) => {
      const t = e.target;
      if (t && t.dataset && t.dataset.src) {
        await post('/api/sources', { action: 'toggle', id: t.dataset.src, enabled: t.checked });
        ui.srcSig = '';
        poll();
      }
    });
  }

  // ---------------------------------------------------------------- polling

  async function poll() {
    if (ui.busy) return;
    ui.busy = true;
    try {
      const res = await fetch('/api/state', { cache: 'no-store' });
      if (!res.ok) throw new Error('bad status');
      const data = await res.json();
      ui.data = data;
      ui.online = true;
      ui.failures = 0;
      render();
    } catch (e) {
      ui.failures++;
      if (ui.failures >= 2) {
        ui.online = false;
        setPill('offline', '连接断开');
      }
    } finally {
      ui.busy = false;
    }
  }

  function ping() {
    fetch('/api/ping', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}' }).catch(() => {});
  }

  // ---------------------------------------------------------------- boot

  initGauge();
  bindControls();
  drawChart();
  poll();
  setInterval(poll, 1000);
  setInterval(ping, 3000);

  window.addEventListener('resize', () => drawChart());
})();
