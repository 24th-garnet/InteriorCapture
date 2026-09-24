'use strict';
// 平面図と 3D は同じ枠（主方向で回し、原点は図面の左上、床が Y=0、単位 m）に
// 載っている。だから同期は引き算だけで済む。座標変換はここには無い。

const NS = 'http://www.w3.org/2000/svg';
const svg = document.getElementById('plan');
const canvas = document.getElementById('gl');

let current = null;          // 選択中のバンドル id
let plan = null;             // 平面図のデータ
let state = new Map();       // id -> {dx, dz, dyaw}（m と度）
let sel = null;
let dirty = false;

const el = (tag, attrs, parent) => {
  const n = document.createElementNS(NS, tag);
  for (const k in attrs) n.setAttribute(k, attrs[k]);
  (parent || svg).appendChild(n);
  return n;
};
const fmt = (v, d = 0) => (v === null || v === undefined ? '—' : v.toFixed(d));
const api = (p, opts) => fetch(p, opts).then(r => r.json());

// --- 一覧 -------------------------------------------------------------------

async function loadList() {
  const box = document.getElementById('scans');
  box.innerHTML = '<p class="empty">読み込み中…</p>';
  const scans = await api('/api/scans');
  if (!scans.length) { box.innerHTML = '<p class="empty">.mdr が見つかりません</p>'; return; }
  box.innerHTML = '';
  for (const s of scans) {
    const d = document.createElement('div');
    d.className = 'scan' + (s.id === current ? ' sel' : '');
    d.dataset.id = s.id;
    const when = s.created ? s.created.slice(0, 16).replace('T', ' ') : '日時不明';
    const tags = [];
    if (s.hasRoom) tags.push('<span class="tag room">RoomPlan</span>');
    if (s.hasMoves) tags.push('<span class="tag moved">配置あり</span>');
    if (s.unfilled > 0.15) tags.push(`<span class="tag warn">未撮影 ${Math.round(s.unfilled * 100)}%</span>`);
    if (!s.hasVertexColor) tags.push('<span class="tag warn">3D なし</span>');
    d.innerHTML = `<div class="name">${s.name}</div>`
      + `<div class="meta"><span>${when}</span>`
      + `<span>${s.frames ?? '—'} 枚</span>`
      + `<span>${s.triangles ? (s.triangles / 1000).toFixed(0) + 'k 面' : '—'}</span></div>`
      + (tags.length ? `<div class="tags">${tags.join('')}</div>` : '');
    d.addEventListener('click', () => select(s.id));
    box.appendChild(d);
  }
}

// --- 選択 -------------------------------------------------------------------

async function select(id) {
  current = id;
  sel = null; dirty = false;
  document.querySelectorAll('.scan').forEach(n =>
    n.classList.toggle('sel', n.dataset.id === id));
  document.getElementById('placeholder').hidden = true;
  document.getElementById('content').hidden = false;
  document.getElementById('title').textContent = id.replace('.mdr', '');
  setStatus('');
  // 読み込み中の表示は出さない。キャッシュ済みなら一瞬で、
  // 出しても点滅するだけだった。失敗したときだけ `gl-note` を使う。
  document.getElementById('gl-note').hidden = true;

  const s = await api(`/api/scans/${id}`);
  document.getElementById('subtitle').textContent =
    [s.device, s.video ? `${s.video.width}×${s.video.height}` : null,
     s.duration ? `${s.duration.toFixed(0)} 秒` : null,
     s.frames ? `${s.frames} 枚` : null].filter(Boolean).join(' / ');
  facts(s);

  plan = await api(`/api/scans/${id}/plan`);
  if (plan.error) { setStatus(plan.error, true); return; }
  document.getElementById('plan-source').textContent =
    plan.source === 'roomplan' ? 'RoomPlan' : 'メッシュ由来';
  state = new Map((plan.objects || []).map(o => [o.id, { dx: 0, dz: 0, dyaw: 0 }]));
  const saved = await api(`/api/scans/${id}/moves`);
  for (const m of (saved.moved || [])) {
    if (!state.has(m.id)) continue;
    // 保存されているのは world 座標。図面の枠へ戻す（rot をそのまま掛ける）。
    const R = plan.rot, d = m.delta || {};
    state.set(m.id, { dx: R[0][0] * (d.dx || 0) + R[0][1] * (d.dz || 0),
                      dz: R[1][0] * (d.dx || 0) + R[1][1] * (d.dz || 0),
                      dyaw: d.dyaw || 0 });
  }
  drawPlan();
  place();
  loadGeom(id);
}

