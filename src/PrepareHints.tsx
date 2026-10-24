import {useEffect,useRef,useState} from 'react'

export type PreparedHint={turnId:number;prompt:{left:string;right:string};target:number;clue:string|null;draft?:string}
type HintInput={turnId:number;clue:string}
type Props={room:string;matchId:string;playerId:string;hints:PreparedHint[];players:{id:string;name:string}[];readyIds:string[];busy:boolean;remainingSeconds?:number|null;onSave?:(hints:HintInput[])=>Promise<void>;onSubmit:(hints:HintInput[])=>Promise<boolean>}
function readDrafts(key:string):Record<number,string>{try{const value=JSON.parse(localStorage.getItem(key)??'{}');if(value&&typeof value==='object'&&!Array.isArray(value))return Object.fromEntries(Object.entries(value).filter(([id,text])=>/^\d{1,2}$/.test(id)&&typeof text==='string').map(([id,text])=>[id,Array.from(text as string).slice(0,100).join('')]))}catch{/* Draft storage is optional. */}return {}}

export default function PrepareHints({room,matchId,playerId,hints,players,readyIds,busy,remainingSeconds=null,onSave,onSubmit}:Props){
 const storageKey=`donohen-hint-drafts:${room}:${matchId}:${playerId}`
 const [drafts,setDrafts]=useState(()=>readDrafts(storageKey))
 const [saveFailed,setSaveFailed]=useState(false)
 const mounted=useRef(false),saving=useRef(false),lastAttempt=useRef(0)
 const savedSignature=useRef(JSON.stringify(hints.map(h=>({turnId:h.turnId,clue:h.draft??''}))))
 const submitted=readyIds.includes(playerId)||(hints.length>0&&hints.every(h=>h.clue!==null))
 const clearDrafts=()=>{try{localStorage.removeItem(storageKey)}catch{/* Optional. */}}
 useEffect(()=>{if(submitted)clearDrafts()},[submitted,storageKey])
 const change=(turnId:number,text:string)=>setDrafts(previous=>{const next={...previous,[turnId]:text};try{localStorage.setItem(storageKey,JSON.stringify(next))}catch{/* Continue without draft restoration. */}return next})
 const value=(h:PreparedHint)=>h.clue??drafts[h.turnId]??h.draft??''
 const complete=hints.length>0&&hints.every(h=>value(h).trim())
 const expired=remainingSeconds!==null&&remainingSeconds<=0
 const signature=JSON.stringify(hints.map(h=>({turnId:h.turnId,clue:value(h)})))
 useEffect(()=>{mounted.current=true;return()=>{mounted.current=false}},[])
 useEffect(()=>{
  if(!onSave||remainingSeconds===null||expired||submitted||busy||!hints.length||signature===savedSignature.current)return
  const timer=window.setTimeout(async()=>{
   if(saving.current||signature===savedSignature.current)return
   lastAttempt.current=Date.now();saving.current=true
   try{await onSave(JSON.parse(signature) as HintInput[]);savedSignature.current=signature;if(mounted.current)setSaveFailed(false)}
   catch{if(mounted.current)setSaveFailed(true)}
   finally{saving.current=false}
  },remainingSeconds<=3?0:Math.max(0,1500-(Date.now()-lastAttempt.current)))
  return()=>window.clearTimeout(timer)
 },[signature,remainingSeconds,expired,submitted,busy,onSave,hints.length])
 const submit=async()=>{if(busy||submitted||expired||!complete)return;if(await onSubmit(hints.map(h=>({turnId:h.turnId,clue:value(h).trim()}))))clearDrafts()}
 return <div className="hint-preparation">
  <div className="preparation-intro"><h2>{submitted?'ヒントを提出しました':'あなたのヒントを考えよう'}</h2><p>{submitted?'みんなのヒントがそろったら、カウントダウンで始まります。':`担当する${hints.length}個のお題をまとめて準備。お題と正解はあなただけに見えています。`}</p></div>
  {remainingSeconds!==null&&<p className={`answer-clock preparation-clock ${remainingSeconds<=30?'urgent':''}`} role="timer" aria-label={`準備の残り${remainingSeconds}秒`}>準備 あと <strong>{Math.floor(remainingSeconds/60)}:{String(remainingSeconds%60).padStart(2,'0')}</strong></p>}
  {remainingSeconds!==null&&!submitted&&<p className="quiet">時間切れで入力済みのヒントを自動提出します。空欄のお題はスキップします。</p>}
  {saveFailed&&!expired&&!submitted&&<p className="status" role="alert">ヒントを保存できません。接続を確認してください。</p>}
  {!hints.length&&<p role="alert">お題を取得できませんでした。再読み込みしてください。</p>}
  <div className="preparation-cards">{hints.map((hint,index)=><article className="preparation-card" key={hint.turnId}>
   <div className="preparation-card-heading"><h3>ヒント {index+1}<small> / {hints.length}</small></h3>{submitted&&<span>提出済み</span>}</div>
   <div className="poles"><span><small>0</small>{hint.prompt.left}</span><b aria-hidden="true">↔</b><span><small>100</small>{hint.prompt.right}</span></div>
   <div className="secret"><span>あなただけの正解</span><strong>{hint.target}<small> / 100</small></strong><div className="track"><i style={{left:`${hint.target}%`}}/></div></div>
   {submitted?<p className="prepared-clue">「{hint.clue??value(hint)}」</p>:<><label htmlFor={`prepared-hint-${hint.turnId}`}>このお題のヒント</label><textarea id={`prepared-hint-${hint.turnId}`} rows={2} maxLength={100} value={value(hint)} disabled={busy||expired} onChange={e=>change(hint.turnId,e.target.value)} placeholder="この正解の位置に合う言葉を考えよう"/></>}
  </article>)}</div>
  {!submitted&&<><button className="primary full" disabled={busy||expired||!complete} onClick={()=>void submit()}>ヒントを提出する</button><p className="quiet">提出後は変更できません。ヒントはラウンド順に公開します。</p></>}
  <section className="preparation-progress" aria-label="ヒントの提出状況"><div><h3>みんなの準備</h3><strong>{readyIds.length} / {players.length} 人</strong></div><div className="answerchips">{players.map(p=><span key={p.id} className={`answerchip ${readyIds.includes(p.id)?'done':''}`}><span aria-label={readyIds.includes(p.id)?'提出済み':'未提出'}>{readyIds.includes(p.id)?'✓':'○'}</span> {p.name}{p.id===playerId?'（あなた）':''}</span>)}</div></section>
 </div>
}
