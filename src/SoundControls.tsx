import {useEffect,useState} from 'react'
import {playClueSound,setSoundPreferences,soundPreferences,unlockSound} from './sound'
export default function SoundControls(){
 const [prefs,setPrefs]=useState(soundPreferences)
 useEffect(()=>{const unlock=()=>void unlockSound();window.addEventListener?.('pointerdown',unlock,{capture:true});window.addEventListener?.('keydown',unlock,{capture:true});return()=>{window.removeEventListener?.('pointerdown',unlock,{capture:true});window.removeEventListener?.('keydown',unlock,{capture:true})}},[])
 const update=(next:typeof prefs)=>{setPrefs(next);setSoundPreferences(next)}
 return <details className="sound-controls"><summary aria-label="通知音の設定">{prefs.muted||prefs.volume===0?'♪ オフ':'♪ 音'}</summary><div className="sound-popover"><button className="secondary" aria-pressed={prefs.muted} onClick={()=>update({...prefs,muted:!prefs.muted})}>{prefs.muted?'ミュート解除':'ミュート'}</button><label>音量 <output>{Math.round(prefs.volume*100)}%</output><input aria-label="通知音の音量" type="range" min="0" max="100" value={Math.round(prefs.volume*100)} onChange={e=>update({...prefs,volume:Number(e.target.value)/100})}/></label><button className="textbtn" disabled={prefs.muted||prefs.volume===0} onClick={()=>void unlockSound().then(playClueSound)}>音を試す</button></div></details>
}
