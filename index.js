/**
 * DingTalk-style completion chime.
 *
 * Rings a short, soft "叮咚" on the machine that runs the Host when a top-level
 * agent finishes its turn. Sub-agent turns are ignored so delegation churn does
 * not ring the bell.
 *
 * Volume: play.ps1 probes the Windows master volume and scales the chime so its
 * peak lands near `volume` percent no matter where the system slider sits.
 *
 * Muting: the client half (composer toolbar bell) talks to this half over the
 * loopback route `/api/ding-chime`, so a click mutes immediately without
 * reloading the plugin. The choice is remembered in
 * `%LOCALAPPDATA%\dsh-ding-chime\state.json`.
 *
 * Behaviour:
 * - Normally the chime plays once when the whole running interval ends
 *   (`agent/status` -> `idle`), not once per turn inside it.
 * - If this plugin starts in the middle of a running interval (fresh install,
 *   reload), the first `agent/turn-stopping` announces it instead, and the
 *   trailing `idle` stays silent.
 *
 * Config:
 *   enabled         (boolean, default true)   mount the chime at all
 *   volume          (number,  default 22)     target peak loudness, 1..100
 *   adaptiveVolume  (boolean, default true)   follow the Windows master volume
 *   subagents       (boolean, default false)  also ring for sub-agent turns
 *   preview         (boolean, default false)  ring once when the plugin activates
 */

