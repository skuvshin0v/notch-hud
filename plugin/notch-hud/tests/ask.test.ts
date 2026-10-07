import { expect, mock, test } from 'claude-code/testing'

const QUESTIONS = [
  {
    question: 'Which color?',
    header: 'Color',
    multiSelect: false,
    options: [
      { label: 'Red', description: 'warm' },
      { label: 'Blue', description: 'cool' },
    ],
  },
]

test('a question goes to the terminal dialog when no widget is watching', async ($, on) => {
  mock.env(on, { HOME: '/nonexistent-home-for-notch-hud-test' })
  let reachedEngine = false
  on('tool.call', { tool: 'AskUserQuestion' }, ($, e) => {
    reachedEngine = true
    return { result: { questions: e.questions, answers: { 'Which color?': 'Blue' } } }
  })
  const ran = await $.tool.call({ tool: 'AskUserQuestion', questions: QUESTIONS })
  expect(reachedEngine).toBe(true)
  expect(ran.isError).toBeUndefined()
})

test('a permission ask falls through to the engine when no widget is watching', async ($, on) => {
  mock.env(on, { HOME: '/nonexistent-home-for-notch-hud-test' })
  on('classic.PermissionRequest', () => ({ decision: { behavior: 'deny', message: 'engine' } }))
  const res = await $.classic.PermissionRequest({ tool_name: 'Bash', tool_input: { command: 'ls' } } as never)
  expect(res.decision).toEqual({ behavior: 'deny', message: 'engine' })
})
