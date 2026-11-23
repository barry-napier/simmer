const $ = (selector, root = document) => root.querySelector(selector);

// Theme switch, remembered per browser.
$('#theme').addEventListener('click', () => {
  const dark = (document.documentElement.dataset.theme || (matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light')) === 'dark';
  const next = dark ? 'light' : 'dark';
  document.documentElement.dataset.theme = next;
  try { localStorage.setItem('theme', next) } catch {}
});

// The demo: four made-up apps, each with its own sound, made in the browser.
const apps = [
  { id: 'music', name: 'Music', glyph: '♪', color: '#fa3e5f', volume: 0.55, make: music },
  { id: 'call', name: 'Team Call', glyph: '☎', color: '#2f8cf5', volume: 1, make: call },
  { id: 'video', name: 'Browser Tab', glyph: '▶', color: '#8a5cf6', volume: 0.3, make: video },
  { id: 'chat', name: 'Chat', glyph: '✉', color: '#2fb569', volume: 0, muted: true, make: chat },
];

const list = $('#mixer');
const playButton = $('#play');
let ctx = null;
let playing = false;

for (const app of apps) {
  const li = document.createElement('li');
  li.innerHTML = `
    <span class="app-icon" style="background:${app.color}" aria-hidden="true">${app.glyph}</span>
    <span>
      <span class="app-top"><span class="app-name">${app.name}</span><output></output></span>
      <span class="meter" aria-hidden="true"><i></i></span>
      <input type="range" min="0" max="100" aria-label="${app.name} volume">
    </span>
    <button class="mute" type="button" aria-label="Mute ${app.name}"></button>`;
  app.el = li;
  app.slider = $('input', li);
  app.out = $('output', li);
  app.muteButton = $('.mute', li);
  app.meter = $('.meter i', li);
  app.default = { volume: app.volume, muted: !!app.muted };
  app.slider.addEventListener('input', () => {
    app.volume = app.slider.value / 100;
    if (app.volume > 0) app.muted = false;
    render(app);
  });
  app.muteButton.addEventListener('click', () => {
    app.muted = !app.muted;
    if (!app.muted && app.volume === 0) app.volume = 1;
    render(app);
  });
  list.append(li);
  render(app);
}

$('#reset').addEventListener('click', () => {
  for (const app of apps) { app.volume = 1; app.muted = false; render(app) }
});

// Same loudness curve as the app: half way on the slider is a quarter of the signal.
function level(app) { return app.muted ? 0 : app.volume * app.volume }

function render(app) {
  app.slider.value = Math.round(app.volume * 100);
  app.slider.disabled = !!app.muted;
  app.out.textContent = app.muted ? 'Muted' : `${Math.round(app.volume * 100)}%`;
  app.muteButton.textContent = app.muted ? '🔇' : '🔊';
  app.muteButton.setAttribute('aria-pressed', String(!!app.muted));
  app.el.classList.toggle('muted', !!app.muted);
  if (app.gain) app.gain.gain.setTargetAtTime(level(app), ctx.currentTime, 0.03);
}

playButton.addEventListener('click', async () => {
  if (!ctx) {
    ctx = new AudioContext();
    for (const app of apps) {
      app.gain = ctx.createGain();
      app.gain.gain.value = level(app);
      app.analyser = ctx.createAnalyser();
      app.analyser.fftSize = 512;
      app.gain.connect(app.analyser).connect(ctx.destination);
      app.make(ctx, app.gain);
    }
    meters();
  }
  playing = !playing;
  if (playing) await ctx.resume(); else await ctx.suspend();
  playButton.setAttribute('aria-pressed', String(playing));
  $('.icon', playButton).textContent = playing ? '❚❚' : '▶';
  $('.label', playButton).textContent = playing ? 'Pause the sounds' : 'Play the sounds';
});

function meters() {
  const data = new Float32Array(512);
  const tick = () => {
    for (const app of apps) {
      app.analyser.getFloatTimeDomainData(data);
      let peak = 0;
      for (const v of data) peak = Math.max(peak, Math.abs(v));
      app.meter.style.width = `${Math.min(100, peak * 260)}%`;
    }
    requestAnimationFrame(tick);
  };
  tick();
}

// ---- The sounds. Small, soft, and all made from scratch. ----

function note(ctx, out, freq, start, length, type = 'triangle', peak = 0.18) {
  const osc = ctx.createOscillator();
  const env = ctx.createGain();
  osc.type = type;
  osc.frequency.value = freq;
  env.gain.setValueAtTime(0, start);
  env.gain.linearRampToValueAtTime(peak, start + 0.02);
  env.gain.exponentialRampToValueAtTime(0.001, start + length);
  osc.connect(env).connect(out);
  osc.start(start);
  osc.stop(start + length + 0.05);
}

// Music: a gentle four-chord arpeggio.
function music(ctx, out) {
  const chords = [[261.6, 329.6, 392, 493.9], [220, 261.6, 329.6, 392], [174.6, 220, 261.6, 329.6], [196, 246.9, 293.7, 392]];
  let step = 0;
  let next = ctx.currentTime + 0.05;
  setInterval(() => {
    while (next < ctx.currentTime + 0.4) {
      const chord = chords[Math.floor(step / 8) % chords.length];
      note(ctx, out, chord[step % 4] * (step % 8 < 4 ? 1 : 2), next, 0.5);
      if (step % 8 === 0) note(ctx, out, chord[0] / 2, next, 1.6, 'sine', 0.22);
      step++;
      next += 0.22;
    }
  }, 100);
}

// A call: soft, wordless "talking" made from filtered noise in bursts.
function call(ctx, out) {
  const buffer = ctx.createBuffer(1, ctx.sampleRate * 2, ctx.sampleRate);
  const samples = buffer.getChannelData(0);
  for (let i = 0; i < samples.length; i++) samples[i] = Math.random() * 2 - 1;
  const noise = ctx.createBufferSource();
  noise.buffer = buffer;
  noise.loop = true;
  const voice = ctx.createBiquadFilter();
  voice.type = 'bandpass';
  voice.frequency.value = 700;
  voice.Q.value = 3;
  const env = ctx.createGain();
  env.gain.value = 0;
  noise.connect(voice).connect(env).connect(out);
  noise.start();
  let next = ctx.currentTime + 0.1;
  setInterval(() => {
    while (next < ctx.currentTime + 0.4) {
      const talking = Math.sin(next / 2.3) > -0.3;
      const amount = talking ? 0.25 + Math.random() * 0.35 : 0;
      env.gain.setTargetAtTime(amount, next, 0.03);
      voice.frequency.setTargetAtTime(500 + Math.random() * 600, next, 0.05);
      next += 0.09 + Math.random() * 0.08;
    }
  }, 100);
}

// A browser tab: a low, buzzy ad jingle drone.
function video(ctx, out) {
  const osc = ctx.createOscillator();
  osc.type = 'sawtooth';
  osc.frequency.value = 110;
  const tone = ctx.createBiquadFilter();
  tone.type = 'lowpass';
  tone.frequency.value = 600;
  const wobble = ctx.createOscillator();
  wobble.frequency.value = 3;
  const depth = ctx.createGain();
  depth.gain.value = 0.05;
  const body = ctx.createGain();
  body.gain.value = 0.1;
  wobble.connect(depth).connect(body.gain);
  osc.connect(tone).connect(body).connect(out);
  osc.start();
  wobble.start();
}

// Chat: a ping every few seconds.
function chat(ctx, out) {
  let next = ctx.currentTime + 1;
  setInterval(() => {
    while (next < ctx.currentTime + 0.4) {
      note(ctx, out, 1046.5, next, 0.25, 'sine', 0.3);
      note(ctx, out, 1568, next + 0.12, 0.35, 'sine', 0.3);
      next += 2.8;
    }
  }, 100);
}
