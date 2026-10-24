import PredictionScale from './PredictionScale'

export type RoundReview = {
  round:number;prompt:{left:string;right:string};clue:string;cluePlayerId:string;cluePlayerName:string;
  target:number;hintPoints:number;
  results:{playerId:string;name:string;guess:number|null;distance:number|null;points:number;timedOut?:boolean}[]
}
export default function MatchReview({rounds}:{rounds:RoundReview[]}) {
  return <section className="match-review" aria-label="ラウンドの振り返り">
    <div className="section-heading"><h2>ラウンドの振り返り</h2><span>{rounds.length}ラウンドの記録</span></div>
    {!rounds.length&&<p className="quiet">このゲームの記録はありません。次のゲームから振り返れます。</p>}
    {rounds.map((round,index)=><details className="review-round" key={round.round} open={index===0}>
      <summary><span className="round-number">{String(round.round).padStart(2,'0')}</span><span className="review-summary"><strong>「{round.clue}」</strong><small>{round.cluePlayerName}のヒント</small></span><span className="review-target">正解 <b>{round.target}</b></span></summary>
      <div className="review-body"><div className="review-poles"><span><small>0</small>{round.prompt.left}</span><span aria-hidden="true">↔</span><span><small>100</small>{round.prompt.right}</span></div>
        <PredictionScale entries={round.results.map(r=>({id:r.playerId,name:r.name,score:r.points,guess:r.guess??undefined}))} target={round.target} showPoints/>
        <div className="hint-award"><span>ヒント役 · {round.cluePlayerName}<small>みんなの平均点</small></span><b>+{round.hintPoints} 点</b></div>
      </div>
    </details>)}
  </section>
}
