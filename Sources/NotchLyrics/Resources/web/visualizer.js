import * as THREE from './three.module.min.js';

// The live meter, and nothing else.
//
// This file used to host four scenes: a ring, an EQ surface, a deforming orb,
// and this. Three of them were decoration — a tilted EQ plot is harder to read
// than a flat one, and an orbiting ball next to a slider says nothing about the
// audio. Only the waterfall earns 3D: depth is time, so a glance shows the last
// couple of seconds of the waveform receding, which no flat meter conveys.
//
// Mirrors LevelStore.capacity on the Swift side. Swift pushes the whole
// snapshot (oldest → newest) rather than a single peak so the scene can never
// drift out of sync with the audio thread's own history.
const LEVELS = 120;

const COLS = 64;
const ROWS = 14;
/// Frames between rows. Row r shows the waveform as it was r*STRIDE samples
/// ago, so the whole waterfall comes from one history buffer with no extra
/// state to keep in sync.
const STRIDE = 4;

const history = new Float32Array(LEVELS);
const state = {
  active: false,
  accent: new THREE.Color(0x1ed760),
  highlight: new THREE.Color(0xb8ffd4),
  /// Smoothed copy of `history` — raw peaks are jittery at 30 Hz and the scene
  /// renders at display rate, so every bar eases toward its target.
  smooth: new Float32Array(LEVELS),
  energy: 0,
  /// System "reduce motion" preference. Kills ambient drift; audio-driven
  /// movement stays, because that movement is the information.
  reduced: false,
};

const mat4 = new THREE.Matrix4();
const color = new THREE.Color();
const IDLE_GREY = new THREE.Color(0x8a8a8a);

let renderer, scene, camera, rig, clock, canvasEl;

// ---------------------------------------------------------------------------
// Boot
// ---------------------------------------------------------------------------

export async function boot() {
  const query = new URLSearchParams(location.search);
  const accent = query.get('accent');
  if (accent) state.accent.set(`#${accent.replace(/^#/, '')}`);
  // The host passes the surface colour it wants behind the scene; painting it
  // here avoids relying on WKWebView's private transparency switch.
  const bg = query.get('bg');
  if (bg) document.body.style.background = `#${bg.replace(/^#/, '')}`;
  state.reduced = query.get('reduced') === '1'
    || window.matchMedia('(prefers-reduced-motion: reduce)').matches;

  const canvas = document.createElement('canvas');
  document.body.appendChild(canvas);

  renderer = new THREE.WebGLRenderer({
    canvas,
    alpha: true,
    antialias: true,
    powerPreference: 'low-power',
  });
  renderer.setClearAlpha(0);
  // Cap DPR: this view is small and a 3x buffer buys nothing visible while
  // costing real GPU time in an app that stays open all day.
  renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2));

  scene = new THREE.Scene();
  camera = new THREE.PerspectiveCamera(45, 1, 0.1, 100);
  clock = new THREE.Clock();

  rig = build();
  scene.add(rig.root);

  // Observe the canvas, not the window. Inside a resizable pane the element's
  // box changes without a window resize event (pane reflow, full screen,
  // sidebar changes), and sizing off `innerWidth` then leaves the drawing
  // buffer and the element disagreeing — the scene renders into a corner.
  canvasEl = canvas;
  new ResizeObserver(resize).observe(canvas);
  resize();

  installBridge();
  notify({ kind: 'ready' });

  renderer.setAnimationLoop(tick);
}

function resize() {
  if (!canvasEl) return;
  const w = Math.max(1, canvasEl.clientWidth || window.innerWidth);
  const h = Math.max(1, canvasEl.clientHeight || window.innerHeight);
  renderer.setSize(w, h, false);
  camera.aspect = w / h;
  rig?.layout?.(w / h);
  camera.updateProjectionMatrix();
}

function tick() {
  const dt = Math.min(clock.getDelta(), 1 / 20);
  const t = clock.elapsedTime;
  if (!state.active) synthesizeIdle(t);
  ease(dt);
  frame(rig, t);
  renderer.render(scene, camera);
}

// ---------------------------------------------------------------------------
// Level plumbing
// ---------------------------------------------------------------------------

/** Gentle drifting swell so the meter is alive before the engine is on. */
function synthesizeIdle(t) {
  // Reduced motion: hold a still, shallow shape instead of an endless loop.
  const time = state.reduced ? 0 : t;
  for (let i = 0; i < LEVELS; i++) {
    const p = i / LEVELS;
    history[i] = Math.max(0,
      0.055
      + 0.030 * Math.sin(time * 0.85 + p * 7.5)
      + 0.020 * Math.sin(time * 1.63 - p * 12.0)
      + 0.014 * Math.sin(time * 0.41 + p * 21.0));
  }
}

function ease(dt) {
  // Fast attack, slow release — the shape audio meters have always had.
  const attack = 1 - Math.exp(-dt * 26);
  const release = 1 - Math.exp(-dt * 7);
  let sum = 0;
  for (let i = 0; i < LEVELS; i++) {
    const target = history[i];
    const cur = state.smooth[i];
    state.smooth[i] = cur + (target - cur) * (target > cur ? attack : release);
    sum += state.smooth[i];
  }
  state.energy = sum / LEVELS;
}

/** Reads the smoothed history as a curve of `n` points, `offset` samples back. */
function sample(out, n, offset) {
  const start = Math.max(0, LEVELS - n - offset);
  const end = Math.max(start + 1, LEVELS - offset);
  const width = end - start;
  for (let i = 0; i < n; i++) {
    const f = n === 1 ? 0 : (i / (n - 1)) * (width - 1);
    const i0 = start + Math.floor(f);
    const i1 = Math.min(end - 1, i0 + 1);
    const frac = f - Math.floor(f);
    out[i] = state.smooth[i0] * (1 - frac) + state.smooth[i1] * frac;
  }
  return out;
}

