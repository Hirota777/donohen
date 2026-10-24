import { useEffect, useRef, useState } from 'react'
import { scoreGroups, scoreRank, visibleScores, type ScoreEntry } from './ranking'

type Props = { entries: ScoreEntry[]; revealKey: string; playerId: string; final?: boolean; onComplete: () => void }

export default function ScoreReveal({ entries, revealKey, playerId, final = false, onComplete }: Props) {
  const [count, setCount] = useState(0)
  const timer = useRef<number>()
  const groups = scoreGroups(entries)
  const complete = count >= groups.length
  const storageKey = `donohen-reveal-${revealKey}`
  const finish = () => {
    window.clearTimeout(timer.current)
    setCount(groups.length)
    try { sessionStorage.setItem(storageKey,'done') } catch { /* Optional presentation state. */ }
    onComplete()
  }

  useEffect(() => {
    let saved = false
    try { saved = sessionStorage.getItem(storageKey) === 'done' } catch { /* Continue without storage. */ }
    if (saved || window.matchMedia('(prefers-reduced-motion: reduce)').matches || !groups.length) {
      setCount(groups.length); onComplete(); return
    }
    setCount(0)
    let visible = 0
    const advance = () => {
      visible++
      setCount(visible)
      if (visible >= groups.length) {
        // Let the winning entry settle before enabling the next action.
        timer.current = window.setTimeout(() => {
          try { sessionStorage.setItem(storageKey,'done') } catch { /* Optional. */ }
          onComplete()
        }, 1200)
      } else timer.current = window.setTimeout(advance, 2000)
    }
    timer.current = window.setTimeout(advance, 900)
    return () => window.clearTimeout(timer.current)
  }, [storageKey, groups.length, onComplete])

  return <div className={`score-reveal ${final?'final-reveal':''}`}>
    <div className="reveal-list" aria-live="polite" aria-relevant="additions">
      {!count&&<div className="reveal-curtain" aria-label="結果発表"><span>?</span><span>?</span><span>?</span></div>}
      {visibleScores(entries,count).map(entry => <div className={`scoreline reveal-entry ${entry.id===playerId?'myanswer':''} ${scoreRank(entries,entry.score)===1?'winner':''}`} key={entry.id}>
        <span className="reveal-player"><span><b className="reveal-rank">{scoreRank(entries,entry.score)}位</b> {entry.name}{entry.id===playerId?'（あなた）':''}</span>
          {!final&&entry.guess!==undefined&&<span className="reveal-guess"><span>予想</span><strong>{entry.guess}</strong></span>}
          {entry.detail&&<small>{entry.detail}</small>}
        </span>
        <b className="reveal-points">{final?'':'+'}{entry.score} 点</b>
      </div>)}
    </div>
    {!complete&&<button className="textbtn reveal-skip" onClick={finish}>まとめて見る</button>}
  </div>
}