function facts(s) {
  const dl = document.getElementById('facts');
  const rows = [
    ['三角形', s.triangles ? s.triangles.toLocaleString() : '—'],
    ['焼き込み', s.bakeSec ? s.bakeSec.toFixed(2) + ' 秒' : '—'],
    ['解像度', s.mmPerTexel ? s.mmPerTexel.toFixed(2) + ' mm/texel' : '—'],
    ['アトラス', s.atlas || '—'],
    ['未撮影', s.unfilled != null ? (s.unfilled * 100).toFixed(1) + '%' : '—'],
    ['RoomPlan', s.hasRoom ? (s.roomplanSec ? s.roomplanSec.toFixed(1) + ' 秒' : 'あり') : 'なし'],
    ['面分類', s.hasClass ? 'あり' : 'なし'],
  ];
  dl.innerHTML = rows.map(([k, v]) => `<dt>${k}</dt><dd>${v}</dd>`).join('');
  const b = document.getElementById('badges');
  b.innerHTML = '';
}

// --- 平面図の描画 -----------------------------------------------------------

let objNodes = new Map();

function toScreen(p) { return [p[1], plan.extent[0] - p[0]]; }   // 長辺を横に

function drawPlan() {
  svg.innerHTML = '';
  const [LX, LZ] = plan.extent, M = 0.7;
  svg.setAttribute('viewBox', `${-M} ${-M} ${LZ + 2 * M} ${LX + 2 * M}`);
  svg.setAttribute('preserveAspectRatio', 'xMidYMid meet');

  const poly = (pts, cls, parent) => el('polygon',
    { points: pts.map(q => toScreen(q).join(',')).join(' '), class: cls }, parent);
  const line = (a, b, cls, parent) => {
    const [x1, y1] = toScreen(a), [x2, y2] = toScreen(b);
    return el('line', { x1, y1, x2, y2, class: cls }, parent);
  };

  const T = 0.12;                           // 壁厚は作図上の仮定
  for (const w of plan.walls) {
    const dx = w.b[0] - w.a[0], dz = w.b[1] - w.a[1];
    const L = Math.hypot(dx, dz) || 1;
    const u = [dx / L, dz / L], n = [-u[1], u[0]];
    const at = t => [w.a[0] + u[0] * t, w.a[1] + u[1] * t];
    const off = (p, s) => [p[0] + n[0] * s, p[1] + n[1] * s];
    const spans = (w.openings || [])
      .map(o => [Math.max(0, Math.min(L, o.s)), Math.max(0, Math.min(L, o.e)), o.cat])
      .sort((p, q) => p[0] - q[0]);
    let cur = 0;
    for (const [s, e, cat] of spans.concat([[L, L, null]])) {
      if (s > cur) {
        // 壁は平行 2 本線（別表2 の材料構造表示記号は材料が分からないので使わない）
        const p = at(cur), q = at(s);
        line(off(p, T / 2), off(q, T / 2), 'wall');
        line(off(p, -T / 2), off(q, -T / 2), 'wall');
        if (cur === 0) line(off(p, T / 2), off(p, -T / 2), 'wall');
        if (s >= L) line(off(q, T / 2), off(q, -T / 2), 'wall');
      }
      if (cat === null) break;
      const p = at(s), q = at(e);
      if (cat === 'window') {
        // 別表1「窓一般」。壁厚の中を平行線で通す。
        for (const k of [0.5, -0.5]) line(off(p, T * k), off(q, T * k), 'wall');
        for (const k of [0.15, -0.15]) line(off(p, T * k), off(q, T * k), 'win');
      } else {
        // 別表1「出入口一般」。**建具の種別が出ないので開き勝手は描かない。**
        // RoomPlan は扉の寸法しか返さず、吊元も開く向きも引違いの別も持たない。
        line(off(p, T / 2), off(p, -T / 2), 'jamb');
        line(off(q, T / 2), off(q, -T / 2), 'jamb');
        const mid = at((s + e) / 2);
        line(off(mid, T / 2), off(mid, -T / 2), 'door-bar');
      }
      cur = e;
    }
  }

  const ghosts = el('g', {});
  const objs = el('g', {});
  objNodes = new Map();
  for (const o of (plan.objects || [])) {
    const [gx, gy] = toScreen(o.c);
    el('rect', { class: 'ghost', x: -o.w / 2, y: -o.d / 2, width: o.w, height: o.d,
                 transform: `translate(${gx} ${gy}) rotate(${o.yaw - 90})` }, ghosts);
    const g = el('g', { class: 'obj', 'data-id': o.id }, objs);
    el('rect', { x: -o.w / 2, y: -o.d / 2, width: o.w, height: o.d }, g);
    el('text', { x: 0, y: 0 }, g).textContent = o.label;
    objNodes.set(o.id, g);
  }
  const y = LX + M * 0.45;
  el('path', { class: 'scalebar',
    d: `M 0 ${y} H 1 M 0 ${y - .06} V ${y + .06} M 1 ${y - .06} V ${y + .06}` });
  el('text', { x: 1.12, y: y + .06, class: 'scaletext' }).textContent = '1 m';
  svg.querySelectorAll('.obj').forEach(g => {
    g.addEventListener('pointerdown', onDown);
    g.addEventListener('pointermove', onMove);
    g.addEventListener('pointerup', onUp);
    g.addEventListener('pointercancel', onUp);
  });
}

