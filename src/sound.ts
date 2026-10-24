export type SoundPreferences={muted:boolean;volume:number}
let preferences:SoundPreferences|null=null,context:AudioContext|null=null,master:GainNode|null=null
export function soundPreferences():SoundPreferences{
 if(!preferences){try{const saved=JSON.parse(localStorage.getItem('donohen-sound')??'null');preferences={muted:saved?.muted===true,volume:typeof saved?.volume==='number'&&Number.isFinite(saved.volume)?Math.max(0,Math.min(1,saved.volume)):0.3}}catch{preferences={muted:false,volume:0.3}}}
 return preferences!
}
export function setSoundPreferences(next:SoundPreferences){preferences={muted:next.muted,volume:Math.max(0,Math.min(1,next.volume))};try{localStorage.setItem('donohen-sound',JSON.stringify(preferences))}catch{/* Optional preference. */}if(context&&master)master.gain.setValueAtTime(preferences.muted?0:preferences.volume*0.16,context.currentTime)}
export async function unlockSound(){try{if(!context){if(typeof AudioContext==='undefined')return;context=new AudioContext();master=context.createGain();master.connect(context.destination)}if(context.state==='suspended')await context.resume();const p=soundPreferences();master!.gain.setValueAtTime(p.muted?0:p.volume*0.16,context.currentTime)}catch{/* Browser may block audio until another interaction. */}}
export function playClueSound(){
 const prefs=soundPreferences();if(prefs.muted||prefs.volume===0||!context||context.state!=='running'||!master)return
 const audio=context,at=audio.currentTime
 for(const [index,frequency] of [784,1046.5].entries()){
  const note=audio.createOscillator(),envelope=audio.createGain(),start=at+index*0.15;note.type='sine';note.frequency.setValueAtTime(frequency,start);envelope.gain.setValueAtTime(0,start);envelope.gain.linearRampToValueAtTime(0.8,start+0.015);envelope.gain.exponentialRampToValueAtTime(0.001,start+0.48);note.connect(envelope);envelope.connect(master);note.start(start);note.stop(start+0.5);note.onended=()=>{note.disconnect();envelope.disconnect()}
 }
}
export type HintMoment={room:string;matchId?:string;round:number;phase:string;clue:string;cluePlayerId?:string}
export function isNewClue(previous:HintMoment|null,next:HintMoment):boolean{return !!previous&&previous.room===next.room&&next.phase==='guess'&&!!next.clue.trim()&&(previous.matchId!==next.matchId||previous.round!==next.round||previous.phase!=='guess'||previous.clue!==next.clue||previous.cluePlayerId!==next.cluePlayerId)}
