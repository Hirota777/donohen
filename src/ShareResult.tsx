import {useEffect,useRef,useState} from 'react'
import {buildShareImage,imageBase64,resultText,socialShareUrl,type SharedResult} from './shareImage'
import {checkedRpc,errorMessage} from './session'

export default function ShareResult({result,room}:{result:SharedResult;room:string}){
 const [image,setImage]=useState<{url:string;blob:Blob;signature:string}|null>(null),[failed,setFailed]=useState(false)
 const [open,setOpen]=useState(false),[message,setMessage]=useState(''),[busy,setBusy]=useState(false),[sharedUrl,setSharedUrl]=useState('')
 const signature=JSON.stringify(result),dialog=useRef<HTMLDialogElement>(null),request=useRef<Promise<string>|null>(null)
 useEffect(()=>{let active=true,url='';setFailed(false);setSharedUrl('');request.current=null
  void buildShareImage(result).then(blob=>{if(!active)return;url=URL.createObjectURL(blob);setImage({url,blob,signature})}).catch(()=>{if(active)setFailed(true)})
  return()=>{active=false;if(url)URL.revokeObjectURL(url)}
 },[signature])
 useEffect(()=>{if(open)dialog.current?.showModal?.();else dialog.current?.close?.()},[open])
 const ready=image?.signature===signature&&!failed
 const prepare=()=>{
  if(sharedUrl)return Promise.resolve(sharedUrl)
  if(!request.current)request.current=(async()=>{
   if(!image||!ready)throw Error('Image unavailable')
   const encoded=await imageBase64(image.blob)
   const response=await checkedRpc('spectrum_create_result_share',{p_room_code:room,p_player_id:result.playerId,p_png:encoded}) as {token?:string}
   if(!response.token||! /^[0-9a-f-]{36}$/i.test(response.token))throw Error('Share unavailable')
   const url=new URL('/api/share',result.url);url.searchParams.set('token',response.token);setSharedUrl(url.href);return url.href
  })().catch(error=>{request.current=null;throw error})
  return request.current
 }
 const select=async(service:'x'|'line')=>{
  if(busy)return
  setBusy(true);setMessage('')
  // Open a same-origin tab synchronously so popup blockers do not swallow the post screen.
  let popup:Window|null=null
  try{popup=window.open('about:blank','_blank');if(popup)popup.opener=null}catch{/* Offer the explicit post links if popups are blocked. */}
  try{const url=await prepare(),target=socialShareUrl(service,resultText(result),url);if(popup&&!popup.closed)popup.location.replace(target);else setMessage('新しい画面を開けませんでした。下のリンクから投稿できます。')}
  catch(error){popup?.close();setMessage(errorMessage(error,'共有ページを作成できませんでした。時間をおいて試してください。'))}
  finally{setBusy(false)}
 }
 const others=async()=>{if(!sharedUrl||!navigator.share||busy)return;setBusy(true);try{await navigator.share({title:'ドノヘン？の結果',text:resultText(result),url:sharedUrl})}catch(error){if(!(error instanceof Error&&error.name==='AbortError'))setMessage('この端末では共有できませんでした。XまたはLINEを選んでください。')}finally{setBusy(false)}}
 return <section className="share-result" aria-label="結果をシェア">
  <div className="section-heading"><h2>この結果をシェア</h2><span>#ドノヘン</span></div>
  {ready&&image?<img className="share-preview" src={image.url} alt="自分の順位・得点とベストヒントの共有画像"/>:<div className="share-preview-placeholder" aria-busy={!failed}>{failed?'画像を作成できませんでした。再読み込みして試してください。':<span className="sr-only">画像を準備中</span>}</div>}
  <button className="primary full" disabled={!ready} onClick={()=>setOpen(true)}>結果を共有する</button>
  {open&&<dialog ref={dialog} className="share-dialog" open={typeof HTMLDialogElement==='undefined'} onCancel={e=>{if(busy)e.preventDefault();else setOpen(false)}} aria-labelledby="share-dialog-title"><div className="share-dialog-heading"><h2 id="share-dialog-title">どこにシェアする？</h2><button aria-label="共有画面を閉じる" disabled={busy} onClick={()=>setOpen(false)}>×</button></div><p>自分の結果とベストヒントを、画像付きの結果リンクで共有します。</p><div className="social-destinations"><button className="social-x" disabled={busy} onClick={()=>void select('x')}><b>𝕏</b>Xに投稿</button><button className="social-line" disabled={busy} onClick={()=>void select('line')}><b>LINE</b>LINEで送る</button></div><p className="share-disclosure">選ぶと、表示中の画像の公開リンクを作成します。ゲーム側での有効期間は7日間です。</p>
   {sharedUrl&&<div className="share-retry"><a href={socialShareUrl('x',resultText(result),sharedUrl)} target="_blank" rel="noopener noreferrer">Xの投稿画面を開く</a><a href={socialShareUrl('line',resultText(result),sharedUrl)} target="_blank" rel="noopener noreferrer">LINEの送信画面を開く</a>{typeof navigator.share==='function'&&<button className="secondary" disabled={busy} onClick={()=>void others()}>その他のアプリへ</button>}</div>}
   {busy&&<p role="status" className="quiet">共有ページを準備しています</p>}{message&&<p className="share-message" role="status">{message}</p>}
  </dialog>}
 </section>
}
