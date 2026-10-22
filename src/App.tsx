import { randomPrompt } from './prompts'
import { useCallback, useEffect, useState } from 'react'
import { createClient, SupabaseClient } from '@supabase/supabase-js'
import { ArrowRight, Copy, Radio, RotateCcw, Sparkles, Trophy, Users } from 'lucide-react'

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
  const [connection, setConnection] = useState<'connecting' | 'connected' | 'offline'>('offline')
  const online = Boolean(db)
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
    if (!db) throw new Error('Supabaseが未設定です。.env.localを設定してください。')
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
        setConnection('connected'); setStatus('前回のルームに復帰しました。')
      } catch {
        if (active) { clearSession(); setStatus('以前のルームには復帰できませんでした。新しく参加してください。') }
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
          setConnection('connected')
        }
      } catch {
        if (alive) setConnection('offline')
      }
    }
    void tick()
    const timer = window.setInterval(() => void tick(), 1500)
    return () => { alive = false; window.clearInterval(timer) }
  }, [game?.room, playerId, rpc, applyRpc])

  const createRoom = async () => {
    if (!db) { setStatus('オンライン設定がまだです。.env.local と Supabase のSQL設定を完了してください。'); return }
    const n = name.trim()
    if (!n) { setStatus('ニックネームを入力してください'); return }
    const id = makeId()
    setBusy(true)
    setConnection('connecting')
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
      saveSession({room: result.state.room, playerId:id, name:n}); setPlayerId(id); setName(n); applyRpc(result); setStatus('ルームを作成しました。招待コードを友達に送ってね！')
    } catch (e) {
      setConnection('offline')
      setStatus(e instanceof Error ? e.message : '作成に失敗しました。Supabase設定を確認してください。')
    } finally { setBusy(false) }
  }

  const joinRoom = async () => {
    if (!db) { setStatus('オンライン設定がまだです。.env.local と Supabase のSQL設定を完了してください。'); return }
    const room = joinCode.trim().toUpperCase()
    const n = name.trim()
    if (!n) { setStatus('ニックネームを入力してください'); return }
    if (!room) { setStatus('ルームコードを入力してください'); return }
    const id = makeId()
    setBusy(true); setConnection('connecting')
    try {
      const result = await rpc('spectrum_join_room', { p_room_code: room, p_player_id: id, p_player_name: n })
      saveSession({room: result.state.room, playerId:id, name:n}); setPlayerId(id); setName(n); applyRpc(result); setStatus('参加しました！ヒント役のターンを待ってね。')
    } catch (e) {
      setConnection('offline')
      setStatus(e instanceof Error ? e.message : '参加に失敗しました。コードを確認してください。')
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
      setStatus(e instanceof Error ? e.message : '操作に失敗しました。少し待って再試行してください。')
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
  const standings = game ? [...game.players].sort((a,b) => b.score-a.score || a.name.localeCompare(b.name,'ja')) : []
  const rankFor = (index: number) => index > 0 && standings[index].score === standings[index-1].score ? standings.findIndex(p=>p.score===standings[index].score)+1 : index+1
  const copy = async () => {
    if (!game) return
    try { await navigator.clipboard.writeText(game.room); setStatus('ルームコードをコピーしました') }
    catch { setStatus(`ルームコード：${game.room}`) }
  }
  const leave = async () => {
    if (!game || !playerId || busy) return
    if (!window.confirm('ルームから退出しますか？ 退出するとこの参加枠には復帰できません。')) return
    setBusy(true)
    try {
      await rpc('spectrum_leave_room', { p_room_code: game.room, p_player_id: playerId })
      clearSession(); setGame(null); setPlayerId(''); setTarget(null); setOwnGuess(null)
      setStatus('ルームから退出しました。'); setConnection('offline')
    } catch (e) {
      setStatus(e instanceof Error ? e.message : '退出に失敗しました。もう一度試してください。')
    } finally { setBusy(false) }
  }

  return <main className="shell">
    <header className="top"><a className="brand"><span className="brandicon"><Radio size={20}/></span><span className="brandname"><span>ド</span><span>ノ</span><span>ヘ</span><span>ン</span><span>？</span></span></a><span className={`badge ${connection==='connected'?'on':''}`}><i/>{online ? (connection==='connected'?'ONLINE · 接続中':connection==='connecting'?'CONNECTING':'接続待ち') : '未設定'}</span></header>
    {restoring ? <section className="landing"><div className="panel"><h2>前回のルームを確認中…</h2><p>再読み込み後も元のプレイヤーとして復帰します。</p></div></section> : !game ? <section className="landing">
      <div className="hero"><div className="eyebrow"><Sparkles size={15}/> DONOHEN? · ONLINE PARTY GAME</div><div className="hero-logo" aria-label="ドノヘン？"><span>ド</span><span>ノ</span><span>ヘ</span><span>ン</span><span>？</span></div><h1 className="tagline">ことばでつたえる、<br/><em>みんなのものさし。</em></h1><p>ヒントから0〜100の位置を予想するオンラインパーティーゲーム！ 名前と部屋を選んで遊ぼう。</p><div className="spectrum"><div/><i/><small><span>0 · こっち</span><span>100 · あっち</span></small></div></div>
      <div className="panel"><div className="iconbox"><Users/></div><div className="phase">STEP 01 · JOIN A ROOM</div><h2>ゲームに参加する</h2><p>ニックネームを入力して、部屋を作るかコードで参加してね。</p><label htmlFor="player-name">ニックネーム</label><input id="player-name" value={name} onChange={e=>setName(e.target.value)} maxLength={18} placeholder="例：ことり" autoComplete="nickname"/><button className="primary full" disabled={busy||!name.trim()} onClick={createRoom}>部屋を作る <ArrowRight size={17}/></button><div className="or">または、友達の部屋に入る</div><label htmlFor="room-code">ルームコード</label><div className="joinrow"><input id="room-code" value={joinCode} onChange={e=>setJoinCode(e.target.value.toUpperCase())} maxLength={8} placeholder="ABCD"/><button className="secondary" disabled={busy||!name.trim()||!joinCode.trim()} onClick={joinRoom}>コードで参加</button></div>{status&&<p className="status" role="alert">{status}</p>}</div>
    </section> : game.phase==='lobby' ? <section className="game">
      <div className="gamehead"><div><div className="eyebrow">ROOM LOBBY</div><h1>ルーム <em>{game.room}</em></h1></div><div className="score"><Users size={18}/>{game.players.length} / 12 人</div></div>
      <div className="panel gamepanel"><div className="phase">LOBBY · GAME START</div><h2>参加者が集まるまで待とう！</h2><p>ルームコードを友達に送って参加してもらおう。ホストが開始すると全員の画面がゲームに切り替わるよ。</p><div className="roombar"><b>ルームコード：{game.room}</b><button className="textbtn" onClick={copy}><Copy size={15}/>コピー</button></div><h3>参加プレイヤー</h3>{game.players.map(p=><div className="scoreline" key={p.id}><span>{p.name}{p.id===playerId?'（あなた）':''}</span><b>{p.id===game.hostId?'ホスト':'参加中'}</b></div>)}{game.hostId===playerId?<button className="primary full" disabled={busy||!allReady} onClick={startGame}>5ラウンドのゲームを開始 <ArrowRight size={17}/></button>:<p>ホストがゲームを開始するのを待っています。</p>}{!allReady&&<p className="notice">ゲーム開始には2人以上必要です。</p>}{status&&<p className="status">{status}</p>}</div>
      <button className="back" disabled={busy} onClick={() => void leave()}>ルームから退出する</button>
    </section> : <section className="game">
      <div className="gamehead"><div><div className="eyebrow">ROOM / {game.room}</div><h1>ラウンド <em>{game.round} / 5</em></h1></div><div className="score"><Trophy size={18}/>{game.players.reduce((s,p)=>s+p.score,0)} 点</div></div>
      <div className="roombar"><span><Users size={16}/>{game.players.length}人</span><div className="chips">{game.players.map(p=><span className={`chip ${p.id===game.cluePlayerId?'active':''}`} key={p.id}>{p.name}{p.id===game.cluePlayerId?' · ヒント役':''} {p.id===playerId?' (あなた)':''} · {p.score}点</span>)}</div><button className="textbtn" onClick={copy}><Copy size={15}/>招待</button></div>
      <div className="prompt"><div className="eyebrow">0 — 100 · どのへん？</div><div className="poles"><span>{game.prompt.left}</span><b>↔</b><span>{game.prompt.right}</span></div></div>
      <div className="panel gamepanel">
        {game.phase==='clue'&&<><div className="phase">PHASE 01 · HINT</div><h2>{clueGiver?'ターゲットの位置をヒントにしよう':'ヒント役の言葉を待とう'}</h2>{clueGiver?<><p>ターゲット位置はヒント役のあなたにだけ、サーバーから送られます。</p><div className="secret"><b>あなたのターゲット位置：{target===null?'取得中…':target}</b><div className="track"><i style={{left:`${target??50}%`}}/></div></div><label>みんなへのヒント</label><div className="joinrow"><input value={clueDraft} onChange={e=>setClueDraft(e.target.value)} placeholder="例：真夏の昼のアスファルト" maxLength={100}/><button className="primary" disabled={busy} onClick={sendClue}>決定</button></div></>:<p>ヒント役：<b>{game.players.find(p=>p.id===game.cluePlayerId)?.name}</b><br/>ヒントが出たら、みんなで位置を相談しよう。</p>}</>}
        {game.phase==='guess'&&<>
          <div className="phase">PHASE 02 · PERSONAL GUESS</div>
          <h2>ヒント：「{game.clue}」</h2>
          <div className="progressinfo"><span>回答状況</span><strong>{answered.length} / {guessers.length} 人</strong></div>
          <div className="progressbar" role="progressbar" aria-label="回答済み人数" aria-valuenow={answered.length} aria-valuemin={0} aria-valuemax={guessers.length}><i style={{width:`${guessers.length?answered.length/guessers.length*100:0}%`}}/></div>
          <div className="answerchips">{guessers.map(p=><span key={p.id} className={`answerchip ${answered.includes(p.id)?'done':''}`}>{answered.includes(p.id)?'✓':'○'} {p.name}{p.id===playerId?'（あなた）':''}</span>)}</div>
          {clueGiver ? <div className="waiting"><h3>みんなの回答を待っています</h3><p>ヒント役は正解を知っているため、このラウンドでは予想しません。回答が全員そろうと、結果発表へ進みます。</p></div>
          : hasAnswered ? <div className="waiting"><h3>回答完了！</h3><p>あなたの予想：<strong>{ownGuess ?? '送信済み'} / 100</strong></p><p>全員の回答がそろうまで待ってね。他の人の数字は結果発表まで公開されません。</p></div>
          : <>
            <p>0〜100の間で、あなた自身の予想位置を選んでね。回答は1人1回、確定後は変更できません。</p>
            <div className="guessnum">{guessValue}<small> / 100</small></div>
            <input aria-label="あなたの予想位置をスライダーで設定" className="range" type="range" min="0" max="100" step="1" value={guessValue} onChange={e=>setGuessValue(Number(e.target.value))}/>
            <div className="rangeends"><span>0 · {game.prompt.left}</span><span>100 · {game.prompt.right}</span></div>
            <label htmlFor="guess-direct">数字でも指定できます</label>
            <input id="guess-direct" aria-label="0から100までの予想数値" type="number" min="0" max="100" step="1" value={guessValue} onChange={e=>{const value=Number(e.target.value);if(Number.isInteger(value))setGuessValue(Math.min(100,Math.max(0,value)))}}/>
            <button className="primary full" disabled={busy} onClick={submitGuess}>この位置で回答を確定 <ArrowRight size={17}/></button>
          </>}
        </>}
        {game.phase==='reveal'&&<>
          <div className="phase">PHASE 03 · RESULTS</div>
          <h2>{game.targetRevealed===null?'全員の回答がそろいました！':'答え合わせ！'}</h2>
          <p>{game.targetRevealed===null?'ホストの結果発表を待っています。':'参加者それぞれの予想と獲得ポイントを確認しよう。'}</p>
          {game.targetRevealed!==null&&<>
            <div className="resulttrack"><div/><i className="targetpin" style={{left:`${game.targetRevealed}%`}}/></div>
            <div className="resultrow"><span>正解位置 <b>{game.targetRevealed}</b></span><span>回答人数 <b>{game.lastRoundResults?.length ?? 0} 人</b></span></div>
            <h3>このラウンドの回答結果</h3>
            {(game.lastRoundResults ?? []).map(r => <div className={`scoreline ${r.playerId===playerId?'myanswer':''}`} key={r.playerId}><span>{game.players.find(p=>p.id===r.playerId)?.name ?? 'プレイヤー'}{r.playerId===playerId?'（あなた）':''}<small>予想：{r.guess} ／ 誤差：{r.distance}</small></span><b>+{r.points} 点</b></div>)}
            <p className="notice">ヒント役：{game.players.find(p=>p.id===game.cluePlayerId)?.name}（予想者の平均得点を四捨五入：+{game.hintPoints ?? 0}点）</p>
            <h3>合計得点</h3>{[...game.players].sort((a,b)=>b.score-a.score).map(p=><div className="scoreline" key={p.id}><span>{p.name}{p.id===playerId?'（あなた）':''}</span><b>{p.score} 点</b></div>)}
          </>}
          {game.targetRevealed===null&&game.hostId===playerId&&<button className="primary full" disabled={busy} onClick={reveal}>答えを公開して全員を採点</button>}
          {game.targetRevealed!==null&&game.round<5&&game.hostId===playerId&&<button className="primary full" disabled={busy} onClick={nextRound}>次のラウンド <ArrowRight size={17}/></button>}
        </>}
        {status&&<p className="status">{status}</p>}
        {game.phase==='finished'&&<><div className="phase">DONOHEN? · FINISH 5 / 5</div><h2>最終結果・ランキング</h2><p>全5戦が終了！合計得点の高い順に順位を表示しています。同点は同順位です。</p><div className="standings">{standings.map((p,i)=><div className="scoreline" key={p.id}><span><b>{rankFor(i)}位</b>　{p.name}{p.id===playerId?'（あなた）':''}</span><b>{p.score} 点</b></div>)}</div>{game.hostId===playerId?<button className="primary full" disabled={busy} onClick={restart}>同じメンバーでもう一度（5戦）</button>:<p>ホストが「もう一度」を押すと新しいゲームが始まります。</p>}</>}
      </div>
      <button className="back" disabled={busy} onClick={() => void leave()}><RotateCcw size={15}/> ルームから退出する</button>
      {!allReady&&<p className="notice">参加者が1人になりました。待機部屋に戻るので、友達を招待してね。</p>}
    </section>}
    <footer><b>ドノヘン？</b><span>ことばでつたえる、みんなのものさし。</span></footer>
  </main>
}

