import { randomPrompt } from './prompts'
import { useCallback, useEffect, useState } from 'react'
import { createClient, SupabaseClient } from '@supabase/supabase-js'
import { ArrowRight, Copy, Radio, Users } from 'lucide-react'

type Prompt = { left: string; right: string }
type Phase = 'lobby' | 'clue' | 'guess' | 'reveal' | 'finished'
type Player = { id: string; name: string; score: number }
type RoundResult = { playerId: string; guess: number; distance: number; points: number }
type PublicGame = {
  room: string
  hostId: string
  players: Player[]
  round: number
  cluePlayerId: string
  prompt: Prompt
  promptHistory?: { left: string; right: string }[]
  clue: string
  phase: Phase
  answeredPlayerIds: string[]
  hintPoints?: number
  lastRoundResults: RoundResult[]
  targetRevealed: number | null
  updatedAt: string
}
type RpcResult = { state: PublicGame; target: number | null; ownGuess: number | null }
const url = import.meta.env.VITE_SUPABASE_URL as string | undefined
const key = (import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY || import.meta.env.VITE_SUPABASE_ANON_KEY) as string | undefined
const db: SupabaseClient | null = url && key ? createClient(url, key) : null
const makeCode = () => Math.random().toString(36).slice(2, 6).toUpperCase()
const makeId = () => crypto.randomUUID()
const SESSION_KEY = 'donohen-session-v1'
type SavedSession = { room: string; playerId: string; name: string }
const saveSession = (data: SavedSession) => localStorage.setItem(SESSION_KEY, JSON.stringify(data))
const clearSession = () => localStorage.removeItem(SESSION_KEY)

