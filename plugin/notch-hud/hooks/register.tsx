import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { WidgetRouted } from '../types'

// Bridge between a Claude Code session and the Notch HUD app.
// Everything goes through plain files under ~/.claude/notch-hud:
//   sessions/<sid>.json        this session's progress (written here)
//   answers/<sid>/<ask>.json   an answer the widget gives to a pending ask
//   answers/<sid>/<ask>.cancel the person chose to answer in the terminal
//   inbox/<sid>.json           a follow-up prompt typed in the widget
//   stop/<sid>                 the person pressed Stop on the session's card
//   presence.json              the widget's heartbeat and the frontmost app
//   limits.json                the account's rate-limit windows (written here)

type Task = { id: string; subject: string; status: string }

type Pending =
  | { id: string; kind: 'question'; questions: unknown[] }
  | { id: string; kind: 'permission'; tool: string; summary: string; detail: string; canAlways: boolean }

/** Who a prompt came from: the person, or an agent / background task speaking in their place. */
type From = 'you' | 'agent'

/** One exchange of the chat, newest last; the widget shows the last few. */
type Exchange = { from: From; prompt: string; answer: string }

/** A subagent of this session that is still going, and what it is doing. */
type AgentCard = { id: string; description: string; type: string; status: string; activity: string }

const HISTORY = 5
/** How much of an answer the card keeps: any ordinary reply whole (5 of them stay well under a megabyte). */
const ANSWER_MAX = 20_000

type SessionFile = {
  id: string
  cwd: string
  project: string
  host: string
  hostName: string
  pid: number
  title: string
  status: 'idle' | 'working' | 'waiting' | 'done' | 'error' | 'aborted'
  turnStartedAt: number | null
  activity: string
  tool: string
  tasks: Task[]
  lastText: string
  /** The prompt the last answer was for. */
  lastPrompt: string
  lastPromptFrom: From
  history: Exchange[]
  agents: AgentCard[]
  pending: Pending | null
  turns: number
  updatedAt: number
}

const routed = atom({ plugin: 'notch-hud', key: 'routed' } as const, null as WidgetRouted | null)

const PRESENCE_FRESH_MS = 6_000
const MIN_MACOS = 15
const WARNED_KEY = 'unsupported-warned'
const UNSUPPORTED_TEXT =
  'Notch HUD works only on macOS 15+ with Apple Silicon. On this machine the notch-hud mod does nothing.'
const WAIT_SCRIPT =
  'while [ ! -f "$1" ] && [ ! -f "$2" ]; do sleep 0.25; done; ' +
  'if [ -f "$1" ]; then cat "$1"; else printf __CANCEL__; fi; rm -f "$1" "$2"'

// A prompt sent from the widget reaches the turn wrapped in the engine's framing
// ("The notch-hud plugin sent a message: … This is how Claude Code surfaces …"): keep the words.
const unframe = (text: string) =>
  text
    .replace(/^\s*The [\w-]+ plugin sent a message:\s*/, '')
    .replace(/\s*This is how Claude Code surfaces a prompt[\s\S]*$/, '')

/** A new exchange starts: the prompt now, its answer later. */
function beginExchange(f: SessionFile, from: From, prompt: string) {
  f.history = [...(f.history ?? []), { from, prompt: clip(prompt, 1000), answer: '' }].slice(-HISTORY)
}

/** The answer (or error, or command output) of the running exchange. */
function endExchange(f: SessionFile, answer: string) {
  const last = f.history.at(-1)
  if (last !== undefined && last.answer === '') last.answer = clip(answer, ANSWER_MAX)
  else f.history = [...f.history, { from: 'you' as From, prompt: '', answer: clip(answer, ANSWER_MAX) }].slice(-HISTORY)
}

// A prompt that reached the turn from a subagent or a background task, by its wording, for when
// prompt.submit did not say (a delivery queued before the hook saw it).
const AGENT_TEXT = /^\s*(<agent-message|<task-notification|\[Subagent hand-back\]|Another Claude session sent a message)/

/** Prompts the person made: typed, from the phone bridge, or the SDK host's own. */
const PERSON_ORIGINS = new Set(['composer', 'bridge', 'sdk'])

