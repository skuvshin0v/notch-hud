import { expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'

const HOME = '/home/hud-test'
const SID = 'sid-1'
const CARD = `${HOME}/.claude/notch-hud/sessions/${SID}.json`
const START = { cwd: '/work/project', surface: 'terminal', isInteractive: true } as const

type Card = { status: string; turns: number; lastText: string }

/** An Apple Silicon Mac on macOS 15 with no widget files yet; `written` holds what the mod writes. */
function mac(on: On) {
  const written = new Map<string, string>()
  mock.env(on, { HOME })
  mock.store(on)
  const clock = mock.clock(on, { now: 1_000 })
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('session.id', () => ({ value: SID }) as never)
  on('session.cwd', () => ({ value: '/work/project' }) as never)
  on('session.usage', () => ({ deny: 'no usage in tests' }) as never)
  on('process.run', ($, e) => {
    const answers: Record<string, string> = { uname: 'Darwin', sysctl: '1', sw_vers: '15.4', '/bin/sh': '1' }
    return { value: { exitCode: 0, stdout: `${answers[e.argv[0] ?? ''] ?? ''}\n`, stderr: '' } as never }
  })
  on('fs.exists', () => ({ value: false }) as never)
  on('fs.read', () => ({ deny: 'no such file' }) as never)
  on('fs.write', ($, e) => {
    const { path, text } = e as { path: string; text: string }
    written.set(path, text)
    return { value: undefined } as never
  })
  on('turn.start', ($, e) => ({ turnId: e.turnId }))
  on('turn.complete', () => ({ text: '' }))
  on('classic.StopFailure', () => ({}))
  const card = () => {
    const text = written.get(CARD)
    return text === undefined ? null : (JSON.parse(text) as Card)
  }
  return { card, clock }
}

/** A `local_command` notice, as the transcript keeps a local slash command's rows. */
const notice = (text: string) =>
  ({
    message: { type: 'system', name: 'local_command', content: [{ type: 'text', text }] },
    door: 'notice',
    origin: { kind: 'engine' },
    uuid: `row-${text.length}`,
  }) as never

test('a session that never ran a turn publishes no card, even on its heartbeat', async ($, on) => {
  const { card, clock } = mac(on)
  await $.session.start(START)
  await clock.advance(10_000)
  expect(card()).toBe(null)

  await $.turn.start({ text: 'hello', turnId: 'turn-1' })
  expect(card()?.status).toBe('working')
  expect(card()?.turns).toBe(1)
})

test("a local slash command's output becomes the card's last answer", async ($, on) => {
  const { card } = mac(on)
  await $.session.start(START)
  await $.session.append(notice('<command-name>/resume</command-name>\n<command-message>resume</command-message>\n<command-args></command-args>'))
  await $.session.append(notice('<local-command-stdout>Resume cancelled</local-command-stdout>'))
  expect(card()?.status).toBe('done')
  expect(card()?.lastText).toBe('`/resume`\n\nResume cancelled')
})

test('/compact is left to the compaction hooks', async ($, on) => {
  const { card } = mac(on)
  await $.session.start(START)
  await $.session.append(notice('<command-name>/compact</command-name>'))
  await $.session.append(notice('<local-command-stdout>Compacted</local-command-stdout>'))
  expect(card()).toBe(null)
})

test('a turn that dies on an API error shows what the terminal says', async ($, on) => {
  const { card } = mac(on)
  await $.session.start(START)
  await $.turn.start({ text: 'go', turnId: 'turn-1' })
  await $.classic.StopFailure({ error: 'rate_limit', last_assistant_message: "You've hit your limit · resets 3pm" })
  await $.turn.complete({ reason: 'error', answer: '', durationMs: 5, isAborted: false, turnId: 'turn-1' })
  expect(card()?.status).toBe('error')
  expect(card()?.lastText).toBe("**Error:** You've hit your limit · resets 3pm")
})

test('a failure reported after the turn ended still reaches the card', async ($, on) => {
  const { card } = mac(on)
  await $.session.start(START)
  await $.turn.start({ text: 'go', turnId: 'turn-1' })
  await $.turn.complete({ reason: 'error', answer: '', durationMs: 5, isAborted: false, turnId: 'turn-1' })
  expect(card()?.lastText).toBe('**Error:** the turn ended with an API error.')
  await $.classic.StopFailure({ error: 'server_error', error_details: '500 Internal server error' })
  expect(card()?.lastText).toBe('**Error:** 500 Internal server error')
})
