import type { ScoreEntry } from './ranking'

export default function PredictionScale({entries,target}:{entries:ScoreEntry[];target:number}) {
  return <section className="prediction-scale" aria-label="みんなの予想位置">
    <div className="scale-heading"><span>0</span><strong>正解 {target}</strong><span>100</span></div>
    <div className="scale-ruler"><i style={{left:`${target}%`}}/></div>
    {entries.map(entry=><div className="prediction-lane" key={entry.id}>
      <div><span>{entry.name}</span><b>{entry.guess===undefined?'時間切れ':entry.guess}</b></div>
      <div className="lane-track"><i className="lane-target" style={{left:`${target}%`}}/>{entry.guess!==undefined&&<i className="lane-guess" style={{left:`${entry.guess}%`}}/>}</div>
    </div>)}
  </section>
}