export default function App() {
  const [name, setName] = useState('')
  const [joinCode, setJoinCode] = useState('')
  const [playerId, setPlayerId] = useState('')
  const [game, setGame] = useState<PublicGame | null>(null)
  const [target, setTarget] = useState<number | null>(null)
  const [clueDraft, setClueDraft] = useState('')
  const [status, setStatus] = useState('')
  const [busy, setBusy] = useState(false)
  const [restoring, setRestoring] = useState(true)
  const [guessValue, setGuessValue] = useState(50)
  const [ownGuess, setOwnGuess] = useState<number | null>(null)
  const [connectionLost, setConnectionLost] = useState(false)
  const [copied, setCopied] = useState(false)
  const clueGiver = game?.cluePlayerId === playerId
  const allReady = (game?.players.length ?? 0) >= 2
  const guessers = game?.players.filter(p => p.id !== game.cluePlayerId) ?? []
  const answered = game?.answeredPlayerIds ?? []
  const hasAnswered = answered.includes(playerId)


  const applyRpc = useCallback((data: unknown) => {
    const result = data as RpcResult
    if (result?.state) {
      setGame(result.state)
      setTarget(typeof result.target === 'number' ? result.target : null)
      setOwnGuess(typeof result.ownGuess === 'number' ? result.ownGuess : null)
    }
  }, [])

  const rpc = useCallback(async (name: string, args: Record<string, unknown>) => {
    if (!db) throw new Error('今は遊べません。時間をおいて試してください。')
    const { data, error } = await db.rpc(name, args)
    if (error) throw error
    return data as RpcResult
  }, [])

  // Restore the SAME player ID: answers, points, and host privileges survive a reload.
  useEffect(() => {
    let active = true
    const restore = async () => {
      const saved = localStorage.getItem(SESSION_KEY)
      if (!saved || !db) { if (active) setRestoring(false); return }
      try {
        const session = JSON.parse(saved) as SavedSession
        if (!session.room || !session.playerId || !session.name) throw new Error('Invalid session')
        const result = await rpc('spectrum_get_room', { p_room_code: session.room, p_player_id: session.playerId })
        if (!active) return
        setName(session.name); setPlayerId(session.playerId); applyRpc(result)
        setConnectionLost(false); setStatus('')
      } catch {
        if (active) { clearSession(); setStatus('前の部屋に戻れませんでした。もう一度参加してください。') }
      } finally { if (active) setRestoring(false) }
    }
    void restore()
    return () => { active = false }
  }, [rpc, applyRpc])

  useEffect(() => {
    if (!game || !playerId || !db) return
    let alive = true
    const tick = async () => {
      if (!alive) return
      try {
        const result = await rpc('spectrum_get_room', { p_room_code: game.room, p_player_id: playerId })
        if (alive) {
          applyRpc(result)
          setConnectionLost(false)
        }
      } catch {
        if (alive) setConnectionLost(true)
      }
    }
    void tick()
    const timer = window.setInterval(() => void tick(), 1500)
    return () => { alive = false; window.clearInterval(timer) }
  }, [game?.room, playerId, rpc, applyRpc])

  const createRoom = async () => {
    if (!db) { setStatus('今は遊べません。時間をおいて試してください。'); return }
    const n = name.trim()
    if (!n) { setStatus('ニックネームを入力してください'); return }
    const id = makeId()
    setBusy(true)
    try {
      let result: RpcResult | null = null
      let lastError: unknown
      for (let attempt = 0; attempt < 4; attempt++) {
        try {
          result = await rpc('spectrum_create_room', {
            p_room_code: makeCode(), p_player_id: id, p_player_name: n,
            p_prompt: randomPrompt(), p_target: Math.floor(15 + Math.random() * 71)
          })
          break
        } catch (e) { lastError = e }
      }
      if (!result) throw lastError
      saveSession({room: result.state.room, playerId:id, name:n}); setPlayerId(id); setName(n); applyRpc(result); setStatus('')
    } catch (e) {
      setStatus('部屋を作れませんでした。もう一度試してください。')
    } finally { setBusy(false) }
  }

  const joinRoom = async () => {
    if (!db) { setStatus('今は遊べません。時間をおいて試してください。'); return }
    const room = joinCode.trim().toUpperCase()
    const n = name.trim()
    if (!n) { setStatus('ニックネームを入力してください'); return }
    if (!room) { setStatus('ルームコードを入力してください'); return }
    const id = makeId()
    setBusy(true)
    try {
      const result = await rpc('spectrum_join_room', { p_room_code: room, p_player_id: id, p_player_name: n })
      saveSession({room: result.state.room, playerId:id, name:n}); setPlayerId(id); setName(n); applyRpc(result); setStatus('')
    } catch (e) {
      setStatus('参加できませんでした。コードと、ゲームが始まっていないかを確認してください。')
    } finally { setBusy(false) }
  }

  const act = async (action: string, payload: Record<string, unknown> = {}) => {
    if (!game || !playerId) return
    setBusy(true)
    try {
      const result = await rpc('spectrum_game_action', {
        p_room_code: game.room, p_player_id: playerId, p_action: action, p_payload: payload
      })
      applyRpc(result); setStatus('')
    } catch (e) {
      setStatus('うまくいきませんでした。もう一度試してください。')
    } finally { setBusy(false) }
  }

  const sendClue = () => {
    if (!clueDraft.trim()) { setStatus('ヒントを入力してください'); return }
    if (!clueGiver) { setStatus('このラウンドのヒント役ではありません'); return }
    void act('clue', { clue: clueDraft.trim() }); setClueDraft('')
  }
  const submitGuess = () => {
    if (!game || clueGiver || hasAnswered) return
    void act('guess', { guess: guessValue })
  }
  const reveal = () => void act('reveal')
  const nextRound = () => void act('next_round', { prompt: randomPrompt(game?.promptHistory ?? (game ? [game.prompt] : [])) })
  const restart = () => void act('restart', { prompt: randomPrompt() })
  const startGame = () => void act('start', { prompt: randomPrompt() })
  useEffect(() => {
    setGuessValue(50)
  }, [game?.room, game?.round])
  useEffect(() => {
    if (!copied) return
    const timer = window.setTimeout(() => setCopied(false), 1800)
    return () => window.clearTimeout(timer)
  }, [copied])
  const standings = game ? [...game.players].sort((a,b) => b.score-a.score || a.name.localeCompare(b.name,'ja')) : []
  const rankFor = (index: number) => index > 0 && standings[index].score === standings[index-1].score ? standings.findIndex(p=>p.score===standings[index].score)+1 : index+1
  const copy = async () => {
    if (!game) return
    try { await navigator.clipboard.writeText(game.room); setCopied(true) }
    catch { setStatus(`ルームコード：${game.room}`) }
  }
  const leave = async () => {
    if (!game || !playerId || busy) return
    if (!window.confirm('退出しますか？ この参加者としては戻れません。')) return
    setBusy(true)
    try {
      await rpc('spectrum_leave_room', { p_room_code: game.room, p_player_id: playerId })
      clearSession(); setGame(null); setPlayerId(''); setTarget(null); setOwnGuess(null)
      setStatus(''); setConnectionLost(false)
    } catch (e) {
      setStatus('退出できませんでした。もう一度試してください。')
    } finally { setBusy(false) }
  }

  return <main className="shell">
    <header className="top"><a className="brand" aria-label="ドノヘン？"><span className="brandicon"><Radio size={20}/></span><span className="brandname"><span>ド</span><span>ノ</span><span>ヘ</span><span>ン</span><span>？</span></span></a></header>
    {game&&connectionLost&&<p className="connection-error" role="status">接続が途切れました。画面はそのままでお待ちください。</p>}
    {restoring ? <section className="restore-placeholder" aria-busy="true"><span className="sr-only" role="status">読み込み中</span><div className="skeleton"/><div className="skeleton"/></section> : !game ? <section className="landing">
      <div className="hero">
        <div className="hero-logo" aria-label="ドノヘン？"><span>ド</span><span>ノ</span><span>ヘ</span><span>ン</span><span>？</span></div>
        <h1 className="tagline">ことばでつたえる、<br/><em>みんなのものさし。</em></h1>
        <p>ヒントを頼りに、0〜100の「どのへん？」を当てよう。</p>
        <div className="spectrum" aria-hidden="true"><div/><i/></div>
      </div>
      <div className="panel">
        <h2>はじめる</h2>
        <label htmlFor="player-name">ニックネーム</label><input id="player-name" value={name} onChange={e=>setName(e.target.value)} maxLength={18} placeholder="例：ことり" autoComplete="nickname"/>
        <button className="primary full" disabled={busy||!name.trim()} onClick={createRoom}>部屋を作る <ArrowRight size={17}/></button>
        <div className="or">または</div>
        <label htmlFor="room-code">ルームコード</label>
        <div className="joinrow"><input id="room-code" value={joinCode} onChange={e=>setJoinCode(e.target.value.toUpperCase())} maxLength={8} placeholder="ABCD"/><button className="secondary" disabled={busy||!name.trim()||!joinCode.trim()} onClick={joinRoom}>参加する</button></div>
        {status&&<p className="status" role="alert">{status}</p>}
        <details className="help"><summary>遊び方</summary><p>ヒント役だけが正解の数字を見て、言葉でヒントを出します。ほかの人は0〜100で予想。正解に近いほど高得点！ 全5ラウンドの合計で競います。</p></details>
      </div>
    </section> : game.phase==='lobby' ? <section className="game">
      <div className="gamehead"><h1>待機室</h1><div className="score"><Users size={18}/>{game.players.length} / 12 人</div></div>
      <div className="panel gamepanel">
        <div className="invite"><span>ルームコード</span><div><b>{game.room}</b><button className="textbtn" onClick={copy}><Copy size={15}/>{copied ? 'コピーしました' : 'コピー'}</button></div><p>コードを友達に送って招待しよう。</p></div>
        <h2 className="member-heading">メンバー</h2>
        {game.players.map(p=><div className="scoreline" key={p.id}><span>{p.name}{p.id===playerId?'（あなた）':''}</span>{p.id===game.hostId&&<b>ホスト</b>}</div>)}
        {game.hostId===playerId?<><button className="primary full" disabled={busy||!allReady} onClick={startGame}>ゲームを始める <ArrowRight size={17}/></button><p className="quiet">{allReady?'全5ラウンド':'あと1人で始められます'}</p></>:<p className="quiet">ホストが始めるのを待とう。</p>}
        {status&&<p className="status" role="alert">{status}</p>}
      </div>
      <button className="back" disabled={busy} onClick={() => void leave()}>退出する</button>
    </section> : <section className="game">
      <div className="gamehead"><div><div className="eyebrow">ルーム {game.room}</div><h1>{game.phase==='finished'?'結果発表':<>ラウンド <em>{game.round} / 5</em></>}</h1></div><button className="textbtn" onClick={copy}><Copy size={15}/>{copied ? 'コピーしました' : 'コードをコピー'}</button></div>
      {game.phase!=='finished'&&<><div className="players-strip">{game.players.map(p=><span className={`chip ${p.id===game.cluePlayerId?'active':''}`} key={p.id}>{p.name}{p.id===game.cluePlayerId?' · ヒント役':''}<b>{p.score}点</b></span>)}</div>
      <div className="prompt"><div className="poles"><span><small>0</small>{game.prompt.left}</span><b aria-hidden="true">↔</b><span><small>100</small>{game.prompt.right}</span></div></div></>}
      <div className="panel gamepanel">
        {game.phase==='clue'&&<>
          <h2>{clueGiver?'どんなヒントにする？':`${game.players.find(p=>p.id===game.cluePlayerId)?.name ?? 'ヒント役'}のヒントを待とう`}</h2>
          {clueGiver&&<>
            <div className="secret"><span>あなただけの正解</span><strong>{target===null?'—':target}<small> / 100</small></strong><div className="track">{target!==null&&<i style={{left:`${target}%`}}/>}</div></div>
            <label htmlFor="clue-input">ヒント</label><div className="joinrow"><input id="clue-input" value={clueDraft} onChange={e=>setClueDraft(e.target.value)} placeholder="例：真夏のアスファルト" maxLength={100}/><button className="primary" disabled={busy||target===null||!clueDraft.trim()} onClick={sendClue}>伝える</button></div>
          </>}
        </>}
        {game.phase==='guess'&&<>
          <h2 className="clue-text">「{game.clue}」</h2>
          <div className="progressinfo"><span>回答</span><strong>{answered.length} / {guessers.length} 人</strong></div>
          <div className="progressbar" role="progressbar" aria-label="回答済み人数" aria-valuenow={answered.length} aria-valuemin={0} aria-valuemax={guessers.length}><i style={{width:`${guessers.length?answered.length/guessers.length*100:0}%`}}/></div>
          <div className="answerchips">{guessers.map(p=><span key={p.id} className={`answerchip ${answered.includes(p.id)?'done':''}`}><span aria-label={answered.includes(p.id)?'回答済み':'未回答'}>{answered.includes(p.id)?'✓':'○'}</span> {p.name}</span>)}</div>
          {clueGiver ? <div className="waiting"><h3>みんなはどのへんを選ぶかな？</h3></div>
          : hasAnswered ? <div className="waiting"><h3>あなたの予想</h3><div className="submitted-guess">{ownGuess ?? '—'}<small> / 100</small></div></div>
          : <>
            <div className="guessnum">{guessValue}<small> / 100</small></div>
            <input aria-label="あなたの予想位置をスライダーで設定" className="range" type="range" min="0" max="100" step="1" value={guessValue} onChange={e=>setGuessValue(Number(e.target.value))}/>
            <div className="rangeends"><span>0 · {game.prompt.left}</span><span>100 · {game.prompt.right}</span></div>
            <label htmlFor="guess-direct">予想の数字</label>
            <input id="guess-direct" aria-label="0から100までの予想数値" type="number" min="0" max="100" step="1" value={guessValue} onChange={e=>{const value=Number(e.target.value);if(Number.isInteger(value))setGuessValue(Math.min(100,Math.max(0,value)))}}/>
            <button className="primary full" disabled={busy} onClick={submitGuess}>この位置に決める <ArrowRight size={17}/></button>
            <p className="quiet">決めたあとは変更できません</p>
          </>}
        </>}
        {game.phase==='reveal'&&<>
          <h2>{game.targetRevealed===null?'みんなの予想がそろった！':'答え合わせ'}</h2>
          {game.clue&&<p className="result-clue">「{game.clue}」</p>}
          {game.targetRevealed===null&&game.hostId!==playerId&&<p>ホストの発表を待とう。</p>}
          {game.targetRevealed!==null&&<>
            <div className="resulttrack"><div/><i className="targetpin" style={{left:`${game.targetRevealed}%`}}/></div>
            <div className="resultrow"><span>正解 <b>{game.targetRevealed}</b></span></div>
            {(game.lastRoundResults ?? []).map(r => <div className={`scoreline ${r.playerId===playerId?'myanswer':''}`} key={r.playerId}><span>{game.players.find(p=>p.id===r.playerId)?.name ?? 'プレイヤー'}{r.playerId===playerId?'（あなた）':''}<small>予想 {r.guess} · 差 {r.distance}</small></span><b>+{r.points} 点</b></div>)}
            <div className="scoreline hint-score"><span>{game.players.find(p=>p.id===game.cluePlayerId)?.name}<small>ヒント役</small></span><b>+{game.hintPoints ?? 0} 点</b></div>
            <><h3>合計</h3>{standings.map(p=><div className="scoreline" key={p.id}><span>{p.name}{p.id===playerId?'（あなた）':''}</span><b>{p.score} 点</b></div>)}</>
            <details className="help"><summary>得点のつけ方</summary><p>ぴったりなら5点。差が3以内で4点、7以内で3点、12以内で2点、20以内で1点。ヒント役はみんなの平均点（四捨五入）をもらえます。</p></details>
          </>}
          {game.targetRevealed===null&&game.hostId===playerId&&<button className="primary full" disabled={busy} onClick={reveal}>答えを見る</button>}
          {game.targetRevealed!==null&&game.round<5&&game.hostId===playerId&&<button className="primary full" disabled={busy} onClick={nextRound}>次のラウンド <ArrowRight size={17}/></button>}
        </>}
        {game.phase==='finished'&&<div className="final-results"><h2>ランキング</h2><div className="standings">{standings.map((p,i)=><div className="scoreline" key={p.id}><span><b>{rankFor(i)}位</b>　{p.name}{p.id===playerId?'（あなた）':''}</span><b>{p.score} 点</b></div>)}</div>{game.hostId===playerId?<button className="primary full" disabled={busy} onClick={restart}>もう一度遊ぶ</button>:<p className="quiet">ホストが次のゲームを始めるのを待とう。</p>}<details className="help"><summary>最終ラウンドの答え合わせ</summary><p>0 · {game.prompt.left} ↔ 100 · {game.prompt.right}</p><p>「{game.clue}」 · 正解 {game.targetRevealed}</p>{(game.lastRoundResults ?? []).map(r=><div className="scoreline" key={r.playerId}><span>{game.players.find(p=>p.id===r.playerId)?.name ?? 'プレイヤー'}<small>予想 {r.guess} · 差 {r.distance}</small></span><b>+{r.points} 点</b></div>)}<div className="scoreline"><span>{game.players.find(p=>p.id===game.cluePlayerId)?.name}<small>ヒント役</small></span><b>+{game.hintPoints ?? 0} 点</b></div></details></div>}
        {status&&<p className="status" role="alert">{status}</p>}
      </div>
      <button className="back" disabled={busy} onClick={() => void leave()}>退出する</button>
    </section>}
  </main>
}