/** The session's subagents that are still going, each with what it last did. */
async function refreshAgents($: EngineInterface) {
  const list = await $.agent.list().catch(() => [])
  const going = list.filter(a => a.status === 'pending' || a.status === 'running' || a.status === 'waiting')
  const agents: AgentCard[] = going.map(a => ({
    id: a.id,
    description: a.description,
    type: a.type,
    status: a.status,
    activity: ctx.agentActivity[a.id] ?? '',
  }))
  await patch($, f => {
    if (JSON.stringify(f.agents) !== JSON.stringify(agents)) f.agents = agents
  })
}

/** The text of a row's content, whether a string or Messages API blocks. */
function messageText(content: unknown): string {
  if (typeof content === 'string') return content
  if (!Array.isArray(content)) return ''
  return content
    .map(b => (b !== null && typeof b === 'object' && (b as { type?: unknown }).type === 'text' ? String((b as { text?: unknown }).text ?? '') : ''))
    .join('\n')
}

// Terminal colour codes some commands print.
const stripAnsi = (text: string) => text.replace(/\u001b\[[0-9;]*m/g, '')

const basename = (path: string) => path.replace(/\/+$/, '').split('/').pop() || path
const clip = (text: string, max: number) => (text.length > max ? `${text.slice(0, max - 1)}…` : text)
const oneLine = (text: string) => text.replace(/\s+/g, ' ').trim()

const GENERIC_ERROR = 'the turn ended with an API error.'
const GENERIC_REFUSAL = 'the model declined to answer.'

/** What the terminal says of an API error that ended a turn (StopFailure), or ''. */
function failureText(e: { error?: unknown; error_details?: unknown; last_assistant_message?: unknown }): string {
  const str = (value: unknown) => (typeof value === 'string' ? stripAnsi(value).trim() : '')
  const kind = str(e.error)
  return str(e.last_assistant_message) || str(e.error_details) || (kind !== '' && kind !== 'unknown' ? `API error: ${kind}` : '')
}

function describeTool(tool: string, input: Record<string, unknown>): string {
  const str = (key: string) => (typeof input[key] === 'string' ? (input[key] as string) : '')
  switch (tool) {
    case 'Bash':
      return str('description') || clip(oneLine(str('command')), 80)
    case 'Read':
    case 'Edit':
    case 'Write':
    case 'NotebookEdit':
      return `${tool} ${basename(str('file_path') || str('notebook_path'))}`
    case 'Grep':
    case 'Glob':
      return `${tool} ${clip(str('pattern'), 60)}`
    case 'WebFetch':
      return `Fetch ${clip(str('url'), 70)}`
    case 'WebSearch':
      return `Search “${clip(str('query'), 60)}”`
    case 'Agent':
    case 'Task':
      return `Agent: ${str('description') || 'subagent'}`
    default:
      return tool.startsWith('mcp__') ? tool.split('__').slice(1).join(' · ') : tool
  }
}

function describePermission(tool: string, input: unknown): { summary: string; detail: string } {
  const obj = (input ?? {}) as Record<string, unknown>
  const str = (key: string) => (typeof obj[key] === 'string' ? (obj[key] as string) : '')
  if (tool === 'Bash') return { summary: str('description') || 'Run a command', detail: str('command') }
  if (tool === 'ExitPlanMode') return { summary: 'Approve the plan', detail: str('plan') }
  if (str('file_path')) return { summary: `${tool} ${basename(str('file_path'))}`, detail: str('file_path') }
  return { summary: describeTool(tool, obj), detail: clip(JSON.stringify(obj, null, 2), 4000) }
}

// Per-load state; a hot reload starts it over and session.start fills it again.
const ctx = {
  home: '',
  host: '',
  hostName: '',
  pid: 0,
  lastCommand: '',
  /** Who the next turn's prompt is from, as prompt.submit saw it; the widget's own prompts are the person's. */
  nextFrom: 'you' as From,
  /** What each subagent is doing, by its id, from its tool calls. */
  agentActivity: {} as Record<string, string>,
  lastSid: '',
  /** The running turn, the one Stop in the widget ends; '' between turns. */
  turnId: '',
  /** Why the running turn failed, as the terminal says it (StopFailure); '' when it did not. */
  failure: '',
  /**
   * The card is published: a turn (or a slash command) has run, or the file was already
   * there. Until then nothing is written, so a pre-started spare process
   * (`claude bg-spare`) that never runs a turn shows no idle card.
   */
  live: false,
  file: null as SessionFile | null,
  writing: Promise.resolve() as Promise<void>,
}

const dir = () => `${ctx.home}/.claude/notch-hud`

async function sid($: EngineInterface) {
  const id = await $.session.id()
  if (ctx.lastSid !== '' && ctx.lastSid !== id) {
    // /clear or a resume moved the session: the old card goes away.
    await $.process.run(['rm', '-f', `${dir()}/sessions/${ctx.lastSid}.json`]).catch(() => undefined)
  }
  ctx.lastSid = id
  return id
}

async function load($: EngineInterface): Promise<SessionFile> {
  if (ctx.file !== null) return ctx.file
  const id = await sid($)
  const cwd = await $.session.cwd()
  const kept = await $.fs
    .read(`${dir()}/sessions/${id}.json`)
    .then(text => JSON.parse(text) as SessionFile)
    .catch(() => null)
  if (kept !== null) ctx.live = true
  ctx.file = kept ?? {
    id,
    cwd,
    project: basename(cwd),
    host: ctx.host,
    hostName: ctx.hostName,
    pid: ctx.pid,
    title: '',
    status: 'idle',
    turnStartedAt: null,
    activity: '',
    tool: '',
    tasks: [],
    lastText: '',
    lastPrompt: '',
    lastPromptFrom: 'you',
    history: [],
    agents: [],
    pending: null,
    turns: 0,
    updatedAt: 0,
  }
  return ctx.file
}

// Every change goes through here, one write at a time; before the card is live
// it only changes the copy in memory.
function patch($: EngineInterface, change: (f: SessionFile) => void): Promise<void> {
  ctx.writing = ctx.writing
    .then(async () => {
      const f = await load($)
      const id = await sid($)
      f.id = id
      f.history ??= []
      f.agents ??= []
      f.lastPromptFrom ??= 'you'
      change(f)
      f.updatedAt = await $.clock.now()
      if (!ctx.live) return
      await $.fs.write(`${dir()}/sessions/${id}.json`, JSON.stringify(f, null, 2))
    })
    .catch(() => undefined)
  return ctx.writing
}

async function isWidgetWatching($: EngineInterface): Promise<boolean> {
  const presence = await $.fs
    .read(`${dir()}/presence.json`)
    .then(
      text =>
        JSON.parse(text) as { updatedAt: number; frontmost: string; routeAlways?: boolean; away?: string[] },
    )
    .catch(() => null)
  if (presence === null) return false
  const now = await $.clock.now()
  if (now - presence.updatedAt > PRESENCE_FRESH_MS) return false
  if (presence.routeAlways === true) return true
  // The widget resolves which app each session lives in (by pid) and lists
  // the sessions whose app is not the frontmost one.
  if (presence.away !== undefined) return presence.away.includes(await sid($))
  return ctx.host !== '' && presence.frontmost !== ctx.host
}

// Hands an ask to the widget and waits for its answer. Resolves the answer's
// JSON text, or null when the widget is not watching or the person chose the terminal.
async function askWidget($: EngineInterface, signal: AbortSignal, pending: Pending, label: string) {
  if (!(await isWidgetWatching($))) return null
  const id = await sid($)
  const answerPath = `${dir()}/answers/${id}/${pending.id}.json`
  const cancelPath = `${dir()}/answers/${id}/${pending.id}.cancel`
  await patch($, f => {
    f.pending = pending
    f.status = 'waiting'
  })
  await update($, routed, () => ({ id: pending.id, kind: pending.kind, label }))
  $.ui.status('⧉ waiting for an answer in the widget')
  let out = ''
  try {
    await $.process.run(['mkdir', '-p', `${dir()}/answers/${id}`])
    const wait = $.process.spawn({ argv: ['/bin/sh', '-c', WAIT_SCRIPT, 'wait', answerPath, cancelPath] })
    for await (const chunk of wait) {
      if (signal.aborted) break
      if (chunk.stream === 'stdout') out += chunk.text
    }
  } finally {
    await update($, routed, () => null)
    $.ui.status(undefined)
    await patch($, f => {
      f.pending = null
      f.status = 'working'
    })
  }
  return out === '' || out === '__CANCEL__' ? null : out
}

// Starts the HUD app the plugin ships (app/Notch HUD.app) unless it is already beating.
async function launchWidget($: EngineInterface) {
  const app = `${$.plugin.root}/app/Notch HUD.app`
  if (!(await $.fs.exists(app))) return
  const presence = await $.fs
    .read(`${dir()}/presence.json`)
    .then(text => JSON.parse(text) as { updatedAt: number })
    .catch(() => null)
  if (presence !== null && (await $.clock.now()) - presence.updatedAt < PRESENCE_FRESH_MS) return
  await $.process.run(['open', '-g', app]).catch(() => undefined)
}

async function drainInbox($: EngineInterface) {
  const inbox = `${dir()}/inbox/${await sid($)}.json`
  if (!(await $.fs.exists(inbox))) return
  const text = await $.fs.read(inbox).catch(() => '')
  await $.process.run(['rm', '-f', inbox])
  let prompt = ''
  try {
    prompt = String((JSON.parse(text) as { text?: unknown }).text ?? '')
  } catch {
    return
  }
  if (prompt.trim() !== '') void $.prompt.submit({ text: prompt })
}

// Stop pressed in the widget: ends the running turn, as Esc does in the terminal.
async function drainStop($: EngineInterface) {
  const stop = `${dir()}/stop/${await sid($)}`
  if (!(await $.fs.exists(stop))) return
  await $.process.run(['rm', '-f', stop])
  const turnId = ctx.turnId
  if (turnId === '') return
  ctx.turnId = ''
  await $.turn.abort({ turnId }).catch(() => undefined)
  await patch($, f => {
    f.status = 'aborted'
    f.activity = ''
    f.tool = ''
    f.pending = null
  })
}

// The widget is an Apple Silicon app built for macOS 15+. hw.optional.arm64 is
// the machine's, so a claude running under Rosetta still counts.
async function hudSupported($: EngineInterface): Promise<boolean> {
  const out = async (argv: string[]) =>
    (await $.process.run(argv).catch(() => null))?.stdout.trim() ?? ''
  if ((await out(['uname', '-s'])) !== 'Darwin') return false
  if ((await out(['sysctl', '-n', 'hw.optional.arm64'])) !== '1') return false
  return Number.parseInt(await out(['sw_vers', '-productVersion']), 10) >= MIN_MACOS
}

/** Says once, ever, that this machine gets no HUD; the store keeps it across sessions. */
async function warnUnsupported($: EngineInterface) {
  if ((await $.store.get(WARNED_KEY).catch(() => null)) === true) return
  $.ui.toast(UNSUPPORTED_TEXT, { timeoutMs: 15_000 })
  await $.store.set(WARNED_KEY, true).catch(() => undefined)
}

type RateLimit = { kind: string; percentUsed: number; resetsAt?: string }

/** The account's windows are the same in every session: whichever measured last writes them. */
async function writeLimits($: EngineInterface, limits: RateLimit[]) {
  if (ctx.home === '' || limits.length === 0) return
  const body = { updatedAt: await $.clock.now(), limits: limits.map(l => ({ kind: l.kind, percentUsed: l.percentUsed, resetsAt: l.resetsAt })) }
  await $.fs.write(`${dir()}/limits.json`, JSON.stringify(body, null, 2)).catch(() => undefined)
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    const started = await next(e)
    // Every other hook does its work only once ctx.home is set, so an
    // unsupported machine leaves it empty and the mod stays out of the way.
    if (!(await hudSupported($))) {
      ctx.home = ''
      if (e.isInteractive) await warnUnsupported($)
      return started
    }
    ctx.home = (await $.env.get('HOME')) ?? ''
    ctx.host = (await $.env.get('__CFBundleIdentifier')) ?? ''
    ctx.hostName = (await $.env.get('TERM_PROGRAM')) ?? ''
    // The sh's parent is this claude process: the widget walks up from it to the app.
    const ppid = await $.process.run(['/bin/sh', '-c', 'echo $PPID']).catch(() => null)
    ctx.pid = Number(ppid?.stdout.trim() ?? 0) || 0
    // A person is at it in the terminal (interactive) or in an app that hosts Claude Code
    // through the SDK and stays open (the VS Code and JetBrains extensions, the desktop app's
    // Code tab: CLAUDE_CODE_ENTRYPOINT claude-vscode, claude-desktop, …). A one-shot
    // `claude -p` is neither and stays out of the island.
    const entrypoint = (await $.env.get('CLAUDE_CODE_ENTRYPOINT')) ?? ''
    const hasPerson = e.isInteractive || /^claude-(vscode|desktop|jetbrains)/.test(entrypoint)
    if (ctx.home === '' || !hasPerson) return started
    await patch($, f => {
      f.host = ctx.host
      f.hostName = ctx.hostName
      f.pid = ctx.pid
      f.cwd = e.cwd
      f.project = basename(e.cwd)
      f.pending = null
      if (f.status === 'working' || f.status === 'waiting') f.status = 'idle'
    })

    await launchWidget($)

    // Heartbeat: the widget drops cards that stop beating (a crashed or killed session).
    $.clock.every(5_000, () => void (ctx.live ? refreshAgents($) : patch($, () => undefined)))

    // Follow-up prompts typed in the widget.
    $.clock.every(1_500, () => void drainInbox($))
    $.clock.every(1_500, () => void drainStop($))

    const usage = await $.session.usage().catch(() => null)
    if (usage) await writeLimits($, usage.rateLimits)
    return started
  })

  on('session.measure', async ($, e, next) => {
    if (e.changed.includes('rateLimits')) await writeLimits($, e.rateLimits)
    return next(e)
  })

  on('session.end', async ($, e, next) => {
    if (ctx.home !== '') {
      await $.process.run(['rm', '-f', `${dir()}/sessions/${e.sessionId}.json`]).catch(() => undefined)
      if (e.reason === 'clear') {
        ctx.file = null
        ctx.lastSid = ''
        ctx.live = false
      }
    }
    return next(e)
  })

  // Compaction: /compact works like a turn of its own; one the engine runs mid-turn only
  // changes what the turn is doing.
  on('classic.PreCompact', async ($, e, next) => {
    if (ctx.home !== '') {
      const now = await $.clock.now()
      const isManual = e.trigger === 'manual'
      if (isManual) ctx.live = true
      await patch($, f => {
        if (isManual) {
          f.status = 'working'
          f.turnStartedAt = now
        }
        f.activity = 'Compacting context…'
        f.tool = 'compact'
      })
    }
    return next(e)
  })

  on('classic.PostCompact', async ($, e, next) => {
    if (ctx.home !== '') {
      const isManual = e.trigger === 'manual'
      const summary = e.compact_summary.trim()
      await patch($, f => {
        f.tool = ''
        f.activity = isManual ? '' : 'Thinking…'
        if (isManual) {
          f.status = 'done'
          f.turns += 1
          f.lastText = clip(`**Context compacted.**${summary ? `\n\n${summary}` : ''}`, ANSWER_MAX)
          beginExchange(f, 'you', '/compact')
          endExchange(f, f.lastText)
        }
      })
    }
    return next(e)
  })

  // A slash command's output (/cost, /context, /model…) is the chat's latest answer. The
  // transcript keeps a local command's rows as `local_command` notices (door `notice`), its
  // name in one row and its output in the next; older builds sent them by door `command`.
  on('session.append', async ($, e, next) => {
    const kept = await next(e)
    if (ctx.home === '' || e.agentId !== undefined) return kept
    const isCommand = e.door === 'command' || (e.message.type === 'system' && e.message.name === 'local_command')
    if (!isCommand) return kept
    const text = messageText(e.message.content)
    const name = /<command-name>\s*(\/[^<\s]+)/.exec(text)?.[1]
    if (name !== undefined) ctx.lastCommand = name
    const out = /<local-command-(?:stdout|stderr)>([\s\S]*?)<\/local-command-(?:stdout|stderr)>/.exec(text)?.[1]?.trim()
    // /compact speaks through the compaction hooks above.
    if (out !== undefined && ctx.lastCommand !== '/compact') {
      const command = ctx.lastCommand
      ctx.live = true
      await patch($, f => {
        f.status = 'done'
        f.activity = ''
        f.tool = ''
        f.turns += 1
        f.lastText = clip(`\`${command}\`${out ? `\n\n${stripAnsi(out)}` : ''}`, ANSWER_MAX)
        beginExchange(f, 'you', command)
        endExchange(f, out ? stripAnsi(out) : '')
      })
    }
    return kept
  }).catch(($, e, next) => next(e))

  // Where the next turn's prompt comes from: the person, or an agent / task notification.
  // (This plugin's own prompts never pass its own hooks; they are the person's, the default.)
  on('prompt.submit', async ($, e, next) => {
    const entered = await next(e)
    if (entered.drop === undefined && e.turnId === undefined) {
      ctx.nextFrom = PERSON_ORIGINS.has(e.origin.kind) ? 'you' : 'agent'
    }
    return entered
  }).catch(($, e, next) => next(e))

  on('classic.SubagentStart', async ($, e, next) => {
    const done = await next(e)
    if (ctx.home !== '' && ctx.live) await refreshAgents($)
    return done
  })

  on('classic.SubagentStop', async ($, e, next) => {
    const done = await next(e)
    if (ctx.home !== '' && ctx.live) await refreshAgents($)
    return done
  })

  on('turn.start', async ($, e, next) => {
    ctx.turnId = e.turnId
    ctx.failure = ''
    if (ctx.home !== '') {
      ctx.live = true
      const now = await $.clock.now()
      const from: From = ctx.nextFrom === 'agent' || AGENT_TEXT.test(e.text) ? 'agent' : 'you'
      ctx.nextFrom = 'you'
      await patch($, f => {
        // The person's latest prompt names the session, however short; a slash command or an
        // agent's message keeps the one before.
        const text = oneLine(unframe(e.text))
        if (from === 'you' && text !== '' && !text.startsWith('/')) f.title = clip(text, 80)
        f.lastPromptFrom = from
        beginExchange(f, from, unframe(e.text).trim())
        f.status = 'working'
        f.turnStartedAt = now
        f.activity = 'Thinking…'
        f.tool = ''
        f.turns += 1
        f.lastPrompt = clip(unframe(e.text).trim(), 1000)
      })
    }
    return next(e)
  })

  on('turn.complete', async ($, e, next) => {
    const done = await next(e)
    if (e.agentId === undefined) ctx.turnId = ''
    if (ctx.home !== '' && e.agentId === undefined) {
      const answer = done.text.trim()
      // An API error (usage limit, overload…) or a refusal leaves no answer: say what happened.
      const lastText =
        e.reason === 'error'
          ? `**Error:** ${ctx.failure || answer || GENERIC_ERROR}`
          : e.reason === 'refusal'
            ? answer || `**Refused:** ${e.refusal.explanation?.trim() || GENERIC_REFUSAL}`
            : answer
      ctx.failure = ''
      await patch($, f => {
        f.status = e.reason === 'answer' ? 'done' : e.reason === 'aborted' ? 'aborted' : 'error'
        f.activity = ''
        f.tool = ''
        f.lastText = clip(lastText, ANSWER_MAX)
        endExchange(f, lastText)
        f.pending = null
      })
    }
    return done
  })

  // An API error ended the turn: keep the words the terminal shows for it. The engine may
  // raise this before or after turn.complete, so the card takes it either way.
  on('classic.StopFailure', async ($, e, next) => {
    if (ctx.home !== '' && e.agent_id === undefined) {
      const failure = failureText(e)
      if (ctx.turnId !== '') ctx.failure = failure
      else if (failure !== '') {
        // turn.complete already wrote the card.
        await patch($, f => {
          if (f.status === 'error') f.lastText = clip(`**Error:** ${failure}`, ANSWER_MAX)
        })
      }
    }
    return next(e)
  }).catch(($, e, next) => next(e))

  on('tool.call', { tool: 'AskUserQuestion' }, async ($, e, next) => {
    if (ctx.home === '') return next(e)
    const id = e.tool_use_id ?? `ask-${await $.clock.now()}`
    const first = e.questions[0]?.question ?? 'Question'
    const raw = await askWidget($, next.signal, { id, kind: 'question', questions: e.questions }, first)
    if (raw === null) return next(e)
    const { answers } = JSON.parse(raw) as { answers: Record<string, string> }
    return { result: { questions: e.questions, answers } }
  }).catch(($, e, next) => next(e))

  on('tool.call', async ($, e, next) => {
    if (ctx.home !== '' && e.tool !== 'AskUserQuestion' && e.agentId === undefined) {
      const activity = describeTool(String(e.tool), e as unknown as Record<string, unknown>)
      const tool = String(e.tool)
      void patch($, f => {
        f.activity = activity
        f.tool = tool
      })
    } else if (ctx.home !== '' && e.agentId !== undefined && ctx.live) {
      // A subagent at work: its row in the card says what it is doing.
      const agentId = e.agentId
      const activity = describeTool(String(e.tool), e as unknown as Record<string, unknown>)
      ctx.agentActivity[agentId] = activity
      void patch($, f => {
        const card = f.agents.find(a => a.id === agentId)
        if (card !== undefined) card.activity = activity
      })
    }
    const ran = await next(e)
    if (ctx.home === '' || ran.deny !== undefined || ran.isError === true) return ran

    if (e.tool === 'TodoWrite') {
      const todos = e.todos
      void patch($, f => {
        f.tasks = todos.map((t, i) => ({ id: String(i), subject: t.content, status: t.status }))
      })
    } else if (e.tool === 'TaskCreate') {
      const task = (ran.result as { task?: { id: string; subject: string } } | undefined)?.task
      if (task) void patch($, f => void f.tasks.push({ id: task.id, subject: task.subject, status: 'pending' }))
    } else if (e.tool === 'TaskUpdate') {
      const { taskId, status, subject } = e
      void patch($, f => {
        const task = f.tasks.find(t => t.id === taskId)
        if (!task) return
        if (status === 'deleted') f.tasks = f.tasks.filter(t => t.id !== taskId)
        else {
          if (status) task.status = status
          if (subject) task.subject = subject
        }
      })
    }
    return ran
  }).catch(($, e, next) => next(e))

  on('classic.PermissionRequest', async ($, e, next) => {
    if (ctx.home === '' || e.tool_name === 'AskUserQuestion') return next(e)
    const { summary, detail } = describePermission(e.tool_name, e.tool_input)
    const id = `perm-${await $.clock.now()}`
    const canAlways = (e.permission_suggestions?.length ?? 0) > 0
    const raw = await askWidget(
      $,
      next.signal,
      { id, kind: 'permission', tool: e.tool_name, summary, detail, canAlways },
      `${e.tool_name}: ${summary}`,
    )
    if (raw === null) return next(e)
    const answer = JSON.parse(raw) as { decision: 'allow' | 'always' | 'deny'; message?: string }
    if (answer.decision === 'deny') {
      return { decision: { behavior: 'deny', message: answer.message || 'Denied from Notch HUD.' } }
    }
    return answer.decision === 'always' && canAlways
      ? { decision: { behavior: 'allow', updatedPermissions: e.permission_suggestions } }
      : { decision: { behavior: 'allow' } }
  }).catch(($, e, next) => next(e))

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const ask = await read($, routed)
    if (ask === null) return next(e)
    const { Box, Button, Text } = $.ui.resolve(e)
    const cancel = `${dir()}/answers/${await sid($)}/${ask.id}.cancel`
    return (
      <Box>
        <Text color="yellow">⧉ </Text>
        <Text>
          {ask.kind === 'question' ? 'Question' : 'Permission'} waiting in Notch HUD:{' '}
        </Text>
        <Text dimColor>{clip(ask.label, Math.max(20, (e.props.bodyColumns ?? 80) - 60))} </Text>
        <Button key="here" label="Answer here" variant="primary" onPress={() => void $.fs.write(cancel, '')} />
      </Box>
    )
  })
}
