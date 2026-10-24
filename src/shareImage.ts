export type SharedPlayer={id:string;name:string;score:number}
export type SharedResult={players:SharedPlayer[];playerId:string;rounds:number;url:string}
export type ShareMode='personal'|'all'
export function publicGameUrl(href:string):string {const url=new URL(href);url.search='';url.hash='';return url.toString()}
export function resultRank(players:SharedPlayer[],score:number):number{return players.filter(p=>p.score>score).length+1}
export function resultText(result:SharedResult):string {
 const player=result.players.find(p=>p.id===result.playerId)
 return player?`ドノヘン？で遊びました！\n${player.name}：${resultRank(result.players,player.score)}位／${result.players.length}人・${player.score}点\nことばでつたえる、みんなのものさし。\n#ドノヘン`:'ドノヘン？で遊びました！\n#ドノヘン'
}
function rounded(ctx:CanvasRenderingContext2D,x:number,y:number,w:number,h:number,r:number,color:string|CanvasGradient){
 ctx.beginPath();ctx.moveTo(x+r,y);ctx.arcTo(x+w,y,x+w,y+h,r);ctx.arcTo(x+w,y+h,x,y+h,r);ctx.arcTo(x,y+h,x,y,r);ctx.arcTo(x,y,x+w,y,r);ctx.closePath();ctx.fillStyle=color;ctx.fill()
}
function fit(ctx:CanvasRenderingContext2D,text:string,max:number){let chars=Array.from(text);while(chars.length&&ctx.measureText(chars.join('')+(chars.length<Array.from(text).length?'…':'')).width>max)chars.pop();return chars.join('')+(chars.length<Array.from(text).length?'…':'')}
export async function buildShareImage(result:SharedResult,mode:ShareMode):Promise<Blob>{
 if(document.fonts)await document.fonts.ready
 const canvas=document.createElement('canvas');canvas.width=1080;canvas.height=mode==='all'?Math.max(1250,760+result.players.length*94):1350
 const ctx=canvas.getContext('2d');if(!ctx)throw Error('Image unavailable')
 const font='"Noto Sans JP",system-ui,sans-serif',width=canvas.width,height=canvas.height
 const bg=ctx.createLinearGradient(0,0,width,height);bg.addColorStop(0,'#e7f5ff');bg.addColorStop(.48,'#fff4f8');bg.addColorStop(1,'#fff2cc');ctx.fillStyle=bg;ctx.fillRect(0,0,width,height)
 ctx.globalAlpha=.45;ctx.fillStyle='#fff';ctx.beginPath();ctx.arc(1080,0,520,0,Math.PI*2);ctx.fill();ctx.beginPath();ctx.arc(0,height,430,0,Math.PI*2);ctx.fill();ctx.globalAlpha=1
 rounded(ctx,60,60,960,height-120,44,'#ffffffdc')
 ctx.textAlign='left';ctx.font=`900 85px ${font}`;['ド','ノ','ヘ','ン','？'].forEach((c,i)=>{ctx.fillStyle=['#f56998','#f3b532','#35b7e9','#32b89c','#bd86da'][i];ctx.fillText(c,112+i*91,180)})
 ctx.fillStyle='#788399';ctx.font=`600 20px ${font}`;ctx.fillText('ことばでつたえる、みんなのものさし。',120,230)
 const spectrum=ctx.createLinearGradient(120,0,960,0);['#34bdf3','#37cfa6','#f2cb48','#fa729a'].forEach((c,i)=>spectrum.addColorStop(i/3,c));rounded(ctx,120,270,840,12,6,spectrum)
 ctx.fillStyle='#788399';ctx.font=`700 21px ${font}`;ctx.fillText(mode==='all'?'FINAL RANKING':'MY RESULT',120,340)
 const sorted=[...result.players].sort((a,b)=>b.score-a.score||a.name.localeCompare(b.name,'ja'))
 if(mode==='all'){
  ctx.fillStyle='#263655';ctx.font=`800 43px ${font}`;ctx.fillText('みんなの結果',120,405)
  sorted.forEach((p,i)=>{const y=447+i*94;const rank=resultRank(sorted,p.score);rounded(ctx,106,y,868,80,17,rank===1?'#fff0ce':p.id===result.playerId?'#fff0f6':'#f4f6fb');ctx.fillStyle=rank===1?'#a97817':'#7b849b';ctx.font=`800 25px ${font}`;ctx.fillText(`${rank}`,132,y+51);ctx.fillStyle='#263655';ctx.font=`700 27px ${font}`;ctx.fillText(fit(ctx,p.name,560),193,y+51);ctx.textAlign='right';ctx.font=`800 31px ${font}`;ctx.fillStyle='#df5883';ctx.fillText(`${p.score}点`,942,y+51);ctx.textAlign='left'})
 }else{
  const p=result.players.find(p=>p.id===result.playerId)??sorted[0];if(!p)throw Error('No results')
  ctx.fillStyle='#263655';ctx.font=`800 47px ${font}`;ctx.fillText(fit(ctx,p.name,830),120,420)
  ctx.fillStyle='#df5883';ctx.font=`900 155px ${font}`;ctx.fillText(`${resultRank(sorted,p.score)}位`,112,635)
  ctx.fillStyle='#7a8499';ctx.font=`500 29px ${font}`;ctx.fillText(`${result.players.length}人で遊びました`,120,690)
  rounded(ctx,112,750,856,210,27,'#f4f6fc');ctx.fillStyle='#7a8499';ctx.font=`700 24px ${font}`;ctx.fillText('TOTAL SCORE',150,803);ctx.fillStyle='#263655';ctx.font=`900 104px ${font}`;ctx.fillText(`${p.score}`,146,916);const scoreWidth=ctx.measureText(String(p.score)).width;ctx.font=`700 32px ${font}`;ctx.fillText('点',146+scoreWidth+18,916)
  ctx.fillStyle='#7a8499';ctx.font=`600 25px ${font}`;ctx.fillText(`全${result.rounds}ラウンド、おつかれさま！`,120,1040)
 }
 ctx.fillStyle='#7a8499';ctx.font=`600 23px ${font}`;ctx.fillText(`${result.players.length} PLAYERS  /  ${result.rounds} ROUNDS`,120,height-205)
 ctx.fillStyle='#263655';ctx.font=`700 27px ${font}`;ctx.fillText('あなたも、どのへん？',120,height-155)
 ctx.fillStyle='#8d94a4';ctx.font=`500 19px ${font}`;ctx.fillText(fit(ctx,new URL(result.url).host,820),120,height-112)
 return new Promise((resolve,reject)=>canvas.toBlob(blob=>blob?resolve(blob):reject(Error('Image unavailable')),'image/png'))
}