// --- 3D ---------------------------------------------------------------------

let renderer, scene, camera, hemi, dirLight, meshes = new Map(), pickable = [];
let materials = [];          // 裏面の扱いを一括で切り替えるため
let cullBack = true;
let boxes = new Map();       // RoomPlan の境界箱（線分）
const cssColor = name =>
  getComputedStyle(document.documentElement).getPropertyValue(name).trim();
let cam = { r: 15, theta: -0.9, phi: 1.02 }, target = new THREE.Vector3();
let needs = true;

function initGL() {
  if (renderer) return;
  if (typeof THREE === 'undefined') {
    document.getElementById('gl-note').textContent = 'three.js を読み込めません（オフライン）';
    return;
  }
  renderer = new THREE.WebGLRenderer({ canvas, antialias: true });
  renderer.setPixelRatio(Math.min(devicePixelRatio, 2));
  scene = new THREE.Scene();
  camera = new THREE.PerspectiveCamera(50, 1, 0.05, 300);
  hemi = new THREE.HemisphereLight(0xffffff, 0x8a8a94, 1.0);
  dirLight = new THREE.DirectionalLight(0xffffff, 0.45);
  dirLight.position.set(3, 8, 2);
  scene.add(hemi, dirLight);
  new ResizeObserver(() => { resizeGL(); draw(); }).observe(canvas.parentElement);
  // **3D からは動かさない。** 視点の操作と選択だけ。配置を変えるのは
  // 平面図の側だけにして、3D はその結果を映す。掴めるようにすると、
  // 掴んだ点と床面の交点で決まるぶん視点によって量が変わり、平面図で
  // 見ている数値と食い違う。鉛直方向の移動も持たない（家具は床に
  // 置いたままとする）。
  canvas.addEventListener('pointerdown', e => {
    canvas.setPointerCapture(e.pointerId);
    orbit = { x: e.clientX, y: e.clientY, t: cam.theta, p: cam.phi, moved: false };
  });
  canvas.addEventListener('pointermove', e => {
    if (!orbit) return;
    const dx = e.clientX - orbit.x, dy = e.clientY - orbit.y;
    if (Math.abs(dx) + Math.abs(dy) > 3) orbit.moved = true;
    cam.theta = orbit.t + dx * 0.006;
    cam.phi = orbit.p + dy * 0.006;
    draw();
  });
  canvas.addEventListener('pointerup', e => {
    if (orbit && !orbit.moved) { sel = objectAt(e); place(); }
    orbit = null;
  });
  canvas.addEventListener('pointercancel', () => { orbit = null; });
  canvas.addEventListener('wheel', e => {
    e.preventDefault(); cam.r *= Math.exp(e.deltaY * 0.0012); draw();
  }, { passive: false });
  loop();
}
let orbit = null;

