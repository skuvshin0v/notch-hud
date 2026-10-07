import { expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'

const HOME = '/nonexistent-home-for-notch-hud-test'

/** A supported Mac; counts the mod's polls of the widget's inbox. */
function mac(on: On) {
  const polls: string[] = []
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('session.id', () => ({ value: 'hosts-test-session' }) as never)
  on('session.cwd', () => ({ value: '/work/game' }) as never)
  on('fs.read', () => ({ deny: 'no such file' }) as never)
  on('fs.write', () => ({ value: undefined }) as never)
  on('process.run', ($, e) => {
    const answers: Record<string, string> = { uname: 'Darwin', sysctl: '1', sw_vers: '15.3', '/bin/sh': '4242' }
    const stdout = answers[e.argv[0] ?? '']
    if (stdout === undefined) return { value: { exitCode: 0, stdout: '', stderr: '' } as never }
    return { value: { exitCode: 0, stdout: `${stdout}\n`, stderr: '' } as never }
  })
  on('fs.exists', ($, e) => {
    const path = (e as { path: string }).path
    if (path.includes('/inbox/')) polls.push(path)
    return { value: false } as never
  })
  return polls
}

test('a session hosted by the VS Code extension (not interactive) still polls the island', async ($, on) => {
  mock.env(on, { HOME, CLAUDE_CODE_ENTRYPOINT: 'claude-vscode' })
  mock.store(on)
  const clock = mock.clock(on)
  const polls = mac(on)
  await $.session.start({ cwd: '/work/game', surface: null, isInteractive: false })
  await clock.advance(3_100)
  expect(polls.length).toBeGreaterThan(0)
})

test('a one-shot claude -p run stays out of the island', async ($, on) => {
  mock.env(on, { HOME, CLAUDE_CODE_ENTRYPOINT: 'sdk-cli' })
  mock.store(on)
  const clock = mock.clock(on)
  const polls = mac(on)
  await $.session.start({ cwd: '/work/game', surface: null, isInteractive: false })
  await clock.advance(3_100)
  expect(polls.length).toBe(0)
})