import { spawn } from 'node:child_process'
import { appendFileSync, existsSync, mkdirSync, readFileSync, statSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const SOUND_DIR = fileURLToPath(new URL('./assets/sounds/', import.meta.url))
const SOUND_IDS = [
  'win-generic',
  'win-calendar',
  'win-email',
  'win-message',
  'win-ding',
  'win-chime',
  'win-nudge',
  'bell',
  'deep',
  'tech',
]
const DEFAULT_SOUND = 'win-calendar'
const PLAY_SCRIPT = fileURLToPath(new URL('./play.ps1', import.meta.url))
const TRAY_SCRIPT = fileURLToPath(new URL('./tray.ps1', import.meta.url))
const TRAY_ICON_ON = fileURLToPath(new URL('./assets/tray-on.png', import.meta.url))
const TRAY_ICON_OFF = fileURLToPath(new URL('./assets/tray-off.png', import.meta.url))
const TRAY_ICON_RING = fileURLToPath(new URL('./assets/tray-ring.png', import.meta.url))

/** Two completions closer than this are one event (fork / resume bursts). */
const DEBOUNCE_MS = 700

/** Never exceed this gain, so a nearly muted desktop cannot turn into a shout. */
const MAX_GAIN = 0.5

const ROUTE_PATH = '/api/ding-chime'
const STATE_DIR = join(
  process.env.LOCALAPPDATA || process.env.XDG_STATE_HOME || dirname(PLAY_SCRIPT),
  'dsh-ding-chime',
)
const STATE_FILE = join(STATE_DIR, 'state.json')
const EVENTS_FILE = join(STATE_DIR, 'events.json')
const PLAY_LOG = join(STATE_DIR, 'play.log')

function logPlay(line) {
  try {
    if (statSync(PLAY_LOG).size > 64 * 1024) writeFileSync(PLAY_LOG, '')
  } catch {
    // Missing log file is the normal first-run case.
  }
  try {
    appendFileSync(PLAY_LOG, `${new Date().toISOString()} ${line}\n`, 'utf8')
  } catch {
    // Logging is best effort.
  }
}

function wavFor(id) {
  return join(SOUND_DIR, `${id}.wav`)
}

/**
 * Pick the voice that will actually play. The `win-*` samples are generated
 * locally from the user's own Windows installation and are not distributed, so
 * a fresh checkout falls back to the first shipped voice.
 */
function resolveSound(id) {
  if (typeof id === 'string' && SOUND_IDS.includes(id) && existsSync(wavFor(id))) return id
  for (const candidate of SOUND_IDS) {
    if (existsSync(wavFor(candidate))) return candidate
  }
  return DEFAULT_SOUND
}

function soundPath(id) {
  return wavFor(resolveSound(id))
}

function readState() {
  try {
    const parsed = JSON.parse(readFileSync(STATE_FILE, 'utf8'))
    return {
      muted: parsed?.muted === true,
      sound: typeof parsed?.sound === 'string' ? parsed.sound : null,
    }
  } catch {
    return { muted: false, sound: null }
  }
}

function writeState(next) {
  try {
    mkdirSync(dirname(STATE_FILE), { recursive: true })
    writeFileSync(STATE_FILE, JSON.stringify({ muted: next.muted === true, sound: next.sound ?? null }), 'utf8')
  } catch {
    // A read-only profile still gets an in-memory mute for this run.
  }
}

function readJsonBody(req) {
  return new Promise((resolve, reject) => {
    let raw = ''
    req.setEncoding('utf8')
    req.on('data', (chunk) => {
      raw += chunk
      if (raw.length > 4096) {
        reject(new Error('body too large'))
        req.destroy()
      }
    })
    req.on('end', () => {
      try {
        resolve(raw ? JSON.parse(raw) : {})
      } catch (error) {
        reject(error)
      }
    })
    req.on('error', reject)
  })
}

function isLoopback(req) {
  const remote = req.socket?.remoteAddress ?? ''
  return remote === '127.0.0.1' || remote === '::1' || remote === '::ffff:127.0.0.1'
}

export function apply(ctx, config = {}) {
  if (config.enabled === false) return

  const percent = Number(config.volume)
  const targetPeak = Math.min(100, Math.max(1, Number.isFinite(percent) ? percent : 22)) / 100
  const adaptive = config.adaptiveVolume !== false

  let muted = readState().muted

  const play = (wav = soundPath(config.sound)) => {
    try {
      // NOT detached: on this Host a detached child is reaped before it reaches
      // audio init (exits in ~120 ms with code 0 and no output). Foreground
      // spawn works, and the chime only needs ~2.5 s of lifetime.
      const child = spawn(
        'powershell.exe',
        [
          '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
          '-File', PLAY_SCRIPT,
          '-Wav', wav,
          '-Volume', String(targetPeak),
          '-Adaptive', adaptive ? '1' : '0',
          '-MaxGain', String(MAX_GAIN),
        ],
        { stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true },
      )
      let output = ''
      child.stdout?.on('data', (chunk) => { output += chunk })
      child.stderr?.on('data', (chunk) => { output += chunk })
      child.on('error', (error) => logPlay(`spawn error: ${error?.message ?? error}`))
      child.on('exit', (code, signal) => logPlay(`exit code=${code} signal=${signal} out=${JSON.stringify(output.trim())}`))
      child.unref()
      logPlay(`spawned pid=${child.pid}`)
    } catch (error) {
      logPlay(`threw: ${error?.message ?? error}`)
    }
  }

  // ---- Notification-area icon: state hint, mute switch, taskbar flash ----

  let trayChild = null

  const stopTray = () => {
    if (!trayChild) return
    try {
      trayChild.kill()
    } catch {
      // Already gone.
    }
    trayChild = null
  }

  const startTray = () => {
    if (config.tray === false) return
    stopTray()
    try {
      trayChild = spawn(
        'powershell.exe',
        [
          '-NoProfile', '-STA', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
          '-File', TRAY_SCRIPT,
          '-StateFile', STATE_FILE,
          '-EventsFile', EVENTS_FILE,
          '-IconOn', TRAY_ICON_ON,
          '-IconOff', TRAY_ICON_OFF,
          '-IconRing', TRAY_ICON_RING,
          '-PreviewScript', PLAY_SCRIPT,
          '-SoundsDir', SOUND_DIR,
          '-ParentPid', String(process.pid),
        ],
        { stdio: 'ignore', windowsHide: true },
      )
      trayChild.on('error', () => {
        trayChild = null
      })
      trayChild.on('exit', () => {
        trayChild = null
      })
    } catch {
      trayChild = null
    }
  }

  startTray()
  ctx.effect(() => () => stopTray(), 'ding-chime:tray')

  if (config.preview === true) play(soundPath(readState().sound ?? config.sound))

  // ---- Mute switch shared with the client half over the local Web route ----
  //
  // `inject` waits for the carrier: at boot this plugin's fiber can activate
  // before `webServer` mounts, and `ctx.get('webServer')` would be undefined.

  ctx.inject(['webServer'], (webCtx) => {
    webCtx.effect(() => {
      const webServer = webCtx.get('webServer')
      if (!webServer || typeof webServer.register !== 'function') return
      return webServer.register({
        kind: 'exact',
        path: ROUTE_PATH,
        handler: async (req, res) => {
          const send = (status, payload) => {
            res.writeHead(status, {
              'content-type': 'application/json; charset=utf-8',
              'cache-control': 'no-store',
            })
            res.end(JSON.stringify(payload))
          }

          if (!isLoopback(req)) return send(403, { error: 'loopback only' })

          if (req.method === 'GET') {
            const state = readState()
            return send(200, {
              muted: state.muted,
              sound: resolveSound(state.sound ?? config.sound),
              volume: Math.round(targetPeak * 100),
              adaptiveVolume: adaptive,
              tray: { pid: trayChild?.pid ?? null },
            })
          }

          if (req.method === 'POST') {
            try {
              const body = await readJsonBody(req)
              const state = readState()
              if (typeof body.muted === 'boolean') {
                muted = body.muted
                state.muted = body.muted
              }
              if (typeof body.sound === 'string') {
                state.sound = resolveSound(body.sound)
              }
              writeState(state)
              return send(200, {
                muted: state.muted,
                sound: resolveSound(state.sound ?? config.sound),
                volume: Math.round(targetPeak * 100),
                adaptiveVolume: adaptive,
              })
            } catch (error) {
              return send(400, { error: String(error?.message ?? error), muted })
            }
          }

          return send(405, { error: 'method not allowed' })
        },
      })
    }, 'ding-chime:mute-route')
  })

  /** id -> 'running' (an interval we saw start) | 'dinged' (already announced) */
  const states = new Map()
  let lastPlayedAt = 0

  const isTopLevel = (id) => {
    if (config.subagents === true) return true
    try {
      const agents = ctx.get('agents')
      if (!agents || typeof agents.roots !== 'function') return true
      return agents.roots().some((agent) => agent.id === id)
    } catch {
      return true
    }
  }

  const ding = () => {
    // The tray may have muted or switched voices without telling us: re-read.
    const state = readState()
    muted = state.muted
    if (muted) return
    const now = Date.now()
    if (now - lastPlayedAt < DEBOUNCE_MS) return
    lastPlayedAt = now
    try {
      writeFileSync(EVENTS_FILE, JSON.stringify({ lastDing: now }), 'utf8')
    } catch {
      // The tray just misses the flash.
    }
    play(soundPath(state.sound ?? config.sound))
  }

  ctx.effect(() => {
    const offStatus = ctx.on('agent/status', ({ agent, status }) => {
      if (!agent) return
      const id = agent.id
      if (status === 'running') {
        states.set(id, 'running')
        return
      }
      if (status !== 'idle') return
      const previous = states.get(id)
      states.delete(id)
      if (previous === 'dinged') return
      if (!isTopLevel(id)) return
      ding()
    })

    const offStopping = ctx.on('agent/turn-stopping', ({ agent }) => {
      if (!agent) return
      const id = agent.id
      const current = states.get(id)
      if (current === 'running' || current === 'dinged') return
      if (!isTopLevel(id)) return
      states.set(id, 'dinged')
      ding()
    })

    const offDisposed = ctx.on('agent/disposed', ({ agent }) => {
      if (agent) states.delete(agent.id)
    })

    return () => {
      offStatus()
      offStopping()
      offDisposed()
      states.clear()
    }
  }, 'ding-chime:completion-chime')
}