function dec(b64, Type) {
  const s = atob(b64), n = s.length, u = new Uint8Array(n);
  for (let i = 0; i < n; i++) u[i] = s.charCodeAt(i);
  return new Type(u.buffer);
}

async function loadGeom(id) {
  initGL();
  if (!renderer) return;
  for (const [, m] of meshes) scene.remove(m.mesh);
  for (const [, b] of boxes) scene.remove(b);
  meshes = new Map(); pickable = []; materials = []; boxes = new Map();
  scene.children.filter(o => o.isMesh).forEach(o => scene.remove(o));
  const g = await api(`/api/scans/${id}/geom`);
  if (id !== current) return;                 // 別のスキャンへ移った
  if (g.error) {
    document.getElementById('gl-note').textContent = g.error;
    return;
  }
  for (const part of g.parts) {
    const geo = new THREE.BufferGeometry();
    geo.setAttribute('position', new THREE.BufferAttribute(dec(part.pos, Float32Array), 3));
    geo.setAttribute('color', new THREE.BufferAttribute(dec(part.col, Uint8Array), 3, true));
    geo.setIndex(new THREE.BufferAttribute(dec(part.idx, Uint32Array), 1));
    if (part.kind === 'object') geo.translate(-part.c[0], 0, -part.c[2]);
    geo.computeVertexNormals();
    // **裏面を描かない。** ARKit のメッシュは法線が室内側を向くので、
    // 外から見ると手前の壁が消えて中が見える。両面で描くと箱の外側しか
    // 見えず、間取りの確認に使えない。
    const mesh = new THREE.Mesh(geo, new THREE.MeshLambertMaterial({
      vertexColors: true, side: cullBack ? THREE.FrontSide : THREE.DoubleSide }));
    materials.push(mesh.material);
    if (part.kind === 'object') {
      mesh.position.set(part.c[0], 0, part.c[2]);
      mesh.userData.id = part.id;
      meshes.set(part.id, { mesh, c: part.c });
      pickable.push(mesh);
      if (part.box) addBox(part);
    }
    scene.add(mesh);
  }
  target.set(g.extent[0] / 2, 1.2, g.extent[1] / 2);
  cam.r = Math.max(6, Math.hypot(g.extent[0], g.extent[1]) * 0.9);
  document.getElementById('gl-note').hidden = true;
  resizeGL(); place(); draw();
}

function resizeGL() {
  if (!renderer) return;
  const r = canvas.parentElement.getBoundingClientRect();
  renderer.setSize(r.width, r.height, false);
  camera.aspect = r.width / Math.max(r.height, 1);
  camera.updateProjectionMatrix();
}
const draw = () => { needs = true; };
function loop() {
  if (needs && renderer) {
    needs = false;
    cam.phi = Math.max(0.12, Math.min(Math.PI / 2 - 0.02, cam.phi));
    cam.r = Math.max(1.5, Math.min(90, cam.r));
    camera.position.set(
      target.x + cam.r * Math.sin(cam.phi) * Math.cos(cam.theta),
      target.y + cam.r * Math.cos(cam.phi),
      target.z + cam.r * Math.sin(cam.phi) * Math.sin(cam.theta));
    camera.lookAt(target);
    renderer.render(scene, camera);
  }
  requestAnimationFrame(loop);
}
/* RoomPlan の境界箱を線で描く。
   隅は中心からの相対座標でサーバから来る（向きの計算は Python 側で済んで
   いるので、ここで回転の符号を推し量らなくてよい）。動かすときは中心を
   移して dyaw だけ回す。 */
