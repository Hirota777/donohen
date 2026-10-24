import { createClient, type SupabaseClient } from '@supabase/supabase-js'

const url = import.meta.env.VITE_SUPABASE_URL as string | undefined
const key = (import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY || import.meta.env.VITE_SUPABASE_ANON_KEY) as string | undefined
export const db: SupabaseClient | null = url && key ? createClient(url, key, {
  auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: false }
}) : null

export class GameApiError extends Error {
  constructor(public code: string, message: string) { super(message); this.name = 'GameApiError' }
}

let protocolReady: Promise<void> | null = null
let identityRequest: Promise<string> | null = null

export async function ensureIdentity(): Promise<string> {
  if (!db) throw new GameApiError('UNAVAILABLE','今は遊べません。時間をおいて試してください。')
  if (!identityRequest) identityRequest = (async () => {
    if (!protocolReady) protocolReady = (async () => {
      const {data,error} = await db!.rpc('spectrum_protocol')
      if (error || data?.version !== 6 || data?.authRequired !== true || data?.preparationVersion !== 1) {
        protocolReady = null
        throw new GameApiError('UPDATE_REQUIRED','現在更新中です。少し待ってから試してください。')
      }
    })()
    await protocolReady
    const {data: existing, error: sessionError} = await db!.auth.getSession()
    if (sessionError) throw new GameApiError('AUTH_FAILED','本人を確認できません。画面を再読み込みしてください。')
    if (existing.session?.user.id) return existing.session.user.id
    const {data,error} = await db!.auth.signInAnonymously()
    if (error || !data.user) throw new GameApiError('AUTH_FAILED','今は参加できません。少し待ってから試してください。')
    return data.user.id
  })().finally(() => { identityRequest = null })
  return identityRequest
}

export async function checkedRpc(name: string, args: Record<string, unknown>): Promise<unknown> {
  if (!db) throw new GameApiError('UNAVAILABLE','今は遊べません。時間をおいて試してください。')
  const {data,error} = await db.rpc(name,args)
  if (error) throw new GameApiError(error.code === '42501' ? 'IDENTITY_MISMATCH' : 'RPC_FAILED',
    error.code === '42501' ? '本人を確認できません。画面を再読み込みしてください。' : 'うまくいきませんでした。もう一度試してください。')
  if (data?.error) throw new GameApiError(data.error.code, data.error.message)
  if (data?.state && data.state.securityVersion !== 6) throw new GameApiError('UPDATE_REQUIRED','現在更新中です。少し待ってから試してください。')
  return data
}

export const errorMessage = (error: unknown, fallback: string) => error instanceof GameApiError ? error.message : fallback

// Uniform 40-bit room codes from the browser CSPRNG. No look-alike I/O/0/1.
export function makeRoomCode(): string {
  const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'
  return Array.from(crypto.getRandomValues(new Uint8Array(8)), byte => alphabet[byte % 32]).join('')
}
