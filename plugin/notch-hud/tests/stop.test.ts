import { expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'

const HOME = '/home/hud-test'
const SID = 'sid-1'
const STOP = `${HOME}/.claude/notch-hud/stop/${SID}`
const START = { cwd: '/work/project', surface: 'terminal', isInteractive: true } as const

/** An Apple Silicon Mac on macOS 15 whose widget folder holds `files`; records the turns aborted. */
function mac(on: On, files: Set<string>) {
  const aborted: string[] = []
  mock.env(on, { HOME })
  mock.store(on)
  const clock = mock.clock(on, { now: 1_000 })
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('session.id', () => ({ value: SID }) as never)
  on('session.cwd', () => ({ value: '/work/project' }) as never)
  on('session.usage', () => ({ deny: 'no usage in tests' }) as never)
  on('process.run', ($, e) => {
    const answers: Record<string, string> = { uname: 'Darwin', sysctl: '1', sw_vers: '15.4', '/bin/sh': '1' }
    if (e.argv[0] === 'rm') for (const path of e.argv.slice(2)) files.delete(path)
    return { value: { exitCode: 0, stdout: `${answers[e.argv[0] ?? ''] ?? ''}\n`, stderr: '' } as never }
  })
  on('fs.exists', ($, e) => ({ value: files.has((e as { path: string }).path) }) as never)
  on('fs.read', () => ({ deny: 'no such file' }) as never)
  on('fs.write', () => ({ value: undefined }) as never)
  on('turn.start', ($, e) => ({ turnId: e.turnId }))
  on('turn.abort', ($, e) => {
    aborted.push(e.turnId)
    return { value: undefined } as never
  })
  return { aborted, clock }
}

test('Stop in the widget ends the running turn', async ($, on) => {
  const files = new Set<string>()
  const { aborted, clock } = mac(on, files)
  await $.session.start(START)
  await $.turn.start({ text: 'refactor everything', turnId: 'turn-7' })

  files.add(STOP)
  await clock.advance(1_500)

  expect(aborted).toEqual(['turn-7'])
  expect(files.has(STOP)).toBe(false)
})

test('Stop with no turn running does nothing but clear the request', async ($, on) => {
  const files = new Set<string>([STOP])
  const { aborted, clock } = mac(on, files)
  await $.session.start(START)

  await clock.advance(1_500)

  expect(aborted).toEqual([])
  expect(files.has(STOP)).toBe(false)
})