function addBox(part) {
  const b = part.box, pts = b.pts, y0 = b.y0, y1 = b.y0 + b.h, v = [];
  for (let i = 0; i < 4; i++) {
    const p = pts[i], q = pts[(i + 1) % 4];
    v.push(p[0], y0, p[1], q[0], y0, q[1]);     // 下の輪
    v.push(p[0], y1, p[1], q[0], y1, q[1]);     // 上の輪
    v.push(p[0], y0, p[1], p[0], y1, p[1]);     // 縦
  }
  const g = new THREE.BufferGeometry();
  g.setAttribute('position', new THREE.Float32BufferAttribute(v, 3));
  const line = new THREE.LineSegments(g,
    new THREE.LineBasicMaterial({ color: new THREE.Color(cssColor('--rule')),
                                  transparent: true, opacity: 0.55 }));
  line.position.set(part.c[0], 0, part.c[2]);
  boxes.set(part.id, line);
  scene.add(line);
}

const ray = typeof THREE !== 'undefined' ? new THREE.Raycaster() : null;

/** 画面の点の下にある家具の id。無ければ null。 */
function objectAt(e) {
  if (!ray) return null;
  const r = canvas.getBoundingClientRect();
  ray.setFromCamera(new THREE.Vector2(
    ((e.clientX - r.left) / r.width) * 2 - 1,
    -((e.clientY - r.top) / r.height) * 2 + 1), camera);
  const hit = ray.intersectObjects(pickable, false)[0];
  return hit ? hit.object.userData.id : null;
}
// --- 同期 -------------------------------------------------------------------

function place() {
  if (!plan) return;
  for (const o of (plan.objects || [])) {
    const m = state.get(o.id);
    const [sx, sy] = toScreen([o.c[0] + m.dx, o.c[1] + m.dz]);
    const g = objNodes.get(o.id);
    if (g) {
      g.setAttribute('transform', `translate(${sx} ${sy}) rotate(${o.yaw - 90 - m.dyaw})`);
      g.classList.toggle('moved', !!(m.dx || m.dz || m.dyaw));
      g.classList.toggle('sel', sel === o.id);
    }
    const m3 = meshes.get(o.id);
    if (m3) {
      m3.mesh.position.set(m3.c[0] + m.dx, 0, m3.c[2] + m.dz);
      m3.mesh.rotation.y = m.dyaw * Math.PI / 180;
    }
    const bx = boxes.get(o.id);
    if (bx && m3) {
      bx.position.set(m3.c[0] + m.dx, 0, m3.c[2] + m.dz);
      bx.rotation.y = m.dyaw * Math.PI / 180;
      const on = sel === o.id;
      bx.material.color.set(cssColor(on ? '--pick' : '--rule'));
      bx.material.opacity = on ? 1 : 0.4;
    }
  }
  draw();
  table();
}

function table() {
  const tb = document.querySelector('#objects tbody');
  tb.innerHTML = '';
  for (const o of (plan.objects || [])) {
    const m = state.get(o.id);
    const tr = document.createElement('tr');
    if (sel === o.id) tr.className = 'sel';
    if (o.confidence === 'low') tr.classList.add('low');
    const f = v => v ? (v > 0 ? '+' : '') + (v * 1000).toFixed(0) : '—';
    tr.innerHTML = `<td class="name">${o.label}</td>`
      + `<td>${(o.w * 1000).toFixed(0)}×${(o.d * 1000).toFixed(0)}</td>`
      + `<td>${f(m.dx)}</td><td>${f(m.dz)}</td>`
      + `<td>${m.dyaw ? (m.dyaw > 0 ? '+' : '') + m.dyaw.toFixed(0) + '°' : '—'}</td>`;
    tr.addEventListener('click', () => { sel = o.id; place(); });
    tb.appendChild(tr);
  }
  for (const b of ['rotL', 'rotR', 'rot90', 'resetOne'])
    document.getElementById(b).disabled = !sel;
  document.getElementById('save').disabled = !dirty;
}

// --- 操作 -------------------------------------------------------------------

