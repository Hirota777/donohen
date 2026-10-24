import { useEffect,useState } from 'react'
import {buildShareImage,resultText,type SharedResult,type ShareMode} from './shareImage'

export default function ShareResult({result}:{result:SharedResult}) {
 const [mode,setMode]=useState<ShareMode>('personal')
 const [image,setImage]=useState<{url:string;file:File;signature:string;mode:ShareMode}|null>(null)
 const [message,setMessage]=useState(''),[sharing,setSharing]=useState(false),[failed,setFailed]=useState(false)
 const signature=JSON.stringify(result)
 useEffect(()=>{let active=true,objectUrl='';setFailed(false);setMessage('');
  void buildShareImage(result,mode).then(blob=>{if(!active)return;objectUrl=URL.createObjectURL(blob);setImage({url:objectUrl,file:new File([blob],'donohen-result.png',{type:'image/png'}),signature,mode})}).catch(()=>{if(active)setFailed(true)})
  return()=>{active=false;if(objectUrl)URL.revokeObjectURL(objectUrl)}
 },[signature,mode])
 const ready=image?.signature===signature&&image.mode===mode&&!failed
 const save=()=>{if(!ready||!image)return;const a=document.createElement('a');a.href=image.url;a.download='donohen-result.png';document.body.appendChild(a);a.click();a.remove();setMessage('画像を保存しました。SNSの投稿に添付できます。')}
 const share=async()=>{
  if(!ready||!image||sharing)return
  try{
   if(!navigator.share||!navigator.canShare?.({files:[image.file]})){save();return}
   setSharing(true)
   await navigator.share({files:[image.file],title:'ドノヘン？の結果',text:resultText(result),url:result.url})
  }catch(error){if(!(error instanceof Error&&error.name==='AbortError'))setMessage('共有できませんでした。「画像を保存」から投稿に添付できます。')}
  finally{setSharing(false)}
 }
 const copyText=async()=>{try{await navigator.clipboard.writeText(`${resultText(result)}\n${result.url}`);setMessage('投稿文をコピーしました。')}catch{setMessage('コピーできませんでした。もう一度試してください。')}}
 return <section className="share-result" aria-label="結果をシェア">
  <div className="section-heading"><h2>この結果をシェア</h2><span>#ドノヘン</span></div>
  <div className="share-mode" aria-label="共有画像の内容"><button disabled={sharing} className={mode==='personal'?'selected':''} aria-pressed={mode==='personal'} onClick={()=>setMode('personal')}>自分の結果</button><button disabled={sharing} className={mode==='all'?'selected':''} aria-pressed={mode==='all'} onClick={()=>setMode('all')}>全員のランキング</button></div>
  {ready&&image?<img className="share-preview" src={image.url} alt={mode==='personal'?'自分の順位・得点の共有画像':'全員のランキングの共有画像'}/>:<div className="share-preview-placeholder" aria-busy={!failed}>{failed?'画像を作成できませんでした。投稿文はコピーできます。':<span className="sr-only">画像を準備中</span>}</div>}
  <button className="primary full" disabled={!ready||sharing} onClick={()=>void share()}>結果を共有する</button>
  <div className="share-options"><button className="textbtn" disabled={!ready||sharing} onClick={save}>画像を保存</button><button className="textbtn" onClick={()=>void copyText()}>投稿文をコピー</button></div>
  <p className="quiet">共有先を選べない場合は、画像を保存して投稿に添付できます。</p>
  {message&&<p className="share-message" role="status">{message}</p>}
 </section>
}
