import { randomPrompt } from './prompts'
import ScoreReveal from './ScoreReveal'
import MatchReview, { type RoundReview } from './MatchReview'
import ShareResult from './ShareResult'
import SoundControls from './SoundControls'
import {isNewClue,playClueSound,type HintMoment} from './sound'
import { bestHintFor, publicGameUrl } from './shareImage'
import { compatibilityAwards,differenceLabel, invitationCode, invitationUrl, matchAwards, type MatchStat } from './extras'
import { useCallback, useEffect, useRef, useState } from 'react'
import { checkedRpc, db, ensureIdentity, errorMessage, GameApiError, makeRoomCode } from './session'
import { ArrowRight, Copy, Users } from 'lucide-react'

type Prompt = { left: string; right: string }
type Phase = 'lobby' | 'clue' | 'guess' | 'reveal' | 'finished'
type Player = { id: string; name: string; score: number }
type RoundResult = { playerId: string; guess: number|null; distance: number|null; points: number; timedOut?:boolean }
type PublicGame = {
  room: string
  hostId: string
  players: Player[]
  resultPlayers?: Player[]
  round: number
  securityVersion?: number
  totalRounds?: number
  roundsPerPlayer?: number
  rulesVersion?: number
  featuresVersion?: number
  endFlowVersion?: number
  answerSeconds?: number
  answerDeadline?: number|null
  timedOutPlayerIds?: string[]
  awardsEnabled?: boolean
  matchStats?: Record<string,MatchStat>
  roundHistory?: RoundReview[]
  matchId?: string
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
type RpcResult = { state: PublicGame; target: number | null; ownGuess: number | null; serverNow?:number }
const SESSION_KEY = 'donohen-session-v2'
type SavedSession = { room: string; playerId: string; name: string }
const saveSession = (data: SavedSession) => { try { localStorage.setItem(SESSION_KEY, JSON.stringify(data)) } catch { /* Play without restoration when storage is blocked. */ } }
const clearSession = () => { try { localStorage.removeItem(SESSION_KEY); localStorage.removeItem('donohen-session-v1') } catch { /* Storage may be blocked. */ } }

export default function App() {
  const [name, setName] = useState('')
  const [joinCode, setJoinCode] = useState(()=>invitationCode(window.location?.search??''))
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
  const [linkCopied, setLinkCopied] = useState(false)
  const [clockOffset,setClockOffset] = useState(0)
  const [now,setNow] = useState(Date.now())
  const [completedReveal, setCompletedReveal] = useState('')
  const [resultTab,setResultTab] = useState<'ranking'|'review'>('ranking')
  const previousSoundMoment=useRef<HintMoment|null>(null),notifiedHints=useRef(new Set<string>())
  const totalRounds = game?.totalRounds ?? 5
  const roundsPerPlayer = game?.roundsPerPlayer ?? 1
  const configurable = (game?.rulesVersion ?? 0) >= 2
  const displayPhase=game?.phase
  const revealKey = `${game?.room}:${game?.matchId ?? ''}:${game?.round}:${displayPhase}:${game?.targetRevealed}`
  const revealComplete = completedReveal === revealKey
  const finishReveal = useCallback(() => setCompletedReveal(revealKey), [revealKey])
  const clueGiver = game?.cluePlayerId === playerId
  const allReady = (game?.players.length ?? 0) >= 2
  const guessers = game?.players.filter(p => p.id !== game.cluePlayerId) ?? []
  const answered = game?.answeredPlayerIds ?? []
  const hasAnswered = answered.includes(playerId)
  const remaining=game?.answerDeadline?Math.max(0,Math.ceil((game.answerDeadline-now-clockOffset)/1000)):null


  const applyRpc = useCallback((data: unknown) => {
    const result = data as RpcResult
    if (result?.state) {
      const next=result.state,key=`${next.room}:${next.matchId??''}:${next.round}:${next.cluePlayerId}:${next.clue}`
      if(isNewClue(previousSoundMoment.current,next)&&!notifiedHints.current.has(key)){
        notifiedHints.current.add(key);if(notifiedHints.current.size>100)notifiedHints.current.delete(notifiedHints.current.values().next().value!)
        playClueSound()
      }
      previousSoundMoment.current=next
      if(typeof result.serverNow==='number')setClockOffset(result.serverNow-Date.now())
      setNow(Date.now())
      setGame(result.state)
      setTarget(typeof result.target === 'number' ? result.target : null)
      setOwnGuess(typeof result.ownGuess === 'number' ? result.ownGuess : null)
    }
  }, [])

  const rpc = useCallback(async (name: string, args: Record<string, unknown>) => {
    return await checkedRpc(name,args) as RpcResult
  }, [])

  // Restore the SAME player ID: answers, points, and host privileges survive a reload.
  useEffect(() => {
    let active = true
    const restore = async () => {
      try {
        const saved = localStorage.getItem(SESSION_KEY)
        if (!saved || !db) return
        const session = JSON.parse(saved) as SavedSession
        const invited=invitationCode(window.location?.search??'')
        if(invited&&invited!==session.room)return
        if (!session.room || !session.playerId || !session.name) throw new Error('Invalid session')
        const identity = await ensureIdentity()
        if (identity !== session.playerId) throw new GameApiError('IDENTITY_MISMATCH','前の部屋には戻れません。参加し直してください。')
        const result = await rpc('spectrum_get_room', { p_room_code: session.room, p_player_id: session.playerId })
        if (!active) return
        setName(session.name); setPlayerId(session.playerId); applyRpc(result)
        setConnectionLost(false); setStatus('')
      } catch (error) {
        if (active) {
          if (!(error instanceof GameApiError) || ['IDENTITY_MISMATCH','ROOM_UNAVAILABLE'].includes(error.code)) clearSession()
          setStatus(errorMessage(error,'前の部屋に戻れませんでした。もう一度参加してください。'))
        }
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
      } catch (error) {
        if (alive) {
          if (error instanceof GameApiError && ['ROOM_UNAVAILABLE','IDENTITY_MISMATCH'].includes(error.code)) {
            clearSession(); setGame(null); setPlayerId(''); setTarget(null); setOwnGuess(null)
            setStatus(error.message)
          } else setConnectionLost(true)
        }
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
    setBusy(true)
    try {
      const id = await ensureIdentity()
      let result: RpcResult | null = null
      let lastError: unknown
      for (let attempt = 0; attempt < 4; attempt++) {
        try {
          result = await rpc('spectrum_create_room', {
            p_room_code: makeRoomCode(), p_player_id: id, p_player_name: n,
            p_prompt: randomPrompt(), p_target: Math.floor(15 + Math.random() * 71)
          })
          break
        } catch (e) {
          if (!(e instanceof GameApiError) || e.code !== 'ROOM_CODE_COLLISION') throw e
          lastError = e
        }
      }
      if (!result) throw lastError
      saveSession({room: result.state.room, playerId:id, name:n}); setPlayerId(id); setName(n); applyRpc(result); setStatus('')
    } catch (e) {
      setStatus(errorMessage(e,'部屋を作れませんでした。もう一度試してください。'))
    } finally { setBusy(false) }
  }

  const joinRoom = async () => {
    if (!db) { setStatus('今は遊べません。時間をおいて試してください。'); return }
    const room = joinCode.normalize('NFKC').trim().toUpperCase()
    const n = name.trim()
    if (!n) { setStatus('ニックネームを入力してください'); return }
    if (!room) { setStatus('ルームコードを入力してください'); return }
    if (!/^[A-Z2-9]{8}$/.test(room)) { setStatus('8文字のルームコードを入力してください'); return }
    setBusy(true)
    try {
      const id = await ensureIdentity()
      const result = await rpc('spectrum_join_room', { p_room_code: room, p_player_id: id, p_player_name: n })
      saveSession({room: result.state.room, playerId:id, name:n}); setPlayerId(id); setName(n); applyRpc(result); setStatus('')
    } catch (e) {
      setStatus(errorMessage(e,'参加できませんでした。コードと、ゲームが始まっていないかを確認してください。'))
    } finally { setBusy(false) }
  }

  const act = async (action: string, payload: Record<string, unknown> = {}) => {
    if (!game || !playerId) return false
    setBusy(true)
    try {
      const result = await rpc('spectrum_game_action', {
        p_room_code: game.room, p_player_id: playerId, p_action: action, p_payload: payload
      })
      applyRpc(result); setStatus('')
      return true
    } catch (e) {
      setStatus(errorMessage(e,'うまくいきませんでした。もう一度試してください。'))
      return false
    } finally { setBusy(false) }
  }

  const sendClue = () => {
    if (!clueDraft.trim()) { setStatus('ヒントを入力してください'); return }
    if (!clueGiver) { setStatus('このラウンドのヒント役ではありません'); return }
    void act('clue', { clue: clueDraft.trim() }).then(success => { if (success) setClueDraft('') })
  }
  const submitGuess = () => {
    if (!game || clueGiver || hasAnswered) return
    void act('guess', { guess: guessValue })
  }
  const reveal = () => void act('reveal')
  const nextRound = () => void act('next_round', { prompt: randomPrompt(game?.promptHistory ?? (game ? [game.prompt] : [])) })
  const restart = () => void act('restart', { prompt: randomPrompt() })
  const openFinalResults=async()=>{
    if(!game||game.hostId!==playerId||game.phase!=='reveal'||!revealComplete)return
    await act('finish')
  }
  const startGame = () => void act('start', { prompt: randomPrompt() })
  const setRounds = (value: number) => void act('settings', { roundsPerPlayer: value })
  const setAnswerSeconds = (value:number) => void act('settings',{answerSeconds:value})
  useEffect(()=>{
    if(game?.phase!=='guess'||!game.answerDeadline)return
    const timer=window.setInterval(()=>setNow(Date.now()),250)
    return ()=>window.clearInterval(timer)
  },[game?.phase,game?.answerDeadline])
  useEffect(() => {
    setGuessValue(50)
  }, [game?.room, game?.round])
  useEffect(() => {
    if (game?.phase!=='reveal' && game?.phase!=='finished') setCompletedReveal('')
    if(game?.phase!=='finished')setResultTab('ranking')
  }, [game?.room, game?.phase])
  useEffect(() => {
    if (!copied&&!linkCopied) return
    const timer = window.setTimeout(() => {setCopied(false);setLinkCopied(false)}, 1800)
    return () => window.clearTimeout(timer)
  }, [copied,linkCopied])
  const resultPlayers=game?.resultPlayers??game?.players??[]
  const standings = [...resultPlayers].sort((a,b) => b.score-a.score || a.name.localeCompare(b.name,'ja'))
  const roundRecord=game?.roundHistory?.find(r=>r.round===game.round)
  const roundEntries = game ? (game.lastRoundResults ?? []).map(r => ({id:r.playerId, name:roundRecord?.results.find(p=>p.playerId===r.playerId)?.name ?? resultPlayers.find(p=>p.id===r.playerId)?.name ?? 'プレイヤー', score:r.points, guess:r.guess??undefined, detail:r.timedOut?'時間切れ · 未回答':differenceLabel(r.guess??undefined,game.targetRevealed??0)})) : []
  const awards=game?.awardsEnabled?matchAwards(resultPlayers,game.matchStats??{}):[]
  const reviewRounds:RoundReview[]=game?.roundHistory?.length?game.roundHistory:game?.phase==='finished'&&game.targetRevealed!==null?[{
    round:game.round,prompt:game.prompt,clue:game.clue,cluePlayerId:game.cluePlayerId,
    cluePlayerName:resultPlayers.find(p=>p.id===game.cluePlayerId)?.name??'ヒント役',target:game.targetRevealed,hintPoints:game.hintPoints??0,
    results:game.lastRoundResults.map(r=>({...r,name:resultPlayers.find(p=>p.id===r.playerId)?.name??'プレイヤー'}))
  }]:[]
  const connections=game?compatibilityAwards(resultPlayers,reviewRounds,playerId):[]
  const hintName=roundRecord?.cluePlayerName??game?.players.find(p=>p.id===game.cluePlayerId)?.name??'ヒント役'
  const visibleTotal = (player: Player) => displayPhase==='reveal' && game?.targetRevealed!==null && !revealComplete
    ? player.score - (player.id===(roundRecord?.cluePlayerId??game?.cluePlayerId)?(game?.hintPoints??0):(roundEntries.find(e=>e.id===player.id)?.score ?? 0)) : player.score
  const copy = async () => {
    if (!game) return
    try { await navigator.clipboard.writeText(game.room); setCopied(true) }
    catch { setStatus(`ルームコード：${game.room}`) }
  }
  const copyLink=async()=>{
    if(!game)return
    const url=invitationUrl(window.location.href,game.room)
    try{await navigator.clipboard.writeText(url);setLinkCopied(true)}
    catch{setStatus(`招待リンク：${url}`)}
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
      setStatus(errorMessage(e,'退出できませんでした。もう一度試してください。'))
    } finally { setBusy(false) }
  }

  return <main className="shell">
    <header className="top"><a className="brand" aria-label="ドノヘン？"><span className="brandicon" aria-hidden="true"><img src="/favicon.svg?v=c1" alt="" width="35" height="35"/></span><span className="brandname"><span>ド</span><span>ノ</span><span>ヘ</span><span>ン</span><span>？</span></span></a><SoundControls/></header>
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
        <div className="joinrow"><input id="room-code" className="room-code-input" value={joinCode} onChange={e=>setJoinCode(e.target.value)} inputMode="text" autoCapitalize="characters" autoCorrect="off" autoComplete="off" spellCheck={false} maxLength={8} placeholder="例：ABCD2345"/><button className="secondary" disabled={busy||!name.trim()||!joinCode.trim()} onClick={joinRoom}>参加する</button></div>
        {status&&<p className="status" role="alert">{status}</p>}
        <details className="help"><summary>遊び方</summary><p>ヒント役だけが正解の数字を見て、言葉でヒントを出します。ほかの人は0〜100で予想。正解に近いほど高得点！ ヒント役は1人1〜3回。合計点で競います。</p></details>
      </div>
    </section> : game.phase==='lobby' ? <section className="game">
      <div className="gamehead"><h1>待機室</h1><div className="score"><Users size={18}/>{game.players.length} / 12 人</div></div>
      <div className="lobby-layout"><div className="panel gamepanel lobby-main">
        <div className="invite"><span>ルームコード</span><div><b>{game.room}</b><button className="textbtn" onClick={copy}><Copy size={15}/>{copied ? 'コピーしました' : 'コピー'}</button></div><button className="secondary share-link" onClick={()=>void copyLink()}><Copy size={15}/>{linkCopied?'リンクをコピーしました':'招待リンクをコピー'}</button><p>リンクを友達に送って招待しよう。</p></div>
        <h2 className="member-heading">メンバー</h2>
        {game.players.map(p=><div className="scoreline" key={p.id}><span>{p.name}{p.id===playerId?'（あなた）':''}</span>{p.id===game.hostId&&<b>ホスト</b>}</div>)}
      </div><div className="panel gamepanel lobby-settings"><h2>ゲームの設定</h2>
        {configurable&&<fieldset className="round-settings"><legend>ヒント役は1人何回？</legend><div className="round-options">{[1,2,3].map(value=><button key={value} className={roundsPerPlayer===value?'selected':''} aria-pressed={roundsPerPlayer===value} disabled={busy||game.hostId!==playerId} onClick={()=>setRounds(value)}>{value}回</button>)}</div><p>{game.players.length}人 × {roundsPerPlayer}回 = 全{game.players.length*roundsPerPlayer}ラウンド</p></fieldset>}
        {(game.featuresVersion??0)>=1&&<fieldset className="round-settings"><legend>回答時間</legend><div className="round-options">{[0,30,60].map(value=><button key={value} className={(game.answerSeconds??0)===value?'selected':''} aria-pressed={(game.answerSeconds??0)===value} disabled={busy||game.hostId!==playerId} onClick={()=>setAnswerSeconds(value)}>{value?`${value}秒`:'なし'}</button>)}</div><p>ヒントが出てから計測。時間切れの未回答は0点です。</p></fieldset>}
        {game.hostId===playerId?<><button className="primary full" disabled={busy||!allReady} onClick={startGame}>ゲームを始める <ArrowRight size={17}/></button>{!allReady&&<p className="quiet">あと1人で始められます</p>}</>:<p className="quiet">ホストが始めるのを待とう。</p>}
        {status&&<p className="status" role="alert">{status}</p>}
      </div></div>
      <button className="back" disabled={busy} onClick={() => void leave()}>退出する</button>
    </section> : <section className="game">
      <div className="gamehead"><h1>{displayPhase==='finished'?'結果発表':<>ラウンド <em>{game.round} / {totalRounds}</em></>}</h1></div>
      {displayPhase!=='finished'&&<><div className="round-context"><span>{game.phase==='clue'?'ヒントを考える':game.phase==='guess'?'位置を予想する':'答え合わせ'}</span><span>ヒント役 · {hintName}</span></div>
      <div className="match-progress" role="progressbar" aria-label="ラウンドの進行" aria-valuenow={game.round} aria-valuemin={0} aria-valuemax={totalRounds}><i style={{width:`${Math.min(100,game.round/totalRounds*100)}%`}}/></div>
      <details className="player-overview"><summary>メンバーと合計点 <span>{game.players.length}人</span></summary><div className="players-strip">{game.players.map(p=><span className={`chip ${p.id===game.cluePlayerId?'active':''}`} key={p.id}>{p.name}{p.id===game.cluePlayerId?' · ヒント役':''}<b>{visibleTotal(p)}点</b></span>)}</div></details>
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
          {remaining!==null&&<p className={`answer-clock ${remaining<=10?'urgent':''}`} role="timer" aria-label={`残り${remaining}秒`}>残り <strong>{remaining}</strong> 秒</p>}
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
            <button className="primary full" disabled={busy||remaining===0} onClick={submitGuess}>この位置に決める <ArrowRight size={17}/></button>
            <p className="quiet">決めたあとは変更できません</p>
          </>}
        </>}
        {displayPhase==='reveal'&&<>
          <h2>{game.targetRevealed===null?((game.timedOutPlayerIds?.length??0)>0?'回答時間が終わりました':'みんなの予想がそろった！'):'答え合わせ'}</h2>
          {game.clue&&<p className="result-clue">「{game.clue}」</p>}
          {game.targetRevealed===null&&game.hostId!==playerId&&<p>ホストの発表を待とう。</p>}
          {game.targetRevealed!==null&&<>
            <ScoreReveal key={revealKey} entries={roundEntries} revealKey={revealKey} playerId={playerId} target={game.targetRevealed} onComplete={finishReveal}/>
            {revealComplete&&<div className="hint-award"><span>ヒント役 · {hintName}<small>みんなの平均点</small></span><b>+{game.hintPoints??0} 点</b></div>}
            {revealComplete&&<details className="total-overview"><summary>合計点を見る</summary>{standings.map(p=><div className="scoreline" key={p.id}><span>{p.name}{p.id===playerId?'（あなた）':''}</span><b>{p.score} 点</b></div>)}</details>}
            <details className="help"><summary>得点のつけ方</summary><p>{(game.rulesVersion??0)>=3?`ぴったりなら${(game.rulesVersion??0)>=4?15:10}点。差が1〜2で9点、3〜4で8点、5〜6で7点、7〜8で6点、9〜10で5点、11〜12で4点、13〜14で3点、15〜16で2点、17〜18で1点。19以上は0点。`:configurable?'ぴったりなら5点。差が2以内で4点、4以内で3点、6以内で2点、8以内で1点。':'ぴったりなら5点。差が3以内で4点、7以内で3点、12以内で2点、20以内で1点。'}ヒント役はみんなの平均点（四捨五入）をもらえます。</p></details>
          </>}
          {game.targetRevealed===null&&game.hostId===playerId&&<button className="primary full" disabled={busy} onClick={reveal}>答えを見る</button>}
          {game.targetRevealed!==null&&game.round<totalRounds&&game.hostId===playerId&&<button className="primary full" disabled={busy||!revealComplete} onClick={nextRound}>次のラウンド <ArrowRight size={17}/></button>}
          {game.targetRevealed!==null&&game.round>=totalRounds&&game.hostId===playerId&&<button className="primary full" disabled={busy||!revealComplete} onClick={()=>void openFinalResults()}>最終結果を見る <ArrowRight size={17}/></button>}
          {game.targetRevealed!==null&&game.round>=totalRounds&&game.hostId!==playerId&&game.phase!=='finished'&&revealComplete&&<p className="quiet">ホストが最終結果へ進むのを待とう。</p>}
        </>}
        {displayPhase==='finished'&&<div className="final-results">
          <nav className="result-tabs" aria-label="結果の表示"><button className={resultTab==='ranking'?'selected':''} aria-pressed={resultTab==='ranking'} onClick={()=>setResultTab('ranking')}>ランキング・表彰</button><button className={resultTab==='review'?'selected':''} aria-pressed={resultTab==='review'} disabled={!revealComplete} onClick={()=>setResultTab('review')}>振り返り</button></nav>
          <div hidden={resultTab!=='ranking'}>
          <h2>ランキング</h2>
          <ScoreReveal key={revealKey} entries={standings.map(p=>({id:p.id,name:p.name,score:p.score}))} revealKey={revealKey} playerId={playerId} final onComplete={finishReveal}/>
          {revealComplete&&(awards.length>0||connections.length>0)&&<section className="match-awards" aria-label="今回の表彰"><h3>みんなの見せ場</h3>{awards.map(award=><div className="award-card" key={award.title}><span>{award.title}</span><strong>{award.names.join('・')}</strong><small>{award.detail}</small></div>)}{connections.map(award=><div className={`award-card compatibility-${award.kind}`} key={award.title}><span>{award.title}</span><small>{award.kind==='close'?'あなたと解釈が近かった人':'あなたと解釈の違いが大きかった人'}</small>{award.partners.map(p=><div className="compatibility-partner" key={p.id}><strong>{p.name}</strong><small>平均の差 {p.average.toFixed(1)} · 比較{p.count}回</small></div>)}</div>)}</section>}
          {revealComplete&&<ShareResult room={game.room} result={{players:standings,playerId,rounds:totalRounds,url:publicGameUrl(window.location.href),bestHint:bestHintFor(reviewRounds,playerId)}}/>}
          </div>
          {revealComplete&&resultTab==='review'&&<MatchReview rounds={reviewRounds}/>}
          <div className="result-actions">{game.hostId===playerId?<button className="primary full" disabled={busy||!revealComplete} onClick={restart}>もう一度遊ぶ</button>:revealComplete&&<p className="quiet">ホストが次のゲームを始めるのを待とう。</p>}</div>
        </div>}
        {status&&<p className="status" role="alert">{status}</p>}
      </div>
      <button className="back" disabled={busy} onClick={() => void leave()}>退出する</button>
    </section>}
  </main>
}






