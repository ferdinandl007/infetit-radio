const element = (id) => document.getElementById(id)
const audio = element('audio')
const tune = element('tune')
const idea = element('idea')
const submit = element('submit')
const status = element('idea-status')
const progress = element('progress')

let state = null
let stateReceived = 0
let currentAudio = null
let tuned = false
let sending = false
let polling = false

function clock(seconds) {
  const total = Math.floor(Math.max(0, seconds))
  return `${Math.floor(total / 60)}:${String(total % 60).padStart(2, '0')}`
}

function livePosition() {
  if (!state?.audio) return 0
  return Math.min(state.duration, state.position + (performance.now() - stateReceived) / 1000)
}

function updateTimeline() {
  const position = tuned && !audio.paused ? audio.currentTime : livePosition()
  progress.max = state?.duration || 1
  progress.value = position
  element('elapsed').textContent = clock(position)
  element('duration').textContent = clock(state?.duration ?? 0)
}

function updateButton() {
  tune.disabled = !tuned && !state?.audio
  element('play-icon').textContent = tuned ? 'Ⅱ' : '▶'
  element('tune-label').textContent = tuned ? 'Stop listening' : 'Tune in'
}

function syncPosition() {
  if (audio.readyState < 1 || currentAudio !== state?.audio || !state?.audio) return
  const target = Math.min(livePosition(), Math.max(0, audio.duration - 0.1))
  if (Number.isFinite(target) && Math.abs(audio.currentTime - target) > 1.5) audio.currentTime = target
}

async function listen() {
  if (!tuned || !state?.audio) return
  if (currentAudio !== state.audio) {
    currentAudio = state.audio
    audio.src = currentAudio
  }
  syncPosition()
  try {
    await audio.play()
    if (tuned) element('listening-status').textContent = ''
  } catch (error) {
    if (!tuned || error.name === 'AbortError') return
    if (error.name === 'NotAllowedError') {
      tuned = false
      updateButton()
      element('listening-status').textContent = 'Tap Tune in to start audio.'
    } else {
      element('listening-status').textContent = 'Reconnecting to the station…'
    }
  }
}

function render() {
  const isLive = Boolean(state?.audio)
  element('broadcast-status').dataset.live = isLive
  element('signal').textContent = isLive ? 'Live now' :
    state?.state === 'preparing' ? 'Preparing the next track' : 'Off air'
  if (state) {
    element('station').textContent = state.station
    element('station-description').textContent = state.description
    element('title').textContent = isLive ? state.title : 'Waiting for a track'
    document.title = `${state.station} · infetit radio`
  }
  if (!isLive) {
    if (currentAudio) {
      audio.pause()
      audio.removeAttribute('src')
      audio.load()
      currentAudio = null
    }
    if (tuned) element('listening-status').textContent = 'Waiting for the broadcast…'
  } else if (tuned && (currentAudio !== state.audio || audio.paused)) {
    if (!audio.error || currentAudio !== state.audio) void listen()
    else {
      currentAudio = null
      void listen()
    }
  } else if (tuned) {
    syncPosition()
  }
  submit.disabled = sending || !state?.suggestionToken
  updateButton()
  updateTimeline()
}

async function poll() {
  if (polling) return
  polling = true
  try {
    const response = await fetch('/state', { cache: 'no-store', signal: AbortSignal.timeout(4500) })
    if (!response.ok) throw new Error('Station offline')
    state = await response.json()
    stateReceived = performance.now()
  } catch {
    if (performance.now() - stateReceived < 5000) return
    state = null
    element('title').textContent = 'Waiting for a track'
  } finally {
    polling = false
  }
  render()
}

tune.addEventListener('click', () => {
  tuned = !tuned
  updateButton()
  if (tuned) void listen()
  else {
    audio.pause()
    element('listening-status').textContent = ''
  }
})
audio.addEventListener('loadedmetadata', syncPosition)
audio.addEventListener('ended', () => void poll())
audio.addEventListener('timeupdate', updateTimeline)
element('mute').addEventListener('click', (event) => {
  audio.muted = !audio.muted
  event.currentTarget.setAttribute('aria-pressed', String(audio.muted))
  event.currentTarget.textContent = audio.muted ? 'Unmute' : 'Mute'
})
element('share').addEventListener('click', async (event) => {
  const button = event.currentTarget
  try {
    await navigator.clipboard.writeText(new URL('/', location.href).href)
    button.textContent = 'Link copied'
    setTimeout(() => { button.textContent = 'Copy station link ↗' }, 2200)
  } catch {
    button.textContent = 'Copy the address from your browser'
  }
})
idea.addEventListener('input', () => {
  element('length').textContent = `${idea.value.length} / 160`
  status.textContent = ''
})
element('idea-form').addEventListener('submit', async (event) => {
  event.preventDefault()
  if (sending || !state?.suggestionToken) return
  sending = true
  submit.disabled = true
  try {
    const response = await fetch('/idea', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-Radio-Token': state.suggestionToken },
      body: JSON.stringify({ idea: idea.value }),
      signal: AbortSignal.timeout(6000)
    })
    status.textContent = (await response.text()) || 'Could not send the idea. Try again.'
    if (response.ok) {
      idea.value = ''
      element('length').textContent = '0 / 160'
    }
  } catch {
    status.textContent = 'Could not send the idea. Try again.'
  } finally {
    sending = false
    submit.disabled = !state?.suggestionToken
  }
})
document.addEventListener('visibilitychange', () => { if (!document.hidden) void poll() })
setInterval(() => void poll(), 1200)
void poll()
