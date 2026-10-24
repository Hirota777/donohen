export type MatchStat = { guessRounds?: number; answeredRounds?: number; totalDistance?: number; exactHits?: number; hintRounds?: number; hintPoints?: number }
import type {RoundReview} from './MatchReview'
export function compatibilityAwards(players:{id:string;name:string}[],rounds:RoundReview[],playerId:string){
 const pairs=players.filter(p=>p.id!==playerId).map(p=>{let distance=0,count=0;
  for(const round of rounds){
   const own=round.cluePlayerId===playerId?round.target:round.results.find(r=>r.playerId===playerId)?.guess
   const other=round.cluePlayerId===p.id?round.target:round.results.find(r=>r.playerId===p.id)?.guess
   if(typeof own==='number'&&typeof other==='number'){distance+=Math.abs(own-other);count++}
  }
  return {...p,count,average:count?distance/count:0}
 }).filter(p=>p.count>=2)
 if(!pairs.length)return []
 const closest=Math.min(...pairs.map(p=>p.average)),farthest=Math.max(...pairs.map(p=>p.average))
 const awards=[{title:'波長がぴったり',kind:'close',partners:pairs.filter(p=>Math.abs(p.average-closest)<1e-9)}]
 if(farthest>closest+1e-9)awards.push({title:'すれ違いも楽しい',kind:'different',partners:pairs.filter(p=>Math.abs(p.average-farthest)<1e-9)})
 return awards
}
export function differenceLabel(guess: number|undefined,target:number):string {
  if(guess===undefined)return '未回答'
  const difference=guess-target
  return difference===0?'ぴったり':`正解より ${difference>0?'＋':'−'}${Math.abs(difference)}`
}
export function invitationCode(search: string): string {
  const value=(new URLSearchParams(search).get('room')??'').normalize('NFKC').trim().toUpperCase()
  return /^[A-Z2-9]{8}$/.test(value)?value:''
}
export function invitationUrl(href: string, room: string): string {
  const url=new URL(href);url.search='';url.hash='';url.searchParams.set('room',room);return url.toString()
}
export function matchAwards(players: {id:string;name:string}[], stats: Record<string,MatchStat>) {
  const rows=players.map(p=>({...p,stat:stats[p.id]??{}}))
  const awards:{title:string;names:string[];detail:string}[]=[]
  const exact=Math.max(0,...rows.map(p=>p.stat.exactHits??0))
  if(exact>0)awards.push({title:'ぴったり賞',names:rows.filter(p=>p.stat.exactHits===exact).map(p=>p.name),detail:`完全一致 ${exact}回`})
  const accurate=rows.filter(p=>(p.stat.answeredRounds??0)>0&&p.stat.answeredRounds===p.stat.guessRounds)
  if(accurate.length){const best=Math.min(...accurate.map(p=>p.stat.totalDistance!/p.stat.answeredRounds!));awards.push({title:'精度賞',names:accurate.filter(p=>Math.abs(p.stat.totalDistance!/p.stat.answeredRounds!-best)<1e-9).map(p=>p.name),detail:`平均の差 ${best.toFixed(1)}（未回答なし）`})}
  const hints=rows.filter(p=>(p.stat.hintRounds??0)>0)
  if(hints.length){const best=Math.max(...hints.map(p=>(p.stat.hintPoints??0)/p.stat.hintRounds!));if(best>0)awards.push({title:'ヒント名人',names:hints.filter(p=>Math.abs((p.stat.hintPoints??0)/p.stat.hintRounds!-best)<1e-9).map(p=>p.name),detail:`ヒント役の平均 ${best.toFixed(1)}点`})}
  return awards
}