// ---------------------------------------------------------------------------
// Scene
// ---------------------------------------------------------------------------

function build() {
  const root = new THREE.Group();
  const count = COLS * ROWS;
  const geo = new THREE.BoxGeometry(1, 1, 1);

  const bars = new THREE.InstancedMesh(
    geo,
    new THREE.MeshBasicMaterial({ transparent: true, opacity: 0.95, depthWrite: false }),
    count
  );
  const halo = new THREE.InstancedMesh(
    geo,
    new THREE.MeshBasicMaterial({
      transparent: true,
      opacity: 0.075,
      blending: THREE.AdditiveBlending,
      depthWrite: false,
    }),
    count
  );
  bars.frustumCulled = false;
  halo.frustumCulled = false;

  // Centre line: the zero crossing, so the panel still reads as a meter.
  const baseline = new THREE.Line(
    new THREE.BufferGeometry().setFromPoints([
      new THREE.Vector3(-1.02, 0.001, 0.42),
      new THREE.Vector3(1.02, 0.001, 0.42),
    ]),
    new THREE.LineBasicMaterial({ transparent: true, opacity: 0.16 })
  );
  baseline.frustumCulled = false;

  root.add(bars, halo, baseline);

  return {
    root, bars, halo, baseline,
    buf: new Float32Array(COLS),
    baseY: 0.78,
    baseDist: 2.2,
    xScale: 1,
    layout(aspect) {
      // Wide-and-short strip: lift the eye as the view gets wider so the
      // waterfall stays readable instead of collapsing to a flat line.
      this.baseY = aspect > 7 ? 0.62 : aspect > 4 ? 0.78 : 1.05;
      const vTan = Math.tan((camera.fov * Math.PI) / 180 / 2);
      this.baseDist = Math.max(2.2, 1.12 / vTan);
      // Stretch to span the frame rather than sitting in the middle of it:
      // fitting the camera to both axes marooned it in a wide strip.
      this.xScale = Math.min(6, Math.max(0.6, (vTan * this.baseDist * aspect) / 1.14));
    },
  };
}

function frame(r, t) {
  const dx = 2.0 / COLS;
  const dz = 1.85 / ROWS;
  const boost = state.active ? 2.3 : 1.5;

  for (let row = 0; row < ROWS; row++) {
    const values = sample(r.buf, COLS, row * STRIDE);
    const depth = row / (ROWS - 1 || 1);
    const fade = Math.pow(1 - depth, 1.5) * 0.92 + 0.08;
    const z = 0.42 - row * dz;

    for (let c = 0; c < COLS; c++) {
      const i = row * COLS + c;
      const x = (c - (COLS - 1) / 2) * dx;
      const h = Math.max(0.006, values[c] * boost);
      const t01 = Math.min(1, h / 1.1);

      mat4.makeScale(dx * 0.52, h, dz * 0.44);
      mat4.setPosition(x, h / 2, z);
      r.bars.setMatrixAt(i, mat4);

      mat4.makeScale(dx * 1.9, h * 1.05, dz * 0.9);
      mat4.setPosition(x, h / 2, z);
      r.halo.setMatrixAt(i, mat4);

      color.copy(state.accent).lerp(state.highlight, t01 * t01);
      if (!state.active) color.lerp(IDLE_GREY, 0.72);
      color.multiplyScalar(fade);
      r.bars.setColorAt(i, color);
      r.halo.setColorAt(i, color.multiplyScalar(fade));
    }
  }

  for (const m of [r.bars, r.halo]) {
    m.instanceMatrix.needsUpdate = true;
    if (m.instanceColor) m.instanceColor.needsUpdate = true;
  }

  r.baseline.material.color.copy(state.active ? state.accent : state.highlight);
  r.baseline.material.opacity = state.active ? 0.22 : 0.08;

  r.root.scale.x = r.xScale;
  // Barely-there sway keeps the perspective alive when audio is silent.
  r.root.rotation.y = state.reduced ? 0 : Math.sin(t * 0.16) * 0.035;

  camera.position.set(0, r.baseY, r.baseDist);
  camera.lookAt(0, 0.02, -0.75);
}

function notify(payload) {
  window.webkit?.messageHandlers?.notch?.postMessage(payload);
}

// ---------------------------------------------------------------------------
// Swift bridge
// ---------------------------------------------------------------------------

function installBridge() {
  window.__nl = {
    /** levels: array of 0..1 peaks, oldest → newest. */
    push(levels) {
      if (!levels || !levels.length) return;
      const n = levels.length;
      if (n === LEVELS) {
        for (let i = 0; i < LEVELS; i++) history[i] = levels[i];
      } else {
        for (let i = 0; i < LEVELS; i++) {
          history[i] = levels[Math.min(n - 1, Math.floor((i / LEVELS) * n))];
        }
      }
    },
    setActive(on) {
      state.active = !!on;
      if (!on) history.fill(0);
    },
    setAccent(hex) {
      state.accent.set(hex);
    },
    setReducedMotion(on) {
      state.reduced = !!on;
    },
    /** Diagnostics for verifying the scene from a host or a browser console. */
    stats() {
      return {
        active: state.active,
        energy: +state.energy.toFixed(4),
        peakSmooth: +Math.max(...state.smooth).toFixed(4),
        aspect: +camera.aspect.toFixed(3),
        xScale: +rig.xScale.toFixed(3),
        camera: [0, +camera.position.y.toFixed(2), +camera.position.z.toFixed(2)],
      };
    },
    setRunning(on) {
      renderer.setAnimationLoop(on ? tick : null);
      if (on) clock.getDelta();
    },
  };
}