function toUser(evt) {
  const pt = svg.createSVGPoint();
  pt.x = evt.clientX; pt.y = evt.clientY;
  const p = pt.matrixTransform(svg.getScreenCTM().inverse());
  return [p.x, p.y];
}
let drag = null;
function onDown(e) {
  const g = e.currentTarget;
  sel = g.dataset.id;
  const m = state.get(sel);
  drag = { start: toUser(e), base: { dx: m.dx, dz: m.dz } };
  g.setPointerCapture(e.pointerId);
  place();
}
function onMove(e) {
  if (!drag || !sel) return;
  const [ux, uy] = toUser(e);
  // 画面 (sx, sy) = (z, LX - x) なので、逆に dz = dsx、dx = -dsy。
  let dz = drag.base.dz + (ux - drag.start[0]);
  let dx = drag.base.dx - (uy - drag.start[1]);
  if (document.getElementById('snap').checked) {
    dx = Math.round(dx / 0.05) * 0.05; dz = Math.round(dz / 0.05) * 0.05;
  }
  const m = state.get(sel);
  m.dx = dx; m.dz = dz;
  dirty = true;
  place();
}
function onUp() { drag = null; }

window.addEventListener('keydown', e => {
  if (!sel || !plan) return;
  const m = state.get(sel), step = e.shiftKey ? 0.01 : 0.05;
  const map = { ArrowUp: [step, 0], ArrowDown: [-step, 0],
                ArrowLeft: [0, -step], ArrowRight: [0, step] };
  if (map[e.key]) { m.dx += map[e.key][0]; m.dz += map[e.key][1]; dirty = true; place(); e.preventDefault(); }
  else if (e.key === '[') { m.dyaw += 5; dirty = true; place(); }
  else if (e.key === ']') { m.dyaw -= 5; dirty = true; place(); }
  else if (e.key === 'Escape') { sel = null; place(); }
});
const bump = d => { if (sel) { state.get(sel).dyaw += d; dirty = true; place(); } };
document.getElementById('rotL').onclick = () => bump(15);
document.getElementById('rotR').onclick = () => bump(-15);
document.getElementById('rot90').onclick = () => bump(90);
document.getElementById('resetOne').onclick = () => {
  if (sel) { state.set(sel, { dx: 0, dz: 0, dyaw: 0 }); dirty = true; place(); }
};
document.getElementById('resetAll').onclick = () => {
  for (const o of (plan.objects || [])) state.set(o.id, { dx: 0, dz: 0, dyaw: 0 });
  dirty = true; place();
};
document.getElementById('cull').onchange = e => {
  cullBack = e.target.checked;
  for (const m of materials) {
    m.side = cullBack ? THREE.FrontSide : THREE.DoubleSide;
    m.needsUpdate = true;
  }
  draw();
};
document.getElementById('vTop').onclick = () => { cam.phi = .14; cam.theta = -Math.PI / 2; draw(); };
document.getElementById('vIso').onclick = () => { cam.phi = 1.02; cam.theta = -.9; draw(); };
document.getElementById('reload').onclick = loadList;

document.getElementById('save').onclick = async () => {
  const R = plan.rot, moved = [];
  for (const o of (plan.objects || [])) {
    const m = state.get(o.id);
    if (!m.dx && !m.dz && !m.dyaw) continue;
    // 図面の枠から world へ。局所 = R·world なので world = Rᵀ·局所。
    moved.push({ id: o.id, delta: {
      dx: +(R[0][0] * m.dx + R[1][0] * m.dz).toFixed(4),
      dz: +(R[0][1] * m.dx + R[1][1] * m.dz).toFixed(4),
      dyaw: +m.dyaw.toFixed(1) } });
  }
  setStatus('切り分けて動かしています…');
  const res = await api(`/api/scans/${current}/arrange`,
    { method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ moved }) });
  if (res.ok) {
    dirty = false;
    setStatus(`arranged.ply を書きました（${res.moved ?? 0} 個 / ${(res.faces || 0).toLocaleString()} 面）`);
    loadList();
  } else {
    setStatus(res.error || '失敗しました', true);
  }
  table();
};

function setStatus(text, err) {
  const s = document.getElementById('status');
  s.textContent = text;
  s.className = 'status' + (err ? ' err' : '');
}

fetch('/api/scans').then(() => loadList());
