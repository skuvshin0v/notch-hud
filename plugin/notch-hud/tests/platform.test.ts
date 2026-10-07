import { expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'

const START = { cwd: '/work/project', surface: 'terminal', isInteractive: true } as const

/** Answers session.start and the platform probes as the given machine would; records every command run. */
function machine(on: On, answers: Record<string, string | null>) {
  const ran: string[] = []
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('process.run', ($, e) => {
    const cmd = e.argv.join(' ')
    ran.push(cmd)
    const stdout = answers[e.argv[0] ?? '']
    if (stdout === null || stdout === undefined) return { deny: `${e.argv[0]}: not found` }
    return { value: { exitCode: 0, stdout: `${stdout}\n`, stderr: '' } as never }
  })
  return ran
}

function toasts(on: On) {
  const shown: string[] = []
  on('ui.toast', ($, e) => {
    shown.push(e.text)
    return { value: undefined }
  })
  return shown
}

test('on a machine without the HUD the mod warns once and then stays out of the way', async ($, on) => {
  mock.env(on, { HOME: '/nonexistent-home-for-notch-hud-test' })
  mock.store(on)
  const ran = machine(on, { uname: 'Linux', sysctl: null, sw_vers: null })
  const shown = toasts(on)
  let reachedEngine = false
  on('tool.call', { tool: 'AskUserQuestion' }, ($, e) => {
    reachedEngine = true
    return { result: { questions: e.questions, answers: {} } }
  })

  await $.session.start(START)
  await $.session.start(START)

  expect(shown.length).toBe(1)
  expect(shown[0]).toMatch('macOS 15+')
  // Only the probe ran: no launch of the app, no files, no shell.
  expect(ran).toEqual(['uname -s', 'uname -s'])

  await $.tool.call({ tool: 'AskUserQuestion', questions: [] } as never)
  expect(reachedEngine).toBe(true)
})

test('an Intel Mac or an older macOS gets the warning too', async ($, on) => {
  mock.env(on, { HOME: '/nonexistent-home-for-notch-hud-test' })
  mock.store(on)
  machine(on, { uname: 'Darwin', sysctl: '1', sw_vers: '14.6.1' })
  const shown = toasts(on)
  await $.session.start(START)
  expect(shown.length).toBe(1)
})

test('a machine that was already warned is not warned again', async ($, on) => {
  mock.env(on, { HOME: '/nonexistent-home-for-notch-hud-test' })
  mock.store(on, { 'unsupported-warned': true })
  machine(on, { uname: 'Darwin', sysctl: '0', sw_vers: '15.5' })
  const shown = toasts(on)
  await $.session.start(START)
  expect(shown.length).toBe(0)
})

test('an Apple Silicon Mac on macOS 15+ gets no warning', async ($, on) => {
  mock.env(on, { HOME: '/nonexistent-home-for-notch-hud-test' })
  mock.store(on)
  machine(on, { uname: 'Darwin', sysctl: '1', sw_vers: '15.5', '/bin/sh': '1', open: '' })
  const shown = toasts(on)
  await $.session.start(START)
  expect(shown.length).toBe(0)
})
