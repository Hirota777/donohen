import type {RoundReview} from './MatchReview'
export type SharedPlayer={id:string;name:string;score:number}
export type BestHint={round:number;prompt:{left:string;right:string};clue:string;target:number;average:number}
export type SharedResult={players:SharedPlayer[];playerId:string;rounds:number;url:string;bestHint?:BestHint}
export function publicGameUrl(href:string):string{const url=new URL(href);url.search='';url.hash='';return url.toString()}
export function resultRank(players:SharedPlayer[],score:number):number{return players.filter(p=>p.score>score).length+1}
export function bestHintFor(rounds:RoundReview[],playerId:string):BestHint|undefined{
 const candidates=rounds.filter(r=>r.cluePlayerId===playerId&&r.results.length).map(r=>({round:r.round,prompt:r.prompt,clue:r.clue,target:r.target,average:r.results.reduce((sum,p)=>sum+p.points,0)/r.results.length})).sort((a,b)=>b.average-a.average||a.round-b.round)
 const best=candidates[0];return best?{...best,average:Number(best.average.toFixed(1))}:undefined
}
export function resultText(result:SharedResult):string{
 const p=result.players.find(p=>p.id===result.playerId)
 return p?`ドノヘン？で遊びました！\n${p.name}：${resultRank(result.players,p.score)}位／${result.players.length}人・${p.score}点\n${result.bestHint?`ベストヒント「${Array.from(result.bestHint.clue).slice(0,45).join('')}${Array.from(result.bestHint.clue).length>45?'…':''}」平均${result.bestHint.average.toFixed(1)}点\n`:''}#ドノヘン`:'ドノヘン？で遊びました！\n#ドノヘン'
}
export function socialShareUrl(service:'x'|'line',text:string,url:string):string{
 const target=new URL(service==='x'?'https://x.com/intent/tweet':'https://line.me/R/share')
 target.searchParams.set('text',service==='x'?text:`${text}\n${url}`)
 if(service==='x')target.searchParams.set('url',url)
 return target.toString()
}
export async function imageBase64(blob:Blob):Promise<string>{const bytes=new Uint8Array(await blob.arrayBuffer());let raw='';for(let i=0;i<bytes.length;i+=8192)raw+=String.fromCharCode(...bytes.subarray(i,i+8192));return btoa(raw)}
function rounded(ctx:CanvasRenderingContext2D,x:number,y:number,w:number,h:number,r:number,color:string|CanvasGradient){ctx.beginPath();ctx.moveTo(x+r,y);ctx.arcTo(x+w,y,x+w,y+h,r);ctx.arcTo(x+w,y+h,x,y+h,r);ctx.arcTo(x,y+h,x,y,r);ctx.arcTo(x,y,x+w,y,r);ctx.closePath();ctx.fillStyle=color;ctx.fill()}
function fit(ctx:CanvasRenderingContext2D,text:string,max:number){const original=Array.from(text),chars=[...original];while(chars.length&&ctx.measureText(chars.join('')+(chars.length<original.length?'…':'')).width>max)chars.pop();return chars.join('')+(chars.length<original.length?'…':'')}
function lines(ctx:CanvasRenderingContext2D,text:string,max:number,count:number):string[]{const result:string[]=[];let current='';const characters=Array.from(text.replace(/[\r\n]+/g,' '));for(let i=0;i<characters.length;i++){const char=characters[i];if(ctx.measureText(current+char).width>max){result.push(current);current='';if(result.length===count-1){result.push(fit(ctx,characters.slice(i).join(''),max));return result}}current+=char}if(current)result.push(current);return result}
export async function buildShareImage(result:SharedResult):Promise<Blob>{
 if(document.fonts)await document.fonts.ready
 const p=result.players.find(p=>p.id===result.playerId);if(!p)throw Error('No result')
 const canvas=document.createElement('canvas');canvas.width=1200;canvas.height=630;const ctx=canvas.getContext('2d');if(!ctx)throw Error('Image unavailable')
 const font='"Noto Sans JP",system-ui,sans-serif',bg=ctx.createLinearGradient(0,0,1200,630);bg.addColorStop(0,'#e3f4ff');bg.addColorStop(.5,'#fff0f6');bg.addColorStop(1,'#fff1c8');ctx.fillStyle=bg;ctx.fillRect(0,0,1200,630);rounded(ctx,28,28,1144,574,28,'#ffffffed')
 ctx.textAlign='left';ctx.font=`900 64px ${font}`;['ド','ノ','ヘ','ン','？'].forEach((c,i)=>{ctx.fillStyle=['#f56998','#f3b532','#35b7e9','#32b89c','#bd86da'][i];ctx.fillText(c,66+i*69,118)})
 ctx.font=`600 18px ${font}`;ctx.fillStyle='#788399';ctx.fillText('ことばでつたえる、みんなのものさし。',70,158)
 const spectrum=ctx.createLinearGradient(70,0,1130,0);['#34bdf3','#37cfa6','#f2cb48','#fa729a'].forEach((c,i)=>spectrum.addColorStop(i/3,c));rounded(ctx,70,182,1060,8,4,spectrum)
 ctx.fillStyle='#263655';ctx.font=`800 32px ${font}`;ctx.fillText(fit(ctx,p.name,320),70,258)
 ctx.fillStyle='#df5883';ctx.font=`900 112px ${font}`;ctx.fillText(`${resultRank(result.players,p.score)}位`,64,390)
 ctx.fillStyle='#263655';ctx.font=`800 60px ${font}`;ctx.fillText(`${p.score}`,70,480);const scoreWidth=ctx.measureText(String(p.score)).width;ctx.font=`700 23px ${font}`;ctx.fillText('点',84+scoreWidth,480)
 ctx.fillStyle='#788399';ctx.font=`600 19px ${font}`;ctx.fillText(`${result.players.length}人・全${result.rounds}ラウンド`,70,530)
 rounded(ctx,425,220,705,320,22,'#f5f5fc');ctx.fillStyle='#967336';ctx.font=`800 22px ${font}`;ctx.fillText('ベストヒント',452,260)
 const best=result.bestHint
 if(best){
  ctx.fillStyle='#68758f';ctx.font=`600 22px ${font}`;ctx.textAlign='right';ctx.fillText(`正解 ${best.target}`,1100,260);ctx.textAlign='left'
  ctx.fillStyle='#263655';ctx.font=`800 32px ${font}`;const clueLines=lines(ctx,`「${best.clue}」`,644,4);clueLines.forEach((line,i)=>ctx.fillText(line,452,378-(clueLines.length-1)*20+i*40))
  ctx.fillStyle='#68758f';ctx.font=`600 20px ${font}`;ctx.fillText(fit(ctx,`0 · ${best.prompt.left}`,285),452,474);ctx.textAlign='right';ctx.fillText(fit(ctx,`100 · ${best.prompt.right}`,285),1100,474);ctx.textAlign='left'
  const answerScale=ctx.createLinearGradient(452,0,1100,0);['#34bdf3','#37cfa6','#f2cb48','#fa729a'].forEach((c,i)=>answerScale.addColorStop(i/3,c));rounded(ctx,452,506,648,8,4,answerScale)
  const answerX=452+648*Math.max(0,Math.min(100,best.target))/100
  ctx.beginPath();ctx.arc(answerX,510,11,0,Math.PI*2);ctx.fillStyle='#263655';ctx.fill();ctx.beginPath();ctx.arc(answerX,510,7,0,Math.PI*2);ctx.fillStyle='#fff';ctx.fill()
 }
 else{ctx.fillStyle='#68758f';ctx.font=`600 24px ${font}`;ctx.fillText('ヒント役の記録はありません',452,355)}
 ctx.fillStyle='#8c94a5';ctx.font=`500 17px ${font}`;ctx.fillText(fit(ctx,new URL(result.url).host,780),70,578);ctx.textAlign='right';ctx.fillStyle='#b45c80';ctx.font=`700 20px ${font}`;ctx.fillText('#ドノヘン',1130,578)
 return new Promise((resolve,reject)=>canvas.toBlob(blob=>blob?resolve(blob):reject(Error('Image unavailable')),'image/png'))
}
