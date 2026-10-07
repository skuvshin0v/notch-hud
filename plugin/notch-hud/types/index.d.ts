/** What the band above the prompt shows while an ask waits in the widget. */
export type WidgetRouted = { id: string; kind: 'question' | 'permission'; label: string }

declare module 'claude-code' {
  interface PluginState {
    'notch-hud': { routed: WidgetRouted | null }
  }
}
